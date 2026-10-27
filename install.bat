@echo off
setlocal
title Rust Pixel Bridge
set "bridge=%~dp0asprite-mcp.exe"
if not exist "%bridge%" set "bridge=%~dp0target\release\asprite-mcp.exe"
if not exist "%bridge%" (
  echo Executavel nao encontrado. Use o instalador ou o pacote Windows de uma release.
  echo Para compilar o projeto, execute build.bat.
  pause
  exit /b 1
)
set "client_option="
if exist "%APPDATA%\Claude\" set "client_option=--claude"
"%bridge%" install %client_option% %*
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo A instalacao falhou. Verifique a mensagem acima.
pause
exit /b %result%
