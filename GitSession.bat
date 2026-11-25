@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: -----------------------------------------------------------------------------
:: GitSession -- Ephemeral Git Workspace Manager
:: Windows Batch Entry Point
:: -----------------------------------------------------------------------------

title GitSession -- Ephemeral Git Workspace Manager

:: Set terminal encoding to UTF-8
chcp 65001 >nul 2>&1

:: Determine script directory
set "GITSESSION_DIR=%~dp0"

:: Default workspace directory
set "DEFAULT_WORKSPACE=%USERPROFILE%\GitSession-Workspace"

:: Isolated GitHub CLI configuration directory
set "GH_CONFIG_DIR=%LOCALAPPDATA%\GitSession\gh"

:: Ensure isolated config directory exists
if not exist "%GH_CONFIG_DIR%" (
    mkdir "%GH_CONFIG_DIR%" >nul 2>&1
)

:: Check for Git CLI dependency
where git >nul 2>&1
if errorlevel 1 (
    if exist "C:\Program Files\Git\cmd\git.exe" (
        set "PATH=!PATH!;C:\Program Files\Git\cmd"
    ) else if exist "%LOCALAPPDATA%\Programs\Git\cmd\git.exe" (
        set "PATH=!PATH!;%LOCALAPPDATA%\Programs\Git\cmd"
    ) else (
        echo ============================================================
        echo [WARNING] Git CLI is required but not found in PATH.
        echo ============================================================
        echo.
        set /p "INSTALL_GIT=Would you like to install Git via Winget now? [Y/N]: "
        if /i "!INSTALL_GIT!"=="Y" (
            echo.
            echo Installing Git via Winget...
            winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
            if exist "C:\Program Files\Git\cmd" set "PATH=!PATH!;C:\Program Files\Git\cmd"
            if exist "%LOCALAPPDATA%\Programs\Git\cmd" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\Git\cmd"
            where git >nul 2>&1
            if errorlevel 1 (
                echo.
                echo [ERROR] Git installation completed but git is not in current PATH.
                echo Please restart your terminal or complete Git setup.
                pause
                exit /b 1
            )
        ) else (
            echo.
            echo Git is required to use GitSession. Exiting.
            pause
            exit /b 1
        )
    )
)

:: Check for GitHub CLI dependency
where gh >nul 2>&1
if errorlevel 1 (
    if exist "C:\Program Files\GitHub CLI\gh.exe" (
        set "PATH=!PATH!;C:\Program Files\GitHub CLI"
    ) else if exist "%LOCALAPPDATA%\Programs\GitHub CLI\gh.exe" (
        set "PATH=!PATH!;%LOCALAPPDATA%\Programs\GitHub CLI"
    ) else (
        echo ============================================================
        echo [WARNING] GitHub CLI is required but not found in PATH.
        echo ============================================================
        echo.
        set /p "INSTALL_GH=Would you like to install GitHub CLI via Winget now? [Y/N]: "
        if /i "!INSTALL_GH!"=="Y" (
            echo.
            echo Installing GitHub CLI via Winget...
            winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
            if exist "C:\Program Files\GitHub CLI" set "PATH=!PATH!;C:\Program Files\GitHub CLI"
            if exist "%LOCALAPPDATA%\Programs\GitHub CLI" set "PATH=!PATH!;%LOCALAPPDATA%\Programs\GitHub CLI"
            where gh >nul 2>&1
            if errorlevel 1 (
                echo.
                echo [ERROR] GitHub CLI installation completed but gh is not in current PATH.
                echo Please restart your terminal or complete GitHub CLI setup.
                pause
                exit /b 1
            )
        ) else (
            echo.
            echo GitHub CLI is required to use GitSession. Exiting.
            pause
            exit /b 1
        )
    )
)

:: Locate GitSession.ps1 engine
set "PS_SCRIPT=%GITSESSION_DIR%GitSession.ps1"
if not exist "%PS_SCRIPT%" (
    echo [ERROR] GitSession.ps1 was not found in:
    echo "%GITSESSION_DIR%"
    pause
    exit /b 1
)

:: Launch PowerShell engine with ExecutionPolicy Bypass
:: Priority: explicit CLI args > caller GITSESSION_WORKSPACE env var > settings.json > DEFAULT_WORKSPACE
if not "%~1"=="" goto :launch_with_args

if not "%GITSESSION_WORKSPACE%"=="" (
    if "!GITSESSION_WORKSPACE:~-1!"=="\" set "GITSESSION_WORKSPACE=!GITSESSION_WORKSPACE:~0,-1!"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Workspace "!GITSESSION_WORKSPACE!"
    exit /b !ERRORLEVEL!
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -DefaultWorkspace "%DEFAULT_WORKSPACE%"
exit /b %ERRORLEVEL%

:launch_with_args
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%
