[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DailyDecision.ps1')
. (Join-Path $PSScriptRoot 'Forecast.ps1')
. (Join-Path $PSScriptRoot 'CoinDetails.ps1')
. (Join-Path $PSScriptRoot 'Policy.ps1')
$checks=0
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual -cne $Expected){throw ('Offline assertion failed: '+$Message+'; actual='+$Actual)};$script:checks++}
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'appsettings.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-BilibiliConfig $config
$day=[datetime]'2030-01-02 20:10:00'
$complete=[pscustomobject]@{Date='2030-01-02';ObservedAt='2030-01-02T20:05:00+08:00';DailyRunLog='Daily-20300102-200000.txt';Status='ConfirmedDailyTaskRewards';LoginExperience=5;WatchExperience=5;ShareExperience=5;CoinExperience=50;CurrentLevel=5}
Assert-Equal (Get-DailyRunDecision -Now $day -Scheduled -Summary $null -DailyConfig $config.DailyTaskConfig).Action 'RunToday' 'late run only current day'
Assert-Equal (Get-DailyRunDecision -Now $day -Scheduled -Summary $complete -DailyConfig $config.DailyTaskConfig).Action 'SkipCompleted' 'completed does not run'
Assert-Equal (Get-DailyRunDecision -Now ([datetime]'2030-01-03 09:00:00') -Scheduled -Summary $complete -DailyConfig $config.DailyTaskConfig).Action 'SkipBeforeTodaySchedule' 'no backfill before next day schedule'
Assert-Equal (Get-DailyRunDecision -Now ([datetime]'2030-01-02 19:57:00') -Scheduled -Summary $null -DailyConfig $config.DailyTaskConfig).Action 'WaitUntil20' 'small early wake waits'
$complete.CurrentLevel=6;$complete.CoinExperience=0
Assert-Equal (Get-DailyRunDecision -Now $day -Scheduled -Summary $complete -DailyConfig $config.DailyTaskConfig).Action 'SkipCompleted' 'Lv6 does not spend coins'
$complete.CurrentLevel=5;$complete.CoinExperience=40
Assert-Equal (Get-DailyRunDecision -Now $day -Scheduled -Summary $complete -DailyConfig $config.DailyTaskConfig).Action 'RunToday' 'partial completion delegates to upstream progress check'
Assert-Equal (Get-Level6Forecast -Remaining 130 -CoinBalance 100 -CoinTarget 5 -ProtectedCoins 0 -WatchEnabled $true -ShareEnabled $true).EstimatedDaysToLv6 2 'full balance forecast'
Assert-Equal (Get-Level6Forecast -Remaining 100 -CoinBalance 0 -CoinTarget 5 -ProtectedCoins 0 -WatchEnabled $true -ShareEnabled $true).EstimatedDaysToLv6 4 'balance limited forecast'
Assert-Equal (Get-Level6Forecast -Remaining 0 -CoinBalance 0 -CoinTarget 5 -ProtectedCoins 0 -WatchEnabled $true -ShareEnabled $true).EstimatedDaysToLv6 0 'Lv6 forecast zero'
Assert-Equal (Test-BilibiliRiskLine 'API code -352') $true 'risk detection'
Assert-Equal (ConvertTo-SafeBilibiliLogLine 'Cookie: synthetic-test-only') $null 'credentials excluded'
Assert-Equal (ConvertTo-SafeBilibiliLogLine 'https://example.invalid/private?token=synthetic') $null 'requests excluded'
Assert-Equal (ConvertTo-SafeBilibiliLogLine '"response_message": "投币"') $null 'multiline response excluded'
Assert-Equal (ConvertTo-SafeBilibiliLogLine '[01:00:02 INF] 投币成功，经验+10') '[01:00:02 INF] 投币成功，经验+10' 'business record retained'
$mutated=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'appsettings.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$mutated.DailyTaskConfig.SelectLike=$true
$rejected=$false
try{Assert-BilibiliConfig $mutated}catch{$rejected=$true}
Assert-Equal $rejected $true 'extra like policy rejected'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('LocalDailyCheckin-BiliTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'Logs') -Force | Out-Null
try {
    $stamp=Get-Date -Format 'yyyyMMdd';$today=Get-Date -Format 'yyyy-MM-dd'
    $logName='Daily-'+$stamp+'-010000.txt';$log=Join-Path $fixture ('Logs\'+$logName)
    @(('DAILY_RUN Started Nonce='+('a'*32)+' Date='+$today),'DAILY_COINS Initial Already=4','DAILY_COINS Accepted NativeSuccessCoins=1 AccountedDailyCoins=5',('DAILY_RUN Completed Nonce='+('a'*32)),'[01:00:00 INF] 登录成功，经验+5','[01:00:01 INF] 【视频】仅用于离线测试的标题','[01:00:02 INF] 投币成功，经验+10','[01:00:03 INF] FlowCompleted DailyTask') | Set-Content -LiteralPath $log -Encoding UTF8
    $ledger=[pscustomobject]@{list=@([pscustomobject]@{time=($today+' 01:00:02');delta=-1;reason='给视频 BV1234567890 打赏'})}
    $script:resolveCount=0
    $details=New-CoinDonationReport -DailyLog $log -CoinLogData $ledger -ResolveVideo {param($bv) $script:resolveCount++;[pscustomobject]@{bvid=$bv;title='仅用于离线测试的标题';owner=[pscustomobject]@{name='测试UP'}}}
    Assert-Equal $details.NativeSuccessCoins 1 'native success count'
    Assert-Equal $script:resolveCount 1 'unique video metadata callback once'
    Assert-Equal $details.Donations[0].UpName '测试UP' 'mock metadata used'
    $manyEntries=@(0..5 | ForEach-Object {[pscustomobject]@{time=($today+' 01:00:02');delta=-1;reason=('给视频 BV123456789'+$_+' 打赏')}})
    $script:resolveCount=0
    $bounded=New-CoinDonationReport -DailyLog $log -CoinLogData ([pscustomobject]@{list=$manyEntries}) -ResolveVideo {param($bv) $script:resolveCount++;[pscustomobject]@{bvid=$bv;title='mock';owner=[pscustomobject]@{name='mock'}}}
    Assert-Equal $script:resolveCount 5 'metadata bounded at five requests'
    Assert-Equal $bounded.MetadataRequests 5 'request counter agrees'
    $riskDetails=New-CoinDonationReport -DailyLog $log -CoinLogData $ledger -ResolveVideo {throw 'PlatformVerificationRequired'}
    Assert-Equal $riskDetails.RiskControlEncountered $true 'risk stops metadata resolution'
    $detailName='CoinDetails-'+[IO.Path]::GetFileNameWithoutExtension($log)+'.json'
    $details | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture ('Logs\'+$detailName)) -Encoding UTF8
    $summary=[ordered]@{Date=$today;DailyRunLog=$logName;RunNonce=('a'*32);NativeCompletedAt=(Get-Date).AddSeconds(-2).ToString('o');ObservedAt=(Get-Date).AddSeconds(-1).ToString('o');SummaryComplete=$true;Status='ConfirmedDailyTaskRewards';DailyTaskExperience=65;LoginExperience=5;WatchExperience=5;ShareExperience=5;CoinExperience=50;CurrentLevel=5;CurrentExperience=24000;RemainingToLv6=4800;CoinBalance=50;EstimatedDaysToLv6=100;LoginCoinStatus='Confirmed';LoginCoinAmount=1;LoginCoinRewardTime=($today+' 00:00:00');CoinDetailsFile=$detailName}
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture ('Logs\Experience-'+$stamp+'.json')) -Encoding UTF8
    @{Date=$today;InvocationObservedAt=(Get-Date).ToString('o');DailyRunLog=$logName;RunNonce=('a'*32);NativeSuccessCoins=1;NativeLaunches=1;Status='ConfirmedDailyTaskRewards'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'Logs\last-invocation.json') -Encoding UTF8
    $null=& (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $fixture -Action 'RanToday' -DailyLog $log
    $report=Get-Content -LiteralPath (Join-Path $fixture ('Logs\Report-'+$stamp+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $report.NativeSuccessCoins 1 'report native increment'
    Assert-Equal $report.TodayCoins 5 'report platform daily total separate from increment'
    Assert-Equal $report.SummarySource 'CurrentRun' 'matching fresh evidence'
    Assert-Equal @($report.PublicTasks).Count 4 'four task rows'
    Assert-Equal @($report.PublicSummary).Count 7 'seven summary rows'
    Assert-Equal $report.CoinDonations[0].Title '仅用于离线测试的标题' 'short title'
    $badInvocation=@{Date=$today;InvocationObservedAt=(Get-Date).AddDays(1).ToString('o');DailyRunLog=$logName;RunNonce=('a'*32);NativeSuccessCoins=1;NativeLaunches=1}
    $badInvocation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'Logs\last-invocation.json') -Encoding UTF8
    $null=& (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $fixture -Action 'RanToday' -DailyLog $log
    $unconfirmed=Get-Content -LiteralPath (Join-Path $fixture ('Logs\Report-'+$stamp+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $unconfirmed.NativeSuccessCoins $null 'future invocation cannot supply current increment'
    Assert-Equal $unconfirmed.SummarySource 'Unavailable' 'future invocation cannot attribute current summary'
    $outsideRejected=$false
    try { $null=& (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $fixture -Action 'RanToday' -DailyLog (Join-Path $fixture $logName) } catch {$outsideRejected=$true}
    Assert-Equal $outsideRejected $true 'run log must belong to the same logs directory'
    $null=& (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $fixture -Action 'SkipCompleted'
    $report=Get-Content -LiteralPath (Join-Path $fixture ('Logs\Report-'+$stamp+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $report.NativeSuccessCoins 0 'skip increments zero'
    Assert-Equal $report.SummarySource 'LastConfirmedToday' 'skip labels previous observation'
} finally {
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $target=[IO.Path]::GetFullPath($fixture)
    if($target.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target) -like 'LocalDailyCheckin-BiliTest-*'){Remove-Item -LiteralPath $target -Recurse -Force}
}
[pscustomobject]@{Status='Passed';Checks=$checks;NetworkRequests=0;NativeToolStarted=$false;ActualAccountUsed=$false}
