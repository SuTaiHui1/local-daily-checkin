$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('local-daily-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$checks=0
function Assert-Fixture([bool]$Condition,[string]$Name){if(-not $Condition){throw ('Synthetic coordinator check failed: '+$Name)};$script:checks++}
try {
    $date=Get-Date -Format 'yyyy-MM-dd';$day=Get-Date -Format 'yyyyMMdd'
    $state=Join-Path $temporary 'state';$config=Join-Path $temporary 'config.json'
    $settings=@{schemaVersion=1;stateRoot=$state;schedule=@{localTime='20:00';timeZone='Asia/Shanghai'};bilibili=@{enabled=$false};heybox=@{enabled=$false}}
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null
    $combined=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Fixture ($combined.Bilibili.Status -eq 'Disabled' -and $combined.Heybox.Status -eq 'Disabled') 'disabled platforms stay disabled'
    Assert-Fixture (@($combined.Launches).Count -eq 0) 'report-only starts no launcher'
    Assert-Fixture ('SummarySource' -notin @($combined.Bilibili.PSObject.Properties.Name)) 'disabled module without data is not described as a confirmed snapshot'
    foreach($name in @('bilibili','heybox')) {
        $folder=Join-Path $state "$name\Logs";$null=New-Item -ItemType Directory -Path $folder -Force
        $fixture=@{Date=$date;ObservedAt=(Get-Date -Format o);Status='SyntheticConfirmed';Reason=$null;PublicTasks=@(@{Key='fixture';Label='合成任务';Result='已完成';DailyExperience=7});PublicSummary=@(@{Label='合成余额';Value='20'});CoinDonations=@()}
        $fixture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder "Report-$day.json") -Encoding UTF8
    }
    $settings.bilibili.enabled=$true;$settings.heybox.enabled=$true
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null
    $markdown=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.md") -Raw -Encoding UTF8
    Assert-Fixture ($markdown -match '合成任务' -and $markdown -match '小黑盒' -and $markdown -match 'B站') 'both safe reports formatted'
    Assert-Fixture ($markdown -match '本轮仅查看' -and $markdown -match '非本轮执行') 'read-only never claims a new successful action'
    . (Join-Path $repository 'scripts\Common.ps1')
    $past=[pscustomobject]@{Date=$date;ObservedAt=([datetimeoffset]::Now.AddMinutes(-10).ToString('o'));Status='SyntheticPastSuccess';PublicTasks=@();PublicSummary=@();CoinDonations=@()}
    $failed=[pscustomobject]@{ExitCode=5;StartedAt=([datetimeoffset]::Now.ToString('o'))}
    $context=Set-LocalDailyReportContext -Report $past -ReportOnly $false -Launch $failed
    Assert-Fixture ($context.SummarySource -eq 'LastConfirmedToday' -and -not $context.NewObservation -and $context.InvocationIssue) 'failed launch labels old successful report as previous data'
    $rejectedInstall=$false
    try { & (Join-Path $repository 'scripts\Install-Heybox.ps1') -StateRoot $repository | Out-Null } catch { $rejectedInstall=$_.Exception.Message -match 'outside this repository' }
    Assert-Fixture $rejectedInstall 'Heybox installer rejects exact checkout root before other setup'
    $old=@{Date='2000-01-01';Status='OldFixture'}
    $old | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state "heybox\Logs\Report-$day.json") -Encoding UTF8
    & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null
    $combined=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Fixture ($combined.Heybox.Status -eq 'Unconfirmed' -and $combined.Bilibili.Status -eq 'SyntheticConfirmed') 'stale module isolated without hiding good module'
    $settings.stateRoot=$repository
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    $rejected=$false
    try { & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null } catch { $rejected=$true }
    Assert-Fixture $rejected 'private state inside checkout rejected'
    Write-Output ("Coordinator synthetic checks: $checks passed; no account module started.")
} finally {
    $target=[IO.Path]::GetFullPath($temporary)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $target.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^local-daily-fixture-[a-f0-9]{32}$'){throw 'Unexpected fixture cleanup target'}
    Remove-Item -LiteralPath $target -Recurse -Force
}
