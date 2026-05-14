# Genera un unico MPV-Interp-Wizard.bat que lleva el .ps1 embebido en base64.
# Uso:  powershell -ExecutionPolicy Bypass -File build-single-bat.ps1

$ErrorActionPreference = "Stop"
$here    = $PSScriptRoot
$srcPs1  = Join-Path $here "mpv-interp-wizard.ps1"
$outBat  = Join-Path $here "MPV-Interp-Wizard.bat"

if (-not (Test-Path $srcPs1)) { throw "No se encuentra $srcPs1" }

# Codificar el .ps1 en base64, con saltos cada 76 chars (formato certutil)
$bytes  = [IO.File]::ReadAllBytes($srcPs1)
$b64    = [Convert]::ToBase64String($bytes, 'InsertLineBreaks')

$header = @'
@echo off
REM ==========================================================================
REM  MPV Interpolation Wizard - launcher auto-extraible
REM  Doble clic para instalar/configurar interpolacion de frames en mpv.
REM  El script PowerShell va embebido al final de este archivo.
REM ==========================================================================
setlocal EnableDelayedExpansion

REM Directorio donde vive este .bat (para que el wizard guarde config aqui)
set "MPV_INTERP_HOME=%~dp0"
if "%MPV_INTERP_HOME:~-1%"=="\" set "MPV_INTERP_HOME=%MPV_INTERP_HOME:~0,-1%"

REM Carpeta temporal para extraer el .ps1 (siempre limpia antes de extraer)
set "TMPDIR=%TEMP%\mpv-interp-wizard"
if exist "%TMPDIR%" rmdir /S /Q "%TMPDIR%" >nul 2>&1
mkdir "%TMPDIR%" >nul 2>&1
set "TMPPS=%TMPDIR%\wizard.ps1"
set "B64FILE=%TMPDIR%\wizard.b64"

REM Encontrar la linea de inicio del payload
for /f "delims=:" %%a in ('findstr /n "^::PAYLOAD_BEGIN::" "%~f0"') do set "START=%%a"
if not defined START (
    echo [ERROR] Payload no encontrado en este .bat
    pause
    exit /b 1
)
set /a START+=1

REM Extraer el base64 a un archivo temporal
more +%START% "%~f0" > "%B64FILE%"

REM Decodificar a .ps1
certutil -decode "%B64FILE%" "%TMPPS%" >nul
if errorlevel 1 (
    echo [ERROR] No se pudo decodificar el wizard.
    pause
    exit /b 1
)

REM Preferir PowerShell 7 si esta disponible
where pwsh.exe >nul 2>&1
if %errorlevel%==0 (
    pwsh.exe -ExecutionPolicy Bypass -NoProfile -File "%TMPPS%"
) else (
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%TMPPS%"
)
set "RC=%errorlevel%"

REM Limpieza
del "%B64FILE%" >nul 2>&1
del "%TMPPS%" >nul 2>&1
rmdir "%TMPDIR%" >nul 2>&1

if not "%RC%"=="0" (
    echo.
    echo El wizard termino con codigo %RC%.
    pause
)
exit /b %RC%

::PAYLOAD_BEGIN::
'@

# Escribir el .bat con CRLF (importante para que findstr/more funcionen bien)
$lines = @($header) + ($b64 -split "`r?`n")
[IO.File]::WriteAllText($outBat, ($lines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

$srcKB = [math]::Round((Get-Item $srcPs1).Length / 1KB, 1)
$outKB = [math]::Round((Get-Item $outBat).Length / 1KB, 1)
Write-Host ""
Write-Host "  OK -> $outBat" -ForegroundColor Green
Write-Host "       fuente: $srcKB KB   |   bat final: $outKB KB" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Compartir SOLO este archivo. Doble clic para usarlo." -ForegroundColor White
