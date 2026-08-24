<#
    [windows] platform fixups - the counterpart to wezterm/deps.sh.

    Dot-sourced by windows/install.ps1 after that section's tools, the same way
    lib/run.sh runs <section>/deps.sh after its tools. Inherits the caller's
    Set-StrictMode and $ErrorActionPreference, so it must not call `exit` -
    that would take install.ps1's summary down with it.

    Everything here is a downgrade if it fails, never a breakage: without the
    font wezterm falls back to JetBrains Mono, and without an elevation helper
    the admin launcher entry is the only thing that stops working.
#>

# One row per Nerd Font this host has to carry. Archive is the nerd-fonts
# release asset name; Prefix is how the installed faces are named in the
# registry, which is what the already-installed check matches on.
#
# JetBrainsMono is here because wezterm/shared.lua names it as the default
# `nvim.editor` lane. Without it wezterm falls back AND raises a toast on every
# single launch -- "Unable to load a font matching one of your font_rules" --
# which is the first thing a new Windows install would show you.
#
# wezterm bundles a plain 'JetBrains Mono', which is the same typeface WITHOUT
# the patched icons, so the fallback is not equivalent and the warning is
# correct. wezterm/deps.sh installs this same pair on Linux and macOS; the two
# lists are asserted against each other in CI, because nothing else reads both.
# Science Gothic -- the PROPORTIONAL family, not the monospaced cut this repo
# generates. wezterm/shared.lua names it as window_frame.font, which is the face
# the tab bar is drawn in, so without it the Windows tab bar silently falls
# through the chain to 0xProto and looks nothing like the same terminal on
# Linux.
#
# Not a Nerd Font, so it is not a zip and does not come from the nerd-fonts
# release pattern: it is one variable .ttf out of google/fonts, the same source
# wezterm/deps.sh pulls it from. The bracketed axis list in the filename is
# URL-encoded, which is why this is a literal rather than something built from
# the family name.
$SingleFonts = @(
    @{
        Prefix = 'Science Gothic'
        File   = 'ScienceGothic.ttf'
        Url    = 'https://raw.githubusercontent.com/google/fonts/main/ofl/sciencegothic/ScienceGothic%5BCTRS,slnt,wdth,wght%5D.ttf'
    }
)

$FontBaseUrl = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download'
$NerdFonts   = @(
    @{ Archive = '0xProto';       Prefix = '0xProto' },
    @{ Archive = 'JetBrainsMono'; Prefix = 'JetBrainsMono' }
)
$FontRegKey  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$UserFontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'

# --- 0xProto Nerd Font -----------------------------------------------------

<#
    Per-user install: copy into %LOCALAPPDATA%\Microsoft\Windows\Fonts and
    register under HKCU. That path needs no admin, which matters because the
    whole point of this script is that it runs unelevated.

    Not the Shell.Application "Fonts folder" COM route, which is the usual
    recipe: it can raise a modal dialog, and a modal dialog on Windows blocks
    the console that spawned it.
#>
function Test-FontInstalled {
    param([Parameter(Mandatory = $true)][string] $Prefix)

    foreach ($key in @($FontRegKey, 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -like "$Prefix*") { return $true }
        }
    }
    return $false
}

# The registry value name must be unique PER FACE, not per family, and that is
# the whole reason this function is not enough on its own.
#
# Windows keys HKCU font registrations by that name. Registering every face of a
# family under "JetBrainsMono Nerd Font (TrueType)" means each -Force write
# overwrites the last, so 16 files on disk left ONE face registered and wezterm
# reported:
#
#   Unable to load a font matching one of your font_rules:
#   wezterm.font('JetBrainsMono Nerd Font', {weight="Regular", style=Italic})
#
# Get-FontFaceName below appends the style, so Regular keeps the bare family
# name (which is what Windows expects for the base face) and every other face
# gets its own row.
function Get-FontFamilyName {
    param([string] $Path)

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $collection = New-Object System.Drawing.Text.PrivateFontCollection
        $collection.AddFontFile($Path)
        $name = $collection.Families[0].Name
        $collection.Dispose()
        if ($name) { return $name }
    }
    catch {
        # System.Drawing.Common is not guaranteed present under PowerShell 7,
        # where it is a NuGet package rather than part of the framework.
    }
    return [IO.Path]::GetFileNameWithoutExtension($Path)
}

# Registers a set of .ttf files, one registry row per face. Returns the count.
#
# Split out because it has TWO callers with different reasons to run: a fresh
# download, and a repair pass over faces already on disk. The repair matters --
# a run before the per-face naming fix left a whole family collapsed into one
# row, and re-registering is what fixes that without anyone editing the registry
# by hand.
function Register-FontFiles {
    param([Parameter(Mandatory = $true)] $Files)

    $n = 0
    foreach ($ttf in $Files) {
        $family = Get-FontFamilyName $ttf.FullName
        $face   = Get-FontFaceName -Family $family -BaseName $ttf.BaseName
        New-ItemProperty -Path $FontRegKey -Name "$face (TrueType)" `
                         -Value $ttf.FullName -PropertyType String -Force | Out-Null
        $n++
    }
    return $n
}

# family + style, so each face gets its own registry row.
#
# The style comes from the filename suffix rather than the font tables:
# System.Drawing exposes FontFamily.Name (the family) but no reliable per-FILE
# subfamily, and every nerd-fonts and google/fonts asset this repo installs is
# named Family-Style.ttf. When there is no suffix -- ScienceGothic.ttf -- the
# bare family name is correct, because that file IS the base face.
function Get-FontFaceName {
    param(
        [Parameter(Mandatory = $true)][string] $Family,
        [Parameter(Mandatory = $true)][string] $BaseName
    )

    $style = ''
    if ($BaseName -match '-([A-Za-z]+)$') { $style = $Matches[1] }

    if (-not $style -or $style -eq 'Regular') { return $Family }
    return "$Family $style"
}

function Install-NerdFont {
    param(
        [Parameter(Mandatory = $true)][string] $Archive,
        [Parameter(Mandatory = $true)][string] $Prefix
    )

    # Already on disk from an earlier run? Re-register rather than re-download.
    # Registration is cheap and idempotent, and running it again is what repairs
    # a family that an older version of this script collapsed into a single row.
    $onDisk = @(Get-ChildItem -LiteralPath $UserFontDir -Filter "$Prefix*.ttf" -ErrorAction SilentlyContinue)
    if ($onDisk.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $FontRegKey)) {
            New-Item -Path $FontRegKey -Force | Out-Null
        }
        $n = Register-FontFiles -Files $onDisk
        Write-Host "  ok $Archive Nerd Font ($n faces registered)"
        return
    }

    $work = Join-Path $env:TEMP ($Archive + '-' + [guid]::NewGuid().ToString('N'))
    $zip  = Join-Path $work ($Archive + '.zip')

    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        Write-Host "  downloading $Archive Nerd Font..."
        Invoke-WebRequest -Uri "$FontBaseUrl/$Archive.zip" -OutFile $zip -UseBasicParsing

        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

        if (-not (Test-Path -LiteralPath $UserFontDir)) {
            New-Item -ItemType Directory -Path $UserFontDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $FontRegKey)) {
            New-Item -Path $FontRegKey -Force | Out-Null
        }

        $copied = @()
        foreach ($ttf in (Get-ChildItem -LiteralPath $work -Filter '*.ttf' -Recurse)) {
            $dest = Join-Path $UserFontDir $ttf.Name
            Copy-Item -LiteralPath $ttf.FullName -Destination $dest -Force
            $copied += (Get-Item -LiteralPath $dest)
        }
        $installed = 0
        if ($copied.Count -gt 0) { $installed = Register-FontFiles -Files $copied }

        if ($installed -gt 0) {
            Write-Host "  installed $Archive Nerd Font ($installed faces)" -ForegroundColor Green
            Write-Host '    Already-running apps keep the old font list - restart wezterm.'
        }
        else {
            Write-Host '  no .ttf files in the archive - skipping font' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  $Archive Nerd Font failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    wezterm falls back and warns on launch. Looks worse, works fine.' -ForegroundColor Yellow
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-FontFile {
    param(
        [Parameter(Mandatory = $true)][string] $Prefix,
        [Parameter(Mandatory = $true)][string] $File,
        [Parameter(Mandatory = $true)][string] $Url
    )

    # Same repair-not-skip rule as Install-NerdFont above.
    $dest = Join-Path $UserFontDir $File
    if (Test-Path -LiteralPath $dest) {
        if (-not (Test-Path -LiteralPath $FontRegKey)) {
            New-Item -Path $FontRegKey -Force | Out-Null
        }
        Register-FontFiles -Files @(Get-Item -LiteralPath $dest) | Out-Null
        Write-Host "  ok $Prefix"
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $UserFontDir)) {
            New-Item -ItemType Directory -Path $UserFontDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $FontRegKey)) {
            New-Item -Path $FontRegKey -Force | Out-Null
        }

        Write-Host "  downloading $Prefix..."
        Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing

        $family = Get-FontFamilyName $dest
        $face   = Get-FontFaceName -Family $family -BaseName ([IO.Path]::GetFileNameWithoutExtension($File))
        New-ItemProperty -Path $FontRegKey -Name "$face (TrueType)" `
                         -Value $dest -PropertyType String -Force | Out-Null

        Write-Host "  installed $Prefix" -ForegroundColor Green
        Write-Host '    Already-running apps keep the old font list - restart wezterm.'
    }
    catch {
        Write-Host "  $Prefix failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    The tab bar falls back to 0xProto. Looks different, works fine.' -ForegroundColor Yellow
    }
}

# --- wezterm font lanes ----------------------------------------------------

# There used to be a Show-WeztermFloor here, reading wezterm\MIN_VERSION, and
# it was the wrong shape on both platforms. It inferred the ONE thing no
# program can prove -- whether this binary applies font_rules on the blink
# attribute at draw time -- from a build stamp, and it could not fail safe:
# every build at or above the floor passed untested, so the silent failure it
# existed to catch survived inside its own green tick.
#
# The answerable half (font files, the config link, what ls-fonts resolved) is
# reported by `make status wezterm` in the WSL guest. The half only an eye can
# read is the carrier line in `font`. Neither needs a number maintained here.


# --- Elevation helper ------------------------------------------------------

<#
    Reports only. wezterm-windows.lua does its own detection at config-eval
    time, so this exists to say why the admin entry will or won't work rather
    than to change anything.

    sudo.exe SHIPS IN System32 on Windows 11 24H2+ whether or not the feature
    is switched on, so Test-Path on the binary answers "did Microsoft ship it",
    not "will it run". Testing the binary reported `ok sudo (Windows 11 24H2+)`
    on a machine with Enable sudo switched OFF - a green line for something
    that then fails at the point of use, which is the one outcome this file is
    supposed to prevent.

    The feature switch lives in the registry. Mode names are reported from the
    raw value rather than assumed, so an unrecognised value prints itself
    instead of being silently mapped to the wrong label.
#>
function Get-SudoState {
    $state = @{
        Present = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\sudo.exe'))
        Enabled = $false
        Mode    = 'disabled'
        Raw     = $null
    }

    $key  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'
    $prop = Get-ItemProperty -Path $key -Name 'Enabled' -ErrorAction SilentlyContinue
    if (-not $prop) { return $state }

    $state.Raw = $prop.Enabled
    if ($prop.Enabled -eq 0) { return $state }

    $state.Enabled = $true
    switch ($prop.Enabled) {
        1 { $state.Mode = 'new window' }
        2 { $state.Mode = 'inline, input closed' }
        3 { $state.Mode = 'inline' }
        default { $state.Mode = "enabled (unrecognised mode $($prop.Enabled))" }
    }
    return $state
}

function Show-ElevationStatus {
    $sudo = Get-SudoState

    if ($sudo.Enabled) {
        Write-Host "  ok sudo - $($sudo.Mode)"
        if ($sudo.Mode -ne 'inline') {
            Write-Host '    That elevates in a NEW WINDOW. For the current pane instead,'
            Write-Host '    run this once from an admin console:'
            Write-Host '      sudo config --enable normal'
        }
        return
    }

    if (Get-Command gsudo -ErrorAction SilentlyContinue) {
        Write-Host '  ok gsudo'
        return
    }

    if ($sudo.Present) {
        Write-Host '  sudo.exe is present but the feature is OFF' -ForegroundColor Yellow
        Write-Host '    The binary ships with the OS; the feature is a separate switch.' -ForegroundColor Yellow
        Write-Host '    Turn it on:  start ms-settings:developers' -ForegroundColor Yellow
        Write-Host '    (Settings > System > Advanced > Terminal > Enable sudo)' -ForegroundColor Yellow
        Write-Host '    Until then the PowerShell (Admin) entry still APPEARS in the' -ForegroundColor Yellow
        Write-Host '    picker and fails when used: wezterm-windows.lua tests for the' -ForegroundColor Yellow
        Write-Host '    binary, and cannot read this switch without spawning a process' -ForegroundColor Yellow
        Write-Host '    on every config evaluation. sudo says why when you hit it.' -ForegroundColor Yellow
        return
    }

    Write-Host '  no elevation helper - the admin launcher entry will not work' -ForegroundColor Yellow
    Write-Host '    Windows 11 24H2+: enable sudo at  start ms-settings:developers'
    Write-Host '    Otherwise uncomment the gsudo line in windows\install.ps1 and re-run.'
}

foreach ($nf in $NerdFonts) {
    Install-NerdFont -Archive $nf.Archive -Prefix $nf.Prefix
}
foreach ($sf in $SingleFonts) {
    Install-FontFile -Prefix $sf.Prefix -File $sf.File -Url $sf.Url
}
Show-ElevationStatus
