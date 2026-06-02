@echo off
chcp 65001 >nul
title Animalchain - Seed-Daten anwenden
color 0E

cd /d "%~dp0"

echo ============================================================
echo   Tier-Liste in lokale Datenbank einfuegen
echo   (Bestehende Daten - Lobbys, Spielzuege - bleiben erhalten)
echo ============================================================
echo.

REM Pruefe ob lokale Supabase laeuft
docker ps --format "{{.Names}}" 2>nul | findstr /R "supabase_db" >nul
if errorlevel 1 (
  echo FEHLER: Lokale Supabase laeuft nicht.
  echo Starte zuerst "start.bat".
  echo.
  pause
  exit /b 1
)

REM Container-Name finden
for /f "tokens=*" %%c in ('docker ps --format "{{.Names}}" ^| findstr /R "supabase_db"') do set DBCONT=%%c
echo Container: %DBCONT%
echo.

echo Pipe seed.sql in den Postgres-Container...
type "supabase\seed.sql" | docker exec -i %DBCONT% psql -U postgres -d postgres -v ON_ERROR_STOP=1
if errorlevel 1 (
  echo.
  echo FEHLER beim Einfuegen.
) else (
  echo.
  echo ============================================================
  echo   FERTIG! Pruefen mit:
  echo   docker exec -it %DBCONT% psql -U postgres -d postgres -c "select count(*) from public.animals;"
  echo ============================================================
)
echo.
pause
