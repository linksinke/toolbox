@echo off
chcp 65001 >nul
echo 正在创建项目目录结构...

:: 使用 if not exist 判断，避免目录已存在时弹出烦人的报错提示
if not exist "00-公共目录" mkdir "00-公共目录"
if not exist "01-项目需求" mkdir "01-项目需求"
if not exist "02-备份文件" mkdir "02-备份文件"
if not exist "03-工作代码" mkdir "03-工作代码"

echo 目录创建完成！
pause