@echo off
set PATH=C:\Program Files\Git\usr\bin;C:\Program Files\Git\cmd;%PATH%
set MSBUILD="C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
cd /d %~dp0crawl-ref\source\MSVC
%MSBUILD% crawl.vcxproj "-p:Configuration=Debug Console" -p:Platform=x64 -p:WindowsTargetPlatformVersion=10.0.26100.0 -p:PlatformToolset=v143 -m
