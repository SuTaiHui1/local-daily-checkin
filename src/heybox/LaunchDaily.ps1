param(
  [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\heybox'),
  [switch]$Scheduled,
  [switch]$Status,
  [string]$RecoveryId
)
$ErrorActionPreference='Stop'
$state=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot)).TrimEnd('\')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
if($state -eq $repository -or $state.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)){
  throw 'Heybox state must be outside the repository'
}
if($RecoveryId -and (-not $Scheduled -or $Status -or $RecoveryId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')){
  throw 'RecoveryId requires Scheduled task execution'
}
$taskPython=Join-Path $state 'venv\Scripts\python.exe'
if(-not (Test-Path -LiteralPath $taskPython)){
  Write-Output '{"Status":"NotInstalled","NetworkRequests":0}'
  exit 6
}
$taskRunner=Join-Path $PSScriptRoot 'RunDaily.py'
if($Status){
  # Local record reads keep their JSON visible; no native signer or App request.
  & $taskPython $taskRunner --state-root $state --status
  exit $LASTEXITCODE
}
try {
  if(-not ('HeyboxLimitedLauncher' -as [type])){ Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HeyboxLimitedLauncher {
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct SI {
    public int cb; public string reserved; public string desktop; public string title;
    public int x,y,xsize,ysize,xchars,ychars,fill,flags; public short show,reserved2;
    public IntPtr reservedPtr,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process,thread; public uint processId,threadId; }
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool SaferCreateLevel(uint scope,uint level,uint flags,out IntPtr handle,IntPtr reserved);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool SaferComputeTokenFromLevel(IntPtr level,IntPtr input,out IntPtr token,uint flags,IntPtr reserved);
  [DllImport("advapi32.dll")] static extern bool SaferCloseLevel(IntPtr level);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessAsUser(IntPtr token,string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref SI si,out PI pi);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static int Run(string exe,string command,string cwd) {
    IntPtr level=IntPtr.Zero,token=IntPtr.Zero; PI pi=new PI();
    try {
      if(!SaferCreateLevel(1,0x20000,1,out level,IntPtr.Zero))throw new System.ComponentModel.Win32Exception();
      if(!SaferComputeTokenFromLevel(level,IntPtr.Zero,out token,0,IntPtr.Zero))throw new System.ComponentModel.Win32Exception();
      SI si=new SI();si.cb=Marshal.SizeOf(typeof(SI));si.desktop="winsta0\\default";si.flags=1;si.show=0;
      if(!CreateProcessAsUser(token,exe,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x00000010u,IntPtr.Zero,cwd,ref si,out pi))throw new System.ComponentModel.Win32Exception();
      WaitForSingleObject(pi.process,0xffffffff);uint code;GetExitCodeProcess(pi.process,out code);return (int)code;
    } finally { if(pi.thread!=IntPtr.Zero)CloseHandle(pi.thread);if(pi.process!=IntPtr.Zero)CloseHandle(pi.process);if(token!=IntPtr.Zero)CloseHandle(token);if(level!=IntPtr.Zero)SaferCloseLevel(level); }
  }
}
'@
  }
  $taskFlag=if($Scheduled){'--scheduled'}else{'--run'}
  if($RecoveryId){
    $taskFlag+=' --recovery-id "'+$RecoveryId+'"'
  }
  $taskCommand='"'+$taskPython+'" "'+$taskRunner+'" --state-root "'+$state+'" '+$taskFlag
  exit [HeyboxLimitedLauncher]::Run($taskPython,$taskCommand,$state)
} catch {
  # No child stderr, request URLs, credentials, or arbitrary exception message.
  'Ordinary-user launch failed; current attempt stopped. Diagnose launch permissions before recovery.' | Set-Content -LiteralPath (Join-Path $state 'launch-error.txt') -Encoding UTF8
  exit 5
}
