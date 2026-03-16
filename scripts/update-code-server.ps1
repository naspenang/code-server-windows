[CmdletBinding()]
param(
  [string]$Password,
  [int]$Port,
  [string]$NodeVersion,
  [string]$CodeServerVersion,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)

  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RepoRoot {
  Split-Path -Parent $PSScriptRoot
}

function Get-ConfigLineValue {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $match = Select-String -Path $Path -Pattern ("^\s*{0}:\s*(.*)$" -f [Regex]::Escape($Key)) | Select-Object -First 1
  if (-not $match) {
    return $null
  }

  $match.Matches[0].Groups[1].Value.Trim()
}

function Get-ConfiguredPort {
  param([Parameter(Mandatory)][string]$ConfigPath)

  $bindAddress = Get-ConfigLineValue -Path $ConfigPath -Key "bind-addr"
  if ([string]::IsNullOrWhiteSpace($bindAddress)) {
    return $null
  }

  $portText = ($bindAddress -split ":")[-1]
  $port = 0
  if ([int]::TryParse($portText, [ref]$port)) {
    return $port
  }

  $null
}

function Get-ConfiguredPassword {
  param([Parameter(Mandatory)][string]$ConfigPath)

  $password = Get-ConfigLineValue -Path $ConfigPath -Key "password"
  if ([string]::IsNullOrWhiteSpace($password)) {
    return $null
  }

  $password
}

function Get-NodeVersionFromStartBat {
  param([Parameter(Mandatory)][string]$StartBatPath)

  if (-not (Test-Path -LiteralPath $StartBatPath)) {
    return $null
  }

  $match = Select-String -Path $StartBatPath -Pattern "node-v([0-9.]+)-win-x64\\node\.exe" | Select-Object -First 1
  if (-not $match) {
    return $null
  }

  $match.Matches[0].Groups[1].Value
}

function Get-InstalledCodeServerVersion {
  param([Parameter(Mandatory)][string]$PackageJsonPath)

  if (-not (Test-Path -LiteralPath $PackageJsonPath)) {
    return $null
  }

  (
    Get-Content -LiteralPath $PackageJsonPath -Raw |
    ConvertFrom-Json
  ).version
}

function Get-NpmCmd {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ResolvedNodeVersion
  )

  $repoLocalNpm = Join-Path $RepoRoot ("node22\node-v{0}-win-x64\npm.cmd" -f $ResolvedNodeVersion)
  if (Test-Path -LiteralPath $repoLocalNpm) {
    return $repoLocalNpm
  }

  $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($npmCommand) {
    return $npmCommand.Source
  }

  throw "Unable to locate npm.cmd. Run the installer once first or provide a repo-local Node runtime."
}

function Get-LatestCodeServerVersion {
  param([Parameter(Mandatory)][string]$NpmCmd)

  $latest = & $NpmCmd view code-server version
  if ($LASTEXITCODE -ne 0) {
    throw "npm view code-server version failed."
  }

  $latest = "$latest".Trim()
  if ([string]::IsNullOrWhiteSpace($latest)) {
    throw "npm did not return a code-server version."
  }

  $latest
}

function Remove-ExistingRuntime {
  param([Parameter(Mandatory)][string]$RuntimePath)

  if (Test-Path -LiteralPath $RuntimePath) {
    Remove-Item -LiteralPath $RuntimePath -Recurse -Force
  }
}

$repoRoot = Get-RepoRoot
$installerPath = Join-Path $repoRoot "scripts\01-install-standalone-direct-code-server.ps1"
$configPath = Join-Path $repoRoot "configs\code-server-config.yaml"
$startBatPath = Join-Path $repoRoot "start.bat"
$runtimePath = Join-Path $repoRoot "code-server-runtime"
$packageJsonPath = Join-Path $runtimePath "node_modules\code-server\package.json"

if (-not (Test-Path -LiteralPath $installerPath)) {
  throw "Installer script not found: $installerPath"
}

$resolvedPassword = if ($PSBoundParameters.ContainsKey("Password")) {
  if ([string]::IsNullOrWhiteSpace($Password)) {
    throw "Password cannot be empty."
  }

  $Password
} else {
  Get-ConfiguredPassword -ConfigPath $configPath
}

if ([string]::IsNullOrWhiteSpace($resolvedPassword)) {
  throw "Unable to determine the existing password from $configPath. Pass -Password explicitly."
}

$resolvedPort = if ($PSBoundParameters.ContainsKey("Port")) {
  $Port
} else {
  $configuredPort = Get-ConfiguredPort -ConfigPath $configPath
  if ($null -ne $configuredPort) { $configuredPort } else { 8080 }
}

$resolvedNodeVersion = if ($PSBoundParameters.ContainsKey("NodeVersion")) {
  $NodeVersion
} else {
  $detectedNodeVersion = Get-NodeVersionFromStartBat -StartBatPath $startBatPath
  if ([string]::IsNullOrWhiteSpace($detectedNodeVersion)) { "22.22.1" } else { $detectedNodeVersion }
}

$installedVersion = Get-InstalledCodeServerVersion -PackageJsonPath $packageJsonPath
$npmCmd = Get-NpmCmd -RepoRoot $repoRoot -ResolvedNodeVersion $resolvedNodeVersion
$targetVersion = if ($PSBoundParameters.ContainsKey("CodeServerVersion")) {
  $CodeServerVersion
} else {
  Get-LatestCodeServerVersion -NpmCmd $npmCmd
}

Write-Step "Checking code-server versions"
Write-Host ("Installed version: {0}" -f $(if ($installedVersion) { $installedVersion } else { "not installed" }))
Write-Host "Target version: $targetVersion"

if (-not $Force -and $installedVersion -and $installedVersion -eq $targetVersion) {
  Write-Host ""
  Write-Host "code-server is already up to date. Use -Force to reinstall the same version."
  exit 0
}

Write-Step "Refreshing the repo-local runtime"
Remove-ExistingRuntime -RuntimePath $runtimePath

Write-Step "Running the standalone installer"
& $installerPath `
  -Password $resolvedPassword `
  -Port $resolvedPort `
  -NodeVersion $resolvedNodeVersion `
  -CodeServerVersion $targetVersion

Write-Host ""
Write-Host "Update complete."
Write-Host "Start code-server with:"
Write-Host ("  {0}" -f (Join-Path $repoRoot "start.bat"))
