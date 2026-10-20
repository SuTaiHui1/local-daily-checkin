[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$StateRoot,[string]$Action='Status',[string]$DailyLog)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$logDir=Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$today=(Get-Date).ToString('yyyy-MM-dd')
$stamp=(Get-Date).ToString('yyyyMMdd')
$reportPath=Join-Path $logDir ('Report-'+$stamp+'.json')
$summaryPath=Join-Path $logDir ('Experience-'+$stamp+'.json')
$details=$null; $detailsPath=$null; $summary=$null; $summarySource='Unavailable'; $lines=@(); $donations=@(); $nativeCoins=0
$reason=$null
if(Test-Path -LiteralPath (Join-Path $root 'daily-paused.txt')){$reason='LocalExecutionPaused'}
if($DailyLog -and (Test-Path -LiteralPath $DailyLog)) {
    if([IO.Path]::GetFileName($DailyLog) -notmatch ('^Daily-'+$stamp+'-\d{6}\.txt$')){throw 'DailyLogDateMismatch'}
    $lines=@(Get-Content -LiteralPath $DailyLog -Encoding UTF8)
    $nativeCoins=@($lines | Where-Object {$_ -match '投币成功，经验\+10'}).Count
}
if(Test-Path -LiteralPath $summaryPath) {
    try {
        $candidate=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $observed=[datetimeoffset]::Parse($candidate.ObservedAt)
        $logName=[string]$candidate.DailyRunLog
        if($candidate.Date -eq $today -and $observed.LocalDateTime.Date -eq (Get-Date).Date -and $logName -match ('^Daily-'+$stamp+'-\d{6}\.txt$') -and (Test-Path -LiteralPath (Join-Path $logDir $logName))) {
            if($Action -eq 'RanToday') {
                if($DailyLog -and $logName -ceq [IO.Path]::GetFileName($DailyLog) -and $observed.LocalDateTime -ge (Get-Item -LiteralPath $DailyLog).LastWriteTime){$summary=$candidate;$summarySource='CurrentRun'}
            } else {$summary=$candidate;$summarySource='LastConfirmedToday'}
        }
    } catch { $reason='SummaryValidationFailed' }
}
$rewardConfirmed=$summary -and $summary.Status -eq 'ConfirmedDailyTaskRewards'
$todayCoins=if($rewardConfirmed -and $null -ne $summary.CoinExperience){[int]$summary.CoinExperience/10}else{$null}
if($Action -in @('SkipCompleted','Paused','SkipBeforeTodaySchedule','Status')){$nativeCoins=0}
if($summary) {
    $detailsName=[string]$summary.CoinDetailsFile
    if($detailsName -match ('^CoinDetails-Daily-'+$stamp+'-\d{6}\.json$')) {
        $detailsPath=Join-Path $logDir $detailsName
    }
} elseif($DailyLog) {$detailsPath=Join-Path $logDir ('CoinDetails-'+[IO.Path]::GetFileNameWithoutExtension($DailyLog)+'.json')}
if($detailsPath -and (Test-Path -LiteralPath $detailsPath)) {
    try {
        $details=Get-Content -LiteralPath $detailsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expectedLog=if($summary){$summary.DailyRunLog}else{[IO.Path]::GetFileName($DailyLog)}
        if($details.Date -eq $today -and $details.DailyRunLog -ceq $expectedLog -and ([datetimeoffset]::Parse($details.ObservedAt)).LocalDateTime.Date -eq (Get-Date).Date) {
            $donations=@($details.Donations | ForEach-Object {
                $title=if($_.Title){[string]$_.Title}else{'未确认'}
                if($title.Length -gt 10){$title=$title.Substring(0,10)+'…'}
                [pscustomobject]@{UpName=$(if($_.UpName){$_.UpName}else{'未确认'});Title=$title;Coins=$_.Coins;Verified=$_.Verified}
            })
        }
    } catch {$reason='DonationSummaryUnavailable'}
}
$tasks=[ordered]@{}
foreach($entry in @(@('Login','登录','LoginExperience','登录成功'),@('Watch','观看','WatchExperience','观看视频成功|视频观看成功'),@('Share','分享','ShareExperience','分享视频成功|视频分享成功'),@('Coin','投币','CoinExperience','投币成功'))) {
    $key=$entry[0]; $value=$null
    if($rewardConfirmed -and $null -ne $summary.($entry[2])){$value=$summary.($entry[2])}
    $result='未确认'
    if($Action -eq 'Paused'){$result='因暂停未执行'}
    elseif($Action -eq 'SkipBeforeTodaySchedule'){$result='未到当天20:00，未执行'}
    elseif($Action -eq 'SkipCompleted'){$result='今天已完成，本次跳过'}
    elseif($Action -eq 'Status'){$result='仅查看本地记录'}
    elseif(@($lines | Where-Object {$_ -match $entry[3]}).Count -gt 0){$result='本次成功'}
    elseif($key -eq 'Coin' -and @($lines | Where-Object {$_ -match '已达到停止投币等级|已完成投币任务|余额不足|余额达到或低于保留值'}).Count -gt 0){$result='按当日进度、余额或Lv6规则跳过'}
    elseif(@($lines | Where-Object {$_ -match 'RiskControlStopped'}).Count -gt 0){$result='风控后停止或未确认'}
    if($key -eq 'Coin'){$result+='；今日累计'+$(if($null -ne $todayCoins){$todayCoins}else{'未确认'})+'枚，本次新增'+$nativeCoins+'枚'}
    $tasks[$key]=[pscustomobject]@{Key=$key;Label=$entry[1];Result=$result;DailyExperience=$value}
}
$loginCoin='未确认'
if($summary.LoginCoinStatus -eq 'Confirmed' -and $summary.LoginCoinAmount -eq 1 -and ([string]$summary.LoginCoinRewardTime).StartsWith($today+' ')){$loginCoin='今日已到账 +1枚（'+$summary.LoginCoinRewardTime+'）'}
elseif($summary.LoginCoinStatus -eq 'NotFound'){$loginCoin='本次未查到今日登录奖励记录，到账未确认'}
$summaryRows=@(
    [pscustomobject]@{Label='登录奖励硬币';Value=$loginCoin},
    [pscustomobject]@{Label='今日累计常规任务经验';Value=$(if($rewardConfirmed){$summary.DailyTaskExperience}else{'未确认'})},
    [pscustomobject]@{Label='当前等级与经验';Value=$(if($null -ne $summary.CurrentLevel -and $null -ne $summary.CurrentExperience){'Lv'+$summary.CurrentLevel+'，'+$summary.CurrentExperience+'经验'}else{'未确认'})},
    [pscustomobject]@{Label='距离Lv6还差的经验';Value=$(if($null -ne $summary.RemainingToLv6){$summary.RemainingToLv6}else{'未确认'})},
    [pscustomobject]@{Label='预计升级天数（考虑余额与每日登录1枚）';Value=$(if($null -ne $summary.EstimatedDaysToLv6){[string]$summary.EstimatedDaysToLv6+'天（估计）'}else{'未确认'})},
    [pscustomobject]@{Label='当前硬币余额';Value=$(if($null -ne $summary.CoinBalance){$summary.CoinBalance}else{'未确认'})},
    [pscustomobject]@{Label='运行记录';Value=$(if($DailyLog -and (Test-Path -LiteralPath $DailyLog)){$DailyLog}elseif($summary){Join-Path $logDir $summary.DailyRunLog}else{'未确认'})}
)
$result=[ordered]@{Date=$today;ObservedAt=(Get-Date).ToString('o');Status=$Action;Reason=$reason;DailyLog=$DailyLog;SummarySource=$summarySource;SummaryObservedAt=$summary.ObservedAt;Tasks=$tasks;NativeSuccessCoins=$nativeCoins;TodayCoins=$todayCoins;Experience=$summary;CoinDonations=$donations;DonationScope=$details.Scope;PublicTasks=@($tasks.Values);PublicSummary=$summaryRows}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8
[pscustomobject]@{ReportPath=$reportPath;Status=$Action;NativeSuccessCoins=$nativeCoins}
