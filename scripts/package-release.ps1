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
      5. with -CopyTo, also copies the package's files into a folder you
         already ship (e.g. a bundle's bin\), so that bundle can't go stale

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

.PARAMETER CopyTo
    After packaging, copy the package's files (sym.exe, sym_shim.exe,
    install.cmd, install.ps1, README.txt, BUILD-INFO.txt) into this folder,
    creating it if needed. Only those six files are written -- anything
    else in the folder is left alone -- and each copy is verified against
    the package by SHA-256. The previous copies are overwritten, not kept.
    BUILD-INFO.txt records the commit they were built from, so an
    equivalent bundle can be rebuilt from it -- equivalent, not identical:
    builds are not bit-for-bit reproducible (the same compiler on the same
    source gives different bytes each time), so the SHA-256 hashes in
    BUILD-INFO.txt are what identify the exact files that shipped.
    Because a shipped bundle should be traceable and tested, this refuses
    to run from a working tree with uncommitted changes (see -AllowDirty)
    and cannot be combined with -SkipTests. Both checks happen before the
    build starts.

.PARAMETER AllowDirty
    Let -CopyTo proceed from a tree with uncommitted changes. BUILD-INFO.txt
    will still say so.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$OutDir,
    [switch]$SkipTests,
    [switch]$NoZip,
    [string]$CopyTo,
    [switch]$AllowDirty
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
    Write-Warning "Working tree has uncommitted changes -- the source this package is built from isn't fully recorded in commit $commit, so it can't be rebuilt from that commit. BUILD-INFO.txt will say so."
}

# Fail before the slow part, not after it.
if ($CopyTo) {
    if ($SkipTests) {
        throw "-CopyTo can't be combined with -SkipTests: a bundle you ship should have passed the tests."
    }
    if (($dirty -or $commit -eq "unknown") -and -not $AllowDirty) {
        $why = if ($commit -eq "unknown") { "can't tell which commit this is (no git)" } else { "the working tree has uncommitted changes" }
        throw "Refusing -CopyTo: $why, so the source the bundle is built from isn't recorded in a commit. Commit first, or pass -AllowDirty to copy anyway."
    }
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
        Invoke-Certo @("test", (Join-Path $repo "src\ShimConfig.cto")) "ShimConfig tests"
        Invoke-Certo @("test", (Join-Path $repo "src\Glob.cto")) "Glob tests"
        Invoke-Certo @("test", (Join-Path $repo "src\Names.cto")) "Names tests"
        & (Join-Path $repo "tests\arg-forwarding\run.ps1") -Certo $Certo -ShimExe (Join-Path $work "sym_shim.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "argument-forwarding test failed against the built shim" }
        & (Join-Path $repo "tests\alias-guards\run.ps1") -SymExe (Join-Path $work "sym.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "alias-guard test failed against the built sym.exe" }
        & (Join-Path $repo "tests\name-validation\run.ps1") -Certo $Certo -SymExe (Join-Path $work "sym.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "name-validation test failed against the built sym.exe" }
        & (Join-Path $repo "tests\commands\run.ps1") -Certo $Certo -SymExe (Join-Path $work "sym.exe") -ShimExe (Join-Path $work "sym_shim.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "command tests (list, which, doctor, shim add-all) failed against the built binaries" }
        & (Join-Path $repo "tests\install-package\run.ps1") -Certo $Certo -SymExe (Join-Path $work "sym.exe") -ShimExe (Join-Path $work "sym_shim.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "install-package tests failed against the built binaries" }
        & (Join-Path $repo "tests\ctrl-c\run.ps1") -Certo $Certo -ShimExe (Join-Path $work "sym_shim.exe") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Ctrl+C test failed against the built shim -- is the certo compiler you built with older than the Process.execInherit Ctrl+C fix?" }
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
        "commit      : $commit$(if ($dirty) { '  (UNCOMMITTED CHANGES -- the source built is not fully in this commit)' })",
        "certo       : $certoVersion",
        "tests       : $(if ($SkipTests) { 'SKIPPED' } else { 'passed (AtomicWrite, Junction, ShimConfig, Glob, Names, arg-forwarding, alias-guards, name-validation, commands, install-package, ctrl-c)' })",
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

    if ($CopyTo) {
        if (-not (Test-Path -LiteralPath $CopyTo)) {
            New-Item -ItemType Directory -Force $CopyTo | Out-Null
            Write-Host "`nCreated $CopyTo"
        }
        Write-Host "`nCopying the package into $CopyTo..."
        foreach ($f in Get-ChildItem -LiteralPath $pkg -File | Sort-Object Name) {
            $dest = Join-Path $CopyTo $f.Name
            $srcHash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $existed = Test-Path -LiteralPath $dest
            # An existing file we can't even read (locked by a running program)
            # just counts as "different": the copy below then fails with the
            # clear "Could not write" message instead of a raw hashing error.
            $destHash = $null
            if ($existed) { try { $destHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash } catch { } }
            if ($existed -and $destHash -eq $srcHash) {
                Write-Host ("  unchanged  {0}" -f $f.Name)
                continue
            }
            # copy beside the destination, then rename over it, so a failure
            # (e.g. sym.exe in use) never leaves a truncated file in the bundle
            $temp = "$dest.new"
            try {
                Copy-Item -LiteralPath $f.FullName -Destination $temp -Force
                Move-Item -LiteralPath $temp -Destination $dest -Force
            } catch {
                if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
                throw "Could not write $dest ($($_.Exception.Message))."
            }
            if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $srcHash) {
                throw "$dest does not match the package after copying."
            }
            Write-Host ("  {0,-10} {1}" -f $(if ($existed) { "updated" } else { "added" }), $f.Name)
        }
    } else {
        Write-Host "Copy it to the target PC and run install.cmd there."
    }
}
finally {
    [IO.Directory]::Delete($work, $true)
}
