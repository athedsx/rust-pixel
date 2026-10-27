[CmdletBinding()]
param([string]$AsepritePath = $env:ASEPRITE_PATH)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $AsepritePath) {
    $command = Get-Command aseprite.exe -ErrorAction SilentlyContinue
    if ($command) { $AsepritePath = $command.Source }
}
if (-not $AsepritePath) {
    $AsepritePath = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Aseprite\Aseprite.exe'
}
if (-not (Test-Path -LiteralPath $AsepritePath)) { throw 'Informe -AsepritePath ou ASEPRITE_PATH.' }
$testPath = Join-Path $projectRoot ('target\aseprite-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testPath -Force | Out-Null
$resultPath = Join-Path $testPath 'result.json'
$process = Start-Process -FilePath $AsepritePath -ArgumentList @(
    '--batch', '--script-param', "`"root=$projectRoot`"",
    '--script-param', "`"queue=$(Join-Path $testPath 'queue')`"",
    '--script-param', "`"result=$resultPath`"",
    '--script', "`"$(Join-Path $projectRoot 'tests\aseprite.lua')`""
) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testPath 'stdout.log') -RedirectStandardError (Join-Path $testPath 'stderr.log')
if (-not $process.WaitForExit(30000)) {
    Stop-Process -Id $process.Id
    throw "Aseprite excedeu 30 segundos. Logs em $testPath"
}
if (-not (Test-Path -LiteralPath $resultPath)) {
    Get-Content -LiteralPath (Join-Path $testPath 'stdout.log'), (Join-Path $testPath 'stderr.log')
    throw "Aseprite nao produziu o resultado. Logs em $testPath"
}
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $result.success) { throw $result.error }
Write-Host "Aseprite $($result.version): testes da extensao passaram."
Write-Host "Resultados: $testPath"
