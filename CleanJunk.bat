@echo off
rem Double-click to open the CleanJunk window. Asks for admin so Windows temp/log folders can be cleaned too.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CleanJunk.ps1"
