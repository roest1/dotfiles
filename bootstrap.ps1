<#
    bootstrap.ps1 - one-line entry point for a fresh Windows machine.

        irm https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.ps1 | iex

    The Windows counterpart to bootstrap.sh, and the same chicken-and-egg: you
    need the repo before you can run anything in it. Installs git if missing,
    clones over HTTPS, hands off to windows\install.ps1.

    This sets up the WINDOWS HOST - wezterm and its config. It does not touch
    WSL. If you use both, run this from PowerShell and bootstrap.sh from inside
    your distro; they configure two different environments that happen to share
    a repo.

    Scope it with environment variables, set before the pipe:

        $env:DOTFILES_DIR    = 'D:\src\dotfiles'   # default %USERPROFILE%\dotfiles
        $env:DOTFILES_REPO   = 'https://...'       # default this repo
        $env:DOTFILES_TARGET = 'link'              # symlinks only, no winget

    Targets Windows PowerShell 5.1 - that is what a fresh box runs, and this
    file has to work there before it is allowed to be elegant.
#>

# The entire body is a scriptblock so that `return` and any `throw` unwind to
# here. Piped into iex, a top-level `exit` would terminate the user's shell,
# which is a hostile way to report that git could not be found.
& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # 5.1 on older builds still negotiates TLS 1.0, which GitHub rejects.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repoUrl = $env:DOTFILES_REPO
    if (-not $repoUrl) { $repoUrl = 'https://github.com/roest1/dotfiles.git' }

    $dotfilesDir = $env:DOTFILES_DIR
    if (-not $dotfilesDir) { $dotfilesDir = Join-Path $env:USERPROFILE 'dotfiles' }

    $linkOnly = ($env:DOTFILES_TARGET -eq 'link')

    Write-Host ''
    Write-Host 'dotfiles bootstrap (Windows)'
    Write-Host '-------------------------------------------'
    Write-Host "  repo:   $repoUrl"
    Write-Host "  dest:   $dotfilesDir"
    if ($linkOnly) { Write-Host '  target: links only' } else { Write-Host '  target: install' }
    Write-Host ''

    # --- git ---------------------------------------------------------------

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host 'git not found - installing...'

        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw 'Neither git nor winget is available. Install Git for Windows from https://git-scm.com/download/win and re-run.'
        }

        winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install git (exit $LASTEXITCODE)."
        }

        # A freshly installed tool is on the machine's PATH but not on this
        # process's - that is inherited at launch and never refreshed. Rebuild
        # it from the registry rather than telling the user to reopen a shell
        # halfway through a bootstrap.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')

        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw 'git installed but still not on PATH. Open a new terminal and re-run.'
        }
    }

    # --- clone or update ---------------------------------------------------

    if (Test-Path -LiteralPath (Join-Path $dotfilesDir '.git')) {
        Write-Host 'Already cloned - pulling latest...'
        git -C $dotfilesDir pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  (pull skipped - local changes or diverged branch)' -ForegroundColor Yellow
        }
    }
    else {
        if (Test-Path -LiteralPath $dotfilesDir) {
            throw "$dotfilesDir exists but is not a git repo. Move it aside and re-run."
        }
        git clone $repoUrl $dotfilesDir
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed (exit $LASTEXITCODE)."
        }
    }

    # --- hand off ----------------------------------------------------------

    $installScript = Join-Path $dotfilesDir 'windows\install.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Clone succeeded but $installScript is missing."
    }

    # A child process with -ExecutionPolicy Bypass, rather than dot-sourcing.
    # Windows client machines default to Restricted, under which a cloned .ps1
    # will not run at all - and this way install.ps1 keeps a real $PSScriptRoot
    # and its exit code arrives in $LASTEXITCODE instead of unwinding through
    # a scriptblock.
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    if ($linkOnly) {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $installScript -RepoRoot $dotfilesDir -LinkOnly
    }
    else {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $installScript -RepoRoot $dotfilesDir
    }
    $rc = $LASTEXITCODE

    Write-Host ''
    Write-Host '-------------------------------------------'
    if ($rc -ne 0) {
        Write-Host "Bootstrap finished with errors (exit $rc)." -ForegroundColor Red
        return
    }
    Write-Host 'Bootstrap complete. Launch wezterm from the Start menu.'
    Write-Host 'CTRL+SHIFT+O opens the shell picker.'
    Write-Host ''
}
