[CmdletBinding()]
param(
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'),
    [string]$NativeBuildDirectory,
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\bilibili\Policy.ps1')
if($env:OS -ne 'Windows_NT'){throw 'WindowsRequired'}
$arch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if($arch -cne 'x64'){throw 'PatchedNativeBuildRequiresWindowsX64'}
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$projectFull=[IO.Path]::GetFullPath($projectRoot).TrimEnd('\')+'\'
if(($root.TrimEnd('\')+'\').StartsWith($projectFull,[StringComparison]::OrdinalIgnoreCase)){throw '运行状态必须保存在仓库外部，避免将凭据提交到 Git。'}
if($root.TrimEnd('\') -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')){throw 'StateRootCannotBeDriveRoot'}
$metadata=Get-Content -LiteralPath (Join-Path $projectRoot 'src\bilibili\patches\upstream.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if((Get-FileHash -LiteralPath (Join-Path $projectRoot ('src\bilibili\patches\'+$metadata.Patch)) -Algorithm SHA256).Hash -ine $metadata.PatchSHA256){throw 'NativePatchHashMismatch'}
if((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count -gt 0){throw 'StateRoot 必须是专用空目录；现有文件和权限不会被修改。'}
if(-not $NativeBuildDirectory){throw '先在仓库外使用 Build-BilibiliNative.ps1 构建，再传入 -NativeBuildDirectory；不会下载未经修复的旧程序。'}
$build=[IO.Path]::GetFullPath($NativeBuildDirectory)
$buildManifestPath=Join-Path $build 'native-build.json'
$buildManifest=Get-Content -LiteralPath $buildManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if($buildManifest.Status -cne 'BuiltAndOfflineTested' -or $buildManifest.UpstreamCommit -cne $metadata.Commit -or $buildManifest.PatchSHA256 -ine $metadata.PatchSHA256 -or $buildManifest.NativeVersion -cne $metadata.NativeVersion -or $buildManifest.Runtime -cne 'win-x64' -or $buildManifest.SelfContained -cne $true -or $buildManifest.TestsPassed -lt 1 -or $buildManifest.TestsFailed -ne 0 -or $buildManifest.PlatformTasksRun -cne $false){throw 'NativeBuildEvidenceMismatch'}
$seen=@{}
foreach($entry in @($buildManifest.Files)){
    if($entry.File -match '(^[\\/]|:|\.\.)' -or $seen.ContainsKey([string]$entry.File) -or $entry.SHA256 -cnotmatch '^[A-Fa-f0-9]{64}$'){throw 'NativeBuildFileInvalid'}
    $seen[[string]$entry.File]=$true
    if((Get-FileHash -LiteralPath (Join-Path (Join-Path $build 'app') $entry.File) -Algorithm SHA256).Hash -ine $entry.SHA256){throw 'NativeBuildHashMismatch'}
}
if(-not $seen.ContainsKey('Ray.BiliBiliTool.Console.exe')){throw 'NativeBuildExecutableMissing'}
$native=Join-Path $build 'app\Ray.BiliBiliTool.Console.exe'
if((Get-Item -LiteralPath $native).VersionInfo.ProductVersion -cne ($metadata.NativeVersion+'+'+$metadata.Commit)){throw 'NativeBuildVersionMismatch'}
if($PlanOnly){[pscustomobject]@{Version=$metadata.NativeVersion;Architecture=$arch;StateRoot=$root;BuildEvidence='Verified';InstallsTask=$false;RunsPlatform=$false};return}
if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')){throw '请用普通 Windows 用户运行安装程序，不需要管理员权限。'}
if(Get-Command pwsh.exe -ErrorAction SilentlyContinue){$null=& pwsh.exe -NoProfile -Command 'if($PSVersionTable.PSVersion.Major -lt 7){exit 1}';if($LASTEXITCODE -ne 0){throw 'PowerShell7Required'}}else{throw '需要先安装 Microsoft PowerShell 7，本脚本不会静默安装系统依赖。'}
$null=New-Item -ItemType Directory -Path $root -Force
Protect-BilibiliState -Path $root
$app=Join-Path $root 'app';$null=New-Item -ItemType Directory -Path $app
Copy-Item -LiteralPath $native -Destination (Join-Path $app 'Ray.BiliBiliTool.Console.exe')
$runtimeFiles=@('Launch.ps1','Run.ps1','DailyRun.ps1','Daily.Common.ps1','DailyDecision.ps1','Recovery.Common.ps1','BrowserShare.ps1','BrowserShare.Common.ps1','Experience.ps1','CoinDetails.ps1','Forecast.ps1','Policy.ps1','Report.ps1','ShowQr.ps1','Bind-BrowserProfile.ps1')
foreach($file in $runtimeFiles){Copy-Item -LiteralPath (Join-Path $projectRoot ('src\bilibili\'+$file)) -Destination (Join-Path $root $file)}
$config=Get-Content -LiteralPath (Join-Path $projectRoot 'src\bilibili\appsettings.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-BilibiliConfig -Config $config
$config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $app 'appsettings.json') -Encoding UTF8
'{}' | Set-Content -LiteralPath (Join-Path $app 'appsettings.Production.json') -Encoding UTF8
$files=@(@($runtimeFiles)+@('app\Ray.BiliBiliTool.Console.exe') | ForEach-Object {[ordered]@{File=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash}})
$manifest=[ordered]@{Version=($metadata.NativeVersion+'-browserproof1');NativeVersion=$metadata.NativeVersion;CoinJournalProtocol='CoinIntentV1';UpstreamCommit=$metadata.Commit;PatchSHA256=$metadata.PatchSHA256;NativeBuildManifestSHA256=(Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash;BrowserProfileLinkSHA256=$null;InstalledAt=[datetimeoffset]::Now.ToString('o');Files=$files}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'daily-runtime-manifest.json') -Encoding UTF8
[ordered]@{Version=$metadata.NativeVersion;Architecture=$arch;SourceRepository=$metadata.Repository;UpstreamCommit=$metadata.Commit;ChecksumVerification='LocallyBuiltOutputVerified';License='GPL-3.0-only';InstalledAt=$manifest.InstalledAt;PlatformTasksRun=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'install.json') -Encoding UTF8
Write-Host ('已安装经离线测试的修复源码构建到 '+$root+'。尚未登录、绑定浏览器账户、执行平台任务或创建调度。')