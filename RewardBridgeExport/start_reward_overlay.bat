@echo off
setlocal
cd /d "%~dp0"
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ".\reward_overlay_control.ps1"
