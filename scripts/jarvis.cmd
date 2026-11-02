@echo off
setlocal EnableExtensions
rem Starts JARVIS from source on Windows. scripts\install-shortcuts.cmd creates two commands that call this:
rem   jarvis        the real app (needs your API key in Settings)     ->  jarvis.cmd real
rem   jarvis-mock   the mock backend: fake replies and a MOCK badge   ->  jarvis.cmd mock
rem It works from any folder. Before starting it brings the checkout up to date, but only when that is
rem safe: on main with no local changes, fast-forward only. Set JARVIS_NO_UPDATE=1 to skip the update.

set "MODE=%~1"
if "%MODE%"=="" set "MODE=real"
if /i "%MODE%"=="real" goto modeok
if /i "%MODE%"=="mock" goto modeok
echo jarvis: unknown mode "%MODE%". Use real or mock. 1>&2
exit /b 2
:modeok

for %%I in ("%~dp0..") do set "REPO=%%~fI"
pushd "%REPO%" || exit /b 1

rem Rust installed with rustup lives in the user's .cargo\bin.
if exist "%USERPROFILE%\.cargo\bin\cargo.exe" set "PATH=%PATH%;%USERPROFILE%\.cargo\bin"
for %%T in (pnpm cargo git) do call :need %%T || goto missing

if "%JARVIS_NO_UPDATE%"=="1" goto noupdate
set "BRANCH="
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set "BRANCH=%%B"
if not "%BRANCH%"=="main" goto notmain
set "DIRTY="
for /f "delims=" %%L in ('git status --porcelain 2^>nul') do set "DIRTY=1"
if defined DIRTY goto dirty
git pull --quiet --ff-only
if errorlevel 1 goto pullfail
echo jarvis: up to date with main.
goto install
:noupdate
echo jarvis: not updating - JARVIS_NO_UPDATE=1.
goto install
:notmain
echo jarvis: on branch '%BRANCH%', not 'main': not updating.
goto install
:dirty
echo jarvis: you have local changes: not updating.
goto install
:pullfail
echo jarvis: could not update - offline? Starting what you have.

:install
call pnpm install --silent
if errorlevel 1 goto installfail
if /i "%MODE%"=="mock" goto mock
echo jarvis: starting JARVIS.
call pnpm tauri dev
goto done
:mock
echo jarvis: starting the MOCK app - fake replies, MOCK badge.
set "VITE_TRANSPORT=mock"
call pnpm tauri dev
:done
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%

:missing
echo jarvis: '%MISSING%' was not found. See "Run it from source" in README.md. 1>&2
popd
exit /b 1

:installfail
echo jarvis: pnpm install failed. Read the message above, fix it, and run jarvis again. 1>&2
popd
exit /b 1

:need
where %1 >nul 2>&1
if errorlevel 1 (
  set "MISSING=%1"
  exit /b 1
)
exit /b 0
