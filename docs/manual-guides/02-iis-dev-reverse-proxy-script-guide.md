# 02 IIS `/dev` Reverse Proxy Script Guide

This guide uses the repo script to create an IIS sub-application named `/dev` that reverse-proxies to a locally running `code-server` backend.

Use this guide when:

- IIS is already installed and working
- URL Rewrite and ARR are already installed
- your standalone `code-server` install already runs on `http://127.0.0.1:8080`
- you want IIS to expose that backend at `https://localhost/dev`

This guide does not install IIS, ARR, URL Rewrite, or HTTPS bindings. It assumes those pieces already exist.

## What The Script Creates

When you run the script, it:

- creates or reuses the IIS application pool `code-server-dev`
- creates or reuses the IIS application `Default Web Site/dev`
- uses `C:\inetpub\wwwroot\dev` as the application physical path by default
- enables ARR proxy mode at the IIS server level
- allows the forwarded rewrite server variables needed by the app-local rule set
- strips proxied `Sec-WebSocket-Extensions` so `code-server` WebSocket traffic works reliably through ARR
- writes `C:\inetpub\wwwroot\dev\web.config` with rewrite rules scoped only to `/dev`

That means the root site can keep serving its existing content while `/dev` proxies to `code-server`.

## 1. Start code-server First

If you installed with the repo standalone script, start the backend from the repo root:

```powershell
.\start.bat
```

If you are using the direct manual setup instead, start it with the generated Node command from [01-standalone-direct-code-server-guide.md](./01-standalone-direct-code-server-guide.md).

The IIS proxy script expects the backend to be reachable at:

`http://127.0.0.1:8080`

If you installed the standalone direct setup before this repo switched from `localhost:8080` to `127.0.0.1:8080`, update `.\configs\code-server-config.yaml` first:

```powershell
(Get-Content .\configs\code-server-config.yaml) `
  -replace '^bind-addr:\s*localhost:8080$', 'bind-addr: 127.0.0.1:8080' |
  Set-Content .\configs\code-server-config.yaml -Encoding ascii
```

Then restart `code-server` before running the IIS proxy script.

## 2. Open An Elevated PowerShell Window

The IIS script changes IIS configuration, so it must be run as Administrator.

If you run it from a normal PowerShell window, it will stop immediately with an elevation error before making IIS changes.
If you run it from PowerShell 7, the script will automatically relaunch itself in Windows PowerShell 5.1 so the IIS `WebAdministration` module and `IIS:` drive work correctly.

Example:

```powershell
Set-Location C:\code-server-iis
```

## 3. Run The IIS `/dev` Proxy Script

Run:

```powershell
.\scripts\02-create-iis-dev-reverse-proxy.ps1
```

Default behavior:

- site name: `Default Web Site`
- application name: `dev`
- application pool: `code-server-dev`
- physical path: `C:\inetpub\wwwroot\dev`
- backend: `http://127.0.0.1:8080`

If you want to override those defaults, for example:

```powershell
.\scripts\02-create-iis-dev-reverse-proxy.ps1 `
  -SiteName "Default Web Site" `
  -ApplicationName "dev" `
  -ApplicationPoolName "code-server-dev" `
  -PhysicalPath "C:\inetpub\wwwroot\dev" `
  -BackendUrl "http://127.0.0.1:8080"
```

## 4. What To Expect

After the script succeeds:

- IIS application `Default Web Site/dev` should exist
- the application pool `code-server-dev` should exist and be restarted
- `C:\inetpub\wwwroot\dev\web.config` should exist
- requests to `/dev` should be isolated from the IIS root site

The generated `web.config` performs two important actions:

- redirects `/dev` to `/dev/`
- rewrites `/dev/*` to `http://127.0.0.1:8080/*`

It also clears the proxied `Sec-WebSocket-Extensions` header before forwarding the request. This avoids ARR `502 5 12152` failures on the `code-server` WebSocket connection.

## 5. Verify The Backend

Check the direct backend first:

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/healthz
```

Expected result:

- HTTP status `200`

## 6. Verify The IIS `/dev` Proxy

Then check the proxied endpoint:

```powershell
Invoke-WebRequest -UseBasicParsing https://localhost/dev/healthz
```

Expected result:

- HTTP status `200`

Then open:

`https://localhost/dev`

Expected result:

- the code-server login page loads under the `/dev` path
- after sign-in, the editor stays under `/dev`

During browser or Playwright validation, you may still see non-blocking warnings about service worker scope or `vsda.js`. Those warnings were present during verification, but the `/dev` workbench still loaded and the proxied editor session worked correctly.

## 7. Restart Later

To restart the backend later:

```powershell
Set-Location C:\code-server-iis
.\start.bat
```

You only need to re-run the IIS proxy script if you want to change the IIS-side configuration.

## 8. Common Fixes

If the script says it must be run as Administrator:

1. Close the current PowerShell window.
2. Open PowerShell with `Run as administrator`.
3. Run the script again.

If the script says ARR proxy settings are not available:

1. Install IIS Application Request Routing.
2. Run the script again.

If the script says URL Rewrite is not available:

1. Install IIS URL Rewrite.
2. Run the script again.

If `https://localhost/dev/healthz` fails but `http://127.0.0.1:8080/healthz` works:

1. Confirm the IIS site already has a working binding for `https://localhost`.
2. Confirm the IIS application `Default Web Site/dev` exists.
3. Confirm `C:\inetpub\wwwroot\dev\web.config` exists.
4. Re-run `.\scripts\02-create-iis-dev-reverse-proxy.ps1` from an elevated PowerShell window.

If both `/dev/healthz` and the backend `/healthz` fail:

1. Start `code-server` again with `.\start.bat`.
2. Re-test `http://127.0.0.1:8080/healthz`.
3. Re-test `https://localhost/dev/healthz`.
