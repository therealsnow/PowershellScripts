# 1. Define the files to delete
$fileNames = @(
    "File1.ext"
    "File2.ext"
)

$desktopPaths = @()

# 2. Get Public Desktop paths
$desktopPaths += Join-Path $env:PUBLIC "Desktop"
$desktopPaths += Join-Path $env:PUBLIC "Public Desktop"

# 3. Get All User Desktops via Registry (Handles OneDrive/Custom paths)
$userSIDs = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" | Select-Object -ExpandProperty PSChildName

foreach ($sid in $userSIDs) {
    # Skip System/Service accounts
    if ($sid.Length -lt 15) { continue }

    $regPath = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    
    if (Test-Path $regPath) {
        $desktopRegistryValue = Get-ItemPropertyValue -Path $regPath -Name "Desktop" -ErrorAction SilentlyContinue
        
        if ($desktopRegistryValue) {
            $expandedPath = [System.Environment]::ExpandEnvironmentVariables($desktopRegistryValue)
            $desktopPaths += $expandedPath
        }
    }
}

$deletedCount = 0

# 4. Execution Logic
# Loop through each unique desktop path found
foreach ($path in ($desktopPaths | Select-Object -Unique)) {
    if (-not (Test-Path $path)) { continue }
    
    # Loop through each file name defined above
    foreach ($file in $fileNames) {
        $filePath = Join-Path $path $file
        
        if (Test-Path $filePath) {
            try {
                Remove-Item -Path $filePath -Force -ErrorAction Stop
                $deletedCount++
                Write-Host "Deleted '$file' from: $path" -ForegroundColor Green
            } catch {
                Write-Warning "Found '$file' but could not delete from $path : $($_.Exception.Message)"
            }
        }
    }
}

# 5. Exit codes
if ($deletedCount -gt 0) {
    Write-Host "Total files deleted: $deletedCount"
    exit 0
} else {
    Write-Warning "None of the specified files were found on any detected Desktop."
    exit 1
}