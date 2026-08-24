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
# shared.lua carries the half of the config that is identical on both platforms.
# wezterm-windows.lua dofile()s it out of its own config_dir, so it has to land
# NEXT TO the config rather than be reached for in the repo. The Linux half is
# the matching link line in deps.conf's [wezterm] section; drop either and that
# platform silently falls back to an unstyled terminal.
$Links = @(
    @{ Source = 'wezterm\wezterm-windows.lua'; Destination = '.config\wezterm\wezterm.lua' },
    @{ Source = 'wezterm\shared.lua';          Destination = '.config\wezterm\shared.lua' },
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
#
# wez.wezterm.nightly, NOT wez.wezterm, and the .nightly is not a channel
# preference -- it is the only package that can run this repo's config.
#
# wez.wezterm tops out at 20240203, the last tagged release, from February
# 2024. Upstream never stopped developing; it stopped TAGGING. main is 900+
# commits and 30+ contributors past that tag and gets pushed daily, and every
# one of those fixes ships only through the nightly. There is no maintained
# stable branch to prefer, so installing wez.wezterm here would pin the host
# to a binary that predates font_rules matching the blink attribute -- which
# is to say the SGR 6 and SGR 5 lanes render in the base font, silently.
#
# Note that this is an ID, not a --version. The nightlies are a separate
# winget package; `--id wez.wezterm --version nightly` simply fails. Both are
# built by the same ci/deploy.sh on the same GitHub-hosted runners and publish
# a .sha256 next to the installer, so the provenance is identical -- what
# differs is the trigger.
#
# You cannot pin a historical nightly. Upstream uploads with `gh release
# upload --clobber nightly`, so the asset URL is rolling; winget's archived
# dated manifests pin a SHA256 against that same rolling URL and stop
# resolving the moment a newer build lands. Keep the setup .exe you installed
# from if you want a rollback -- that is the only one there is.
$WingetTools = @(
    @{ Command = 'wezterm'; Package = 'wez.wezterm.nightly' }
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
    $rc = $LASTEXITCODE

    # A freshly installed tool is on the machine's PATH but not on this
    # process's - that is inherited at launch and never refreshed. Rebuild it
    # the same way bootstrap.ps1 does after installing git, so the check below
    # sees what a new shell would see.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    # Trust the tool, not the installer's exit code - the same rule
    # lib/providers.sh follows, and for a sharper reason here.
    #
    # winget reports "already installed, no upgrade available" as a FAILURE:
    # exit 0x8A15002B / -1978335189, APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE.
    # That is not a failure, it is the state this function exists to reach. It
    # shows up on any re-run where the shell's PATH predates the install, so
    # `Get-Command` misses wezterm, winget is asked to install it again, and
    # says it is already current. The whole run then reports "1 item(s) failed"
    # for a machine that is correctly set up.
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "  installed $Command" -ForegroundColor Green
        return $true
    }

    # Same conclusion without needing $Command on PATH - some packages install
    # a binary this shell still cannot see until it restarts.
    if ($rc -eq -1978335189) {
        Write-Host "  ok $Command (already installed and current)"
        return $true
    }

    # $ErrorActionPreference does not apply to native executables, so a failed
    # winget would otherwise be reported as success.
    if ($rc -ne 0) {
        Write-Host "  FAILED $Command - winget exit $rc" -ForegroundColor Red
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
