[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Version)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$distPath = Join-Path $projectRoot 'dist'
$pluginFiles = @('LICENSE', 'package.json', 'init.lua', 'bridge.lua', 'panel.lua', 'panel-view.lua', 'ui.lua')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-ArchiveContents([string]$ArchivePath, [string[]]$Expected) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') })
        $difference = @(Compare-Object ($Expected | Sort-Object) ($entries | Sort-Object))
        if ($difference.Count -ne 0) { throw 'Package contains missing or unexpected files. Publication is blocked.' }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(?i)\.(png|jpe?g|gif|bmp|webp|ase|aseprite|log|jsonl|pdb|pem|key)$') {
                throw 'Private artwork or diagnostic data found in package. Publication is blocked.'
            }
        }
    } finally { $archive.Dispose() }
}

$expectedPortable = @(
    'asprite-mcp.exe', 'rust-pixel-agent.exe', 'install.bat', 'uninstall.bat',
    'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'docs/README.pt-BR.md'
)
$expectedPortable += $pluginFiles | ForEach-Object { "aseprite-plugin/$_" }
Assert-ArchiveContents (Join-Path $distPath "rust-pixel-$Version-windows-x64.zip") $expectedPortable
Assert-ArchiveContents (Join-Path $distPath "rust-pixel-$Version.aseprite-extension") $pluginFiles

$privatePaths = @($projectRoot, [Environment]::GetFolderPath('UserProfile')) |
    Where-Object { $_ -and $_.Length -gt 3 } | ForEach-Object { $_; $_.Replace('\', '/') } | Select-Object -Unique
foreach ($name in @('asprite-mcp.exe', 'rust-pixel-agent.exe')) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path (Join-Path $projectRoot 'target\release') $name))
    $representations = @([Text.Encoding]::UTF8.GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes))
    foreach ($representation in $representations) {
        foreach ($privatePath in $privatePaths) {
            if ($representation.IndexOf($privatePath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw 'A developer-specific path is embedded in a release binary. Publication is blocked.'
            }
        }
    }
}
Write-Host 'Package privacy checks passed: exact allowlist, no artwork or runtime files, no developer home or workspace paths.'
