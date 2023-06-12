#Load SharePoint CSOM Assemblies
Add-Type -Path "C:\Program Files\Common Files\Microsoft Shared\Web Server Extensions\16\ISAPI\Microsoft.SharePoint.Client.dll"
Add-Type -Path "C:\Program Files\Common Files\Microsoft Shared\Web Server Extensions\16\ISAPI\Microsoft.SharePoint.Client.Runtime.dll"
 
#Function to migrate all Files and Folders from FileShare to SharePoint Online
Function Migrate-FileShareToSPO()
{ 
    param
    (
        [Parameter(Mandatory=$true)] [string] $SiteURL,
        [Parameter(Mandatory=$true)] [string] $TargetLibraryName,
        [Parameter(Mandatory=$true)] [string] $SourceFolderPath
    )
 
    #Setup Credentials to connect
	$credPath = 'Path to Creds'  
	$fileCred = Import-Clixml -path $credpath  
	$Cred = New-Object Microsoft.SharePoint.Client.SharePointOnlineCredentials($fileCred.UserName, $fileCred.Password)
  
    #Setup the context
    $Ctx = New-Object Microsoft.SharePoint.Client.ClientContext($SiteURL)
    $Ctx.Credentials = $Credentials
       
    #Get the Target Folder to Upload
    $Web = $Ctx.Web
    $Ctx.Load($Web)
    $List = $Web.Lists.GetByTitle($TargetLibraryName)
    $Ctx.Load($List)
    $TargetFolder = $List.RootFolder
    $Ctx.Load($TargetFolder)
    $Ctx.ExecuteQuery() 
 
    #Get All Files and Folders from the Source
    Get-ChildItem $SourceFolderPath -Recurse | ForEach-Object {
        If ($_.PSIsContainer -eq $True) #If its a Folder!
        {
            $TargetFolderRelativeURL = $TargetFolder.ServerRelativeURL+$_.FullName.Replace($SourceFolderPath,[string]::Empty).Replace("\","/")
            Write-host -f Yellow "Ensuring Folder '$TargetFolderRelativeURL' Exists..."
                     
            #Check Folder Exists
            Try {
                #Get Source Folder's metadata
                $CreatedDate= [DateTime]$_.CreationTime
                $ModifiedDate =  [DateTime]$_.LastWriteTime
 
                $Folder = $Web.GetFolderByServerRelativeUrl($TargetFolderRelativeURL)
                $Ctx.Load($Folder)
                $Ctx.ExecuteQuery()
  
                #Write-host -f Green "Folder Already Exists!"
            }
            Catch {
                #Create New Sub-Folder
                $Folder=$Web.Folders.Add($TargetFolderRelativeURL)
                $Ctx.ExecuteQuery()
                Write-host -f Green "Created Folder at "$TargetFolderRelativeURL
 
                #Set Metadata of the Folder
                $FolderProperties = $Folder.ListItemAllFields
                $FolderProperties["Created"] = $CreatedDate
                $FolderProperties["Modified"] = $ModifiedDate
                $FolderProperties.Update()
                $Ctx.ExecuteQuery()
            }
        }
        Else #If its a File
        {
            $TargetFileURL = $TargetFolder.ServerRelativeURL + $_.DirectoryName.Replace($SourceFolderPath,[string]::Empty).Replace("\","/") +"/"+$_.Name          
            $SourceFilePath = $_.FullName
 
            Write-host -f Yellow "Uploading File '$_' to URL "$TargetFileURL
            #Get the file from disk
            $FileStream = ([System.IO.FileInfo] (Get-Item $SourceFilePath)).OpenRead()
    
            #Upload the File to SharePoint Library's Folder
            $FileCreationInfo = New-Object Microsoft.SharePoint.Client.FileCreationInformation
            $FileCreationInfo.Overwrite = $true
            $FileCreationInfo.ContentStream = $FileStream
            $FileCreationInfo.URL = $TargetFileURL
            $FileUploaded = $TargetFolder.Files.Add($FileCreationInfo)
   
            $Ctx.ExecuteQuery()  
            #Close file stream
            $FileStream.Close()
 
            #Update Metadata of the File
            $FileProperties = $FileUploaded.ListItemAllFields
            $FileProperties["Created"] = [datetime]$_.CreationTime 
            $FileProperties["Modified"] =[datetime]$_.LastWriteTime
            $FileProperties.Update()
            $Ctx.ExecuteQuery()
            Write-host "File '$TargetFileURL' Uploaded Successfully!" -ForegroundColor Green
        }
    }
}
 
#Set parameter values
$SiteURL="sharepoint site"
$TargetLibraryName="Document Library"
$SourceFolderPath="Source Path"
  
#Call the function to Upload All files & folders from network Fileshare to SharePoint Online
Migrate-FileShareToSPO -SiteURL $SiteURL -SourceFolderPath $SourceFolderPath -TargetLibraryName $TargetLibraryName
