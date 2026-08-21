#Requires -Version 5.1
<#
.SYNOPSIS
    Links config and installs tools for the Windows host.

.DESCRIPTION
    The Windows payload is declared in the two tables below rather than parsed
    out of deps.conf, and that is a deliberate reversal.

    This script used to reimplement the manifest parser in PowerShell - comment
    stripping, section headers, a two-pass read so a `platform` line below a
    `link` line could not silently drop it - so that "nothing else enumerates
    the links" held across both entry points. That cost about 130 lines to
    describe one symlink and one winget package, and the parity it bought was
    always partial: the two parsers read `platform` with opposite defaults
    precisely because a shared reading would have linked bashrc into
    %USERPROFILE%.

    Declaring the payload here removes the second parser, the `platform`
    mechanism that existed to arbitrate between the two, and the class of bug
    where the parsers disagree about the same file. The cost is stated plainly:
    adding a Windows config is now an edit to this file instead of to
    deps.conf. The section held one link and one tool for its entire life, so
    that trade is worth the deletion.

    Targets Windows PowerShell 5.1, not just PowerShell 7 - 5.1 is what a
    fresh Windows box runs when you paste the bootstrap line. So: no ternary
    operators, no null-coalescing, no $IsWindows, and Join-Path takes exactly
    two arguments.

.PARAMETER RepoRoot
    The dotfiles clone. Defaults to this script's parent directory, which is
    absent when the script is run as a scriptblock (bootstrap.ps1 does that to
    sidestep the execution policy), so bootstrap passes it explicitly.

.PARAMETER LinkOnly
    Symlinks only - no winget, no downloads. The analogue of `make link`, for
    a machine where you can't install anything but still want your config.

.EXAMPLE
    .\windows\install.ps1
    .\windows\install.ps1 -LinkOnly
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $LinkOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 5.1 on older builds negotiates TLS 1.0 by default, which GitHub refuses.
# Harmless where the default is already sane.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- The Windows payload ---------------------------------------------------
#
# Source is relative to the repo, Destination relative to %USERPROFILE%. Both
# use backslashes: nothing translates them any more, because nothing is
# reading paths written for the bash side.
#
# wezterm-windows.lua is a different file for a different job, not a variant of
# wezterm/wezterm.lua. It configures wezterm.exe on the host, whose purpose is
# to get you into WSL; it declares no unix_domains, because that socket path
# belongs to a process inside the guest.

# The fonts directory carries Science Gothic Mono, which `make` output inside
# WSL is rendered in -- the guest emits the escape, but wezterm.exe out here
# does the drawing, so the font has to exist on THIS side. It is read via
# font_dirs in wezterm-windows.lua rather than installed into the Windows font
# store, which keeps it to one copy that tracks the repo.
$Links = @(
    @{ Source = 'wezterm\wezterm-windows.lua'; Destination = '.config\wezterm\wezterm.lua' },
    @{ Source = 'wezterm\fonts';               Destination = '.config\wezterm\fonts' }
)

# Elevation helper, off by default. Windows 11 24H2+ ships `sudo` in System32
# and wezterm-windows.lua prefers it when present. Uncomment the gsudo entry
# below on Windows 10, or if you'd rather not run `sudo config --enable normal`
# for inline elevation.
#
# It has to stay INSIDE the array. A hashtable uncommented above the assignment
# is a statement rather than an element: PowerShell would write it to the output
# stream, print it to the console, and install nothing - which reads as "I
# enabled gsudo and it silently didn't work".
$WingetTools = @(
    @{ Command = 'wezterm'; Package = 'wez.wezterm' }
    # @{ Command = 'gsudo';   Package = 'gerardog.gsudo' }
)

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
$BackupDir = Join-Path $env:USERPROFILE ('.dotfiles_backup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))

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
        # Second attempt, via cmd's mklink, and it is not redundant.
        #
        # Windows PowerShell 5.1's New-Item does not pass
        # SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE, so it is refused even
        # with Developer Mode ON unless the shell is elevated - which this
        # script deliberately is not. mklink does pass that flag, and has since
        # Windows 10 1703. PowerShell 7's New-Item does too, which is why this
        # only bites on the edition a fresh box actually runs.
        #
        # Found on a real machine: Developer Mode on, and every link still fell
        # through to the copy. Each path is passed as its own argument so
        # PowerShell quotes it - "C:\Users\Riley Oest\..." has a space in it,
        # and building one command string would have needed hand-quoting.
        $linked = $false
        try {
            if (Test-Path -LiteralPath $Source -PathType Container) {
                & cmd.exe /c mklink /D $Destination $Source 2>&1 | Out-Null
            }
            else {
                & cmd.exe /c mklink $Destination $Source 2>&1 | Out-Null
            }
            $linked = ($LASTEXITCODE -eq 0)
        }
        catch {
            $linked = $false
        }

        if ($linked) {
            Write-Host "  linked $Destination -> $Source (mklink)"
            return $true
        }

        # A directory source needs -Recurse. Without it Copy-Item creates an
        # empty folder and reports success, so wezterm\fonts would arrive with
        # no fonts in it and the terminal would quietly fall back.
        if (Test-Path -LiteralPath $Source -PathType Container) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
        }
        Write-Host "  copied $Destination (both link routes denied)" -ForegroundColor Yellow
        Write-Host "    Turn on Developer Mode, then re-run to get a link that tracks" -ForegroundColor Yellow
        Write-Host "    the repo. Until then this is a copy: editing the repo will not" -ForegroundColor Yellow
        Write-Host "    change it. To open the right page on any Windows build:" -ForegroundColor Yellow
        Write-Host "      start ms-settings:developers" -ForegroundColor Yellow
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

$failed = 0

Write-Host ''
Write-Host 'links:'
foreach ($link in $Links) {
    $src  = Join-Path $RepoRoot $link.Source
    $dest = Join-Path $env:USERPROFILE $link.Destination
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
foreach ($tool in $WingetTools) {
    if (-not (Install-WingetTool -Command $tool.Command -Package $tool.Package)) { $failed++ }
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
