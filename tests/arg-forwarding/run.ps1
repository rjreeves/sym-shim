<#
    End-to-end regression test for argument forwarding through sym_shim.

    The shim receives its arguments already split by the OS, then has to
    flatten them back into one command line for CreateProcess; the child
    re-splits that with CommandLineToArgvW's rules. If the flattening
    quotes wrongly the child sees different arguments than the caller
    sent -- historically, anything ending in a backslash swallowed its
    closing quote and merged with the arguments after it (fixed upstream
    in Certo 749dc02). This builds a shim and an echo program from
    source, sends eight awkward arguments through, and diffs what arrives.

    Needs the certo compiler (a dev-time dependency, not an install one)
    to build the echo program, and the shim too unless -ShimExe is given.
    Pass -ShimExe to test an already-built shim instead -- e.g. a copy
    from %LOCALAPPDATA%\Sym\bin, to check that a stamped shim isn't still
    carrying an older compiler's runtime.
    Exits 0 on success, 1 on any mismatch.
#>
[CmdletBinding()]
param(
    [string]$Certo = "certo",
    [string]$ShimExe
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$work = Join-Path ([IO.Path]::GetTempPath()) ("sym-arg-forwarding-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work | Out-Null

function Build($source, $output) {
    & $Certo $source -o $output | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certo failed to build $source" }
}

try {
    Build (Join-Path $here "echoargs.cto") (Join-Path $work "echoargs.exe")
    if ($ShimExe) {
        Copy-Item $ShimExe (Join-Path $work "sym_shim.exe")
    } else {
        Build (Join-Path $repoRoot "src\sym_shim.cto") (Join-Path $work "sym_shim.exe")
    }

    $symHome = Join-Path $work "home"
    foreach ($d in "bin", "shims", "packages\echoargs\1") {
        New-Item -ItemType Directory -Force (Join-Path $symHome $d) | Out-Null
    }
    Copy-Item (Join-Path $work "echoargs.exe") (Join-Path $symHome "packages\echoargs\1\echoargs.exe")
    Copy-Item (Join-Path $work "sym_shim.exe") (Join-Path $symHome "bin\echoargs.exe")
    Set-Content (Join-Path $symHome "shims\echoargs.toml") -Value @(
        'package = "echoargs"', 'command = "echoargs.exe"', 'version = "1"'
    )

    # Written to follow CommandLineToArgvW's rules exactly, so the intended
    # argv is known: what the shim receives and must reproduce faithfully.
    $rawArgs = 'plain "with space" "trailing\\" "quote\"inside" "back\\\"quote" "" "C:\dir with space\\" a\b'
    $expected = @(
        '[plain]', '[with space]', '[trailing\]', '[quote"inside]',
        '[back\"quote]', '[]', '[C:\dir with space\]', '[a\b]'
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $symHome "bin\echoargs.exe"
    $psi.Arguments = $rawArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["SYM_HOME"] = $symHome
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $got = @($out -split "`r?`n" | Where-Object { $_ -ne "" })

    $failed = $false
    for ($i = 0; $i -lt [Math]::Max($expected.Count, $got.Count); $i++) {
        $e = if ($i -lt $expected.Count) { $expected[$i] } else { "<missing>" }
        $g = if ($i -lt $got.Count) { $got[$i] } else { "<missing>" }
        $ok = $e -ceq $g
        if (-not $ok) { $failed = $true }
        Write-Host ("{0} expected {1,-24} got {2}" -f $(if ($ok) { "ok  " } else { "FAIL" }), $e, $g)
    }
    if ($p.ExitCode -ne 0) { $failed = $true; Write-Host "shim exit code: $($p.ExitCode)" }
    if ($err) { Write-Host "stderr: $err" }

    if ($failed) { Write-Host "`nFAIL: arguments did not survive the shim intact"; exit 1 }
    Write-Host "`nPASS: all $($expected.Count) arguments survived the shim intact"
}
finally {
    [IO.Directory]::Delete($work, $true)
}
