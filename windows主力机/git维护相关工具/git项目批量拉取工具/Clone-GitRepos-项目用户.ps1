#requires -Version 5.1
# =============================================================================
# 批量克隆 / 更新 Git 仓库，并切换到指定分支，支持自定义目录名。
# 结构：参数配置 → 初始化 → 校验 → 克隆 / 更新（进度 + 心跳）→ 结果汇总。
# 默认保存到脚本所在目录；可用 -TargetParent 指定父目录。
# 示例：.\Clone-GitRepos-test.ps1 -TargetParent 'D:\repos' -PauseOnExit
# -Depth 1：浅克隆（默认）；-Depth 0：完整历史；-MaxAttempts 3：总共最多尝试 3 次。
# 已有仓库：要求 origin 匹配、工作区干净；只快进更新，不自动合并或丢弃本地改动。
# 失败的临时克隆目录保留供排查；确认不需要后可手动删除。
# =============================================================================
[CmdletBinding()]
param(
    [string]$TargetParent = $PSScriptRoot,
    # 格式：仓库地址,分支名称,自定义文件夹名（字段中不能包含逗号）
    [string[]]$Repositories = @(
        'https://github.com/alibaba/AliSQL.git,AliSQL-5.6-master,AliSQL文件夹',
        'https://github.com/alibaba/MongoShake.git,improve-2.4.16,MongoShake文件夹'
    ),
    [ValidateRange(0, 2147483647)][int]$Depth = 1,
    [ValidateRange(1, 10)][int]$MaxAttempts = 3,
    [ValidateRange(0, 60)][int]$RetryDelaySeconds = 2,
    [ValidateRange(1, 300)][int]$HeartbeatSeconds = 8,
    # 每条 Git 命令的总时限；0 表示不限制。大型仓库可调大。
    [ValidateRange(0, 86400)][int]$CommandTimeoutSeconds = 900,
    [switch]$PauseOnExit
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
function Initialize-ConsoleUtf8 {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try { [Console]::OutputEncoding = $utf8 } catch { }
    $script:OutputEncoding = $utf8
}

# Windows 原生命令行参数转义：只在引号前 / 结尾处理反斜杠，不改普通路径。
function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# 同时异步读取 stdout / stderr，防止管道阻塞；ReadLineAsync 可识别 CR 进度行。
function Invoke-GitCommand {
    param(
        [string[]]$GitArguments,
        [string]$WorkingDirectory,
        [switch]$Quiet
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:GitExecutable
    $psi.Arguments = ($GitArguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    # 批处理不等待隐藏的凭据输入；已有凭据助手 / SSH 配置仍可使用。
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
    $psi.EnvironmentVariables['LC_ALL'] = 'C'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastActivity = 0.0
    $started = $false
    try {
        $started = $proc.Start()
        $outRead = $proc.StandardOutput.ReadLineAsync()
        $errRead = $proc.StandardError.ReadLineAsync()
        while ($null -ne $outRead -or $null -ne $errRead -or -not $proc.HasExited) {
            foreach ($stream in @('out', 'err')) {
                $task = if ($stream -eq 'out') { $outRead } else { $errRead }
                if ($null -ne $task -and $task.IsCompleted) {
                    $line = $task.GetAwaiter().GetResult()
                    if ($null -eq $line) {
                        if ($stream -eq 'out') { $outRead = $null } else { $errRead = $null }
                    } else {
                        if ($stream -eq 'out') {
                            [void]$stdout.AppendLine($line)
                            $outRead = $proc.StandardOutput.ReadLineAsync()
                        } else {
                            [void]$stderr.AppendLine($line)
                            $errRead = $proc.StandardError.ReadLineAsync()
                        }
                        if (-not $Quiet -and $line) { Write-Host $line }
                        $lastActivity = $watch.Elapsed.TotalSeconds
                    }
                }
            }
            if ($CommandTimeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -ge $CommandTimeoutSeconds) {
                throw "Git 命令超过 ${CommandTimeoutSeconds} 秒，请检查网络或调大 -CommandTimeoutSeconds。"
            }
            if (-not $Quiet -and ($watch.Elapsed.TotalSeconds - $lastActivity) -ge $HeartbeatSeconds) {
                Write-Host ("仍在等待 Git，已用时 {0}s ..." -f [int]$watch.Elapsed.TotalSeconds) -ForegroundColor DarkYellow
                $lastActivity = $watch.Elapsed.TotalSeconds
            }
            # 已有输出就继续读取；只有两侧均无可读取输出时才等待。
            if (($null -eq $outRead -or -not $outRead.IsCompleted) -and
                ($null -eq $errRead -or -not $errRead.IsCompleted)) {
                Start-Sleep -Milliseconds 50
            }
        }
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut = $stdout.ToString().TrimEnd()
            StdErr = $stderr.ToString().TrimEnd()
        }
    } finally {
        if ($started -and -not $proc.HasExited) {
            # Windows PowerShell 5.1 没有 Kill(true)，需终止该 Git 的子进程树。
            try {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F 2>&1 | Out-Null
            } catch { }
            try {
                if (-not $proc.HasExited) { $proc.Kill() }
                [void]$proc.WaitForExit(5000)
            } catch {
                Write-Warning "无法完全终止 Git 进程（PID $($proc.Id)），请手动检查。"
            }
        }
        $proc.Dispose()
        $watch.Stop()
    }
}

function Assert-GitSuccess {
    param($Result, [string]$Action)
    if ($Result.ExitCode -ne 0) {
        throw "$Action 失败（退出码 $($Result.ExitCode)）：$($Result.StdErr)"
    }
}

function Test-TransientNetworkError {
    param([string]$Message)
    # 128 是通用致命错误码；只对明确的连接 / 传输错误重试。
    return $Message -match '(?i)connection (was )?reset|failed to connect|could not connect|could not resolve (host|proxy)|timed? out|timeout|recv failure|send failure|remote end hung up|early EOF|HTTP/2 stream|HTTP (502|503|504)|requested URL returned error: (429|502|503|504)'
}

function Invoke-GitNetworkCommand {
    param([string[]]$GitArguments, [string]$WorkingDirectory)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-GitCommand -GitArguments $GitArguments -WorkingDirectory $WorkingDirectory
        if ($result.ExitCode -eq 0) { return $result }
        if ($attempt -ge $MaxAttempts -or -not (Test-TransientNetworkError $result.StdErr)) {
            return $result
        }
        Write-Warning "连接 / 传输失败；准备第 $($attempt + 1)/$MaxAttempts 次尝试。"
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Resolve-RepoConfiguration {
    param([string]$Entry, [string]$ParentDirectory)
    $parts = @($Entry -split ',')
    if ($parts.Count -ne 3) { throw "配置必须有三个字段：地址,分支,文件夹名。实际：$Entry" }
    $url, $branch, $folder = $parts | ForEach-Object { $_.Trim() }
    if (-not $url -or -not $branch -or -not $folder) { throw "配置字段不能为空：$Entry" }
    # 允许常见远程地址，以及本地仓库绝对路径（用于离线镜像）。
    if ($url -notmatch '^(https?|ssh|git|file)://' -and $url -notmatch '^[^@/\s]+@[^:\s]+:.+' -and
        -not ([IO.Path]::IsPathRooted($url) -and (Test-Path -LiteralPath $url -PathType Container))) {
        throw "不支持的仓库地址：$url"
    }
    if ($folder -in @('.', '..') -or $folder -match '[\\/:*?"<>|\x00-\x1f]' -or
        $folder -match '[. ]$' -or $folder -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw "文件夹名无效，必须是单个 Windows 文件夹名称：$folder"
    }
    $check = Invoke-GitCommand -GitArguments @('check-ref-format', '--branch', $branch) -WorkingDirectory $ParentDirectory -Quiet
    Assert-GitSuccess $check '校验分支名'
    # 禁止 Git 的 @{-1} 等历史分支简写，配置必须为明确的分支名称。
    if ($check.StdOut -cne $branch) { throw "请填写明确的分支名：$branch" }
    return [pscustomobject]@{
        Url = $url; Branch = $branch; Folder = $folder
        Path = [IO.Path]::GetFullPath((Join-Path $ParentDirectory $folder))
    }
}

function Get-NormalizedRemote {
    param([string]$Url)
    return ($Url.Trim().TrimEnd('/') -replace '\.git$', '')
}

function Update-ExistingRepository {
    param($Repo)
    if (-not (Test-Path -LiteralPath $Repo.Path -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $Repo.Path '.git'))) {
        throw '目标已存在，但不是独立 Git 工作目录；请检查路径。'
    }
    $root = Invoke-GitCommand @('rev-parse', '--show-toplevel') $Repo.Path -Quiet
    Assert-GitSuccess $root '检查仓库根目录'
    if ([IO.Path]::GetFullPath($root.StdOut) -ine $Repo.Path) { throw '目标路径不是仓库根目录。' }
    $origin = Invoke-GitCommand @('remote', 'get-url', 'origin') $Repo.Path -Quiet
    Assert-GitSuccess $origin '读取 origin'
    if ((Get-NormalizedRemote $origin.StdOut) -cne (Get-NormalizedRemote $Repo.Url)) {
        throw "origin 与配置不一致，跳过。实际：$($origin.StdOut)"
    }
    $status = Invoke-GitCommand @('status', '--porcelain', '--untracked-files=all') $Repo.Path -Quiet
    Assert-GitSuccess $status '检查工作区'
    if ($status.StdOut) { throw '工作区存在未提交或未跟踪文件，请先自行处理后再更新。' }
    foreach ($marker in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer', 'BISECT_LOG')) {
        $markerPath = Invoke-GitCommand @('rev-parse', '--git-path', $marker) $Repo.Path -Quiet
        Assert-GitSuccess $markerPath '检查未完成的 Git 操作'
        $resolvedMarker = $markerPath.StdOut
        if (-not [IO.Path]::IsPathRooted($resolvedMarker)) { $resolvedMarker = Join-Path $Repo.Path $resolvedMarker }
        if (Test-Path -LiteralPath $resolvedMarker) { throw "仓库存在未完成的 Git 操作：$marker" }
    }
    # 明确抓取目标分支；兼容最初以 --depth 1 克隆的单分支仓库。
    $remoteRef = "refs/remotes/origin/$($Repo.Branch)"
    $fetch = Invoke-GitNetworkCommand @('fetch', '--progress', 'origin', "+refs/heads/$($Repo.Branch):$remoteRef") $Repo.Path
    Assert-GitSuccess $fetch '获取目标分支'
    $localRef = "refs/heads/$($Repo.Branch)"
    $exists = Invoke-GitCommand @('show-ref', '--verify', '--quiet', $localRef) $Repo.Path -Quiet
    if ($exists.ExitCode -eq 0) {
        # 在 checkout 之前检查能否快进，避免分叉时改变当前分支。
        $ancestor = Invoke-GitCommand @('merge-base', '--is-ancestor', $localRef, $remoteRef) $Repo.Path -Quiet
        if ($ancestor.ExitCode -ne 0) {
            throw '本地目标分支无法快进到远程（可能有本地提交、历史分叉或浅克隆历史不足），请手动检查。'
        }
        $checkout = Invoke-GitCommand @('checkout', $Repo.Branch) $Repo.Path
        Assert-GitSuccess $checkout '切换目标分支'
    } elseif ($exists.ExitCode -eq 1) {
        $checkout = Invoke-GitCommand @('checkout', '-b', $Repo.Branch, '--track', $remoteRef) $Repo.Path
        Assert-GitSuccess $checkout '创建目标分支'
    } else {
        Assert-GitSuccess $exists '检查本地分支'
    }
    $merge = Invoke-GitCommand @('merge', '--ff-only', $remoteRef) $Repo.Path
    Assert-GitSuccess $merge '快进更新'
    $head = Invoke-GitCommand @('symbolic-ref', '--short', 'HEAD') $Repo.Path -Quiet
    Assert-GitSuccess $head '校验当前分支'
    if ($head.StdOut -cne $Repo.Branch) { throw '更新后分支校验失败。' }
}

function New-ClonedRepository {
    param($Repo, [string]$ParentDirectory)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # 每次使用唯一暂存目录，成功后再改成配置名称；不删除用户已有目录。
        $temporaryPath = Join-Path $ParentDirectory ('.git-clone-' + [guid]::NewGuid().ToString('N'))
        try {
            Write-Host "开始克隆，第 $attempt/$MaxAttempts 次尝试..." -ForegroundColor Green
            $cloneArguments = @('clone', '--progress', '--verbose', '--branch', $Repo.Branch)
            if ($Depth -gt 0) { $cloneArguments += @('--depth', "$Depth") }
            $cloneArguments += @('--', $Repo.Url, $temporaryPath)
            $result = Invoke-GitCommand $cloneArguments $ParentDirectory
            if ($result.ExitCode -eq 0) {
                $head = Invoke-GitCommand @('symbolic-ref', '--short', 'HEAD') $temporaryPath -Quiet
                Assert-GitSuccess $head '校验克隆分支'
                if ($head.StdOut -cne $Repo.Branch) { throw '克隆结果的分支与配置不一致。' }
                if (-not (Test-Path -LiteralPath (Join-Path $temporaryPath '.git'))) { throw '克隆结果缺少 .git。' }
                # Directory.Move 在目标已存在时失败，不会将暂存目录嵌套移入已有目录。
                [IO.Directory]::Move($temporaryPath, $Repo.Path)
                return
            }
            if ($attempt -ge $MaxAttempts -or -not (Test-TransientNetworkError $result.StdErr)) {
                Assert-GitSuccess $result '克隆仓库'
            }
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Write-Warning "本次未完成的暂存目录已保留，确认后可手动删除：$temporaryPath"
            }
        }
        Write-Warning "连接 / 传输失败；准备第 $($attempt + 1)/$MaxAttempts 次尝试。"
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

# -----------------------------------------------------------------------------
# 主流程：默认不暂停，适合终端 / 批处理调用；需要保留窗口时传入 -PauseOnExit。
# -----------------------------------------------------------------------------
Initialize-ConsoleUtf8
$results = New-Object 'System.Collections.Generic.List[object]'
$exitCode = 0
try {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host '  批量 Git 仓库克隆 / 更新'
    Write-Host '========================================' -ForegroundColor Cyan
    $script:GitExecutable = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($TargetParent)) { throw '保存目录不能为空。' }
    $parent = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetParent)
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw '保存路径不是目录。' }
    Write-Host "保存目录：$parent"
    if ($Repositories.Count -eq 0) { throw '仓库列表为空。' }
    $seen = @{}
    for ($index = 0; $index -lt $Repositories.Count; $index++) {
        $label = $Repositories[$index]
        $operation = '校验'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $repo = Resolve-RepoConfiguration $Repositories[$index] $parent
            $label = $repo.Folder
            if ($seen.ContainsKey($repo.Path)) { throw '配置中存在重复目标目录。' }
            $seen[$repo.Path] = $true
            Write-Progress -Id 1 -Activity '批量处理 Git 仓库' -Status "正在处理 $($index + 1)/$($Repositories.Count)" `
                -CurrentOperation "$($repo.Folder) | 分支: $($repo.Branch)" -PercentComplete (($index / $Repositories.Count) * 100)
            Write-Host "`n--- [$($index + 1)/$($Repositories.Count)] $($repo.Folder) ---" -ForegroundColor Cyan
            Write-Host "地址：$($repo.Url)`n分支：$($repo.Branch)`n目录：$($repo.Path)"
            if (Test-Path -LiteralPath $repo.Path) {
                $operation = '更新'
                Update-ExistingRepository $repo
            } else {
                $operation = '克隆'
                New-ClonedRepository $repo $parent
            }
            Write-Host "$operation 成功：$label" -ForegroundColor Green
            $results.Add([pscustomobject]@{ Repository = $label; Action = $operation; Result = '成功'; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Detail = '' })
        } catch {
            $exitCode = 1
            Write-Host "$operation 失败：$label`n$($_.Exception.Message)" -ForegroundColor Red
            $results.Add([pscustomobject]@{ Repository = $label; Action = $operation; Result = '失败'; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Detail = $_.Exception.Message })
        } finally {
            $watch.Stop()
        }
    }
} catch {
    $exitCode = 1
    Write-Host "初始化失败：$($_.Exception.Message)" -ForegroundColor Red
} finally {
    Write-Progress -Id 1 -Activity '批量处理 Git 仓库' -Completed
}

Write-Host "`n执行结果：" -ForegroundColor Cyan
$results | Format-Table Repository, Action, Result, Seconds -AutoSize | Out-Host
$failed = @($results | Where-Object { $_.Result -eq '失败' }).Count
$succeeded = @($results | Where-Object { $_.Result -eq '成功' }).Count
Write-Host "成功 $succeeded 个，失败 $failed 个。退出码：$exitCode"
if ($PauseOnExit) { [void](Read-Host '按回车退出') }
exit $exitCode
