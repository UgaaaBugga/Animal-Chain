@echo off
chcp 65001 >nul
title Animalchain - DB initialisieren (ERSTES Mal)
color 0E

cd /d "%~dp0"

echo ============================================================
echo   Datenbank initialisieren
echo ============================================================
echo.
echo   Wendet Schema und Seed-Daten an.
echo   Nutze das EINMAL beim ersten Aufsetzen, oder wenn du
echo   ein neues Schema entwickelt hast.
echo.
echo   Bestehende Daten (Lobbys, Zuege) werden geloescht!
echo.
echo   (Supabase muss bereits laufen - sonst zuerst start.bat)
echo.
pause

call supabase db reset --local

echo.
echo Fertig.
pause
