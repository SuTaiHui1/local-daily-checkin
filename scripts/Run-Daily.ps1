param(
    [string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.json'),
    [switch]$Scheduled,
    [switch]$ReportOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$settings=Get-LocalDailyConfig -ConfigPath $ConfigPath
if (-not $ReportOnly -and [TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours -ne 8) {
    throw 'Set this computer to the intended UTC+08 platform day before executing account tasks; no system setting was changed.'
}
$today=Get-Date -Format 'yyyy-MM-dd'
$day=Get-Date -Format 'yyyyMMdd'
if ($Scheduled -and (Get-Date).Hour -lt 20) {
    Write-Output 'SkipBeforeTodaySchedule: no platform task was started.'
    return
}
$null=New-Item -ItemType Directory -Path $settings.StateRoot -Force
$mutex=New-Object Threading.Mutex($false,'Local\LocalDailyCheckin-Coordinator')
$owned=$false
try {
    $owned=$mutex.WaitOne(0)
    if (-not $owned) { Write-Output 'SkipRunning: another coordinator owns the mutex.'; return }
    $starts=@()
    if (-not $ReportOnly) {
        foreach ($name in @('bilibili','heybox')) {
            $module=$settings.Config.$name
            if (-not $module.enabled) { continue }
            if ((Get-Date -Format 'yyyy-MM-dd') -ne $today) { break }
            $state=Join-Path $settings.StateRoot $name
            $script=if($name -eq 'bilibili'){'src\bilibili\Launch.ps1'}else{'src\heybox\LaunchDaily.ps1'}
            $parameters=@('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','RemoteSigned','-File',(Join-Path $settings.Repository $script),'-StateRoot',$state)
            if ($name -eq 'bilibili') { $parameters+=@('-Mode','Daily') }
            if ($Scheduled) { $parameters+='-Scheduled' }
            $startedAt=Get-Date -Format o
            try {
                & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @parameters
                $starts+=[pscustomobject]@{Module=$name;ExitCode=$LASTEXITCODE;StartedAt=$startedAt;CompletedAt=(Get-Date -Format o)}
            } catch {
                # Exception text may include signed URLs. Never copy arbitrary diagnostics.
                $starts+=[pscustomobject]@{Module=$name;ExitCode=$null;StartedAt=$startedAt;CompletedAt=(Get-Date -Format o);Reason='Local launcher failed; no retry.'}
            }
        }
    }
    if ((Get-Date -Format 'yyyy-MM-dd') -ne $today) { throw 'Date changed; no historical report is published as current.' }
    $bili=Read-LocalDailyPublicReport -Path (Join-Path $settings.StateRoot "bilibili\Logs\Report-$day.json") -Date $today -Name 'B站' -Enabled $settings.Config.bilibili.enabled
    $heybox=Read-LocalDailyPublicReport -Path (Join-Path $settings.StateRoot "heybox\Logs\Report-$day.json") -Date $today -Name '小黑盒' -Enabled $settings.Config.heybox.enabled
    $bili=Set-LocalDailyReportContext -Report $bili -ReportOnly ([bool]$ReportOnly) -Launch ($starts | Where-Object {$_.Module -eq 'bilibili'} | Select-Object -First 1)
    $heybox=Set-LocalDailyReportContext -Report $heybox -ReportOnly ([bool]$ReportOnly) -Launch ($starts | Where-Object {$_.Module -eq 'heybox'} | Select-Object -First 1)
    $combined=[ordered]@{Date=$today;ObservedAt=(Get-Date -Format o);ReportOnly=[bool]$ReportOnly;Launches=$starts;Bilibili=$bili;Heybox=$heybox}
    $output=Join-Path $settings.StateRoot "reports\Combined-$day.json"
    Write-LocalDailyJson -Path $output -Value $combined
    & (Join-Path $PSScriptRoot 'Format-Report.ps1') -ReportPath $output | Out-Null
    Write-Output ('Safe combined report: '+$output)
} finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
