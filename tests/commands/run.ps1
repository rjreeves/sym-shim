<#
    End-to-end tests for `sym list`, `sym which`, `sym doctor` and
    `sym shim add-all`, driving a real sym.exe and a real sym_shim.exe
    against scratch SYM_HOMEs.

    The most important check is the drift test: `sym which` re-implements,
    inside sym.exe, how the shim picks its target (sym_shim.cto stays one
    self-contained file and keeps its own copy). Here the REAL shim launches
    a program that prints its own argv[0], and that must equal the path
    `sym which` reports -- with no pin, with a project pin, when the nearest
    sym.toml doesn't mention the tool, through an alias, and for a version
    that isn't installed. If the two ever disagree this fails.

    Builds sym.exe, sym_shim.exe and a tiny helper from source unless
    -SymExe / -ShimExe are given. Exits 0 on success, 1 on any failed check.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$SymExe,
    [string]$ShimExe
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-commands-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
$script:failures = 0

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
}
function Norm([string]$p) { $p.Replace('/', '\').TrimEnd('\').ToLowerInvariant() }
function Build([string]$source, [string]$output) {
    & $Certo $source -o $output | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certo failed to build $source" }
}

# Runs sym.exe against a home, from a working directory. -OnPath puts the
# home and its bin\ on PATH for the child, so doctor's PATH checks pass.
function Sym([string[]]$SymArgs, [string]$Home_ = $script:symHome, [string]$Cwd = $work, [switch]$OnPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:sym
    $psi.Arguments = ($SymArgs | ForEach-Object { '"' + $_ + '"' }) -join " "
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["SYM_HOME"] = $Home_
    if ($OnPath) { $psi.EnvironmentVariables["PATH"] = "$Home_;$Home_\bin;" + $env:PATH }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out; Err = $err; All = $out + $err }
}
function Run-Shim([string]$Home_, [string]$name, [string]$Cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Home_ "bin\$name.exe"
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["SYM_HOME"] = $Home_
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out.Trim(); Err = $err }
}
function Which-Runs([string]$name, [string]$Cwd) {
    $r = Sym @("which", $name) -Cwd $Cwd
    $line = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\s+runs\s' })
    if ($line.Count -eq 0) { return "<no runs line>" }
    return ($line[0] -replace '^\s+runs\s+', '').Trim()
}
function Content([string]$path) { if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { "<missing>" } }

# a standard small, healthy home: tool 1.0 and 2.0, alias latest -> 2.0, shim tool -> latest
function New-Home([string]$name) {
    $h = Join-Path $work $name
    New-Item -ItemType Directory -Force "$h\shim" | Out-Null
    Copy-Item $script:shim "$h\shim\sym_shim.exe"
    $script:symHome = $h
    Sym @("install", "tool", "1.0", $script:f1, "tool.exe") | Out-Null
    Sym @("install", "tool", "2.0", $script:f2, "tool.exe") | Out-Null
    Sym @("alias", "tool", "latest", "2.0") | Out-Null
    Sym @("shim", "add", "tool", "tool", "latest") | Out-Null
    return $h
}

try {
    # ---------------------------------------------------------------- build
    if ($SymExe) { $script:sym = (Resolve-Path -LiteralPath $SymExe).Path } else { $script:sym = Join-Path $work "sym.exe"; Build (Join-Path $repoRoot "src\sym.cto") $script:sym }
    if ($ShimExe) { $script:shim = (Resolve-Path -LiteralPath $ShimExe).Path } else { $script:shim = Join-Path $work "sym_shim.exe"; Build (Join-Path $repoRoot "src\sym_shim.cto") $script:shim }
    $probe = Join-Path $work "probe.exe"
    Build (Join-Path $PSScriptRoot "argzero.cto") $probe
    $script:f1 = Join-Path $work "one.bin"; Set-Content $script:f1 "ONE" -NoNewline
    $script:f2 = Join-Path $work "two.bin"; Set-Content $script:f2 "TWO" -NoNewline
    # a sym.toml at the top of the scratch area, pinning nothing: whatever
    # lives above the temp folder can't leak into the pin lookups below
    Set-Content (Join-Path $work "sym.toml") "# boundary" -NoNewline

    # ----------------------------------------------------------------- list
    Write-Host "sym list"
    $h = New-Home "list"
    $r = Sym @("list")
    Check ($r.Code -eq 0) "exits 0"
    Check ($r.Out -match '(?m)^tool\r?$') "names the package"
    Check ($r.Out -match '(?m)^  1\.0\r?$') "a real version with nothing using it"
    Check ($r.Out -match '(?m)^  latest\s+->\s+2\.0\s+\(alias\)\s+used by: tool') "an alias, shown pointing at its version and marked as used by the shim"
    Sym @("install", "other", "9", $script:f1, "other.exe") | Out-Null
    $r = Sym @("list", "other")
    Check ($r.Out -match '(?m)^other' -and $r.Out -notmatch '(?m)^tool') "filtering by package shows only that package"
    $r = Sym @("list", "nosuch")
    Check ($r.Out -match "no package named 'nosuch'") "says so for a package that isn't installed"
    $empty = Join-Path $work "empty-home"; New-Item -ItemType Directory -Force $empty | Out-Null
    $r = Sym @("list") -Home_ $empty
    Check ($r.Code -eq 0 -and $r.Out -match "nothing installed") "an empty home is not an error"

    # ---------------------------------------------------------------- which
    Write-Host "`nsym which"
    $h = New-Home "which"
    $r = Sym @("which", "tool")
    Check ($r.Code -eq 0) "exits 0 for a healthy shim"
    Check ($r.Out -match '(?m)^  runs\s+.*tool\\latest\\tool\.exe') "reports the target through the alias"
    Check ($r.Out -match '(?m)^  alias\s+latest\s+->\s+2\.0') "and what the alias points at"
    Check ($r.Out -match '(?m)^  status\s+ok') "status ok"
    Check ($r.Out -match '(?m)^  pin\s+none') "no pin when no sym.toml pins it"
    $r = Sym @("which", "tool.exe")
    Check ($r.Code -eq 0 -and $r.Out -match '(?m)^tool\r?$') "accepts the name with .exe"

    $proj = Join-Path $work "proj-which"; New-Item -ItemType Directory -Force $proj | Out-Null
    Set-Content (Join-Path $proj "sym.toml") 'tool = "1.0"' -NoNewline
    $r = Sym @("which", "tool") -Cwd $proj
    Check ($r.Out -match '(?m)^  runs\s+.*tool\\1\.0\\tool\.exe' -and $r.Out -match '\(project pin\)') "a project pin overrides the global version"
    Check ($r.Out -match [regex]::Escape((Join-Path $proj "sym.toml"))) "and says which sym.toml it came from"

    $inner = Join-Path $proj "inner"; New-Item -ItemType Directory -Force $inner | Out-Null
    Set-Content (Join-Path $inner "sym.toml") 'something-else = "1"' -NoNewline
    $r = Sym @("which", "tool") -Cwd $inner
    Check ($r.Out -match "exists but doesn't pin tool" -and $r.Out -match 'tool\\latest\\tool\.exe') "the nearest sym.toml wins entirely: a parent's pin isn't consulted"

    Set-Content (Join-Path $proj "sym.toml") 'tool = "9.9"' -NoNewline
    $r = Sym @("which", "tool") -Cwd $proj
    Check ($r.Code -eq 1 -and $r.Out -match 'status\s+NOT INSTALLED') "a pin to an uninstalled version exits 1 and says so"

    $r = Sym @("which", "ghost")
    Check ($r.Code -eq 1 -and $r.Out -match "isn't a shimmed name") "an unknown name exits 1 with a hint"
    Set-Content (Join-Path $proj "sym.toml") 'ghost = "3.0"' -NoNewline
    $r = Sym @("which", "ghost") -Cwd $proj
    Check ($r.Code -eq 1 -and $r.Out -match 'pinned to 3\.0 but never shimmed') "a pin for a never-shimmed name is called out"

    # ------------------------------------------- the shim and `which` agree
    Write-Host "`nthe real shim vs sym which (drift check)"
    $h = New-Home "drift"
    Sym @("install", "probe", "1", $probe, "probe.exe") | Out-Null
    Sym @("install", "probe", "2", $probe, "probe.exe") | Out-Null
    Sym @("alias", "probe", "latest", "1") | Out-Null
    Sym @("shim", "add", "probe", "probe", "latest") | Out-Null

    function Compare-Cases([string]$label, [string]$cwd) {
        $shimRun = Run-Shim $script:symHome "probe" $cwd
        $which = Which-Runs "probe" $cwd
        Check ($shimRun.Code -eq 0 -and (Norm $shimRun.Out) -eq (Norm $which)) "$label -- shim ran '$($shimRun.Out)', which says '$which'"
    }
    $p0 = Join-Path $work "drift-none"; New-Item -ItemType Directory -Force $p0 | Out-Null
    Compare-Cases "no pin (through the alias)" $p0
    $p1 = Join-Path $work "drift-pin"; New-Item -ItemType Directory -Force $p1 | Out-Null
    Set-Content (Join-Path $p1 "sym.toml") 'probe = "2"' -NoNewline
    Compare-Cases "project pin" $p1
    $p2 = Join-Path $p1 "sub\deeper"; New-Item -ItemType Directory -Force $p2 | Out-Null
    Compare-Cases "pin found by climbing from a subfolder" $p2
    $p3 = Join-Path $p1 "other"; New-Item -ItemType Directory -Force $p3 | Out-Null
    Set-Content (Join-Path $p3 "sym.toml") 'unrelated = "1"' -NoNewline
    Compare-Cases "nearest sym.toml doesn't mention the tool, parent does" $p3

    $p4 = Join-Path $work "drift-missing"; New-Item -ItemType Directory -Force $p4 | Out-Null
    Set-Content (Join-Path $p4 "sym.toml") 'probe = "9"' -NoNewline
    $shimRun = Run-Shim $script:symHome "probe" $p4
    $looked = if ($shimRun.Err -match 'looked for (.+?)\)') { $Matches[1] } else { "<no path in the shim's error>" }
    Check ($shimRun.Code -ne 0 -and (Norm $looked) -eq (Norm (Which-Runs "probe" $p4))) "uninstalled pin -- the shim looked for '$looked' and which reports the same path"

    # ---------------------------------------------------------- shim add-all
    Write-Host "`nsym shim add-all"
    $h = New-Home "addall"
    foreach ($e in "suite.exe", "suite-fmt.exe", "suite-lsp.exe", "demo_prog.exe") {
        Sym @("install", "suite", "1.0", $script:f1, $e) | Out-Null
    }
    $r = Sym @("shim", "add-all", "suite", "1.0", "suite*", "--dry-run")
    Check ($r.Code -eq 0 -and $r.Out -match "would shim 'suite-fmt'" -and $r.Out -match "would shim 3, skipped 0") "--dry-run lists what it would do"
    Check (-not (Test-Path "$h\bin\suite-fmt.exe") -and -not (Test-Path "$h\shims\suite.toml")) "and changes nothing"

    $r = Sym @("shim", "add-all", "suite", "1.0", "suite*")
    Check ($r.Code -eq 0 -and $r.Out -match "shimmed 3, skipped 0, failed 0") "shims the three matching executables"
    foreach ($n in "suite", "suite-fmt", "suite-lsp") {
        $d = Content "$h\shims\$n.toml"
        Check ((Test-Path "$h\bin\$n.exe") -and $d -match 'package = "suite"' -and $d -match "command = `"$n\.exe`"" -and $d -match 'version = "1\.0"') "${n}: stamped and described correctly"
        Check ((Get-FileHash "$h\bin\$n.exe").Hash -eq (Get-FileHash "$h\shim\sym_shim.exe").Hash) "${n}: bin\ copy is the master shim"
    }
    Check (-not (Test-Path "$h\bin\demo_prog.exe") -and -not (Test-Path "$h\shims\demo_prog.toml")) "demo_prog.exe doesn't match the pattern and is left alone"

    $r = Sym @("shim", "add-all", "suite", "1.0", "suite*")
    Check ($r.Code -eq 0 -and $r.Out -match "shimmed 3, skipped 0, failed 0") "re-running is safe"
    $r = Sym @("shim", "add-all", "suite", "1.0", "DEMO*")
    Check ($r.Code -eq 0 -and (Test-Path "$h\bin\demo_prog.exe")) "the pattern is case-insensitive"
    $r = Sym @("shim", "add-all", "suite", "1.0", "suite-fmt")
    Check ($r.Code -eq 0 -and $r.Out -match "shimmed 1,") "a pattern matches the name with or without .exe"

    Sym @("shim", "add", "suite-lsp", "tool", "latest", "suite-lsp.exe") | Out-Null     # now owned by another package
    $r = Sym @("shim", "add-all", "suite", "1.0", "suite*")
    Check ($r.Out -match "skipped 'suite-lsp': already shimmed to package 'tool'" -and $r.Out -match "shimmed 2, skipped 1") "a name shimmed to a different package is skipped, not overwritten"
    Check ((Content "$h\shims\suite-lsp.toml") -match 'package = "tool"') "and its descriptor is untouched"

    $r = Sym @("shim", "add-all", "suite", "1.0", "zzz*")
    Check ($r.Code -ne 0 -and $r.Err -match "no executables .* match 'zzz\*'") "no match is an error"
    $r = Sym @("shim", "add-all", "suite", "7.7")
    Check ($r.Code -ne 0 -and $r.Err -match "is not installed") "an uninstalled version is an error"
    $r = Sym @("shim", "add-all", "suite")
    Check ($r.Code -ne 0 -and $r.Err -match "missing <version>") "missing arguments are an error"

    # --------------------------------------------------------------- doctor
    Write-Host "`nsym doctor"
    $h = New-Home "doctor-ok"
    $r = Sym @("doctor") -OnPath
    Check ($r.Code -eq 0 -and $r.Out -match "no problems found") "a healthy home: no problems, exit 0"
    Check ($r.Out -notmatch '(?m)^  (warn|FAIL)') "and not a single warning"
    $r = Sym @("doctor")
    Check ($r.Code -eq 0 -and $r.Out -match "(?m)^  warn .*not on PATH") "PATH problems are warnings, not failures"

    # each fault goes into its own fresh home so they can't mask one another
    function Fault([string]$name, [scriptblock]$break) {
        $h = New-Home "doctor-$name"
        & $break $h
        return @{ Home = $h; R = (Sym @("doctor") -Home_ $h -OnPath) }
    }

    $x = Fault "stale" { param($h) $b = [IO.File]::ReadAllBytes("$h\bin\tool.exe"); [IO.File]::WriteAllBytes("$h\bin\tool.exe", $b + [byte[]](0)) }
    Check ($x.R.Code -eq 0 -and $x.R.Out -match "(?m)^  warn .*tool: bin\\tool\.exe differs from shim\\sym_shim\.exe") "a shim stamped by a different build: warning with the fix"
    Check ($x.R.Out -match "sym shim add tool tool latest") "and the exact command to refresh it"

    $x = Fault "nobin" { param($h) [IO.File]::Delete("$h\bin\tool.exe") }
    Check ($x.R.Code -eq 1 -and $x.R.Out -match "(?m)^  FAIL .*tool: bin\\tool\.exe is missing") "a shim with no bin\ entry: failure"

    # the original incident: a bin\ entry hardlinked to the real binary
    $x = Fault "hardlink" {
        param($h)
        [IO.File]::Delete("$h\bin\tool.exe")
        $null = & cmd.exe /c "mklink /H `"$h\bin\tool.exe`" `"$h\packages\tool\2.0\tool.exe`"" 2>&1
    }
    Check ($x.R.Code -eq 1 -and $x.R.Out -match "(?m)^  FAIL .*tool: bin\\tool\.exe shares its data with") "a bin\ entry hardlinked to a real binary: failure naming the link"

    # uninstall the real version the alias points at, leaving the alias dangling
    $h = New-Home "doctor-gone"
    Sym @("uninstall", "tool", "2.0") | Out-Null
    $r = Sym @("doctor") -OnPath
    Check ($r.Code -eq 1 -and $r.Out -match "(?m)^  FAIL .*latest points at .* which no longer exists") "an alias whose target was uninstalled: failure"
    Check ($r.Out -match "(?m)^  FAIL .*tool: tool@latest isn't runnable") "and the shim that depends on it"

    $x = Fault "orphan" { param($h) Copy-Item "$h\shim\sym_shim.exe" "$h\bin\ghost.exe" }
    Check ($x.R.Code -eq 0 -and $x.R.Out -match "(?m)^  warn .*bin\\ghost\.exe has no descriptor") "an exe in bin\ with no descriptor: warning"

    $x = Fault "temp" { param($h) Set-Content "$h\bin\half.exe.tmp" "x" }
    Check ($x.R.Code -eq 0 -and $x.R.Out -match "(?m)^  warn .*leftover temp file bin\\half\.exe\.tmp") "a leftover .tmp from an interrupted write: warning"

    $x = Fault "malformed" { param($h) Set-Content "$h\shims\bad.toml" 'package = "only"' }
    Check ($x.R.Code -eq 1 -and $x.R.Out -match "(?m)^  FAIL .*bad: .* is missing package, command or version") "a malformed descriptor: failure"

    $h = New-Home "doctor-pins"
    $pp = Join-Path $work "doctor-pin-proj"; New-Item -ItemType Directory -Force $pp | Out-Null
    Set-Content (Join-Path $pp "sym.toml") "tool = `"9.9`"`nnosuch = `"1`"" -NoNewline
    $r = Sym @("doctor") -Cwd $pp -OnPath
    Check ($r.Code -eq 1 -and $r.Out -match "(?m)^  FAIL .*tool is pinned to 9\.9 but .* doesn't exist") "a pin to an uninstalled version: failure"
    Check ($r.Out -match "(?m)^  warn .*nosuch is pinned to 1 but was never shimmed") "a pin for a never-shimmed tool: warning"
    Set-Content (Join-Path $pp "sym.toml") 'tool = "1.0"' -NoNewline
    $r = Sym @("doctor") -Cwd $pp -OnPath
    Check ($r.Code -eq 0 -and $r.Out -match "tool = 1\.0 is installed") "a good pin passes"

    $r = Sym @("doctor") -Home_ (Join-Path $work "does-not-exist") -OnPath
    Check ($r.Code -eq 1 -and $r.Out -match "Sym home not found") "no Sym home at all: failure, and it doesn't crash"
}
finally {
    # remove aliases (junctions) first so the recursive cleanup can never reach through one
    if (Test-Path $work) {
        Get-ChildItem $work -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
            ForEach-Object { try { [IO.Directory]::Delete($_.FullName) } catch { } }
        [IO.Directory]::Delete($work, $true)
    }
}

if ($script:failures -eq 0) { Write-Host "`nPASS: all command checks"; exit 0 }
Write-Host "`nFAIL: $($script:failures) check(s) failed"; exit 1
