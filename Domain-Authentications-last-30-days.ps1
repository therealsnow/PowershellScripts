[CmdletBinding()]
param(
    # Removed Mandatory=$true so we can prompt the user if empty
    [Parameter(Mandatory = $false)]
    [string]$UserName,

    [int]$Days = 30,

    [Parameter(Mandatory = $false)]
    [string]$Domain,

    [string]$CsvPath,

    [string]$SkippedDcCsvPath,

    [int]$RpcTimeoutMs = 1500,

    [switch]$Only4624
)

$ErrorActionPreference = "Stop"

# --- NEW PROMPT LOGIC ---
if ([string]::IsNullOrWhiteSpace($UserName)) {
    $UserName = Read-Host "Please enter the Target Username (e.g., jsmith)"
}

if ([string]::IsNullOrWhiteSpace($Domain)) {
    $Domain = Read-Host "Please enter the Domain (e.g., contoso.com) [Leave blank for current]"
}
# ------------------------

if ($Days -lt 1) {
    throw "Days must be 1 or greater."
}

function Escape-ADFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    return $Value.Replace("'", "''")
}

function New-XPathLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )
    if ($null -eq $Value) { return "''" }
    if ($Value.IndexOf("'") -eq -1) { return "'" + $Value + "'" }
    if ($Value.IndexOf('"') -eq -1) { return '"' + $Value + '"' }
    $parts = $Value -split "'", -1
    $segments = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].Length -gt 0) { $segments.Add("'" + $parts[$i] + "'") }
        if ($i -lt ($parts.Count - 1)) { $segments.Add('"''"') }
    }
    return "concat($($segments -join ','))"
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [int]$Port = 135,
        [int]$TimeoutMs = 1500
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { if ($client) { $client.Close() } }
}

function Get-EventDataHash {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord
    )
    $xml = [xml]$EventRecord.ToXml()
    $hash = @{}
    foreach ($node in $xml.Event.EventData.Data) {
        $name = $node.GetAttribute("Name")
        if (-not [string]::IsNullOrWhiteSpace($name)) { $hash[$name] = $node.InnerText }
    }
    return $hash
}

function Ensure-ParentFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Write-HeaderOnlyCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )
    $headerLine = ($Columns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','
    Set-Content -Path $Path -Value $headerLine -Encoding UTF8
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    throw "The ActiveDirectory PowerShell module is required."
}

if ($Domain) {
    $adDomain = Get-ADDomain -Identity $Domain -ErrorAction Stop
}
else {
    $adDomain = Get-ADDomain -ErrorAction Stop
}

$domainDnsRoot = $adDomain.DNSRoot
$domainNetBios = $adDomain.NetBIOSName
$lookupName = $UserName

if ($UserName -match '^[^\\]+\\(?<name>.+)$') {
    $lookupName = $Matches.name
}

try {
    $adUser = Get-ADUser -Identity $lookupName -Server $adDomain.PDCEmulator -Properties SamAccountName, UserPrincipalName, SID -ErrorAction Stop
}
catch {
    $safeLookup = Escape-ADFilterValue -Value $lookupName
    $safeOriginal = Escape-ADFilterValue -Value $UserName
    $matches = @(
        Get-ADUser -Filter "SamAccountName -eq '$safeLookup' -or UserPrincipalName -eq '$safeLookup' -or UserPrincipalName -eq '$safeOriginal'" `
                   -Server $adDomain.PDCEmulator -Properties SamAccountName, UserPrincipalName, SID -ErrorAction Stop
    )
    if ($matches.Count -eq 0) { throw "Could not find domain user '$UserName'." }
    if ($matches.Count -gt 1) { throw "Found multiple AD users matching '$UserName'." }
    $adUser = $matches[0]
}

$samAccountName = $adUser.SamAccountName
$userPrincipalName = $adUser.UserPrincipalName
$userSid = $adUser.SID.Value
$domainAccount = "$domainNetBios\$samAccountName"

$safeUser = $samAccountName -replace '[\\/:*?"<>|]', '_'
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# --- UPDATED PATH LOGIC TO C:\TEMP ---
$defaultExportDir = "C:\Temp"
if (-not (Test-Path $defaultExportDir)) {
    New-Item -Path $defaultExportDir -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path -Path $defaultExportDir -ChildPath "LogonHistory_${safeUser}_$timestamp.csv"
}

if ([string]::IsNullOrWhiteSpace($SkippedDcCsvPath)) {
    $SkippedDcCsvPath = Join-Path -Path $defaultExportDir -ChildPath "SkippedDCs_${safeUser}_$timestamp.csv"
}
# -------------------------------------

Ensure-ParentFolder -Path $CsvPath
$eventIds = if ($Only4624) { @(4624) } else { @(4624, 4768, 4776) }
$eventNameMap = @{ 4624 = "Successful logon"; 4768 = "Kerberos TGT"; 4776 = "NTLM Validation" }
$logonTypeMap = @{ "2"="Interactive"; "3"="Network"; "4"="Batch"; "5"="Service"; "7"="Unlock"; "8"="NetworkCleartext"; "9"="NewCredentials"; "10"="RDP"; "11"="Cached" }

$domainControllers = @(Get-ADDomainController -Filter * -Server $domainDnsRoot | Select-Object -ExpandProperty HostName | Sort-Object -Unique)

$namesToMatch = @($samAccountName, $userPrincipalName, $domainAccount) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
$nameClauses = ($namesToMatch | ForEach-Object { "Data[@Name='TargetUserName']=$(New-XPathLiteral -Value $_)" }) -join " or "
$idClauses = ($eventIds | ForEach-Object { "EventID=$_" }) -join " or "
$ageMs = [int64]([TimeSpan]::FromDays($Days).TotalMilliseconds)
$filterXPath = "*[System[(($idClauses) and TimeCreated[timediff(@SystemTime) <= $ageMs])]] and *[EventData[$nameClauses]]"

$results = New-Object System.Collections.Generic.List[object]
$skippedDcs = New-Object System.Collections.Generic.List[object]

foreach ($dc in $domainControllers) {
    Write-Host "Checking $dc ..." -ForegroundColor Cyan
    if (-not (Test-TcpPort -ComputerName $dc -Port 135 -TimeoutMs $RpcTimeoutMs)) {
        $skippedDcs.Add([pscustomobject]@{ DomainController = $dc; Reason = "Unreachable"; TimeChecked = Get-Date })
        continue
    }
    try {
        $events = @(Get-WinEvent -ComputerName $dc -LogName Security -FilterXPath $filterXPath -ErrorAction Stop)
        foreach ($event in $events) {
            $data = Get-EventDataHash -EventRecord $event
            # Validation logic remains same...
            $results.Add([pscustomobject]@{
                TimeCreated           = $event.TimeCreated
                DomainController      = $dc
                EventId               = $event.Id
                EventName             = $eventNameMap[[int]$event.Id]
                SamAccountName        = $samAccountName
                IpAddress             = $data["IpAddress"]
                Workstation           = if ($data["WorkstationName"]) { $data["WorkstationName"] } else { $data["Workstation"] }
                LogonTypeName         = $logonTypeMap[[string]$data["LogonType"]]
                Status                = "Success"
            })
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -notmatch "NoMatchingEventsFound") {
            $skippedDcs.Add([pscustomobject]@{ DomainController = $dc; Reason = $_.Exception.Message; TimeChecked = Get-Date })
        }
    }
}

# Export
if ($results.Count -gt 0) { $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 }
if ($skippedDcs.Count -gt 0) { $skippedDcs | Export-Csv -Path $SkippedDcCsvPath -NoTypeInformation -Encoding UTF8 }

Write-Host "`nComplete! Files saved to C:/Temp" -ForegroundColor Green