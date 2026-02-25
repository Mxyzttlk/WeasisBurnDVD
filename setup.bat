@echo off
REM Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
chcp 65001 >nul 2>&1
title DICOM DVD Burn - Setup

echo.
echo ============================================
echo   Setup - Weasis Portable + JRE
echo ============================================
echo   Ruleaza o singura data inainte de primul burn
echo ============================================
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1"

echo.
pause
