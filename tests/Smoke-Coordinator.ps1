# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('local-daily-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$checks=0
function Assert-Fixture([bool]$Condition,[string]$Name){if(-not $Condition){throw ('Synthetic coordinator check failed: '+$Name)};$script:checks++}
function New-SyntheticReport([string]$Name) {
    $fixture=@{
        Date=$date;ObservedAt=$fixtureTime;SummaryObservedAt=$fixtureTime;Status='SyntheticConfirmed';Reason=$null
        PublicTasks=@();PublicSummary=@();CoinDonations=@();NewObservation=$true
        NativeSuccessCoins=5;TodayCoins=5;ActionsSubmittedThisInvocation=4
    }
    if($Name -eq 'bilibili') {
        $fixture.PublicTasks=@(
            @{Key='Login';Label='登录';Result='已确认奖励';DailyExperience=5},
            @{Key='Watch';Label='观看';Result='已确认奖励';DailyExperience=5},
            @{Key='Share';Label='分享';Result='已确认奖励';DailyExperience=5},
            @{Key='Coin';Label='投币';Result='已确认奖励；今日累计5枚，本次新增5枚';DailyExperience=50}
        )
        $fixture.PublicSummary=@(
            @{Label='登录奖励硬币';Value='今日已到账 +1枚'},
            @{Label='今日累计常规任务经验';Value=65},
            @{Label='当前等级与经验';Value='Lv4，15000经验'},
            @{Label='距离Lv6还差的经验';Value=13800},
            @{Label='预计升级天数（考虑余额与每日登录1枚）';Value='400天（估计）'},
            @{Label='当前硬币余额';Value=20},
            @{Label='运行记录';Value=(Join-Path $temporary ('synthetic Daily-'+$day+'-200000.txt'))}
        )
        $fixture.CoinDonations=@(@{UpName='合成UP';Title='合成测试标题超出八个字符';Coins=2;Verified=$true})
        $fixture.DonationScope='ObservedDailyPlatformSpending'
    } else {
        $fixture.PublicTasks=@(
            @{Key='sign';Label='签到';Result='已确认奖励';DailyExperience=100},
            @{Key='1';Label='分享帖子';Result='已确认奖励';DailyExperience=10},
            @{Key='19';Label='分享游戏详情';Result='已确认奖励';DailyExperience=10},
            @{Key='31';Label='分享游戏评价';Result='已确认奖励';DailyExperience=10}
        )
        $fixture.PublicSummary=@(
            @{Label='今日四项任务经验';Value=130},
            @{Label='当前等级';Value=5},
            @{Label='当前经验进度';Value='500/1000'},
            @{Label='下一等级';Value=6},
            @{Label='距下一级经验';Value=500},
            @{Label='预计升级天数（估算）';Value=4},
            @{Label='H币余额';Value=100},
            @{Label='今日签到H币奖励';Value=20},
            @{Label='连续签到天数';Value=3}
        )
        $fixture.RecordFile=Join-Path $temporary ('synthetic Daily-'+$day+'.json')
        $fixture.ProfileObservedAt=$fixtureTime
        $fixture.SnapshotObservedAt=$fixtureTime
        $fixture.ShareMode='UserAuthorizedSimulatedRegistration'
        $fixture.ExternalSocialMessagesSent=0
    }
    return ($fixture | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}
function Write-SyntheticCombined([object]$Bilibili,[object]$Heybox,[bool]$Only=$false) {
    $path=Join-Path $temporary 'render.json'
    @{Date=$date;ObservedAt=$renderTime;ReportOnly=$Only;Bilibili=$Bilibili;Heybox=$Heybox} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    & (Join-Path $repository 'scripts\Format-Report.ps1') -ReportPath $path | Out-Null
    return Get-Content -LiteralPath ([IO.Path]::ChangeExtension($path,'.md')) -Raw -Encoding UTF8
}
try {
    $date=Get-Date -Format 'yyyy-MM-dd';$day=Get-Date -Format 'yyyyMMdd'
    $fixtureTime=([datetimeoffset]::Now.AddMinutes(-10)).ToString('o')
    $renderTime=([datetimeoffset]::Now).ToString('o')
    $state=Join-Path $temporary 'state';$config=Join-Path $temporary 'config.json'
    $settings=@{schemaVersion=1;stateRoot=$state;schedule=@{localTime='20:00';timeZone='Asia/Shanghai'};bilibili=@{enabled=$false};heybox=@{enabled=$false}}
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null
    $combined=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $markdown=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.md") -Raw -Encoding UTF8
    Assert-Fixture ($combined.Bilibili.Status -eq 'Disabled' -and $combined.Heybox.Status -eq 'Disabled') 'disabled platforms stay disabled'
    Assert-Fixture (@($combined.Launches).Count -eq 0) 'report-only starts no launcher'
    Assert-Fixture ('SummarySource' -notin @($combined.Bilibili.PSObject.Properties.Name)) 'disabled module without data is not described as a confirmed snapshot'
    Assert-Fixture ([regex]::Matches($markdown,'(?m)^\| (登录|观看|分享|投币|签到|分享帖子|分享游戏详情|分享游戏评价) \| 未确认 \| 未确认 \|').Count -eq 8) 'missing modules retain eight explicit unconfirmed task rows'
    Assert-Fixture ($markdown -notmatch '未向外部社交平台发送消息') 'missing share evidence is not presented as confirmed'
    foreach($name in @('bilibili','heybox')) {
        $folder=Join-Path $state "$name\Logs";$null=New-Item -ItemType Directory -Path $folder -Force
        New-SyntheticReport $name | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $folder "Report-$day.json") -Encoding UTF8
    }
    $settings.bilibili.enabled=$true;$settings.heybox.enabled=$true
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    & (Join-Path $repository 'scripts\Run-Daily.ps1') -ConfigPath $config -ReportOnly | Out-Null
    $combined=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $markdown=Get-Content -LiteralPath (Join-Path $state "reports\Combined-$day.md") -Raw -Encoding UTF8
    Assert-Fixture ([regex]::Matches($markdown,'(?m)^\| (登录|观看|分享|投币|签到|分享帖子|分享游戏详情|分享游戏评价) \|').Count -eq 8) 'both reports have exactly four fixed task rows'
    Assert-Fixture ($markdown -match '本轮仅查看' -and $markdown -match '非本轮执行') 'read-only never claims a new successful action'
    Assert-Fixture ($combined.Bilibili.NativeSuccessCoins -eq 0 -and $combined.Heybox.ActionsSubmittedThisInvocation -eq 0 -and $combined.Bilibili.TodayCoins -eq 5) 'read-only clears invocation counts while retaining daily coin total'
    Assert-Fixture ($markdown -match 'B站本轮新增投币：0 枚；今日任务投币累计：5 枚' -and $markdown -match '小黑盒本轮提交尝试：0 项' -and $markdown -notmatch '本次新增5枚') 'read-only header and coin row cannot reuse previous invocation counts'
    Assert-Fixture ($markdown.Contains($fixtureTime) -and $combined.Heybox.SummaryObservedAt -eq $fixtureTime -and $combined.Bilibili.SummaryObservedAt -eq $fixtureTime) 'actual confirmation times survive report-only'
    Assert-Fixture ($markdown -match '当前等级与经验：Lv4，15000经验' -and $markdown -match '当前硬币余额：20' -and $markdown -match '400天（估计）') 'Bilibili fixed summaries include balance and finite-balance estimate'
    Assert-Fixture ($markdown -match '今日四项任务经验：130' -and $markdown -match 'Lv5；500/1000' -and $markdown -match 'Lv6；还差 500' -and $markdown -match '连续 3 天') 'Heybox fixed summaries include reward level progress and streak'
    Assert-Fixture ($markdown -match '可能包含手动投币' -and $markdown -match '合成UP｜合成测试标题超出…｜2 枚') 'daily platform ledger scope and concise donation lines preserved'
    Assert-Fixture ($markdown -match '三项分享采用用户授权的模拟登记；未向外部社交平台发送消息') 'known simulated sharing semantics are explicit'
    Assert-Fixture ($markdown -match '\[本机记录\]\(<' -and $markdown -match '报告生成时间：' -and $markdown -match '此时间不替代') 'local record links and generated time are distinct from observation time'
    $expectedDate=([datetime]::ParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy年M月d日')
    Assert-Fixture ($markdown.Contains('## B站 · '+$expectedDate) -and $markdown.Contains('## 小黑盒 · '+$expectedDate)) 'both platform headings use the report date in Chinese'

    . (Join-Path $repository 'scripts\Common.ps1')
    $past=New-SyntheticReport 'bilibili'
    $pastHeybox=New-SyntheticReport 'heybox'
    $failed=[pscustomobject]@{ExitCode=5;StartedAt=$renderTime}
    $context=Set-LocalDailyReportContext -Report $past -ReportOnly $false -Launch $failed
    $heyboxContext=Set-LocalDailyReportContext -Report $pastHeybox -ReportOnly $false -Launch $failed
    Assert-Fixture ($context.SummarySource -eq 'LastConfirmedToday' -and -not $context.NewObservation -and $context.InvocationIssue) 'failed launch labels old successful report as previous data'
    Assert-Fixture ($null -eq $context.NativeSuccessCoins -and $null -eq $heyboxContext.ActionsSubmittedThisInvocation) 'failed new invocation cannot turn unknown effects into zero'
    $failedMarkdown=Write-SyntheticCombined $context $heyboxContext
    Assert-Fixture ($failedMarkdown -match 'B站本轮新增投币：未确认 枚' -and $failedMarkdown -match '小黑盒本轮提交尝试：未确认 项' -and $failedMarkdown -match '没有自动重试') 'failed invocation shows unknown new counts and retained failure'
    Assert-Fixture ($failedMarkdown.Contains($fixtureTime) -and $failedMarkdown -notmatch '本次新增5枚') 'failed old snapshot retains real time without stale invocation count'

    $localOnly=[pscustomobject]@{ExitCode=0;StartedAt=$renderTime;LocalOnly=$true;PreparationStatus='ReadyForBrowser'}
    $pending=Set-LocalDailyReportContext -Report (New-SyntheticReport 'bilibili') -ReportOnly $false -Launch $localOnly
    $pendingMarkdown=Write-SyntheticCombined $pending $heyboxContext
    Assert-Fixture ($pending.NativeSuccessCoins -eq 0 -and -not $pending.NewObservation -and $pending.InvocationStatus -eq 'ReadyForBrowser') 'local-only browser preparation submits no account task'
    Assert-Fixture ($pendingMarkdown -match 'B站本轮新增投币：0 枚' -and $pendingMarkdown -match '本轮仅完成本地前置检查' -and $pendingMarkdown -match 'ReadyForBrowser') 'pending browser preparation is visible with zero new coins'

    $nativeOnly=New-SyntheticReport 'bilibili'
    $nativeOnly.DonationScope='NativeLogOnly'
    $nativeMarkdown=Write-SyntheticCombined $nativeOnly (New-SyntheticReport 'heybox')
    Assert-Fixture ($nativeMarkdown -match '仅本机执行日志；未由平台当日账本核验' -and $nativeMarkdown -notmatch '可能包含手动投币') 'native-only donations do not claim platform daily ledger scope'
    $missingTask=New-SyntheticReport 'heybox'
    $missingTask.PublicTasks=@($missingTask.PublicTasks | Where-Object {$_.Key -ne '31'})
    $missingMarkdown=Write-SyntheticCombined $nativeOnly $missingTask
    Assert-Fixture ($missingMarkdown -match '\| 分享游戏评价 \| 未确认 \| 未确认 \|') 'one missing task stays visible and unconfirmed'

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
