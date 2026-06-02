@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Animalchain - Lokaler Server (Docker + Supabase)
color 0A

echo ============================================================
echo   Animalchain - Lokaler Entwicklungs-Server
echo ============================================================
echo.

cd /d "%~dp0"
echo Arbeitsverzeichnis: %CD%
echo.

echo [1/3] Pruefe Docker Desktop...
docker info >nul 2>&1
if errorlevel 1 (
  echo.
  echo   FEHLER: Docker laeuft nicht oder ist nicht installiert.
  echo   - Falls Docker Desktop installiert ist: starte es.
  echo   - Falls nicht: https://docker.com/products/docker-desktop
  echo.
  goto :ende
)
echo   OK: Docker laeuft.
echo.

echo [2/3] Pruefe Supabase CLI...
where supabase >nul 2>&1
if errorlevel 1 (
  echo.
  echo   FEHLER: Supabase CLI nicht gefunden.
  echo   Installation:
  echo     - Per Scoop:  scoop install supabase
  echo     - Per NPM:    npm install -g supabase
  echo     - Per Choco:  choco install supabase
  echo     - Manuell:    https://github.com/supabase/cli/releases
  echo.
  goto :ende
)
for /f "tokens=*" %%v in ('supabase --version 2^>nul') do set SBVER=%%v
echo   OK: Supabase CLI %SBVER%
echo.

echo [3/3] Starte Supabase-Container...
echo   (Beim ERSTEN Mal dauert das mehrere Minuten - Docker Images werden geladen)
echo   (Bei spaeteren Starts geht's in Sekunden, deine Daten bleiben erhalten)
echo.
call supabase start
if errorlevel 1 (
  echo.
  echo   FEHLER beim supabase start.
  echo   Tipp: supabase stop --no-backup     dann erneut versuchen.
  echo.
  goto :ende
)
echo.

echo ============================================================
echo   FERTIG!
echo.
echo   Studio (DB-UI): http://127.0.0.1:54323
echo   API:            http://127.0.0.1:54321
echo.
echo   Naechster Schritt: Datei "serve.bat" doppelklicken,
echo   um den Webserver auf http://localhost:3000 zu starten.
echo.
echo   HINWEIS: Schema wird NUR beim ersten Start angewendet.
echo   Wenn du das Schema neu aufsetzen willst (alle Daten weg),
echo   nutze "reset-db.bat"
echo ============================================================
echo.

start "" "http://127.0.0.1:54323"

:ende
echo.
echo (Druecke eine Taste zum Schliessen)
pause >nul
endlocal
