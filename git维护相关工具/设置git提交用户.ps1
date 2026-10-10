# 仅设置当前仓库的 Git 提交用户，不影响全局 git config
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

# 与 Git提交的账号 yourname / SSH 公钥备注一致；如需修改只改这两行
$name  = "yourname"
$email = "email@example.com"

if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
  Write-Host "当前目录不是 git 仓库：$repoRoot" -ForegroundColor Red
  pause
  exit 1
}

git config --local user.name  $name
git config --local user.email $email

Write-Host ""
Write-Host "已写入本仓库提交身份（仅 local，不影响全局）：" -ForegroundColor Green
Write-Host ("  user.name  = " + (git config --local user.name))
Write-Host ("  user.email = " + (git config --local user.email))
Write-Host ""
Write-Host "全局仍为（其他仓库继续用这个）：" -ForegroundColor Yellow
Write-Host ("  user.name  = " + (git config --global user.name))
Write-Host ("  user.email = " + (git config --global user.email))
Write-Host ""
Write-Host "验证：之后在本仓库提交会显示为 $name <$email>"
pause
