@echo off
title Animalchain - Server stoppen
color 0E

cd /d "%~dp0"

echo Stoppe alle Supabase-Container...
supabase stop

echo.
echo Erledigt. Daten bleiben im Docker-Volume erhalten.
echo Beim naechsten "supabase start" sind sie wieder da.
echo.
pause
