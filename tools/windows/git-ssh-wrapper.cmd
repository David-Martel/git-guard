@echo off
setlocal
node "%~dp0git-ssh-wrapper.js" %*
exit /b %ERRORLEVEL%
