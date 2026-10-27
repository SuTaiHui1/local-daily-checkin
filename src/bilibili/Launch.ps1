param([Parameter(Mandatory=$true)][string]$StateRoot,[ValidateSet('Daily','Login','Menu','Status')][string]$Mode='Menu',[switch]$Scheduled,[ValidatePattern('^(?:[a-f0-9]{32})?$')][string]$RecoveryId='')
$ErrorActionPreference='Stop'
$StateRoot=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
if($StateRoot.Contains([char]34)){throw 'InvalidStatePath'}
if(-not(Test-Path -LiteralPath $StateRoot)){throw 'StateRootNotInstalled'}
try {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LocalLimitedLauncher {
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
  public static int Run(string exe,string command,string cwd,bool hidden) {
    IntPtr level=IntPtr.Zero,token=IntPtr.Zero; PI pi=new PI();
    try {
      if(!SaferCreateLevel(1,0x20000,1,out level,IntPtr.Zero))throw new System.ComponentModel.Win32Exception();
      if(!SaferComputeTokenFromLevel(level,IntPtr.Zero,out token,0,IntPtr.Zero))throw new System.ComponentModel.Win32Exception();
      SI si=new SI(); si.cb=Marshal.SizeOf(typeof(SI)); si.desktop="winsta0\\default"; if(hidden){si.flags=1;si.show=0;}
      if(!CreateProcessAsUser(token,exe,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x00000010u,IntPtr.Zero,cwd,ref si,out pi))throw new System.ComponentModel.Win32Exception();
      WaitForSingleObject(pi.process,0xffffffff); uint code; GetExitCodeProcess(pi.process,out code); return (int)code;
    } finally { if(pi.thread!=IntPtr.Zero)CloseHandle(pi.thread); if(pi.process!=IntPtr.Zero)CloseHandle(pi.process); if(token!=IntPtr.Zero)CloseHandle(token); if(level!=IntPtr.Zero)SaferCloseLevel(level); }
  }
}
'@
  $exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $command='"'+$exe+'" -NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "'+(Join-Path $StateRoot 'Run.ps1')+'" -StateRoot "'+$StateRoot+'" -Mode '+$Mode
  if($Scheduled){$command+=' -Scheduled'}
  if($RecoveryId){if($Mode -ne 'Daily' -or -not $Scheduled){throw 'RecoveryOnlyForScheduledDaily'};$command+=' -RecoveryId '+$RecoveryId}
  exit [LocalLimitedLauncher]::Run($exe,$command,$PSScriptRoot,($Mode -ne 'Menu'))
} catch {
  '本机普通权限启动失败，未请求平台。' | Set-Content -LiteralPath (Join-Path $StateRoot 'boot-error.txt') -Encoding UTF8
  exit 5
}
