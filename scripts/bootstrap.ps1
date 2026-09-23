<#
    Bootstraps sym-shim on a fresh machine: builds sym_shim.exe and sym.exe
    from source, creates the Sym\ directory layout, and copies sym_shim.exe
    into place. This automates steps 1-3 of docs/USAGE.md -- read that file
    for what each step actually does and why.

    PATH is never touched unless you pass -AddToPath explicitly; adding
    Sym\bin to PATH is the one PATH change sym-shim ever needs.
#>
[CmdletBinding()]
param(
    [string]$SymHome = $(if ($env:SYM_HOME) { $env:SYM_HOME } else { Join-Path $env:LOCALAPPDATA "Sym" }),
    [switch]$AddToPath,
    # Pinned in docs/USAGE.md step 1 -- the commit sym.cto/sym_shim.cto are
    # verified to build against. Re-pin here (and in USAGE.md) together,
    # only after confirming both .cto files still build cleanly.
    [string]$CertoRev = "9cf8298ffb91fb01203bd292a110607134de9d2e"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Certo {
    $existing = Get-Command certo -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "certo found on PATH ($($existing.Source)): $(certo --version)"
        Write-Host "  (pinned build commit is $CertoRev -- certo --version doesn't embed the" -ForegroundColor DarkGray
        Write-Host "   commit hash, so this isn't verified automatically; see USAGE.md step 1)" -ForegroundColor DarkGray
        return
    }
    Write-Host "certo not found on PATH -- building it from source (pinned commit $CertoRev)..."
    cargo install --git https://github.com/rjreeves/Certo --rev $CertoRev certo
    if (-not (Get-Command certo -ErrorAction SilentlyContinue)) {
        throw "certo still not found on PATH after cargo install -- check that ~\.cargo\bin is on PATH"
    }
}

Assert-Certo

Write-Host "`nBuilding sym_shim.exe and sym.exe from $repoRoot..."
Push-Location $repoRoot
try {
    & certo src/sym_shim.cto -o sym_shim.exe
    & certo src/sym.cto -o sym.exe
} finally {
    Pop-Location
}

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
Copy-Item (Join-Path $repoRoot "sym_shim.exe") $shimDest -Force
Write-Host "`nsym_shim.exe -> $shimDest"

$symExe = Join-Path $repoRoot "sym.exe"
Write-Host "sym.exe built at $symExe"
Write-Host "  (not part of the Sym\ layout -- USAGE.md says keep it wherever's" -ForegroundColor DarkGray
Write-Host "   convenient on your own PATH; this script doesn't move it for you)" -ForegroundColor DarkGray

$binDir = Join-Path $SymHome "bin"
if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @($userPath -split ";" | Where-Object { $_ -ne "" })
    if ($entries -contains $binDir) {
        Write-Host "`n$binDir already on user PATH"
    } else {
        $newPath = ($entries + $binDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "`nAdded $binDir to user PATH (open a new shell to pick it up)"
    }
} else {
    Write-Host "`nNOT modifying PATH. Add this to your PATH yourself, or re-run with -AddToPath:"
    Write-Host "  $binDir"
}

Write-Host "`nDone. Next steps (see docs/USAGE.md sections 4 and 6):"
Write-Host "  sym install <package> <version> <source-file> [<command-filename>]"
Write-Host "  sym shim add <name> <package> <version>"
