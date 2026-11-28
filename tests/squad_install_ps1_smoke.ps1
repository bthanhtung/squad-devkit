#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path $PSScriptRoot) 'install.ps1'
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join "`n") }

$temp = Join-Path ([IO.Path]::GetTempPath()) "squad ps1 smoke $([guid]::NewGuid())"
$bin = Join-Path $temp 'bin with spaces'
$archiveName = 'squad-x86_64-pc-windows-msvc.zip'
$archive = Join-Path $temp $archiveName
$manifest = Join-Path $temp 'SHA256SUMS'
$fixture = Join-Path $temp 'squad.exe'
$installed = Join-Path $bin 'squad.exe'
$originalUrl = $env:SQUAD_DEVKIT_RELEASE_URL
try {
    [void](New-Item -ItemType Directory -Path $temp)
    $urlPath = $temp.Replace('\', '/')
    if (!$urlPath.StartsWith('/')) { $urlPath = "/$urlPath" }
    $env:SQUAD_DEVKIT_RELEASE_URL = ([uri]("file://$urlPath/")).AbsoluteUri
    pwsh -NoProfile -File $installer -NoSkill -BinDir $bin -Check
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $bin)) { throw 'Check mode failed or wrote files' }

    [IO.File]::WriteAllBytes($fixture, [byte[]](0, 42, 255))
    Compress-Archive -LiteralPath $fixture -DestinationPath $archive
    $valid = "$((Get-FileHash -LiteralPath $archive).Hash) *$archiveName"
    Set-Content -LiteralPath $manifest -Value $valid
    pwsh -NoProfile -File $installer -NoSkill -BinDir $bin
    if ($LASTEXITCODE -ne 0) { throw 'Offline installation failed' }
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $fixture).Hash) { throw 'Wrong installed binary' }

    foreach ($name in 'squad-devkit', 'squad-worker', 'squad-monitor', 'squad-orchestration', 'squad-route', 'squad-ask', 'squad-telegram') {
        $cmd = Get-Content -Raw -LiteralPath (Join-Path $bin "$name.cmd")
        $shim = Get-Content -Raw -LiteralPath (Join-Path $bin $name)
        $script = if ($name -eq 'squad-monitor') { 'squad-worker-monitor.sh' } else { "$name.sh" }
        if (!$cmd.Contains($script) -or !$cmd.Contains('%*') -or !$shim.Contains($script) -or !$shim.Contains('"$@"')) {
            throw "Invalid wrappers for $name"
        }
    }

    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $versionOutput = & (Join-Path $bin 'squad-devkit.cmd') --version
    } else {
        $versionOutput = & (Join-Path $bin 'squad-devkit') --version
    }
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '\d+\.\d+\.\d+') {
        throw 'Installed squad-devkit command could not run --version'
    }

    # Successful upgrade replaces an existing file.
    [IO.File]::WriteAllBytes($installed, [byte[]](255, 1, 0))
    pwsh -NoProfile -File $installer -NoSkill -BinDir $bin
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $fixture).Hash) {
        throw 'Replacement installation failed'
    }
    [IO.File]::WriteAllBytes($installed, [byte[]](255, 0, 1))
    $before = (Get-FileHash -LiteralPath $installed).Hash
    foreach ($problem in 'missing', 'duplicate', 'mismatch', 'missing checksum manifest') {
        $lines = switch ($problem) {
            'missing' { "$('0' * 64)  other.zip" }
            'duplicate' { $valid; $valid }
            'mismatch' { "$('0' * 64)  $archiveName" }
        }
        if ($problem -eq 'missing checksum manifest') {
            Remove-Item -LiteralPath $manifest
        } else {
            Set-Content -LiteralPath $manifest -Value $lines
        }
        $output = pwsh -NoProfile -File $installer -NoSkill -BinDir $bin 2>&1
        if ($LASTEXITCODE -eq 0 -or ($output -join ' ') -notmatch $problem) { throw "Installer did not reject $problem checksum" }
        if ((Get-FileHash -LiteralPath $installed).Hash -ne $before) { throw "Binary changed after $problem checksum" }
    }
} finally {
    $env:SQUAD_DEVKIT_RELEASE_URL = $originalUrl
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
Write-Output 'squad_install_ps1_smoke: PASS'
