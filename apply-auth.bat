@echo off
chcp 65001 >nul
title Animalchain - Auth-Migration anwenden
color 0E

cd /d "%~dp0"

echo ============================================================
echo   Account-Migration anwenden (accounts + sessions Tabellen,
echo   register_account, login_account etc.)
echo   Bestehende Daten (Lobbys, Tiere) bleiben erhalten.
echo ============================================================
echo.

docker ps --format "{{.Names}}" 2>nul | findstr /R "supabase_db" >nul
if errorlevel 1 (
  echo FEHLER: Lokale Supabase laeuft nicht. Starte zuerst start.bat.
  echo.
  pause
  exit /b 1
)

for /f "tokens=*" %%c in ('docker ps --format "{{.Names}}" ^| findstr /R "supabase_db"') do set DBCONT=%%c
echo Container: %DBCONT%
echo.

echo Wende Migration an...
type "supabase\migrations\20260528010000_accounts.sql" | docker exec -i %DBCONT% psql -U postgres -d postgres -v ON_ERROR_STOP=1
if errorlevel 1 (
  echo.
  echo FEHLER beim Anwenden.
) else (
  echo.
  echo ============================================================
  echo   FERTIG! Du kannst dich jetzt unter http://localhost:3000/account.html
  echo   registrieren und anmelden.
  echo ============================================================
)
echo.
pause
