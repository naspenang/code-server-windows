[CmdletBinding()]
param(
  [string]$SiteName = "Default Web Site",
  [string]$ApplicationName = "dev",
  [string]$ApplicationPoolName = "code-server-dev",
  [string]$PhysicalPath = "C:\inetpub\wwwroot\dev",
  [string]$BackendUrl = "http://127.0.0.1:8080",
  [string]$ForwardedProto = "https",
  [string]$ForwardedHost = "{HTTP_HOST}",
  [switch]$SkipBackendHealthCheck
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)

  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsPowerShellExecutable {
  $defaultPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  if (Test-Path -LiteralPath $defaultPath) {
    return $defaultPath
  }

  $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  throw "Unable to locate Windows PowerShell. Run this script from Windows PowerShell 5.1 or install powershell.exe."
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Ensure-WebsiteExists {
  param([Parameter(Mandatory)][string]$Name)

  if (-not (Get-Website -Name $Name -ErrorAction SilentlyContinue)) {
    throw "IIS site '$Name' does not exist."
  }
}

function Ensure-AppPool {
  param([Parameter(Mandatory)][string]$Name)

  $appPoolPath = "IIS:\AppPools\$Name"
  if (-not (Test-Path -LiteralPath $appPoolPath)) {
    New-WebAppPool -Name $Name | Out-Null
  }

  Set-ItemProperty -LiteralPath $appPoolPath -Name managedRuntimeVersion -Value ""
  Set-ItemProperty -LiteralPath $appPoolPath -Name managedPipelineMode -Value "Integrated"
  Set-ItemProperty -LiteralPath $appPoolPath -Name autoStart -Value $true
}

function Get-ApplicationFilter {
  param(
    [Parameter(Mandatory)][string]$Site,
    [Parameter(Mandatory)][string]$Application
  )

  "system.applicationHost/sites/site[@name='{0}']/application[@path='/{1}']" -f $Site, $Application
}

function Get-VirtualDirectoryFilter {
  param(
    [Parameter(Mandatory)][string]$Site,
    [Parameter(Mandatory)][string]$Application
  )

  "{0}/virtualDirectory[@path='/']" -f (Get-ApplicationFilter -Site $Site -Application $Application)
}

function Ensure-WebApplication {
  param(
    [Parameter(Mandatory)][string]$Site,
    [Parameter(Mandatory)][string]$Application,
    [Parameter(Mandatory)][string]$AppPool,
    [Parameter(Mandatory)][string]$Path
  )

  $webApp = Get-WebApplication -Site $Site -Name $Application -ErrorAction SilentlyContinue
  if (-not $webApp) {
    New-WebApplication -Site $Site -Name $Application -PhysicalPath $Path -ApplicationPool $AppPool -Force | Out-Null
    return
  }

  $appFilter = Get-ApplicationFilter -Site $Site -Application $Application
  $vdirFilter = Get-VirtualDirectoryFilter -Site $Site -Application $Application

  Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $appFilter -Name applicationPool -Value $AppPool
  Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $vdirFilter -Name physicalPath -Value $Path
}

function Ensure-ArrProxyEnabled {
  $proxy = Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/proxy" -Name "." -ErrorAction SilentlyContinue
  if ($null -eq $proxy) {
    throw "ARR proxy settings are not available. Install IIS Application Request Routing first."
  }

  Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/proxy" -Name enabled -Value $true
  Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/proxy" -Name preserveHostHeader -Value $true
  Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/proxy" -Name reverseRewriteHostInResponseHeaders -Value $false
}

function Ensure-AllowedServerVariable {
  param([Parameter(Mandatory)][string]$Name)

  try {
    $existing = @(Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/rewrite/allowedServerVariables/add" -Name "." -ErrorAction Stop)
  } catch {
    throw "URL Rewrite is not available. Install IIS URL Rewrite first."
  }

  if ($existing | Where-Object { $_.name -eq $Name }) {
    return
  }

  Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter "system.webServer/rewrite/allowedServerVariables" -Name "." -Value @{ name = $Name }
}

function Enable-ApplicationWebSockets {
  param(
    [Parameter(Mandatory)][string]$Site,
    [Parameter(Mandatory)][string]$Application
  )

  try {
    Set-WebConfigurationProperty `
      -PSPath "MACHINE/WEBROOT/APPHOST" `
      -Location "$Site/$Application" `
      -Filter "system.webServer/webSocket" `
      -Name enabled `
      -Value $true
  } catch {
    Write-Warning "Unable to set the IIS WebSocket flag for $Site/$Application. Verify the IIS WebSocket Protocol feature is enabled."
  }
}

function Write-ApplicationWebConfig {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Application,
    [Parameter(Mandatory)][string]$TargetUrl,
    [Parameter(Mandatory)][string]$Proto,
    [Parameter(Mandatory)][string]$HostHeader
  )

  $applicationBasePath = "/$Application"
  $backendBaseUrl = $TargetUrl.TrimEnd("/")

  @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <clear />
        <rule name="code-server-$Application-add-trailing-slash" stopProcessing="true">
          <match url="^$" />
          <conditions>
            <add input="{REQUEST_URI}" pattern="^$applicationBasePath$" />
          </conditions>
          <action type="Redirect" url="$applicationBasePath/" redirectType="Found" />
        </rule>
        <rule name="code-server-$Application-reverse-proxy" stopProcessing="true">
          <match url="(.*)" />
          <serverVariables>
            <set name="HTTP_X_FORWARDED_PROTO" value="$Proto" />
            <set name="HTTP_X_FORWARDED_HOST" value="$HostHeader" />
            <set name="HTTP_X_FORWARDED_FOR" value="{REMOTE_ADDR}" />
            <set name="HTTP_X_FORWARDED_PREFIX" value="$applicationBasePath" />
            <set name="HTTP_SEC_WEBSOCKET_EXTENSIONS" value="" />
          </serverVariables>
          <action type="Rewrite" url="$backendBaseUrl/{R:1}" appendQueryString="true" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
"@ | Set-Content -LiteralPath (Join-Path $Path "web.config") -Encoding ascii
}

function Test-BackendHealth {
  param([Parameter(Mandatory)][string]$Url)

  try {
    $response = Invoke-WebRequest -Uri ("{0}/healthz" -f $Url.TrimEnd("/")) -Method Get -TimeoutSec 10 -UseBasicParsing
    return ($response.StatusCode -eq 200)
  } catch {
    return $false
  }
}

if (-not (Test-IsAdministrator)) {
  throw "Run this script from an elevated PowerShell session. Open PowerShell with 'Run as administrator', go to the repo root, and rerun .\scripts\02-create-iis-dev-reverse-proxy.ps1."
}

if ($PSVersionTable.PSEdition -ne "Desktop") {
  $windowsPowerShell = Get-WindowsPowerShellExecutable
  $argumentList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $PSCommandPath
  )

  foreach ($parameter in $PSBoundParameters.GetEnumerator()) {
    if ($parameter.Value -is [switch]) {
      if ($parameter.Value.IsPresent) {
        $argumentList += "-$($parameter.Key)"
      }
      continue
    }

    if ($parameter.Value -is [bool]) {
      if ($parameter.Value) {
        $argumentList += "-$($parameter.Key)"
      }
      continue
    }

    $argumentList += "-$($parameter.Key)"
    $argumentList += [string]$parameter.Value
  }

  Write-Host "Switching to Windows PowerShell for IIS administration..." -ForegroundColor Yellow
  & $windowsPowerShell @argumentList
  exit $LASTEXITCODE
}

Import-Module WebAdministration

$applicationPath = "/$ApplicationName"

Write-Step "Validating IIS prerequisites"
Ensure-WebsiteExists -Name $SiteName

Write-Step "Ensuring ARR proxy mode and rewrite server variables"
Ensure-ArrProxyEnabled
foreach ($serverVariable in @(
  "HTTP_X_FORWARDED_PROTO",
  "HTTP_X_FORWARDED_HOST",
  "HTTP_X_FORWARDED_FOR",
  "HTTP_X_FORWARDED_PREFIX",
  "HTTP_SEC_WEBSOCKET_EXTENSIONS"
)) {
  Ensure-AllowedServerVariable -Name $serverVariable
}

Write-Step "Creating the physical application folder"
Ensure-Directory -Path $PhysicalPath

Write-Step "Creating the IIS application pool"
Ensure-AppPool -Name $ApplicationPoolName

Write-Step "Creating the IIS application"
Ensure-WebApplication -Site $SiteName -Application $ApplicationName -AppPool $ApplicationPoolName -Path $PhysicalPath
Enable-ApplicationWebSockets -Site $SiteName -Application $ApplicationName

Write-Step "Writing the application-scoped reverse proxy rules"
Write-ApplicationWebConfig `
  -Path $PhysicalPath `
  -Application $ApplicationName `
  -TargetUrl $BackendUrl `
  -Proto $ForwardedProto `
  -HostHeader $ForwardedHost

Write-Step "Restarting the application pool"
Restart-WebAppPool -Name $ApplicationPoolName

if (-not $SkipBackendHealthCheck) {
  Write-Step "Checking the code-server backend health"
  if (-not (Test-BackendHealth -Url $BackendUrl)) {
    Write-Warning "The backend at $BackendUrl did not answer with HTTP 200 on /healthz. Start code-server before testing the IIS proxy."
  }
}

Write-Step "IIS reverse proxy setup complete"
Write-Host "Site: $SiteName"
Write-Host "Application: $applicationPath"
Write-Host "Application pool: $ApplicationPoolName"
Write-Host "Physical path: $PhysicalPath"
Write-Host "Backend: $BackendUrl"
Write-Host "App web.config: $(Join-Path $PhysicalPath 'web.config')"
Write-Host ""
Write-Host "Next checks:" -ForegroundColor Green
Write-Host "  1. Start code-server if it is not already running."
Write-Host "  2. Open https://localhost$applicationPath/healthz"
Write-Host "  3. Open https://localhost$applicationPath"
