<#
    End-to-end regression test for name validation in sym.exe.

    Package, version, alias and shim names all become folder or file names
    under the Sym home. Before validation existed they were used as raw path
    fragments, so:
        sym uninstall tool ""             deleted EVERY version of tool
        sym uninstall tool ..             deleted the whole packages\ folder
        sym install demo ..\escaped x     wrote outside the package's folder
        sym shim remove ..\sym            deleted <home>\sym.exe
    all reporting success. This drives a real sym.exe against a scratch home
    with sentinel files at the places those attacks reach, feeds every
    command that takes a name a set of bad values in every position, and
    checks that each is refused with an "invalid ..." message and that the
    WHOLE tree (the home and a sibling folder next to it) is byte-for-byte
    unchanged. It also checks that every kind of real name in use -- dotted
    and "+"-suffixed versions, hyphens, underscores, a command file with
    spaces -- still works.

    Builds sym.exe from source unless -SymExe is given (pass a built one to
    test it as-is). Exits 0 on success, 1 on any failed check.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$SymExe
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-name-validation-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
$script:failures = 0
$script:checks = 0

function Check([bool]$ok, [string]$what) {
    $script:checks++
    if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
}

# Runs sym.exe against $script:symHome; every argument is quoted (none of
# ours end in a backslash).
function Sym([string[]]$SymArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:sym
    $psi.Arguments = ($SymArgs | ForEach-Object { '"' + $_ + '"' }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["SYM_HOME"] = $script:symHome
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $out; Err = $err }
}

# A text picture of a tree: every folder, file (with its content) and
# junction, never following a junction.
function Snap([string]$root) {
    $lines = New-Object System.Collections.Generic.List[string]
    $walk = {
        param($dir)
        foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $rel = $e.Substring($root.Length)
            $attr = [IO.File]::GetAttributes($e)
            if ($attr -band [IO.FileAttributes]::ReparsePoint) { $lines.Add("J $rel") }
            elseif ($attr -band [IO.FileAttributes]::Directory) { $lines.Add("D $rel"); & $walk $e }
            else { $lines.Add("F $rel = " + [IO.File]::ReadAllText($e)) }
        }
    }
    & $walk $root
    ($lines | Sort-Object) -join "`n"
}

function Content([string]$path) { if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { "<missing>" } }

function Fill([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, $text)
}

# Delete a tree without ever following a junction (a buggy sym could have
# made one).
function Wipe-Tree([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
        $attr = [IO.File]::GetAttributes($e)
        if ($attr -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($e) }
        elseif ($attr -band [IO.FileAttributes]::Directory) { Wipe-Tree $e }
        else { [IO.File]::Delete($e) }
    }
    [IO.Directory]::Delete($dir)
}

try {
    if ($SymExe) { $script:sym = (Resolve-Path -LiteralPath $SymExe).Path }
    else {
        $script:sym = Join-Path $work "sym.exe"
        & $Certo (Join-Path $repoRoot "src\sym.cto") -o $script:sym | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "certo failed to build src\sym.cto" }
    }

    # ---- part 1: bad names are refused and nothing changes -----------------
    #
    #   $area\home\...      the Sym home, with sentinels where attacks land
    #   $area\outside\...   a sibling an escaping path could reach
    $area = Join-Path $work "area"
    $script:symHome = Join-Path $area "home"
    $src = Join-Path $work "src.bin"
    [IO.File]::WriteAllText($src, "SRC")
    $proj = Join-Path $area "proj"

    Fill "$script:symHome\packages\tool\1.0\tool.exe" "TOOL-1.0"
    Fill "$script:symHome\packages\tool\2.0\tool.exe" "TOOL-2.0"
    Fill "$script:symHome\packages\other\1.0\other.exe" "OTHER-1.0"
    Fill "$script:symHome\shim\sym_shim.exe" "MASTER-SHIM"
    Fill "$script:symHome\bin\tool.exe" "MASTER-SHIM"
    Fill "$script:symHome\shims\tool.toml" "package = `"tool`"`ncommand = `"tool.exe`"`nversion = `"1.0`"`n"
    Fill "$script:symHome\sym.exe" "SENTINEL-SYM-EXE"
    Fill "$script:symHome\keep.txt" "KEEP"
    Fill "$area\outside\victim.txt" "VICTIM"
    New-Item -ItemType Directory -Force $proj | Out-Null

    $bad = @(
        @{ v = "";               label = '""' },
        @{ v = ".";              label = '.' },
        @{ v = "..";             label = '..' },
        @{ v = "...";            label = '...' },
        @{ v = "..\escaped";     label = '..\escaped' },
        @{ v = "../escaped";     label = '../escaped' },
        @{ v = "..\..\outside";  label = '..\..\outside' },
        @{ v = "a\b";            label = 'a\b' },
        @{ v = "a/b";            label = 'a/b' },
        @{ v = "C:\x";           label = 'C:\x' },
        @{ v = "a:b";            label = 'a:b' },
        @{ v = "a b";            label = 'a b' },
        @{ v = "a=b";            label = 'a=b' },
        @{ v = "-x";             label = '-x' },
        @{ v = "x.";             label = 'x.' },
        @{ v = "a`nb";           label = 'a<newline>b' }
    )
    # (template; the bad value replaces BAD)
    $templates = @(
        "install BAD 1.0 SRC tool.exe", "install demo BAD SRC tool.exe", "install demo BAD",
        "uninstall BAD 1.0", "uninstall tool BAD",
        "use BAD 1.0", "use tool BAD",
        "pin BAD 1.0 PROJ", "pin tool BAD PROJ",
        "alias BAD latest 1.0", "alias tool BAD 1.0", "alias tool latest BAD",
        "shim add BAD tool 1.0", "shim add n BAD 1.0", "shim add n tool BAD",
        "shim add-all BAD 1.0", "shim add-all tool BAD",
        "shim remove BAD",
        "which BAD"
    )

    $before = Snap $area
    Write-Host "bad names, in every position of every command that takes one"
    $bad_cases = 0
    foreach ($b in $bad) {
        foreach ($t in $templates) {
            $a = @($t -split ' ' | ForEach-Object {
                if ($_ -eq "BAD") { $b.v } elseif ($_ -eq "SRC") { $src } elseif ($_ -eq "PROJ") { $proj } else { $_ }
            })
            $r = Sym $a
            $after = Snap $area
            $ok = ($r.Code -ne 0) -and ($r.Err -match "invalid") -and ($after -ceq $before)
            $bad_cases++
            if (-not $ok) {
                $why = @()
                if ($r.Code -eq 0) { $why += "exited 0" }
                if ($r.Err -notmatch "invalid") { $why += "no 'invalid' message (stderr: $($r.Err.Trim()))" }
                if ($after -cne $before) { $why += "THE TREE CHANGED" }
                Check $false ("sym " + ($t -replace 'BAD', $b.label) + " -- " + ($why -join "; "))
                # re-baseline so one failure doesn't cascade through the rest
                $before = $after
            }
        }
    }
    Check $true "$bad_cases refusals ($($bad.Count) bad values x $($templates.Count) positions): non-zero exit, 'invalid' message, whole tree unchanged"

    Write-Host "`nthe four original disasters, by name"
    foreach ($case in @(
        @{ name = 'uninstall tool ""';          args = @("uninstall", "tool", "");                    guard = "$script:symHome\packages\tool\1.0\tool.exe"; want = "TOOL-1.0" },
        @{ name = 'uninstall tool ..';          args = @("uninstall", "tool", "..");                  guard = "$script:symHome\packages\other\1.0\other.exe"; want = "OTHER-1.0" },
        @{ name = 'install demo ..\escaped';    args = @("install", "demo", "..\escaped", $src, "x.exe"); guard = "$script:symHome\packages\escaped"; want = "<missing>" },
        @{ name = 'shim remove ..\sym';         args = @("shim", "remove", "..\sym");                 guard = "$script:symHome\sym.exe"; want = "SENTINEL-SYM-EXE" }
    )) {
        $r = Sym $case.args
        Check ($r.Code -ne 0 -and (Content $case.guard) -ceq $case.want) "sym $($case.name): refused, and the thing it used to destroy/create is untouched"
    }

    Write-Host "`nbad command file names"
    $badFiles = @(
        @{ v = "";            label = '""' },
        @{ v = "..";          label = '..' },
        @{ v = "..\x.exe";    label = '..\x.exe' },
        @{ v = "a/b.exe";     label = 'a/b.exe' },
        @{ v = "C:\x.exe";    label = 'C:\x.exe' },
        @{ v = "a*b.exe";     label = 'a*b.exe' },
        @{ v = "a?b.exe";     label = 'a?b.exe' },
        @{ v = "a|b.exe";     label = 'a|b.exe' },
        @{ v = "x.exe.";      label = 'x.exe.' }
    )
    $fileTemplates = @("install demo 1.0 SRC BAD", "shim add n tool 1.0 BAD")
    $bad_cases = 0
    foreach ($b in $badFiles) {
        foreach ($t in $fileTemplates) {
            $a = @($t -split ' ' | ForEach-Object {
                if ($_ -eq "BAD") { $b.v } elseif ($_ -eq "SRC") { $src } else { $_ }
            })
            $r = Sym $a
            $after = Snap $area
            $bad_cases++
            if (-not (($r.Code -ne 0) -and ($r.Err -match "invalid") -and ($after -ceq $before))) {
                Check $false ("sym " + ($t -replace 'BAD', $b.label) + " -- exit $($r.Code), stderr '$($r.Err.Trim())', tree changed: $($after -cne $before)")
                $before = $after
            }
        }
    }
    Check $true "$bad_cases command-file refusals: non-zero exit, 'invalid' message, tree unchanged"

    Write-Host "`nthe message says what and why"
    $r = Sym "uninstall", "tool", ".."
    Check ($r.Err -match "invalid version '\.\.'") "names the kind of value and the value"
    $r = Sym "alias", "tool", "a b", "1.0"
    Check ($r.Err -match "invalid alias 'a b'" -and $r.Err -match "' '") "an alias with a space: says alias, and which character"
    $r = Sym "shim", "remove", "..\sym"
    Check ($r.Err -match "invalid shim name") "a shim name is called a shim name"

    Write-Host "`nusage lists the allowed characters"
    $r = Sym "bogus-command"
    Check ($r.Err -match "letters, digits and") "sym with an unknown command prints the naming rule"

    Write-Host "`nshim add-all skips an executable whose name can't be a shim, and shims the rest"
    Fill "$script:symHome\packages\multi\1.0\good.exe" "GOOD"
    Fill "$script:symHome\packages\multi\1.0\bad name.exe" "BAD"
    Fill "$script:symHome\packages\multi\1.0\also-good.exe" "ALSO"
    $r = Sym "shim", "add-all", "multi", "1.0"
    Check ($r.Code -eq 0) "exits 0 (a skip is not a failure)"
    Check ($r.Out -match "skipped 'bad name\.exe'") "says it skipped the odd one, by file name"
    Check ((Test-Path "$script:symHome\bin\good.exe") -and (Test-Path "$script:symHome\bin\also-good.exe")) "the valid ones are shimmed"
    Check (-not (Test-Path "$script:symHome\bin\bad name.exe")) "no shim was made for the invalid one"
    Check ($r.Out -match "shimmed 2, skipped 1, failed 0") "summary counts add up"

    # ---- part 2: every real name still works -------------------------------
    Write-Host "`nreal names in use still work"
    $script:symHome = Join-Path $work "home2"
    New-Item -ItemType Directory -Force $script:symHome | Out-Null
    Fill "$script:symHome\shim\sym_shim.exe" "MASTER-SHIM"
    $pkgs = "$script:symHome\packages"

    $good = @(
        @{ p = "certo";       v = "1.0.72.261016.86";                              f = "certo.exe" },
        @{ p = "certo";       v = "1.0.73";                                        f = "certo.exe" },
        @{ p = "ion-win";     v = "0.1.0-bootstrap";                               f = "ion-win.exe" },
        @{ p = "pg_sentinel"; v = "0.9.0+598c4bbae470136da6fd3ca33966fc431e337c8a"; f = "pg_sentinel.exe" },
        @{ p = "db_users";    v = "1.8.0";                                         f = "My Tool (x64).exe" },
        @{ p = "win";         v = "latest";                                        f = "win.exe" }
    )
    foreach ($g in $good) {
        $r = Sym "install", $g.p, $g.v, $src, $g.f
        Check ($r.Code -eq 0 -and (Content "$pkgs\$($g.p)\$($g.v)\$($g.f)") -ceq "SRC") "install $($g.p) $($g.v) as '$($g.f)'"
    }
    $r = Sym "alias", "certo", "latest", "1.0.72.261016.86"
    Check ($r.Code -eq 0 -and (Content "$pkgs\certo\latest\certo.exe") -ceq "SRC") "alias certo latest -> 1.0.72.261016.86"
    $r = Sym "alias", "ion-win", "lts", "0.1.0-bootstrap"
    Check ($r.Code -eq 0) "alias ion-win lts -> 0.1.0-bootstrap"
    $r = Sym "shim", "add", "pg_sentinel", "pg_sentinel", "0.9.0+598c4bbae470136da6fd3ca33966fc431e337c8a"
    Check ($r.Code -eq 0 -and (Test-Path "$script:symHome\bin\pg_sentinel.exe")) "shim add pg_sentinel"
    $r = Sym "shim", "add", "mytool", "db_users", "1.8.0", "My Tool (x64).exe"
    Check ($r.Code -eq 0 -and (Content "$script:symHome\shims\mytool.toml") -match 'My Tool \(x64\)\.exe') "shim add with a command file that has spaces and parentheses"
    $r = Sym "shim", "add-all", "certo", "1.0.73"
    Check ($r.Code -eq 0 -and (Test-Path "$script:symHome\bin\certo.exe")) "shim add-all certo 1.0.73"
    $r = Sym "use", "certo", "1.0.73"
    Check ($r.Code -eq 0) "use certo 1.0.73"
    $r = Sym "which", "pg_sentinel"
    Check ($r.Code -eq 0) "which pg_sentinel"
    $r = Sym "list", "certo"
    Check ($r.Code -eq 0 -and $r.Out -match "1\.0\.72\.261016\.86" -and $r.Out -match "1\.0\.73") "list certo shows both versions"
    $r = Sym "uninstall", "certo", "1.0.73"
    Check ($r.Code -eq 0 -and -not (Test-Path "$pkgs\certo\1.0.73") -and (Test-Path "$pkgs\certo\1.0.72.261016.86")) "uninstall one version leaves the other"
    $r = Sym "shim", "remove", "pg_sentinel"
    Check ($r.Code -eq 0 -and -not (Test-Path "$script:symHome\bin\pg_sentinel.exe")) "shim remove pg_sentinel"
}
finally {
    # never follow a junction when cleaning up
    Wipe-Tree $work
}

Write-Host ""
if ($script:failures -eq 0) { Write-Host "PASS: all $($script:checks) name-validation checks"; exit 0 }
Write-Host "FAIL: $($script:failures) of $($script:checks) check(s) failed"; exit 1
