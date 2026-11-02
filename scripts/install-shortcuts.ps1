# Installs the `jarvis` and `jarvis-mock` commands on Windows.
#   scripts\install-shortcuts.cmd              install
#   scripts\install-shortcuts.cmd -Uninstall   remove
#
# It writes two small .cmd files into %USERPROFILE%\.local\bin that call scripts\jarvis.cmd in this
# checkout, and adds that folder to YOUR PATH (the user-level one, never the system one) if it is not
# there yet. It will not overwrite a file of the same name that it did not write. Run it again if you
# move the checkout. ASCII only on purpose: Windows PowerShell 5 reads files without a BOM as ANSI.
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo   = (Resolve-Path (Join-Path $here '..')).Path
$bin    = if ($env:JARVIS_BIN_DIR) { $env:JARVIS_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$marker = 'rem JARVIS shortcut written by scripts\install-shortcuts.ps1'
$stubs  = @{ 'jarvis.cmd' = 'real'; 'jarvis-mock.cmd' = 'mock' }

function Test-Ours([string]$path) {
    (Test-Path $path) -and ((Get-Content -LiteralPath $path -Raw) -like "*$marker*")
}

if ($Uninstall) {
    foreach ($name in $stubs.Keys) {
        $p = Join-Path $bin $name
        if (Test-Ours $p) { Remove-Item -LiteralPath $p -Force }
        elseif (Test-Path $p) { Write-Host "Left $p alone: JARVIS did not write it." }
    }
    Write-Host "Removed jarvis and jarvis-mock from $bin."
    Write-Host "The folder stays on your PATH; that is harmless. Remove it in Settings > System > About > Advanced system settings > Environment Variables if you like."
    exit 0
}

if ($repo -match '[^\x20-\x7E]') {
    throw "The folder $repo has characters that batch files cannot read reliably. Move the checkout to a folder with a plain name (letters, digits, spaces), then run this again."
}
# Check everything before writing anything, so a refusal never leaves half an install behind.
foreach ($name in $stubs.Keys) {
    $p = Join-Path $bin $name
    if ((Test-Path $p) -and -not (Test-Ours $p)) {
        throw "$p already exists and was not written by JARVIS. Move or delete it, then run this again."
    }
}
New-Item -ItemType Directory -Force -Path $bin | Out-Null
foreach ($name in $stubs.Keys) {
    $p = Join-Path $bin $name
    $mode = $stubs[$name]
    $lines = @('@echo off', $marker, ('call "{0}\scripts\jarvis.cmd" {1} %*' -f $repo, $mode), 'exit /b %ERRORLEVEL%')
    [IO.File]::WriteAllText($p, (($lines -join "`r`n") + "`r`n"), (New-Object Text.ASCIIEncoding))
}
Write-Host "Wrote $bin\jarvis.cmd and $bin\jarvis-mock.cmd -> $repo\scripts\jarvis.cmd"

if ($env:JARVIS_SKIP_PATH -eq '1') {
    Write-Host "Not touching PATH (JARVIS_SKIP_PATH=1)."
} else {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries  = @($userPath -split ';' | Where-Object { $_ -ne '' })
    $want     = $bin.TrimEnd('\')
    if ($entries | Where-Object { $_.TrimEnd('\') -ieq $want }) {
        Write-Host "$bin is already on your PATH."
    } else {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $bin) -join ';'), 'User')
        Write-Host "Added $bin to your PATH."
    }
}

# A PowerShell alias or function of the same name beats a command file, so an old one would hide the new command.
if ($PROFILE -and (Test-Path $PROFILE) -and (Select-String -Path $PROFILE -Pattern '^\s*(function\s+jarvis|Set-Alias\s+(-Name\s+)?jarvis|New-Alias\s+(-Name\s+)?jarvis)' -Quiet)) {
    Write-Host ''
    Write-Host "Heads up: $PROFILE still defines an old 'jarvis' function or alias, which takes priority."
    Write-Host 'Delete those lines, then open a new terminal window.'
}

Write-Host ''
Write-Host 'Open a NEW terminal window (PowerShell or Command Prompt), then type:  jarvis   or   jarvis-mock'
