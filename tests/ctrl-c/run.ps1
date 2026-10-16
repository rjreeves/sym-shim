<#
    Regression test: what happens to the shim when the user presses Ctrl+C.

    Pressing Ctrl+C delivers the signal to EVERY process attached to the
    console -- the shim and the real program behind it. A program such as a
    shell handles it itself and carries on. If the shim simply dies, the
    terminal gets its prompt back while the real program is still running
    behind it (both now reading the keyboard) and the program's real exit
    status is lost. The shim must therefore ignore Ctrl+C while it waits and
    return whatever the program exits with. This is done in Certo's
    Process.execInherit, so a compiler change could silently undo it.

    Each scenario runs in its own hidden console and Ctrl+C is delivered the
    way a terminal does it. The same test program is also run WITHOUT the
    shim as a baseline, so a harness that can't deliver Ctrl+C (or a program
    that doesn't behave as described) fails loudly instead of letting a broken
    shim pass.

    Needs a C compiler for the three tiny helpers in this folder (clang or
    gcc; certo needs one anyway). Takes about half a minute. Builds the shim
    from source unless -ShimExe is given. Exits 0 on success, 1 on any failure.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$ShimExe,
    [string]$Cc
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-ctrl-c-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null
$script:failures = 0
$STATUS_CONTROL_C_EXIT = [uint32]3221225786     # 0xC000013A: what Windows reports for a process ended by Ctrl+C

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" } else { Write-Host "  FAIL $what"; $script:failures++ }
}
function Find-CCompiler {
    if ($Cc) { return $Cc }
    foreach ($name in "clang", "gcc") { $c = Get-Command $name -ErrorAction SilentlyContinue; if ($c) { return $c.Source } }
    foreach ($p in "C:\Program Files\LLVM\bin\clang.exe", "C:\Program Files (x86)\LLVM\bin\clang.exe") { if (Test-Path $p) { return $p } }
    throw "no C compiler found (looked for clang and gcc). Install LLVM, or pass -Cc <path to clang or gcc>."
}
function Alive([int]$id) { $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }

# One scenario: start `kid` (directly, or through the shim) in its own console, send Ctrl+C
# after 1.5s if asked, then watch until both the launched process and the real program are gone.
function Scenario([string]$name, [bool]$viaShim, [string]$mode, [bool]$sendCtrlC) {
    $log = Join-Path $work "$name.log"
    $pidFile = Join-Path $work "$name.pid"
    $codeFile = Join-Path $work "$name.code"
    $env:CTRLC_LOG = $log; $env:CTRLC_MODE = $mode; $env:SYM_HOME = $script:symHome
    $cmd = if ($viaShim) { "$($script:symHome)\bin\kid.exe" } else { "$($script:symHome)\packages\kid\1\kid.exe" }
    $null = Start-Process -FilePath "$work\launch.exe" -ArgumentList @("`"$work`"", "`"$cmd`"", "`"$codeFile`"") -RedirectStandardOutput $pidFile -WindowStyle Hidden -PassThru
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    while ($t0.Elapsed.TotalSeconds -lt 5 -and -not ((Test-Path $pidFile) -and ((Get-Content $pidFile -Raw) -match '^\d+'))) { Start-Sleep -Milliseconds 50 }
    $launchedPid = [int]((Get-Content $pidFile -Raw).Trim())
    $proc = [Diagnostics.Process]::GetProcessById($launchedPid)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 1500

    $childPid = 0
    if (Test-Path $log) { $m = [regex]::Match((Get-Content $log -Raw), 'child: start pid=(\d+)'); if ($m.Success) { $childPid = [int]$m.Groups[1].Value } }
    if ($sendCtrlC) { $null = & "$work\sendctrlc.exe" $launchedPid }

    $launchedGone = $null; $childGone = $null
    while ($sw.Elapsed.TotalSeconds -lt 10) {
        if ($null -eq $launchedGone -and $proc.HasExited) { $launchedGone = $sw.Elapsed.TotalSeconds }
        if ($childPid -ne 0 -and $null -eq $childGone -and -not (Alive $childPid)) { $childGone = $sw.Elapsed.TotalSeconds }
        if ($null -ne $launchedGone -and ($childPid -eq 0 -or $null -ne $childGone)) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $launchedGone) { try { $proc.Kill() } catch { } }
    if ($childPid -ne 0 -and $null -eq $childGone) { try { Stop-Process -Id $childPid -Force } catch { } }

    $exitCode = $null
    if ($null -ne $launchedGone) {
        $w = [Diagnostics.Stopwatch]::StartNew(); while ($w.Elapsed.TotalSeconds -lt 3 -and -not (Test-Path $codeFile)) { Start-Sleep -Milliseconds 50 }
        if (Test-Path $codeFile) { $exitCode = [uint32](Get-Content $codeFile -Raw).Trim() }
    }
    Remove-Item Env:\CTRLC_LOG, Env:\CTRLC_MODE, Env:\SYM_HOME -ErrorAction SilentlyContinue
    $logText = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
    # when the launched process is the child itself there is no separate "real program"
    if (-not $viaShim) { $childGone = $launchedGone }
    return @{ LaunchedGone = $launchedGone; ChildGone = $childGone; Code = $exitCode; Log = $logText; ChildStarted = ($childPid -ne 0) }
}
function Fmt($s) { if ($null -eq $s) { "never" } else { "{0:N1}s" -f $s } }
function CodeText($c) { if ($null -eq $c) { "unknown" } else { "{0} (0x{1:X8})" -f $c, $c } }

try {
    # ---------------------------------------------------------------- build
    $cc = Find-CCompiler
    foreach ($h in "child", "launch", "sendctrlc") {
        & $cc -O1 -Wno-deprecated-declarations "$here\$h.c" -o "$work\$h.exe" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$cc failed to build $h.c" }
    }
    if ($ShimExe) { $shim = (Resolve-Path -LiteralPath $ShimExe).Path }
    else {
        $shim = Join-Path $work "sym_shim.exe"
        & $Certo (Join-Path $repoRoot "src\sym_shim.cto") -o $shim | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "certo failed to build src\sym_shim.cto" }
    }
    # a scratch home: package "kid" 1 holds the test program, shimmed by the shim under test
    $script:symHome = Join-Path $work "home"
    foreach ($d in "bin", "shims", "packages\kid\1") { New-Item -ItemType Directory -Force (Join-Path $script:symHome $d) | Out-Null }
    Copy-Item "$work\child.exe" "$($script:symHome)\packages\kid\1\kid.exe"
    Copy-Item $shim "$($script:symHome)\bin\kid.exe"
    Set-Content "$($script:symHome)\shims\kid.toml" @('package = "kid"', 'command = "kid.exe"', 'version = "1"')

    # ------------------------------------------------- harness sanity (no shim)
    Write-Host "baseline: the program on its own (proves the test can see the difference)"
    $a = Scenario "direct-handle" $false "handle" $true
    Check ($a.Log -match "ctrl-c received") "Ctrl+C really reaches a console program"
    Check ($a.Code -eq 7 -and $a.Log -match "finished normally") "a program that handles it carries on and finishes (exit 7)"
    $e = Scenario "direct-default" $false "default" $true
    Check ($e.Code -eq $STATUS_CONTROL_C_EXIT -and $e.Log -notmatch "finished normally") "a program that doesn't handle it dies with 0xC000013A"

    # --------------------------------------------------------------- the shim
    Write-Host "`nthrough the shim"
    $d = Scenario "shim-control" $true "handle" $false
    Check ($d.Code -eq 7) "no Ctrl+C: the shim returns the program's exit code (7), got $(CodeText $d.Code)"
    Check ($null -ne $d.LaunchedGone -and $null -ne $d.ChildGone -and [math]::Abs($d.LaunchedGone - $d.ChildGone) -lt 1.0) "and finishes together with it"

    $b = Scenario "shim-handle" $true "handle" $true
    Check ($b.ChildStarted -and $b.Log -match "ctrl-c received") "Ctrl+C reached the real program behind the shim"
    Check ($null -ne $b.LaunchedGone -and $null -ne $b.ChildGone -and $b.LaunchedGone -ge ($b.ChildGone - 0.5)) "the shim did NOT exit before the program (it exited at $(Fmt $b.LaunchedGone), the program at $(Fmt $b.ChildGone))"
    Check ($b.Code -eq 7) "and it returned the program's real exit code (7), got $(CodeText $b.Code)"

    $c = Scenario "shim-default" $true "default" $true
    Check ($null -ne $c.ChildGone -and $c.ChildGone -lt 4.0 -and $c.Log -notmatch "finished normally") "a program that doesn't handle Ctrl+C still dies at once through the shim"
    Check ($c.Code -eq $STATUS_CONTROL_C_EXIT) "and the shim reports the same code as running it directly (0xC000013A), got $(CodeText $c.Code)"
}
finally {
    Get-Process -Name kid, child -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    [IO.Directory]::Delete($work, $true)
}

if ($script:failures -eq 0) { Write-Host "`nPASS: Ctrl+C behaves correctly through the shim"; exit 0 }
Write-Host "`nFAIL: $($script:failures) check(s) failed"; exit 1
