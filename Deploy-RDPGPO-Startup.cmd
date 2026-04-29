@echo off
REM ============================================================================
REM  Deploy-RDPGPO-Startup.cmd - Wrapper GPO Computer Startup
REM ============================================================================
REM  A referencer dans :
REM    Configuration ordinateur > Strategies > Parametres Windows > Scripts
REM    > Demarrage > Ajouter > Deploy-RDPGPO-Startup.cmd
REM
REM  Le .ps1 doit etre dans le meme dossier que ce .cmd
REM  (typiquement \\domain\sysvol\<dom>\scripts\RDPShadow\)
REM ============================================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Deploy-RDPGPO.ps1"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOGDIR=C:\Windows\Logs"
set "LOGFILE=%LOGDIR%\RDP-Shadow-Deploy.log"

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

if not exist "%PS1%" (
    echo [ERROR] Script introuvable: "%PS1%" >> "%LOGFILE%"
    exit /b 2
)

REM ExecutionPolicy Bypass uniquement pour ce processus, sans modifier la machine.
"%PSEXE%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
    -File "%PS1%" ^
    -ShadowMode 2 ^
    -AllowedRemoteAddresses "LocalSubnet" ^
    -NetworkWaitTimeoutSeconds 0 ^
    -NetworkRetryIntervalSeconds 5 ^
    -MaxAgeDays 7

set RC=%ERRORLEVEL%
endlocal & exit /b %RC%
