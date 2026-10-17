<#
    End-to-end tests for scripts/install-package.ps1, which installs a package
    that ships several executables (a zip, or an unpacked folder) into sym as
    one version, aliases it, and shims every executable.

    Uses small stand-in packages built here, so it doesn't depend on any real
    release, plus -- if one is found -- the real Certo zip (8 executables) from
    the neighbouring Certo checkout's dist\ folder. Every install goes into a
    scratch SYM_HOME; the real Sym home is never touched.

    Builds sym.exe, sym_shim.exe and the stand-in program from source unless
    -SymExe / -ShimExe are given. Exits 0 on success, 1 on any failed check.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$SymExe,
    [string]$ShimExe,
    [string]$CertoZip
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script_ = Join-Path $repoRoot "scripts\install-package.ps1"
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-install-package-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
$script:failures = 0
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
}
function Build([string]$source, [string]$output) {
    & $Certo $source -o $output | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certo failed to build $source" }
}
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

# Deletes a folder tree without ever following a junction: finds every reparse point with a
# walk that never descends into one, unlinks each (the link only), then deletes the rest. A
# BROKEN install script can leave an alias pointing back at its own parent, and a plain
# recursive delete or Get-ChildItem -Recurse would then loop or reach outside the tree; the
# test must report that as failed checks, not die in its cleanup.
function Wipe-Tree([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $links = @(); $stack = [System.Collections.Stack]::new(); $stack.Push($path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($e in Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue) {
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $links += $e.FullName }
            elseif ($e.PSIsContainer) { $stack.Push($e.FullName) }
        }
    }
    foreach ($l in $links) { try { [IO.Directory]::Delete($l) } catch { } }
    try { [IO.Directory]::Delete($path, $true) } catch { Write-Host "  (note: couldn't fully remove $path : $($_.Exception.Message))" }
}

# A fresh scratch home with just the master shim, as the installer leaves it.
function New-Home([string]$name) {
    $h = Join-Path $work $name
    New-Item -ItemType Directory -Force "$h\shim" | Out-Null
    Copy-Item $script:shim "$h\shim\sym_shim.exe"
    return $h
}

# Runs the install script against a home. Returns the exit code and all output.
function Install([string]$Home_, [string[]]$ScriptArgs) {
    # Splatting an ARRAY would pass "-Package" as a plain positional string, not a
    # parameter name, so turn the "-Name value" list into a hashtable.
    $switches = "DryRun", "NoAlias", "NoShim"
    $splat = @{}
    for ($i = 0; $i -lt $ScriptArgs.Count; $i++) {
        $name = $ScriptArgs[$i].TrimStart('-')
        if ($switches -contains $name) { $splat[$name] = $true } else { $i++; $splat[$name] = $ScriptArgs[$i] }
    }
    $splat["Sym"] = $script:sym
    $old = $env:SYM_HOME
    [Environment]::SetEnvironmentVariable("SYM_HOME", $Home_, "Process")
    $global:LASTEXITCODE = 0
    try { $out = (& $script_ @splat *>&1 | Out-String); $code = $LASTEXITCODE }
    catch { $out = "THREW: $($_.Exception.Message)"; $code = 99 }
    finally { [Environment]::SetEnvironmentVariable("SYM_HOME", $old, "Process") }
    return @{ Code = $code; Out = $out }
}

# Runs a command of sym against a home.
function Sym([string]$Home_, [string[]]$SymArgs) {
    $old = $env:SYM_HOME
    [Environment]::SetEnvironmentVariable("SYM_HOME", $Home_, "Process")
    try { $out = (& $script:sym @SymArgs 2>&1 | Out-String); $code = $LASTEXITCODE }
    finally { [Environment]::SetEnvironmentVariable("SYM_HOME", $old, "Process") }
    return @{ Code = $code; Out = $out }
}

# Runs a shim (or any exe) with SYM_HOME pointing at a home; returns its first line of output.
function RunShim([string]$Home_, [string]$exe) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = "--version"
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["SYM_HOME"] = $Home_
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
}

# Builds a stand-in package folder: three executables, docs\, examples\, and (optionally) VERSION.
function New-PackageFolder([string]$name, [string]$version, [bool]$withVersionFile, [string]$exeSource) {
    $d = Join-Path $work $name
    New-Item -ItemType Directory -Force "$d\docs", "$d\examples" | Out-Null
    foreach ($e in "fakepkg.exe", "fakepkg-tool.exe", "fakepkg-other.exe") { Copy-Item $exeSource (Join-Path $d $e) }
    Set-Content "$d\docs\readme.txt" "docs" -NoNewline
    Set-Content "$d\examples\sample.txt" "example" -NoNewline
    if ($withVersionFile) { Set-Content "$d\VERSION" $version -NoNewline }
    return $d
}
function New-Zip([string]$folder, [string]$zipPath) {
    if (Test-Path $zipPath) { [IO.File]::Delete($zipPath) }
    [IO.Compression.ZipFile]::CreateFromDirectory($folder, $zipPath)
}

try {
    # ---------------------------------------------------------------- build
    if ($SymExe) { $script:sym = (Resolve-Path -LiteralPath $SymExe).Path } else { $script:sym = Join-Path $work "sym.exe"; Build (Join-Path $repoRoot "src\sym.cto") $script:sym }
    if ($ShimExe) { $script:shim = (Resolve-Path -LiteralPath $ShimExe).Path } else { $script:shim = Join-Path $work "sym_shim.exe"; Build (Join-Path $repoRoot "src\sym_shim.cto") $script:shim }
    $exe25 = Join-Path $work "fake25.exe"; $exe26 = Join-Path $work "fake26.exe"
    foreach ($pair in @(@("2.5.0", $exe25), @("2.6.0", $exe26))) {
        $src = Join-Path $work ("fake-" + $pair[0] + ".cto")
        (Get-Content (Join-Path $PSScriptRoot "fake.cto") -Raw).Replace("@VERSION@", $pair[0]) | Set-Content $src -NoNewline
        Build $src $pair[1]
    }
    $pkg25 = New-PackageFolder "pkg25" "2.5.0" $true $exe25
    $pkg26 = New-PackageFolder "pkg26" "2.6.0" $true $exe26
    $zip25 = Join-Path $work "fakepkg-2.5.0-windows-x64.zip"; New-Zip $pkg25 $zip25
    $zip26 = Join-Path $work "fakepkg-2.6.0-windows-x64.zip"; New-Zip $pkg26 $zip26

    # ------------------------------------------------------ the normal case
    Write-Host "a zip with three executables, docs, examples and a VERSION file"
    $h = New-Home "a"
    $r = Install $h @("-Package", "fakepkg", "-Source", $zip25)
    Check ($r.Code -eq 0) "exits 0"
    Check ($r.Out -match "Version\s+: 2\.5\.0\s+\(from the package's VERSION file\)") "takes the version from the VERSION file"
    $installed = @(Get-ChildItem "$h\packages\fakepkg\2.5.0" -Force | ForEach-Object Name | Sort-Object)
    Check (($installed -join ",") -ceq "fakepkg-other.exe,fakepkg-tool.exe,fakepkg.exe") "installs exactly the three executables (found: $($installed -join ', '))"
    Check (-not (Test-Path "$h\packages\fakepkg\2.5.0\docs") -and -not (Test-Path "$h\packages\fakepkg\2.5.0\VERSION")) "and leaves docs, examples and VERSION behind"
    $same = $true; foreach ($e in "fakepkg.exe", "fakepkg-tool.exe", "fakepkg-other.exe") { if ((Sha "$h\packages\fakepkg\2.5.0\$e") -ne (Sha "$pkg25\$e")) { $same = $false } }
    Check $same "each installed file is byte-identical to the package's"
    $alias = Get-Item "$h\packages\fakepkg\latest" -Force -ErrorAction SilentlyContinue
    Check ($null -ne $alias -and $alias.LinkType -eq "Junction") "latest is an alias (a junction)"
    Check (Test-Path "$h\packages\fakepkg\latest\fakepkg.exe") "and it resolves to the installed version"
    $shimNames = @(Get-ChildItem "$h\bin" -File | ForEach-Object Name | Sort-Object)
    Check (($shimNames -join ",") -ceq "fakepkg-other.exe,fakepkg-tool.exe,fakepkg.exe") "shims every executable (found: $($shimNames -join ', '))"
    Check ((Get-Content "$h\shims\fakepkg-tool.toml" -Raw) -match 'package = "fakepkg"' -and (Get-Content "$h\shims\fakepkg-tool.toml" -Raw) -match 'version = "latest"') "each shim goes through the alias"
    Check ((RunShim $h "$h\bin\fakepkg.exe") -ceq "fakepkg 2.5.0") "running a shim runs the installed program ('$(RunShim $h "$h\bin\fakepkg.exe")')"
    Check ($r.Out -match "Self-test : fakepkg 2\.5\.0") "the package's own --version was checked before installing"
    $d = Sym $h @("doctor")
    Check ($d.Out -notmatch "(?m)^  FAIL") "sym doctor finds no failures afterwards"

    # --------------------------------------------------- again, then upgrade
    Write-Host "`nre-running, then installing a newer version"
    $before = Sha "$h\packages\fakepkg\2.5.0\fakepkg.exe"
    $r = Install $h @("-Package", "fakepkg", "-Source", $zip25)
    Check ($r.Code -eq 0 -and (Sha "$h\packages\fakepkg\2.5.0\fakepkg.exe") -eq $before) "re-running the same version is safe and changes nothing"
    $r = Install $h @("-Package", "fakepkg", "-Source", $zip26)
    Check ($r.Code -eq 0) "installing 2.6.0 exits 0"
    Check ((RunShim $h "$h\bin\fakepkg.exe") -ceq "fakepkg 2.6.0") "latest now runs 2.6.0"
    Check ((Sha "$h\packages\fakepkg\2.5.0\fakepkg.exe") -eq $before) "2.5.0 is still there, untouched"
    $null = Sym $h @("alias", "fakepkg", "latest", "2.5.0")
    Check ((RunShim $h "$h\bin\fakepkg.exe") -ceq "fakepkg 2.5.0") "and one 'sym alias' rolls back to it"

    # --------------------------------------------------- where the version comes from
    Write-Host "`nwhere the version comes from"
    $noVer = New-PackageFolder "nover" "x" $false $exe25
    $zipNamed = Join-Path $work "fakepkg-3.1.4-windows-x64.zip"; New-Zip $noVer $zipNamed
    $r = Install (New-Home "v1") @("-Package", "fakepkg", "-Source", $zipNamed)
    Check ($r.Code -eq 0 -and $r.Out -match "Version\s+: 3\.1\.4\s+\(from the file name") "no VERSION file: taken from the archive's name (3.1.4)"
    $r = Install (New-Home "v2") @("-Package", "fakepkg", "-Source", $zip25, "-Version", "9.9.9")
    Check ($r.Code -eq 0 -and $r.Out -match "Version\s+: 9\.9\.9" -and (Test-Path "$work\v2\packages\fakepkg\9.9.9\fakepkg.exe")) "-Version overrides everything"
    $zipPlain = Join-Path $work "release.zip"; New-Zip $noVer $zipPlain
    $r = Install (New-Home "v3") @("-Package", "fakepkg", "-Source", $zipPlain)
    Check ($r.Code -eq 1 -and $r.Out -match "couldn't work out the version") "nothing to go on: refuses and asks for -Version"
    Check (-not (Test-Path "$work\v3\packages")) "and installs nothing"

    # ------------------------------------------------------------- safety
    Write-Host "`nthe version becomes a folder name, so it must stay one plain name"
    foreach ($bad in "..\evil", "../evil", "a\b", "..", ".hidden") {
        $hh = New-Home "unsafe"
        $r = Install $hh @("-Package", "fakepkg", "-Source", $zip25, "-Version", $bad)
        Check ($r.Code -eq 1 -and $r.Out -match "isn't a usable version") "refuses -Version '$bad'"
        Check (-not (Test-Path "$hh\packages") -and -not (Test-Path "$work\evil")) "and creates nothing, here or outside the home"
        Wipe-Tree $hh
    }
    $r = Install (New-Home "same") @("-Package", "fakepkg", "-Source", $zip25, "-Version", "latest")
    Check ($r.Code -eq 1 -and $r.Out -match "same as the alias name") "a version called 'latest' can't also be the alias"

    # ----------------------------------------------------- other source shapes
    Write-Host "`nother kinds of source"
    $r = Install (New-Home "folder") @("-Package", "fakepkg", "-Source", $pkg25)
    Check ($r.Code -eq 0 -and (Test-Path "$work\folder\packages\fakepkg\2.5.0\fakepkg-tool.exe")) "an unpacked folder works too"
    $wrapRoot = Join-Path $work "wrap"; New-Item -ItemType Directory -Force "$wrapRoot\fakepkg-2.5.0" | Out-Null
    Copy-Item "$pkg25\*" "$wrapRoot\fakepkg-2.5.0" -Recurse
    $zipWrap = Join-Path $work "fakepkg-wrapped.zip"; New-Zip $wrapRoot $zipWrap
    $r = Install (New-Home "wrapped") @("-Package", "fakepkg", "-Source", $zipWrap)
    Check ($r.Code -eq 0 -and (Test-Path "$work\wrapped\packages\fakepkg\2.5.0\fakepkg.exe")) "a zip with everything inside one wrapping folder works"
    $empty = Join-Path $work "emptypkg"; New-Item -ItemType Directory -Force $empty | Out-Null
    Set-Content "$empty\notes.txt" "no executables here"
    $r = Install (New-Home "noexe") @("-Package", "fakepkg", "-Source", $empty, "-Version", "1.0")
    Check ($r.Code -eq 1 -and $r.Out -match "no \.exe files") "a package with no executables is refused"
    $r = Install (New-Home "nosrc") @("-Package", "fakepkg", "-Source", (Join-Path $work "does-not-exist.zip"))
    Check ($r.Code -eq 1 -and $r.Out -match "source not found") "a missing source is refused"
    $r = Install (New-Home "badext") @("-Package", "fakepkg", "-Source", "$empty\notes.txt")
    Check ($r.Code -eq 1 -and $r.Out -match "must be a \.zip or a folder") "a source that is neither a zip nor a folder is refused"

    # ------------------------------------------------------------- options
    Write-Host "`noptions"
    $hd = New-Home "dry"
    $r = Install $hd @("-Package", "fakepkg", "-Source", $zip25, "-DryRun")
    Check ($r.Code -eq 0 -and $r.Out -match "Dry run: nothing was changed") "-DryRun prints the plan"
    Check (-not (Test-Path "$hd\packages") -and -not (Test-Path "$hd\bin") -and -not (Test-Path "$hd\shims")) "and changes nothing"
    $r = Install (New-Home "noalias") @("-Package", "fakepkg", "-Source", $zip25, "-NoAlias")
    Check ($r.Code -eq 0 -and -not (Test-Path "$work\noalias\packages\fakepkg\latest") -and (Get-Content "$work\noalias\shims\fakepkg.toml" -Raw) -match 'version = "2\.5\.0"') "-NoAlias: no alias, and the shims point straight at the version"
    $r = Install (New-Home "noshim") @("-Package", "fakepkg", "-Source", $zip25, "-NoShim")
    Check ($r.Code -eq 0 -and (Test-Path "$work\noshim\packages\fakepkg\latest\fakepkg.exe") -and -not (Test-Path "$work\noshim\bin")) "-NoShim: installed and aliased, nothing shimmed"
    $r = Install (New-Home "pattern") @("-Package", "fakepkg", "-Source", $zip25, "-ShimPattern", "fakepkg")
    $only = @(Get-ChildItem "$work\pattern\bin" -File -ErrorAction SilentlyContinue | ForEach-Object Name)
    Check ($r.Code -eq 0 -and ($only -join ",") -ceq "fakepkg.exe") "-ShimPattern fakepkg shims only fakepkg.exe (found: $($only -join ', '))"

    # ------------------------------------------------------- awkward homes
    Write-Host "`nawkward starting points"
    $hr = New-Home "realfolder"
    New-Item -ItemType Directory -Force "$hr\packages\fakepkg\latest" | Out-Null
    Set-Content "$hr\packages\fakepkg\latest\old.txt" "an older install lives here" -NoNewline
    $r = Install $hr @("-Package", "fakepkg", "-Source", $zip25)
    Check ($r.Code -eq 1 -and $r.Out -match "ordinary folder") "'latest' already a real folder: stops and explains"
    Check ($r.Out -match "ARE installed as fakepkg@2\.5\.0") "and says the files did install under their version"
    Check ((Get-Content "$hr\packages\fakepkg\latest\old.txt" -Raw) -ceq "an older install lives here") "the existing folder is left untouched"
    Check (-not (Test-Path "$hr\bin")) "and nothing is shimmed against the half-finished state"

    $ho = New-Home "owned"
    $null = Sym $ho @("install", "other", "1", $exe25, "other.exe")
    $null = Sym $ho @("shim", "add", "fakepkg-tool", "other", "1", "other.exe")
    $r = Install $ho @("-Package", "fakepkg", "-Source", $zip25)
    Check ($r.Code -eq 0 -and $r.Out -match "skipped 'fakepkg-tool': already shimmed to package 'other'") "a name another package already owns is skipped, not overwritten"
    Check ((Get-Content "$ho\shims\fakepkg-tool.toml" -Raw) -match 'package = "other"') "and that shim is untouched"

    # ---------------------------------------------------- the real Certo zip
    if (-not $CertoZip) {
        $dist = Join-Path (Split-Path -Parent $repoRoot) "Certo\dist"
        if (Test-Path $dist) { $z = Get-ChildItem $dist -Filter "certo-*-windows-x64.zip" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($z) { $CertoZip = $z.FullName } }
    }
    Write-Host "`nthe real Certo package"
    if (-not $CertoZip -or -not (Test-Path $CertoZip)) {
        Write-Host "  (skipped: no certo-*-windows-x64.zip found in the neighbouring Certo checkout's dist\)"
    } else {
        Write-Host "  using $([IO.Path]::GetFileName($CertoZip))"
        $hc = New-Home "certo"
        $r = Install $hc @("-Package", "certo", "-Source", $CertoZip)
        Check ($r.Code -eq 0) "installs cleanly"
        $ver = (Get-ChildItem "$hc\packages\certo" -Directory | Where-Object { -not $_.LinkType } | Select-Object -First 1).Name
        $count = @(Get-ChildItem "$hc\packages\certo\$ver" -File -Filter *.exe).Count
        Check ($count -eq 8) "all 8 executables installed under $ver (found $count)"
        Check (@(Get-ChildItem "$hc\bin" -File -Filter *.exe).Count -eq 8) "and all 8 shimmed"
        $line = RunShim $hc "$hc\bin\certo.exe"
        Check ($line -like "certo $ver*") "certo runs through its shim and reports '$line'"
        Check ((Sym $hc @("doctor")).Out -notmatch "(?m)^  FAIL") "sym doctor finds no failures"
    }

    Check (@(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter "sym-install-package-????????????????????????????????" -ErrorAction SilentlyContinue).Count -eq 0) "no unpacked-zip temp folders left behind by the script"
}
finally {
    Wipe-Tree $work
}

if ($script:failures -eq 0) { Write-Host "`nPASS: all install-package checks"; exit 0 }
Write-Host "`nFAIL: $($script:failures) check(s) failed"; exit 1
