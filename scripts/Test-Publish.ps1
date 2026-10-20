param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$parseFailures = @()
Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/](\.git|__pycache__)[\\/]' } | ForEach-Object {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { $parseFailures += $_.Name }
}
if ($parseFailures.Count -gt 0) { throw ('PowerShell syntax failed: ' + ($parseFailures -join ', ')) }
# Syntax parsing never executes a deployment script. Python only opens public source/fixtures.
& $Python -B -m unittest discover -s (Join-Path $root 'tests') -p 'test*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Offline publication checks failed.' }
& $Python -B (Join-Path $root 'src\heybox\test_offline.py')
if ($LASTEXITCODE -ne 0) { throw 'Heybox synthetic logic checks failed.' }
& (Join-Path $root 'src\bilibili\Test-Offline.ps1')
& (Join-Path $root 'tests\Smoke-Coordinator.ps1')
Write-Output 'Offline publication checks passed. This is not a live account acceptance test.'
