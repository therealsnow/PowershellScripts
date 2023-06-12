##Run as admin to generate cred file
$credentials = Get-Credential                                                                     
$filename = 'D:\Arvind\safe\secretfile.txt'  
$credentials | Export-Clixml -path $filename  
