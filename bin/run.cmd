@echo off
rem Windows entry point, the cmd.exe twin of bin/run.sh.
rem Kimi Code starts hooks with `shell: true`, so on Windows the command line is
rem handed to cmd.exe and a .sh file cannot run. This script picks the prebuilt
rem .exe for this machine instead. There is no compile fallback: Windows has no
rem cc by default, so a missing prebuilt fails open with exit code 0, exactly
rem like the POSIX dispatcher does.
rem
rem Usage: run.cmd <tool> [args...]   e.g.  run.cmd secret_guard fingerprint
setlocal EnableExtensions

if "%~1"=="" (
  echo run.cmd: missing tool name ^(cbm_nudge^|secret_guard^) 1>&2
  exit /b 0
)

set "ROOT=%~dp0.."
set "TOOL=%~1"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  set "PLAT=windows-arm64"
) else (
  set "PLAT=windows-x86_64"
)

set "BIN=%ROOT%\bin\prebuilt\%PLAT%\%TOOL%.exe"
if not exist "%BIN%" (
  echo run.cmd: no prebuilt for %PLAT% at %BIN% 1>&2
  exit /b 0
)

rem The tool name is argument 1 and must not be forwarded: cbm_nudge reads stdin
rem and secret_guard takes an optional mode as its own first argument.
"%BIN%" %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
