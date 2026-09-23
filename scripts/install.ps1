<#
    Installs sym-shim on a target machine from pre-built binaries: creates
    the Sym\ directory layout and copies sym_shim.exe/sym.exe into place.

    Does NOT build anything and does NOT require the certo compiler on the
    target machine -- that's a dev-time concern (see docs/USAGE.md steps
    1-2 for building sym_shim.exe/sym.exe from source). This script only
    assumes those two files already exist somewhere, defaulting to
    "next to this script's parent folder" -- i.e. ship install.ps1
    alongside sym.exe and sym_shim.exe in a release folder/zip.

    PATH is never touched unless you pass -AddToPath explicitly.
#>
[CmdletBinding()]
param(
    [string]$SymHome = $(if ($env:SYM_HOME) { $env:SYM_HOME } else { Join-Path $env:LOCALAPPDATA "Sym" }),
    [string]$SymShimExe = (Join-Path (Split-Path -Parent $PSScriptRoot) "sym_shim.exe"),
    [string]$SymExe = (Join-Path (Split-Path -Parent $PSScriptRoot) "sym.exe"),
    [switch]$AddToPath
)

$ErrorActionPreference = "Stop"

foreach ($required in @{ "sym_shim.exe" = $SymShimExe; "sym.exe" = $SymExe }.GetEnumerator()) {
    if (-not (Test-Path $required.Value)) {
        throw "$($required.Key) not found at $($required.Value). This script installs pre-built " +
              "binaries only -- build them first (docs/USAGE.md steps 1-2), or pass " +
              "-SymShimExe/-SymExe pointing at where you put them."
    }
}

Write-Host "Installing from:"
Write-Host "  sym_shim.exe: $SymShimExe"
Write-Host "  sym.exe:      $SymExe"

Write-Host "`nCreating layout under $SymHome..."
# sources\ isn't in USAGE.md's "four folders" list (it's only needed once
# you write a source config for fetch-based installs), but pre-creating it
# here is harmless and saves a manual step later.
foreach ($sub in "shim", "bin", "shims", "packages", "sources") {
    $path = Join-Path $SymHome $sub
    New-Item -ItemType Directory -Force $path | Out-Null
    Write-Host "  $path"
}

$shimDest = Join-Path $SymHome "shim\sym_shim.exe"
Copy-Item $SymShimExe $shimDest -Force
Write-Host "`nsym_shim.exe -> $shimDest"

$symExeDest = Join-Path $SymHome "sym.exe"
Copy-Item $SymExe $symExeDest -Force
Write-Host "sym.exe -> $symExeDest"

$binDir = Join-Path $SymHome "bin"
if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @($userPath -split ";" | Where-Object { $_ -ne "" })
    # Both are needed once sym.exe lives inside Sym\ itself: bin\ so
    # shimmed tools resolve, Sym\ so the `sym` command itself resolves.
    $wanted = @($SymHome, $binDir) | Where-Object { $entries -notcontains $_ }
    if ($wanted.Count -eq 0) {
        Write-Host "`n$SymHome and $binDir already on user PATH"
    } else {
        $newPath = ($entries + $wanted) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "`nAdded to user PATH (open a new shell to pick it up):"
        $wanted | ForEach-Object { Write-Host "  $_" }
    }
} else {
    Write-Host "`nNOT modifying PATH. Add these yourself, or re-run with -AddToPath:"
    Write-Host "  $SymHome   (so the 'sym' command resolves)"
    Write-Host "  $binDir   (so shimmed tools resolve)"
}

Write-Host "`nDone. Next steps (see docs/USAGE.md sections 4 and 6):"
Write-Host "  sym install <package> <version> <source-file> [<command-filename>]"
Write-Host "  sym shim add <name> <package> <version>"
