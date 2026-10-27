# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version Latest

function Get-LocalDailyConfig {
    param([string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw 'Configuration missing. Run scripts/Setup.ps1 first.'
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.schemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
    $repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\','/')
    $stateRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$config.stateRoot)).TrimEnd('\','/')
    if ($stateRoot -eq $repository -or $stateRoot.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private stateRoot must be outside this Git checkout.'
    }
    if ($config.schedule.localTime -ne '20:00') { throw 'This release supports the documented 20:00 schedule only.' }
    if ($config.schedule.timeZone -ne 'Asia/Shanghai') { throw 'This release supports Asia/Shanghai platform days only.' }
    if (-not ($config.bilibili.enabled -is [bool]) -or -not ($config.heybox.enabled -is [bool])) {
        throw 'Module enabled flags must be JSON booleans.'
    }
    return [pscustomobject]@{ Config=$config; StateRoot=$stateRoot; Repository=$repository }
}

function Write-LocalDailyJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    $temporary = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-LocalDailyPublicReport {
    param([string]$Path,[string]$Date,[string]$Name,[bool]$Enabled)
    if (-not $Enabled) {
        return [pscustomobject]@{ Name=$Name; Date=$Date; Status='Disabled'; Reason='Module disabled in local configuration.'; PublicTasks=@(); PublicSummary=@(); CoinDonations=@() }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Name=$Name; Date=$Date; Status='Unconfirmed'; Reason='No current-day safe report; no retry performed.'; PublicTasks=@(); PublicSummary=@(); CoinDonations=@() }
    }
    try { $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        return [pscustomobject]@{ Name=$Name; Date=$Date; Status='Unconfirmed'; Reason='Safe report could not be parsed; no retry.'; PublicTasks=@(); PublicSummary=@(); CoinDonations=@() }
    }
    if ($null -eq $data -or 'Date' -notin @($data.PSObject.Properties.Name) -or $data.Date -ne $Date) {
        return [pscustomobject]@{ Name=$Name; Date=$Date; Status='Unconfirmed'; Reason='A report from another date was refused.'; PublicTasks=@(); PublicSummary=@(); CoinDonations=@() }
    }
    $names=@($data.PSObject.Properties.Name)
    if ('PublicTasks' -notin $names) { $data | Add-Member NoteProperty PublicTasks $(if('Tasks' -in $names){@($data.Tasks)}else{@()}) }
    if ('PublicSummary' -notin $names) { $data | Add-Member NoteProperty PublicSummary $(if('Summary' -in $names){@($data.Summary)}else{@()}) }
    if ('CoinDonations' -notin $names) { $data | Add-Member NoteProperty CoinDonations $(if('Donations' -in $names){@($data.Donations)}else{@()}) }
    if ('Reason' -notin $names) { $data | Add-Member NoteProperty Reason $null }
    return $data
}

function Set-LocalDailyReportContext {
    param([object]$Report,[bool]$ReportOnly,[object]$Launch)
    $properties=@($Report.PSObject.Properties.Name)
    $hasSnapshot=('ObservedAt' -in $properties -and $Report.ObservedAt)
    $reused=$ReportOnly -and $hasSnapshot
    $issue=$null
    if ($Launch) {
        if ($null -eq $Launch.ExitCode -or $Launch.ExitCode -ne 0) { $issue='本轮启动或执行异常；没有自动重试。' }
        $fresh=$false
        if ('ObservedAt' -in $properties -and $Report.ObservedAt) {
            try { $fresh=([datetimeoffset]::Parse($Report.ObservedAt) -ge [datetimeoffset]::Parse($Launch.StartedAt)) } catch {}
        }
        if (-not $fresh) {
            $reused=[bool]$hasSnapshot
            if(-not $issue){$issue='本轮未取得新的模块报告；没有自动重试。'}
        }
    }
    if($reused) {
        $confirmedAt=if('SummaryObservedAt' -in $properties){$Report.SummaryObservedAt}elseif('ProfileObservedAt' -in $properties){$Report.ProfileObservedAt}elseif('ObservedAt' -in $properties){$Report.ObservedAt}else{$null}
        $Report | Add-Member NoteProperty SummarySource 'LastConfirmedToday' -Force
        $Report | Add-Member NoteProperty SummaryObservedAt $confirmedAt -Force
        $Report | Add-Member NoteProperty NewObservation $false -Force
        $Report | Add-Member NoteProperty ReusedForThisInvocation $true -Force
        # A stale report cannot establish how many actions an unsuccessful new launch submitted.
        $Report | Add-Member NoteProperty NativeSuccessCoins $null -Force
        $Report | Add-Member NoteProperty ActionsSubmittedThisInvocation $null -Force
    }
    if($ReportOnly) {
        $Report | Add-Member NoteProperty NativeSuccessCoins 0 -Force
        $Report | Add-Member NoteProperty ActionsSubmittedThisInvocation 0 -Force
    }
    if($Launch -and 'LocalOnly' -in @($Launch.PSObject.Properties.Name) -and $Launch.LocalOnly) {
        $Report | Add-Member NoteProperty NativeSuccessCoins 0 -Force
        $Report | Add-Member NoteProperty ActionsSubmittedThisInvocation 0 -Force
        $Report | Add-Member NoteProperty NewObservation $false -Force
        $Report | Add-Member NoteProperty InvocationStatus $Launch.PreparationStatus -Force
        $issue='本轮仅完成本地前置检查，未启动 B站账号任务：'+$Launch.PreparationStatus+'。'
    }
    if($issue){$Report | Add-Member NoteProperty InvocationIssue $issue -Force}
    return $Report
}
