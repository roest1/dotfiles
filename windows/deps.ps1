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

$FontUrl     = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/0xProto.zip'
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
    param([string] $Prefix = '0xProto')

    foreach ($key in @($FontRegKey, 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($name in $props.PSObject.Properties.Name) {
            if ($name -like "$Prefix*") { return $true }
        }
    }
    return $false
}

# The registry value name should be the font's real family name. Read it out of
# the file rather than guessing from "0xProtoNerdFont-Regular.ttf", which would
# need camel-case splitting to get back to "0xProto Nerd Font".
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

function Install-ProtoFont {
    if (Test-FontInstalled) {
        Write-Host '  ok 0xProto Nerd Font'
        return
    }

    $work = Join-Path $env:TEMP ('0xproto-' + [guid]::NewGuid().ToString('N'))
    $zip  = Join-Path $work '0xProto.zip'

    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        Write-Host '  downloading 0xProto Nerd Font...'
        Invoke-WebRequest -Uri $FontUrl -OutFile $zip -UseBasicParsing

        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

        if (-not (Test-Path -LiteralPath $UserFontDir)) {
            New-Item -ItemType Directory -Path $UserFontDir -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $FontRegKey)) {
            New-Item -Path $FontRegKey -Force | Out-Null
        }

        $installed = 0
        foreach ($ttf in (Get-ChildItem -LiteralPath $work -Filter '*.ttf' -Recurse)) {
            $dest = Join-Path $UserFontDir $ttf.Name
            Copy-Item -LiteralPath $ttf.FullName -Destination $dest -Force

            $family = Get-FontFamilyName $dest
            New-ItemProperty -Path $FontRegKey -Name "$family (TrueType)" `
                             -Value $dest -PropertyType String -Force | Out-Null
            $installed++
        }

        if ($installed -gt 0) {
            Write-Host "  installed 0xProto Nerd Font ($installed faces)" -ForegroundColor Green
            Write-Host '    Already-running apps keep the old font list - restart wezterm.'
        }
        else {
            Write-Host '  no .ttf files in the archive - skipping font' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  0xProto Nerd Font failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '    wezterm falls back to JetBrains Mono. Looks worse, works fine.' -ForegroundColor Yellow
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Elevation helper ------------------------------------------------------

<#
    Reports only. wezterm-windows.lua does its own detection at config-eval
    time, so this exists to say why the admin entry will or won't work rather
    than to change anything.
#>
function Show-ElevationStatus {
    $nativeSudo = Join-Path $env:SystemRoot 'System32\sudo.exe'

    if (Test-Path -LiteralPath $nativeSudo) {
        Write-Host '  ok sudo (Windows 11 24H2+)'
        Write-Host '    Elevates in a NEW WINDOW until you run, from an admin console:'
        Write-Host '      sudo config --enable normal'
        Write-Host '    Enable it first at Settings > System > For developers > Enable sudo.'
        return
    }

    if (Get-Command gsudo -ErrorAction SilentlyContinue) {
        Write-Host '  ok gsudo'
        return
    }

    Write-Host '  no elevation helper - the admin launcher entry will not work' -ForegroundColor Yellow
    Write-Host '    Windows 11 24H2+: enable sudo in Settings > System > For developers.'
    Write-Host '    Otherwise uncomment the gsudo line in deps.conf and re-run.'
}

Install-ProtoFont
Show-ElevationStatus
