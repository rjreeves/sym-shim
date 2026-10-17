<#
.SYNOPSIS
    Installs a package that ships several executables -- a zip or an unpacked
    folder -- into sym as ONE version, points an alias at it, and shims every
    executable.

.DESCRIPTION
    For a release like Certo's (certo, certo-fmt, certo-lsp, certo-test,
    certo-ffi, certo-llvm, certo-ui, certo-wasm in one zip) this does by hand
    what would otherwise be a dozen `sym` commands:

      1. unpacks the zip to a temporary folder (or uses the folder you gave)
      2. finds every .exe at the top of the package
      3. works out the version: -Version, else the package's VERSION file,
         else the archive's file name (certo-1.0.73-windows-x64.zip -> 1.0.73)
      4. starts <Package>.exe --version to prove the package runs, before
         anything is installed (only that one -- other tools in a package may
         not take --version, and an editor server such as certo-lsp would sit
         waiting on its input)
      5. sym install <Package> <version> <each exe>
      6. sym alias <Package> <Alias> <version>        (default alias: latest)
      7. sym shim add-all <Package> <Alias> <pattern> (default: every exe)

    Only executables are installed; docs, examples and the like stay in the
    zip. Re-running for the same version just overwrites in place; installing
    a newer version keeps the old one, so you can roll back with
    `sym alias <Package> latest <old-version>`.

    The target home is the SYM_HOME environment variable if set, else
    %LOCALAPPDATA%\Sym -- the same rule sym itself uses.

.PARAMETER Package
    The sym package name, e.g. certo.

.PARAMETER Source
    A .zip, or a folder holding the executables (a zip whose contents sit in
    one wrapping folder is handled too).

.PARAMETER Version
    Override the detected version. Letters, digits and . _ + - only.

.PARAMETER Alias
    The alias to point at the installed version. Default: latest.

.PARAMETER ShimPattern
    Which installed executables to shim, by `sym shim add-all`'s pattern
    (* and ?, case-insensitive, matches the name with or without .exe).
    Default: * (all of them). Use e.g. certo to shim only certo.exe.

.PARAMETER NoAlias
    Don't create/repoint the alias. Shims then point straight at the version.

.PARAMETER NoShim
    Install (and alias) but create no shims.

.PARAMETER DryRun
    Unpack, validate, smoke-test and print the plan; change nothing in sym.

.PARAMETER Sym
    Path to sym.exe. Default: `sym` on PATH, else <home>\sym.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Version,
    [string]$Alias = "latest",
    [string]$ShimPattern = "*",
    [switch]$NoAlias,
    [switch]$NoShim,
    [switch]$DryRun,
    [string]$Sym
)

$ErrorActionPreference = "Stop"

function Fail([string]$message) {
    Write-Host "install-package: $message" -ForegroundColor Red
    exit 1
}

# Runs an executable with a hard time limit and returns its first output line.
# Used only to ask the MAIN executable for its version.
function Invoke-Version([string]$exe) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--version"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch { }; return @{ Ran = $true; TimedOut = $true; Line = "" } }
    $text = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd())
    $first = ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    return @{ Ran = $true; TimedOut = $false; Line = "$first".Trim() }
}

$symHome = if ($env:SYM_HOME) { $env:SYM_HOME } else { Join-Path $env:LOCALAPPDATA "Sym" }
if (-not $Sym) {
    $found = Get-Command sym -ErrorAction SilentlyContinue
    if ($found) { $Sym = $found.Source }
    elseif (Test-Path -LiteralPath (Join-Path $symHome "sym.exe")) { $Sym = Join-Path $symHome "sym.exe" }
    else { Fail "sym.exe not found (not on PATH, and not at $symHome\sym.exe). Install sym first, or pass -Sym <path>." }
}
if (-not (Test-Path -LiteralPath $Sym)) { Fail "sym.exe not found at $Sym" }
if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { Fail "'$Alias' isn't a usable alias name (letters, digits and . _ + - only)." }
if (-not (Test-Path -LiteralPath $Source)) { Fail "source not found: $Source" }

$item = Get-Item -LiteralPath $Source
$work = $null
try {
    # -------------------------------------------------------------- unpack
    if ($item.PSIsContainer) {
        $root = $item.FullName
    } elseif ($item.Extension -ieq ".zip") {
        $work = Join-Path ([IO.Path]::GetTempPath()) ("sym-install-package-" + [Guid]::NewGuid().ToString("N"))
        Expand-Archive -LiteralPath $item.FullName -DestinationPath $work
        $root = $work
        # a zip that wraps everything in one folder
        if (@(Get-ChildItem -LiteralPath $root -Filter *.exe -File).Count -eq 0) {
            $subs = @(Get-ChildItem -LiteralPath $root -Directory)
            if ($subs.Count -eq 1 -and @(Get-ChildItem -LiteralPath $subs[0].FullName -Filter *.exe -File).Count -gt 0) { $root = $subs[0].FullName }
        }
    } else {
        Fail "the source must be a .zip or a folder, not $($item.Name)"
    }

    $exes = @(Get-ChildItem -LiteralPath $root -Filter *.exe -File | Sort-Object Name)
    if ($exes.Count -eq 0) { Fail "no .exe files at the top of $($item.Name) -- nothing to install." }

    # ------------------------------------------------------------- version
    $versionFrom = "-Version"
    if (-not $Version) {
        $vf = Join-Path $root "VERSION"
        if (Test-Path -LiteralPath $vf) {
            $Version = ((Get-Content -LiteralPath $vf | Where-Object { $_.Trim() } | Select-Object -First 1) + "").Trim()
            $versionFrom = "the package's VERSION file"
        }
    }
    if (-not $Version) {
        $m = [regex]::Match($item.BaseName, "^" + [regex]::Escape($Package) + "-(?<v>\d[0-9A-Za-z._+]*)")
        if ($m.Success) { $Version = $m.Groups["v"].Value; $versionFrom = "the file name $($item.Name)" }
    }
    if (-not $Version) { Fail "couldn't work out the version: there's no VERSION file and the name '$($item.Name)' doesn't look like $Package-<version>. Pass -Version." }
    # the version becomes a folder name under packages\<Package>\ -- keep it to one plain path segment
    if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { Fail "'$Version' isn't a usable version (letters, digits and . _ + - only, no slashes)." }
    if ($Version -ieq $Alias -and -not $NoAlias) { Fail "the version '$Version' is the same as the alias name; they must differ." }

    # ------------------------------------------------- does it actually run
    Get-ChildItem -LiteralPath $root -Filter *.exe -File | Unblock-File -ErrorAction SilentlyContinue   # a downloaded zip marks its files
    $mainExe = Join-Path $root "$Package.exe"
    $smoke = "skipped ($Package.exe isn't in the package)"
    if (Test-Path -LiteralPath $mainExe) {
        try { $r = Invoke-Version $mainExe } catch { Fail "$Package.exe can't be started: $($_.Exception.Message)" }
        if ($r.TimedOut) { $smoke = "WARNING: $Package.exe --version did not finish in 10s" }
        elseif (-not $r.Line) { $smoke = "WARNING: $Package.exe --version printed nothing" }
        elseif ($r.Line.Contains($Version)) { $smoke = "$($r.Line)" }
        else { $smoke = "WARNING: reports '$($r.Line)', which doesn't mention $Version" }
    }

    # ---------------------------------------------------------------- plan
    $target = if ($NoAlias) { $Version } else { $Alias }
    Write-Host "Package   : $Package"
    Write-Host "Version   : $Version   (from $versionFrom)"
    Write-Host "Source    : $($item.FullName)"
    Write-Host "Into      : $symHome"
    Write-Host "Installs  : $($exes.Count) executable(s): $(($exes | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "Alias     : $(if ($NoAlias) { 'none' } else { "$Alias -> $Version" })"
    Write-Host "Shims     : $(if ($NoShim) { 'none' } else { "pattern '$ShimPattern', resolved through '$target'" })"
    Write-Host "Self-test : $smoke"
    if ($smoke -like "WARNING*") { Write-Host "            (continuing: only $Package.exe was asked, and only as a sanity check)" -ForegroundColor Yellow }
    if ($DryRun) { Write-Host "`nDry run: nothing was changed."; exit 0 }
    Write-Host ""

    # ------------------------------------------------------------- install
    $installedDir = Join-Path (Join-Path (Join-Path $symHome "packages") $Package) $Version
    foreach ($exe in $exes) {
        $out = & $Sym install $Package $Version $exe.FullName $exe.Name 2>&1
        if ($LASTEXITCODE -ne 0) {
            $out | ForEach-Object { Write-Host "  $_" }
            Fail "sym install failed for $($exe.Name). If it's running, close it and try again. Files installed before this one are left in place."
        }
        $copy = Join-Path $installedDir $exe.Name
        if (-not (Test-Path -LiteralPath $copy) -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash) {
            Fail "$($exe.Name) in $installedDir doesn't match the package after copying."
        }
        Write-Host ("  installed {0,-18} {1,6:N1} MB" -f $exe.Name, ($exe.Length / 1MB))
    }

    # --------------------------------------------------------------- alias
    if (-not $NoAlias) {
        $out = & $Sym alias $Package $Alias $Version 2>&1 | Where-Object { "$_" -notmatch '^Junction created' }
        if ($LASTEXITCODE -ne 0) {
            $out | ForEach-Object { Write-Host "  $_" }
            $aliasPath = Join-Path (Join-Path (Join-Path $symHome "packages") $Package) $Alias
            if ((Test-Path -LiteralPath $aliasPath) -and -not ((Get-Item -LiteralPath $aliasPath -Force).LinkType)) {
                Fail "$aliasPath is an ordinary folder (an older install), not an alias, so sym won't replace it. The files ARE installed as $Package@$Version. Move that folder away, or re-run with -Alias <another name> or -NoAlias."
            }
            Fail "couldn't point the alias '$Alias' at $Version. The files ARE installed as $Package@$Version."
        }
        Write-Host "  alias     $Alias -> $Version"
    }

    # --------------------------------------------------------------- shims
    if (-not $NoShim) {
        $out = & $Sym shim add-all $Package $target $ShimPattern 2>&1
        $code = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "  $_" }
        if ($code -ne 0) { Fail "shimming failed (see above). The files are installed." }
    }

    # ---------------------------------------------------------- final check
    if (-not $NoShim -and (Test-Path -LiteralPath (Join-Path $symHome "bin\$Package.exe"))) {
        $r = Invoke-Version (Join-Path $symHome "bin\$Package.exe")
        Write-Host "`nthrough the shim: $($r.Line)"
    }
    Write-Host "`nsym doctor:"
    & $Sym doctor 2>&1 | Where-Object { "$_" -match '^\s+(warn|FAIL)|problem|no problems' } | ForEach-Object { Write-Host "  $($_.ToString().Trim())" }
    $doctorCode = $LASTEXITCODE
    if ($doctorCode -ne 0) {
        # the install itself succeeded; doctor audits the whole home, so a failure may be unrelated to this package
        Write-Host "  (sym doctor reports problems -- run 'sym doctor' for the full list)" -ForegroundColor Yellow
    }
    Write-Host "`nDone: $Package $Version is installed."
    exit 0       # explicit: otherwise the exit code would be whatever `sym doctor` left behind
}
finally {
    if ($work -and (Test-Path -LiteralPath $work)) { [IO.Directory]::Delete($work, $true) }
}
