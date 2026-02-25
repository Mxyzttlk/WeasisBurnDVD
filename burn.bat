@echo off
REM Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
chcp 65001 >nul 2>&1
title DICOM DVD Burn - Weasis

echo.
echo ============================================
echo   DICOM DVD Burn - Weasis Portable
echo ============================================
echo.

REM Check if ZIP path was provided (drag & drop or argument)
if "%~1"=="" (
    echo [EROARE] Trage un fisier ZIP peste acest BAT!
    echo          Sau ruleaza: burn.bat "cale\catre\fisier.zip"
    echo.
    pause
    exit /b 1
)

REM Check if file exists
if not exist "%~1" (
    echo [EROARE] Fisierul nu exista: %~1
    echo.
    pause
    exit /b 1
)

REM Check if it's a ZIP
if /i not "%~x1"==".zip" (
    echo [EROARE] Fisierul trebuie sa fie .zip!
    echo          Ai dat: %~x1
    echo.
    pause
    exit /b 1
)

REM Run the PowerShell script
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\burn.ps1" -ZipPath "%~1"

echo.
pause
