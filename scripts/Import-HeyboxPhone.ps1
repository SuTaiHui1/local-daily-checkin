param(
  [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\heybox'),
  [string]$AdbPath='adb.exe'
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$state=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$python=Join-Path $state 'venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $python)){throw 'Install the compatible private resources first; no phone data was read.'}
if((([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Use an ordinary Windows session.'}
$oldAdb=$env:HEYBOX_ADB
try {
  $env:HEYBOX_ADB=(Get-Command $AdbPath -ErrorAction Stop).Source
  # Uses only its own port 5039; no kill-server, driver or USB setting changes.
  & $python (Join-Path $repo 'src\heybox\ImportPhone.py') --state-root $state --read
  if($LASTEXITCODE -ne 0){throw 'Phone import stopped. Check USB authorization and logged-in compatible official App; no bypass or automatic retry.'}
} finally { $env:HEYBOX_ADB=$oldAdb }
