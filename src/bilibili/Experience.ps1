param([Parameter(Mandatory=$true)][string]$DailyLog)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot

# Pure guards are extracted by offline tests; tests never dot-source the live body.
function Get-DailySummaryAdmission {
  param([string]$Date,[datetimeoffset]$Now,[datetimeoffset]$Deadline,[datetimeoffset]$NativeEnded,[bool]$IsPaused,[bool]$SummaryAttempted,$NativeEvidence,[string]$ExpectedNonce)
  try {
    $day=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $offset=[timespan]::FromHours(8)
    if($Now.ToOffset($offset).ToString('yyyy-MM-dd') -cne $Date -or $NativeEnded.ToOffset($offset).ToString('yyyy-MM-dd') -cne $Date){return 'ExecutionDateChanged'}
    if($NativeEnded -gt $Now -or $Now -ge $Deadline -or $Deadline -le $NativeEnded -or ($Deadline-$NativeEnded).TotalMinutes -gt 15){return 'OutsideSummaryWindow'}
  } catch {return 'InvalidSummaryContext'}
  if($IsPaused){return 'LocalExecutionPaused'}
  if($SummaryAttempted){return 'SummaryAlreadyAttempted'}
  if($ExpectedNonce -cnotmatch '^[0-9a-f]{32}$' -or $null -eq $NativeEvidence -or $NativeEvidence.RunNonce -cne $ExpectedNonce){return 'RunNonceMismatch'}
  if($NativeEvidence.Date -cne $Date){return 'ExecutionDateChanged'}
  if($NativeEvidence.Complete -cne $true -or $NativeEvidence.Ordinary -cne $true -or $NativeEvidence.EvidenceValid -cne $true){return 'NativeCompletionUnconfirmed'}
  if($null -ne $NativeEvidence.NativeSuccessCoins -and (($NativeEvidence.NativeSuccessCoins -isnot [int] -and $NativeEvidence.NativeSuccessCoins -isnot [long]) -or $NativeEvidence.NativeSuccessCoins -lt 0 -or $NativeEvidence.NativeSuccessCoins -gt 5)){return 'NativeCompletionUnconfirmed'}
  return 'Ready'
}

function New-DailySummaryClaim {
  param([string]$Path)
  try {$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose();return $true}
  catch [IO.IOException] {if(Test-Path -LiteralPath $Path){return $false};throw}
}

function Set-DailyRewardEvidence {
  param($Report,$Reward)
  # Preserve valid individual fields if a different field is absent or invalid.
  $Report.DailyTaskExperience=$null;$Report.Status='Unconfirmed'
  foreach($item in @(@('login','LoginExperience'),@('watch','WatchExperience'),@('share','ShareExperience'))){
    $Report[$item[1]]=$null
    if($null -ne $Reward -and $Reward.($item[0]) -is [bool]){$Report[$item[1]]=5*[int]$Reward.($item[0])}
  }
  $Report.CoinExperience=$null
  if($null -ne $Reward -and ($Reward.coins -is [int] -or $Reward.coins -is [long]) -and $Reward.coins -ge 0 -and $Reward.coins -le 50 -and $Reward.coins % 10 -eq 0){$Report.CoinExperience=[long]$Reward.coins}
  if($null -eq $Report.LoginExperience -or $null -eq $Report.WatchExperience -or $null -eq $Report.ShareExperience){throw 'MissingDailyRewardFields'}
  if($null -eq $Report.CoinExperience){throw 'UnexpectedCoinExperience'}
  $Report.DailyTaskExperience=$Report.LoginExperience+$Report.WatchExperience+$Report.ShareExperience+$Report.CoinExperience
  $Report.Status='ConfirmedDailyTaskRewards'
}

function Invoke-DailySummarySequence {
  param($Report,[scriptblock]$ReadNav,[scriptblock]$ReadReward,[scriptblock]$ReadCoinLog,[scriptblock]$BuildDetails)
  $Report.Stage='AccountExperience'
  $nav=& $ReadNav
  if($nav.isLogin -isnot [bool] -or $nav.isLogin -cne $true){throw 'PlatformVerificationRequired'}
  if(($nav.level_info.current_exp -is [int] -or $nav.level_info.current_exp -is [long]) -and $nav.level_info.current_exp -ge 0){$Report.CurrentExperience=[long]$nav.level_info.current_exp}
  if(($nav.level_info.current_level -is [int] -or $nav.level_info.current_level -is [long]) -and $nav.level_info.current_level -ge 0 -and $nav.level_info.current_level -le 6){$Report.CurrentLevel=[int]$nav.level_info.current_level}
  if($null -ne $nav.money -and $nav.money -is [ValueType] -and $nav.money -isnot [bool] -and $nav.money -ge 0){$Report.CoinBalance=$nav.money}
  if($null -eq $Report.CurrentExperience -or $null -eq $Report.CurrentLevel){throw 'MissingExperienceFields'}
  if($Report.CurrentLevel -ge 6){$Report.RemainingToLv6=0}
  elseif($Report.CurrentLevel -eq 5 -and $nav.level_info.next_exp -match '^\d+$'){$Report.RemainingToLv6=[Math]::Max(0,([long]$nav.level_info.next_exp-$Report.CurrentExperience))}
  $Report.Stage='DailyTaskExperience'
  Set-DailyRewardEvidence -Report $Report -Reward (& $ReadReward)
  $Report.Stage='LoginCoinReward'
  $coinLog=& $ReadCoinLog
  if($null -eq $coinLog -or 'list' -notin $coinLog.PSObject.Properties.Name -or $null -eq $coinLog.list -or $coinLog.list -isnot [Array]){throw 'MissingCoinLogFields'}
  $login=@($coinLog.list | Where-Object {([string]$_.time).StartsWith($Report.Date+' ') -and $_.reason -match '^(每日)?登录奖励$' -and [decimal]$_.delta -eq 1} | Sort-Object time -Descending | Select-Object -First 1)
  if($login.Count -eq 1){$Report.LoginCoinStatus='Confirmed';$Report.LoginCoinAmount=1;$Report.LoginCoinRewardTime=[string]$login[0].time}
  else {$Report.LoginCoinStatus='NotFound';$Report.LoginCoinReason='NoMatchingRewardRecord'}
  $Report.LoginCoinObservedAt=[datetimeoffset]::Now.ToString('o')
  $Report.Stage='CoinDetails'
  $details=& $BuildDetails $coinLog
  if($details.RiskControlEncountered){throw 'PlatformVerificationRequired'}
  if($details.QueryStopped){throw 'MetadataQueryStopped'}
  $Report.SummaryComplete=$true
}

$report=$null;$client=$null;$handler=$null;$summaryClaimed=$false
$pauseFile=Join-Path $root 'daily-paused.txt'
try {
  . (Join-Path $root 'Daily.Common.ps1')
  $deadline=[datetimeoffset]::Parse($env:DAILY_SUMMARY_DEADLINE)
  $nativeEnded=[datetimeoffset]::Parse($env:DAILY_NATIVE_COMPLETED_AT)
  $nonce=$env:DAILY_RUN_NONCE
  $expectedDate=$nativeEnded.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd')
  $logName=[IO.Path]::GetFileName($DailyLog);$fullLog=[IO.Path]::GetFullPath($DailyLog)
  if($fullLog -cne [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'Logs') $logName)) -or $logName -notmatch ('^Daily-'+$expectedDate.Replace('-','')+'-\d{6}\.txt$')){throw 'LogIdentityMismatch'}
  $summaryAttempt=Join-Path $root ('Logs\'+[IO.Path]::GetFileNameWithoutExtension($logName)+'.summary.attempted')
  $logInfo=Get-Item -LiteralPath $fullLog
  if($logInfo.LastWriteTimeUtc -gt $nativeEnded.UtcDateTime){throw 'NativeCompletionUnconfirmed'}
  $evidence=Get-DailyEvidence -Lines @(Get-Content -LiteralPath $fullLog -Encoding UTF8)
  $admission=Get-DailySummaryAdmission -Date $expectedDate -Now ([datetimeoffset]::Now) -Deadline $deadline -NativeEnded $nativeEnded -IsPaused (Test-Path -LiteralPath $pauseFile) -SummaryAttempted (Test-Path -LiteralPath $summaryAttempt) -NativeEvidence $evidence -ExpectedNonce $nonce
  if($admission -ne 'Ready'){throw $admission}
  if(-not(New-DailySummaryClaim -Path $summaryAttempt)){throw 'SummaryAlreadyAttempted'}
  $summaryClaimed=$true
  $report=[ordered]@{Date=$expectedDate;DailyRunLog=$logName;RunNonce=$nonce;NativeCompletedAt=$nativeEnded.ToString('o');ObservedAt=$null;Status='Unconfirmed';SummaryComplete=$false;Stage='LocalValidation';DailyTaskExperience=$null;LoginExperience=$null;WatchExperience=$null;ShareExperience=$null;CoinExperience=$null;NativeSuccessCoins=$evidence.NativeSuccessCoins;CurrentExperience=$null;CurrentLevel=$null;RemainingToLv6=$null;CoinBalance=$null;EstimatedDaysToLv6=$null;Reason=$null;LoginCoinStatus='Unconfirmed';LoginCoinAmount=$null;LoginCoinRewardTime=$null;LoginCoinObservedAt=$null;LoginCoinReason=$null;CoinDetailsFile=$null}
  function Assert-DailySummaryWindow {
    if([datetimeoffset]::Now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $expectedDate){throw 'ExecutionDateChanged'}
    if([datetimeoffset]::Now -ge $deadline){throw 'SummaryDeadline'}
    if(Test-Path -LiteralPath $pauseFile){throw 'LocalExecutionPaused'}
  }
  function Read-ExperienceApi([string]$Path,[switch]$Anonymous) {
    Assert-DailySummaryWindow
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,('https://api.bilibili.com'+$Path));$response=$null;$cancel=$null
    try {
      if(-not $Anonymous){$null=$request.Headers.TryAddWithoutValidation('Cookie',$cookie)}
      $null=$request.Headers.TryAddWithoutValidation('User-Agent',$config.Security.UserAgent)
      $referer=if($Anonymous -or $Path -eq '/x/web-interface/nav'){'https://www.bilibili.com/'}elseif($Path -eq '/x/member/web/coin/log'){'https://account.bilibili.com/account/coin'}else{'https://account.bilibili.com/account/home'}
      $origin=if($Anonymous -or $Path -eq '/x/web-interface/nav'){'https://www.bilibili.com'}else{'https://account.bilibili.com'}
      $null=$request.Headers.TryAddWithoutValidation('Referer',$referer)
      $null=$request.Headers.TryAddWithoutValidation('Origin',$origin)
      $remaining=$deadline-[datetimeoffset]::Now
      if($remaining.TotalMilliseconds -le 0){throw 'SummaryDeadline'}
      $cancel=[Threading.CancellationTokenSource]::new();$cancel.CancelAfter([timespan]::FromMilliseconds([Math]::Min(15000,$remaining.TotalMilliseconds)))
      $response=$client.SendAsync($request,$cancel.Token).GetAwaiter().GetResult()
      if($response.Headers.Contains('x-bili-gaia-vvoucher') -or $response.Headers.Contains('x-bili-gaia-vtoken') -or [int]$response.StatusCode -in @(403,412)){throw 'PlatformVerificationRequired'}
      if(-not $response.IsSuccessStatusCode){throw 'HttpQueryFailed'}
      $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
      if($body.code -in @(-352,-101,-102,-403)){throw 'PlatformVerificationRequired'}
      if(($body.code -isnot [int] -and $body.code -isnot [long]) -or $body.code -ne 0 -or $null -eq $body.data){throw 'ApiQueryFailed'}
      Assert-DailySummaryWindow
      return $body.data
    } finally {if($cancel){$cancel.Dispose()};if($response){$response.Dispose()};$request.Dispose()}
  }
  Assert-DailySummaryWindow
  $config=Get-Content -LiteralPath (Join-Path $root 'app\appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $credentials=Get-Content -LiteralPath (Join-Path $root 'app\cookies.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $cookies=@($credentials.BiliBiliCookies | Where-Object {$_ -is [string] -and $_.Trim()})
  if($cookies.Count -ne 1){throw 'SingleLocalAccountRequired'}
  $cookie=$cookies[0]
  Add-Type -AssemblyName System.Net.Http
  $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseProxy=$false
  $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[timespan]::FromSeconds(15)
  . (Join-Path $root 'CoinDetails.ps1')
  $detailsPath=Join-Path $root ('Logs\CoinDetails-'+[IO.Path]::GetFileNameWithoutExtension($logName)+'.json')
  $buildDetails={param($coinLog)
    $details=New-CoinDonationReport -DailyLog $fullLog -CoinLogData $coinLog -ConfirmedNativeSuccessCoins $evidence.NativeSuccessCoins -ResolveVideo {param($bvid) Read-ExperienceApi -Path ('/x/web-interface/view?bvid='+$bvid) -Anonymous}
    $details | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailsPath -Encoding UTF8
    $report.CoinDetailsFile=[IO.Path]::GetFileName($detailsPath)
    return $details
  }
  Invoke-DailySummarySequence -Report $report -ReadNav {Read-ExperienceApi '/x/web-interface/nav'} -ReadReward {Read-ExperienceApi '/x/member/web/exp/reward'} -ReadCoinLog {Read-ExperienceApi '/x/member/web/coin/log'} -BuildDetails $buildDetails
  if($null -ne $report.RemainingToLv6 -and $null -ne $report.CoinBalance){
    . (Join-Path $root 'Forecast.ps1')
    $forecast=Get-Level6Forecast -Remaining $report.RemainingToLv6 -CoinBalance $report.CoinBalance -CoinTarget $config.DailyTaskConfig.NumberOfCoins -ProtectedCoins $config.DailyTaskConfig.NumberOfProtectedCoins -WatchEnabled $config.DailyTaskConfig.IsWatchVideo -ShareEnabled $config.DailyTaskConfig.IsShareVideo
    $report.EstimatedDaysToLv6=$forecast.EstimatedDaysToLv6;$report.EstimatedDaysWithEnoughCoins=$forecast.EstimatedDaysWithEnoughCoins;$report.EstimatedFullDailyExperience=$forecast.EstimatedFullDailyExperience
  }
} catch {
  $safe=@('InvalidSummaryContext','ExecutionDateChanged','OutsideSummaryWindow','LocalExecutionPaused','RunNonceMismatch','SummaryAlreadyAttempted','NativeCompletionUnconfirmed','LogIdentityMismatch','SummaryDeadline','PlatformVerificationRequired','HttpQueryFailed','ApiQueryFailed','SingleLocalAccountRequired','MissingExperienceFields','MissingDailyRewardFields','UnexpectedCoinExperience','MissingCoinLogFields','MetadataQueryStopped')
  $reason=if($_.Exception.Message -in $safe){$_.Exception.Message}else{'QueryUnavailable'}
  if($report){$report.Reason=$report.Stage+':'+$reason;$report.SummaryComplete=$false}
  if($summaryClaimed -and -not(Test-Path -LiteralPath $pauseFile)){[IO.File]::WriteAllText($pauseFile,('Daily summary stopped: '+$reason+'; no retry.'),[Text.Encoding]::UTF8)}
  if(-not $report){throw $reason}
} finally {
  if($client){$client.Dispose()}elseif($handler){$handler.Dispose()}
  $cookie=$null;$credentials=$null;$cookies=$null
  if($report){
    if([datetimeoffset]::Now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $expectedDate){
      $report.Status='Unconfirmed';$report.SummaryComplete=$false;$report.Reason='ResultCommit:ExecutionDateChanged'
      foreach($field in @('DailyTaskExperience','LoginExperience','WatchExperience','ShareExperience','CoinExperience','CurrentExperience','CurrentLevel','RemainingToLv6','CoinBalance','EstimatedDaysToLv6','LoginCoinAmount','LoginCoinRewardTime','LoginCoinObservedAt','CoinDetailsFile')){$report[$field]=$null}
      $report.LoginCoinStatus='Unconfirmed'
    }
    $report.ObservedAt=[datetimeoffset]::Now.ToString('o')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root ('Logs\Experience-'+$expectedDate.Replace('-','')+'.json')) -Encoding UTF8
  }
}
if(-not $report.SummaryComplete){exit 4}
