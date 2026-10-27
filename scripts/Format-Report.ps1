# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
$report=Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Field([object]$Object,[string]$Name) {
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $null
}
function Cell([object]$Value) {
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return '未确认'}
    return ([string]$Value).Replace('|','／') -replace '[\r\n]',' '
}
function SummaryValue([object]$Data,[string]$Label) {
    foreach($item in @(Field $Data 'PublicSummary')) {
        if((Field $item 'Label') -eq $Label){return Cell (Field $item 'Value')}
    }
    return '未确认'
}
function InvocationCount([object]$Data,[string]$Name) {
    if([bool](Field $report 'ReportOnly')){return 0}
    return Field $Data $Name
}
function LocalLink([object]$Path) {
    if($null -eq $Path -or [string]::IsNullOrWhiteSpace([string]$Path) -or $Path -eq '未确认'){return '未确认'}
    $value=[string]$Path
    if(-not [IO.Path]::IsPathRooted($value) -or $value -match '[\r\n<>]'){return Cell $value}
    return '[本机记录](<'+$value.Replace('\','/').Replace('>','%3E')+'>)'
}
function AddContext([object]$Data) {
    $lines.Add(('状态：'+(Cell (Field $Data 'Status'))))
    foreach($name in @('Reason','InvocationIssue')) {
        $value=Field $Data $name
        if($value){$lines.Add((Cell $value))}
    }
    if([bool](Field $Data 'ReusedForThisInvocation') -or (Field $Data 'SummarySource') -eq 'LastConfirmedToday') {
        $lines.Add('以下引用当日上次确认记录，不代表本轮重新执行或查询。')
    } elseif((Field $Data 'NewObservation') -eq $false) {
        $lines.Add('本轮未新增平台查询；仅展示已有记录，缺失项为未确认。')
    }
}
function AddTasks([object]$Data,[object[]]$Rows) {
    $lines.Add('');$lines.Add('| 任务 | 结果 | 今日经验 |');$lines.Add('| --- | --- | ---: |')
    foreach($row in $Rows) {
        $matches=@(@(Field $Data 'PublicTasks') | Where-Object {(Field $_ 'Key') -eq $row.Key})
        $task=if($matches.Count -eq 1){$matches[0]}else{$null}
        $result=Cell (Field $task 'Result')
        # Counts belong to the current invocation header, not a reused result sentence.
        if($row.Key -eq 'Coin'){$result=$result -replace '；今日累计.*$',''}
        if([bool](Field $Data 'ReusedForThisInvocation') -and $null -ne $task){$result='当日记录（非本轮执行）：'+$result}
        $lines.Add(('| '+$row.Label+' | '+$result+' | '+(Cell (Field $task 'DailyExperience'))+' |'))
    }
}

$lines=New-Object 'Collections.Generic.List[string]'
$dateText=Cell (Field $report 'Date')
try{$dateText=[datetime]::ParseExact($dateText,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).ToString('yyyy年M月d日')}catch{}
$bili=Field $report 'Bilibili';$heybox=Field $report 'Heybox'
$lines.Add(('# '+$dateText+' 每日任务结果'))
$lines.Add('')
$lines.Add(('B站本轮新增投币：'+(Cell (InvocationCount $bili 'NativeSuccessCoins'))+' 枚；今日任务投币累计：'+(Cell (Field $bili 'TodayCoins'))+' 枚。'))
$lines.Add(('小黑盒本轮提交尝试：'+(Cell (InvocationCount $heybox 'ActionsSubmittedThisInvocation'))+' 项；尝试数不等于奖励到账数。'))
if([bool](Field $report 'ReportOnly')){$lines.Add('本轮仅查看已有记录，没有启动账户任务或请求平台。')}

$lines.Add('');$lines.Add(('## B站 · '+$dateText));$lines.Add('')
AddContext $bili
AddTasks $bili @(@{Key='Login';Label='登录'},@{Key='Watch';Label='观看'},@{Key='Share';Label='分享'},@{Key='Coin';Label='投币'})
$lines.Add('')
foreach($label in @('登录奖励硬币','今日累计常规任务经验','当前等级与经验','距离Lv6还差的经验','预计升级天数（考虑余额与每日登录1枚）','当前硬币余额')) {
    $lines.Add(('- '+$label+'：'+(SummaryValue $bili $label)))
}
$biliLog=SummaryValue $bili '运行记录'
if($biliLog -eq '未确认'){$biliLog=Field $bili 'DailyLog'}
$lines.Add(('- 运行记录与确认时间：'+(LocalLink $biliLog)+'；'+(Cell (Field $bili 'SummaryObservedAt'))))
$donations=@(Field $bili 'CoinDonations')
$lines.Add('')
switch(Field $bili 'DonationScope') {
    'ObservedDailyPlatformSpending' {$lines.Add('今日投币去向（平台当日账本，可能包含手动投币，不能全部归于本轮自动任务）：')}
    'NativeLogOnly' {$lines.Add('投币去向（仅本机执行日志；未由平台当日账本核验）：')}
    default {$lines.Add('投币去向（归属范围未确认）：')}
}
if($donations.Count -gt 0 -and $null -ne $donations[0]) {
    foreach($donation in $donations) {
        $title=Cell (Field $donation 'Title')
        if($title.Length -gt 9){$title=$title.Substring(0,8)+'…'}
        $lines.Add(((Cell (Field $donation 'UpName'))+'｜'+$title+'｜'+(Cell (Field $donation 'Coins'))+' 枚'))
    }
} else {$lines.Add('未确认；不为补齐展示追加查询。')}

$lines.Add('');$lines.Add(('## 小黑盒 · '+$dateText));$lines.Add('')
AddContext $heybox
AddTasks $heybox @(@{Key='sign';Label='签到'},@{Key='1';Label='分享帖子'},@{Key='19';Label='分享游戏详情'},@{Key='31';Label='分享游戏评价'})
$lines.Add('')
$lines.Add(('- 今日四项任务经验：'+(SummaryValue $heybox '今日四项任务经验')))
$lines.Add(('- 当前等级与经验进度：Lv'+(SummaryValue $heybox '当前等级')+'；'+(SummaryValue $heybox '当前经验进度')))
$lines.Add(('- 下一等级与所需经验：Lv'+(SummaryValue $heybox '下一等级')+'；还差 '+(SummaryValue $heybox '距下一级经验')))
$lines.Add(('- 预计升级天数（估算）：'+(SummaryValue $heybox '预计升级天数（估算）')))
$lines.Add(('- H币余额：'+(SummaryValue $heybox 'H币余额')))
$lines.Add(('- 今日签到H币奖励与连续签到：'+(SummaryValue $heybox '今日签到H币奖励')+'；连续 '+(SummaryValue $heybox '连续签到天数')+' 天'))
$lines.Add(('- 数据确认时间：任务 '+(Cell (Field $heybox 'SummaryObservedAt'))+'；账号资料 '+(Cell (Field $heybox 'ProfileObservedAt'))))
$lines.Add(('- 运行记录：'+(LocalLink (Field $heybox 'RecordFile'))))
if((Field $heybox 'ShareMode') -eq 'UserAuthorizedSimulatedRegistration' -and (Field $heybox 'ExternalSocialMessagesSent') -eq 0) {
    $lines.Add('三项分享采用用户授权的模拟登记；未向外部社交平台发送消息。')
} else {$lines.Add('分享登记方式及外部消息发送情况：未确认。')}
$lines.Add('');$lines.Add(('报告生成时间：'+(Cell (Field $report 'ObservedAt'))+'。此时间不替代上面的数据确认时间。'))
$lines.Add('经验按各平台当天已确认的任务奖励分别统计；预计天数仅为估算。缺失项不补发请求。')
$destination=[IO.Path]::ChangeExtension($ReportPath,'.md')
$lines | Set-Content -LiteralPath $destination -Encoding UTF8
Write-Output $destination
