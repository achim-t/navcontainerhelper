﻿<# 
 .Synopsis
  Export objects from a Nav container
 .Description
  Creates a session to the Nav container and launch the Export-NavApplicationObjects Cmdlet to export object
 .Parameter containerName
  Name of the container for which you want to enter a session
 .Parameter objectsFolder
  The folder to which the objects are exported (needs to be shared with the container)
 .Parameter sqlCredential
  Credentials for the SQL admin user if using NavUserPassword authentication. User will be prompted if not provided
 .Parameter filter
  Specifies which objects to export (default is modified=Yes)
 .Parameter exportToNewSyntax
  Specifies whether or not to export objects in new syntax (default is true)
 .Example
  Export-NavContainerObject -containerName test -objectsFolder c:\programdata\navcontainerhelper\objects
 .Example
  Export-NavContainerObject -containerName test -objectsFolder c:\programdata\navcontainerhelper\objects -sqlCredential (get-credential -credential 'sa') -filter ""
#>
function Export-NavContainerObjects {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$containerName, 
        [Parameter(Mandatory=$true)]
        [string]$objectsFolder, 
        [string]$filter = "modified=Yes", 
        [System.Management.Automation.PSCredential]$sqlCredential = $null,
        [ValidateSet('txt folder','txt folder (new syntax)','txt file','txt file (new syntax)','fob file')]
        [string]$exportTo = 'txt folder (new syntax)',
        [Obsolete("exportToNewSyntax is obsolete, please use exportTo instead")]
        [switch]$exportToNewSyntax = $true
    )

    if (!$exportToNewSyntax) {
        $exportTo = 'txt folder'
    }

    $sqlCredential = Get-DefaultSqlCredential -containerName $containerName -sqlCredential $sqlCredential
    $containerObjectsFolder = Get-NavContainerPath -containerName $containerName -path $objectsFolder -throw
    $session = Get-NavContainerSession -containerName $containerName
    Invoke-Command -Session $session -ScriptBlock { Param($filter, $objectsFolder, $sqlCredential, $exportTo)

        if ($exportTo -eq 'fob file') {
            $objectsFile = "$objectsFolder.fob"
        } else {
            $objectsFile = "$objectsFolder.txt"
        }
        New-Item -Path $objectsFolder -ItemType Directory -Force -ErrorAction Ignore | Out-Null
        Remove-Item -Path $objectsFile -Force -ErrorAction Ignore
        Remove-Item -Path $objectsFolder -Force -Recurse -ErrorAction Ignore

        $filterStr = ""
        if ($filter) {
            $filterStr = " with filter '$filter'"
        }
        if ($exportTo.Contains('(new syntax)')) {
            Write-Host "Export Objects$filterStr (new syntax) to $objectsFile"
        } else {
            Write-Host "Export Objects$filterStr to $objectsFile"
        }

        $customConfigFile = Join-Path (Get-Item "C:\Program Files\Microsoft Dynamics NAV\*\Service").FullName "CustomSettings.config"
        [xml]$customConfig = [System.IO.File]::ReadAllText($customConfigFile)
        $databaseServer = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseServer']").Value
        $databaseInstance = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseInstance']").Value
        $databaseName = $customConfig.SelectSingleNode("//appSettings/add[@key='DatabaseName']").Value
        if ($databaseInstance) { $databaseServer += "\$databaseInstance" }

        $params = @{}
        if ($sqlCredential) {
            $params = @{ 'Username' = $sqlCredential.UserName; 'Password' = ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlCredential.Password))) }
        }
        if ($exportTo.Contains('(new syntax)')) {
            $params += @{ 'ExportToNewSyntax' = $true }
        }

        Export-NAVApplicationObject @params -DatabaseName $databaseName `
                                    -Path $objectsFile `
                                    -DatabaseServer $databaseServer `
                                    -Force `
                                    -Filter "$filter" | Out-Null

        if ($exportTo.Contains("folder")) {
            Write-Host "Split $objectsFile to $objectsFolder"
            New-Item -Path $objectsFolder -ItemType Directory -Force -ErrorAction Ignore | Out-Null
            Split-NAVApplicationObjectFile -Source $objectsFile `
                                           -Destination $objectsFolder
            Remove-Item -Path $objectsFile -Force -ErrorAction Ignore
        }
    
    }  -ArgumentList $filter, $containerObjectsFolder, $sqlCredential, $exportTo
}
Export-ModuleMember -function Export-NavContainerObjects
