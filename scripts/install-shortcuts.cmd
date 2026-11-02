@echo off
rem Runs install-shortcuts.ps1 for this one run only (-ExecutionPolicy Bypass applies to this process; it
rem changes no setting on your computer), so the "running scripts is disabled" error does not get in the way.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-shortcuts.ps1" %*
exit /b %ERRORLEVEL%
