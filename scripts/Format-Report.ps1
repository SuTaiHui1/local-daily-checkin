param([Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
$report=Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Cell([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '未确认' }
    return ([string]$Value).Replace('|','／').Replace("`r",' ').Replace("`n",' ')
}
$lines=New-Object 'Collections.Generic.List[string]'
$lines.Add(('# '+$report.Date+' 每日任务结果'))
if($report.ReportOnly){$lines.Add('');$lines.Add('本轮仅查看已有记录，没有启动账户任务或请求平台。')}
foreach($entry in @(@{Title='B站';Data=$report.Bilibili},@{Title='小黑盒';Data=$report.Heybox})) {
    $data=$entry.Data
    $properties=@($data.PSObject.Properties.Name)
    $lines.Add('');$lines.Add(('## '+$entry.Title));$lines.Add('')
    $lines.Add(('状态：'+(Cell $data.Status)))
    if($data.Reason){$lines.Add((Cell $data.Reason))}
    if('InvocationIssue' -in $properties -and $data.InvocationIssue){$lines.Add(('本轮结果：'+(Cell $data.InvocationIssue)))}
    if('SummarySource' -in $properties -and $data.SummarySource -eq 'LastConfirmedToday') {
        $lines.Add('本轮没有重新查询；以下为当日上次确认值。')
        if('SummaryObservedAt' -in $properties){$lines.Add(('数据确认时间：'+(Cell $data.SummaryObservedAt)))}
    }
    if('NewObservation' -in $properties -and -not $data.NewObservation){$lines.Add('本轮没有新增查询，引用当日已确认记录；缺失项仍为未确认。')}
    $tasks=$data.PublicTasks
    $lines.Add('');$lines.Add('| 任务 | 结果 | 今日经验 |');$lines.Add('| --- | --- | ---: |')
    if($tasks -and @($tasks).Count -gt 0) {
        foreach($task in $tasks){
            $result=Cell $task.Result
            if('ReusedForThisInvocation' -in $properties -and $data.ReusedForThisInvocation){$result='当日记录（非本轮执行）：'+$result}
            $lines.Add(('| '+(Cell $task.Label)+' | '+$result+' | '+(Cell $task.DailyExperience)+' |'))
        }
    } else { $lines.Add('| 未执行或尚未取得记录 | 未确认 | 未确认 |') }
    $lines.Add('')
    foreach($item in $data.PublicSummary){$lines.Add(('- '+(Cell $item.Label)+'：'+(Cell $item.Value)))}
    $donations=$data.CoinDonations
    if($donations -and @($donations).Count -gt 0) {
        $lines.Add('');$lines.Add('今日投币去向（平台当日明细，可能包含手动投币）：');$lines.Add('')
        foreach($donation in $donations) {
            $title=Cell $donation.Title
            if($title.Length -gt 9){$title=$title.Substring(0,8)+'…'}
            $lines.Add(('- '+(Cell $donation.UpName)+'｜'+$title+'｜'+(Cell $donation.Coins)+'枚'))
        }
    }
    if('ProfileObservedAt' -in $properties -and $data.ProfileObservedAt){$lines.Add('');$lines.Add(('账号资料确认时间：'+(Cell $data.ProfileObservedAt)))}
    if('SnapshotObservedAt' -in $properties -and $data.SnapshotObservedAt){$lines.Add(('任务快照时间：'+(Cell $data.SnapshotObservedAt)))}
    if('ObservedAt' -in $properties -and $data.ObservedAt){$lines.Add('');$lines.Add(('报告生成时间：'+(Cell $data.ObservedAt)))}
    if('RecordFile' -in $properties -and $data.RecordFile){$lines.Add(('本机记录：'+(Cell $data.RecordFile)))}
}
$lines.Add('');$lines.Add('经验按各平台当天已确认的任务奖励分别统计；预计天数仅为估算。缺失项不补发请求。')
$destination=[IO.Path]::ChangeExtension($ReportPath,'.md')
$lines | Set-Content -LiteralPath $destination -Encoding UTF8
Write-Output $destination
