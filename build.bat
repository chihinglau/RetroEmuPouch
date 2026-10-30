@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

rem ===================================================================
rem  GamePouch (趣玩匣) one-click Android build
rem
rem  Usage (double-click or run from a terminal):
rem    build.bat              -> release APK (default)
rem    build.bat debug        -> debug APK
rem    build.bat install      -> debug APK + adb install to the device
rem    build.bat release nopause -> no "press any key" prompt (CI / scripts)
rem
rem  Everything is local: the toolchain lives in .tools (junctions to the
rem  shared SDK/Flutter/JDK). No system-wide installation required.
rem ===================================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "MODE=release"
set "DO_INSTALL=0"
set "NOPAUSE=0"
set "FLAVOR=community"
if /i "%~1"=="debug"   set "MODE=debug"
if /i "%~1"=="install" ( set "MODE=debug" & set "DO_INSTALL=1" )
rem flavor is the 2nd or 3rd positional arg; accept "store"/"community"
if /i "%~2"=="store"    set "FLAVOR=store"
if /i "%~2"=="community" set "FLAVOR=community"
if /i "%~3"=="store"    set "FLAVOR=store"
if /i "%~3"=="community" set "FLAVOR=community"
if /i "%~1"=="store"    set "FLAVOR=store"
if /i "%~1"=="community" set "FLAVOR=community"
if /i "%~2"=="nopause" set "NOPAUSE=1"
if /i "%~1"=="nopause" set "NOPAUSE=1"

set "PS=powershell.exe -NoProfile -ExecutionPolicy Bypass"

echo.
echo ================= GamePouch one-click build =================
echo   project : %ROOT%
echo   mode    : %MODE%
echo   flavor  : %FLAVOR%
echo.

rem ---------- 1. toolchain ----------
if not exist "%ROOT%\.tools\flutter\bin\flutter.bat" (
    echo [1/3] Preparing local toolchain ^(first run, creates junctions^)...
    %PS% -File "%ROOT%\scripts\setup-env.ps1"
    if errorlevel 1 goto :fail
) else (
    echo [1/3] Local toolchain already present: .tools
)

if not exist "%ROOT%\.tools\flutter\bin\flutter.bat" (
    echo [ERROR] flutter not found under .tools\flutter
    goto :fail
)

rem ---------- 2. build ----------
echo.
echo [2/3] Building APK ^(this takes a few minutes on a cold cache^)...
if /i "%MODE%"=="debug" (
    %PS% -File "%ROOT%\scripts\build-apk.ps1" -DebugBuild -Flavor %FLAVOR%
) else (
    %PS% -File "%ROOT%\scripts\build-apk.ps1" -Flavor %FLAVOR%
)
if errorlevel 1 goto :fail

rem ---------- 3. result ----------
set "OUTDIR=%ROOT%\app\build\app\outputs\flutter-apk"
echo.
echo [3/3] Result
if not exist "%OUTDIR%" (
    echo [ERROR] output directory missing: %OUTDIR%
    goto :fail
)
set "FOUND=0"
for /f "delims=" %%F in ('dir /b /a:-d "%OUTDIR%\app-%FLAVOR%-*.apk" 2^>nul') do (
    set "FOUND=1"
    for %%S in ("%OUTDIR%\%%F") do echo   %%F   %%~zS bytes
    echo   %OUTDIR%\%%F
)
if "%FOUND%"=="0" (
    echo [ERROR] no APK produced for flavor %FLAVOR%
    goto :fail
)

rem ---------- 4. optional install ----------
if "%DO_INSTALL%"=="1" (
    echo.
    echo Installing to device...
    for /f "delims=" %%F in ('dir /b /a:-d "%OUTDIR%\app-%FLAVOR%-*.apk" 2^>nul') do (
        "%ROOT%\.tools\android-sdk\platform-tools\adb.exe" install -r -t "%OUTDIR%\%%F"
        if errorlevel 1 goto :fail
    )
)

echo.
echo [OK] Build succeeded.
echo.
if "%NOPAUSE%"=="1" exit /b 0
pause
exit /b 0

:fail
echo.
echo [FAILED] See build-apk.log in the project root for details.
echo.
if "%NOPAUSE%"=="1" exit /b 1
pause
exit /b 1
