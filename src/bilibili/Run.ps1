param([Parameter(Mandatory=$true)][string]$StateRoot,[ValidateSet('Daily','Login','Menu','Status')][string]$Mode='Menu',[switch]$Scheduled,[ValidatePattern('^(?:[a-f0-9]{32})?$')][string]$RecoveryId='')
$ErrorActionPreference='Stop'
if($Mode -eq 'Daily'){ & (Join-Path $StateRoot 'DailyRun.ps1') -Scheduled:$Scheduled -RecoveryId $RecoveryId; exit $LASTEXITCODE }
. (Join-Path $PSScriptRoot 'Policy.ps1')
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$app=Join-Path $root 'app'
$pauseFile=Join-Path $root 'daily-paused.txt'
$logDir=Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
if($Mode -eq 'Status'){ & (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $root; return }
$action='NotStarted'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Please launch through Launch.ps1 or the desktop entry. Administrator execution is disabled.' }
if($Mode -eq 'Daily' -and (Test-Path -LiteralPath $pauseFile)) {
  Write-Host '每日任务已暂停，本次未启动工具，也未请求 B站。'
  & (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $root -Action 'Paused'
  exit 6
}
if($Mode -eq 'Menu') {
  while($true) {
    Clear-Host
    Write-Host 'B站每日任务 — 本机运行' -ForegroundColor Cyan
    $isPaused=Test-Path -LiteralPath $pauseFile
    $executionState=if($isPaused){'本机执行已暂停'}else{'本机允许执行'}
    Write-Host ('本机任务：'+$executionState)
    Write-Host '需要电脑开机联网、Windows 用户保持登录、Codex 保持运行。定时任务启用状态和下次时间请在 Codex“定时任务”中查看。'
    if($isPaused){Get-Content -LiteralPath $pauseFile | Write-Host}
    Get-Content -LiteralPath (Join-Path $root 'status.txt') -ErrorAction SilentlyContinue | Write-Host
    Write-Host "`n1 查看最近结果   2 重新扫码登录   3 暂停/恢复本机执行   4 立即运行   0 退出"
    switch(Read-Host '选择') {
      '1' { $latest=Get-ChildItem -LiteralPath $logDir -Filter 'Daily-*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if($latest){Get-Content -LiteralPath $latest.FullName | Write-Host}; Read-Host '回车返回' | Out-Null }
      '2' { & (Join-Path $PSScriptRoot 'Launch.ps1') -StateRoot $root -Mode Login; Read-Host '回车返回' | Out-Null }
      '3' { if($isPaused){Write-Host '暂停记录保留。请先查因并按恢复契约归档，再创建新的 RecoveryId；此菜单不清除故障证据。'}else{'用户从桌面入口暂停了本机执行。' | Set-Content -LiteralPath $pauseFile -Encoding UTF8; Write-Host '本机执行已暂停；Codex 唤起时也会跳过。'}; Write-Host '遇到验证码或 -352 时请先处理原因，再恢复；正在执行的实例会继续到结束。'; Read-Host '回车返回' | Out-Null }
      '4' { & (Join-Path $PSScriptRoot 'Launch.ps1') -StateRoot $root -Mode Daily -Scheduled; Read-Host '回车返回' | Out-Null }
      '0' { return }
    }
  }
}
$mutex=New-Object Threading.Mutex($false,'Local\LocalDailyCheckin-Bilibili')
if(-not $mutex.WaitOne(0)) { Write-Host '已有登录或每日任务正在运行，本次跳过。'; $mutex.Dispose(); return }
$process=$null
$qrRows=New-Object 'Collections.Generic.List[string]'
$qrShown=$false
$logFile=Join-Path $logDir ($Mode+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt')
$loginDone=Join-Path $root 'login.done'
try {
  if($Mode -eq 'Daily') {
    . (Join-Path $PSScriptRoot 'DailyDecision.ps1')
    $summary=$null
    $summaryPath=Join-Path $logDir ('Experience-'+(Get-Date -Format 'yyyyMMdd')+'.json')
    if(Test-Path -LiteralPath $summaryPath) {
      try {$summary=Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json} catch {}
    }
    $config=Get-Content -LiteralPath (Join-Path $app 'appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-BilibiliConfig -Config $config
    $decision=Get-DailyRunDecision -Now (Get-Date) -Scheduled:$Scheduled -Summary $summary -DailyConfig $config.DailyTaskConfig
    while($decision.Action -eq 'WaitUntil20') {
      Start-Sleep -Seconds ([Math]::Min(60,$decision.WaitSeconds))
      $decision=Get-DailyRunDecision -Now (Get-Date) -Scheduled:$Scheduled -Summary $summary -DailyConfig $config.DailyTaskConfig
    }
    if($decision.Action -eq 'SkipCompleted') {
        $action='SkipCompleted'
        $notice='今日登录、观看、分享及投币目标已完成，本次未启动工具、未请求 B站、未重复投币。结果记录：'+$summary.DailyRunLog
        $notice | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
        Write-Host $notice
        return
    }
    if($decision.Action -eq 'SkipBeforeTodaySchedule') {
      $action='SkipBeforeTodaySchedule'
      $notice='当前未到当天20:00，已跳过旧日期的补做触发；不补历史任务，未启动工具、未请求 B站。'
      $notice | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
      Write-Host $notice
      return
    }
  }
  if($Mode -eq 'Daily' -and -not(Test-Path -LiteralPath (Join-Path $app 'cookies.json'))) { '等待扫码登录；请使用 Launch.ps1 -Mode Login，处理后从 Menu 恢复本机执行。' | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8; '缺少本机登录凭证，等待扫码。' | Set-Content -LiteralPath $pauseFile -Encoding UTF8; $action='Paused'; exit 2 }
  if($Mode -eq 'Login') {
    $config=Get-Content -LiteralPath (Join-Path $app 'appsettings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-BilibiliConfig -Config $config
    Remove-Item -LiteralPath $loginDone -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath (Join-Path $app 'cookies.json')) { New-Item -ItemType Directory -Path (Join-Path $root 'Backups') -Force | Out-Null; Copy-Item -LiteralPath (Join-Path $app 'cookies.json') -Destination (Join-Path $root ('Backups\cookies-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')) }
  }
  if((Get-Content -LiteralPath (Join-Path $app 'appsettings.Production.json') -Raw).Trim() -ne '{}'){throw 'UnexpectedProductionOverride'}
  ('执行中：'+$Mode+'；开始于 '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=Join-Path $app 'Ray.BiliBiliTool.Console.exe'
  $start.Arguments='--runTasks='+$Mode
  $start.WorkingDirectory=$app
  $start.UseShellExecute=$false
  $start.CreateNoWindow=$false
  $start.RedirectStandardOutput=$true
  $start.RedirectStandardError=$true
  $start.StandardOutputEncoding=[Text.Encoding]::UTF8
  $start.StandardErrorEncoding=[Text.Encoding]::UTF8
  # Upstream reads all environment configuration. Remove overrides in the child only.
  foreach($key in @($start.EnvironmentVariables.Keys)) {
    if($key -match '^(?i)(Ray_|RunTasks$|DailyTaskConfig|MangaTaskConfig|MangaPrivilegeTaskConfig|Silver2CoinTaskConfig|ChargeTaskConfig|VipPrivilegeConfig|VipBigPointConfig|LiveLotteryTaskConfig|LiveFansMedalTaskConfig|UnfollowBatchedTaskConfig|Security|Serilog|BiliBiliCookies|QingLongConfig|DOTNET_ENVIRONMENT)'){$start.EnvironmentVariables.Remove($key)}
  }
  $start.EnvironmentVariables['DOTNET_ENVIRONMENT']='Production'
  $action='RanToday'
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$start
  $null=$process.Start()
  $err=$process.StandardError.ReadToEndAsync()
  $pending=$process.StandardOutput.ReadLineAsync()
  $stopped=$false
  while($true) {
    if(-not $pending.IsCompleted) { Start-Sleep -Milliseconds 100; continue }
    $line=$pending.Result
    if($null -eq $line) { break }
    $plain=$line -replace '^\[\d\d:\d\d:\d\d\s+\w+\]\s?',''
    if($Mode -eq 'Login' -and $plain -match '^[ █▄▀]+$' -and $plain -match '[█▄▀]') { $qrRows.Add($plain) }
    elseif($Mode -eq 'Login' -and $qrRows.Count -gt 5 -and -not $qrShown) {
      Add-Type -AssemblyName System.Drawing
      $scale=9; $width=($qrRows | ForEach-Object Length | Measure-Object -Maximum).Maximum
      $bmp=[Drawing.Bitmap]::new([int](($width+8)*$scale),[int]((2*$qrRows.Count+8)*$scale))
      $g=[Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
      for($y=0;$y -lt $qrRows.Count;$y++) { for($x=0;$x -lt $qrRows[$y].Length;$x++) {
        $ch=$qrRows[$y][$x]
        if($ch -eq ' ' -or $ch -eq '▄'){$g.FillRectangle([Drawing.Brushes]::Black,($x+4)*$scale,($y*2+4)*$scale,$scale,$scale)}
        if($ch -eq ' ' -or $ch -eq '▀'){$g.FillRectangle([Drawing.Brushes]::Black,($x+4)*$scale,($y*2+5)*$scale,$scale,$scale)}
      }}
      $bmp.Save((Join-Path $root 'login-qr.png'),[Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
      Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -STA -File "'+(Join-Path $PSScriptRoot 'ShowQr.ps1')+'" -StateRoot "'+$root+'"') -WindowStyle Normal
      $qrShown=$true
      '等待扫码：请用哔哩哔哩 App 扫描电脑上的二维码并确认。' | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
    }
    $safeLine=ConvertTo-SafeBilibiliLogLine -Line $line
    if($null -ne $safeLine) { Add-Content -LiteralPath $logFile -Value $safeLine -Encoding UTF8 }
    $isGaia352 = $line -match '(?<!\d)-352(?!\d)'
    if(Test-BilibiliRiskLine -Line $line) {
      $process.Kill(); $stopped=$true; $action='Paused'; ('RiskControlStopped; Code='+$(if($isGaia352){'-352'}else{'Unconfirmed'})) | Add-Content -LiteralPath $logFile -Encoding UTF8
      '工具报告风控、验证码或登录失效，已停止后续每日执行。处理完成前请保持暂停。' | Set-Content -LiteralPath $pauseFile -Encoding UTF8
      $notice='遇到阻塞：已停止运行并暂停后续本机执行。若明确提示登录失效，选 2 重新扫码；若有验证码，按官方页面提示处理。'
      if($isGaia352) { $notice='遇到阻塞：工具请求被 B站接口以 -352 拒绝，已停止运行并暂停后续本机执行。不能据此认定账号受限，也不能保证手机验证能解决；请保持暂停，排查工具接口原因。' }
      $notice | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
      break
    }
    $pending=$process.StandardOutput.ReadLineAsync()
  }
  $process.WaitForExit()
  if($Mode -eq 'Daily' -and (Test-Path -LiteralPath $logFile)) {
    . (Join-Path $PSScriptRoot 'CoinDetails.ps1')
    New-CoinDonationReport -DailyLog $logFile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logDir ('CoinDetails-'+[IO.Path]::GetFileNameWithoutExtension($logFile)+'.json')) -Encoding UTF8
  }
  if($Mode -eq 'Daily' -and -not $stopped -and (Select-String -LiteralPath $logFile -Pattern 'FlowCompleted DailyTask' -Quiet)) {
    & (Get-Command pwsh.exe -ErrorAction Stop).Source -NoProfile -File (Join-Path $PSScriptRoot 'Experience.ps1') -StateRoot $root -DailyLog $logFile
  }
  if(-not $stopped) { ('运行结束：'+$Mode+'；时间 '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'；请查看基础结果记录，退出码不代表各任务成功。') | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8 }
  if($Mode -eq 'Login') { 'done' | Set-Content -LiteralPath $loginDone -Encoding UTF8 }
  if($err.Result) { '程序有错误输出；未保存可能包含凭证的原始内容。' | Add-Content -LiteralPath $logFile -Encoding UTF8 }
  if($stopped){exit 3}
  exit $process.ExitCode
} catch {
  $action='FailedLocalRun'
  '启动或本机运行失败；原始异常未输出。' | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8
  if($process -and -not $process.HasExited){$process.Kill()}
  if($Mode -eq 'Login'){'done' | Set-Content -LiteralPath $loginDone -Encoding UTF8}
  exit 4
} finally {
  try {
    if($Mode -eq 'Daily'){ & (Join-Path $PSScriptRoot 'Report.ps1') -StateRoot $root -Action $action -DailyLog $logFile }
  } catch { '本地日报生成失败；未重跑平台任务。' | Set-Content -LiteralPath (Join-Path $root 'status.txt') -Encoding UTF8 }
  finally { $mutex.ReleaseMutex(); $mutex.Dispose(); if($process){$process.Dispose()} }
}
