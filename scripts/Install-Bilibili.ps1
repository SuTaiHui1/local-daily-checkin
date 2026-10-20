[CmdletBinding()]
param(
    [string]$StateRoot=(Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\bilibili'),
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='4.2.1',
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\bilibili\Policy.ps1')
if($env:OS -ne 'Windows_NT'){throw 'WindowsRequired'}
$arch=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if($arch -notin @('x64','x86','arm64')){throw 'UnsupportedWindowsArchitecture'}
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
$projectFull=[IO.Path]::GetFullPath($projectRoot).TrimEnd('\')+'\'
if(($root.TrimEnd('\')+'\').StartsWith($projectFull,[StringComparison]::OrdinalIgnoreCase)){throw '运行状态必须保存在仓库外部，避免将凭据提交到 Git。'}
if($root.TrimEnd('\') -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')){throw 'StateRootCannotBeDriveRoot'}
$app=Join-Path $root 'app'
$assetName="bilibili-tool-pro-v$Version-win-$arch.zip"
if($PlanOnly){[pscustomobject]@{Version=$Version;Architecture=$arch;StateRoot=$root;Asset=$assetName;InstallsTask=$false;RunsPlatform=$false};return}
if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')){throw '请用普通 Windows 用户运行安装程序，不需要管理员权限。'}
if(Test-Path -LiteralPath $app){throw '已有安装未被修改。请在新的 StateRoot 安装，或自行备份后升级；不会覆盖已有登录凭据。'}
if((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count -gt 0){throw 'StateRoot 必须是专用空目录；现有文件和权限不会被修改。'}
if(Get-Command pwsh.exe -ErrorAction SilentlyContinue){$null=& pwsh.exe -NoProfile -Command 'if($PSVersionTable.PSVersion.Major -lt 7){exit 1}';if($LASTEXITCODE -ne 0){throw 'PowerShell7Required'}}else{throw '需要先安装 Microsoft PowerShell 7（只读经验汇总使用），本脚本不会静默安装系统依赖。'}
New-Item -ItemType Directory -Path $root -Force | Out-Null
Protect-BilibiliState -Path $root
$releaseUri="https://api.github.com/repos/RayWangQvQ/BiliBiliToolPro/releases/tags/$Version"
$release=Invoke-RestMethod -Uri $releaseUri -Headers @{'User-Agent'='LocalDailyCheckin';Accept='application/vnd.github+json'}
if($release.draft -or $release.prerelease -or $release.tag_name -cne $Version){throw 'StableReleaseRequired'}
$assets=@($release.assets | Where-Object {$_.name -ceq $assetName})
if($assets.Count -ne 1){throw 'MatchingOfficialAssetNotFound'}
$asset=$assets[0]
if($asset.browser_download_url -notlike 'https://github.com/RayWangQvQ/BiliBiliToolPro/releases/download/*'){throw 'UnexpectedDownloadOrigin'}
$downloadRoot=Join-Path $root 'downloads'
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$zip=Join-Path $downloadRoot $assetName
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
    if($hash -ne $Matches[1].ToLowerInvariant()){throw 'PublisherChecksumMismatch'}
    $verification='PublisherSha256Verified'
} else {
    # Pinned stable release hashes are publisher-provided GitHub release asset digests.
    $pinned=@{
        '4.2.1-win-x64'='ae8eb59c788515243fe68369cbb1a5038f63be738b74f296b247dd3d9902fc02'
        '4.2.1-win-arm64'='9938a38e46d6743569883db1c1d48e1d3862ea9a4d7563629b6d93b645cde260'
        '4.2.1-win-x86'='518d1db67ec028297f4e0297468a722b7237fac081b0e37b142ac555d544c718'
    }
    $expected=$pinned["$Version-win-$arch"]
    if($expected){if($hash -ne $expected){throw 'PublisherChecksumMismatch'};$verification='PinnedPublisherSha256Verified'}
    else{throw '发布方没有可用 SHA256，未解压或运行。请核对发布渠道后再适配该版本，不能把本地哈希称为发布方校验。'}
}
$staging=Join-Path $root ('staging-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $staging
$executables=@(Get-ChildItem -LiteralPath $staging -Recurse -File -Filter 'Ray.BiliBiliTool.Console.exe')
if($executables.Count -ne 1){throw 'UnexpectedOfficialArchiveLayout'}
$payload=$executables[0].Directory.FullName
New-Item -ItemType Directory -Path $app | Out-Null
Get-ChildItem -LiteralPath $payload -Force | Copy-Item -Destination $app -Recurse
# The official default config enables more tasks/sinks. Replace only the newly installed template.
Get-ChildItem -LiteralPath $app -Filter 'appsettings*.json' -File | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
$config=Get-Content -LiteralPath (Join-Path $projectRoot 'src\bilibili\appsettings.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-BilibiliConfig -Config $config
$config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $app 'appsettings.json') -Encoding UTF8
'{}' | Set-Content -LiteralPath (Join-Path $app 'appsettings.Production.json') -Encoding UTF8
[ordered]@{Version=$Version;Architecture=$arch;Source=$asset.browser_download_url;Sha256=$hash;ChecksumVerification=$verification;InstalledAt=(Get-Date).ToString('o');License='GPL-3.0';SourceRepository='https://github.com/RayWangQvQ/BiliBiliToolPro'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'install.json') -Encoding UTF8
# Keep extracted package for diagnostics. No program execution, login or schedule occurs here.
Write-Host ('已安装官方 BiliBiliToolPro '+$Version+' 到 '+$app+'；SHA256 已核对。下一步用 Launch.ps1 -Mode Login 扫码。')
