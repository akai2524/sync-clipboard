@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-AutomaticFirewall.ps1" -Action Restore
