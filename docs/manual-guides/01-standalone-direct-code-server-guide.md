# 01 Standalone Direct code-server Guide

This guide installs and runs `code-server` directly on Windows over plain HTTP with:

- no IIS
- no reverse proxy
- no scheduled task or service
- no dependency on this repo's PowerShell scripts

This guide is for direct local access only:

`http://127.0.0.1:8080`

It does not configure HTTPS, IIS, ARR, or the `/dev` application path.

## What This Guide Requires

Use this guide on a Windows machine with:

- a fresh clone of this repository
- internet access
- PowerShell
- desktop Visual Studio Code already installed locally

Important Windows note:

- current `code-server` Windows npm installs still depend on native VS Code modules
- `npm install --ignore-scripts` avoids shell-script failures on Windows, but it also skips the native-module setup that `code-server` expects
- this guide works around that by copying the matching native modules from an installed desktop VS Code into the local repo runtime

This guide was tested with:

- `code-server` `4.111.0`
- bundled VS Code `1.111.0`
- desktop VS Code `1.111.0`

It was re-verified on a fresh clone on March 16, 2026 with the same version combination.

Related repo-script note:

- if you want to validate the repo helper instead of following the manual steps below, `scripts/01-install-standalone-direct-code-server.ps1` now accepts an optional password argument for non-interactive runs, either as `-Password <value>` or as the first positional argument
- that same installer now also generates `.\start.bat` in the repo root so you can launch the installed standalone direct setup without retyping the Node command

## 1. Open PowerShell In The Repo Root

Open PowerShell and change into the cloned repository folder.

Example:

```powershell
Set-Location C:\code-server-iis
```

All commands below assume you are running from the repo root.

## 2. Create The Required Local Folders

```powershell
New-Item -ItemType Directory -Force -Path `
  .\code-server-runtime, `
  .\configs, `
  .\data\user-data, `
  .\data\extensions, `
  .\logs, `
  .\node22 | Out-Null
```

## 3. Download A Local Node.js Runtime

This keeps the setup self-contained inside the repo.

```powershell
$nodeVersion = "22.22.1"
$nodeZip = ".\node22\node-v$nodeVersion-win-x64.zip"
$nodeUrl = "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-win-x64.zip"

Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeZip
Expand-Archive -Path $nodeZip -DestinationPath .\node22 -Force
```

After this step, this file should exist:

`.\node22\node-v22.22.1-win-x64\node.exe`

## 4. Install code-server Into The Repo

Install the main `code-server` package locally:

```powershell
.\node22\node-v22.22.1-win-x64\npm.cmd install --ignore-scripts --prefix .\code-server-runtime code-server
```

After this step, this file should exist:

`.\code-server-runtime\node_modules\code-server\out\node\entry.js`

## 5. Install The Bundled VS Code JavaScript Dependencies

Run both commands below exactly as shown. They use the repo-local Node 22 runtime directly instead of relying on any system Node.js install.

```powershell
$node = (Resolve-Path .\node22\node-v22.22.1-win-x64\node.exe).Path
$npmCli = (Resolve-Path .\node22\node-v22.22.1-win-x64\node_modules\npm\bin\npm-cli.js).Path

Push-Location .\code-server-runtime\node_modules\code-server\lib\vscode
& $node $npmCli install --ignore-scripts --omit=dev
Pop-Location

Push-Location .\code-server-runtime\node_modules\code-server\lib\vscode\extensions
& $node $npmCli install --ignore-scripts --omit=dev
Pop-Location
```

## 6. Copy Matching Native Modules From Desktop VS Code

This is the key Windows-specific step that makes the standalone direct install work without repo scripts or Visual Studio C++ build tools.

Run this block from the repo root:

```powershell
$codeCommand = Get-Command code -ErrorAction Stop
$codeExe = if ($codeCommand.Source -like '*.cmd') {
  Join-Path (Split-Path -Parent (Split-Path -Parent $codeCommand.Source)) 'Code.exe'
} else {
  $codeCommand.Source
}

if (-not (Test-Path $codeExe)) {
  throw "Unable to find Code.exe from the 'code' command."
}

$expectedVsCodeVersion = (
  Get-Content .\code-server-runtime\node_modules\code-server\lib\vscode\package.json -Raw |
  ConvertFrom-Json
).version
$installedVsCodeVersion = (Get-Item $codeExe).VersionInfo.ProductVersion

if ($installedVsCodeVersion -ne $expectedVsCodeVersion) {
  throw "Installed VS Code version $installedVsCodeVersion does not match the bundled VS Code version $expectedVsCodeVersion."
}

$vscodeRoot = Split-Path -Parent $codeExe
$vscodeRuntimeDir = Get-ChildItem $vscodeRoot -Directory |
  Where-Object { Test-Path (Join-Path $_.FullName 'resources\app\node_modules') } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $vscodeRuntimeDir) {
  throw "Unable to find the desktop VS Code runtime directory under $vscodeRoot."
}

$sourceNodeModules = Join-Path $vscodeRuntimeDir.FullName 'resources\app\node_modules'
$targetNodeModules = (Resolve-Path .\code-server-runtime\node_modules\code-server\lib\vscode\node_modules).Path
$targetNodeModulesAsar = '.\code-server-runtime\node_modules\code-server\lib\vscode\node_modules.asar'

robocopy $sourceNodeModules $targetNodeModules /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null

if (-not (Test-Path $targetNodeModulesAsar)) {
  New-Item -ItemType Junction -Path $targetNodeModulesAsar -Target $targetNodeModules | Out-Null
}
```

Notes:

- `code` must already be on your `PATH`
- the desktop VS Code version must match the bundled VS Code version shown in `lib\vscode\package.json`
- the junction target must be an absolute path, which is why the command uses `Resolve-Path`

## 7. Create A Local Direct-HTTP code-server Config

This config binds to `127.0.0.1:8080`, enables password auth, and keeps the endpoint on plain HTTP.

```powershell
$root = (Get-Location).Path -replace '\\', '/'
$password = Read-Host "Enter a password for code-server"

@"
bind-addr: 127.0.0.1:8080
auth: password
password: $password
cert: false
user-data-dir: $root/data/user-data
extensions-dir: $root/data/extensions
disable-telemetry: true
"@ | Set-Content -Path .\configs\code-server-config.yaml -Encoding ascii
```

Use `127.0.0.1` here rather than `localhost` so the repo's IIS `/dev` reverse-proxy flow can reliably proxy both HTTP requests and code-server WebSocket traffic on the same machine.

After this step, this file should exist:

`.\configs\code-server-config.yaml`

## 8. Optionally Save A Local Credential Note

```powershell
@"
Direct URL: http://127.0.0.1:8080
Password: $password
"@ | Set-Content -Path .\configs\code-server-credentials.txt -Encoding ascii
```

Do not commit that credentials file to Git.

## 9. Start code-server In The Foreground

Start it without passing a Windows folder path on the command line.

```powershell
.\node22\node-v22.22.1-win-x64\node.exe `
  .\code-server-runtime\node_modules\code-server\out\node\entry.js `
  --config .\configs\code-server-config.yaml `
  --ignore-last-opened
```

Leave this PowerShell window open while `code-server` is running.

To stop it later, press `Ctrl+C`.

Expected startup behavior:

- `stdout` should log `HTTP server listening on http://127.0.0.1:8080/`
- on some Windows setups, `stderr` may also log `Could not create socket at ...\code-server-ipc.sock` once during startup
- if `/healthz` returns `200` and browser sign-in works, treat that socket warning as non-blocking for this direct local setup

Why this guide does not pass `.\workspace` or another folder path:

- with the current Windows direct-web flow, a raw Windows path on the `code-server` command line produces an unresolved folder in the browser
- starting with `--ignore-last-opened` gives a clean and repeatable HTTP launch

## 10. Verify The HTTP Endpoint

Open a second PowerShell window in the repo root and run:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/healthz
```

Expected result:

- HTTP status code `200`
- JSON content similar to `{"status":"expired","lastHeartbeat":0}` before browser sign-in
- after you sign in and the browser stays connected, the same endpoint should return `status` `alive`

If you prefer `curl.exe`, use:

```powershell
curl.exe -s http://127.0.0.1:8080/healthz
```

## 11. Sign In From Your Browser

Open:

`http://127.0.0.1:8080`

Sign in with the password you chose in Step 7.

Expected result:

- the login page loads
- sign-in succeeds
- the `code-server` web workbench opens over plain HTTP

## 12. Restart Later

Whenever you want to start it again:

```powershell
Set-Location C:\code-server-iis

.\node22\node-v22.22.1-win-x64\node.exe `
  .\code-server-runtime\node_modules\code-server\out\node\entry.js `
  --config .\configs\code-server-config.yaml `
  --ignore-last-opened
```

If you installed with `scripts/01-install-standalone-direct-code-server.ps1`, you can also just run:

```powershell
.\start.bat
```

## 13. Optional Background Start

```powershell
Start-Process `
  -FilePath .\node22\node-v22.22.1-win-x64\node.exe `
  -ArgumentList @(
    ".\code-server-runtime\node_modules\code-server\out\node\entry.js",
    "--config",
    ".\configs\code-server-config.yaml",
    "--ignore-last-opened"
  ) `
  -RedirectStandardOutput .\logs\code-server.out.log `
  -RedirectStandardError .\logs\code-server.err.log
```

To stop that background instance later:

```powershell
$listenerPid = (Get-NetTCPConnection -LocalPort 8080 -State Listen).OwningProcess
Stop-Process -Id $listenerPid -Force
```

## 14. Common Fixes

If the browser shows a `500` page with errors like `Cannot find package` or `Cannot find module ... .node`:

1. Re-run Step 5.
2. Re-run Step 6.
3. Start `code-server` again.

If Step 6 fails with a version mismatch:

1. Check the bundled version:

```powershell
(Get-Content .\code-server-runtime\node_modules\code-server\lib\vscode\package.json -Raw | ConvertFrom-Json).version
```

2. Install the same desktop VS Code version locally.
3. Re-run Step 6.

If port `8080` is already in use:

1. Edit `.\configs\code-server-config.yaml`.
2. Change `bind-addr: 127.0.0.1:8080` to another value such as `127.0.0.1:18080`.
3. Start `code-server` again.
4. Open the matching URL.

If you forget the password:

1. Edit `.\configs\code-server-config.yaml`.
2. Change the `password:` value.
3. Start `code-server` again.

If startup logs show `Could not create socket at ...\code-server-ipc.sock` once, but Step 10 and Step 11 still pass:

1. Treat it as a warning rather than a blocker for this standalone direct-local flow.
2. Continue only if `http://127.0.0.1:8080/healthz` returns `200` and the browser can open the workbench.
3. If the browser does not load, stop `code-server`, remove `.\data\user-data`, and start again.

If you need IIS and the `/dev` reverse-proxy path, stop here and use [02-iis-dev-reverse-proxy-script-guide.md](./02-iis-dev-reverse-proxy-script-guide.md) instead.
