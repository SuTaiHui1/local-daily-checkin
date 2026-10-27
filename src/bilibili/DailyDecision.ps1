function Get-DailyRunDecision {
  param([datetime]$Now,[switch]$Scheduled,$Summary,$DailyConfig,[bool]$Attempted=$false)
  $today=$Now.ToString('yyyy-MM-dd')
  $coinTarget=[Math]::Max(0,[Math]::Min(5,[int]$DailyConfig.NumberOfCoins))
  $completed=$false
  $sameDayEvidence=$false
  if($null -ne $Summary){
    try {
      $observed=[datetimeoffset]::Parse($Summary.ObservedAt).ToOffset([timespan]::FromHours(8)).DateTime
      $sameDayEvidence=$Summary.Date -ceq $today -and $observed.ToString('yyyy-MM-dd') -ceq $today -and $observed -le $Now -and $Summary.DailyRunLog -cmatch ('^Daily-'+$today.Replace('-','')+'-\d{6}\.txt$')
    } catch {}
  }
  if($sameDayEvidence -and $Summary.Status -eq 'ConfirmedDailyTaskRewards') {
    $loginDone=$Summary.LoginExperience -ge 5
    $watchDone=(-not $DailyConfig.IsWatchVideo) -or $Summary.WatchExperience -ge 5
    $shareDone=(-not $DailyConfig.IsShareVideo) -or $Summary.ShareExperience -ge 5
    $coinsDone=$Summary.CoinExperience -ge (10*$coinTarget) -or ($DailyConfig.SaveCoinsWhenLv6 -and $Summary.CurrentLevel -ge 6)
    $completed=$loginDone -and $watchDone -and $shareDone -and $coinsDone
  }
  if($completed){return [pscustomobject]@{Action='SkipCompleted';RunDate=$today;WaitSeconds=0;CoinTarget=$coinTarget}}
  if($Attempted){return [pscustomobject]@{Action='SkipAttempted';RunDate=$today;WaitSeconds=0;CoinTarget=$coinTarget}}
  $due=$Now.Date.AddHours(20)
  if($Scheduled -and $Now -lt $due) {
    if($Now -ge $due.AddMinutes(-5)) {
      return [pscustomobject]@{Action='WaitUntil20';RunDate=$today;WaitSeconds=[int][Math]::Ceiling(($due-$Now).TotalSeconds);CoinTarget=$coinTarget}
    }
    return [pscustomobject]@{Action='SkipBeforeTodaySchedule';RunDate=$today;WaitSeconds=0;CoinTarget=$coinTarget}
  }
  return [pscustomobject]@{Action='RunToday';RunDate=$today;WaitSeconds=0;CoinTarget=$coinTarget}
}
