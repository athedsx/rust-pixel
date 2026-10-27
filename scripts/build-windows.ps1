[CmdletBinding()]
param(
    [switch]$BootstrapInno,
    [switch]$SkipInstaller,
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$distPath = Join-Path $projectRoot 'dist'
$toolsPath = Join-Path $projectRoot '.tools'
$previousEncodedFlags = $env:CARGO_ENCODED_RUSTFLAGS
$pluginFiles = @('LICENSE', 'package.json', 'init.lua', 'bridge.lua', 'panel.lua', 'panel-view.lua', 'ui.lua')

function Find-InnoCompiler {
    if ($IsccPath) {
        return (Get-Item -LiteralPath $IsccPath).FullName
    }
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compiler) { return $compiler.Source }
    $candidates = @(
        (Join-Path $toolsPath 'inno\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    if (-not $BootstrapInno) {
        throw 'Inno Setup 6 nao encontrado. Use -BootstrapInno ou informe -IsccPath.'
    }
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    $setupPath = Join-Path $toolsPath 'innosetup-6.7.3.exe'
    $download = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
    Write-Host 'Baixando Inno Setup 6.7.3...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $download -OutFile $setupPath
    $signature = Get-AuthenticodeSignature -LiteralPath $setupPath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
        throw 'A assinatura digital do Inno Setup nao foi validada.'
    }
    $innoPath = Join-Path $toolsPath 'inno'
    $process = Start-Process -FilePath $setupPath -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
        '/NOICONS', "/DIR=`"$innoPath`""
    ) -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "Inno Setup retornou $($process.ExitCode)." }
    return (Get-Item -LiteralPath (Join-Path $innoPath 'ISCC.exe')).FullName
}

Push-Location -LiteralPath $projectRoot
try {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw 'Rust nao encontrado. Instale a toolchain estavel em https://rustup.rs.'
    }
    $compiler = if (-not $SkipInstaller) { Find-InnoCompiler }
    $separator = [char]0x1f
    $buildFlags = @()
    if ($previousEncodedFlags) {
        $buildFlags += $previousEncodedFlags.Split($separator)
    } elseif ($env:RUSTFLAGS) {
        $buildFlags += $env:RUSTFLAGS.Split([char[]]" `t`r`n", [StringSplitOptions]::RemoveEmptyEntries)
    }
    $buildFlags += "--remap-path-prefix=$projectRoot=/rust-pixel"
    $userProfilePath = [Environment]::GetFolderPath('UserProfile')
    if ($userProfilePath) { $buildFlags += "--remap-path-prefix=$userProfilePath=/build/user" }
    if ($env:CARGO_HOME) { $buildFlags += "--remap-path-prefix=$env:CARGO_HOME=/build/cargo" }
    if ($env:RUSTUP_HOME) { $buildFlags += "--remap-path-prefix=$env:RUSTUP_HOME=/build/rustup" }
    $env:CARGO_ENCODED_RUSTFLAGS = $buildFlags -join $separator
    & cargo rustc --release --locked -p asprite-mcp --bin asprite-mcp -- -C target-feature=+crt-static -C 'link-arg=/PDBALTPATH:%_PDB%'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o executavel.' }
    & cargo rustc --release --locked -p asprite-mcp --bin rust-pixel-agent -- -C target-feature=+crt-static -C 'link-arg=/PDBALTPATH:%_PDB%'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o assistente.' }
    $metadata = & cargo metadata --no-deps --format-version 1 --locked | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao consultar a versao do projeto.' }
    $version = ($metadata.packages | Where-Object { $_.name -eq 'asprite-mcp' }).version
    $plugin = Get-Content -LiteralPath (Join-Path $projectRoot 'aseprite-plugin\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plugin.version -ne $version) { throw 'As versoes do servidor e da extensao devem ser iguais.' }
    $target = & rustc -vV | Select-String '^host: (.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    if ($target -ne 'x86_64-pc-windows-msvc') {
        throw 'O pacote Windows requer a toolchain x86_64-pc-windows-msvc.'
    }
    New-Item -ItemType Directory -Path $distPath -Force | Out-Null
    New-Item -ItemType Directory -Path $toolsPath -Force | Out-Null
    $stagePath = Join-Path $toolsPath ('package-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagePath | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'target\release\asprite-mcp.exe') -Destination $stagePath
    Copy-Item -LiteralPath (Join-Path $projectRoot 'target\release\rust-pixel-agent.exe') -Destination $stagePath
    foreach ($name in @('install.bat', 'uninstall.bat', 'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'CONTRIBUTING.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $stagePath
    }
    $stageDocs = Join-Path $stagePath 'docs'
    New-Item -ItemType Directory -Path $stageDocs | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\README.pt-BR.md') -Destination $stageDocs
    $stagePlugin = Join-Path $stagePath 'aseprite-plugin'
    New-Item -ItemType Directory -Path $stagePlugin | Out-Null
    foreach ($name in $pluginFiles) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $projectRoot 'aseprite-plugin') $name) -Destination $stagePlugin
    }
    $zipPath = Join-Path $distPath "rust-pixel-$version-windows-x64.zip"
    Compress-Archive -Path (Join-Path $stagePath '*') -DestinationPath $zipPath -Force
    $extensionZip = Join-Path $distPath 'rust-pixel-extension.zip'
    Compress-Archive -Path (Join-Path $stagePlugin '*') -DestinationPath $extensionZip -Force
    $extensionPath = Join-Path $distPath "rust-pixel-$version.aseprite-extension"
    Move-Item -LiteralPath $extensionZip -Destination $extensionPath -Force
    if (-not $SkipInstaller) {
        & $compiler "/DAppVersion=$version" "/DSourceRoot=$projectRoot" (Join-Path $projectRoot 'installer\rust-pixel.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o instalador.' }
    }
    $artifacts = @($zipPath, $extensionPath)
    if (-not $SkipInstaller) {
        $artifacts += Join-Path $distPath "RustPixelBridge-$version-windows-x64-Setup.exe"
    }
    $checksums = foreach ($artifact in $artifacts) {
        $hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
        '{0}  {1}' -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($artifact)
    }
    [IO.File]::WriteAllLines((Join-Path $distPath 'SHA256SUMS.txt'), [string[]]$checksums)
    & (Join-Path $PSScriptRoot 'test-package.ps1') -Version $version
    if (-not $?) { throw 'Falha na verificacao de privacidade do pacote.' }
    Write-Host "Pacotes gerados em $distPath"
} finally {
    if ($null -eq $previousEncodedFlags) { Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue }
    else { $env:CARGO_ENCODED_RUSTFLAGS = $previousEncodedFlags }
    Pop-Location
}
