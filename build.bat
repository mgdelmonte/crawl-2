@echo off
setlocal

set SLN=crawl-ref\source\MSVC\crawl-ref.sln
set OUTDIR=crawl-ref\source

:: Initialize git submodules if needed
git submodule update --init --recursive

:: Find MSBuild via vswhere
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set MSBUILD=%%i

if not defined MSBUILD (
    echo ERROR: MSBuild not found. Make sure Visual Studio is installed.
    exit /b 1
)

echo Using MSBuild: %MSBUILD%

:: Detect installed Windows SDK version
set WINSDK=
for /f "tokens=*" %%d in ('dir /b /o-n "%ProgramFiles(x86)%\Windows Kits\10\Include\"') do (
    if not defined WINSDK set WINSDK=%%d
)
if not defined WINSDK (
    echo ERROR: No Windows 10 SDK found.
    exit /b 1
)
echo Using Windows SDK: %WINSDK%
echo.

:: Add Git's usr/bin to PATH so perl.exe is available to the pre-build step
set "PATH=C:\Program Files\Git\usr\bin;C:\Program Files\Git\cmd;%PATH%"

:: Create release_ver fallback if git describe fails (no tags)
git describe >"%OUTDIR%\util\release_ver" 2>nul
if errorlevel 1 (
    echo 0.32-a>"%OUTDIR%\util\release_ver"
    echo Created fallback release_ver: 0.32-a
)

set RETARGET=/p:WindowsTargetPlatformVersion=%WINSDK% /p:PlatformToolset=v143

:: Build Release Tiles x64
echo ============================================
echo  Building Tiles client (Release x64)
echo ============================================
"%MSBUILD%" "%SLN%" /p:Configuration="Release Tiles" /p:Platform=x64 %RETARGET% /m /v:minimal
if errorlevel 1 (
    echo ERROR: Tiles build failed!
    exit /b 1
)

:: Rename tiles output
if exist "%OUTDIR%\crawl.exe" (
    copy /y "%OUTDIR%\crawl.exe" "%OUTDIR%\tcrawl.exe" >nul
    echo Copied tiles build to %OUTDIR%\tcrawl.exe
)

:: Build Release Console x64
echo.
echo ============================================
echo  Building Console client (Release x64)
echo ============================================
"%MSBUILD%" "%SLN%" /p:Configuration="Release Console" /p:Platform=x64 %RETARGET% /m /v:minimal
if errorlevel 1 (
    echo ERROR: Console build failed!
    exit /b 1
)

:: Rename console output
if exist "%OUTDIR%\crawl.exe" (
    copy /y "%OUTDIR%\crawl.exe" "%OUTDIR%\ccrawl.exe" >nul
    echo Copied console build to %OUTDIR%\ccrawl.exe
)

echo.
echo ============================================
echo  Build complete!
echo  Tiles:   %OUTDIR%\tcrawl.exe
echo  Console: %OUTDIR%\ccrawl.exe
echo ============================================
