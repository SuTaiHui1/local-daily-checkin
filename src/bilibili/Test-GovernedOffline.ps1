[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Daily.Common.ps1')
. (Join-Path $PSScriptRoot 'BrowserShare.Common.ps1')
. (Join-Path $PSScriptRoot 'Recovery.Common.ps1')
$count=0
function Check($actual,$expected,[string]$label){if($actual -cne $expected){throw ('Governed offline assertion failed: '+$label)};$script:count++}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('LocalDailyCheckin-GovernedTest-'+[guid]::NewGuid().ToString('N'))
$logs=Join-Path $fixture 'Logs';$null=New-Item -ItemType Directory -Path $logs -Force
function Save($path,$object){$object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8}
try {
    # Exercise the real wrapper using an inert entry substitute in isolated state.
    $tokens=$null;$errors=$null
    $entryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'DailyRun.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'DailyEntrySyntaxInvalid'}
    $stub=$entryAst.ParamBlock.Extent.Text+"`r`n"+@'
[ordered]@{Scheduled=[bool]$Scheduled;RecoveryId=$RecoveryId} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stub-invocation.json') -Encoding UTF8
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'DailyRun.ps1'),$stub,[Text.UTF8Encoding]::new($true))
    $wrapper=Join-Path $PSScriptRoot 'Run.ps1';$stubResult=Join-Path $fixture 'stub-invocation.json'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -StateRoot $fixture -Mode Daily -Scheduled
    Check $LASTEXITCODE 0 'ordinary wrapper forwards empty recovery safely'
    $inv=Get-Content -LiteralPath $stubResult -Raw | ConvertFrom-Json
    Check $inv.RecoveryId '' 'ordinary wrapper has no recovery id'
    Check $inv.Scheduled $true 'ordinary wrapper preserves Scheduled'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -StateRoot $fixture -Mode Daily -Scheduled -RecoveryId ('a'*32)
    Check $LASTEXITCODE 0 'recovery wrapper forwards valid id'
    $inv=Get-Content -LiteralPath $stubResult -Raw | ConvertFrom-Json
    Check $inv.RecoveryId ('a'*32) 'recovery wrapper preserves id'
    $stubHash=(Get-FileHash -LiteralPath $stubResult -Algorithm SHA256).Hash
    $invalidRejected=$false
    try { & $wrapper -StateRoot $fixture -Mode Daily -Scheduled -RecoveryId 'invalid' } catch {$invalidRejected=$true}
    Check $invalidRejected $true 'invalid recovery is rejected before stub entry'
    Check (Get-FileHash -LiteralPath $stubResult -Algorithm SHA256).Hash $stubHash 'rejected recovery preserves prior invocation'
    $date='2030-01-02';$nonce='a'*32;$profileHash='b'*64;$now=[datetimeoffset]'2030-01-02T20:10:00+08:00'
    Save (Join-Path $fixture 'daily-runtime-manifest.json') @{BrowserProfileLinkSHA256=$profileHash}
    $evidenceName='BrowserShareReward-20300102-'+$nonce+'.json';$evidencePath=Join-Path $logs $evidenceName
    $evidence=@{Date=$date;Nonce=$nonce;RecoveryId='';Source='OfficialAccountPageObservedByCodex';AccountMatches=$true;ProfileLinkSHA256=$profileHash;BeforeShareExperience=0;AfterShareExperience=5;BeforeCurrentExperience=100;AfterCurrentExperience=105;SubmittedClicks=1;BeforeObservedAt='2030-01-02T20:01:00+08:00';ObservedAt='2030-01-02T20:03:00+08:00'}
    $args=@{Root=$fixture;Date=$date;Nonce=$nonce;StartedAt=[datetimeoffset]'2030-01-02T20:00:00+08:00';SubmittedAt=[datetimeoffset]'2030-01-02T20:02:00+08:00';ObservedAt=$now;EvidenceFile=$evidenceName}
    Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareRewardEvidence @args) $true 'observed official reward transition accepted'
    $evidence.ProfileLinkSHA256='c'*64;Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareRewardEvidence @args) $false 'account mismatch rejected'
    $evidence.ProfileLinkSHA256=$profileHash;$evidence.SubmittedClicks=2;Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareRewardEvidence @args) $false 'second click rejected'
    $evidence.SubmittedClicks=1;$evidence.BeforeObservedAt='2030-01-02T20:02:30+08:00';Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareRewardEvidence @args) $false 'before observation after click rejected'
    $evidence.BeforeObservedAt='2030-01-02T20:01:00+08:00';$evidence.ObservedAt='2030-01-03T00:00:00+08:00';Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareRewardEvidence @args) $false 'different reward day rejected'
    $evidence.ObservedAt='2030-01-02T20:03:00+08:00';Save $evidencePath $evidence;$args.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    $paths=Get-BrowserSharePaths -Root $fixture -Date $date
    Save $paths.Claim @{Date=$date;Nonce=$nonce;RecoveryId='';StartedAt='2030-01-02T20:00:00+08:00'}
    Save $paths.Submitted @{Date=$date;Nonce=$nonce;SubmittedAt='2030-01-02T20:02:00+08:00';MaximumClicks=1;State='ClaimedBeforeClick'}
    $ready=@{Date=$date;Nonce=$nonce;RecoveryId='';ObservedAt='2030-01-02T20:04:00+08:00';Status='ConfirmedOfficialBrowserShare';ShareExperience=5;Submitted=1;ValidationMethod='OfficialRewardTransitionV1';ResponseBusinessCode=$null;Source='OfficialAccountPageObservedByCodex';ResponseObservation='Unavailable';RewardEvidenceFile=$evidenceName;RewardEvidenceSHA256=$args.EvidenceSHA256}
    Save $paths.Ready $ready
    Check (Test-BrowserShareReady -Root $fixture -Date $date -Now $now) $true 'ready requires real evidence'
    $ready.ValidationMethod=$null;$ready.ResponseBusinessCode=0;Save $paths.Ready $ready
    Check (Test-BrowserShareReady -Root $fixture -Date $date -Now $now) $false 'invented default response zero rejected'
    $already=@{Date=$date;Nonce=$nonce;RecoveryId='';Source='OfficialAccountPageObservedByCodex';AccountMatches=$true;ProfileLinkSHA256=$profileHash;ShareExperience=5;SubmittedClicks=0;ObservedAt='2030-01-02T20:03:00+08:00'}
    Save $evidencePath $already
    $alreadyArgs=@{Root=$fixture;Date=$date;Nonce=$nonce;StartedAt=[datetimeoffset]'2030-01-02T20:00:00+08:00';ObservedAt=$now;EvidenceFile=$evidenceName;EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash}
    Check (Test-BrowserShareAlreadyEvidence @alreadyArgs) $true 'already complete observation accepted'
    $already.ShareExperience=0;Save $evidencePath $already;$alreadyArgs.EvidenceSHA256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash
    Check (Test-BrowserShareAlreadyEvidence @alreadyArgs) $false 'unearned reward not declared complete'
    $claim=Join-Path $logs 'immutable.attempted'
    Check (New-DailyClaim -Path $claim -Content 'first') $true 'first immutable claim succeeds'
    Check (New-DailyClaim -Path $claim -Content 'second') $false 'same attempt not overwritten'
    Check ([IO.File]::ReadAllText($claim)) 'first' 'original attempt preserved'
    Check (Get-DailyRecoveryBudget -Root $fixture -Date $date -Now $now).ReadOnlyRequired $false 'no native attempt has no coin uncertainty'
    $manifest=@{Version='test';CoinJournalProtocol='CoinIntentV1';Files=@(@{File='app\Ray.BiliBiliTool.Console.exe';SHA256=('d'*64)})}
    $manifestFile=Join-Path $logs 'manifest-fixture.json';Save $manifestFile $manifest
    $mh=(Get-FileHash $manifestFile -Algorithm SHA256).Hash;Copy-Item -LiteralPath $manifestFile -Destination (Join-Path $logs ('Runtime-'+$mh+'.json'))
    $attempt=@{Date=$date;RunNonce=$nonce;AttemptedAt='2030-01-02T20:00:00+08:00';Version='test';CoinJournalRequired=$true;CoinJournalProtocol='CoinIntentV1';RuntimeManifestSHA256=$mh;NativeSHA256=('d'*64)}
    Save (Join-Path $logs 'Daily-20300102.attempted') $attempt
    $intentPath=Join-Path $logs ('CoinPost-20300102-'+$nonce+'-1.json')
    $intent=@{Date=$date;RunNonce=$nonce;Sequence=1;Coins=1;Aid=123;AccountingBefore=4;Status='ClaimedBeforeSubmit';ClaimedAt='2030-01-02T20:01:00+08:00'};Save $intentPath $intent
    $budget=Get-DailyRecoveryBudget -Root $fixture -Date $date -Now $now
    Check $budget.ReadOnlyRequired $true 'unconfirmed submission forces read-only recovery'
    Check $budget.ConfirmedDailyFloor 4 'previous platform floor preserved'
    $receipt=@{Date=$date;RunNonce=$nonce;Sequence=1;Coins=1;IntentSHA256=(Get-FileHash $intentPath -Algorithm SHA256).Hash;ObservedAt='2030-01-02T20:02:00+08:00';Status='Confirmed';BusinessCode=0;AccountingAfter=5}
    Save ([IO.Path]::ChangeExtension($intentPath,'.result.json')) $receipt
    $budget=Get-DailyRecoveryBudget -Root $fixture -Date $date -Now $now
    Check $budget.ReadOnlyRequired $false 'valid confirmation resolves unknown submission'
    Check $budget.ConfirmedDailyFloor 5 'fifth coin floor carries into next attempt'
    $receipt.IntentSHA256='e'*64;Save ([IO.Path]::ChangeExtension($intentPath,'.result.json')) $receipt
    Check (Get-DailyRecoveryBudget -Root $fixture -Date $date -Now $now).ReadOnlyRequired $true 'changed intent provenance forces read-only'
    $rid='f'*32
    $permit=@{Date=$date;RecoveryId=$rid;CreatedAt='2030-01-02T20:05:00+08:00';Status='AuthorizedRepair';PolicyVersion='ContinuousRepairV1';RepairSummary='Synthetic diagnosed failure';OriginalAttemptSHA256=(Get-FileHash (Join-Path $logs 'Daily-20300102.attempted')).Hash;ReadOnly=$true}
    Save (Get-DailyRecoveryPermitPath -Root $fixture -Date $date -RecoveryId $rid) $permit
    Check (Test-DailyRecoveryPermit -Root $fixture -Date $date -RecoveryId $rid -Now $now) $true 'same-day evidence-bound permit accepted'
    $permit.OriginalAttemptSHA256='e'*64;Save (Get-DailyRecoveryPermitPath -Root $fixture -Date $date -RecoveryId $rid) $permit
    Check (Test-DailyRecoveryPermit -Root $fixture -Date $date -RecoveryId $rid -Now $now) $false 'changed original attempt rejects permit'
} finally {
    $base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';$target=[IO.Path]::GetFullPath($fixture)
    if($target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($target) -like 'LocalDailyCheckin-GovernedTest-*'){Remove-Item -LiteralPath $target -Recurse -Force}
}
[pscustomobject]@{Status='Passed';Checks=$count;NetworkRequests=0;NativeToolStarted=$false;ActualAccountUsed=$false}
