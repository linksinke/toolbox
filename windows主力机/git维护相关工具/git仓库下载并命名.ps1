# =============================================================================
# 脚本：git仓库下载并命名.ps1
# 作用：输入 git 地址（HTTP / HTTPS / SSH），带进度克隆到本地，
#       并按「仓库末段名 + 年月日时分」命名目录
# 用法：直接运行按提示输入；或 .\xxx.ps1 <git地址> [保存目录]
# 命名：https://github.com/owner/repo.git
#       → repo.git.202610121455
# 流程：初始化 → 校验 git → 解析地址/命名 → 确定保存目录 → 克隆(带进度) → 校验/收尾
# =============================================================================
param(
  [Parameter(Position = 0, Mandatory = $false)]
  [string]$GitUrl,        # 可选：命令行预填的远程地址

  [Parameter(Position = 1, Mandatory = $false)]
  [string]$TargetParent   # 可选：克隆父目录；省略则默认脚本所在目录（可交互改）
)

$ErrorActionPreference = "Stop"
$HeartbeatSeconds = 8   # 克隆过程无新输出超过该秒数时打印「仍在克隆中」心跳

# ---------------------------------------------------------------------------
# 工具函数（本脚本自包含）
# ---------------------------------------------------------------------------

# 将控制台输出编码设为 UTF-8，减少中文提示乱码
function Initialize-ConsoleUtf8 {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [Console]::OutputEncoding = $utf8
  $global:OutputEncoding = $utf8
  try { chcp 65001 | Out-Null } catch { }
}

# 打印提示后 pause，再按指定退出码结束脚本
function Exit-WithPause {
  param(
    [int]$Code = 0,
    [string]$Message = "",
    [ConsoleColor]$Color = [ConsoleColor]::Yellow
  )
  if ($Message) { Write-Host $Message -ForegroundColor $Color }
  Write-Host ""
  pause
  exit $Code
}

# 粗判是否像有效的 git 远程地址（HTTP / HTTPS / git:// / SSH）
function Test-LooksLikeGitUrl {
  param([string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  $u = $Url.Trim()

  if ($u -match '^https?://') { return $true }
  if ($u -match '^git://') { return $true }
  if ($u -match '^ssh://') { return $true }
  # SSH 简写：git@host:owner/repo.git
  if ($u -match '^[^@/\s]+@[^:\s]+:.+\.git$') { return $true }
  if ($u -match '^[^@/\s]+@[^:\s]+:.+/') { return $true }
  return $false
}

# 从远程地址解析仓库末段名（URL 自带 .git 则保留）
# 例：https://github.com/owner/repo.git → repo.git
#     git@github.com:owner/repo.git    → repo.git
function Get-RepoBaseNameFromUrl {
  param([Parameter(Mandatory = $true)][string]$Url)

  $u = $Url.Trim()
  if ([string]::IsNullOrWhiteSpace($u)) { return $null }

  # 去掉查询串 / 片段 / 尾部斜杠，避免干扰末段解析
  $u = $u -replace '[?#].*$', ''
  $u = $u.TrimEnd('/')

  $path = $null

  # ssh://git@host/owner/repo.git
  if ($u -match '^ssh://[^/]+/(.+)$') {
    $path = $Matches[1]
  }
  # git@host:owner/repo.git
  elseif ($u -match '^[^@/\s]+@[^:\s]+:(.+)$') {
    $path = $Matches[1]
  }
  # http(s)://host/owner/repo.git
  elseif ($u -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    try {
      $uri = [Uri]$u
      if (-not $uri.AbsolutePath -or $uri.AbsolutePath -eq '/') { return $null }
      $path = $uri.AbsolutePath.TrimStart('/')
    }
    catch {
      return $null
    }
  }
  else {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($path)) { return $null }

  $segments = @($path -split '/' | Where-Object { $_ -ne '' })
  if ($segments.Count -eq 0) { return $null }

  $name = $segments[-1]
  if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '.git') { return $null }

  # Windows 目录名非法字符
  if ($name -match '[\\/:*?"<>|]') { return $null }

  return $name
}

# 生成带时间戳的本地目录名：{末段名}.{yyyyMMddHHmm}
function New-CloneFolderName {
  param([Parameter(Mandatory = $true)][string]$BaseName)

  $stamp = Get-Date -Format "yyyyMMddHHmm"
  return ("{0}.{1}" -f $BaseName, $stamp)
}

# 转义单个参数，供 ProcessStartInfo.Arguments 拼接（含空格/引号时加引号）
function ConvertTo-ProcessArgument {
  param([string]$Value)

  if ($null -eq $Value) { return '""' }
  if ($Value -match '[\s"]') {
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
  }
  return $Value
}

# 交互或参数得到远程地址，并做格式 / 仓库名校验；失败则退出
function Resolve-CloneGitUrl {
  param([string]$InputUrl)

  if ([string]::IsNullOrWhiteSpace($InputUrl)) {
    Write-Host "请输入 Git 仓库地址（支持 HTTP / HTTPS / SSH）：" -ForegroundColor Yellow
    Write-Host "  例：https://github.com/owner/repo.git"
    Write-Host "  例：git@github.com:owner/repo.git"
    Write-Host ""
    $InputUrl = Read-Host "Git 地址"
  }

  $url = $InputUrl.Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($url)) {
    Exit-WithPause -Code 1 -Message "未输入地址，已取消。" -Color Red
  }
  if (-not (Test-LooksLikeGitUrl -Url $url)) {
    Exit-WithPause -Code 1 -Message "地址格式不像有效的 git 远程地址：$url" -Color Red
  }

  $baseName = Get-RepoBaseNameFromUrl -Url $url
  if (-not $baseName) {
    Exit-WithPause -Code 1 -Message "无法从地址解析仓库名：$url" -Color Red
  }

  return [pscustomobject]@{
    Url      = $url
    BaseName = $baseName
  }
}

# 交互或参数得到保存父目录，规范化为绝对路径；不存在则创建
function Resolve-CloneParentDirectory {
  param(
    [string]$InputParent,
    [Parameter(Mandatory = $true)][string]$DefaultParent
  )

  if ([string]::IsNullOrWhiteSpace($InputParent)) {
    Write-Host "默认保存到脚本所在目录：" -ForegroundColor DarkGray
    Write-Host "  $DefaultParent"
    Write-Host "直接回车使用默认；或输入其他目录路径：" -ForegroundColor Yellow
    $inputParent = Read-Host "保存目录"
    if ([string]::IsNullOrWhiteSpace($inputParent)) {
      $InputParent = $DefaultParent
    }
    else {
      $InputParent = $inputParent.Trim().Trim('"').Trim("'")
    }
  }

  try {
    $parent = [System.IO.Path]::GetFullPath($InputParent)
  }
  catch {
    Exit-WithPause -Code 1 -Message "保存目录路径无效：$InputParent" -Color Red
  }

  if (-not (Test-Path -LiteralPath $parent)) {
    try {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    catch {
      Exit-WithPause -Code 1 -Message "无法创建保存目录：$parent`n$($_.Exception.Message)" -Color Red
    }
  }

  return $parent
}

# 克隆失败时尽量删除不完整目录，避免残留半拉仓库
function Remove-IncompleteCloneDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return }

  try {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    Write-Host "已清理不完整目录：$Path" -ForegroundColor DarkYellow
  }
  catch {
    Write-Host "克隆失败，且无法自动删除残留目录，请手动检查：$Path" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------------------
# 带进度克隆
# 说明：
#   - git 进度写在 stderr，且用 \r 同行刷新；PowerShell 直接 & git 时经常看不见
#   - 这里用 Process 重定向 stderr，异步读字节，把 \r / \n 转成可见输出
#   - 长时间无输出时打印心跳，避免误以为卡死（连 GitHub 慢时很常见）
# ---------------------------------------------------------------------------
function Invoke-GitCloneWithProgress {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Destination,
    [int]$HeartbeatSeconds = 8
  )

  $gitCmd = Get-Command git -ErrorAction Stop

  # --- 启动 git clone（重定向 stdout/stderr，由本函数负责打印）---
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $gitCmd.Source
  $psi.Arguments = @(
    'clone',
    '--progress',   # 强制输出进度（即使 stderr 不是 TTY）
    '--verbose',
    '--',
    (ConvertTo-ProcessArgument $Url),
    (ConvertTo-ProcessArgument $Destination)
  ) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  # stdout 异步读完即可（clone 主要信息在 stderr）
  $outTask = $proc.StandardOutput.ReadToEndAsync()

  # stderr：按字节异步读，才能捕获 \r 进度刷新（ReadLine 会丢进度）
  $errStream = $proc.StandardError.BaseStream
  $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
  $byteBuf = New-Object byte[] 1024
  $charBuf = New-Object char[] 1024
  $lineBuf = New-Object System.Text.StringBuilder
  $lastPaint = Get-Date
  $lastActivity = Get-Date
  $onSameLine = $false
  $stderrDone = $false
  $readTask = $errStream.ReadAsync($byteBuf, 0, $byteBuf.Length)

  while (-not $stderrDone) {
    # Wait(超时) 避免 Peek/同步 Read 卡住，才能穿插心跳
    if ($readTask.Wait(80)) {
      $n = $readTask.Result
      if ($n -le 0) {
        $stderrDone = $true
        break
      }

      $charCount = $decoder.GetChars($byteBuf, 0, $n, $charBuf, 0)
      for ($i = 0; $i -lt $charCount; $i++) {
        $ch = $charBuf[$i]
        if ($ch -eq "`r" -or $ch -eq "`n") {
          $text = $lineBuf.ToString()
          [void]$lineBuf.Clear()
          if ([string]::IsNullOrWhiteSpace($text)) { continue }

          $lastActivity = Get-Date
          $lastPaint = Get-Date

          if ($ch -eq "`r") {
            # 同行刷新：Receiving objects:  45% ...
            Write-Host ("`r" + $text + "          ") -NoNewline
            $onSameLine = $true
          }
          else {
            if ($onSameLine) { Write-Host "" }
            Write-Host $text
            $onSameLine = $false
          }
        }
        else {
          [void]$lineBuf.Append($ch)
        }
      }

      $readTask = $errStream.ReadAsync($byteBuf, 0, $byteBuf.Length)
    }

    # 心跳：无新 stderr 输出超过阈值则提示仍在等待
    $idle = ((Get-Date) - $lastActivity).TotalSeconds
    if ($idle -ge $HeartbeatSeconds -and ((Get-Date) - $lastPaint).TotalSeconds -ge $HeartbeatSeconds) {
      if ($onSameLine) { Write-Host ""; $onSameLine = $false }
      $elapsed = [int]((Get-Date) - $proc.StartTime).TotalSeconds
      Write-Host ("…仍在克隆中，已等待 {0}s（网络较慢时属正常）" -f $elapsed) -ForegroundColor DarkYellow
      $lastPaint = Get-Date
    }

    # 进程已退出且当前读完成且无更多数据 → 结束循环
    if ($proc.HasExited -and $readTask.IsCompleted) {
      try {
        if ($readTask.Result -le 0) { $stderrDone = $true }
      }
      catch {
        $stderrDone = $true
      }
    }
  }

  # 刷出缓冲区残余
  if ($lineBuf.Length -gt 0) {
    if ($onSameLine) { Write-Host "" }
    Write-Host $lineBuf.ToString()
    $onSameLine = $false
  }
  if ($onSameLine) { Write-Host "" }

  # 打印 stdout（通常很少）
  $stdoutText = $outTask.Result
  if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
    foreach ($line in ($stdoutText -split "`r?`n")) {
      if ($line) { Write-Host $line }
    }
  }

  $proc.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
  }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

# --- 0) 初始化 ---
Initialize-ConsoleUtf8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Git 仓库下载并命名"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Exit-WithPause -Code 1 -Message "未检测到 git，请先安装 Git for Windows 并确保已加入 PATH。" -Color Red
}

# --- 1) 解析远程地址与本地目录名 ---
$resolved = Resolve-CloneGitUrl -InputUrl $GitUrl
$GitUrl = $resolved.Url
$folderName = New-CloneFolderName -BaseName $resolved.BaseName

# --- 2) 确定保存父目录与完整目标路径 ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetParent = Resolve-CloneParentDirectory -InputParent $TargetParent -DefaultParent $scriptDir
$targetPath = Join-Path $TargetParent $folderName

if (Test-Path -LiteralPath $targetPath) {
  Exit-WithPause -Code 1 -Message "目标目录已存在，请稍后重试（时间戳会变化）：`n  $targetPath" -Color Red
}

Write-Host ""
Write-Host "远程地址 : $GitUrl" -ForegroundColor Cyan
Write-Host "目录命名 : $folderName"
Write-Host "完整路径 : $targetPath"
Write-Host ""
Write-Host "开始克隆（下方为 git 进度输出）..." -ForegroundColor Green
Write-Host "----------------------------------------"

# --- 3) 执行克隆（带进度 + 心跳）---
$cloneFailed = $false
$cloneErrorHint = ""
try {
  $cloneResult = Invoke-GitCloneWithProgress `
    -Url $GitUrl `
    -Destination $targetPath `
    -HeartbeatSeconds $HeartbeatSeconds
  if ($cloneResult.ExitCode -ne 0) {
    $cloneFailed = $true
    $cloneErrorHint = "git clone 退出码：$($cloneResult.ExitCode)"
  }
}
catch {
  $cloneFailed = $true
  $cloneErrorHint = $_.Exception.Message
}

Write-Host "----------------------------------------"

# --- 4) 失败收尾 ---
if ($cloneFailed) {
  Remove-IncompleteCloneDirectory -Path $targetPath
  Write-Host ""
  Write-Host "克隆失败。" -ForegroundColor Red
  Write-Host "常见原因：地址错误、无权限、网络不通、SSH 密钥未配置、仓库不存在。" -ForegroundColor Yellow
  if ($cloneErrorHint) {
    Write-Host "详情：$cloneErrorHint" -ForegroundColor DarkGray
  }
  Exit-WithPause -Code 1 -Message "" -Color Red
}

# --- 5) 成功校验 ---
if (-not (Test-Path -LiteralPath (Join-Path $targetPath ".git"))) {
  Exit-WithPause -Code 1 -Message "克隆后未发现 .git 目录，结果异常：$targetPath" -Color Red
}

Write-Host ""
Write-Host "克隆完成。" -ForegroundColor Green
Write-Host "本地目录：$targetPath"
Write-Host ""
pause
exit 0
