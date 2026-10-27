# SPDX-License-Identifier: GPL-3.0-only
# All launchers below are synthetic files in a temporary checkout; no account module is imported.
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('local-daily-coordinator-fixture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$checks=0
function Assert-Preparation([bool]$Condition,[string]$Name) {
    if(-not $Condition){throw ('Synthetic preparation check failed: '+$Name)}
    $script:checks++
}
function Property([object]$Object,[string]$Name) {
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $null
}
function Write-FixtureFile([string]$Path,[string]$Content) {
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($true))
}
function Save-Control([object]$Case) {
    $Case.Control | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Case.State 'fixture-control.json') -Encoding UTF8
}
function New-Case([string]$Name,[string]$Preparation='ReadyForNative') {
    $directory=Join-Path $fixture $Name
    $state=Join-Path $directory 'state'
    $null=New-Item -ItemType Directory -Path $state -Force
    $config=Join-Path $directory 'config.json'
    $settings=@{schemaVersion=1;stateRoot=$state;schedule=@{localTime='20:00';timeZone='Asia/Shanghai'};bilibili=@{enabled=$true};heybox=@{enabled=$true}}
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
    $case=[pscustomobject]@{Config=$config;State=$state;Settings=$settings;Control=@{
        Now='2030-01-02T20:15:00';Preparation=$Preparation;PreparationMode='Normal';BilibiliBehavior='Complete';HeyboxBehavior='Complete'
    }}
    Save-Control $case
    return $case
}
function Invoke-Fixture([object]$Case,[hashtable]$Options=@{}) {
    Save-Control $Case
    & (Join-Path $fixtureRepo 'scripts\Run-Daily.ps1') -ConfigPath $Case.Config @Options | Out-Null
    $path=Join-Path $Case.State 'reports\Combined-20300102.json'
    if(Test-Path -LiteralPath $path){return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}
    return $null
}
function Trace([object]$Case) {
    $path=Join-Path $Case.State 'trace.jsonl'
    if(Test-Path -LiteralPath $path){return @(Get-Content -LiteralPath $path | ForEach-Object {$_|ConvertFrom-Json})}
    return @()
}
function Assert-Rejected([object]$Case,[hashtable]$Options,[string]$Expected,[string]$Name) {
    $rejected=$false
    try{Invoke-Fixture $Case $Options|Out-Null}catch{$rejected=$_.Exception.Message -match $Expected}
    Assert-Preparation $rejected $Name
    Assert-Preparation (@(Trace $Case).Count -eq 0) ($Name+' before any synthetic launcher')
}
try {
    $fixtureRepo=Join-Path $fixture 'repo'
    $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') -Force
    foreach($name in @('Common.ps1','Format-Report.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repository ('scripts\'+$name)) -Destination (Join-Path $fixtureRepo ('scripts\'+$name))
    }
    $coordinator=Get-Content -LiteralPath (Join-Path $repository 'scripts\Run-Daily.ps1') -Raw -Encoding UTF8
    $offsetExpression='[TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours'
    if(-not $coordinator.Contains($offsetExpression)){throw 'Coordinator timezone expression changed; review fixture isolation.'}
    # Only the fixture observes a controlled UTC+08 clock. Branches and module coordination are unchanged.
    # This lets Windows CI run at any local time/zone without changing the computer or skipping schedule tests.
    $coordinator=$coordinator.Replace($offsetExpression,'(8)').Replace('Get-Date','Get-FixtureDate')
    $clock=@'
function Get-FixtureDate {
    param([string]$Format)
    $control=Get-Content -LiteralPath (Join-Path $settings.StateRoot 'fixture-control.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $instant=[datetime]::ParseExact($control.Now,'s',[Globalization.CultureInfo]::InvariantCulture)
    if($Format){return $instant.ToString($Format)}
    return $instant
}
'@
    $coordinator=$coordinator.Replace("$"+"ErrorActionPreference='Stop'",$clock+[Environment]::NewLine+"$"+"ErrorActionPreference='Stop'")
    $coordinator=$coordinator.Replace('Local\LocalDailyCheckin-Coordinator',('Local\LocalDailyCheckin-Fixture-'+[guid]::NewGuid().ToString('N')))
    Write-FixtureFile (Join-Path $fixtureRepo 'scripts\Run-Daily.ps1') $coordinator

    $preparer=@'
param([string]$StateRoot,[string]$Action,[string]$RecoveryId)
$ErrorActionPreference='Stop'
$parent=Split-Path -Parent $StateRoot
$control=Get-Content -LiteralPath (Join-Path $parent 'fixture-control.json') -Raw -Encoding UTF8 | ConvertFrom-Json
@{Stage='Prepare';Action=$Action;RecoveryId=$RecoveryId}|ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $parent 'trace.jsonl') -Encoding UTF8
if($control.PreparationMode -eq 'Throw'){throw 'Synthetic preparation failure'}
if($control.PreparationMode -eq 'InvalidJson'){Write-Output 'synthetic invalid json';exit 0}
$date=if($control.PreparationMode -eq 'WrongDate'){'2030-01-01'}else{'2030-01-02'}
$requests=if($control.PreparationMode -eq 'NonzeroRequests'){1}else{0}
@{Date=$date;Status=$control.Preparation;ObservedAt=$control.Now;HelperPlatformRequests=$requests;Nonce='synthetic-private-helper-value'}|ConvertTo-Json -Compress
'@
    Write-FixtureFile (Join-Path $fixtureRepo 'src\bilibili\BrowserShare.ps1') $preparer
    $launcher=@'
param([string]$StateRoot,[string]$Mode,[switch]$Scheduled,[string]$RecoveryId)
$ErrorActionPreference='Stop'
$parent=Split-Path -Parent $StateRoot
$control=Get-Content -LiteralPath (Join-Path $parent 'fixture-control.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$module='__MODULE__'
$behavior=if($module -eq 'bilibili'){$control.BilibiliBehavior}else{$control.HeyboxBehavior}
@{Stage=$module;Mode=$Mode;Scheduled=[bool]$Scheduled;RecoveryId=$RecoveryId;Submitted=($behavior -eq 'Complete')}|ConvertTo-Json -Compress|Add-Content -LiteralPath (Join-Path $parent 'trace.jsonl') -Encoding UTF8
if($behavior -eq 'NoReport'){exit 0}
if($behavior -eq 'Failure'){exit 5}
$logs=Join-Path $StateRoot 'Logs'
$null=New-Item -ItemType Directory -Path $logs -Force
$coinCount=if($behavior -eq 'SkipCompleted'){0}else{5}
$actionCount=if($behavior -eq 'SkipCompleted'){0}else{4}
@{
    Date='2030-01-02';ObservedAt=$control.Now;SummaryObservedAt=$control.Now
    Status=$behavior;Reason=$null;PublicTasks=@();PublicSummary=@();CoinDonations=@()
    NativeSuccessCoins=$coinCount;TodayCoins=5;ActionsSubmittedThisInvocation=$actionCount
    NewObservation=($behavior -eq 'Complete')
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $logs 'Report-20300102.json') -Encoding UTF8
'@
    Write-FixtureFile (Join-Path $fixtureRepo 'src\bilibili\Launch.ps1') ($launcher.Replace('__MODULE__','bilibili'))
    Write-FixtureFile (Join-Path $fixtureRepo 'src\heybox\LaunchDaily.ps1') ($launcher.Replace('__MODULE__','heybox'))

    $pending=New-Case 'pending' 'ReadyForBrowser'
    $result=Invoke-Fixture $pending @{Scheduled=$true}
    $events=@(Trace $pending)
    Assert-Preparation (@($events|Where-Object {$_.Stage -eq 'bilibili'}).Count -eq 0 -and @($events|Where-Object {$_.Stage -eq 'heybox'}).Count -eq 1) 'browser pending keeps native idle and allows independent Heybox'
    Assert-Preparation ($result.Bilibili.InvocationStatus -eq 'ReadyForBrowser' -and $result.Bilibili.NativeSuccessCoins -eq 0 -and $result.Heybox.ActionsSubmittedThisInvocation -eq 4) 'pending zero counts do not hide Heybox submission count'
    Assert-Preparation (($result|ConvertTo-Json -Depth 12) -notmatch 'synthetic-private-helper-value') 'private helper nonce is absent from combined report'

    $ready=New-Case 'ready'
    $result=Invoke-Fixture $ready @{Scheduled=$true}
    $events=@(Trace $ready)
    Assert-Preparation (($events.Stage -join ',') -eq 'Prepare,bilibili,heybox') 'native-ready preparation precedes independent modules'
    Assert-Preparation ($result.Bilibili.NativeSuccessCoins -eq 5 -and $result.Heybox.ActionsSubmittedThisInvocation -eq 4) 'fresh module reports keep current invocation counts'
    Assert-Preparation (@($events|Where-Object {$_.Stage -ne 'Prepare' -and -not $_.Scheduled}).Count -eq 0 -and $events[1].Mode -eq 'Daily') 'scheduled and daily mode reach synthetic native launcher'

    foreach($failure in @('Throw','InvalidJson','WrongDate','NonzeroRequests')) {
        $case=New-Case ('prepare-'+$failure)
        $case.Control.PreparationMode=$failure
        $result=Invoke-Fixture $case @{Scheduled=$true}
        $events=@(Trace $case)
        Assert-Preparation ($result.Bilibili.BrowserPreparation.Status -eq 'LocalPreparationFailed' -and @($events|Where-Object {$_.Stage -eq 'bilibili'}).Count -eq 0 -and @($events|Where-Object {$_.Stage -eq 'heybox'}).Count -eq 1) ($failure+' preparation failure cannot block Heybox or start native')
        Assert-Preparation ($result.Bilibili.NativeSuccessCoins -eq 0 -and $result.Heybox.ActionsSubmittedThisInvocation -eq 4) ($failure+' preparation failure is local-only')
    }

    $repeat=New-Case 'repeat'
    $null=Invoke-Fixture $repeat @{Scheduled=$true}
    $repeat.Control.Now='2030-01-02T20:16:00'
    $repeat.Control.Preparation='SkipCompleted'
    $repeat.Control.HeyboxBehavior='SkipCompleted'
    $result=Invoke-Fixture $repeat @{Scheduled=$true}
    $events=@(Trace $repeat)
    Assert-Preparation (@($events|Where-Object {$_.Stage -eq 'bilibili'}).Count -eq 1 -and @($events|Where-Object {$_.Stage -eq 'heybox' -and $_.Submitted}).Count -eq 1) 'completed second invocation does not repeat synthetic submissions'
    Assert-Preparation ($result.Bilibili.NativeSuccessCoins -eq 0 -and $result.Heybox.ActionsSubmittedThisInvocation -eq 0 -and $result.Bilibili.TodayCoins -eq 5) 'completed second invocation has zero new actions and retains daily total'
    Assert-Preparation ($result.Bilibili.SummaryObservedAt -eq '2030-01-02T20:15:00' -and $result.Bilibili.ReusedForThisInvocation) 'completed local skip retains previous real observation time'

    $empty=New-Case 'empty-report'
    $empty.Control.BilibiliBehavior='NoReport';$empty.Control.HeyboxBehavior='NoReport'
    $result=Invoke-Fixture $empty @{Scheduled=$true}
    Assert-Preparation ($result.Bilibili.Status -eq 'Unconfirmed' -and $result.Heybox.Status -eq 'Unconfirmed' -and $null -eq (Property $result.Bilibili 'NativeSuccessCoins') -and $null -eq (Property $result.Heybox 'ActionsSubmittedThisInvocation')) 'successful launcher without module report cannot establish actions'
    $missing=New-Case 'stale-report'
    $null=Invoke-Fixture $missing @{Scheduled=$true}
    $missing.Control.Now='2030-01-02T20:16:00'
    $missing.Control.BilibiliBehavior='NoReport';$missing.Control.HeyboxBehavior='Failure'
    $result=Invoke-Fixture $missing @{Scheduled=$true}
    Assert-Preparation ($null -eq $result.Bilibili.NativeSuccessCoins -and $null -eq $result.Heybox.ActionsSubmittedThisInvocation -and $result.Bilibili.ReusedForThisInvocation -and $result.Heybox.ReusedForThisInvocation) 'missing and failed reports leave effects unknown instead of reusing previous success counts'
    Assert-Preparation ($result.Bilibili.SummaryObservedAt -eq '2030-01-02T20:15:00' -and $result.Heybox.SummaryObservedAt -eq '2030-01-02T20:15:00') 'missing and failed reports do not advance confirmation time'

    $biliId=('a'*32);$heyboxId='synthetic-recovery-1'
    $recovery=New-Case 'recovery'
    $result=Invoke-Fixture $recovery @{Scheduled=$true;BilibiliRecoveryId=$biliId;HeyboxRecoveryId=$heyboxId}
    $events=@(Trace $recovery)
    Assert-Preparation ($events[0].RecoveryId -eq $biliId -and $events[1].RecoveryId -eq $biliId -and $events[2].RecoveryId -eq $heyboxId) 'separate recovery IDs reach only their intended platform'
    $readOnly=New-Case 'readonly-recovery' 'ReadyForReadOnly'
    $null=Invoke-Fixture $readOnly @{Scheduled=$true;BilibiliRecoveryId=$biliId}
    Assert-Preparation (@(Trace $readOnly|Where-Object {$_.Stage -eq 'bilibili' -and $_.RecoveryId -eq $biliId}).Count -eq 1) 'validated read-only readiness reaches native with its recovery ID'
    Assert-Rejected (New-Case 'manual-recovery') @{BilibiliRecoveryId=$biliId} 'require Scheduled' 'manual recovery rejected'
    Assert-Rejected (New-Case 'reportonly-recovery') @{Scheduled=$true;ReportOnly=$true;HeyboxRecoveryId=$heyboxId} 'require Scheduled' 'report-only recovery rejected'
    Assert-Rejected (New-Case 'invalid-bili-id') @{Scheduled=$true;BilibiliRecoveryId='invalid'} 'BilibiliRecoveryId' 'invalid Bilibili recovery ID rejected'
    Assert-Rejected (New-Case 'invalid-heybox-id') @{Scheduled=$true;HeyboxRecoveryId='../invalid'} 'HeyboxRecoveryId' 'invalid Heybox recovery ID rejected'
    $disabled=New-Case 'disabled-recovery'
    $disabled.Settings.bilibili.enabled=$false
    $disabled.Settings|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $disabled.Config -Encoding UTF8
    Assert-Rejected $disabled @{Scheduled=$true;BilibiliRecoveryId=$biliId} 'disabled module' 'recovery cannot target a disabled module'

    $reportOnly=New-Case 'report-only'
    $result=Invoke-Fixture $reportOnly @{ReportOnly=$true}
    Assert-Preparation (@(Trace $reportOnly).Count -eq 0 -and @($result.Launches).Count -eq 0) 'report-only executes neither preparation nor platform launchers'
    Assert-Preparation ($result.Bilibili.NativeSuccessCoins -eq 0 -and $result.Heybox.ActionsSubmittedThisInvocation -eq 0) 'report-only empty modules report zero new submissions'
    $before=New-Case 'before-schedule'
    $before.Control.Now='2030-01-02T19:59:59'
    $result=Invoke-Fixture $before @{Scheduled=$true}
    Assert-Preparation ($null -eq $result -and @(Trace $before).Count -eq 0) 'scheduled execution before 20:00 starts no module'
    $result=Invoke-Fixture $before @{Scheduled=$true;ReportOnly=$true}
    Assert-Preparation ($null -ne $result -and @(Trace $before).Count -eq 0) 'report-only remains available before schedule without launching modules'
    Write-Output ("Coordinator preparation checks: $checks passed; temporary synthetic launchers only; controlled fixture clock UTC+08.")
} finally {
    $target=[IO.Path]::GetFullPath($fixture)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $target.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^local-daily-coordinator-fixture-[a-f0-9]{32}$'){throw 'Unexpected coordinator fixture cleanup target'}
    Remove-Item -LiteralPath $target -Recurse -Force
}
