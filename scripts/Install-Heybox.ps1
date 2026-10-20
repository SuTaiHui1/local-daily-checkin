param(
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'LocalDailyCheckin\heybox'),
  [string]$AppApk,
  [string]$ResourceDirectory,
  [string]$UpstreamSourceDirectory,
  [switch]$FetchUpstreamSource
)
$ErrorActionPreference='Stop'
$repo = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repo 'src\heybox'
$state = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
if ($state.TrimEnd('\','/') -eq $repo.TrimEnd('\','/') -or $state.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'StateRoot must be outside this repository.' }
if ($state.TrimEnd('\','/') -eq [IO.Path]::GetPathRoot($state).TrimEnd('\','/')) { throw 'StateRoot cannot be a disk or share root.' }
if ((Test-Path -LiteralPath $state) -and @(Get-ChildItem -LiteralPath $state -Force).Count -gt 0) { throw 'Existing nonempty StateRoot was preserved; select a fresh private directory.' }
if (-not [Environment]::Is64BitOperatingSystem -or ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64')) { throw 'Only Windows x64 has been qualified for this native engine.' }
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run installation as your ordinary Windows user.' }
$required = @('shader-code.bin','report-material.properties','report-public-key.der','provenance.json')
if (-not $AppApk -or -not (Test-Path -LiteralPath $AppApk -PathType Leaf) -or -not $ResourceDirectory) {
  throw 'Heybox remains disabled: personally obtained compatible APK and runtime resources are required. Read docs/heybox.md; nothing was downloaded or run.'
}
foreach($name in $required) {
  if(-not (Test-Path -LiteralPath (Join-Path $ResourceDirectory $name) -PathType Leaf)) { throw "Missing resource $name. No App API has been requested; read docs/heybox.md." }
}
$java = (Get-Command java.exe -ErrorAction Stop).Source
$javac = Join-Path (Split-Path $java -Parent) 'javac.exe'
if(-not (Test-Path -LiteralPath $javac)) { throw 'JDK 17 (including javac) is required; a JRE is insufficient.' }
$version = (& $java -version 2>&1 | Out-String)
if($version -notmatch 'version "17[\.]') { throw 'This local native engine requires JDK 17; newer JDKs disable its network restriction mechanism.' }
$maven = (Get-Command mvn.cmd -ErrorAction Stop).Source
$python = (Get-Command python.exe -ErrorAction Stop).Source
$private=Join-Path $state 'private'
if(Test-Path -LiteralPath (Join-Path $private 'resource-manifest.json')) { throw 'Existing deployment preserved; select a fresh state directory rather than overwriting resources or credentials.' }
New-Item -ItemType Directory -Path $private -Force | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $state /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Private state ACL could not be applied.'}
New-Item -ItemType Directory -Path (Join-Path $state 'logs'),(Join-Path $private 'build'),(Join-Path $private 'lib'),(Join-Path $private 'java-tmp') -Force | Out-Null
$upstreamCommit='b7cc58df7c4bd1527ad25a333985ea2a59c792e4'
if(-not $UpstreamSourceDirectory) {
  if(-not $FetchUpstreamSource){throw 'External native bridge has no repository-level license. Supply your own fixed upstream checkout, or explicitly choose -FetchUpstreamSource for personal local use; it is not redistributed here.'}
  $UpstreamSourceDirectory=Join-Path $private 'upstream-source'
  if(Test-Path -LiteralPath $UpstreamSourceDirectory){throw 'External source directory already exists; it was preserved.'}
  & git.exe clone --no-checkout https://github.com/zhong08/heybox-checkin.git $UpstreamSourceDirectory *> (Join-Path $private 'source-build.log')
  if($LASTEXITCODE -ne 0){throw 'External source acquisition failed; no retry.'}
  & git.exe -C $UpstreamSourceDirectory checkout --detach $upstreamCommit *>> (Join-Path $private 'source-build.log')
  if($LASTEXITCODE -ne 0){throw 'Fixed external source checkout failed; no retry.'}
}
$actual=(& git.exe -C $UpstreamSourceDirectory rev-parse HEAD 2>$null | Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $upstreamCommit){throw 'External source commit mismatch.'}
$dirty=(& git.exe -C $UpstreamSourceDirectory status --porcelain --untracked-files=no | Out-String).Trim()
if($dirty){throw 'External source contains tracked modifications; it was preserved.'}
$venv=Join-Path $state 'venv'
& $python -m venv $venv *> (Join-Path $private 'python-install.log')
if($LASTEXITCODE -ne 0){throw 'Private Python environment creation failed.'}
$taskPython=Join-Path $venv 'Scripts\python.exe'
& $taskPython -m pip install --disable-pip-version-check --retries 0 -r (Join-Path $source 'requirements.txt') *>> (Join-Path $private 'python-install.log')
if($LASTEXITCODE -ne 0){throw 'Python dependency installation failed; no retry.'}
& $taskPython (Join-Path $source 'PrepareResources.py') --state-root $state --apk $AppApk --resources $ResourceDirectory
if($LASTEXITCODE -ne 0){throw 'Offline resource compatibility check failed.'}
$pom=Join-Path $UpstreamSourceDirectory 'signer\pom.xml'
& $maven -B -f $pom '-Dmaven.wagon.http.retryHandler.count=0' '-Dmaven.wagon.httpconnectionManager.ttlSeconds=10' 'org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies' "-DoutputDirectory=$(Join-Path $private 'lib')" "-Dmaven.repo.local=$(Join-Path $private 'm2')" *> (Join-Path $private 'source-build.log')
if($LASTEXITCODE -ne 0){throw 'Pinned dependency build failed; no App request was sent.'}
$javaSources=@((Join-Path $UpstreamSourceDirectory 'signer\NativeSigner.java'),(Join-Path $UpstreamSourceDirectory 'signer\net\fornwall\jelf\ElfParser.java'),(Join-Path $UpstreamSourceDirectory 'signer\net\fornwall\jelf\ElfParserCheck.java'),(Join-Path $source 'PhoneNativeRunner.java'),(Join-Path $source 'ReportBuilder.java'))
& $javac -encoding UTF-8 -cp "$(Join-Path $private 'lib')\*" -d (Join-Path $private 'build') @javaSources *>> (Join-Path $private 'source-build.log')
if($LASTEXITCODE -ne 0){throw 'Local Java build failed; no App request was sent.'}
& $java -cp "$(Join-Path $private 'build');$(Join-Path $private 'lib')\*" net.fornwall.jelf.ElfParserCheck *>> (Join-Path $private 'source-build.log')
if($LASTEXITCODE -ne 0){throw 'Offline 64-bit engine check failed.'}
$settings=@{JavaExecutable=$java;UpstreamCommit=$upstreamCommit;InstalledAt=(Get-Date).ToString('o')}
$settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $private 'installation.json') -Encoding UTF8
'Local dependencies built. Import your own authorized phone session next. No App API or daily task was executed; Heybox is not automatically enabled.'
