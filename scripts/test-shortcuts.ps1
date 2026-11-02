# Tests scripts\jarvis.cmd and scripts\install-shortcuts.ps1 in a scratch folder with a fake pnpm and
# cargo, so nothing real is installed or started and your PATH is never touched.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-shortcuts.ps1
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ('jarvis-shortcuts-' + [guid]::NewGuid().ToString('N'))
$fakebin = Join-Path $tmp 'fakebin'
$bin  = Join-Path $tmp 'bin'
$repo = Join-Path $tmp 'JARVIS'
$log  = Join-Path $tmp 'log.txt'
$out  = Join-Path $tmp 'out.txt'
$origPath = $env:Path
$origProfile = $env:USERPROFILE

function Ok([string]$m)   { Write-Host "ok: $m" }
function Fail([string]$m) { throw "FAIL: $m" }
function Invoke-RepoGit { & git -C $repo @args 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Fail "git $args" } }

# Runs a command the way a person would: from another folder, with a chosen PATH.
function Invoke-Jarvis([string]$name, [string]$pathValue) {
    $env:Path = $pathValue
    $env:USERPROFILE = Join-Path $tmp 'home'   # so a real %USERPROFILE%\.cargo\bin is not picked up
    Push-Location $tmp
    try {
        & cmd.exe /d /c "$name > $out 2>&1"
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        $env:Path = $origPath
        $env:USERPROFILE = $origProfile
    }
    [pscustomobject]@{ Code = $code; Out = (Get-Content -LiteralPath $out -Raw) }
}

try {
    New-Item -ItemType Directory -Force -Path $fakebin, "$repo\scripts", (Join-Path $tmp 'home') | Out-Null
    foreach ($tool in 'pnpm', 'cargo') {
        $fake = "@echo off`r`necho %~n0 %* ^| VITE_TRANSPORT=%VITE_TRANSPORT% ^| pwd=%CD% >> `"%FAKE_LOG%`"`r`nexit /b 0`r`n"
        [IO.File]::WriteAllText((Join-Path $fakebin "$tool.cmd"), $fake, (New-Object Text.ASCIIEncoding))
    }
    $env:FAKE_LOG = $log
    Set-Content -LiteralPath $log -Value ''

    # A scratch checkout, so `git pull` and the update checks act on it and not on a real repository.
    Copy-Item "$here\jarvis.cmd", "$here\install-shortcuts.ps1" "$repo\scripts\"
    Invoke-RepoGit init -q -b main
    Invoke-RepoGit add -A
    Invoke-RepoGit -c user.name=t -c user.email=t@t commit -q -m init

    $env:JARVIS_BIN_DIR = $bin
    $env:JARVIS_SKIP_PATH = '1'
    function Install([string[]]$extra) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$repo\scripts\install-shortcuts.ps1" @extra 2>&1 | Out-Null
        $LASTEXITCODE
    }

    # --- install -------------------------------------------------------------------------------
    if ((Install) -ne 0) { Fail 'installer failed' }
    if (-not (Test-Path "$bin\jarvis.cmd") -or -not (Test-Path "$bin\jarvis-mock.cmd")) { Fail 'a command file is missing' }
    Ok 'both commands are written'
    $text = Get-Content -LiteralPath "$bin\jarvis-mock.cmd" -Raw
    if ($text -notlike '*jarvis.cmd" mock*') { Fail "jarvis-mock.cmd does not call the launcher in mock mode: $text" }
    if ((Get-Content -LiteralPath "$bin\jarvis.cmd" -Raw) -notlike '*jarvis.cmd" real*') { Fail 'jarvis.cmd does not call the launcher in real mode' }
    Ok 'each command calls the launcher in the right mode'
    if ((Install) -ne 0) { Fail 'installing a second time failed' }
    Ok 'installing twice works'

    $env:JARVIS_BIN_DIR = Join-Path $tmp 'bin2'
    New-Item -ItemType Directory -Force -Path $env:JARVIS_BIN_DIR | Out-Null
    Set-Content -LiteralPath "$env:JARVIS_BIN_DIR\jarvis.cmd" -Value 'echo not ours'
    if ((Install) -eq 0) { Fail 'the installer overwrote a file it did not write' }
    if ((Get-Content -LiteralPath "$env:JARVIS_BIN_DIR\jarvis.cmd" -Raw) -notlike '*not ours*') { Fail 'the foreign file was changed' }
    Ok 'a command file it did not write is left alone'
    $env:JARVIS_BIN_DIR = $bin

    # --- running it ----------------------------------------------------------------------------
    $path = "$bin;$fakebin;$origPath"
    $r = Invoke-Jarvis 'jarvis' $path
    $logText = Get-Content -LiteralPath $log -Raw
    if ($r.Code -ne 0) { Fail "jarvis exited with $($r.Code): $($r.Out)" }
    if ($logText -notlike '*pnpm tauri dev | VITE_TRANSPORT= | pwd=*\JARVIS*') { Fail "jarvis did not run 'pnpm tauri dev' in the repo: $logText" }
    if ($r.Out -notlike '*starting JARVIS*') { Fail "jarvis banner: $($r.Out)" }
    Ok 'jarvis starts the real app, in the repo, from another folder'
    if ($logText -notlike '*pnpm install --silent*') { Fail 'the install step is missing' }
    Ok 'dependencies are installed first'

    Set-Content -LiteralPath $log -Value ''
    $r = Invoke-Jarvis 'jarvis-mock' $path
    $logText = Get-Content -LiteralPath $log -Raw
    if ($logText -notlike '*pnpm tauri dev | VITE_TRANSPORT=mock*') { Fail "jarvis-mock did not set VITE_TRANSPORT=mock: $logText" }
    if ($r.Out -notlike '*MOCK*') { Fail "jarvis-mock banner: $($r.Out)" }
    Ok 'jarvis-mock starts the mock app'

    # --- updating is only done when it is safe ---------------------------------------------------
    Set-Content -LiteralPath "$repo\file.txt" -Value 'dirty'
    $r = Invoke-Jarvis 'jarvis' $path
    if ($r.Out -notlike '*local changes: not updating*') { Fail "a dirty tree should not update: $($r.Out)" }
    Remove-Item -LiteralPath "$repo\file.txt"
    Ok 'local changes: no update'

    Invoke-RepoGit checkout -q -b feature
    $r = Invoke-Jarvis 'jarvis' $path
    if ($r.Out -notlike "*on branch 'feature', not 'main': not updating*") { Fail "another branch should not update: $($r.Out)" }
    Invoke-RepoGit checkout -q main
    Ok 'another branch: no update'

    $env:JARVIS_NO_UPDATE = '1'
    $r = Invoke-Jarvis 'jarvis' $path
    Remove-Item Env:\JARVIS_NO_UPDATE
    if ($r.Out -notlike '*JARVIS_NO_UPDATE=1*') { Fail "the opt-out was ignored: $($r.Out)" }
    Ok 'JARVIS_NO_UPDATE=1 skips the update'

    $r = Invoke-Jarvis 'jarvis' $path
    if ($r.Out -notlike '*could not update*' -or $r.Code -ne 0) { Fail "a failed update should not stop the app: $($r.Code) $($r.Out)" }
    Ok 'a failed update still starts the app'

    # --- a missing tool is a clear error -----------------------------------------------------------
    $gitDir = Split-Path -Parent (Get-Command git).Source
    $r = Invoke-Jarvis 'jarvis' "$bin;$gitDir;$env:SystemRoot\System32"
    if ($r.Code -eq 0) { Fail 'should fail without pnpm' }
    if ($r.Out -notlike "*'pnpm' was not found*") { Fail "missing-tool message: $($r.Out)" }
    Ok 'a missing tool gives a clear message'

    # --- uninstall -----------------------------------------------------------------------------------
    if ((Install @('-Uninstall')) -ne 0) { Fail 'uninstall failed' }
    if ((Test-Path "$bin\jarvis.cmd") -or (Test-Path "$bin\jarvis-mock.cmd")) { Fail 'uninstall left files behind' }
    Ok 'uninstall removes both commands'

    Write-Host 'All Windows shortcut checks passed.'
} finally {
    $env:Path = $origPath
    $env:USERPROFILE = $origProfile
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
