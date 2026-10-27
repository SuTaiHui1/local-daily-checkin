param([switch]$Scheduled,[ValidatePattern('^(?:[a-f0-9]{32})?$')][string]$RecoveryId='')
if($RecoveryId -and -not $Scheduled){throw 'RecoveryOnlyForScheduledDaily'}
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=$PSScriptRoot
. (Join-Path $root 'Daily.Common.ps1')
. (Join-Path $root 'DailyDecision.ps1')
. (Join-Path $root 'Recovery.Common.ps1')
. (Join-Path $root 'BrowserShare.Common.ps1')
$pause=Join-Path $root 'daily-paused.txt'
$logs=Join-Path $root 'Logs'
$app=Join-Path $root 'app'
$null=New-Item -ItemType Directory -Path $logs -Force
$mutex=$null;$locked=$false;$claimed=$false;$logFile=$null;$nativeEnded=$null;$summaryConfirmed=$false;$permit=$null;$readOnly=$false
$now=[datetimeoffset]::Now
$date=$now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd')
$nonce=[guid]::NewGuid().ToString('N')
$result=[ordered]@{Date=$date;Status='Unconfirmed';Reason=$null;InvocationObservedAt=$null;DailyRunLog=$null;RunNonce=$nonce;NativeLaunches=0;SummaryLaunches=0;NativeSuccessCoins=$null;PlatformTaskRewardsConfirmed=$false;RewardGoalConfirmed=$false;ProductionPaused=$null;NoRetryWithinAttempt=$true;RecoveryAllowed=$true}
try {
  if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){$result.Reason='OrdinaryUserRequired';return}
  if(Test-Path -LiteralPath $pause){$result.Status='Paused';$result.Reason='LocalPauseExists';return}
  $mutex=New-Object Threading.Mutex($false,'Local\LocalDailyCheckin-Bilibili')
  $locked=$mutex.WaitOne(0)
  if(-not $locked){$result.Status='Skipped';$result.Reason='SkipRunning';return}
  # Match the immutable native governed scope without loading private configuration here.
  $decisionConfig=[pscustomobject]@{NumberOfCoins=5;IsWatchVideo=$true;IsShareVideo=$true;SaveCoinsWhenLv6=$true}
  while($true){
    if(Test-Path -LiteralPath $pause){$result.Status='Paused';$result.Reason='LocalPauseExists';return}
    $now=[datetimeoffset]::Now;$date=$now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd');$result.Date=$date
    $summaryPath=Join-Path $logs ('Experience-'+$date.Replace('-','')+'.json')
    if($RecoveryId){
      if(-not(Test-DailyRecoveryPermit -Root $root -Date $date -RecoveryId $RecoveryId -Now $now)){throw 'InvalidRecoveryPermit'}
      $permitPath=Get-DailyRecoveryPermitPath -Root $root -Date $date -RecoveryId $RecoveryId
      $permit=Get-Content -LiteralPath $permitPath -Raw -Encoding UTF8|ConvertFrom-Json
    }
    $suffix=if($RecoveryId){'-recovery-'+$RecoveryId}else{''}
    $claim=Join-Path $logs ('Daily-'+$date.Replace('-','')+$suffix+'.attempted')
    $attempted=Test-Path -LiteralPath $claim
    if(-not $RecoveryId -and @(Get-ChildItem -LiteralPath $logs -Filter ('Daily-'+$date.Replace('-','')+'-recovery-*.attempted') -File).Count -gt 0){$attempted=$true}
    $previous=$null
    if(Test-Path -LiteralPath $summaryPath){try{$previous=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json}catch{}}
    $decision=Get-DailyRunDecision -Now $now.ToOffset([timespan]::FromHours(8)).DateTime -Scheduled:$Scheduled -Summary $previous -DailyConfig $decisionConfig -Attempted $attempted
    if($decision.Action -ne 'WaitUntil20'){break}
    Start-Sleep -Seconds ([Math]::Min(60,$decision.WaitSeconds))
  }
  if($decision.Action -ne 'RunToday'){
    $result.Status='Skipped';$result.Reason=$decision.Action
    if($decision.Action -eq 'SkipCompleted'){$result.DailyRunLog=$previous.DailyRunLog;$result.EvidenceObservedAt=$previous.ObservedAt;$result.PlatformTaskRewardsConfirmed=$true;$result.RewardGoalConfirmed=$true}
    return
  }
  $manifestPath=Join-Path $root 'daily-runtime-manifest.json'
  $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $required=@('Launch.ps1','Run.ps1','DailyRun.ps1','Daily.Common.ps1','DailyDecision.ps1','Recovery.Common.ps1','BrowserShare.ps1','BrowserShare.Common.ps1','Experience.ps1','CoinDetails.ps1','Forecast.ps1','Policy.ps1','Report.ps1','ShowQr.ps1','Bind-BrowserProfile.ps1','app\Ray.BiliBiliTool.Console.exe')
  if(@($manifest.Files).Count -ne $required.Count -or @(Compare-Object $required @($manifest.Files.File) -CaseSensitive).Count -ne 0){throw 'RuntimeManifestMismatch'}
  foreach($entry in $manifest.Files){if($entry.File -match '(^[\\/]|:|\.\.)' -or (Get-FileHash -LiteralPath (Join-Path $root $entry.File) -Algorithm SHA256).Hash -cne $entry.SHA256){throw 'RuntimeManifestMismatch'}}
  if($manifest.CoinJournalProtocol -cne 'CoinIntentV1'){throw 'RuntimeManifestMismatch'}
  $budget=Get-DailyRecoveryBudget -Root $root -Date $date -Permit $permit
  $readOnly=$budget.ReadOnlyRequired -or ($permit -and $permit.ReadOnly -eq $true)
  if($readOnly -and -not $RecoveryId){throw 'RecoveryPermitRequiredForUnknownCoins'}
  if(-not $readOnly -and -not(Test-BrowserShareReady -Root $root -Date $date -Now ([datetimeoffset]::Now) -RecoveryId $RecoveryId)){$result.Status='AwaitingBrowserShare';$result.Reason='BrowserShareEvidenceRequired';return}
  $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
  $manifestCopy=Join-Path $logs ('Runtime-'+$manifestHash+'.json')
  if(-not(Test-Path -LiteralPath $manifestCopy)){Copy-Item -LiteralPath $manifestPath -Destination $manifestCopy}
  if((Get-FileHash -LiteralPath $manifestCopy -Algorithm SHA256).Hash -cne $manifestHash){throw 'RuntimeManifestMismatch'}
  $nativeHash=($manifest.Files|Where-Object {$_.File -ceq 'app\Ray.BiliBiliTool.Console.exe'}).SHA256
  $result.RecoveryId=$RecoveryId;$result.ReadOnlyRecovery=[bool]$readOnly;$result.CarriedCoinFloor=$budget.ConfirmedDailyFloor;$result.CoinBudgetEvidence=$budget
  $permitHash=if($RecoveryId){(Get-FileHash -LiteralPath $permitPath -Algorithm SHA256).Hash}else{$null}
  $claimText=([ordered]@{Date=$date;RunNonce=$nonce;AttemptedAt=$now.ToString('o');Version=$manifest.Version;RecoveryId=$RecoveryId;RecoveryPermitSHA256=$permitHash;CoinJournalRequired=$true;CoinJournalProtocol='CoinIntentV1';RuntimeManifestSHA256=$manifestHash;NativeSHA256=$nativeHash;CarriedCoinFloor=$budget.ConfirmedDailyFloor;ReadOnlyRecovery=[bool]$readOnly;NoRetryWithinAttempt=$true}|ConvertTo-Json -Compress)
  if(-not(New-DailyClaim -Path $claim -Content $claimText)){$result.Status='Skipped';$result.Reason='SkipAttempted';return}
  $claimed=$true
  if($RecoveryId){
    foreach($prior in @($summaryPath,(Join-Path $logs 'last-invocation.json'))){
      if(Test-Path -LiteralPath $prior){
        $saved=Join-Path $logs (([IO.Path]::GetFileNameWithoutExtension($prior))+'-before-recovery-'+$RecoveryId+'.json')
        [IO.File]::Copy($prior,$saved,$false)
        if((Get-FileHash -LiteralPath $prior).Hash -cne (Get-FileHash -LiteralPath $saved).Hash){throw 'RecoveryArchiveMismatch'}
      }
    }
  }
  $started=[datetimeoffset]::Now
  $deadline=$started.AddMinutes(15)
  if($started.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $date){throw 'ExecutionDateChanged'}
  $logFile=Join-Path $logs ('Daily-'+$started.ToOffset([timespan]::FromHours(8)).ToString('yyyyMMdd-HHmmss')+'.txt')
  $empty=[IO.File]::Open($logFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$empty.Dispose()
  $result.DailyRunLog=[IO.Path]::GetFileName($logFile)
  $stopCheck={
    if(Test-Path -LiteralPath $pause){return 'LocalPauseExists'}
    if([datetimeoffset]::Now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $date){return 'ExecutionDateChanged'}
    return $null
  }
  $onLine={param($line)
    $safe=Get-DailySafeLine -Line $line
    if($safe){Add-Content -LiteralPath $logFile -Value $safe -Encoding UTF8}
    $stop=Get-DailyStopReason -Line $line
    if($stop){Save-DailyPause -Root $root -Reason $stop;Add-Content -LiteralPath $logFile -Value ('DAILY_RUN Stopped Reason='+$stop) -Encoding UTF8}
    return $stop
  }
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=Join-Path $app 'Ray.BiliBiliTool.Console.exe';$start.Arguments='--runTasks=Daily';$start.WorkingDirectory=$app
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.StandardOutputEncoding=[Text.Encoding]::UTF8;$start.StandardErrorEncoding=[Text.Encoding]::UTF8
  . (Join-Path $root 'Policy.ps1')
  $config=Get-Content -LiteralPath (Join-Path $app 'appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-BilibiliConfig -Config $config
  if((Get-Content -LiteralPath (Join-Path $app 'appsettings.Production.json') -Raw).Trim() -ne '{}'){throw 'UnexpectedProductionOverride'}
  foreach($key in @($start.EnvironmentVariables.Keys)){if($key -match '^(?i)(Ray_|RunTasks$|DailyTaskConfig|MangaTaskConfig|MangaPrivilegeTaskConfig|Silver2CoinTaskConfig|ChargeTaskConfig|VipPrivilegeConfig|VipBigPointConfig|LiveLotteryTaskConfig|LiveFansMedalTaskConfig|UnfollowBatchedTaskConfig|Security|Serilog|BiliBiliCookies|QingLongConfig|Repair|DOTNET_ENVIRONMENT)'){$start.EnvironmentVariables.Remove($key)}}
  $start.EnvironmentVariables['DOTNET_ENVIRONMENT']='Production';$start.EnvironmentVariables['DOTNET_CONTENTROOT']=$app
  $start.EnvironmentVariables['BILI_DAILY_RUN_NONCE']=$nonce
  $start.EnvironmentVariables['BILI_DAILY_LEDGER_DIRECTORY']=$logs
  $start.EnvironmentVariables['BILI_DAILY_RECOVERY_FLOOR']=[string]$budget.ConfirmedDailyFloor
  $start.EnvironmentVariables['BILI_DAILY_RECOVERY_READONLY']=([bool]$readOnly).ToString().ToLowerInvariant()
  $start.EnvironmentVariables['Ray_Repair__BrowserShareRequired']='true'
  $native=Invoke-DailyChild -StartInfo $start -Deadline $deadline -OnLine $onLine -StopCheck $stopCheck
  $nativeEnded=[datetimeoffset]::Now;$result.NativeLaunches=[int]$native.Started
  if($native.Reason -or -not $native.StopConfirmed -or $native.ExitCode -ne 0){$result.Reason=if($native.Reason){$native.Reason}else{'NativeExecutionUnconfirmed'};Save-DailyPause -Root $root -Reason $result.Reason;return}
  $evidence=Get-DailyEvidence -Lines @(Get-Content -LiteralPath $logFile -Encoding UTF8)
  if(-not $evidence.Complete -or $evidence.RunNonce -cne $nonce -or $evidence.Date -cne $date){$result.Reason='NativeCompletionUnconfirmed';Save-DailyPause -Root $root -Reason $result.Reason;return}
  $summaryStart=New-Object Diagnostics.ProcessStartInfo
  $summaryStart.FileName=(Get-Command pwsh.exe -ErrorAction Stop).Source
  $summaryStart.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "'+(Join-Path $root 'Experience.ps1')+'" -DailyLog "'+$logFile+'"'
  $summaryStart.WorkingDirectory=$root;$summaryStart.UseShellExecute=$false;$summaryStart.CreateNoWindow=$true
  $summaryStart.RedirectStandardOutput=$true;$summaryStart.RedirectStandardError=$true
  $summaryStart.EnvironmentVariables['DAILY_NATIVE_COMPLETED_AT']=$nativeEnded.ToString('o')
  $summaryStart.EnvironmentVariables['DAILY_SUMMARY_DEADLINE']=$deadline.ToString('o')
  $summaryStart.EnvironmentVariables['DAILY_RUN_NONCE']=$nonce
  $aggregate=Invoke-DailyChild -StartInfo $summaryStart -Deadline $deadline -OnLine {param($line) return $null} -StopCheck $stopCheck
  $result.SummaryLaunches=[int]$aggregate.Started
  if($aggregate.Reason -or -not $aggregate.StopConfirmed -or $aggregate.ExitCode -ne 0){$result.Reason='AutomaticSummaryUnconfirmed';Save-DailyPause -Root $root -Reason $result.Reason;return}
  $summary=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if(-not(Test-DailySummary -Summary $summary -Date $date -LogName $result.DailyRunLog -Nonce $nonce -NativeEnded $nativeEnded -Now ([datetimeoffset]::Now))){$result.Reason='AutomaticSummaryUnconfirmed';Save-DailyPause -Root $root -Reason $result.Reason;return}
  $goalDecision=Get-DailyRunDecision -Now ([datetimeoffset]::Now.ToOffset([timespan]::FromHours(8)).DateTime) -Scheduled:$Scheduled -Summary $summary -DailyConfig $decisionConfig -Attempted $false
  $result.RewardGoalConfirmed=$goalDecision.Action -eq 'SkipCompleted'
  $result.Status=if($result.RewardGoalConfirmed){'ConfirmedDailyTaskRewards'}else{'RewardConfirmationPending'}
  $result.Reason=if($result.RewardGoalConfirmed){'Completed'}else{'ObservedRewardsBelowDailyGoal'}
  $result.PlatformTaskRewardsConfirmed=$true
  $summaryConfirmed=$true
  if($readOnly){$result.Reason=if($result.RewardGoalConfirmed){'ReadOnlyGoalConfirmed'}else{'ReadOnlyReconciliationPending'}}
  $result.DailyTaskExperience=$summary.DailyTaskExperience;$result.PlatformCoinExperience=$summary.CoinExperience
} catch {
  $result.Reason=if($_.Exception.Message -in @('RuntimeManifestMismatch','ExecutionDateChanged','InvalidRecoveryPermit','RecoveryPermitRequiredForUnknownCoins','RecoveryArchiveMismatch')){$_.Exception.Message}else{'LocalValidationOrExecutionUnconfirmed'}
  Save-DailyPause -Root $root -Reason $result.Reason
} finally {
  if($claimed){
    $evidence=Get-DailyEvidence -Lines $(if($logFile -and (Test-Path -LiteralPath $logFile)){@(Get-Content -LiteralPath $logFile -Encoding UTF8)}else{@()})
    $result.NativeSuccessCoins=$evidence.NativeSuccessCoins
    if(-not $summaryConfirmed){
      Save-DailyPause -Root $root -Reason $result.Reason
      # Preserve any partial same-invocation read-only evidence already committed by Experience.
      $sameReport=$false
      if(Test-Path -LiteralPath $summaryPath){try{$existing=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8|ConvertFrom-Json;$sameReport=$existing.RunNonce -ceq $nonce -and $existing.DailyRunLog -ceq $result.DailyRunLog}catch{}}
      if(-not $sameReport){
        if(Test-Path -LiteralPath $summaryPath){Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $logs ('Experience-previous-'+$nonce+'.json'))}
        New-DailyPartialReport -Date $date -LogName $result.DailyRunLog -Nonce $nonce -Evidence $evidence -Reason $result.Reason | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
      }
    }
  }
  if($result.NativeLaunches -eq 0){$result.NativeSuccessCoins=0}
  $result.InvocationObservedAt=[datetimeoffset]::Now.ToString('o');$result.ProductionPaused=Test-Path -LiteralPath $pause
  $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $logs 'last-invocation.json') -Encoding UTF8
  if($claimed){$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $logs ('Invocation-'+$date.Replace('-','')+'-'+$nonce+'.json')) -Encoding UTF8}
  if($result.Status -ne 'Unconfirmed'){('Daily: '+$result.Status+' / '+$result.Reason) | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8}
  try { $reportAction=if($result.Status -eq 'Skipped'){$result.Reason}elseif($result.NativeLaunches -gt 0){'RanToday'}else{$result.Status}; & (Join-Path $root 'Report.ps1') -StateRoot $root -Action $reportAction -DailyLog $logFile | Out-Null } catch { Write-Warning 'Local report could not be generated; platform work was not repeated.' }
  if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
  if($result.Status -eq 'Unconfirmed'){exit 3}
}
if($result.Status -eq 'Unconfirmed'){exit 3}
exit 0
