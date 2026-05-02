@echo off
REM ============================================================================
REM  RemoteDesktopAssistant.cmd - Lanceur avec elevation administrateur
REM ============================================================================
REM  Utilisation : double-cliquer sur ce fichier, ou ajouter un raccourci
REM  avec "Executer en tant qu'administrateur" coche dans les proprietes.
REM
REM  Ce wrapper gere l'elevation via cmd.exe (et non via PowerShell se
REM  re-lancant lui-meme), ce qui est moins ambigu pour les EDR/AV.
REM ============================================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%RemoteDesktopAssistantV1.4.ps1"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS1%" (
    echo [ERREUR] Script introuvable : "%PS1%"
    pause
    exit /b 1
)

REM Verifier si on est deja administrateur (net session renvoie 0 si admin)
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    REM Relancer ce .cmd en administrateur via ShellExecute runas
    "%PSEXE%" -NoProfile -Command "Start-Process '%comspec%' -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b
)

REM ExecutionPolicy Bypass porte uniquement sur ce processus, sans modifier la machine.
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

endlocal
exit /b %ERRORLEVEL%
