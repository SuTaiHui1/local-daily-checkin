[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$StateRoot,[Parameter(Mandatory=$true)][string]$ProfileUrl,[switch]$AccountMatchConfirmed)
$ErrorActionPreference='Stop'
if(-not $AccountMatchConfirmed){throw '请先实际核对原生登录与官方浏览器页面为同一账户，再传入 AccountMatchConfirmed。'}
$root=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
if($ProfileUrl -cnotmatch '^https://space\.bilibili\.com/[1-9][0-9]*/?$'){throw 'OfficialPersonalSpaceUrlRequired'}
. (Join-Path $root 'BrowserShare.Common.ps1')
if(-not(Test-BrowserShareRuntimeManifest -Root $root)){throw 'RuntimeManifestMismatch'}
$normalized=$ProfileUrl.TrimEnd('/')
$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
$path=Join-Path $root 'daily-runtime-manifest.json'
$manifest=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
if($manifest.BrowserProfileLinkSHA256){
  if($manifest.BrowserProfileLinkSHA256 -cne $hash){throw 'ExistingBrowserAccountBindingMismatch'}
  [pscustomobject]@{Status='AlreadyBound';AccountIdentifierPrinted=$false;PlatformRequests=0};return
}
$manifest.BrowserProfileLinkSHA256=$hash
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
[pscustomobject]@{Status='BoundFromExplicitAccountMatch';AccountIdentifierPrinted=$false;PlatformRequests=0}