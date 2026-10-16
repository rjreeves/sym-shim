@echo off
rem Installs sym on a machine with nothing else on it: double-click, or run
rem from a terminal. Runs install.ps1 from this folder, bypassing the
rem PowerShell execution policy for that one process only (nothing is
rem changed machine-wide), and adds sym to the user PATH.
rem
rem Needs sym.exe and sym_shim.exe next to this file (or in its parent
rem folder). Extra arguments pass straight through to install.ps1, e.g.
rem   install.cmd -SymHome D:\Sym
rem To install without touching PATH, run install.ps1 directly instead.

echo sym setup
echo ---------
echo Installs sym (default: %%LOCALAPPDATA%%\Sym) and adds it to your user PATH.
echo.

rem A zip from a browser or email marks every extracted file as downloaded,
rem and a "RemoteSigned" policy (common on managed PCs, and set by Group
rem Policy it outranks -ExecutionPolicy Bypass) then refuses to run
rem install.ps1 as "not digitally signed". Clear the mark on the files in
rem THIS folder -- what "right-click > Properties > Unblock" does by hand --
rem using a -Command, which that policy doesn't apply to. The folder goes
rem via an environment variable so no path can break the quoting.
set "SYM_PKG_DIR=%~dp0"
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath $env:SYM_PKG_DIR -File | Unblock-File" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -AddToPath %*
set "rc=%ERRORLEVEL%"

echo.
if "%rc%"=="0" (
  echo Setup complete. Open a new terminal and run: sym
) else (
  echo Setup FAILED with exit code %rc%.
  echo If PowerShell said scripts are disabled or not signed, your administrator's
  echo policy may require signed scripts; the manual steps in docs\USAGE.md step 3
  echo do the same thing without PowerShell.
)

rem Hold the window open only when launched by double-click, so a
rem terminal isn't left waiting on a keypress. A script that runs this via
rem "cmd /c" looks the same as a double-click, so set SYM_NO_PAUSE=1 there.
if not defined SYM_NO_PAUSE echo %cmdcmdline% | find /i "%~nx0" >nul && pause
exit /b %rc%
