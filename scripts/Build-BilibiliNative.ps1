[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$DotnetPath='dotnet',
    [string]$PackageCache,
    [switch]$OfflineRestore,
    [string]$UpstreamRepository='https://github.com/RayWangQvQ/BiliBiliToolPro.git'
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$metadata=Get-Content -LiteralPath (Join-Path $projectRoot 'src\bilibili\patches\upstream.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$patch=Join-Path $projectRoot ('src\bilibili\patches\'+$metadata.Patch)
if((Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash -ine $metadata.PatchSHA256){throw 'NativePatchHashMismatch'}
$output=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputDirectory))
$checkout=[IO.Path]::GetFullPath($projectRoot).TrimEnd('\')+'\'
if(($output.TrimEnd('\')+'\').StartsWith($checkout,[StringComparison]::OrdinalIgnoreCase)){throw 'BuildOutputMustBeOutsideRepository'}
if($output.TrimEnd('\') -eq [IO.Path]::GetPathRoot($output).TrimEnd('\')){throw 'BuildOutputCannotBeDriveRoot'}
if((Test-Path -LiteralPath $output) -and @(Get-ChildItem -LiteralPath $output -Force).Count){throw 'BuildOutputMustBeEmpty'}
if($OfflineRestore -and -not $PackageCache){throw 'OfflineRestoreRequiresPackageCache'}
$null=Get-Command git -ErrorAction Stop
$dotnet=(Get-Command $DotnetPath -ErrorAction Stop).Source
$null=New-Item -ItemType Directory -Path $output -Force
$source=Join-Path $output 'source'
$payload=Join-Path $output 'app'
$savedEnvironment=@{}
foreach($name in @('DOTNET_CLI_HOME','DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_NOLOGO','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_GENERATE_ASPNET_CERTIFICATE','NUGET_PACKAGES','HUSKY')){$savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
    $env:DOTNET_CLI_HOME=Join-Path $output 'dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_NOLOGO='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:HUSKY='0'
    if($PackageCache){$env:NUGET_PACKAGES=[IO.Path]::GetFullPath($PackageCache)}
    & git clone --no-checkout -- $UpstreamRepository $source
    if($LASTEXITCODE -ne 0){throw 'UpstreamCloneFailed'}
    & git -C $source checkout --detach $metadata.Commit
    if($LASTEXITCODE -ne 0){throw 'PinnedUpstreamCommitUnavailable'}
    $head=(& git -C $source rev-parse HEAD).Trim()
    if($head -cne $metadata.Commit){throw 'UpstreamCommitMismatch'}
    & git -C $source apply --check -- $patch
    if($LASTEXITCODE -ne 0){throw 'NativePatchCheckFailed'}
    & git -C $source apply -- $patch
    if($LASTEXITCODE -ne 0){throw 'NativePatchApplyFailed'}
    $restoreArgs=@('-p:NuGetAudit=false','-p:HUSKY=0','--verbosity','quiet')
    if($OfflineRestore){
        $offline=Join-Path $output 'NuGet.Offline.Config'
        [IO.File]::WriteAllText($offline,'<configuration><packageSources><clear /></packageSources></configuration>')
        $restoreArgs+=@('--configfile',$offline)
    }
    $test=Join-Path $source 'test\SharePathComparison.Tests\SharePathComparison.Tests.csproj'
    $console=Join-Path $source 'src\Ray.BiliBiliTool.Console\Ray.BiliBiliTool.Console.csproj'
    Push-Location $source
    try {
        $sdk=(& $dotnet --version).Trim()
        if($LASTEXITCODE -ne 0 -or ($sdk -notmatch '^10\.0\.\d+$' -or [version]$sdk -lt [version]$metadata.SdkVersion)){throw 'PinnedDotnetSdkRequired'}
        & $dotnet restore $test @restoreArgs
        if($LASTEXITCODE -ne 0){throw 'NativeTestRestoreFailed'}
        & $dotnet test $test --no-restore -c Release -p:NuGetAudit=false -p:HUSKY=0 --logger 'trx;LogFileName=native-tests.trx' --results-directory (Join-Path $output 'test-results') --verbosity quiet
        if($LASTEXITCODE -ne 0){throw 'NativeOfflineTestsFailed'}
        & $dotnet restore $console -r win-x64 -p:SelfContained=true -p:PublishSingleFile=true @restoreArgs
        if($LASTEXITCODE -ne 0){throw 'NativePublishRestoreFailed'}
        & $dotnet publish $console --no-restore -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -p:Deterministic=true -p:IncludeSourceRevisionInInformationalVersion=false ('-p:Version='+$metadata.NativeVersion) ('-p:InformationalVersion='+$metadata.NativeVersion+'+'+$metadata.Commit) -p:NuGetAudit=false -p:HUSKY=0 -o $payload --verbosity quiet
        if($LASTEXITCODE -ne 0){throw 'NativePublishFailed'}
    } finally {Pop-Location}
    $exe=Join-Path $payload 'Ray.BiliBiliTool.Console.exe'
    if(-not(Test-Path -LiteralPath $exe)){throw 'NativeExecutableMissing'}
    [xml]$trx=Get-Content -LiteralPath (Join-Path $output 'test-results\native-tests.trx') -Raw
    $counts=$trx.TestRun.ResultSummary.Counters
    if([int]$counts.total -lt 1 -or [int]$counts.failed -ne 0 -or [int]$counts.passed -ne [int]$counts.total){throw 'NativeTestEvidenceInvalid'}
    $files=@(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName | ForEach-Object {[ordered]@{File=$_.FullName.Substring($payload.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
    $manifest=[ordered]@{SchemaVersion=1;Status='BuiltAndOfflineTested';UpstreamRepository=$metadata.Repository;UpstreamCommit=$head;Patch=$metadata.Patch;PatchSHA256=$metadata.PatchSHA256;NativeVersion=$metadata.NativeVersion;SdkVersion=$sdk;Runtime='win-x64';SelfContained=$true;TestsPassed=[int]$counts.passed;TestsFailed=0;PlatformTasksRun=$false;BuiltAt=[datetimeoffset]::Now.ToString('o');HashMeaning='LocallyBuiltOutputNotPublisherBinaryDigest';Files=$files}
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'native-build.json') -Encoding UTF8
    [pscustomobject]@{Status=$manifest.Status;BuildDirectory=$output;TestsPassed=$manifest.TestsPassed;NativeVersion=$manifest.NativeVersion;PlatformTasksRun=$false}
} finally {foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}}
