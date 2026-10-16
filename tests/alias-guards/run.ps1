<#
    End-to-end regression test for the alias guards in sym.exe.

    An alias (`sym alias`) is a directory junction. Anything that treats it
    as an ordinary folder acts on whatever real version it points at:
    `sym uninstall <pkg> latest` used to delete that version's contents, and
    `sym install <pkg> latest <file>` overwrites a file inside it. Both are
    now refused. This drives a real sym.exe against a scratch SYM_HOME to
    check the refusals -- and that nothing legitimate was broken: installing
    real versions, repointing an alias, and the dev flow where `latest` is
    just a plain folder that is overwritten in place on every install.

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
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-alias-guards-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
$script:failures = 0

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
}

# Runs sym.exe against the scratch home; every argument is quoted (none of
# ours contain a quote or end in a backslash).
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
function Content([string]$path) { if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { "<missing>" } }
function IsJunction([string]$path) {
    (Test-Path -LiteralPath $path) -and
    (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

try {
    if ($SymExe) { $script:sym = (Resolve-Path -LiteralPath $SymExe).Path }
    else {
        $script:sym = Join-Path $work "sym.exe"
        & $Certo (Join-Path $repoRoot "src\sym.cto") -o $script:sym | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "certo failed to build src\sym.cto" }
    }
    $script:symHome = Join-Path $work "home"
    New-Item -ItemType Directory -Force $script:symHome | Out-Null
    $pkgs = Join-Path $script:symHome "packages"

    Set-Content -LiteralPath (Join-Path $work "one.bin") -Value "ONE" -NoNewline
    Set-Content -LiteralPath (Join-Path $work "two.bin") -Value "TWO" -NoNewline
    $one = Join-Path $work "one.bin"; $two = Join-Path $work "two.bin"

    Write-Host "setup: install tool 1.0, alias latest -> 1.0"
    Check ((Sym "install", "tool", "1.0", $one, "tool.exe").Code -eq 0) "install a real version"
    Check ((Sym "alias", "tool", "latest", "1.0").Code -eq 0) "create the alias"
    Check (IsJunction "$pkgs\tool\latest") "latest is a junction"
    Check ((Content "$pkgs\tool\latest\tool.exe") -ceq "ONE") "latest resolves to 1.0"

    Write-Host "`nuninstall through the alias"
    $r = Sym "uninstall", "tool", "latest"
    Check ($r.Code -ne 0 -and $r.Err -match "is an alias") "refused, saying why"
    Check ((Content "$pkgs\tool\1.0\tool.exe") -ceq "ONE") "the real version's files are intact"
    Check (IsJunction "$pkgs\tool\latest") "the alias is still there"

    Write-Host "`ninstall a local file through the alias"
    $r = Sym "install", "tool", "latest", $two, "tool.exe"
    Check ($r.Code -ne 0 -and $r.Err -match "is an alias") "refused, saying why"
    Check ($r.Err -match "sym alias tool latest") "and tells you the fix"
    Check ((Content "$pkgs\tool\1.0\tool.exe") -ceq "ONE") "1.0 was NOT overwritten with the other build"
    Check (IsJunction "$pkgs\tool\latest") "the alias is still a junction"

    Write-Host "`nfetch-style install through the alias (no file given)"
    $r = Sym "install", "tool", "latest"
    Check ($r.Code -ne 0 -and $r.Err -match "is an alias") "refused up front"
    Check ($r.Err -notmatch "no source config") "before it ever looks for a source to download from"

    Write-Host "`nthe legitimate flow still works"
    Check ((Sym "install", "tool", "2.0", $two, "tool.exe").Code -eq 0) "install a second real version"
    Check ((Sym "alias", "tool", "latest", "2.0").Code -eq 0) "repoint the alias"
    Check ((Content "$pkgs\tool\latest\tool.exe") -ceq "TWO") "latest now resolves to 2.0"
    Check ((Content "$pkgs\tool\1.0\tool.exe") -ceq "ONE") "1.0 untouched by the repoint"
    Check ((Sym "uninstall", "tool", "1.0").Code -eq 0) "uninstall a real version"
    Check ((Content "$pkgs\tool\latest\tool.exe") -ceq "TWO") "the alias still resolves afterwards"

    Write-Host "`ndev flow: 'latest' as a plain folder (no alias) keeps working"
    Check ((Sym "install", "dev", "latest", $one, "dev.exe").Code -eq 0) "first install into a literal latest"
    Check (-not (IsJunction "$pkgs\dev\latest")) "it is an ordinary folder, not a junction"
    Check ((Content "$pkgs\dev\latest\dev.exe") -ceq "ONE") "holds the first build"
    Check ((Sym "install", "dev", "latest", $two, "dev.exe").Code -eq 0) "re-install overwrites in place"
    Check ((Content "$pkgs\dev\latest\dev.exe") -ceq "TWO") "now holds the second build"
}
finally {
    # remove the junction itself first, so cleanup can never reach through it
    $j = Join-Path $script:symHome "packages\tool\latest"
    if ($script:symHome -and (Test-Path -LiteralPath $j) -and (IsJunction $j)) { [IO.Directory]::Delete($j) }
    [IO.Directory]::Delete($work, $true)
}

if ($script:failures -eq 0) { Write-Host "`nPASS: all alias-guard checks"; exit 0 }
Write-Host "`nFAIL: $($script:failures) check(s) failed"; exit 1
