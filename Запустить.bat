@echo off
chcp 65001 >nul
title Capitalis - Финансовый симулятор
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"
if errorlevel 1 pause
