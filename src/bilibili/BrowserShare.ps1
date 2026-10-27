param(
  [string]$StateRoot=$PSScriptRoot,
  [Parameter(Mandatory=$true)][ValidateSet('Prepare','ClaimSubmit','ConfirmAlready','ConfirmSubmitted','Fail')][string]$Action,
  [string]$Nonce,
  [ValidatePattern('^(?:[a-f0-9]{32})?$')][string]$RecoveryId='',
  [string]$RewardEvidenceFile='',
  [ValidateSet('BrowserUnavailable','NotLoggedIn','AccountMismatch','PlatformRejected','RewardUnconfirmed','UiChanged','LocalEvidenceUnconfirmed')][string]$Reason='LocalEvidenceUnconfirmed'
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
if($root -cne $PSScriptRoot){
  $installed=Join-Path $root 'BrowserShare.ps1'
  if(-not(Test-Path -LiteralPath $installed)){throw 'StateRootNotInstalled'}
  $forward=@{};foreach($key in $PSBoundParameters.Keys){if($key -ne 'StateRoot'){$forward[$key]=$PSBoundParameters[$key]}}
  & $installed @forward
  return
}
. (Join-Path $root 'Daily.Common.ps1')
. (Join-Path $root 'DailyDecision.ps1')
. (Join-Path $root 'BrowserShare.Common.ps1')
. (Join-Path $root 'Recovery.Common.ps1')
$now=[datetimeoffset]::Now
$date=$now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd')
$logs=Join-Path $root 'Logs'
$null=New-Item -ItemType Directory -Path $logs -Force
$paths=Get-BrowserSharePaths -Root $root -Date $date -RecoveryId $RecoveryId
$result=[ordered]@{Date=$date;RecoveryId=$RecoveryId;Action=$Action;Status='Unconfirmed';Reason=$null;Nonce=$null;ObservedAt=$now.ToString('o');HelperPlatformRequests=0}
$mutex=$null;$locked=$false
try {
  if($RewardEvidenceFile -and $Action -cnotin @('ConfirmSubmitted','ConfirmAlready')){throw 'BrowserEvidenceInvalid'}
  if(Test-Path -LiteralPath (Join-Path $root 'daily-paused.txt')){$result.Status='Paused';$result.Reason='LocalPauseExists';return}
  $mutex=New-Object Threading.Mutex($false,'Local\LocalDailyCheckin-Bilibili')
  $locked=$mutex.WaitOne(0)
  if(-not $locked){$result.Status='SkipRunning';return}
  if(Test-Path -LiteralPath (Join-Path $root 'daily-paused.txt')){$result.Status='Paused';$result.Reason='LocalPauseExists';return}
  if($now.ToOffset([timespan]::FromHours(8)).Hour -lt 20){$result.Status='SkipBeforeTodaySchedule';return}
  $nativeClaim=Join-Path $logs ('Daily-'+$date.Replace('-','')+'.attempted')
  if($RecoveryId){
    if(-not(Test-DailyRecoveryPermit -Root $root -Date $date -RecoveryId $RecoveryId -Now $now)){throw 'RecoveryPermitInvalid'}
    $permit=Get-Content -LiteralPath (Join-Path $logs ('Recovery-'+$date.Replace('-','')+'-'+$RecoveryId+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
    $nativeClaim=Join-Path $logs ('Daily-'+$date.Replace('-','')+'-recovery-'+$RecoveryId+'.attempted')
  }
  $previous=$null
  $summaryPath=Join-Path $logs ('Experience-'+$date.Replace('-','')+'.json')
  if(Test-Path -LiteralPath $summaryPath){try{$previous=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
  $config=[pscustomobject]@{NumberOfCoins=5;IsWatchVideo=$true;IsShareVideo=$true;SaveCoinsWhenLv6=$true}
  $attempted=Test-Path -LiteralPath $nativeClaim
  if(-not $RecoveryId -and @(Get-ChildItem -LiteralPath $logs -Filter ('Daily-'+$date.Replace('-','')+'-recovery-*.attempted') -File).Count -gt 0){$attempted=$true}
  $decision=Get-DailyRunDecision -Now $now.ToOffset([timespan]::FromHours(8)).DateTime -Scheduled -Summary $previous -DailyConfig $config -Attempted $attempted
  if($decision.Action -ne 'RunToday'){$result.Status=$decision.Action;return}
  if(-not(Test-BrowserShareRuntimeManifest -Root $root)){throw 'BrowserRuntimeInvalid'}
  if($RecoveryId -and $permit.ReadOnly){$result.Status='ReadyForReadOnly';return}
  if($Action -in @('ConfirmSubmitted','ConfirmAlready') -and -not $RewardEvidenceFile){throw 'BrowserEvidenceRequired'}
  $runtime=Get-Content -LiteralPath (Join-Path $root 'daily-runtime-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($runtime.BrowserProfileLinkSHA256 -cnotmatch '^[a-f0-9]{64}$'){$result.Status='BrowserAccountBindingRequired';return}
  if($Action -eq 'Prepare'){
    if(Test-BrowserShareReady -Root $root -Date $date -Now $now -RecoveryId $RecoveryId){$result.Status='ReadyForNative';return}
    if(Test-Path -LiteralPath $paths.Ready){throw 'BrowserEvidenceInvalid'}
    if(Test-Path -LiteralPath $paths.Claim){$result.Status='SkipAttempted';return}
    if(Test-Path -LiteralPath $paths.Submitted){throw 'BrowserEvidenceInvalid'}
    $newNonce=[guid]::NewGuid().ToString('N')
    $claim=[ordered]@{Date=$date;RecoveryId=$RecoveryId;Nonce=$newNonce;StartedAt=$now.ToString('o');OneSubmissionPerAttempt=$true}
    if(-not(New-DailyClaim -Path $paths.Claim -Content ($claim|ConvertTo-Json -Compress))){$result.Status='SkipAttempted';return}
    $result.Status='ReadyForBrowser';$result.Nonce=$newNonce;return
  }
  $claim=Get-Content -LiteralPath $paths.Claim -Raw -Encoding UTF8|ConvertFrom-Json
  if($Nonce -cnotmatch '^[a-f0-9]{32}$' -or $claim.Nonce -cne $Nonce -or $claim.Date -cne $date -or [string]$claim.RecoveryId -cne $RecoveryId){throw 'BrowserEvidenceInvalid'}
  $started=[datetimeoffset]::Parse($claim.StartedAt)
  if($started.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $date -or $started -gt $now){throw 'BrowserEvidenceInvalid'}
  $result.Nonce=$Nonce
  if($Action -eq 'Fail'){Save-DailyPause -Root $root -Reason ('BrowserShare'+$Reason);$result.Status='Paused';$result.Reason=$Reason;return}
  if(Test-Path -LiteralPath $paths.Ready){$result.Status='SkipAttempted';return}
  if($Action -eq 'ClaimSubmit'){
    $record=[ordered]@{Date=$date;Nonce=$Nonce;SubmittedAt=$now.ToString('o');MaximumClicks=1;State='ClaimedBeforeClick'}
    if(-not(New-DailyClaim -Path $paths.Submitted -Content ($record|ConvertTo-Json -Compress))){$result.Status='SkipAttempted';return}
    $result.Status='ReadyForOneClick';return
  }
  $submitted=if($Action -eq 'ConfirmSubmitted'){1}else{0}
  if((Test-Path -LiteralPath $paths.Submitted) -ne [bool]$submitted){throw 'BrowserEvidenceInvalid'}
  $ready=[ordered]@{Date=$date;RecoveryId=$RecoveryId;Nonce=$Nonce;ObservedAt=$now.ToString('o');Status='ConfirmedOfficialBrowserShare';ShareExperience=5;Submitted=$submitted;ResponseBusinessCode=$null;Source='OfficialAccountPageObservedByCodex';NoExternalMessages=$true;NoCoins=$true}
  if($RewardEvidenceFile){
    $expected='BrowserShareReward-'+$date.Replace('-','')+'-'+$Nonce+'.json'
    if($RewardEvidenceFile -cne $expected){throw 'BrowserEvidenceInvalid'}
    $evidenceHash=(Get-FileHash -LiteralPath (Join-Path $logs $RewardEvidenceFile) -Algorithm SHA256).Hash
    if($Action -eq 'ConfirmAlready'){
      if(-not(Test-BrowserShareAlreadyEvidence -Root $root -Date $date -Nonce $Nonce -RecoveryId $RecoveryId -StartedAt $started -ObservedAt $now -EvidenceFile $RewardEvidenceFile -EvidenceSHA256 $evidenceHash)){throw 'BrowserEvidenceInvalid'}
      $ready.ValidationMethod='OfficialAlreadyRewardV1'
    } else {
    $submission=Get-Content -LiteralPath $paths.Submitted -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not(Test-BrowserShareRewardEvidence -Root $root -Date $date -Nonce $Nonce -RecoveryId $RecoveryId -StartedAt $started -SubmittedAt ([datetimeoffset]::Parse($submission.SubmittedAt)) -ObservedAt $now -EvidenceFile $RewardEvidenceFile -EvidenceSHA256 $evidenceHash)){throw 'BrowserEvidenceInvalid'}
    $ready.ResponseBusinessCode=$null
    $ready.ValidationMethod='OfficialRewardTransitionV1'
    }
    $ready.ResponseObservation='Unavailable'
    $ready.RewardEvidenceFile=$RewardEvidenceFile
    $ready.RewardEvidenceSHA256=$evidenceHash
  }
  if(-not(New-DailyClaim -Path $paths.Ready -Content ($ready|ConvertTo-Json -Compress))){$result.Status='SkipAttempted';return}
  if(-not(Test-BrowserShareReady -Root $root -Date $date -Now $now -RecoveryId $RecoveryId)){throw 'BrowserEvidenceInvalid'}
  $result.Status='ReadyForNative'
} catch {
  Save-DailyPause -Root $root -Reason 'BrowserShareLocalEvidenceUnconfirmed'
  $result.Status='Paused';$result.Reason='LocalEvidenceUnconfirmed'
} finally {
  $result.ObservedAt=[datetimeoffset]::Now.ToString('o')
  $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $logs 'browser-last-invocation.json') -Encoding UTF8
  $result|ConvertTo-Json -Depth 5|Write-Output
  if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
