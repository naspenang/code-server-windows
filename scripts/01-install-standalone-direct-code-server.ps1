[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Password,

  [Parameter(Position = 1)]
  [int]$Port = 8080,

  [Parameter(Position = 2)]
  [string]$NodeVersion = "22.22.1",

  [Parameter(Position = 3)]
  [string]$CodeServerVersion
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)

  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Convert-SecureStringToPlainText {
  param([Parameter(Mandatory)][SecureString]$Value)

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Read-ConfirmedPassword {
  while ($true) {
    $first = Read-Host "Enter a password for code-server" -AsSecureString
    $second = Read-Host "Confirm the password" -AsSecureString

    $firstPlain = Convert-SecureStringToPlainText -Value $first
    $secondPlain = Convert-SecureStringToPlainText -Value $second

    if ([string]::IsNullOrWhiteSpace($firstPlain)) {
      Write-Warning "Password cannot be empty."
      continue
    }

    if ($firstPlain -cne $secondPlain) {
      Write-Warning "Passwords did not match. Try again."
      continue
    }

    return $firstPlain
  }
}

function Resolve-CodeServerPassword {
  param(
    [string]$ProvidedPassword,
    [Parameter(Mandatory)][bool]$WasProvided
  )

  if ($WasProvided) {
    if ([string]::IsNullOrWhiteSpace($ProvidedPassword)) {
      throw "Password cannot be empty."
    }

    return $ProvidedPassword
  }

  Read-ConfirmedPassword
}

function Get-RepoRoot {
  Split-Path -Parent $PSScriptRoot
}

function Get-ForwardSlashPath {
  param([Parameter(Mandatory)][string]$Path)

  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $resolved -replace "\\", "/"
}

function Get-DesktopVSCodeExe {
  $codeCommand = Get-Command code -ErrorAction SilentlyContinue
  if ($codeCommand) {
    $codeExe = if ($codeCommand.Source -like "*.cmd") {
      Join-Path (Split-Path -Parent (Split-Path -Parent $codeCommand.Source)) "Code.exe"
    } else {
      $codeCommand.Source
    }

    if (Test-Path -LiteralPath $codeExe) {
      return (Resolve-Path -LiteralPath $codeExe).Path
    }
  }

  $fallbacks = @(
    "C:\Program Files\Microsoft VS Code\Code.exe",
    (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe")
  )

  foreach ($candidate in $fallbacks) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "Unable to locate desktop VS Code. Install desktop VS Code first, and make sure Code.exe is available."
}

function Get-DesktopVSCodeRuntimeDir {
  param([Parameter(Mandatory)][string]$CodeExe)

  $vscodeRoot = Split-Path -Parent $CodeExe
  $rootNodeModules = Join-Path $vscodeRoot "resources\app\node_modules"
  if (Test-Path -LiteralPath $rootNodeModules) {
    return $vscodeRoot
  }

  $runtimeDir = Get-ChildItem -Path $vscodeRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "resources\app\node_modules") } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $runtimeDir) {
    throw "Unable to find the desktop VS Code runtime directory under $vscodeRoot."
  }

  $runtimeDir.FullName
}

function Invoke-NpmCommand {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed: $FilePath $($Arguments -join ' ')"
  }
}

function Invoke-RepoLocalNpmInstall {
  param(
    [Parameter(Mandatory)][string]$NodeExe,
    [Parameter(Mandatory)][string]$NpmCli,
    [Parameter(Mandatory)][string]$WorkingDirectory
  )

  Push-Location $WorkingDirectory
  try {
    & $NodeExe $NpmCli install --ignore-scripts --omit=dev
    if ($LASTEXITCODE -ne 0) {
      throw "npm install failed in $WorkingDirectory"
    }
  } finally {
    Pop-Location
  }
}

function Copy-DesktopVSCodeNodeModules {
  param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$TargetDirectory,
    [Parameter(Mandatory)][string]$TargetAsarPath
  )

  Ensure-Directory -Path $TargetDirectory

  & robocopy $SourceDirectory $TargetDirectory /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed while copying native modules from desktop VS Code."
  }

  if (-not (Test-Path -LiteralPath $TargetAsarPath)) {
    New-Item -ItemType Junction -Path $TargetAsarPath -Target $TargetDirectory | Out-Null
  }
}

$password = Resolve-CodeServerPassword `
  -ProvidedPassword $Password `
  -WasProvided $PSBoundParameters.ContainsKey("Password")
$repoRoot = Get-RepoRoot

$paths = [ordered]@{
  Root = $repoRoot
  CodeServerRuntime = Join-Path $repoRoot "code-server-runtime"
  Configs = Join-Path $repoRoot "configs"
  Data = Join-Path $repoRoot "data"
  UserData = Join-Path $repoRoot "data\user-data"
  Extensions = Join-Path $repoRoot "data\extensions"
  Logs = Join-Path $repoRoot "logs"
  Node22 = Join-Path $repoRoot "node22"
  NodeZip = Join-Path $repoRoot ("node22\node-v{0}-win-x64.zip" -f $NodeVersion)
  NodeDir = Join-Path $repoRoot ("node22\node-v{0}-win-x64" -f $NodeVersion)
  NodeExe = Join-Path $repoRoot ("node22\node-v{0}-win-x64\node.exe" -f $NodeVersion)
  NpmCmd = Join-Path $repoRoot ("node22\node-v{0}-win-x64\npm.cmd" -f $NodeVersion)
  NpmCli = Join-Path $repoRoot ("node22\node-v{0}-win-x64\node_modules\npm\bin\npm-cli.js" -f $NodeVersion)
  CodeServerEntry = Join-Path $repoRoot "code-server-runtime\node_modules\code-server\out\node\entry.js"
  VsCodeRoot = Join-Path $repoRoot "code-server-runtime\node_modules\code-server\lib\vscode"
  VsCodeNodeModules = Join-Path $repoRoot "code-server-runtime\node_modules\code-server\lib\vscode\node_modules"
  VsCodeNodeModulesAsar = Join-Path $repoRoot "code-server-runtime\node_modules\code-server\lib\vscode\node_modules.asar"
  CodeServerConfig = Join-Path $repoRoot "configs\code-server-config.yaml"
  Credentials = Join-Path $repoRoot "configs\code-server-credentials.txt"
  StartBat = Join-Path $repoRoot "start.bat"
}

Write-Step "Creating repo-local folders"
foreach ($directory in @(
  $paths.CodeServerRuntime,
  $paths.Configs,
  $paths.UserData,
  $paths.Extensions,
  $paths.Logs,
  $paths.Node22
)) {
  Ensure-Directory -Path $directory
}

Write-Step "Downloading repo-local Node.js $NodeVersion"
if (-not (Test-Path -LiteralPath $paths.NodeExe)) {
  $nodeUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
  Invoke-WebRequest -Uri $nodeUrl -OutFile $paths.NodeZip
  Expand-Archive -Path $paths.NodeZip -DestinationPath $paths.Node22 -Force
}

if (-not (Test-Path -LiteralPath $paths.NodeExe)) {
  throw "Node runtime was not installed correctly. Missing file: $($paths.NodeExe)"
}

Write-Step "Installing code-server into the repo"
$codeServerPackage = if ([string]::IsNullOrWhiteSpace($CodeServerVersion)) {
  "code-server"
} else {
  "code-server@$CodeServerVersion"
}

Invoke-NpmCommand -FilePath $paths.NpmCmd -Arguments @(
  "install",
  "--ignore-scripts",
  "--prefix",
  $paths.CodeServerRuntime,
  $codeServerPackage
)

if (-not (Test-Path -LiteralPath $paths.CodeServerEntry)) {
  throw "code-server entry point was not created. Missing file: $($paths.CodeServerEntry)"
}

Write-Step "Installing bundled VS Code JavaScript dependencies"
Invoke-RepoLocalNpmInstall -NodeExe $paths.NodeExe -NpmCli $paths.NpmCli -WorkingDirectory $paths.VsCodeRoot
Invoke-RepoLocalNpmInstall -NodeExe $paths.NodeExe -NpmCli $paths.NpmCli -WorkingDirectory (Join-Path $paths.VsCodeRoot "extensions")

Write-Step "Copying matching native modules from desktop VS Code"
$codeExe = Get-DesktopVSCodeExe
$expectedVsCodeVersion = (
  Get-Content -LiteralPath (Join-Path $paths.VsCodeRoot "package.json") -Raw |
  ConvertFrom-Json
).version
$installedVsCodeVersion = (Get-Item -LiteralPath $codeExe).VersionInfo.ProductVersion

if ($installedVsCodeVersion -ne $expectedVsCodeVersion) {
  throw "Installed VS Code version $installedVsCodeVersion does not match bundled VS Code version $expectedVsCodeVersion."
}

$desktopRuntimeDir = Get-DesktopVSCodeRuntimeDir -CodeExe $codeExe
$sourceNodeModules = Join-Path $desktopRuntimeDir "resources\app\node_modules"
Copy-DesktopVSCodeNodeModules `
  -SourceDirectory $sourceNodeModules `
  -TargetDirectory $paths.VsCodeNodeModules `
  -TargetAsarPath $paths.VsCodeNodeModulesAsar

Write-Step "Writing the direct HTTP code-server config"
@"
bind-addr: 127.0.0.1:$Port
auth: password
password: $password
cert: false
user-data-dir: $(Get-ForwardSlashPath -Path $paths.UserData)
extensions-dir: $(Get-ForwardSlashPath -Path $paths.Extensions)
disable-telemetry: true
"@ | Set-Content -LiteralPath $paths.CodeServerConfig -Encoding ascii

Write-Step "Writing the local credential note"
@"
Direct URL: http://127.0.0.1:$Port
Password: $password
"@ | Set-Content -LiteralPath $paths.Credentials -Encoding ascii

Write-Step "Writing the batch launcher"
@"
@echo off
setlocal
set "ROOT=%~dp0"
"%ROOT%node22\node-v$NodeVersion-win-x64\node.exe" "%ROOT%code-server-runtime\node_modules\code-server\out\node\entry.js" --config "%ROOT%configs\code-server-config.yaml" --ignore-last-opened
"@ | Set-Content -LiteralPath $paths.StartBat -Encoding ascii

Write-Step "Install complete"
$installedCodeServerVersion = (
  Get-Content -LiteralPath (Join-Path $paths.CodeServerRuntime "node_modules\code-server\package.json") -Raw |
  ConvertFrom-Json
).version
Write-Host "Desktop VS Code: $codeExe"
Write-Host "code-server version: $installedCodeServerVersion"
Write-Host "Bundled VS Code version: $expectedVsCodeVersion"
Write-Host "code-server config: $($paths.CodeServerConfig)"
Write-Host "credentials note: $($paths.Credentials)"
Write-Host "batch launcher: $($paths.StartBat)"
Write-Host ""
Write-Host "Start code-server with:" -ForegroundColor Green
Write-Host ("  & `"{0}`" `"{1}`" --config `"{2}`" --ignore-last-opened" -f $paths.NodeExe, $paths.CodeServerEntry, $paths.CodeServerConfig)
Write-Host "Or run:"
Write-Host ("  {0}" -f $paths.StartBat)
Write-Host ""
Write-Host "Then open http://127.0.0.1:$Port and sign in with the password you entered."
