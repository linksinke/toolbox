@echo off
:: 删除空文件夹的批处理脚本
:: 创建日期：2026年10月10日
:: 作者：[您的名字]
:: 版本：1.0
::
:: 功能描述：
:: 该脚本允许用户循环输入根路径，并删除该路径下所有空文件夹。
:: 脚本会由深到浅尝试删除子目录（仅空目录会成功），路径不存在时给出提示。
:: 同时支持 UTF-8 编码与友好的控制台界面设置。

:: 设置控制台编码为UTF-8
chcp 65001 > nul

:: 设置窗口标题
title 删除空文件夹

:: 设置控制台颜色（黑色背景，绿色字体）
color 0a

:input_loop
setlocal

:: 提示用户输入要删除空文件夹的路径
set /p targetDir=请输入要删除空文件夹的根路径: 

:: 检查路径是否存在
if exist "%targetDir%\" (
    :: 列出所有子目录，并逆序排序以先处理最深的子目录
    for /f "delims=" %%d in ('dir /ad /b /s "%targetDir%" ^| sort /r') do (
        :: 尝试删除每个找到的目录，只有空目录会被成功删除
        rd "%%d" 2>nul
    )
) else (
    echo 文件夹 %targetDir% 不存在，请检查路径。
)

endlocal
goto :input_loop
