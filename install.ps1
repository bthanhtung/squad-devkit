#Requires -Version 5.1
param(
    [string]$BinDir,
    [switch]$BuildSquad,
    [switch]$SkipSquad,
    [switch]$AddToPath,
    [switch]$NoSkill,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$windowsHost = [IO.Path]::DirectorySeparatorChar -eq '\'
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
if (!$BinDir) {
    $BinDir = if ($env:SQUAD_DEVKIT_BIN_DIR) { $env:SQUAD_DEVKIT_BIN_DIR } else { Join-Path $userHome '.local/bin' }
}
$BinDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BinDir)
$commands = [ordered]@{
    'squad-devkit' = 'squad-devkit.sh'
    'squad-worker' = 'squad-worker.sh'
    'squad-monitor' = 'squad-worker-monitor.sh'
    'squad-orchestration' = 'squad-orchestration.sh'
    'squad-route' = 'squad-route.sh'
    'squad-ask' = 'squad-ask.sh'
    'squad-telegram' = 'squad-telegram.sh'
}

$scriptsDir = Join-Path $PSScriptRoot 'scripts'
foreach ($scriptName in $commands.Values) {
    if (!(Test-Path -LiteralPath (Join-Path $scriptsDir $scriptName) -PathType Leaf)) { throw "Missing scripts/$scriptName" }
}
$versionMatch = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Cargo.toml')), '(?m)^version\s*=\s*"([^"]+)"')
if (!$versionMatch.Success) { throw 'Could not determine squad version from Cargo.toml' }
$version = $versionMatch.Groups[1].Value
$releaseUrl = $env:SQUAD_DEVKIT_RELEASE_URL
if (!$releaseUrl) { $releaseUrl = "https://github.com/bthanhtung/squad-devkit/releases/download/v$version" }

$gitBash = $null
if ($windowsHost) {
    # System32's bash.exe launches WSL and cannot run a Git Bash shim.
    $gitBash = Get-Command bash.exe -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { !$_.Source.StartsWith("$env:SystemRoot\", [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1 -ExpandProperty Source
    if (!$gitBash) {
        foreach ($programDir in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if (!$programDir) { continue }
            $candidate = Join-Path $programDir 'Git/bin/bash.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $gitBash = $candidate; break }
        }
    }
    if (!$gitBash) {
        if (!(Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            Write-Warning 'Install Git for Windows (Git Bash) or WSL2 to run the devkit shell commands.'
        } else {
            Write-Warning 'Install Git Bash for native .cmd wrappers, or run scripts/install-devkit.sh inside WSL2.'
        }
    }
}

$cargo = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue
if ($BuildSquad -and !$SkipSquad -and !$cargo) { throw 'Install Rust from https://rustup.rs to build squad.' }
$skillSource = Join-Path $PSScriptRoot 'skills/squad-devkit'
if (!$NoSkill -and !(Test-Path -LiteralPath (Join-Path $skillSource 'SKILL.md') -PathType Leaf)) {
    throw 'Missing skills/squad-devkit/SKILL.md'
}
if ($AddToPath -and !$windowsHost) { throw '-AddToPath requires Windows.' }
if ($Check) {
    Write-Host "Installer check passed for squad $version."
    return
}

function Get-ReleaseFile([string]$Name, [string]$Destination) {
    if ($releaseUrl -match '^https?://') {
        Invoke-WebRequest -UseBasicParsing -Uri "$($releaseUrl.TrimEnd('/'))/$Name" -OutFile $Destination
    } else {
        $directory = if ($releaseUrl -match '^file://') { ([uri]$releaseUrl).LocalPath } else { $releaseUrl }
        Copy-Item -LiteralPath (Join-Path $directory $Name) -Destination $Destination
    }
}

if (!$SkipSquad) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) "squad-install-$([guid]::NewGuid())"
    [void][IO.Directory]::CreateDirectory($temp)
    try {
        $binary = $null
        if (!$BuildSquad) {
            $archiveName = 'squad-x86_64-pc-windows-msvc.zip'
            $archive = Join-Path $temp $archiveName
            $available = $true
            try {
                Get-ReleaseFile $archiveName $archive
            } catch {
                Write-Warning "Release archive unavailable. Falling back to a source build."
                $available = $false
            }
            if ($available) {
                $manifest = Join-Path $temp 'SHA256SUMS'
                try {
                    Get-ReleaseFile 'SHA256SUMS' $manifest
                } catch {
                    throw "Missing checksum manifest SHA256SUMS for $archiveName"
                }
                $pattern = '(^|\s|\*)' + [regex]::Escape($archiveName) + '$'
                $entries = @(Get-Content -LiteralPath $manifest | Where-Object { $_ -cmatch $pattern })
                if ($entries.Count -eq 0) { throw "Missing checksum for $archiveName" }
                if ($entries.Count -gt 1) { throw "Duplicate checksum for $archiveName" }
                $expected = ($entries[0].TrimStart() -split '\s+', 2)[0]
                if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $expected) {
                    throw "Checksum mismatch for $archiveName"
                }
                $extracted = Join-Path $temp 'extracted'
                Expand-Archive -LiteralPath $archive -DestinationPath $extracted
                $binary = Join-Path $extracted 'squad.exe'
                if (!(Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Missing squad.exe in $archiveName" }
            }
        }
        if (!$binary) {
            if (!$cargo) { throw 'Install Rust from https://rustup.rs to build squad.' }
            Push-Location -LiteralPath $PSScriptRoot
            try {
                & $cargo.Source build --release --locked
                if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
            } finally {
                Pop-Location
            }
            $builtName = if ($windowsHost) { 'squad.exe' } else { 'squad' }
            $binary = Join-Path $PSScriptRoot "target/release/$builtName"
        }

        [void][IO.Directory]::CreateDirectory($BinDir)
        $target = Join-Path $BinDir 'squad.exe'
        $staged = Join-Path $BinDir ".squad-install-$([guid]::NewGuid())"
        try {
            [IO.File]::Copy($binary, $staged)
            if ([IO.File]::Exists($target)) {
                if ($windowsHost) {
                    [IO.File]::Replace($staged, $target, [NullString]::Value)
                } else {
                    [IO.File]::Move($staged, $target, $true)
                }
            } else {
                [IO.File]::Move($staged, $target)
            }
        } finally {
            [IO.File]::Delete($staged)
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}

[void][IO.Directory]::CreateDirectory($BinDir)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bashCommand = if ($gitBash) { $gitBash } else { 'bash.exe' }
foreach ($name in $commands.Keys) {
    $scriptPath = (Join-Path $scriptsDir $commands[$name]).Replace('\', '/')
    $shellPath = $scriptPath.Replace("'", "'\''")
    $shim = '#!/usr/bin/env bash' + "`n" + 'exec ' + "'$shellPath'" + ' "$@"' + "`n"
    $shimPath = Join-Path $BinDir $name
    $shimEntry = Get-Item -LiteralPath $shimPath -Force -ErrorAction SilentlyContinue
    if ($shimEntry -and ($shimEntry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ($shimEntry.PSIsContainer) { throw "Expected a command file at $shimPath" }
        Remove-Item -LiteralPath $shimPath -Force
    }
    [IO.File]::WriteAllText($shimPath, $shim, $utf8)
    if (!$windowsHost) {
        & chmod 755 $shimPath
        if ($LASTEXITCODE -ne 0) { throw "chmod failed for $shimPath" }
    }
    $cmd = '@echo off', 'setlocal DisableDelayedExpansion', 'set "CHERE_INVOKING=1"',
        ('"{0}" --login "{1}" %*' -f $bashCommand.Replace('%', '%%'), $scriptPath.Replace('%', '%%'))
    [IO.File]::WriteAllText((Join-Path $BinDir "$name.cmd"), ($cmd -join "`r`n") + "`r`n", $utf8)
}

if (!$NoSkill) {
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $userHome '.claude' }
    $codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }
    foreach ($configDir in $claudeDir, $codexDir) {
        if (!(Test-Path -LiteralPath $configDir -PathType Container)) { continue }
        $skillsDir = Join-Path $configDir 'skills'
        $skillTarget = Join-Path $skillsDir 'squad-devkit'
        if (Test-Path -LiteralPath $skillTarget) { continue }
        [void][IO.Directory]::CreateDirectory($skillsDir)
        try {
            [void](New-Item -ItemType SymbolicLink -Path $skillTarget -Target $skillSource)
        } catch {
            Write-Warning "Skill skipped at $skillTarget (symlink unavailable)."
        }
    }
}

if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($BinDir -notin ($userPath -split ';')) {
        if ($userPath) { $userPath = "$userPath;$BinDir" } else { $userPath = $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $userPath, 'User')
    }
    Write-Host 'Open a new terminal to use the updated User PATH.'
} else {
    $quotedBin = $BinDir.Replace("'", "''")
    Write-Host 'Add the commands to Windows User PATH with PowerShell:'
    Write-Host ('[Environment]::SetEnvironmentVariable(''Path'', ((([Environment]::GetEnvironmentVariable(''Path'', ''User'') -split '';'') + ''{0}'') | Where-Object {{ $_ }} | Select-Object -Unique) -join '';'', ''User'')' -f $quotedBin)
}
