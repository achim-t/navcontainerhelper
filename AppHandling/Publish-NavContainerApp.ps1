<# 
 .Synopsis
  Publish App to a NAV/BC Container
 .Description
  Copies the appFile to the container if necessary
  Creates a session to the container and runs the CmdLet Publish-NavApp in the container
 .Parameter containerName
  Name of the container in which you want to publish an app
 .Parameter appFile
  Path of the app you want to publish  
 .Parameter skipVerification
  Include this parameter if the app you want to publish is not signed
 .Parameter ignoreIfAppExists
  Include this parameter if you want to ignore the error if the app already is published/installed
 .Parameter sync
  Include this parameter if you want to synchronize the app after publishing
 .Parameter syncMode
  Specify Add, Clean or Development based on how you want to synchronize the database schema. Default is Add
 .Parameter install
  Include this parameter if you want to install the app after publishing
 .Parameter upgrade
  Include this parameter if you want to upgrade the app after publishing. if no upgrade is necessary then its just installed instead.
 .Parameter tenant
  If you specify the install switch, then you can specify the tenant in which you want to install the app
 .Parameter packageType
  Specify Extension or SymbolsOnly based on which package you want to publish
 .Parameter scope
  Specify Global or Tenant based on how you want to publish the package. Default is Global
 .Parameter useDevEndpoint
  Specify the useDevEndpoint switch if you want to publish using the Dev Endpoint (like VS Code). This allows VS Code to re-publish.
 .Parameter credential
  Specify the credentials for the admin user if you use DevEndpoint and authentication is set to UserPassword
 .Parameter language
  Specify language version that is used for installing the app. The value must be a valid culture name for a language in Business Central, such as en-US or da-DK. If the specified language does not exist on the Business Central Server instance, then en-US is used.
 .Parameter replaceDependencies
  With this parameter, you can specify a hashtable, describring that the specified dependencies in the apps being published should be replaced
 .Parameter internalsVisibleTo
  An Array of hashtable, containing id, name and publisher of an app, which should be added to internals Visible to
 .Parameter showMyCode
  With this parameter you can change or check ShowMyCode in the app file. Check will throw an error if ShowMyCode is False.
 .Parameter PublisherAzureActiveDirectoryTenantId
  AAD Tenant of the publisher to ensure access to keyvault (unless publisher check is disables in server config)
 .Parameter bcAuthContext
  Authorization Context created by New-BcAuthContext. By specifying BcAuthContext and environment, the function will publish the app to the online Business Central Environment specified
 .Parameter environment
  Environment to use for publishing
 .Example
  Publish-BcContainerApp -appFile c:\temp\myapp.app
 .Example
  Publish-BcContainerApp -containerName test2 -appFile c:\temp\myapp.app -skipVerification
 .Example
  Publish-BcContainerApp -containerName test2 -appFile c:\temp\myapp.app -install -sync
 .Example
  Publish-BcContainerApp -containerName test2 -appFile c:\temp\myapp.app -skipVerification -install -sync -tenant mytenant
 .Example
  Publish-BcContainerApp -containerName test2 -appFile c:\temp\myapp.app -install -sync -replaceDependencies @{ "437dbf0e-84ff-417a-965d-ed2bb9650972" = @{ "id" = "88b7902e-1655-4e7b-812e-ee9f0667b01b"; "name" = "MyBaseApp"; "publisher" = "Freddy Kristiansen"; "minversion" = "1.0.0.0" }}
#>
function Publish-BcContainerApp {
    Param (
        [string] $containerName = "",
        [Parameter(Mandatory=$true)]
        $appFile,
        [switch] $skipVerification,
        [switch] $ignoreIfAppExists,
        [switch] $sync,
        [Parameter(Mandatory=$false)]
        [ValidateSet('Add','Clean','Development','ForceSync')]
        [string] $syncMode,
        [switch] $install,
        [switch] $upgrade,
        [Parameter(Mandatory=$false)]
        [string] $tenant = "default",
        [ValidateSet('Extension','SymbolsOnly')]
        [string] $packageType = 'Extension',
        [Parameter(Mandatory=$false)]
        [ValidateSet('Global','Tenant')]
        [string] $scope,
        [switch] $useDevEndpoint,
        [pscredential] $credential,
        [string] $language = "",
        [hashtable] $replaceDependencies = $null,
        [hashtable[]] $internalsVisibleTo = $null,
        [ValidateSet('Ignore','True','False','Check')]
        [string] $ShowMyCode = "Ignore",
        [switch] $replacePackageId,
        [string] $PublisherAzureActiveDirectoryTenantId,
        [Hashtable] $bcAuthContext,
        [string] $environment
    )

$telemetryScope = InitTelemetryScope -name $MyInvocation.InvocationName -parameterValues $PSBoundParameters -includeParameters @()
try {

    Add-Type -AssemblyName System.Net.Http

    if ($containerName -eq "" -and (!($bcAuthContext -and $environment))) {
        $containerName = $bcContainerHelperConfig.defaultContainerName
    }

    if ($containerName) {
        $customconfig = Get-BcContainerServerConfiguration -ContainerName $containerName
        $appFolder = Join-Path $extensionsFolder "$containerName\$([guid]::NewGuid().ToString())"
        if ($appFile -is [string] -and $appFile.Startswith(':')) {
            New-Item $appFolder -ItemType Directory | Out-Null
            $destFile = Join-Path $appFolder ([System.IO.Path]::GetFileName($appFile.SubString(1)))
            Invoke-ScriptInBcContainer -containerName $containerName -scriptblock { Param($appFile, $destFile)
                Copy-Item -Path $appFile -Destination $destFile -Force
            } -argumentList (Get-BcContainerPath -containerName $containerName -path $appFile), (Get-BcContainerPath -containerName $containerName -path $destFile) | Out-Null
            $appFiles = @($destFile)
        }
        else {
            $appFiles = CopyAppFilesToFolder -appFiles $appFile -folder $appFolder
        }
        $navversion = Get-BcContainerNavversion -containerOrImageName $containerName
        $version = [System.Version]($navversion.split('-')[0])
        $force = ($version.Major -ge 14)
    }
    else {
        $appFolder = Join-Path (Get-TempDir) ([guid]::NewGuid().ToString())
        $appFiles = CopyAppFilesToFolder -appFiles $appFile -folder $appFolder
        $force = $true
    }

    try {
        if ($appFolder) {
            $appFiles = @(Sort-AppFilesByDependencies -containerName $containerName -appFiles $appFiles -WarningAction SilentlyContinue)
        }
        $appFiles | Where-Object { $_ } | ForEach-Object {

            $appFile = $_

            if ($ShowMyCode -ne "Ignore" -or $replaceDependencies -or $replacePackageId -or $internalsVisibleTo) {
                Write-Host "Checking dependencies in $appFile"
                Replace-DependenciesInAppFile -containerName $containerName -Path $appFile -replaceDependencies $replaceDependencies -internalsVisibleTo $internalsVisibleTo -ShowMyCode $ShowMyCode -replacePackageId:$replacePackageId
            }
        
            if ($bcAuthContext -and $environment) {
                $useDevEndpoint = $true
            }
            elseif ($customconfig.ServerInstance -eq "") {
                throw "You cannot publish an app to a filesOnly container. Specify bcAuthContext and environemnt to publish to an online tenant"
            }
        
            if ($useDevEndpoint) {
        
                if ($scope -eq "Global") {
                    throw "You cannot publish to global scope using the dev. endpoint"
                }
        
                $sslVerificationDisabled = $false
                if ($bcAuthContext -and $environment) {
                    $bcAuthContext = Renew-BcAuthContext -bcAuthContext $bcAuthContext
                    $devServerUrl = "$($bcContainerHelperConfig.apiBaseUrl.TrimEnd('/'))/v2.0/$environment"
                    $tenant = ""
        
                    $handler = New-Object System.Net.Http.HttpClientHandler
                    $HttpClient = [System.Net.Http.HttpClient]::new($handler)
                    $HttpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $bcAuthContext.AccessToken)
                    $HttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
                    $HttpClient.DefaultRequestHeaders.ExpectContinue = $false
                }
                else {
                    $handler = New-Object System.Net.Http.HttpClientHandler
                    if ($customConfig.ClientServicesCredentialType -eq "Windows") {
                        $handler.UseDefaultCredentials = $true
                    }
                    $HttpClient = [System.Net.Http.HttpClient]::new($handler)
                    if ($customConfig.ClientServicesCredentialType -eq "NavUserPassword") {
                        if (!($credential)) {
                            throw "You need to specify credentials when you are not using Windows Authentication"
                        }
                        $pair = ("$($Credential.UserName):"+[System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)))
                        $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
                        $base64 = [System.Convert]::ToBase64String($bytes)
                        $HttpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $base64);
                    }
                    $HttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
                    $HttpClient.DefaultRequestHeaders.ExpectContinue = $false
                    
                    if ($customConfig.DeveloperServicesSSLEnabled -eq "true") {
                        $protocol = "https://"
                    }
                    else {
                        $protocol = "http://"
                    }
                
                    $ip = Get-BcContainerIpAddress -containerName $containerName
                    if ($ip) {
                        $devServerUrl = "$($protocol)$($ip):$($customConfig.DeveloperServicesPort)/$($customConfig.ServerInstance)"
                    }
                    else {
                        $devServerUrl = "$($protocol)$($containerName):$($customConfig.DeveloperServicesPort)/$($customConfig.ServerInstance)"
                    }
                
                    $sslVerificationDisabled = ($protocol -eq "https://")
                    if ($sslVerificationDisabled) {
                        if (-not ([System.Management.Automation.PSTypeName]"SslVerification").Type)
                        {
                            Add-Type -TypeDefinition "
                                using System.Net.Security;
                                using System.Security.Cryptography.X509Certificates;
                                public static class SslVerification
                                {
                                    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; }
                                    public static void Disable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
                                    public static void Enable()  { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; }
                                }"
                        }
                        Write-Host "Disabling SSL Verification"
                        [SslVerification]::Disable()
                    }
                }
                
                $schemaUpdateMode = "synchronize"
                if ($syncMode -eq "Clean") {
                    $schemaUpdateMode = "recreate";
                }
                elseif ($syncMode -eq "ForceSync") {
                    $schemaUpdateMode = "forcesync"
                }
                $url = "$devServerUrl/dev/apps?SchemaUpdateMode=$schemaUpdateMode"
                if ($tenant) {
                    $url += "&tenant=$tenant"
                }
                
                $appName = [System.IO.Path]::GetFileName($appFile)
                
                $multipartContent = [System.Net.Http.MultipartFormDataContent]::new()
                $FileStream = [System.IO.FileStream]::new($appFile, [System.IO.FileMode]::Open)
                try {
                    $fileHeader = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new("form-data")
                    $fileHeader.Name = "$AppName"
                    $fileHeader.FileName = "$appName"
                    $fileHeader.FileNameStar = "$appName"
                    $fileContent = [System.Net.Http.StreamContent]::new($FileStream)
                    $fileContent.Headers.ContentDisposition = $fileHeader
                    $multipartContent.Add($fileContent)
                    Write-Host "Publishing $appName to $url"
                    $result = $HttpClient.PostAsync($url, $multipartContent).GetAwaiter().GetResult()
                    if (!$result.IsSuccessStatusCode) {
                        $message = "Status Code $($result.StatusCode) : $($result.ReasonPhrase)"
                        try {
                            $resultMsg = $result.Content.ReadAsStringAsync().Result
                            try {
                                $json = $resultMsg | ConvertFrom-Json
                                $message += "`n$($json.Message)"
                            }
                            catch {
                                $message += "`n$resultMsg"
                            }
                        }
                        catch {}
                        throw $message
                    }
                }
                finally {
                    $FileStream.Close()
                }
            
                if ($sslverificationdisabled) {
                    Write-Host "Re-enablssing SSL Verification"
                    [SslVerification]::Enable()
                }
        
            }
            else {
        
                Invoke-ScriptInBcContainer -containerName $containerName -ScriptBlock { Param($appFile, $skipVerification, $sync, $install, $upgrade, $tenant, $syncMode, $packageType, $scope, $language, $PublisherAzureActiveDirectoryTenantId, $force, $ignoreIfAppExists)
        
                    $publishArgs = @{ "packageType" = $packageType }
                    if ($scope) {
                        $publishArgs += @{ "Scope" = $scope }
                        if ($scope -eq "Tenant") {
                            $publishArgs += @{ "Tenant" = $tenant }
                        }
                    }
                    if ($PublisherAzureActiveDirectoryTenantId) {
                        $publishArgs += @{ "PublisherAzureActiveDirectoryTenantId" = $PublisherAzureActiveDirectoryTenantId }
                    }
                    if ($force) {
                        $publishArgs += @{ "Force" = $true }
                    }
                    
                    $publishIt = $true
                    if ($ignoreIfAppExists) {
                        $navAppInfo = Get-NAVAppInfo -Path $appFile
                        $addArg = @{
                            "tenantSpecificProperties" = $true
                            "tenant" = $tenant
                        }
                        if ($packageType -eq "SymbolsOnly") {
                            $addArg = @{ "SymbolsOnly" = $true }
                        }
                        $appInfo = (Get-NAVAppInfo -ServerInstance $serverInstance -Name $navAppInfo.Name -Publisher $navAppInfo.Publisher -Version $navAppInfo.Version @addArg)
                        if ($appInfo) {
                            $publishIt = $false
                            Write-Host "$($navAppInfo.Name) is already published"
                            if ($appInfo.IsInstalled) {
                                $install = $false
                                Write-Host "$($navAppInfo.Name) is already installed"
                            }
                        }
                    }
            
                    if ($publishIt) {
                        Write-Host "Publishing $appFile"
                        Publish-NavApp -ServerInstance $ServerInstance -Path $appFile -SkipVerification:$SkipVerification @publishArgs
                    }
        
                    if ($sync -or $install -or $upgrade) {
        
                        $navAppInfo = Get-NAVAppInfo -Path $appFile
                        $appPublisher = $navAppInfo.Publisher
                        $appName = $navAppInfo.Name
                        $appVersion = $navAppInfo.Version
        
                        $syncArgs = @{}
                        if ($syncMode) {
                            $syncArgs += @{ "Mode" = $syncMode }
                        }
            
                        if ($sync) {
                            Write-Host "Synchronizing $appName on tenant $tenant"
                            Sync-NavTenant -ServerInstance $ServerInstance -Tenant $tenant -Force
                            Sync-NavApp -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @syncArgs -force -WarningAction Ignore
                        }

                        if($upgrade -and $install){
                            $navAppInfoFromDb = Get-NAVAppInfo -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant -TenantSpecificProperties
                            if($navAppInfoFromDb.ExtensionDataVersion -eq  $navAppInfoFromDb.Version){
                                $upgrade = $false
                            } else {
                                $install = $false
                            }
                        }
                        
                        if ($install) {
        
                            $languageArgs = @{}
                            if ($language) {
                                $languageArgs += @{ "Language" = $language }
                            }
                            Write-Host "Installing $appName on tenant $tenant"
                            Install-NavApp -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @languageArgs
                        }
        
                        if ($upgrade) {
        
                            $languageArgs = @{}
                            if ($language) {
                                $languageArgs += @{ "Language" = $language }
                            }
                            Write-Host "Upgrading $appName on tenant $tenant"
                            Start-NavAppDataUpgrade -ServerInstance $ServerInstance -Publisher $appPublisher -Name $appName -Version $appVersion -Tenant $tenant @languageArgs
                        }
                    }
        
                } -ArgumentList (Get-BcContainerPath -containerName $containerName -path $appFile), $skipVerification, $sync, $install, $upgrade, $tenant, $syncMode, $packageType, $scope, $language, $PublisherAzureActiveDirectoryTenantId, $force, $ignoreIfAppExists
            }
            Write-Host -ForegroundColor Green "App $([System.IO.Path]::GetFileName($appFile)) successfully published"
        }
    }
    finally {
        Remove-Item $appFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    TrackException -telemetryScope $telemetryScope -errorRecord $_
    throw
}
finally {
    TrackTrace -telemetryScope $telemetryScope
}
}
Set-Alias -Name Publish-NavContainerApp -Value Publish-BcContainerApp
Export-ModuleMember -Function Publish-BcContainerApp -Alias Publish-NavContainerApp
