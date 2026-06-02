@echo off
chcp 65001 >nul
title Animalchain - Webserver
color 0B

cd /d "%~dp0"

echo ============================================================
echo   Animalchain - Webserver auf http://localhost:3000
echo   (Strg+C zum Beenden, Fenster offen lassen)
echo ============================================================
echo.

REM 1) Echtes Python (nicht der MS-Store-Stub!) mit unserem smarten Server
python --version >nul 2>&1
if not errorlevel 1 (
  echo Starte mit Python server.py...
  start "" "http://localhost:3000"
  python "%~dp0server.py" 3000
  goto :ende
)

REM 2) py.exe (Windows Python Launcher)
py --version >nul 2>&1
if not errorlevel 1 (
  echo Starte mit py server.py...
  start "" "http://localhost:3000"
  py "%~dp0server.py" 3000
  goto :ende
)

REM 3) Node.js / npx serve (kann auch .html-Extensions auto-aufloesen)
node --version >nul 2>&1
if not errorlevel 1 (
  echo Starte mit npx serve...
  start "" "http://localhost:3000"
  npx --yes serve -l 3000 --no-clipboard .
  goto :ende
)

REM 4) PowerShell Fallback mit .html-Aufloesung
where powershell >nul 2>&1
if not errorlevel 1 (
  echo Starte mit PowerShell-Webserver ^(Fallback^)...
  start "" "http://localhost:3000"
  powershell -ExecutionPolicy Bypass -NoProfile -Command ^
    "$listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add('http://localhost:3000/'); $listener.Start(); Write-Host 'Webserver laeuft auf http://localhost:3000'; $root = (Get-Location).Path; while ($listener.IsListening) { try { $ctx = $listener.GetContext(); $path = $ctx.Request.Url.LocalPath; if ($path -eq '/') { $path = '/index.html' }; $file = Join-Path $root ($path.TrimStart('/')); if (-not (Test-Path $file -PathType Leaf) -and -not $file.Contains('.')) { if (Test-Path ($file + '.html') -PathType Leaf) { $file = $file + '.html' } }; if (Test-Path $file -PathType Leaf) { $bytes = [System.IO.File]::ReadAllBytes($file); $ext = [System.IO.Path]::GetExtension($file).ToLower(); $mime = switch ($ext) { '.html' {'text/html'} '.css' {'text/css'} '.js' {'application/javascript'} '.svg' {'image/svg+xml'} '.json' {'application/json'} '.png' {'image/png'} '.jpg' {'image/jpeg'} default {'application/octet-stream'} }; $ctx.Response.ContentType = $mime; $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); } else { $ctx.Response.StatusCode = 404; }; $ctx.Response.Close(); } catch { Write-Host $_.Exception.Message } }"
  goto :ende
)

echo.
echo FEHLER: Kein Webserver-Tool gefunden.
echo Installiere eines davon:
echo   - Python:   https://python.org/downloads/
echo   - Node.js:  https://nodejs.org/
echo.

:ende
echo.
echo Webserver beendet.
pause
