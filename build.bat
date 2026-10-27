@echo off
setlocal
title Rust Pixel Bridge - Build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-windows.ps1" -BootstrapInno %*
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Falha ao gerar os pacotes. Verifique a mensagem acima.
pause
exit /b %result%
