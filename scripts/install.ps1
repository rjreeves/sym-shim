<#
.SYNOPSIS
    Sets up sym on a machine from scratch, from pre-built binaries.

.DESCRIPTION
    Creates the Sym\ directory layout, copies sym.exe and sym_shim.exe
    into place, smoke-tests the installed sym.exe, and (with -AddToPath)
    puts Sym\ and Sym\bin on the user PATH.

    Needs nothing else on the machine: no Certo compiler, no build tools,
    no admin rights. Building the binaries is a dev-time step (see
    docs/USAGE.md steps 1-2); this script only installs them.

    The binaries are looked up next to this script first, then in its
    parent folder -- so it works both from a flat release folder
    (install.ps1, sym.exe and sym_shim.exe together) and from a checkout
    (scripts\install.ps1 with the build output in the repo root). Re-running
    is safe: layout creation is idempotent, binaries are overwritten, and
    PATH entries already present are not added twice.

    Windows only. A tool fetched with `sym install <pkg> <ver>` (no local
    file) also needs the `tar` that ships with Windows 10 1803 and later;
    this script warns if it is missing.

.PARAMETER SymHome
    Install location. Defaults to $env:SYM_HOME, else %LOCALAPPDATA%\Sym.

.PARAMETER SymExe
.PARAMETER SymShimExe
    Explicit paths to the pre-built binaries, overriding the lookup.

.PARAMETER AddToPath
    Add Sym\ (so `sym` resolves) and Sym\bin (so shimmed tools resolve) to
    the user PATH. Without this switch PATH is never touched.

.PARAMETER EnvRegistryKey
    Testing only: the HKCU subkey holding the Path value. Leave at the
    default, which is the real user environment.
#>
[CmdletBinding()]
param(
    [string]$SymHome,
    [string]$SymExe,
    [string]$SymShimExe,
    [switch]$AddToPath,
    [string]$EnvRegistryKey = "Environment"
)

$ErrorActionPreference = "Stop"

if (-not $SymHome) {
    if ($env:SYM_HOME) { $SymHome = $env:SYM_HOME }
    elseif ($env:LOCALAPPDATA) { $SymHome = Join-Path $env:LOCALAPPDATA "Sym" }
    else { throw "Neither SYM_HOME nor LOCALAPPDATA is set. Pass -SymHome <folder>." }
}

function Find-Binary([string]$Name, [string]$Explicit) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "$Name not found at $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $searched = @(
        (Join-Path $PSScriptRoot $Name),
        (Join-Path (Split-Path -Parent $PSScriptRoot) $Name)
    )
    foreach ($candidate in $searched) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw ("$Name not found. Looked in:`n  " + ($searched -join "`n  ") +
           "`nThis script installs pre-built binaries only -- put $Name next to it, " +
           "or pass its location explicitly (-SymExe / -SymShimExe).")
}

# Copy to a sibling temp name, then rename over the destination, so a
# failure part-way never leaves a truncated exe behind. A no-op when
# source and destination are the same file (re-running from inside Sym\).
function Install-File([string]$Source, [string]$Destination) {
    if ((Test-Path -LiteralPath $Destination) -and
        ((Resolve-Path -LiteralPath $Destination).Path -ieq $Source)) {
        Write-Host "  already in place: $Destination"
        return
    }
    $temp = "$Destination.new"
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } catch {
        if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
        throw "Could not write $Destination ($($_.Exception.Message)). " +
              "If a shimmed tool or sym itself is running, close it and re-run."
    }
    # A zip that came from a browser or email marks every extracted file as
    # downloaded, so Windows would warn (SmartScreen) the first time sym.exe
    # ran. The user has chosen to install these; clear the mark on the copies.
    Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    Write-Host "  $Source -> $Destination"
}

function Normalize-PathEntry([string]$Entry) {
    [Environment]::ExpandEnvironmentVariables($Entry).TrimEnd('\').ToLowerInvariant()
}

# Edits the raw registry value instead of using [Environment]'s User-scope
# Get/SetEnvironmentVariable: those hand back (and then write back) the
# *expanded* string, which permanently flattens any %USERPROFILE%-style
# entry already in the user's PATH, and rewrites an expandable value as a
# plain string. Reading the unexpanded text and keeping the value's
# existing type avoids both. Returns the entries actually added.
function Add-UserPathEntries([string[]]$Entries, [string]$KeyPath) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($KeyPath)
    try {
        $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        try { $kind = $key.GetValueKind("Path") } catch { }

        $current = @($raw -split ";" | Where-Object { $_ -ne "" })
        $have = @($current | ForEach-Object { Normalize-PathEntry $_ })
        $added = @()
        foreach ($entry in $Entries) {
            if ($have -notcontains (Normalize-PathEntry $entry)) {
                $current += $entry
                $added += $entry
            }
        }
        if ($added.Count -gt 0) { $key.SetValue("Path", ($current -join ";"), $kind) }
        return ,$added
    } finally {
        $key.Dispose()
    }
}

# Tells running programs (Explorer, and through it any new terminal) that
# the environment changed, so a freshly opened shell sees the new PATH
# without a logoff. Best-effort: a failure only means re-logging in.
function Send-EnvironmentChange {
    try {
        Add-Type -Namespace SymInstaller -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        $result = [UIntPtr]::Zero
        [void][SymInstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero,
            "Environment", 2, 5000, [ref]$result)
    } catch {
        Write-Warning "Could not broadcast the environment change; sign out and back in if a new terminal doesn't see sym."
    }
}

# ---------------------------------------------------------------- install

$symSource = Find-Binary "sym.exe" $SymExe
$shimSource = Find-Binary "sym_shim.exe" $SymShimExe

Write-Host "Installing sym into $SymHome"
Write-Host "  from sym.exe:      $symSource"
Write-Host "  from sym_shim.exe: $shimSource"

if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Warning "tar not found on PATH. 'sym install <pkg> <ver>' (fetching an archive) needs the tar that ships with Windows 10 1803+. Installing from a local file still works."
}

Write-Host "`nCreating layout..."
foreach ($sub in "shim", "bin", "shims", "packages", "sources") {
    $path = Join-Path $SymHome $sub
    New-Item -ItemType Directory -Force $path | Out-Null
    Write-Host "  $path"
}

Write-Host "`nCopying binaries..."
$symDest = Join-Path $SymHome "sym.exe"
Install-File $symSource $symDest
Install-File $shimSource (Join-Path $SymHome "shim\sym_shim.exe")

# Prove the installed copy actually runs before declaring success: a
# damaged download or a blocked executable shows up here, not later as a
# confusing failure inside the first shimmed tool.
Write-Host "`nSmoke test..."
$previousHome = $env:SYM_HOME
$env:SYM_HOME = $SymHome
try {
    & $symDest shim list | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "installed sym.exe exited with code $LASTEXITCODE on 'sym shim list'" }
} finally {
    [Environment]::SetEnvironmentVariable("SYM_HOME", $previousHome, "Process")
}
Write-Host "  sym.exe runs"

$binDir = Join-Path $SymHome "bin"
if ($AddToPath) {
    Write-Host "`nUpdating user PATH..."
    $added = Add-UserPathEntries @($SymHome, $binDir) $EnvRegistryKey
    if ($added.Count -eq 0) {
        Write-Host "  already present, nothing to add"
    } else {
        $added | ForEach-Object { Write-Host "  added $_" }
        if ($EnvRegistryKey -eq "Environment") { Send-EnvironmentChange }
        Write-Host "  open a NEW terminal for it to take effect"
    }
} else {
    Write-Host "`nPATH not modified. Add these yourself, or re-run with -AddToPath:"
    Write-Host "  $SymHome   (so the 'sym' command resolves)"
    Write-Host "  $binDir   (so shimmed tools resolve)"
}

Write-Host "`nDone. Next:"
Write-Host "  sym install <package> <version> <file> [<command-filename>]"
Write-Host "  sym shim add <name> <package> <version>"
