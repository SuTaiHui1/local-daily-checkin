$ErrorActionPreference='Stop'

function Get-DailyEvidence {
  param([string[]]$Lines)
  $starts=@();$ends=@();$flows=0;$valid=$true;$failed=$false;$count=$null;$initial=$null;$accounted=$null
  foreach($line in $Lines){
    if($line -match '\bDAILY_RUN Started Nonce=([a-f0-9]{32}) Date=(\d{4}-\d{2}-\d{2})\b'){$starts+=,@($Matches[1],$Matches[2])}
    if($line -match '\bDAILY_RUN Completed Nonce=([a-f0-9]{32})\b'){$ends+=$Matches[1]}
    if($line -match '\bFlowCompleted DailyTask\b'){$flows++}
    if($line -match '\bDAILY_COINS Initial Already=([0-9]+)'){$initial=[int]$Matches[1];if($initial -gt 5){$valid=$false};$count=0}
    if($line -match '\bDAILY_COINS Accepted NativeSuccessCoins=([0-9]+)\b'){
      $next=[int]$Matches[1]
      if($next -gt 5 -or $next -ne ([int]$count+1)){$valid=$false}
      $count=$next
    }
    if($line -match '\bDAILY_COINS (?:Skipped|Completed)\b.*\bNativeSuccessCoins=([0-9]+)\b'){
      $last=[int]$Matches[1]
      if($last -gt 5 -or ($null -ne $count -and $last -ne $count)){$valid=$false}
      $count=$last
    }
    if($line -match '\bDAILY_COINS\b.*\bAccountedDailyCoins=([0-9]+)\b'){
      $value=[int]$Matches[1]
      if($value -gt 5 -or ($null -ne $accounted -and $value -lt $accounted)){$valid=$false}
      $accounted=$value
    }
    if($null -ne $initial -and $null -ne $count -and $initial+$count -gt 5){$valid=$false}
    if($null -ne $accounted -and $null -ne $initial -and $accounted -lt $initial+[int]$count){$valid=$false}
    if(Get-DailyStopReason -Line $line){$failed=$true}
  }
  $ordinary=$starts.Count -eq 1
  $nonce=if($ordinary){$starts[0][0]}else{$null}
  $date=if($ordinary){$starts[0][1]}else{$null}
  $complete=$ordinary -and $valid -and -not $failed -and $ends.Count -eq 1 -and $ends[0] -ceq $nonce -and $flows -eq 1
  [pscustomobject]@{Ordinary=$ordinary;EvidenceValid=$valid;Complete=$complete;RunNonce=$nonce;Date=$date;NativeSuccessCoins=$count;InitialDailyCoins=$initial;FailureSeen=$failed}
}

function Get-DailyStopReason {
  param([string]$Line)
  if($Line -match '\b(STOP_MUTATION_UNCONFIRMED|COIN_QUERY_FAILURE|GOVERNED_DAILY_BLOCKED|DAILY_BLOCKED)\b|\b(?:DAILY_RUN|DAILY_FLOW|DAILY_COINS) (Stopped|Blocked)\b|\bFlowFailed\b'){return 'NativeOperationUnconfirmed'}
  if($Line -match '(?<!\d)-403(?!\d)'){return 'PlatformBusiness403'}
  if($Line -match '(?<!\d)-352(?!\d)|验证码|风控|风险控制|登录失败|登录失效|HTTP 412'){return 'PlatformRejectedOrLoginUnconfirmed'}
  if($Line -match '\[(?:\d\d:\d\d:\d\d\s+)?(?:ERR|FTL)\]'){return 'NativeError'}
  return $null
}

function Get-DailySafeLine {
  param([string]$Line)
  if($Line -match '(?i)https?://|SESSDATA|bili_jct|DedeUserID|refresh_token|access_token|qrcode_key|Cookie|Token|请求体|响应体|Headers'){return $null}
  if($Line -match '\b(DAILY_RUN|DAILY_FLOW|DAILY_COINS|DAILY_BLOCKED|COIN_QUERY_FAILURE|SHARE_CONTEXT)\b'){return $Line}
  if($Line -match '\bFlow(?:Completed|Failed) DailyTask\b'){return $Line}
  if($Line -match '^(?:\[\d\d:\d\d:\d\d\s+\w+\]\s*)?(?:登录成功，经验\+\d+|视频分享成功，经验\+\d+|投币成功，经验\+\d+)'){return $Line}
  return $null
}

function New-DailyClaim {
  param([string]$Path,[string]$Content)
  $stream=$null
  try {$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$data=[Text.Encoding]::UTF8.GetBytes($Content);$stream.Write($data,0,$data.Length);$stream.Flush($true);return $true}
  catch [IO.IOException] {return $false}
  finally {if($stream){$stream.Dispose()}}
}

function Save-DailyPause {
  param([string]$Root,[string]$Reason)
  $text='Daily attempt paused: '+$Reason+'; confirmed actions are preserved; diagnose and use a new recovery permit before another attempt.'
  $pause=Join-Path $Root 'daily-paused.txt'
  if(-not(Test-Path -LiteralPath $pause)){[IO.File]::WriteAllText($pause,$text,[Text.UTF8Encoding]::new($true))}
  [IO.File]::WriteAllText((Join-Path $Root 'status.txt'),$text,[Text.UTF8Encoding]::new($true))
}

function New-DailyPartialReport {
  param([string]$Date,[string]$LogName,[string]$Nonce,$Evidence,[string]$Reason)
  [ordered]@{Date=$Date;DailyRunLog=$LogName;RunNonce=$Nonce;ObservedAt=[datetimeoffset]::Now.ToString('o');Status='Unconfirmed';SummaryComplete=$false;NativeFlowCompleted=[bool]$Evidence.Complete;NativeSuccessCoins=$Evidence.NativeSuccessCoins;InitialDailyCoins=$Evidence.InitialDailyCoins;DailyTaskExperience=$null;LoginExperience=$null;WatchExperience=$null;ShareExperience=$null;CoinExperience=$null;CurrentExperience=$null;CurrentLevel=$null;RemainingToLv6=$null;CoinBalance=$null;EstimatedDaysToLv6=$null;LoginCoinStatus='Unconfirmed';LoginCoinAmount=$null;LoginCoinRewardTime=$null;CoinDetailsFile=$null;Reason=$Reason;PlatformSummaryRequested=$false}
}

function Test-DailySummary {
  param($Summary,[string]$Date,[string]$LogName,[string]$Nonce,[datetimeoffset]$NativeEnded,[datetimeoffset]$Now)
  try {
    $stamp=[datetimeoffset]::Parse($Summary.ObservedAt)
    if($Summary.Date -cne $Date -or $Summary.DailyRunLog -cne $LogName -or $Summary.RunNonce -cne $Nonce -or $stamp -lt $NativeEnded -or $stamp -gt $Now -or $stamp.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date){return $false}
    if($Summary.Status -cne 'ConfirmedDailyTaskRewards' -or $Summary.SummaryComplete -cne $true -or $Summary.Reason){return $false}
    if($Summary.LoginExperience -notin @(0,5) -or $Summary.WatchExperience -notin @(0,5) -or $Summary.ShareExperience -notin @(0,5) -or $null -eq $Summary.CoinExperience -or $Summary.CoinExperience -lt 0 -or $Summary.CoinExperience -gt 50 -or $Summary.CoinExperience % 10 -ne 0){return $false}
    return ($Summary.DailyTaskExperience -eq ($Summary.LoginExperience+$Summary.WatchExperience+$Summary.ShareExperience+$Summary.CoinExperience))
  } catch {return $false}
}

function Invoke-DailyChild {
  param([Diagnostics.ProcessStartInfo]$StartInfo,[datetimeoffset]$Deadline,[scriptblock]$OnLine,[scriptblock]$StopCheck)
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$StartInfo
  $started=$false; $reason=$null; $exitCode=$null; $stopConfirmed=$true; $stderrPresent=$false
  try {
    if([datetimeoffset]::Now -ge $Deadline){return [pscustomobject]@{Started=$false;Reason='Deadline';ExitCode=$null;StopConfirmed=$true;StderrPresent=$false}}
    $reason=& $StopCheck
    if($reason){return [pscustomobject]@{Started=$false;Reason=$reason;ExitCode=$null;StopConfirmed=$true;StderrPresent=$false}}
    $null=$process.Start(); $started=$true
    $errors=$process.StandardError.ReadToEndAsync()
    $pending=$process.StandardOutput.ReadLineAsync()
    while($true){
      if([datetimeoffset]::Now -ge $Deadline){$reason='Deadline';break}
      $reason=& $StopCheck
      if($reason){break}
      if(-not $pending.IsCompleted){Start-Sleep -Milliseconds 100;continue}
      $line=$pending.Result
      if($null -eq $line){break}
      $reason=& $OnLine $line
      if($reason){break}
      $pending=$process.StandardOutput.ReadLineAsync()
    }
    while(-not $reason -and -not $process.HasExited){
      if([datetimeoffset]::Now -ge $Deadline){$reason='Deadline';break}
      $reason=& $StopCheck
      if(-not $reason){Start-Sleep -Milliseconds 100}
    }
  } catch {$reason='LocalProcessFailure'}
  finally {
    if($started){
      try {
        if(-not $process.HasExited){$process.Kill()}
        if(-not $process.WaitForExit(3000)){$stopConfirmed=$false}
        else {$exitCode=$process.ExitCode; if($errors.IsCompleted){$stderrPresent=[bool]$errors.Result}}
      } catch {$stopConfirmed=$false}
    }
    $process.Dispose()
  }
  [pscustomobject]@{Started=$started;Reason=$reason;ExitCode=$exitCode;StopConfirmed=$stopConfirmed;StderrPresent=$stderrPresent}
}
