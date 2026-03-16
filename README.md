# code-server-windows

Source-controlled setup files for running `code-server` on Windows directly and through IIS `/dev`.

This project provides Windows and IIS setup automation for `code-server`. The upstream `code-server` project is maintained by Coder: https://github.com/coder/code-server

This repository intentionally tracks the authored parts of the workspace and ignores the live machine state. That keeps Git history portable and avoids committing local credentials, private keys, logs, screenshots, and bundled runtime directories.

## License Scope

The MIT `LICENSE` in this repository applies to the original files stored in Git in this project, such as the PowerShell scripts, documentation, and example configs.

This repo also downloads, installs, or copies third-party components during local setup, including `code-server`, Node.js, and native modules from an installed desktop Visual Studio Code. Those third-party components are not relicensed by this repository and remain subject to their own upstream licenses and terms.

See `NOTICE` for a short summary.

## Supported Scripts

This repo keeps these supported setup scripts:

- `scripts/01-install-standalone-direct-code-server.ps1`
  Installs the repo-local `code-server` runtime and writes `start.bat` for direct local access on `http://127.0.0.1:8080`.
- `scripts/02-create-iis-dev-reverse-proxy.ps1`
  Creates or updates `Default Web Site/dev` as an IIS reverse proxy to the local `code-server` backend.
- `scripts/update-code-server.ps1`
  Reinstalls the repo-local runtime to the latest `code-server` release while reusing the current password and port from the local config.

## Getting Started

Open an elevated PowerShell session in the repo root and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\01-install-standalone-direct-code-server.ps1
.\start.bat
.\scripts\02-create-iis-dev-reverse-proxy.ps1
```

For a non-interactive password, use either:

```powershell
.\scripts\01-install-standalone-direct-code-server.ps1 -Password 'N@sh!123404015'
```

or the positional shorthand:

```powershell
.\scripts\01-install-standalone-direct-code-server.ps1 'N@sh!123404015'
```

Then open either:

- `http://127.0.0.1:8080`
- `https://localhost/dev`

## Updating code-server

When a new upstream `code-server` release is available, run:

```powershell
.\scripts\update-code-server.ps1
```

The updater reads the current password and port from `configs/code-server-config.yaml`, refreshes `code-server-runtime/`, and then you can start the updated runtime again with:

```powershell
.\start.bat
```

If you want to pin a specific version instead of the latest published release:

```powershell
.\scripts\update-code-server.ps1 -CodeServerVersion 4.111.0
```

## Fresh Clone Output

These paths are intentionally generated locally instead of being stored in Git:

- `code-server-runtime/`
- `configs/code-server-config.yaml`
- `configs/code-server-credentials.txt`
- `data/`
- `logs/`
- `node22/`
- `start.bat`

## Tracked

- `scripts/`
- `docs/manual-guides/`
- `configs/*.example`

## Ignored

- `data/`
- `logs/`
- `downloads/`
- `node22/`
- `code-server-runtime/`
- live config, credentials, and PID files

## Notes

- The standalone installer writes the runtime config and credentials locally.
- `docs/manual-guides/01-standalone-direct-code-server-guide.md` and `docs/manual-guides/02-iis-dev-reverse-proxy-script-guide.md` are the current reference guides.
- The example files in `configs/` document the expected shape without storing secrets.
- `NOTICE` clarifies the intended scope of this repo's MIT license versus third-party components generated or downloaded during setup.

