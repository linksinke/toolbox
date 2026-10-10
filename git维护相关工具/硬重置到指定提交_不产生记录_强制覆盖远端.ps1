# =============================================================================
# 脚本：硬重置到指定提交_不产生记录_强制覆盖远端.ps1
# 作用：reset --hard 到目标提交（不产生新提交），再 push --force-with-lease 覆盖远端
# 用法：直接运行；或 .\xxx.ps1 <提交哈希>
# 流程：初始化 → 仓库上下文 → 列出提交 → 输入目标 → 校验 → 确认 YES → 执行
# =============================================================================
param(
  [Parameter(Position = 0, Mandatory = $false)]
  [string]$Commit   # 可选：命令行预填的目标提交（哈希或相对引用）
)

$ErrorActionPreference = "Stop"
$ListCount = 20   # 列表默认展示的提交条数
# ---------------------------------------------------------------------------
# 工具函数（本脚本自包含）
# ---------------------------------------------------------------------------

# 将控制台输出编码设为 UTF-8，减少中文提交说明乱码
function Initialize-GitUtf8Console {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [Console]::OutputEncoding = $utf8
  $global:OutputEncoding = $utf8
  try { chcp 65001 | Out-Null } catch { }
}

# 把 git 原始字节解码为文本：优先 UTF-8，失败或出现替换符时回退 GBK
function Convert-GitBytesToText {
  param([byte[]]$Bytes)
  if (-not $Bytes -or $Bytes.Length -eq 0) { return "" }
  $utf8Strict = New-Object System.Text.UTF8Encoding $false, $true
  try {
    $text = $utf8Strict.GetString($Bytes)
    if ($text -notmatch [char]0xFFFD) { return $text }
  } catch { }
  return [System.Text.Encoding]::GetEncoding(936).GetString($Bytes)
}

# 运行 git 命令并返回 ExitCode / Text / Lines / StdErr
# 说明：不用「git | Select-Object」后的 $LASTEXITCODE（管道后常变成 -1，会误判失败）
function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory = (Get-Location).Path
  )
  $gitCmd = Get-Command git -ErrorAction Stop
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $gitCmd.Source
  $psi.Arguments = (
    $Arguments | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"' } else { $_ }
    }
  ) -join ' '
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  # Latin1 按字节 1:1 读入，避免 PowerShell 过早按错误代码页解码
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $psi.StandardOutputEncoding = $latin1
  $psi.StandardErrorEncoding = $latin1
  $proc = [System.Diagnostics.Process]::Start($psi)
  $rawOut = $proc.StandardOutput.ReadToEnd()
  $rawErr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $text = Convert-GitBytesToText -Bytes ($latin1.GetBytes($rawOut))
  $errText = Convert-GitBytesToText -Bytes ($latin1.GetBytes($rawErr))
  $lines = @()
  if (-not [string]::IsNullOrEmpty($text)) {
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })
  }
  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
    Text     = $text
    Lines    = $lines
    StdErr   = $errText
  }
}

# 运行 git，成功时返回输出行数组；失败返回空数组
function Get-GitLines {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $r = Invoke-Git -Arguments $Arguments
  if ($r.ExitCode -ne 0) { return @() }
  return @($r.Lines)
}

# 从起始目录向上查找含 .git 的仓库根目录
function Find-GitRepoRoot {
  param([string]$StartDir)
  $dir = $StartDir
  while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir ".git")) { return $dir }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  return $null
}

# 打印提示后 pause，再按指定退出码结束脚本
function Exit-WithPause {
  param(
    [int]$Code = 0,
    [string]$Message = "",
    [ConsoleColor]$Color = [ConsoleColor]::Yellow
  )
  if ($Message) { Write-Host $Message -ForegroundColor $Color }
  pause
  exit $Code
}

# 解析仓库上下文：仓库根、当前分支、origin 地址、短 HEAD；失败则退出
function Get-GitRepoContext {
  param([string]$ScriptPath)
  $scriptDir = Split-Path -Parent $ScriptPath
  $repoRoot = Find-GitRepoRoot -StartDir $scriptDir
  if (-not $repoRoot) {
    Exit-WithPause -Code 1 -Message "未找到 git 仓库（已从脚本目录向上查找）：$scriptDir" -Color Red
  }
  Set-Location $repoRoot
  $branch = (Get-GitLines @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1)
  if (-not $branch) { $branch = "" }
  $branch = $branch.Trim()
  if (-not $branch -or $branch -eq "HEAD") {
    Exit-WithPause -Code 1 -Message "当前处于游离 HEAD，请先切换到目标分支（如 main）。" -Color Red
  }
  $remote = "origin"
  $remoteUrl = (Get-GitLines @('remote', 'get-url', $remote) | Select-Object -First 1)
  if (-not $remoteUrl) {
    Exit-WithPause -Code 1 -Message "未找到远端 $remote，无法推送。" -Color Red
  }
  $remoteUrl = $remoteUrl.Trim()
  $head = (Get-GitLines @('rev-parse', '--short', 'HEAD') | Select-Object -First 1)
  if (-not $head) { $head = "" }
  $head = $head.Trim()
  return [pscustomobject]@{
    RepoRoot  = $repoRoot
    Branch    = $branch
    Remote    = $remote
    RemoteUrl = $remoteUrl
    HeadShort = $head
  }
}

# 打印仓库 / 分支 / 远端 / HEAD 摘要
function Show-RepoContext {
  param($Context)
  Write-Host ""
  Write-Host "仓库    : $($Context.RepoRoot)" -ForegroundColor Cyan
  Write-Host "分支    : $($Context.Branch)"
  Write-Host "远端    : $($Context.Remote) ($($Context.RemoteUrl))"
  Write-Host "当前 HEAD: $($Context.HeadShort)"
  Write-Host ""
}

# 列出最近 N 条提交（哈希/日期/说明），并返回第一条哈希供提示示例
function Show-RecentCommits {
  param([int]$Count = 20)
  $logLines = @(Get-GitLines @(
      '-c', 'i18n.logOutputEncoding=utf-8',
      'log', '-n', "$Count",
      '--format=%h%x09%s%x09%ci'
    ))
  if ($logLines.Count -eq 0) {
    Exit-WithPause -Code 1 -Message "当前分支没有可展示的提交记录。" -Color Red
  }
  $exampleHash = $null
  Write-Host ("最近 {0} 条提交（新 → 旧）：" -f $logLines.Count) -ForegroundColor Cyan
  Write-Host ("{0,-10} {1,-20} {2}" -f "哈希", "日期", "说明")
  Write-Host ("-" * 72)
  foreach ($line in $logLines) {
    $parts = $line -split "`t", 3
    if ($parts.Count -lt 2) { continue }
    $hash = $parts[0].Trim()
    $subject = $parts[1].Trim()
    $date = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
    if ($date.Length -gt 19) { $date = $date.Substring(0, 19) }
    if (-not $exampleHash) { $exampleHash = $hash }
    Write-Host ("{0,-10} {1,-20} {2}" -f $hash, $date, $subject)
  }
  return $exampleHash
}

# 交互读取目标提交：支持哈希或相对引用；留空且无默认值则取消
function Read-CommitInput {
  param(
    [string]$DefaultCommit = "",
    [string]$Prompt = "请输入目标提交",
    [string]$ExampleHash = "",
    [string]$RelativeExample = "HEAD~1"
  )
  Write-Host ""
  Write-Host "提示：" -ForegroundColor Yellow
  if ($ExampleHash) {
    Write-Host "  - 输入上表中的「哈希」（短/完整均可），例如：$ExampleHash"
  }
  Write-Host "  - 也可输入相对引用，例如：$RelativeExample"
  Write-Host "  - 直接回车（留空）= 取消，不执行任何操作"
  if (-not [string]::IsNullOrWhiteSpace($DefaultCommit)) {
    Write-Host "  - 命令行已传入默认值：$DefaultCommit（可直接回车采用，或改输其他）" -ForegroundColor DarkYellow
  }
  Write-Host ""
  $label = $Prompt
  if (-not [string]::IsNullOrWhiteSpace($DefaultCommit)) {
    $label = "$Prompt（默认：$DefaultCommit）"
  }
  $inputValue = Read-Host $label
  if ([string]::IsNullOrWhiteSpace($inputValue)) {
    if (-not [string]::IsNullOrWhiteSpace($DefaultCommit)) {
      Write-Host "采用命令行默认值：$($DefaultCommit.Trim())" -ForegroundColor DarkYellow
      return $DefaultCommit.Trim()
    }
    Exit-WithPause -Code 0 -Message "未输入目标提交，已取消。" -Color Yellow
  }
  return $inputValue.Trim()
}

# 将用户输入解析为完整 commit SHA；无法解析时返回 $null
function Resolve-CommitObject {
  param([Parameter(Mandatory = $true)][string]$InputRef)
  foreach ($spec in @(($InputRef + '^{commit}'), $InputRef)) {
    $lines = @(Get-GitLines @('rev-parse', '--verify', $spec))
    if ($lines.Count -gt 0 -and $lines[0]) {
      return $lines[0].Trim()
    }
  }
  return $null
}

# 判断指定提交是否在当前 HEAD 历史中（是自身祖先也算通过）
function Test-CommitAncestorOfHead {
  param(
    [Parameter(Mandatory = $true)][string]$Commit,
    [string]$WorkingDirectory = (Get-Location).Path
  )
  $r = Invoke-Git -Arguments @('merge-base', '--is-ancestor', $Commit, 'HEAD') -WorkingDirectory $WorkingDirectory
  return ($r.ExitCode -eq 0)
}

# 获取提交摘要：短哈希、说明、是否合并提交
function Get-CommitSummary {
  param([Parameter(Mandatory = $true)][string]$Commit)
  $short = (Get-GitLines @('rev-parse', '--short', $Commit) | Select-Object -First 1)
  if ($short) { $short = $short.Trim() } else { $short = $Commit.Substring(0, [Math]::Min(7, $Commit.Length)) }
  $subject = (Get-GitLines @(
      '-c', 'i18n.logOutputEncoding=utf-8',
      'log', '-1', '--format=%s', $Commit
    ) | Select-Object -First 1)
  if ($subject) { $subject = $subject.Trim() } else { $subject = "" }
  $parentLine = (Get-GitLines @('rev-list', '--parents', '-n', '1', $Commit) | Select-Object -First 1)
  $isMerge = $false
  if ($parentLine) {
    $fields = @($parentLine.Trim() -split '\s+')
    $isMerge = $fields.Count -gt 2
  }
  return [pscustomobject]@{
    Full    = $Commit
    Short   = $short
    Subject = $subject
    IsMerge = $isMerge
  }
}

# 操作前备份提醒：回退/重置可能造成历史或文件难以找回
function Show-BackupReminder {
  param([string]$RiskLevel = "高风险")
  Write-Host "【备份提醒 · $RiskLevel】" -ForegroundColor Red
  Write-Host "  操作前请务必自行备份当前仓库，例如：" -ForegroundColor Yellow
  Write-Host "  1) 另存整个项目目录副本"
  Write-Host "  2) 新建备份分支：git branch backup/$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "  3) 确认远端/其它机器仍保留需要的提交"
  Write-Host "  未备份直接继续，可能导致提交或文件丢失后难以找回。" -ForegroundColor Yellow
  Write-Host ""
}

# 二次确认：输入 yes（大小写均可）才继续，否则取消退出
function Confirm-YesToContinue {
  param([string]$Prompt = "已备份且确认执行？请输入 yes（大小写均可；其他任意键取消）")
  $confirm = Read-Host $Prompt
  if ($confirm.Trim().ToUpperInvariant() -ne "YES") {
    Exit-WithPause -Code 0 -Message "已取消。" -Color Yellow
  }
}

# 检查是否存在未提交改动（含已 add 未 commit、已改未暂存）
function Get-GitPorcelainStatus {
  return @(Get-GitLines @('status', '--porcelain'))
}

# 硬重置前：若工作区/暂存区有改动，明确告知 reset --hard 会弄丢，并二次确认
function Assert-UncommittedChangesAcknowledged {
  $lines = @(Get-GitPorcelainStatus)
  if ($lines.Count -eq 0) { return }

  Write-Host ""
  Write-Host "【未提交改动警告】检测到当前有未提交内容：" -ForegroundColor Red
  foreach ($line in $lines) {
    Write-Host "  $line"
  }
  Write-Host ""
  Write-Host "说明：即将执行 git reset --hard，会丢弃：" -ForegroundColor Yellow
  Write-Host "  - 已 git add 但尚未 commit 的暂存内容"
  Write-Host "  - 已修改但未暂存的跟踪文件改动"
  Write-Host "  （未跟踪的新文件一般会保留，除非另行清理）"
  Write-Host "建议先：git stash push -u -m `"backup-before-hard-reset`"  或先提交/拷贝备份。" -ForegroundColor Yellow
  Write-Host ""
  $confirm = Read-Host "仍要丢弃上述未提交改动并继续？请输入 yes（其他任意键取消）"
  if ($confirm.Trim().ToUpperInvariant() -ne "YES") {
    Exit-WithPause -Code 0 -Message "已取消（未提交改动仍保留在工作区）。" -Color Yellow
  }
}

# 操作完成后展示 status 与最近若干条 log，再 pause
function Show-GitStatusTail {
  param([int]$LogCount = 3)
  Write-Host ""
  Write-Host "完成。当前状态：" -ForegroundColor Green
  git status -sb
  git log --oneline --decorate -$LogCount
  Write-Host ""
  pause
}

# ---------------------------------------------------------------------------
# 本脚本专有：计划展示 / 执行
# ---------------------------------------------------------------------------

# 展示即将执行的硬重置步骤与风险提示
function Show-HardResetPlan {
  param($Context, $Target)
  Write-Host ""
  Write-Host "目标提交: $($Target.Short)  $($Target.Subject)" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "将执行：" -ForegroundColor Yellow
  Write-Host "  1) git fetch $($Context.Remote)"
  Write-Host "  2) git reset --hard $($Target.Short)"
  Write-Host "  3) git push --force-with-lease $($Context.Remote) $($Context.Branch)"
  Write-Host ""
  Write-Host "警告：目标提交之后的提交会从本分支历史中移除，远端 $($Context.Branch) 也会被强制改写。" -ForegroundColor Red
  Write-Host ""
}

# 执行：fetch → reset --hard → push --force-with-lease
function Invoke-HardResetAndForcePush {
  param($Context, $Target)
  Write-Host ""
  Write-Host "==> fetch..." -ForegroundColor Cyan
  $fetch = Invoke-Git -Arguments @('fetch', $Context.Remote) -WorkingDirectory $Context.RepoRoot
  if ($fetch.ExitCode -ne 0) {
    Exit-WithPause -Code 1 -Message "fetch 失败。" -Color Red
  }
  Write-Host "==> reset --hard $($Target.Short) ..." -ForegroundColor Cyan
  $reset = Invoke-Git -Arguments @('reset', '--hard', $Target.Full) -WorkingDirectory $Context.RepoRoot
  if ($reset.ExitCode -ne 0) {
    Exit-WithPause -Code 1 -Message "reset 失败。" -Color Red
  }
  Write-Host "==> push --force-with-lease ..." -ForegroundColor Cyan
  $push = Invoke-Git -Arguments @('push', '--force-with-lease', $Context.Remote, $Context.Branch) -WorkingDirectory $Context.RepoRoot
  if ($push.ExitCode -ne 0) {
    Exit-WithPause -Code 1 -Message "强制推送失败。本地已 reset，可稍后手动 push --force-with-lease。" -Color Red
  }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
Initialize-GitUtf8Console
$ctx = Get-GitRepoContext -ScriptPath $MyInvocation.MyCommand.Path
Show-RepoContext -Context $ctx
Show-BackupReminder -RiskLevel "高风险（改写历史并强制覆盖远端）"
Write-Host "说明：本脚本会硬重置到目标提交（不产生新记录），并强制覆盖远端。" -ForegroundColor DarkYellow
Write-Host "      若只需撤销某一个提交且保留历史，请用：还原指定提交_产生记录_正常推送.ps1" -ForegroundColor DarkYellow
Write-Host ""
$exampleHash = Show-RecentCommits -Count $ListCount
$inputRef = Read-CommitInput -DefaultCommit $Commit -Prompt "请输入目标提交" -ExampleHash $exampleHash -RelativeExample "HEAD~1"
$fullSha = Resolve-CommitObject -InputRef $inputRef
if (-not $fullSha) {
  Exit-WithPause -Code 1 -Message "无法解析提交：$inputRef" -Color Red
}
if (-not (Test-CommitAncestorOfHead -Commit $fullSha -WorkingDirectory $ctx.RepoRoot)) {
  Exit-WithPause -Code 1 -Message "提交 $inputRef 不在当前分支 $($ctx.Branch) 的历史中，拒绝执行。" -Color Red
}
$target = Get-CommitSummary -Commit $fullSha
Show-HardResetPlan -Context $ctx -Target $target
Assert-UncommittedChangesAcknowledged
Confirm-YesToContinue
Invoke-HardResetAndForcePush -Context $ctx -Target $target
Show-GitStatusTail -LogCount 3