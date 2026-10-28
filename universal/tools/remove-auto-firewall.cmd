@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configure-LightClipFirewall.ps1" -Mode RemoveAutomatic
