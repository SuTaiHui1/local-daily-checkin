param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config.local.json'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$repository=Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath $ConfigPath) { throw 'Local configuration already exists; it will not be overwritten.' }
Copy-Item -LiteralPath (Join-Path $repository 'config.example.json') -Destination $ConfigPath
$settings=Get-LocalDailyConfig -ConfigPath $ConfigPath
$null=New-Item -ItemType Directory -Path $settings.StateRoot -Force
Write-Output ('Local configuration prepared: '+$ConfigPath)
Write-Output ('Private data directory: '+$settings.StateRoot)
Write-Output 'No program downloaded, account accessed, or scheduled task created. Follow README module setup.'
