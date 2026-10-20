param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$DailyLog)
$LoginCoinOnly=$false
$CoinDetailsOnly=$false
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$reportPath=Join-Path $root ('Logs\Experience-'+(Get-Date -Format 'yyyyMMdd')+'.json')
$report=[ordered]@{Date=(Get-Date -Format 'yyyy-MM-dd');DailyRunLog=[IO.Path]::GetFileName($DailyLog);ObservedAt=$null;Status='Unconfirmed';DailyTaskExperience=$null;LoginExperience=$null;WatchExperience=$null;ShareExperience=$null;CoinExperience=$null;CurrentExperience=$null;CurrentLevel=$null;RemainingToLv6=$null;Reason=$null}
$client=$null
$handler=$null
$stage='LocalValidation'
function Read-ExperienceApi([string]$path,[string]$referer,[string]$origin,[switch]$Anonymous) {
  $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,('https://api.bilibili.com'+$path))
  $response=$null
  try {
    if(-not $Anonymous){$null=$request.Headers.TryAddWithoutValidation('Cookie',$cookie)}
    $null=$request.Headers.TryAddWithoutValidation('User-Agent',$config.Security.UserAgent)
    $null=$request.Headers.TryAddWithoutValidation('Referer',$referer)
    $null=$request.Headers.TryAddWithoutValidation('Origin',$origin)
    $response=$client.SendAsync($request).GetAwaiter().GetResult()
    if([int]$response.StatusCode -in @(403,412)){throw 'PlatformVerificationRequired'}
    if(-not $response.IsSuccessStatusCode){throw 'HttpQueryFailed'}
    $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    if($body.code -in @(-352,-101,-102,-403) -or $response.Headers.Contains('x-bili-gaia-vvoucher')){throw 'PlatformVerificationRequired'}
    if($null -eq $body.code -or $body.code -ne 0 -or $null -eq $body.data){throw 'ApiQueryFailed'}
    return $body.data
  } finally {if($response){$response.Dispose()};$request.Dispose()}
}
try {
  if(Test-Path -LiteralPath (Join-Path $root 'daily-paused.txt')){throw 'LocalExecutionPaused'}
  $dailyLines=Get-Content -LiteralPath $DailyLog -Encoding UTF8
  if(((-not $CoinDetailsOnly) -and (Get-Item -LiteralPath $DailyLog).LastWriteTime.Date -ne (Get-Date).Date) -or -not($dailyLines -match 'FlowCompleted DailyTask')){throw 'NoCompletedRunToday'}
  if($LoginCoinOnly) {
    $existing=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($existing.Date -ne $report.Date -or $existing.DailyRunLog -ne $report.DailyRunLog){throw 'ExistingSummaryRequired'}
    foreach($property in $existing.PSObject.Properties){$report[$property.Name]=$property.Value}
  }
  $report.LoginCoinStatus='Unconfirmed'
  $report.LoginCoinAmount=$null
  $report.LoginCoinRewardTime=$null
  $report.LoginCoinObservedAt=$null
  $report.LoginCoinReason=$null
  $config=Get-Content -LiteralPath (Join-Path $root 'app\appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $credentials=Get-Content -LiteralPath (Join-Path $root 'app\cookies.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $cookies=@($credentials.BiliBiliCookies | Where-Object {$_ -is [string] -and $_.Trim()})
  if($cookies.Count -ne 1){throw 'SingleLocalAccountRequired'}
  $cookie=$cookies[0]
  Add-Type -AssemblyName System.Net.Http
  $handler=[Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect=$false
  $handler.UseCookies=$false
  $handler.UseProxy=$false
  $client=[Net.Http.HttpClient]::new($handler)
  $client.Timeout=[TimeSpan]::FromSeconds(15)
  . (Join-Path $PSScriptRoot 'CoinDetails.ps1')
  $detailsPath=Join-Path $root ('Logs\CoinDetails-'+[IO.Path]::GetFileNameWithoutExtension($DailyLog)+'.json')
  $resolveVideo={param($bvid) Read-ExperienceApi ('/x/web-interface/view?bvid='+$bvid) 'https://www.bilibili.com/' 'https://www.bilibili.com' -Anonymous}
  if($CoinDetailsOnly) {
    $stage='CoinDetails'
    $coinLog=Read-ExperienceApi '/x/member/web/coin/log' 'https://account.bilibili.com/account/coin' 'https://account.bilibili.com'
    if('list' -notin $coinLog.PSObject.Properties.Name){throw 'MissingCoinLogFields'}
    $details=New-CoinDonationReport -DailyLog $DailyLog -CoinLogData $coinLog -ResolveVideo $resolveVideo
    $details | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailsPath -Encoding UTF8
    if($details.RiskControlEncountered){throw 'PlatformVerificationRequired'}
    return
  }
  if(-not $LoginCoinOnly) {
  $stage='AccountExperience'
  $nav=Read-ExperienceApi '/x/web-interface/nav' 'https://www.bilibili.com/' 'https://www.bilibili.com'
  if($nav.isLogin -ne $true){throw 'PlatformVerificationRequired'}
  if($null -eq $nav.level_info.current_exp -or $null -eq $nav.level_info.current_level){throw 'MissingExperienceFields'}
  $report.CurrentExperience=[long]$nav.level_info.current_exp
  $report.CurrentLevel=[int]$nav.level_info.current_level
  $report.CoinBalance=$nav.money
  if($report.CurrentLevel -ge 6){$report.RemainingToLv6=0}
  elseif($report.CurrentLevel -ge 0 -and $report.CurrentLevel -lt 6){$report.RemainingToLv6=[Math]::Max(0,(28800-$report.CurrentExperience))}
  $stage='DailyTaskExperience'
  $reward=Read-ExperienceApi '/x/member/web/exp/reward' 'https://account.bilibili.com/account/home' 'https://account.bilibili.com'
  if($reward.login -isnot [bool] -or $reward.watch -isnot [bool] -or $reward.share -isnot [bool] -or $null -eq $reward.coins){throw 'MissingDailyRewardFields'}
  $coinExp=[long]$reward.coins
  if($coinExp -lt 0 -or $coinExp -gt 50 -or $coinExp % 10 -ne 0){throw 'UnexpectedCoinExperience'}
  $report.LoginExperience=5*[int]$reward.login
  $report.WatchExperience=5*[int]$reward.watch
  $report.ShareExperience=5*[int]$reward.share
  $report.CoinExperience=$coinExp
  $report.DailyTaskExperience=$report.LoginExperience+$report.WatchExperience+$report.ShareExperience+$coinExp
  $report.Status='ConfirmedDailyTaskRewards'
  if($null -ne $report.RemainingToLv6 -and $null -ne $report.CoinBalance) {
    . (Join-Path $PSScriptRoot 'Forecast.ps1')
    $forecast=Get-Level6Forecast -Remaining $report.RemainingToLv6 -CoinBalance $report.CoinBalance -CoinTarget $config.DailyTaskConfig.NumberOfCoins -ProtectedCoins $config.DailyTaskConfig.NumberOfProtectedCoins -WatchEnabled $config.DailyTaskConfig.IsWatchVideo -ShareEnabled $config.DailyTaskConfig.IsShareVideo
    $report.EstimatedDaysToLv6=$forecast.EstimatedDaysToLv6
    $report.EstimatedDaysWithEnoughCoins=$forecast.EstimatedDaysWithEnoughCoins
    $report.EstimatedFullDailyExperience=$forecast.EstimatedFullDailyExperience
  }
  }
  $stage='LoginCoinReward'
  $coinLog=Read-ExperienceApi '/x/member/web/coin/log' 'https://account.bilibili.com/account/coin' 'https://account.bilibili.com'
  if('list' -notin $coinLog.PSObject.Properties.Name){throw 'MissingCoinLogFields'}
  $loginReward=@($coinLog.list | Where-Object {([string]$_.time).StartsWith($report.Date+' ') -and $_.reason -match '^(每日)?登录奖励$' -and [decimal]$_.delta -eq 1} | Sort-Object time -Descending | Select-Object -First 1)
  if($loginReward.Count -eq 1) {
    $report.LoginCoinStatus='Confirmed'
    $report.LoginCoinAmount=1
    $report.LoginCoinRewardTime=[string]$loginReward[0].time
  } else {
    $report.LoginCoinStatus='NotFound'
    $report.LoginCoinReason='NoMatchingRewardRecord'
  }
  $report.LoginCoinObservedAt=(Get-Date).ToString('o')
  $stage='CoinDetails'
  $details=New-CoinDonationReport -DailyLog $DailyLog -CoinLogData $coinLog -ResolveVideo $resolveVideo
  $details | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailsPath -Encoding UTF8
  $report.CoinDetailsFile=[IO.Path]::GetFileName($detailsPath)
  if($details.RiskControlEncountered){throw 'PlatformVerificationRequired'}
} catch {
  $safeReasons=@('PlatformVerificationRequired','LocalExecutionPaused','NoCompletedRunToday','SingleLocalAccountRequired','MissingExperienceFields','MissingDailyRewardFields','UnexpectedCoinExperience','HttpQueryFailed','ApiQueryFailed','ExistingSummaryRequired','MissingCoinLogFields')
  $reason=if($_.Exception.Message -in $safeReasons){$_.Exception.Message}else{'QueryUnavailable'}
  $safeFailure=$stage+':'+$reason
  if($reason -eq 'QueryUnavailable'){$safeFailure+=':'+($_.Exception.GetType().Name)+':line'+$_.InvocationInfo.ScriptLineNumber}
  if($stage -eq 'LoginCoinReward'){$report.LoginCoinReason=$safeFailure}else{$report.Reason=$safeFailure}
  if($reason -eq 'PlatformVerificationRequired'){'经验只读查询遇到登录失效或平台验证要求，已暂停；请处理后再恢复。' | Set-Content -LiteralPath (Join-Path $root 'daily-paused.txt') -Encoding UTF8}
  if($CoinDetailsOnly) {
    if($detailsPath -and -not (Test-Path -LiteralPath $detailsPath)) {
      . (Join-Path $PSScriptRoot 'CoinDetails.ps1')
      New-CoinDonationReport -DailyLog $DailyLog | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailsPath -Encoding UTF8
    }
    return
  }
} finally {
  if($client){$client.Dispose()}elseif($handler){$handler.Dispose()}
  $cookie=$null;$credentials=$null;$cookies=$null
}
if(-not $LoginCoinOnly){$report.ObservedAt=(Get-Date).ToString('o')}
if($stage -eq 'LoginCoinReward'){$report.LoginCoinObservedAt=(Get-Date).ToString('o')}
$report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding UTF8
