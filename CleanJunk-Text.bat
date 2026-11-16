@echo off
rem Text version (pick by typing numbers). Use this if the window version has problems.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CleanJunk.ps1" -Console
echo.
pause
