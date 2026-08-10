#Requires -Version 5.1
<#
.SYNOPSIS
    Links config and installs tools for the Windows host, driven by deps.conf.

.DESCRIPTION
    The Windows counterpart to install.sh. Both read the same manifest, so
    adding a Windows config stays a deps.conf edit - the invariant the bash
    side already holds itself to.

    Only sections that explicitly declare `platform windows` are visible here.
    That is deliberately opt-IN, where the bash parser is opt-OUT: a section
    with no platform line means "every platform this entry point handles",
    which is right for [bash] (Linux and macOS both) and catastrophic here,
    where it would link bashrc into %USERPROFILE%.

    Targets Windows PowerShell 5.1, not just PowerShell 7 - 5.1 is what a
    fresh Windows box runs when you paste the bootstrap line. So: no ternary
    operators, no null-coalescing, no $IsWindows, and Join-Path takes exactly
    two arguments.

.PARAMETER RepoRoot
    The dotfiles clone. Defaults to this script's parent directory, which is
    absent when the script is run as a scriptblock (bootstrap.ps1 does that to
    sidestep the execution policy), so bootstrap passes it explicitly.

.PARAMETER Sections
    Limit to these manifest sections. Default: every windows section.

.PARAMETER LinkOnly
    Symlinks only - no winget, no downloads. The analogue of `make link`, for
    a machine where you can't install anything but still want your config.

.EXAMPLE
    .\windows\install.ps1
    .\windows\install.ps1 -LinkOnly
#>
[CmdletBinding()]
param(
    [string]   $RepoRoot,
    [string[]] $Sections,
    [switch]   $LinkOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 5.1 on older builds negotiates TLS 1.0 by default, which GitHub refuses.
# Harmless where the default is already sane.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Locate the repo -------------------------------------------------------

if (-not $RepoRoot) {
    if ($PSScriptRoot) {
        $RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    }
    else {
        throw 'Could not determine the repo root. Pass -RepoRoot <path>.'
    }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$Manifest = Join-Path $RepoRoot 'deps.conf'

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "Manifest not found: $Manifest"
}

$BackupDir = Join-Path $env:USERPROFILE ('.dotfiles_backup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))

# --- Manifest --------------------------------------------------------------

# Strip from the first '#' and trim. Matches bash's ${raw%%#*} exactly -
# including that a '#' inside a value would truncate it, which is why the
# manifest has no such values.
function Remove-ManifestComment {
    param([string] $Line)

    $hash = $Line.IndexOf('#')
    if ($hash -ge 0) { $Line = $Line.Substring(0, $hash) }
    return $Line.Trim()
}

<#
    Two passes, because `platform` is a property of the whole section and the
    bash parser collects it before deciding anything. A single pass would make
    a `platform` line placed below a `link` line silently drop that link, so
    the two parsers would disagree about the same file. They must not.
#>
function Get-ManifestRecord {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Platform = 'windows'
    )

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8

    # Pass 1: section -> declared platform
    $platformOf = @{}
    $section = ''
    foreach ($raw in $lines) {
        $line = Remove-ManifestComment $raw
        if ($line.Length -eq 0) { continue }

        if ($line -match '^\[([A-Za-z0-9_-]+)\]') {
            $section = $Matches[1]
            if (-not $platformOf.ContainsKey($section)) { $platformOf[$section] = '' }
            continue
        }

        $fields = $line -split '\s+'
        if ($fields[0] -eq 'platform' -and $fields.Count -ge 2 -and $section) {
            $platformOf[$section] = $fields[1]
        }
    }

    # Pass 2: emit the records belonging to a section that named this platform
    $records = New-Object System.Collections.ArrayList
    $section = ''
    foreach ($raw in $lines) {
        $line = Remove-ManifestComment $raw
        if ($line.Length -eq 0) { continue }

        if ($line -match '^\[([A-Za-z0-9_-]+)\]') {
            $section = $Matches[1]
            continue
        }
        if (-not $section) { continue }
        if ($platformOf[$section] -ne $Platform) { continue }

        $fields = $line -split '\s+'
        if ($fields[0] -eq 'platform') { continue }

        [void] $records.Add([pscustomobject]@{
            Section = $section
            Kind    = $fields[0]
            Fields  = $fields
        })
    }

    return $records.ToArray()
}

# `~/.config/x` -> `C:\Users\<you>\.config\x`. The manifest is written for the
# bash side, so destinations arrive with forward slashes.
function Resolve-Destination {
    param([string] $Destination)

    $path = $Destination
    if ($path.StartsWith('~')) { $path = $env:USERPROFILE + $path.Substring(1) }
    return $path.Replace('/', '\')
}

# --- Linking ---------------------------------------------------------------

function Test-ReparsePoint {
    param([System.IO.FileSystemInfo] $Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
}

function Get-LinkTarget {
    param([System.IO.FileSystemInfo] $Item)

    # .Target is a string on some versions and a collection on others, and is
    # absent entirely on the oldest. Normalise rather than trust the shape.
    try {
        $t = $Item.Target
        if ($null -eq $t) { return $null }
        return @($t)[0]
    }
    catch {
        return $null
    }
}

function Install-ConfigLink {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Host "  MISSING source: $Source" -ForegroundColor Red
        return $false
    }
    $Source = (Resolve-Path -LiteralPath $Source).ProviderPath

    # Test-Path reports $false for a symlink whose target is gone, so ask for
    # the directory entry itself. A stale link is exactly the case that needs
    # replacing, and it must not look like "nothing is there".
    $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue

    if ($existing) {
        if ((Test-ReparsePoint $existing) -and ((Get-LinkTarget $existing) -eq $Source)) {
            Write-Host "  ok $Destination"
            return $true
        }

        if (-not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        }
        Move-Item -LiteralPath $Destination -Destination $BackupDir -Force
        Write-Host "  backed up $Destination -> $BackupDir"
    }

    $parent = Split-Path -Path $Destination -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # -Value, not -Target: 5.1's New-Item has no -Target parameter, and PS7
    # still accepts -Value. Attempting the link and catching is more honest
    # than probing the Developer Mode registry key, which answers a related
    # question rather than this one.
    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Value $Source -Force | Out-Null
        Write-Host "  linked $Destination -> $Source"
        return $true
    }
    catch {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Write-Host "  copied $Destination (symlink denied)" -ForegroundColor Yellow
        Write-Host "    Turn on Settings > System > For developers > Developer Mode" -ForegroundColor Yellow
        Write-Host "    and re-run to get a link that tracks the repo. Until then this" -ForegroundColor Yellow
        Write-Host "    is a copy: editing the repo will not change it." -ForegroundColor Yellow
        return $true
    }
}

# --- Tools -----------------------------------------------------------------

function Install-WingetTool {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string] $Package
    )

    # Short-circuit on presence, like every helper in lib/pkg.sh. It's what
    # makes a tool declared in two sections safe to install twice.
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "  ok $Command"
        return $true
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  SKIP $Command - winget not found" -ForegroundColor Yellow
        Write-Host "    Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Yellow
        return $false
    }

    Write-Host "  installing $Command ($Package)..."

    # | Out-Host, not bare. A native command's stdout joins this function's
    # output stream, so `if (-not (Install-WingetTool ...))` would be testing
    # an array of winget's progress lines with a boolean stapled on the end -
    # non-empty either way, so every failure would read as success. Out-Host
    # writes to the console without entering the pipeline.
    winget install --exact --id $Package --accept-package-agreements --accept-source-agreements | Out-Host

    # $ErrorActionPreference does not apply to native executables, so a failed
    # winget would otherwise be reported as success.
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED $Command - winget exit $LASTEXITCODE" -ForegroundColor Red
        return $false
    }

    Write-Host "  installed $Command" -ForegroundColor Green
    return $true
}

# --- Run -------------------------------------------------------------------

Write-Host ''
Write-Host "Windows dotfiles - $RepoRoot"
Write-Host '-------------------------------------------'

# @() because a single-record result unrolls to a scalar on return, and the
# .Count / -contains checks below would then be measuring the wrong thing.
$records = @(Get-ManifestRecord -Path $Manifest -Platform 'windows')

if ($Sections) {
    $known = @($records | ForEach-Object { $_.Section } | Sort-Object -Unique)
    foreach ($s in $Sections) {
        if ($known -notcontains $s) {
            throw "No windows section named '$s'. Available: $($known -join ', ')"
        }
    }
    $records = @($records | Where-Object { $Sections -contains $_.Section })
}

if ($records.Count -eq 0) {
    Write-Host '  (no windows sections in deps.conf)' -ForegroundColor Yellow
    exit 0
}

$failed = 0

Write-Host ''
Write-Host 'links:'
foreach ($r in ($records | Where-Object { $_.Kind -eq 'link' })) {
    if ($r.Fields.Count -lt 3) {
        Write-Host "  malformed link line in [$($r.Section)]: $($r.Fields -join ' ')" -ForegroundColor Red
        $failed++
        continue
    }
    $src  = Join-Path $RepoRoot ($r.Fields[1].Replace('/', '\'))
    $dest = Resolve-Destination $r.Fields[2]
    if (-not (Install-ConfigLink -Source $src -Destination $dest)) { $failed++ }
}

if ($LinkOnly) {
    Write-Host ''
    Write-Host '-------------------------------------------'
    Write-Host 'Links only (-LinkOnly). Skipped tools.'
    exit $(if ($failed -gt 0) { 1 } else { 0 })
}

Write-Host ''
Write-Host 'tools:'
foreach ($r in ($records | Where-Object { $_.Kind -eq 'tool' })) {
    if ($r.Fields.Count -lt 3) {
        Write-Host "  malformed tool line in [$($r.Section)]: $($r.Fields -join ' ')" -ForegroundColor Red
        $failed++
        continue
    }
    $provider = $r.Fields[1]
    $command  = $r.Fields[2]
    $package  = $command
    if ($r.Fields.Count -ge 4) { $package = $r.Fields[3] }

    if ($provider -ne 'winget') {
        Write-Host "  SKIP $command - provider '$provider' is not available on Windows" -ForegroundColor Yellow
        continue
    }
    if (-not (Install-WingetTool -Command $command -Package $package)) { $failed++ }
}

# Per-section fixups, mirroring how lib/run.sh runs <section>/deps.sh after
# that section's tools. Dot-sourced so it shares this script's strict mode.
#
# Path derived from $RepoRoot, not $PSScriptRoot: the latter is empty when this
# script is run as a scriptblock rather than a file, which would skip the
# fixups in silence - the worst way for them not to run.
$depsScript = Join-Path $RepoRoot 'windows\deps.ps1'
if (Test-Path -LiteralPath $depsScript) {
    Write-Host ''
    Write-Host 'fixups:'
    . $depsScript
}

Write-Host ''
Write-Host '-------------------------------------------'
if (Test-Path -LiteralPath $BackupDir) {
    Write-Host "Backed up existing files to: $BackupDir"
}
if ($failed -gt 0) {
    Write-Host "$failed item(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'Done. Open a new terminal to pick up PATH changes.'
exit 0
