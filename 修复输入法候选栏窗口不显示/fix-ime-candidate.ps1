#Requires -Version 5.1
<#
.SYNOPSIS
  自动修复「输入法候选栏窗口不显示」。

.DESCRIPTION
  【用途】
    修复打字时输入法候选栏窗口不出现的问题。

  【入口】
    1) 双击 fix-ime-candidate.bat（推荐）
    2) 右键 fix-ime-candidate.ps1 -> 使用 PowerShell 运行

  【覆盖范围】
    1) 微软拼音：按系统自动选择新版 / 旧版兼容策略
    2) 常见第三方输入法：搜狗 / 百度 / QQ / 讯飞 / 华为（进程热重载）
    3) 通用候选宿主：TextInputHost / ChsIME / ctfmon

  【执行流程】
    菜单选择 -> 本窗口显示修复进度 -> 打开记事本验证
    -> 输出收尾提示 -> 用户手动关闭窗口（或按 Enter 退出）

  【说明】
    - 进度条始终在当前窗口显示
    - 仅结束受保护进程或写策略失败时，才会后台提权
    - 不依赖记事本进程是否关闭（兼容 Win11 新记事本）

.PARAMETER Mode
  修复策略：
    Auto - 自动（Win11 及以上用新版，Win10 及更早用旧版兼容）
    New  - 强制新版微软拼音策略
    Old  - 强制旧版兼容策略

.PARAMETER ShowMenu
  显示中文菜单。双击 bat 时传入；直接运行本脚本且未指定 Mode 时也会自动弹出。

.PARAMETER RepairOnly
  只执行修复，不做记事本验证（供自动化或兼容调用）。

.PARAMETER NoNotepad
  跳过打开记事本验证。

.PARAMETER NoPause
  结束时不暂停（自动化用；正常交互请勿使用）。

.PARAMETER SkipElevate
  跳过 UAC 提权（调试用；可能导致无法结束 ChsIME 等进程）。

.NOTES
  - 编码：UTF-8 带 BOM（Windows PowerShell 5.1 必需，否则中文会乱码）
  - 退出码：0 正常；1 异常；9009 由 bat 在找不到 PowerShell 时返回
#>
[CmdletBinding()]
param(
    # 修复策略：Auto / New / Old
    [ValidateSet('Auto', 'New', 'Old')]
    [string]$Mode = 'Auto',

    # 结束时不暂停（自动化）
    [switch]$NoPause,

    # 跳过 UAC 提权（调试）
    [switch]$SkipElevate,

    # 跳过记事本验证
    [switch]$NoNotepad,

    # 只修复、不验证
    [switch]$RepairOnly,

    # 显示中文菜单
    [switch]$ShowMenu
)

# =============================================================================
# 一、全局配置
# =============================================================================

# 遇错继续，避免个别步骤失败导致整窗直接退出
$ErrorActionPreference = 'Continue'

# 设置窗口标题（失败可忽略）
try { $Host.UI.RawUI.WindowTitle = '输入法候选栏修复' } catch {}

# 进度：检测3 + 微软拼音1 + 第三方1 + 通用宿主1 + 验证1 + 完成1 = 8
$script:TotalSteps = 8
$script:CurrentStep = 0
$script:ExitCodeToUse = 0

# 微软拼音 TIP 的 CLSID（用于 TSF3 覆盖注册表）
$script:MsPinyinTipClsid = '{81d4e9c9-1d3b-41bc-9e6c-4b40bf79e35e}'

# 第三方输入法：显示名 -> 常见进程名（结束进程后一般由厂商服务自动拉起）
$script:ThirdPartyImeProcessMap = [ordered]@{
    '搜狗输入法' = @('SogouCloud', 'SogouImeBroker', 'SGTool', 'SogouExe', 'SogouComMgr')
    '百度输入法' = @('BaiduPinyin', 'BaiduBs', 'BaiduHDime', 'BDInput')
    'QQ输入法'   = @('QQPinYin', 'QQPYMain', 'QQInput')
    '讯飞输入法' = @('iFlyIME', 'iFlyVoice')
    '华为输入法' = @('HuaweiIme', 'HwIme')
}

# 第三方输入法：常见安装目录（弱检测，仅用于识别是否安装）
$script:ThirdPartyInstallPaths = @(
    @{ Name = '搜狗输入法'; Path = "${env:ProgramFiles(x86)}\SogouInput" }
    @{ Name = '搜狗输入法'; Path = "$env:ProgramFiles\SogouInput" }
    @{ Name = '百度输入法'; Path = "${env:ProgramFiles(x86)}\Baidu\BaiduPinyin" }
    @{ Name = 'QQ输入法';   Path = "${env:ProgramFiles(x86)}\Tencent\QQPinyin" }
)

# =============================================================================
# 二、基础工具
# =============================================================================

function Test-IsAdmin {
    <#
    .SYNOPSIS
      判断当前进程是否已具备管理员权限。
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Reg {
    <#
    .SYNOPSIS
      调用 reg.exe 写注册表。
    .DESCRIPTION
      不把非 0 退出码当异常（例如 delete 时键不存在也会返回非 0）。
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Arguments
    )

    $proc = Start-Process -FilePath 'reg.exe' `
        -ArgumentList $Arguments `
        -Wait -PassThru -WindowStyle Hidden
    return $proc.ExitCode
}

function Invoke-ElevatedCommand {
    <#
    .SYNOPSIS
      后台隐藏窗口提权执行一条 PowerShell 命令。
    .DESCRIPTION
      用于结束受保护进程、写入策略项等。后台隐藏提权，前台窗口继续显示进度。
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    Write-Host '[*] 需要管理员权限执行部分操作，请在 UAC 弹窗中选择「是」...' -ForegroundColor Yellow

    $argList = @(
        '-NoProfile'
        '-WindowStyle', 'Hidden'
        '-ExecutionPolicy', 'Bypass'
        '-Command', $Command
    )

    $proc = Start-Process -FilePath 'powershell.exe' `
        -Verb RunAs `
        -ArgumentList $argList `
        -Wait -PassThru `
        -WindowStyle Hidden

    if ($proc) { return [int]$proc.ExitCode }
    return 1
}

function Stop-ProcessSafe {
    <#
    .SYNOPSIS
      按进程名强制结束；普通权限失败时再后台提权重试。
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # 先尝试普通权限结束
    Start-Process -FilePath 'taskkill.exe' `
        -ArgumentList '/F', '/IM', "$Name.exe" `
        -Wait -WindowStyle Hidden `
        -ErrorAction SilentlyContinue | Out-Null

    Start-Sleep -Milliseconds 400
    $stillRunning = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if (-not $stillRunning) { return }

    # 已是管理员或明确跳过提权：只提示
    if ($SkipElevate -or (Test-IsAdmin)) {
        Write-Host ("  -> 未能结束进程 {0}（权限不足或受系统保护）" -f $Name) -ForegroundColor Yellow
        return
    }

    # 后台提权结束
    Write-Host ("  -> 普通权限无法结束 {0}，改为后台提权结束..." -f $Name) -ForegroundColor Yellow
    [void](Invoke-ElevatedCommand -Command ("taskkill /F /IM {0}.exe 2>`$null; exit 0" -f $Name))
}

function Show-ProgressStep {
    <#
    .SYNOPSIS
      输出步骤文字，并同步刷新 Write-Progress 进度条。
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Status
    )

    $script:CurrentStep++
    $percent = [int](($script:CurrentStep / $script:TotalSteps) * 100)
    if ($percent -gt 100) { $percent = 100 }

    Write-Progress -Activity $Activity `
        -Status ("[{0}/{1}] {2}" -f $script:CurrentStep, $script:TotalSteps, $Status) `
        -PercentComplete $percent

    Write-Host ("[{0}/{1}] {2}" -f $script:CurrentStep, $script:TotalSteps, $Status) `
        -ForegroundColor Cyan
}

# =============================================================================
# 三、环境检测
# =============================================================================

function Get-OsInfo {
    <#
    .SYNOPSIS
      读取操作系统信息。
    .DESCRIPTION
      内部版本号 Build >= 22000 判定为 Windows 11 及以上。
    #>
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $isWin11OrLater = $build -ge 22000

    [pscustomobject]@{
        Caption        = $os.Caption
        Version        = $os.Version
        Build          = $build
        IsWin11OrLater = $isWin11OrLater
        Label          = if ($isWin11OrLater) { 'Windows 11 及以上' } else { 'Windows 10 及更早' }
    }
}

function Resolve-FixMode {
    <#
    .SYNOPSIS
      把 Auto/New/Old 解析成最终要执行的 New 或 Old。
    #>
    param(
        [Parameter(Mandatory)][string]$RequestedMode,
        [Parameter(Mandatory)][bool]$IsWin11OrLater
    )

    # 手动指定则直接返回
    if ($RequestedMode -ne 'Auto') { return $RequestedMode }

    # 自动：Win11+ 走新版，更早系统走旧版兼容
    if ($IsWin11OrLater) { return 'New' }
    return 'Old'
}

function Get-MsPinyinVersionStatus {
    <#
    .SYNOPSIS
      读取当前微软拼音是新版还是被强制旧版。
    .DESCRIPTION
      优先级：策略 ConfigureImeVersion > 用户 Enable Compatibility Version > TSF 默认值。
      注意：tsf3override 下空键可被系统重建，不能仅凭“键存在”判定为旧版；
      只有默认值 (Default)=1 时才视为强制旧版。
    #>
    $compat = 0
    $policy = $null
    $tipForcesOld = $false

    try {
        $compat = [int](Get-ItemProperty -Path 'HKCU:\Software\Microsoft\InputMethod\Settings\CHS' `
            -Name 'Enable Compatibility Version' -ErrorAction Stop).'Enable Compatibility Version'
    }
    catch { $compat = 0 }

    try {
        $policy = [int](Get-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS' `
            -Name 'ConfigureImeVersion' -ErrorAction Stop).ConfigureImeVersion
    }
    catch { $policy = $null }

    $tipPath = "HKCU:\Software\Microsoft\Input\tsf\tsf3override\$($script:MsPinyinTipClsid)"
    if (Test-Path -LiteralPath $tipPath) {
        try {
            # 旧版脚本写入的是默认值 DWORD=1
            $item = Get-Item -LiteralPath $tipPath -ErrorAction Stop
            $defaultVal = $item.GetValue('', $null)
            if ($null -ne $defaultVal -and [int]$defaultVal -eq 1) {
                $tipForcesOld = $true
            }
        }
        catch {
            $tipForcesOld = $false
        }
    }

    $isOld = $false
    $reason = '新版（默认）'
    if ($policy -eq 1) {
        $isOld = $true
        $reason = '旧版（策略 ConfigureImeVersion=1 强制）'
    }
    elseif ($policy -eq 0) {
        $isOld = $false
        $reason = '新版（策略 ConfigureImeVersion=0）'
    }
    elseif ($compat -eq 1) {
        $isOld = $true
        $reason = '旧版（用户兼容开关已开）'
    }
    elseif ($tipForcesOld) {
        $isOld = $true
        $reason = '旧版（TSF3 覆盖默认值=1）'
    }

    [pscustomobject]@{
        IsOld          = $isOld
        Reason         = $reason
        CompatSwitch   = $compat
        PolicyVersion  = $policy
        TipForcesOld   = $tipForcesOld
        DisplayName    = $(if ($isOld) { '旧版兼容' } else { '新版' })
    }
}

function Clear-MsPinyinForcedOldPolicy {
    <#
    .SYNOPSIS
      清除「强制旧版」策略与 TSF 覆盖（必要时提权）。
    .OUTPUTS
      $true 表示已不再被策略强制为旧版。
    #>
    $policyPath = 'HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS'
    $tipPath = "HKCU:\Software\Microsoft\Input\tsf\tsf3override\$($script:MsPinyinTipClsid)"

    # 先普通权限尝试
    try {
        if (Test-Path -LiteralPath $policyPath) {
            Remove-ItemProperty -Path $policyPath -Name 'ConfigureImeVersion' -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $policyPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}

    try {
        if (Test-Path -LiteralPath $tipPath) {
            Remove-Item -Path $tipPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}

    # 若策略仍在且为 1，必须提权清除
    $stillForced = $false
    try {
        $v = [int](Get-ItemProperty -Path $policyPath -Name 'ConfigureImeVersion' -ErrorAction Stop).ConfigureImeVersion
        if ($v -eq 1) { $stillForced = $true }
    }
    catch {
        $stillForced = $false
    }

    if ($stillForced -or (Test-Path -LiteralPath $policyPath)) {
        if (-not $SkipElevate -and -not (Test-IsAdmin)) {
            Write-Host '  -> 清除强制旧版策略需要管理员，正在提权...' -ForegroundColor Yellow
            $cmd = @'
$p='HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS'
$t='HKCU:\Software\Microsoft\Input\tsf\tsf3override\{81d4e9c9-1d3b-41bc-9e6c-4b40bf79e35e}'
if(Test-Path $p){ Remove-ItemProperty -Path $p -Name ConfigureImeVersion -Force -ErrorAction SilentlyContinue; Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
if(Test-Path $p){ New-ItemProperty -Path $p -Name ConfigureImeVersion -PropertyType DWord -Value 0 -Force -ErrorAction SilentlyContinue | Out-Null; if((Get-ItemProperty $p -Name ConfigureImeVersion -EA SilentlyContinue).ConfigureImeVersion -ne 0){} ; Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
if(Test-Path $t){ Remove-Item -Path $t -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
'@
            [void](Invoke-ElevatedCommand -Command $cmd)
        }
        else {
            [void](Invoke-Reg 'delete "HKCU\Software\Policies\Microsoft\InputMethod\Settings\CHS" /v ConfigureImeVersion /f')
            [void](Invoke-Reg 'delete "HKCU\Software\Policies\Microsoft\InputMethod\Settings\CHS" /f')
            [void](Invoke-Reg "delete `"HKCU\Software\Microsoft\Input\tsf\tsf3override\$($script:MsPinyinTipClsid)`" /f")
        }
    }

    # 返回是否仍被强制旧版
    try {
        $v = [int](Get-ItemProperty -Path $policyPath -Name 'ConfigureImeVersion' -ErrorAction Stop).ConfigureImeVersion
        return ($v -ne 1)
    }
    catch {
        return $true
    }
}

function Get-InstalledImeSummary {
    <#
    .SYNOPSIS
      汇总本机输入法情况：是否启用微软拼音、第三方是否安装/运行。
    #>
    $tips = @()
    try {
        foreach ($lang in (Get-WinUserLanguageList)) {
            foreach ($tip in @($lang.InputMethodTips)) {
                $tips += [string]$tip
            }
        }
    }
    catch {
        # 个别环境取语言列表失败时忽略，后续仍做通用修复
    }

    # 微软拼音 TIP 标识
    $hasMsPinyin = $false
    foreach ($tip in $tips) {
        if ($tip -match '81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E') {
            $hasMsPinyin = $true
            break
        }
    }

    # 第三方：先看进程是否在跑，再看安装目录是否存在
    $thirdParty = @()
    foreach ($name in $script:ThirdPartyImeProcessMap.Keys) {
        $procNames = @($script:ThirdPartyImeProcessMap[$name])
        $running = @(Get-Process -Name $procNames -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            $thirdParty += [pscustomobject]@{
                Name      = $name
                Processes = @($running.ProcessName | Select-Object -Unique)
            }
        }
    }

    foreach ($item in $script:ThirdPartyInstallPaths) {
        if ((Test-Path -LiteralPath $item.Path) -and ($thirdParty.Name -notcontains $item.Name)) {
            $thirdParty += [pscustomobject]@{
                Name      = $item.Name
                Processes = @()
            }
        }
    }

    $detected = @()
    if ($hasMsPinyin) { $detected += '微软拼音' }
    $detected += @($thirdParty.Name)
    $detected = @($detected | Select-Object -Unique)

    [pscustomobject]@{
        Tips          = $tips
        HasMsPinyin   = $hasMsPinyin
        ThirdParty    = $thirdParty
        DetectedNames = $detected
    }
}

# =============================================================================
# 四、修复动作
# =============================================================================

function Repair-MicrosoftPinyin {
    <#
    .SYNOPSIS
      按新版/旧版策略调整微软拼音，并重置候选窗相关配置。
    #>
    param(
        [ValidateSet('New', 'Old')]
        [string]$FixMode
    )

    $tipOverride = "HKCU\Software\Microsoft\Input\tsf\tsf3override\$($script:MsPinyinTipClsid)"

    # ---------- 新版策略：关闭旧版兼容，重置候选窗 ----------
    if ($FixMode -eq 'New') {
        Show-ProgressStep -Activity '修复微软拼音' -Status '按新版策略处理（关闭旧版兼容、清除强制旧版策略）'

        # 1) 用户级：关闭「使用以前版本的微软拼音」
        [void](Invoke-Reg 'add "HKCU\Software\Microsoft\InputMethod\Settings\CHS" /v "Enable Compatibility Version" /t REG_DWORD /d 0 /f')

        # 2) 策略级 + TSF 覆盖：必须清掉，否则会一直锁在旧版
        $cleared = Clear-MsPinyinForcedOldPolicy

        # 3) 重置候选窗节点，并打开云候选
        [void](Invoke-Reg 'delete "HKCU\Software\Microsoft\InputMethod\CandidateWindow\CHS" /f')
        [void](Invoke-Reg 'add "HKCU\Software\Microsoft\InputMethod\CandidateWindow\CHS" /f')
        [void](Invoke-Reg 'add "HKCU\Software\Microsoft\InputMethod\Settings\CHS" /v "Enable Cloud Candidate" /t REG_DWORD /d 1 /f')

        $status = Get-MsPinyinVersionStatus
        if (-not $cleared -or $status.IsOld) {
            Write-Host ("  -> 警告：当前仍判定为 {0}" -f $status.Reason) -ForegroundColor Red
            Write-Host '  -> 请确认 UAC 已点「是」，然后重新选择「强制新版」再试' -ForegroundColor Yellow
        }
        else {
            Write-Host ("  -> 新版已生效：{0}" -f $status.Reason) -ForegroundColor Green
        }
        return
    }

    # ---------- 旧版策略：开启兼容模式（更稳，外观较旧） ----------
    Show-ProgressStep -Activity '修复微软拼音' -Status '按旧版/兼容策略处理（开启以前版本的微软拼音）'

    [void](Invoke-Reg 'add "HKCU\Software\Microsoft\InputMethod\Settings\CHS" /v "Enable Compatibility Version" /t REG_DWORD /d 1 /f')

    # 策略项有时需要管理员；失败则后台提权重试
    $policyPath = 'HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS'
    $policyOk = $false
    try {
        New-Item -Path $policyPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $policyPath -Name 'ConfigureImeVersion' `
            -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        $policyOk = $true
    }
    catch {
        if (-not $SkipElevate -and -not (Test-IsAdmin)) {
            Write-Host '  -> 写入策略项需要管理员，改为后台提权...' -ForegroundColor Yellow
            $cmd = 'New-Item -Path ''HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS'' -Force | Out-Null; New-ItemProperty -Path ''HKCU:\Software\Policies\Microsoft\InputMethod\Settings\CHS'' -Name ConfigureImeVersion -PropertyType DWord -Value 1 -Force | Out-Null'
            [void](Invoke-ElevatedCommand -Command $cmd)
            $policyOk = $true
        }
        else {
            Write-Host '  -> 策略项写入失败，已尽量使用用户级兼容开关' -ForegroundColor Yellow
        }
    }

    [void](Invoke-Reg "add `"$tipOverride`" /ve /t REG_DWORD /d 1 /f")
    [void](Invoke-Reg 'add "HKCU\Software\Microsoft\InputMethod\Settings\CHS" /v "Enable Cloud Candidate" /t REG_DWORD /d 1 /f')

    if ($policyOk) {
        Write-Host '  -> 旧版：兼容模式已开（用户开关 + 策略 + TSF 覆盖）' -ForegroundColor Green
    }
    else {
        Write-Host '  -> 旧版：用户级兼容开关已开（策略项未写入）' -ForegroundColor Yellow
    }

    $status = Get-MsPinyinVersionStatus
    Write-Host ("  -> 当前判定：{0}" -f $status.Reason) -ForegroundColor $(if ($status.IsOld) { 'Green' } else { 'Yellow' })
}

function Repair-ThirdPartyIme {
    <#
    .SYNOPSIS
      对已识别的第三方输入法相关进程做热重载尝试。
    #>
    param($ImeSummary)

    Show-ProgressStep -Activity '修复第三方输入法' -Status '检测并热重载第三方输入法相关进程'

    if (-not $ImeSummary.ThirdParty -or $ImeSummary.ThirdParty.Count -eq 0) {
        Write-Host '  -> 未发现正在运行/已安装的常见第三方输入法，跳过' -ForegroundColor DarkGray
        return
    }

    foreach ($item in $ImeSummary.ThirdParty) {
        $procNames = @($script:ThirdPartyImeProcessMap[$item.Name])
        if (-not $procNames) { continue }

        $running = @(Get-Process -Name $procNames -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            Write-Host ("  -> {0}：已安装但当前未运行相关进程" -f $item.Name) -ForegroundColor DarkGray
            continue
        }

        foreach ($procName in ($running.ProcessName | Select-Object -Unique)) {
            Write-Host ("  -> {0}：结束进程 {1}" -f $item.Name, $procName) -ForegroundColor Yellow
            Stop-ProcessSafe $procName
        }
    }

    Start-Sleep -Seconds 2
    Write-Host '  -> 第三方进程已尝试热重载（厂商服务通常会自动拉起）' -ForegroundColor Green
}

function Repair-CommonImeHost {
    <#
    .SYNOPSIS
      热重载系统级候选宿主进程（对多数输入法都有帮助）。
    #>
    Show-ProgressStep -Activity '通用候选宿主' -Status '热重载 TextInputHost / ChsIME / ctfmon（通用层）'

    # 结束旧宿主（必要时会后台提权）
    Stop-ProcessSafe 'TextInputHost'
    Stop-ProcessSafe 'ChsIME'
    Start-Sleep -Seconds 2

    # 重新拉起
    $ctfmon = Join-Path $env:SystemRoot 'System32\ctfmon.exe'
    $chsIme = Join-Path $env:SystemRoot 'System32\InputMethod\CHS\ChsIME.exe'
    if (Test-Path -LiteralPath $ctfmon) { Start-Process -FilePath $ctfmon }
    if (Test-Path -LiteralPath $chsIme) { Start-Process -FilePath $chsIme }
    Start-Sleep -Seconds 2

    $procs = @(Get-Process -Name ChsIME, TextInputHost, ctfmon -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-Host ($procs | Format-Table ProcessName, Id, StartTime -AutoSize | Out-String)
        Write-Host '  -> 通用宿主进程已重新拉起' -ForegroundColor Green
    }
    else {
        Write-Host '  -> 未检测到宿主进程，请稍后手动切换一次输入法' -ForegroundColor Yellow
    }
}

function Invoke-RepairPipeline {
    <#
    .SYNOPSIS
      完整修复流水线（本窗口显示全部进度）。
    .DESCRIPTION
      顺序：环境检测 -> 策略选择 -> 微软拼音 -> 第三方 -> 通用宿主。
    #>
    Write-Host ''
    Write-Host '================================================' -ForegroundColor White
    Write-Host ' 输入法候选栏不显示 · 自动修复' -ForegroundColor White
    Write-Host ' 用途：修复打字时输入法候选栏窗口不出现的问题' -ForegroundColor DarkGray
    Write-Host '================================================' -ForegroundColor White
    Write-Host ''

    # --- 1) 环境检测 ---
    Show-ProgressStep -Activity '环境检测' -Status '识别系统版本'
    $os = Get-OsInfo
    Write-Host ("  -> 系统：{0}（内部版本 {1}，判定为 {2}）" -f $os.Caption, $os.Build, $os.Label)

    Show-ProgressStep -Activity '环境检测' -Status '识别已安装/正在运行的输入法'
    $ime = Get-InstalledImeSummary
    if ($ime.DetectedNames.Count -gt 0) {
        Write-Host ("  -> 检测到：{0}" -f ($ime.DetectedNames -join '、'))
    }
    else {
        Write-Host '  -> 未明确识别到输入法，仍将执行通用修复' -ForegroundColor Yellow
    }

    # --- 2) 策略选择 ---
    $fixMode = Resolve-FixMode -RequestedMode $Mode -IsWin11OrLater $os.IsWin11OrLater
    $modeLabel = if ($fixMode -eq 'New') { '新版微软拼音策略' } else { '旧版兼容策略' }
    Show-ProgressStep -Activity '策略选择' -Status ("策略 => {0}" -f $modeLabel)

    if ($Mode -eq 'Auto') {
        $autoLabel = if ($fixMode -eq 'New') { '新版' } else { '旧版兼容' }
        Write-Host ("  -> 自动：{0} => 使用 {1}" -f $os.Label, $autoLabel)
    }
    else {
        Write-Host ("  -> 手动指定模式：{0}" -f $(if ($Mode -eq 'New') { '新版' } elseif ($Mode -eq 'Old') { '旧版兼容' } else { $Mode }))
    }

    # --- 3) 执行修复 ---
    Repair-MicrosoftPinyin -FixMode $fixMode
    Repair-ThirdPartyIme -ImeSummary $ime
    Repair-CommonImeHost

    # --- 4) 复核当前微软拼音版本（便于确认是否切成功） ---
    $ver = Get-MsPinyinVersionStatus
    Write-Host ''
    Write-Host ("[*] 微软拼音当前状态：{0}" -f $ver.DisplayName) -ForegroundColor Cyan
    Write-Host ("    {0}" -f $ver.Reason) -ForegroundColor DarkGray
}

# =============================================================================
# 五、验证与收尾
# =============================================================================

function Start-VerifyNotepad {
    <#
    .SYNOPSIS
      打开系统记事本，供用户手动验证候选栏。
    .DESCRIPTION
      不 Wait-Process 等待记事本退出：
      Win11 记事本启动器进程会立刻结束，等待它会导致流程异常。
      验证结束后由用户在本窗口按 Enter 继续，或手动关闭本窗口。
    #>
    Show-ProgressStep -Activity '验证' -Status '打开记事本验证（本窗口保持打开）'

    $notepadPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    if (-not (Test-Path -LiteralPath $notepadPath)) {
        $notepadPath = 'notepad.exe'
    }

    $notepad = $null
    try {
        $notepad = Start-Process -FilePath $notepadPath -PassThru -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        Write-Host '  -> 已尝试打开记事本' -ForegroundColor Green
    }
    catch {
        Write-Host '  -> 未能自动打开记事本，请自行打开记事本验证' -ForegroundColor Yellow
    }

    # 尝试把验证说明粘贴进记事本（失败可忽略）
    if ($notepad) {
        try {
            $wshell = New-Object -ComObject WScript.Shell
            Start-Sleep -Milliseconds 400
            $null = $wshell.AppActivate($notepad.Id)
            Start-Sleep -Milliseconds 250

            $hint = @"
【输入法候选栏验证】
1. 请在下方输入拼音（例如：shihou）
2. 看候选栏窗口是否出现并能选字
3. 验证完成后，回到本窗口：可手动关闭窗口，或按 Enter 继续

"@
            Set-Clipboard -Value $hint
            $wshell.SendKeys('^v')
            Start-Sleep -Milliseconds 200
            $wshell.SendKeys('{ENTER}{ENTER}')
        }
        catch {
            Write-Host '  -> 自动填入验证说明失败，请在记事本中手动输入拼音验证' -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '================================================' -ForegroundColor Yellow
    Write-Host ' 请在记事本中输入拼音，检查候选栏是否出现' -ForegroundColor Yellow
    Write-Host '================================================' -ForegroundColor Yellow
    Write-Host ''

    if (-not $NoPause) {
        [void](Read-Host '验证完成后：可手动关闭本窗口，或按 Enter 继续')
    }
}

function Show-FinalFeedback {
    <#
    .SYNOPSIS
      输出收尾提示（不询问成败，仅提示若仍失败可重启）。
    #>
    param([bool]$SkippedVerify)

    Show-ProgressStep -Activity '完成' -Status '输出最终提示（窗口保持打开）'
    Write-Progress -Activity '完成' -Completed

    Write-Host ''
    Write-Host '================================================' -ForegroundColor Green
    Write-Host ' 修复流程已执行完成' -ForegroundColor Green
    Write-Host '================================================' -ForegroundColor Green
    Write-Host ''

    if ($SkippedVerify) {
        Write-Host '已跳过记事本验证。请自行打开记事本输入拼音检查候选栏。' -ForegroundColor DarkGray
    }
    else {
        Write-Host '请确认刚才在记事本中验证时，输入候选栏窗口是否正常出现。' -ForegroundColor White
    }

    Write-Host ''
    Write-Host '若验证后还是未出现输入候选栏窗口，则可能修复失败，' -ForegroundColor Yellow
    Write-Host '请手动重启电脑后再试。' -ForegroundColor Yellow
    Write-Host ''
}

function Wait-BeforeExit {
    <#
    .SYNOPSIS
      收尾后保持窗口，由用户手动关闭或按 Enter 退出。
    #>
    Write-Progress -Activity '完成' -Completed
    if ($NoPause) { return }

    Write-Host '------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '脚本已执行完毕。' -ForegroundColor Cyan
    Write-Host '请手动关闭本窗口（点击右上角），或按 Enter 退出。' -ForegroundColor Cyan
    [void](Read-Host)
}

# =============================================================================
# 六、菜单
# =============================================================================

function Show-MainMenuAndResolveMode {
    <#
    .SYNOPSIS
      显示中文菜单，返回 Auto / New / Old；选 0 则退出脚本。
    #>
    Write-Host ''
    Write-Host '================================================' -ForegroundColor White
    Write-Host ' 输入法候选栏不显示 · 自动修复' -ForegroundColor White
    Write-Host ' 用途：修复打字时输入法候选栏窗口不出现的问题' -ForegroundColor DarkGray
    Write-Host '================================================' -ForegroundColor White
    Write-Host ''
    Write-Host '  [1] 自动修复（推荐：按系统自动选择新版/旧版策略）' -ForegroundColor Cyan
    Write-Host '  [2] 强制按新版微软拼音策略' -ForegroundColor Cyan
    Write-Host '  [3] 强制按旧版兼容策略' -ForegroundColor Cyan
    Write-Host '  [0] 退出' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $choice = Read-Host '请选择 (0/1/2/3)'
        switch ($choice) {
            '1' { return 'Auto' }
            '2' { return 'New' }
            '3' { return 'Old' }
            '0' {
                Write-Host '已取消。' -ForegroundColor DarkGray
                exit 0
            }
            default {
                Write-Host '无效选项，请输入 0、1、2 或 3。' -ForegroundColor Yellow
            }
        }
    }
}

# =============================================================================
# 七、主流程
# =============================================================================

try {
    # ----- 0. 菜单 -----
    # 显示菜单的条件：
    #   a) 显式传入 -ShowMenu（bat 双击）
    #   b) 直接运行本 ps1，且未指定 -Mode / -RepairOnly
    $shouldShowMenu = $ShowMenu -or (
        (-not $PSBoundParameters.ContainsKey('Mode')) -and
        (-not $RepairOnly)
    )
    if ($shouldShowMenu) {
        $Mode = Show-MainMenuAndResolveMode
        Write-Host ("[*] 已选择：{0}" -f $(
            if ($Mode -eq 'Auto') { '自动修复' }
            elseif ($Mode -eq 'New') { '新版策略' }
            else { '旧版兼容策略' }
        )) -ForegroundColor Green
    }

    # ----- A. 修复（本窗口显示完整进度） -----
    # 仅结束受保护进程 / 写策略失败时才会后台提权
    Invoke-RepairPipeline

    # 若只要求修复：到此结束
    if ($RepairOnly) {
        Show-ProgressStep -Activity '完成' -Status '修复完成（RepairOnly，跳过验证）'
        Write-Progress -Activity '完成' -Completed
        Write-Host ''
        Write-Host '[完成] 修复已完成。' -ForegroundColor Green
        $script:ExitCodeToUse = 0
        exit 0
    }

    # ----- B. 验证（打开记事本；不询问 Y/N） -----
    $skippedVerify = $false
    if ($NoNotepad) {
        Show-ProgressStep -Activity '验证' -Status '已跳过打开记事本'
        $skippedVerify = $true
    }
    else {
        Start-VerifyNotepad
    }

    # ----- C. 收尾提示 -----
    Show-FinalFeedback -SkippedVerify:$skippedVerify
    $script:ExitCodeToUse = 0
}
catch {
    Write-Progress -Activity '修复失败' -Completed
    Write-Host ''
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkRed
    }
    Write-Host ''
    Write-Host '若多次失败，请手动重启电脑后再试。' -ForegroundColor Yellow
    $script:ExitCodeToUse = 1
}
finally {
    # 无论成功失败，都尽量保持窗口，方便用户看完提示
    Wait-BeforeExit
}

exit $script:ExitCodeToUse