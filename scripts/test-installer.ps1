[CmdletBinding()]
param([string]$SetupPath)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $SetupPath) {
    $SetupPath = (Get-ChildItem -LiteralPath (Join-Path $projectRoot 'dist') -Filter '*-Setup.exe' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not $SetupPath) { throw 'Compile o instalador primeiro.' }
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{46D4E724-7AE7-4BB1-8BCB-B488E8981C01}_is1'
if (Test-Path -LiteralPath $uninstallKey) {
    throw 'Ja existe uma instalacao registrada. Execute este teste em um perfil Windows sem Rust Pixel Bridge instalado.'
}
$testId = [Guid]::NewGuid().ToString('N')
$testGroup = "Rust Pixel Test $testId"
$testPath = Join-Path $projectRoot "target\installer-test-$testId"
$appPath = Join-Path $testPath 'App'
$asepriteDir = Join-Path $testPath 'Aseprite'
$queuePath = Join-Path $testPath 'queue'
New-Item -ItemType Directory -Path $testPath -Force | Out-Null
$previousQueue = $env:RUST_PIXEL_QUEUE_DIR
try {
    $env:RUST_PIXEL_QUEUE_DIR = $queuePath
    $process = Start-Process -FilePath $SetupPath -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=""',
        "/DIR=`"$appPath`"", "/ASEPRITEDIR=`"$asepriteDir`"",
        "/GROUP=`"$testGroup`"", "/LOG=`"$(Join-Path $testPath 'install.log')`""
    ) -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id; throw 'Tempo limite na instalacao.' }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Setup retornou $($process.ExitCode). Logs em $testPath" }
    foreach ($file in @(
        (Join-Path $appPath 'asprite-mcp.exe'), (Join-Path $appPath 'mcp.json'),
        (Join-Path $appPath 'rust-pixel-agent.exe'),
        (Join-Path $asepriteDir 'extensions\rust-pixel\init.lua')
    )) {
        if (-not (Test-Path -LiteralPath $file)) { throw "Arquivo nao instalado: $file" }
    }
    $config = Get-Content -LiteralPath (Join-Path $appPath 'mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.mcpServers.'rust-pixel'.command -ne (Join-Path $appPath 'asprite-mcp.exe')) {
        throw 'O caminho registrado para o servidor esta incorreto.'
    }
    $linkDirectory = Join-Path (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs') $testGroup
    $linkPath = (Get-ChildItem -LiteralPath $linkDirectory -Filter '*.lnk' | Where-Object { $_.Name -like 'Verificar*' }).FullName
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($linkPath)
    if ($shortcut.Arguments -notlike '*doctor*') { throw 'Atalho de diagnostico incorreto.' }
    Write-Host "Atalho de diagnostico: $($shortcut.Arguments)"
    [IO.File]::WriteAllText((Join-Path $queuePath 'assets\keep.txt'), 'asset')
    $uninstaller = Start-Process -FilePath (Join-Path $appPath 'unins000.exe') -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $testPath 'uninstall.log')`""
    ) -PassThru -WindowStyle Hidden
    if (-not $uninstaller.WaitForExit(30000)) { Stop-Process -Id $uninstaller.Id; throw 'Tempo limite na desinstalacao.' }
    $uninstaller.Refresh()
    if ($uninstaller.ExitCode -ne 0) { throw "Uninstaller retornou $($uninstaller.ExitCode)." }
    if (Test-Path -LiteralPath (Join-Path $asepriteDir 'extensions\rust-pixel\init.lua')) { throw 'A extensao nao foi removida.' }
    if (-not (Test-Path -LiteralPath (Join-Path $queuePath 'assets\keep.txt'))) { throw 'Os assets nao foram preservados.' }
    if (Test-Path -LiteralPath $uninstallKey) { throw 'O registro de desinstalacao nao foi removido.' }
    Write-Host 'Setup: instalacao, configuracao MCP, atalhos e desinstalacao passaram.'
    Write-Host "Resultados: $testPath"
} finally {
    $remainingUninstaller = Join-Path $appPath 'unins000.exe'
    if (Test-Path -LiteralPath $remainingUninstaller) {
        Start-Process -FilePath $remainingUninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -WindowStyle Hidden
    }
    if ($null -eq $previousQueue) { Remove-Item Env:RUST_PIXEL_QUEUE_DIR -ErrorAction SilentlyContinue }
    else { $env:RUST_PIXEL_QUEUE_DIR = $previousQueue }
}
