<#
.SYNOPSIS
    Builds sym and packs a self-contained installer folder (and zip) for a
    machine that has nothing else installed -- in particular no Certo.

.DESCRIPTION
    Run this on a machine that HAS the certo compiler. It:
      1. builds sym.exe and sym_shim.exe from src\
      2. runs the tests against exactly those builds, and refuses to package
         if any fails (use -SkipTests to override)
      3. assembles dist\sym-<date>-<commit>\ holding sym.exe, sym_shim.exe,
         install.cmd, install.ps1, README.txt and BUILD-INFO.txt (commit,
         certo version, SHA-256 of every file)
      4. zips that folder

    Copy the folder or zip to the target PC and run install.cmd there.
    The target needs only Windows; see install.ps1.

.PARAMETER Certo
    The certo compiler to build with. Default: certo on PATH.

.PARAMETER OutDir
    Where to put the package. Default: <repo>\dist (git-ignored).

.PARAMETER SkipTests
    Package without running the tests. Not recommended.

.PARAMETER NoZip
    Leave just the folder.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$OutDir,
    [switch]$SkipTests,
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repo "dist" }

if (-not (Get-Command $Certo -ErrorAction SilentlyContinue)) {
    throw "certo not found ('$Certo'). Building sym needs the Certo compiler -- see docs/USAGE.md step 1. (The machine you install onto does not.)"
}
$certoVersion = ((& $Certo --version) | Out-String).Trim()

function Invoke-Certo([string[]]$CertoArgs, [string]$What) {
    & $Certo @CertoArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

$commit = "unknown"; $dirty = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    $c = (& git -C $repo rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $c) {
        $commit = "$c".Trim()
        $dirty = [bool](& git -C $repo status --porcelain 2>$null)
    }
}
if ($dirty) {
    Write-Warning "Working tree has uncommitted changes -- this package can't be reproduced from commit $commit alone. BUILD-INFO.txt will say so."
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-package-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    Write-Host "Building with $certoVersion..."
    Invoke-Certo @((Join-Path $repo "src\sym_shim.cto"), "-o", (Join-Path $work "sym_shim.exe")) "building sym_shim.exe"
    Invoke-Certo @((Join-Path $repo "src\sym.cto"), "-o", (Join-Path $work "sym.exe")) "building sym.exe"

    if ($SkipTests) {
        Write-Warning "Tests skipped."
    } else {
        Write-Host "`nTesting the built binaries..."
        Invoke-Certo @("test", (Join-Path $repo "src\AtomicWrite.cto")) "AtomicWrite tests"
        Invoke-Certo @("test", (Join-Path $repo "src\Junction.cto")) "Junction tests"
        & (Join-Path $repo "tests\arg-forwarding\run.ps1") -Certo $Certo -ShimExe (Join-Path $work "sym_shim.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "argument-forwarding test failed against the built shim" }
    }

    $name = "sym-{0}-{1}{2}" -f (Get-Date -Format "yyyyMMdd"), $commit, $(if ($dirty) { "-dirty" } else { "" })
    $pkg = Join-Path $OutDir $name
    if (Test-Path -LiteralPath $pkg) { [IO.Directory]::Delete($pkg, $true) }
    New-Item -ItemType Directory -Force $pkg | Out-Null

    Copy-Item (Join-Path $work "sym.exe"), (Join-Path $work "sym_shim.exe") $pkg
    Copy-Item (Join-Path $repo "scripts\install.cmd"), (Join-Path $repo "scripts\install.ps1") $pkg

    Set-Content -LiteralPath (Join-Path $pkg "README.txt") -Encoding ASCII -Value @(
        "sym - install on a machine with nothing else on it",
        "==================================================",
        "",
        "1. If this arrived as a download or email attachment, right-click the",
        "   .zip > Properties > tick Unblock > OK, BEFORE extracting it.",
        "2. Extract the zip anywhere.",
        "3. Double-click install.cmd.",
        "   It installs sym under %LOCALAPPDATA%\Sym and adds it to your user",
        "   PATH. No admin rights, no other software needed.",
        "4. Open a NEW terminal and run:  sym",
        "",
        "To install without changing PATH, run instead:",
        "   powershell -ExecutionPolicy Bypass -File install.ps1",
        "",
        "Re-running install.cmd is safe, and is how you update.",
        "BUILD-INFO.txt records exactly what this package was built from."
    )

    $files = Get-ChildItem -LiteralPath $pkg -File | Where-Object { $_.Name -ne "BUILD-INFO.txt" } | Sort-Object Name
    $info = @(
        "built (UTC) : $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))",
        "commit      : $commit$(if ($dirty) { '  (UNCOMMITTED CHANGES -- not reproducible from this commit)' })",
        "certo       : $certoVersion",
        "tests       : $(if ($SkipTests) { 'SKIPPED' } else { 'passed (AtomicWrite, Junction, arg-forwarding)' })",
        "",
        "sha256:"
    )
    foreach ($f in $files) { $info += ("  {0}  {1}" -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(), $f.Name) }
    Set-Content -LiteralPath (Join-Path $pkg "BUILD-INFO.txt") -Encoding ASCII -Value $info

    if (-not $NoZip) {
        $zip = "$pkg.zip"
        if (Test-Path -LiteralPath $zip) { [IO.File]::Delete($zip) }
        Compress-Archive -Path (Join-Path $pkg "*") -DestinationPath $zip
    }

    Write-Host "`nPackaged: $pkg"
    if (-not $NoZip) { Write-Host "Zip:      $zip" }
    Write-Host "Copy it to the target PC and run install.cmd there."
}
finally {
    [IO.Directory]::Delete($work, $true)
}
