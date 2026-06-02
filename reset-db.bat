@echo off
chcp 65001 >nul
title Animalchain - Datenbank zuruecksetzen
color 0E

cd /d "%~dp0"

echo ============================================================
echo   ACHTUNG: Datenbank zuruecksetzen
echo ============================================================
echo.
echo   Das loescht ALLE lokalen Daten (Lobbys, Spielzuege, etc.)
echo   und legt das Schema neu an (mit den Seed-Tieren).
echo.
echo   Falls Supabase noch nicht laeuft, starte zuerst "start.bat".
echo.
set /p CONFIRM="Wirklich zuruecksetzen? (j/n): "
if /i not "%CONFIRM%"=="j" (
  echo Abgebrochen.
  pause
  exit /b
)

echo.
echo Wende Migrationen + Seed-Daten an...
call supabase db reset --local
echo.

echo Fertig.
pause
