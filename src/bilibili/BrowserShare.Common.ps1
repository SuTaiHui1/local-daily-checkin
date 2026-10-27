function Get-BrowserSharePaths {
  param([string]$Root,[string]$Date,[string]$RecoveryId='')
  if($RecoveryId -and $RecoveryId -cnotmatch '^[a-f0-9]{32}$'){throw 'InvalidRecoveryId'}
  $stem=Join-Path (Join-Path $Root 'Logs') ('BrowserShare-'+$Date.Replace('-',''))
  if($RecoveryId){$stem+='-recovery-'+$RecoveryId}
  [pscustomobject]@{Claim=$stem+'.attempted';Submitted=$stem+'.submitted';Ready=$stem+'.json'}
}

function Test-BrowserShareRuntimeManifest {
  param([string]$Root)
  try {
    $required=@('Launch.ps1','Run.ps1','DailyRun.ps1','Daily.Common.ps1','DailyDecision.ps1','Recovery.Common.ps1','BrowserShare.ps1','BrowserShare.Common.ps1','Experience.ps1','CoinDetails.ps1','Forecast.ps1','Policy.ps1','Report.ps1','ShowQr.ps1','Bind-BrowserProfile.ps1','app\Ray.BiliBiliTool.Console.exe')
    $manifest=Get-Content -LiteralPath (Join-Path $Root 'daily-runtime-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if(@($manifest.Files).Count -ne $required.Count -or @(Compare-Object $required @($manifest.Files.File) -CaseSensitive).Count -ne 0){return $false}
    foreach($entry in $manifest.Files){
      if($entry.File -match '(^[\\/]|:|\.\.)' -or (Get-FileHash -LiteralPath (Join-Path $Root $entry.File) -Algorithm SHA256).Hash -cne $entry.SHA256){return $false}
    }
    return $true
  } catch {return $false}
}

function Test-BrowserShareRewardEvidence {
  param([string]$Root,[string]$Date,[string]$Nonce,[string]$RecoveryId='',
    [datetimeoffset]$StartedAt,[datetimeoffset]$SubmittedAt,[datetimeoffset]$ObservedAt,
    [string]$EvidenceFile,[string]$EvidenceSHA256)
  try {
    $expected='BrowserShareReward-'+$Date.Replace('-','')+'-'+$Nonce+'.json'
    if($EvidenceFile -cne $expected -or $EvidenceSHA256 -cnotmatch '^[A-F0-9]{64}$'){return $false}
    $path=Join-Path (Join-Path $Root 'Logs') $EvidenceFile
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $EvidenceSHA256){return $false}
    $evidence=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($evidence.Date -cne $Date -or $evidence.Nonce -cne $Nonce -or [string]$evidence.RecoveryId -cne $RecoveryId){return $false}
    if($evidence.Source -cne 'OfficialAccountPageObservedByCodex' -or $evidence.AccountMatches -isnot [bool] -or -not $evidence.AccountMatches){return $false}
    $manifest=Get-Content -LiteralPath (Join-Path $Root 'daily-runtime-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.BrowserProfileLinkSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $evidence.ProfileLinkSHA256 -cne $manifest.BrowserProfileLinkSHA256){return $false}
    foreach($key in @('BeforeShareExperience','AfterShareExperience','BeforeCurrentExperience','AfterCurrentExperience','SubmittedClicks')){
      $value=$evidence.$key
      if($null -eq $value -or $value -is [string] -or $value -is [bool]){return $false}
      $number=[double]$value
      if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0){return $false}
    }
    if($evidence.BeforeShareExperience -ne 0 -or $evidence.AfterShareExperience -ne 5 -or $evidence.SubmittedClicks -ne 1 -or $evidence.AfterCurrentExperience -lt $evidence.BeforeCurrentExperience){return $false}
    $before=[datetimeoffset]::Parse($evidence.BeforeObservedAt)
    $after=[datetimeoffset]::Parse($evidence.ObservedAt)
    if($before.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $after.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date){return $false}
    if($before -lt $StartedAt -or $before -gt $SubmittedAt -or $after -lt $SubmittedAt -or $after -gt $ObservedAt){return $false}
    return $true
  } catch {return $false}
}

function Test-BrowserShareReady {
  param([string]$Root,[string]$Date,[datetimeoffset]$Now,[string]$RecoveryId='')
  try {
    $paths=Get-BrowserSharePaths -Root $Root -Date $Date -RecoveryId $RecoveryId
    $claim=Get-Content -LiteralPath $paths.Claim -Raw -Encoding UTF8 | ConvertFrom-Json
    $ready=Get-Content -LiteralPath $paths.Ready -Raw -Encoding UTF8 | ConvertFrom-Json
    $started=[datetimeoffset]::Parse($claim.StartedAt)
    $observed=[datetimeoffset]::Parse($ready.ObservedAt)
    if($claim.Date -cne $Date -or $ready.Date -cne $Date -or $claim.Nonce -cnotmatch '^[a-f0-9]{32}$' -or $ready.Nonce -cne $claim.Nonce){return $false}
    if([string]$claim.RecoveryId -cne $RecoveryId -or [string]$ready.RecoveryId -cne $RecoveryId){return $false}
    if($started.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $observed.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $observed -lt $started -or $observed -gt $Now){return $false}
    if($ready.Status -cne 'ConfirmedOfficialBrowserShare' -or $ready.ShareExperience -cne 5 -or $ready.Submitted -notin @(0,1)){return $false}
    if($ready.Source -cne 'OfficialAccountPageObservedByCodex' -or $null -ne $ready.ResponseBusinessCode){return $false}
    if($ready.Submitted -eq 1){
      $submitted=Get-Content -LiteralPath $paths.Submitted -Raw -Encoding UTF8 | ConvertFrom-Json
      $at=[datetimeoffset]::Parse($submitted.SubmittedAt)
      if($submitted.Date -cne $Date -or $submitted.Nonce -cne $claim.Nonce -or $submitted.MaximumClicks -cne 1 -or $submitted.State -cne 'ClaimedBeforeClick' -or $at -lt $started -or $at -gt $observed){return $false}
      if($ready.ValidationMethod -ceq 'OfficialRewardTransitionV1'){
        if($null -ne $ready.ResponseBusinessCode -or $ready.Source -cne 'OfficialAccountPageObservedByCodex' -or $ready.ResponseObservation -cne 'Unavailable'){return $false}
        if(-not(Test-BrowserShareRewardEvidence -Root $Root -Date $Date -Nonce $claim.Nonce -RecoveryId $RecoveryId -StartedAt $started -SubmittedAt $at -ObservedAt $observed -EvidenceFile $ready.RewardEvidenceFile -EvidenceSHA256 $ready.RewardEvidenceSHA256)){return $false}
      } else {return $false}
    } else {
      if((Test-Path -LiteralPath $paths.Submitted) -or $ready.ValidationMethod -cne 'OfficialAlreadyRewardV1'){return $false}
      if(-not(Test-BrowserShareAlreadyEvidence -Root $Root -Date $Date -Nonce $claim.Nonce -RecoveryId $RecoveryId -StartedAt $started -ObservedAt $observed -EvidenceFile $ready.RewardEvidenceFile -EvidenceSHA256 $ready.RewardEvidenceSHA256)){return $false}
    }
    return $true
  } catch {return $false}
}

function Test-BrowserShareAlreadyEvidence {
  param([string]$Root,[string]$Date,[string]$Nonce,[string]$RecoveryId='',
    [datetimeoffset]$StartedAt,[datetimeoffset]$ObservedAt,[string]$EvidenceFile,[string]$EvidenceSHA256)
  try {
    if($EvidenceFile -cne ('BrowserShareReward-'+$Date.Replace('-','')+'-'+$Nonce+'.json') -or $EvidenceSHA256 -cnotmatch '^[A-F0-9]{64}$'){return $false}
    $path=Join-Path (Join-Path $Root 'Logs') $EvidenceFile
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $EvidenceSHA256){return $false}
    $e=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    $m=Get-Content -LiteralPath (Join-Path $Root 'daily-runtime-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($e.Date -cne $Date -or $e.Nonce -cne $Nonce -or [string]$e.RecoveryId -cne $RecoveryId -or $e.Source -cne 'OfficialAccountPageObservedByCodex'){return $false}
    if($e.AccountMatches -cne $true -or $e.AccountMatches -isnot [bool] -or $m.BrowserProfileLinkSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $e.ProfileLinkSHA256 -cne $m.BrowserProfileLinkSHA256){return $false}
    if($e.ShareExperience -cne 5 -or $e.SubmittedClicks -cne 0){return $false}
    $at=[datetimeoffset]::Parse($e.ObservedAt)
    return $at.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -ceq $Date -and $at -ge $StartedAt -and $at -le $ObservedAt
  } catch {return $false}
}