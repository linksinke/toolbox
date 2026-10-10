@echo off
setlocal EnableExtensions
title 输入法候选栏修复

rem ============================================================================
rem  输入法候选栏修复 - 启动入口
rem  实际逻辑：fix-ime-candidate.ps1
rem  用法：
rem    双击本文件          -> 中文菜单
rem    fix-ime-candidate.bat 1  -> 自动修复
rem    fix-ime-candidate.bat 2  -> 新版策略
rem    fix-ime-candidate.bat 3  -> 旧版兼容
rem ============================================================================

rem 进入脚本所在目录
cd /d "%~dp0"
if errorlevel 1 (
  echo [错误] 无法进入脚本所在目录。
  echo 请把整个文件夹放到本地磁盘后再试。
  pause
  exit /b 1
)

rem 检查本机是否有 Windows PowerShell（避免双击后毫无反应）
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo.
  echo ========================================================
  echo  [错误] 本机未找到 Windows PowerShell
  echo ========================================================
  echo  本修复工具需要 PowerShell 才能运行。
  echo  请先安装/修复 Windows PowerShell 后再双击本脚本。
  echo  也可在开始菜单搜索“Windows PowerShell”确认是否可用。
  echo ========================================================
  echo.
  pause
  exit /b 9009
)

rem 再探测一次能否启动
"%PS%" -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 (
  echo.
  echo [错误] PowerShell 无法启动，请修复系统组件后再试。
  echo.
  pause
  exit /b 9009
)

rem 无参数：打开中文菜单
if "%~1"=="" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-ime-candidate.ps1" -ShowMenu
  exit /b %ERRORLEVEL%
)

rem 命令行快捷：0/1/2/3
if "%~1"=="0" exit /b 0
if "%~1"=="1" set "MODE=Auto" & goto RUN
if "%~1"=="2" set "MODE=New" & goto RUN
if "%~1"=="3" set "MODE=Old" & goto RUN

echo [错误] 无效选项：%~1
echo 请使用：0=退出  1=自动  2=新版  3=旧版
pause
exit /b 1

:RUN
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-ime-candidate.ps1" -Mode %MODE%
exit /b %ERRORLEVEL%
