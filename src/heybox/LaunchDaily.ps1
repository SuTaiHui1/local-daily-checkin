param(
  [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\heybox'),
  [switch]$Scheduled,
  [switch]$Status
)
$ErrorActionPreference='Stop'
if((([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){
  Write-Output '{"Status":"RefusedElevatedExecution","NetworkRequests":0}'
  exit 5
}
$state=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$python=Join-Path $state 'venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $python)){
  Write-Output '{"Status":"NotInstalled","NetworkRequests":0}'
  exit 6
}
$arguments=@((Join-Path $PSScriptRoot 'RunDaily.py'),'--state-root',$state)
if($Status){$arguments+='--status'}elseif($Scheduled){$arguments+='--scheduled'}else{$arguments+='--run'}
& $python @arguments
exit $LASTEXITCODE
