function Get-DailyRecoveryPermitPath {
  param([string]$Root,[string]$Date,[string]$RecoveryId)
  if($Date -cnotmatch '^\d{4}-\d{2}-\d{2}$' -or $RecoveryId -cnotmatch '^[a-f0-9]{32}$'){throw 'InvalidRecoveryIdentity'}
  Join-Path (Join-Path $Root 'Logs') ('Recovery-'+$Date.Replace('-','')+'-'+$RecoveryId+'.json')
}

function Test-RecoverySafeEvidence {
  param([string]$Root,[string]$Date,[string]$File,[string]$SHA256)
  try {
    if($File -cnotmatch '^Logs[\\/](?:Daily-|BrowserShare-|Invocation-|RecoveryEvidence-|browser-last-invocation)[a-zA-Z0-9_.-]*\.(?:json|attempted)$' -or $SHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){return $false}
    $path=Join-Path $Root $File
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $SHA256){return $false}
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    return $record.Date -ceq $Date
  } catch {return $false}
}

function Test-DailyRecoveryPermit {
  param([string]$Root,[string]$Date,[string]$RecoveryId,[datetimeoffset]$Now)
  try {
    $path=Get-DailyRecoveryPermitPath -Root $Root -Date $Date -RecoveryId $RecoveryId
    $p=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    $created=[datetimeoffset]::Parse($p.CreatedAt)
    if($p.Date -cne $Date -or $p.RecoveryId -cne $RecoveryId -or $p.Status -cne 'AuthorizedRepair' -or $p.PolicyVersion -cne 'ContinuousRepairV1' -or [string]::IsNullOrWhiteSpace($p.RepairSummary)){return $false}
    if($Now.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $created.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $created -gt $Now){return $false}
    if($null -ne $p.ReadOnly -and $p.ReadOnly -isnot [bool]){return $false}
    $original=Join-Path (Join-Path $Root 'Logs') ('Daily-'+$Date.Replace('-','')+'.attempted')
    if(Test-Path -LiteralPath $original){if((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ine $p.OriginalAttemptSHA256){return $false}}
    elseif($p.OriginalAttemptSHA256 -cne 'Absent' -or -not(Test-RecoverySafeEvidence -Root $Root -Date $Date -File $p.SourceEvidenceFile -SHA256 $p.SourceEvidenceSHA256)){return $false}
    foreach($r in @($p.CoinResolutions)){
      if($null -eq $r){continue}
      if($r.IntentFile -cnotmatch ('^CoinPost-'+$Date.Replace('-','')+'-[a-f0-9]{32}-[1-5]\.json$') -or $r.IntentSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or $r.Disposition -cnotin @('Confirmed','NotAccepted') -or $r.VerificationMethod -cne 'PlatformCoinLedgerAndBalanceAndDailyTotal'){return $false}
      if((Get-FileHash -LiteralPath (Join-Path (Join-Path $Root 'Logs') $r.IntentFile) -Algorithm SHA256).Hash -ine $r.IntentSHA256){return $false}
      $verified=[datetimeoffset]::Parse($r.VerifiedAt)
      if($verified -gt $created -or $verified.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or -not(Test-RecoverySafeEvidence -Root $Root -Date $Date -File $r.EvidenceFile -SHA256 $r.EvidenceSHA256)){return $false}
    }
    return $true
  } catch {return $false}
}

function Test-CoinJournalAttempt {
  param([string]$Root,$Attempt)
  try {
    if($Attempt.CoinJournalRequired -cne $true -or $Attempt.CoinJournalProtocol -cne 'CoinIntentV1' -or $Attempt.RuntimeManifestSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or $Attempt.NativeSHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){return $false}
    $path=Join-Path (Join-Path $Root 'Logs') ('Runtime-'+$Attempt.RuntimeManifestSHA256+'.json')
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Attempt.RuntimeManifestSHA256){return $false}
    $m=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    $native=@($m.Files|Where-Object {$_.File -ceq 'app\Ray.BiliBiliTool.Console.exe'})
    return $m.Version -ceq $Attempt.Version -and $m.CoinJournalProtocol -ceq 'CoinIntentV1' -and $native.Count -eq 1 -and $native[0].SHA256 -ieq $Attempt.NativeSHA256
  } catch {return $false}
}

function Get-DailyRecoveryBudget {
  param([string]$Root,[string]$Date,$Permit=$null,[datetimeoffset]$Now=[datetimeoffset]::Now)
  $logs=Join-Path $Root 'Logs';$compact=$Date.Replace('-','');$floor=0;$unknown=$false;$confirmedCount=0
  $reasons=New-Object 'Collections.Generic.List[string]';$seen=@{};$knownIntents=@{};$knownResults=@{};$knownLogs=@{}
  $journalOrder=New-Object 'Collections.Generic.List[object]'
  $allRunLogs=@(Get-ChildItem -LiteralPath $logs -Filter ('Daily-'+$compact+'-*.txt') -File)
  foreach($file in @(Get-ChildItem -LiteralPath $logs -Filter ('Daily-'+$compact+'*.attempted') -File)){
    try {
      if($file.Name -cnotmatch ('^Daily-'+$compact+'(?:-recovery-[a-f0-9]{32})?\.attempted$')){throw 'AttemptNameInvalid'}
      $a=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
      if($a.Date -cne $Date -or $a.RunNonce -cnotmatch '^[a-f0-9]{32}$' -or $seen.ContainsKey($a.RunNonce)){throw 'AttemptIdentityInvalid'}
      $seen[$a.RunNonce]=$true
      $runLogs=@($allRunLogs | Where-Object {Select-String -LiteralPath $_.FullName -Pattern ('\bDAILY_RUN Started Nonce='+$a.RunNonce+' Date='+$Date+'\b') -Quiet})
      if($runLogs.Count -gt 1){throw 'DuplicateRunLog'}
      if($runLogs.Count -eq 1){$knownLogs[$runLogs[0].Name]=$true}
      $lines=if($runLogs.Count -eq 1){@(Get-Content -LiteralPath $runLogs[0].FullName -Encoding UTF8)}else{@()}
      $journal=Test-CoinJournalAttempt -Root $Root -Attempt $a
      $intents=@(Get-ChildItem -LiteralPath $logs -Filter ('CoinPost-'+$compact+'-'+$a.RunNonce+'-*.json') -File | Where-Object {$_.Name -notlike '*.result.json'} | Sort-Object Name)
      if($journal){
        $attempted=[datetimeoffset]::Parse($a.AttemptedAt)
        if($attempted.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $attempted -gt $Now){throw 'AttemptTimeInvalid'}
        $sequence=0;$previousAfter=-1
        foreach($intentFile in $intents){
          $sequence++;$knownIntents[$intentFile.Name]=$true
          $i=Get-Content -LiteralPath $intentFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json
          if($intentFile.Name -cne ('CoinPost-'+$compact+'-'+$a.RunNonce+'-'+$sequence+'.json') -or $i.Date -cne $Date -or $i.RunNonce -cne $a.RunNonce -or $i.Sequence -cne $sequence -or $sequence -gt 5 -or $i.Coins -cne 1 -or $i.Aid -le 0 -or $i.AccountingBefore -notin @(0,1,2,3,4) -or $i.AccountingBefore -lt $previousAfter -or $i.Status -cne 'ClaimedBeforeSubmit'){throw 'CoinIntentInvalid'}
          $claimed=[datetimeoffset]::Parse($i.ClaimedAt)
          if($claimed.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $claimed -lt $attempted -or $claimed -gt $Now){throw 'CoinIntentTimeInvalid'}
          $floor=[math]::Max($floor,[int]$i.AccountingBefore)
          $intentHash=(Get-FileHash -LiteralPath $intentFile.FullName -Algorithm SHA256).Hash
          $resultPath=[IO.Path]::ChangeExtension($intentFile.FullName,'.result.json')
          $resolved=$false;$accepted=$false
          if(Test-Path -LiteralPath $resultPath){
            $knownResults[[IO.Path]::GetFileName($resultPath)]=$true
            $r=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
            if($r.Date -cne $Date -or $r.RunNonce -cne $a.RunNonce -or $r.Sequence -cne $sequence -or $r.IntentSHA256 -ine $intentHash -or $r.Coins -cne 1){throw 'CoinResultInvalid'}
            $observed=[datetimeoffset]::Parse($r.ObservedAt)
            if($observed.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $observed -lt $claimed -or $observed -gt $Now){throw 'CoinResultTimeInvalid'}
            if($r.Status -ceq 'Confirmed' -and $r.BusinessCode -ceq 0 -and $r.AccountingAfter -ceq ([int]$i.AccountingBefore+1)){$resolved=$true;$accepted=$true}
            elseif($r.Status -ceq 'Rejected' -and $r.BusinessCode -in @(-101,-102,-111,-400,-403,-412,10003,34002,34003,34004,34005) -and $r.AccountingAfter -ceq $i.AccountingBefore){$resolved=$true}
          }
          if(-not $resolved){
            $resolution=@($Permit.CoinResolutions|Where-Object {$_.IntentFile -ceq $intentFile.Name -and $_.IntentSHA256 -ieq $intentHash})
            if($resolution.Count -eq 1){
              $observed=[datetimeoffset]::Parse($resolution[0].VerifiedAt)
              if($observed.ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd') -cne $Date -or $observed -lt $claimed -or $observed -gt $Now){throw 'CoinResolutionTimeInvalid'}
              $resolved=$true;$accepted=$resolution[0].Disposition -ceq 'Confirmed'
            }
          }
          if($resolved){
            $previousAfter=[int]$i.AccountingBefore+[int]$accepted;$floor=[math]::Max($floor,$previousAfter)
            if($accepted){$confirmedCount++}
            $journalOrder.Add([pscustomobject]@{Claimed=$claimed;Observed=$observed;Before=[int]$i.AccountingBefore;After=$previousAfter})
          }
          else{$unknown=$true;$reasons.Add('CoinSubmissionUnconfirmed')}
        }
      } elseif($intents.Count -gt 0){throw 'CoinJournalProvenanceMissing'}
      if($lines.Count -gt 0){
        $e=Get-DailyEvidence -Lines $lines
        if(-not $e.EvidenceValid -or $e.RunNonce -cne $a.RunNonce -or $e.Date -cne $Date){throw 'RunEvidenceInvalid'}
        $accounted=@($lines|ForEach-Object {if($_ -match '\bAccountedDailyCoins=([0-9]+)\b'){[int]$Matches[1]}})
        if($accounted.Count -gt 0){$floor=[math]::Max($floor,[int]($accounted|Measure-Object -Maximum).Maximum)}
        if($null -ne $e.InitialDailyCoins -and $null -ne $e.NativeSuccessCoins){$floor=[math]::Max($floor,[int]$e.InitialDailyCoins+[int]$e.NativeSuccessCoins)}
        if(-not $journal -and $e.Complete -and ($null -eq $e.InitialDailyCoins -or $null -eq $e.NativeSuccessCoins)){throw 'LegacyCompletedCoinEvidenceMissing'}
        if(-not $journal -and -not $e.Complete){
          $preCoinShareFailure=($a.Version -cmatch '^4\.2\.1-localfix5(?:\+[a-f0-9]{40})?$' -and @($lines|Where-Object {$_ -match '\bDAILY_COINS\b'}).Count -eq 0 -and @($lines|Where-Object {$_ -match '\bSHARE_CONTEXT Reply .*Stage=Share .*ServerCode=-403\b'}).Count -eq 1 -and @($lines|Where-Object {$_ -match '^DAILY_RUN Stopped Reason=PlatformBusiness403$'}).Count -eq 1)
          if(-not $preCoinShareFailure){$unknown=$true;$reasons.Add('LegacyRunOutcomeUnconfirmed')}
        }
      } elseif(-not $journal){$unknown=$true;$reasons.Add('LegacyRunLogMissing')}
    } catch {$unknown=$true;$reasons.Add($_.Exception.Message)}
  }
  foreach($orphan in @(Get-ChildItem -LiteralPath $logs -Filter ('CoinPost-'+$compact+'-*.json') -File|Where-Object {$_.Name -notlike '*.result.json'})){
    if(-not $knownIntents.ContainsKey($orphan.Name)){$unknown=$true;$reasons.Add('OrphanCoinIntent')}
  }
  foreach($orphan in @(Get-ChildItem -LiteralPath $logs -Filter ('CoinPost-'+$compact+'-*.result.json') -File)){
    if(-not $knownResults.ContainsKey($orphan.Name)){$unknown=$true;$reasons.Add('OrphanCoinResult')}
  }
  foreach($orphan in $allRunLogs){
    if(-not $knownLogs.ContainsKey($orphan.Name)){$unknown=$true;$reasons.Add('OrphanDailyRunLog')}
  }
  $previousFloor=0;$previousObserved=$null
  foreach($event in @($journalOrder|Sort-Object Claimed)){
    if($event.Before -lt $previousFloor -or ($null -ne $previousObserved -and $event.Claimed -lt $previousObserved)){$unknown=$true;$reasons.Add('CoinJournalOrderInvalid')}
    $previousFloor=[math]::Max($previousFloor,$event.After);$previousObserved=$event.Observed
  }
  $floor=[math]::Max($floor,$confirmedCount)
  if($floor -lt 0 -or $floor -gt 5){$unknown=$true;$reasons.Add('DailyCoinFloorInvalid');$floor=5}
  [pscustomobject]@{Date=$Date;ConfirmedDailyFloor=$floor;ReadOnlyRequired=$unknown;Reasons=@($reasons|Select-Object -Unique);AttemptCount=$seen.Count;PlatformQuantityConfirmed=$false}
}
