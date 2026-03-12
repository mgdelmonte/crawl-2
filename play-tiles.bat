@echo off
setlocal

REM Add Git's usr/bin to PATH for perl (needed by build's pre-build step)
set PATH=C:\Program Files\Git\usr\bin;%PATH%

set MSBUILD="C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
set CONFIG=Debug Tiles
set PLATFORM=x64
set SDK=10.0.26100.0
set TOOLSET=v143
set RCFILE=C:\dev\simple\assist.rc
set SRCDIR=%~dp0crawl-ref\source

cd /d %SRCDIR%\MSVC

echo Building %CONFIG%...
%MSBUILD% crawl.vcxproj "-p:Configuration=%CONFIG%" -p:Platform=%PLATFORM% -p:WindowsTargetPlatformVersion=%SDK% -p:PlatformToolset=%TOOLSET% -m
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)

REM Copy matching DLLs next to crawl.exe
cd /d %SRCDIR%
copy /y contrib\bin\%PLATFORM%\Debug\SDL2.dll . >nul
copy /y contrib\bin\%PLATFORM%\Debug\SDL2_image.dll . >nul
copy /y contrib\bin\%PLATFORM%\Debug\libpng.dll . >nul

start "" crawl.exe -rc "%RCFILE%"
