@echo off
setlocal
title Rust Pixel Bridge
set "bridge=%LOCALAPPDATA%\Programs\Rust Pixel Bridge\asprite-mcp.exe"
if exist "%LOCALAPPDATA%\Programs\Rust Pixel Bridge\unins000.exe" (
  "%LOCALAPPDATA%\Programs\Rust Pixel Bridge\unins000.exe"
  exit /b
)
if not exist "%bridge%" (
  echo Rust Pixel Bridge nao foi encontrado na pasta padrao.
  echo Use a opcao Desinstalar do Windows para instalacoes feitas pelo Setup.
  pause
  exit /b 1
)
"%bridge%" uninstall %*
set "result=%errorlevel%"
echo.
if "%result%"=="0" (
  del /q "%bridge%"
  del /q "%LOCALAPPDATA%\Programs\Rust Pixel Bridge\rust-pixel-agent.exe"
  rmdir "%LOCALAPPDATA%\Programs\Rust Pixel Bridge" 2>nul
  echo Programa e extensao removidos. Os assets locais foram preservados.
)
pause
exit /b %result%
