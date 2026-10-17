# Using sym-shim

This is a practical, step-by-step guide to setting up and using the shim.
For the design rationale behind each of these behaviors, see the main
[README](../README.md); this document is about *doing*, not *why*.

**Scope note:** this repo ships two things — the shim binary
(`src/sym_shim.cto`) and a small `sym` CLI (`src/sym.cto`) implementing
`install`/`uninstall`/`use`/`shim add`/`shim remove`/`shim list`/`pin`. `install`
can fetch a real GitHub release itself (with checksum verification) or
take an already-obtained local file — see step 4. Every section below
also shows the raw filesystem operations each `sym` command performs
— useful for understanding what's actually happening, or for scripting
around `sym` if you'd rather not depend on it.

## 1. Prerequisites

You need the `certo` compiler on `PATH` to build the shim. It's not
packaged anywhere conventional (no apt/choco/winget entry) — build it
from source, pinned to the exact commit `sym`/`sym_shim` are verified
against:

```bash
cargo install --git https://github.com/rjreeves/Certo --rev 6d16532478f39117041cec792c41778905624ba6 certo
```

That commit is the one with everything this project needs
(`Process.execInherit` with its `workingDir` argument, correct Windows
argument quoting and Ctrl+C handling, `getCurrentDir`,
`HttpResponse.bodyBytes`, `renameFile`, `removeDir`) — verified by
building `src/sym.cto` and `src/sym_shim.cto` and running every test
suite listed below against it directly. Don't pin earlier than the
commit that introduced each of these, both inside `execInherit`:

- `749dc02` — before it, `execInherit` takes two arguments (this
  project's code passes three) and mangles any argument ending in a
  backslash.
- `6d16532` — before it, the shim dies the instant you press Ctrl+C even
  when the tool behind it handles Ctrl+C itself, leaving that tool running
  with nothing waiting on it and its real exit status lost. A shim built
  by an older compiler fails `tests/ctrl-c`, and `scripts/package-release.ps1`
  refuses to package it.

Certo has
exactly one tagged release (`v0.1.0`, June 2026), which predates all of
these, so a release build won't work here; pinning to a commit instead
of `--branch master` means a future, unrelated change to Certo's
`master` can't silently break this project's build (the
`execInherit` signature change above is exactly that kind of change).
Re-pin to a newer commit only after checking it still builds
`src/sym.cto` and `src/sym_shim.cto` and passes the tests in
`src/AtomicWrite.cto`, `src/Junction.cto`, `src/ShimConfig.cto`,
`src/Glob.cto`, `src/Names.cto` (run each with `certo test`), and
`tests/arg-forwarding`, `tests/alias-guards`, `tests/name-validation`,
`tests/commands`, `tests/install-package` and `tests/ctrl-c`.

(Note: `certo` is a Cargo workspace with several binary-producing
crates, so the package name `certo` must be passed explicitly — `--bin
certo` alone is ambiguous and fails.)

## 2. Build the shim and the installer

```bash
certo src/sym_shim.cto -o sym_shim.exe
certo src/sym.cto -o sym.exe
```

`sym_shim.exe` is generic — it doesn't know which tool it's fronting
until you copy it under a specific name (step 6). `sym.exe` is the CLI
that does that copying and the rest of the bookkeeping for you. By hand
you can keep it wherever's convenient on your own `PATH`; the installer
below puts it in the `Sym\` folder itself, next to `shim\` and `bin\`.

## 3. Set up the directory layout

**On a machine that only needs to *run* sym** — no Certo, no build —
skip steps 1–2 and this one. Build once, on a machine that has Certo:

```powershell
.\scripts\package-release.ps1
```

That builds both binaries, runs the tests against exactly those builds
(and refuses to package if one fails), and writes
`dist\sym-<date>-<commit>\` plus a `.zip` containing `sym.exe`,
`sym_shim.exe`, `install.cmd`, `install.ps1`, a `README.txt`, and a
`BUILD-INFO.txt` recording the commit, the Certo version and a SHA-256 of
every file. If you ship the binaries inside a larger bundle, add
`-CopyTo <folder>` and the same six files are also copied into that
folder (nothing else in it is touched, each copy is verified by hash, and
the output says which files were updated, added or already current) so
the bundle can't quietly go stale. It refuses to run from a tree with
uncommitted changes (`-AllowDirty` overrides) or with `-SkipTests`, since
a shipped bundle should be tested and traceable to a commit; both checks
happen before the build starts. Copy that folder or zip to the target PC and run
`install.cmd` there (double-click works; it clears the "downloaded from
the internet" mark on the extracted files first, so a `RemoteSigned`
policy doesn't refuse `install.ps1`, though an `AllSigned` policy still
would). It
creates the layout below, copies both binaries into place, runs
`sym shim list` against the result to confirm the install works, and
adds `Sym\` and `Sym\bin` to your user PATH. Open a new terminal
afterwards. It needs no admin rights and is safe to re-run (it also
works as a way to update the binaries). To install without touching
PATH, run `install.ps1` directly instead — PATH is only changed when
you pass `-AddToPath`, which `install.cmd` does for you. Running it
straight from a checkout also works: it finds the binaries in the repo
root. The PATH edit works on the raw registry value, so existing
`%USERPROFILE%`-style entries are left exactly as they were.

The rest of this step is what the installer does, for doing it by hand.

The shim expects this structure under `%LOCALAPPDATA%\Sym` (or wherever
`SYM_HOME` points, if you set that environment variable):

```
%LOCALAPPDATA%\Sym\
    shim\       <- the master sym_shim.exe build lives here, never on PATH
    bin\        <- per-tool copies of shim\sym_shim.exe; the only PATH entry needed
    shims\      <- one <name>.toml descriptor per shimmed tool
    packages\   <- actual installed binaries, one folder per version
```

Create the four folders once:

```powershell
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Sym\shim"
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Sym\bin"
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Sym\shims"
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Sym\packages"
```

Copy the binary you just built into its permanent home:

```powershell
Copy-Item sym_shim.exe "$env:LOCALAPPDATA\Sym\shim\sym_shim.exe"
```

Keeping one master copy here — separate from `bin\`, and not wherever
it happened to be built — means shimming a new tool later is always a
copy from `shim\sym_shim.exe`, never a recompile from Certo source.

Add `%LOCALAPPDATA%\Sym\bin` to your `PATH` — this is the **only** PATH
change ever required, no matter how many tools you shim later.
`shim\` is deliberately never added to `PATH`.

## 4. Install a real version of a tool

**What names are allowed.** A package, version, alias or shim name
becomes a folder or file name under the Sym home, so `sym` accepts only
letters, digits and `. _ + -`, starting with a letter or digit and not
ending in `.`. That covers real names such as `certo`, `ion-win`,
`pg_sentinel`, `1.0.72.261016.86`, `0.9.0+598c4bb…` and `latest`. Anything
else — an empty string, `.`, `..`, a path (`..\x`, `a/b`, `C:\x`), spaces,
`=` — is refused with `sym: invalid <kind> '<value>': <why>` before
anything on disk is touched. (Without this, `sym uninstall tool ..`
deleted the whole `packages\` folder.) The `<command-filename>` is
looser — spaces and parentheses are fine in `My Tool.exe` — but it must
still be one plain file name, never a path. `sym shim add-all` skips,
and says it skipped, any executable whose name can't be a shim name.

Two ways to install: give `sym install` a file you already have, or let
it fetch one.

**With a local file:**

```bash
sym install certo 1.8.0 C:\path\to\certo-1.8.0.exe certo.exe
```

This copies (binary-safe — see the code walkthrough for why that
matters) the given file to `packages\certo\1.8.0\certo.exe`, creating
the version folder if needed. The trailing `certo.exe` names the file
inside that folder; if omitted, it defaults to the source file's own
name. Equivalent by hand:

```powershell
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Sym\packages\certo\1.8.0"
Copy-Item "C:\path\to\certo-1.8.0.exe" "$env:LOCALAPPDATA\Sym\packages\certo\1.8.0\certo.exe"
```

**Fetching instead** — omit the file argument, and write a source
config once per package first:

```toml
# %LOCALAPPDATA%\Sym\sources\certo.toml
provider = "github-release"
repo = "rjreeves/Certo"
tag = "v{version}"
asset = "certo-windows-x86_64.zip"
archive = "tar"
binary_path = "certo.exe"
```

```bash
sym install certo 1.8.0
```

This downloads `https://github.com/rjreeves/Certo/releases/download/v1.8.0/certo-windows-x86_64.zip`,
extracts it (via the `tar` binary bundled with Windows — no extra
install needed; `archive = "tar"` handles `.zip`, `.tar`, and
`.tar.gz`/`.tgz` alike, not just zip despite the name), and places
`certo.exe` the same way the local-file path would. For anything not
on GitHub — GitLab, a project's own server — use `provider = "url"`
with a fully-specified `url = "..."` template instead of
`repo`/`tag`/`asset`; see the README's "Fetching a package" section.
Add `%LOCALAPPDATA%\Sym\sources\certo\checksums.toml` with
a `<version> = "<sha256-hex>"` line to have the download verified
before it's installed — without one, `sym install` still works, just
prints an "unverified" warning. See the README's "Fetching a package"
section for the full format and the reasoning behind pinning checksums
separately rather than trusting whatever the release itself publishes.

**Installing as `latest`.** `<version>` is just a folder name, so
`sym install mytool latest mytool.exe` works and is a perfectly good fit
for a tool you rebuild constantly and only ever want the newest copy of:
`latest` is an ordinary folder, and re-running the install overwrites it
in place (it can't replace a copy that's currently running — close it
first). The one thing it can't be is *both* that and an alias. If
`latest` is a directory junction made by `sym alias` (step 9), `sym
install` refuses rather than writing through it into whatever real
version it points at; install under a real version number and repoint
the alias instead. Pick one model per package: a literal `latest` folder
for a single always-newest dev build, or real versions plus
`sym alias` when you want to keep old versions and roll back.

## 5. Remove an installed version

```bash
sym uninstall certo 1.7.0
```

Deletes `packages\certo\1.7.0\` outright, including every file in it,
regardless of how many shimmed names still have descriptors pointing at
that package/version. Nothing shimmed is touched — a descriptor or
`sym.toml` pin still pointing at a now-uninstalled version just hits
the ordinary "is not installed" error the next time that shim runs.
Running it again for a version that's already gone prints a message
and exits `0`, not an error.

If `<version>` names an alias (see step 9) rather than a real installed
version, `sym uninstall` refuses instead of deleting anything: an alias
is a directory junction, and deleting through it would recurse into and
destroy whatever real version it currently points at rather than
removing the alias itself. Uninstall the real version number instead.

## 6. Shim the tool

```bash
sym shim add certo certo 1.8.0
```

This copies `shim\sym_shim.exe` to `bin\certo.exe` (always re-copying,
even if already present — cheap, and picks up a rebuilt shim
automatically) and writes `shims\certo.toml`. An optional fifth
argument names the command inside the version folder if it isn't
`<name>.exe` (e.g. `sym shim add certo certo 1.8.0 certo-cli.exe`).
Equivalent by hand:

```powershell
Copy-Item "$env:LOCALAPPDATA\Sym\shim\sym_shim.exe" "$env:LOCALAPPDATA\Sym\bin\certo.exe"
```

```toml
# shims\certo.toml
package = "certo"
command = "certo.exe"
version = "1.8.0"
```

See [examples/shims/certo.toml](../examples/shims/certo.toml) for a
working example. Format rules: flat `key = "value"` lines only (no
nesting), `#` starts a full-line comment, blank lines are ignored,
quotes around the value are optional.

That's it — `certo --version` typed anywhere now runs through the shim
to the real `1.8.0` binary. `sym shim list` prints every currently
shimmed name; `sym shim remove certo` deletes both `bin\certo.exe` and
`shims\certo.toml` (leaving installed packages alone, since another
name might still reference the same package/version).

**Ctrl+C.** Pressing it in a terminal signals every program attached to
that console — the shim *and* the tool it started. The shim ignores it
while it waits and leaves the decision to the tool, then returns whatever
the tool exits with. So a tool that handles Ctrl+C itself (a shell cancelling
the running command, a REPL, an editor) carries on exactly as it would
without the shim, and one that doesn't handle it dies as usual — with the
same exit code as running it directly (`0xC000013A`). Without this the
shim would die first, your terminal would show its prompt again while the
tool was still running behind it, and the tool's real exit status would be
lost. Ctrl+Break is not ignored: it still stops the shim. This lives in
Certo's `Process.execInherit`, so a shim must be built with a compiler
that includes it; `tests/ctrl-c` checks the result.

## 7. Switch versions

Install the new version the same way as step 4, then:

```bash
sym use certo 1.9.0
```

This rewrites `version` in **every** `shims\*.toml` whose `package`
matches — one command, whether `certo` is fronted by one name or, per
the toolchain design, several. Equivalent by hand: edit just the
`version` line in `shims\certo.toml`:

```toml
package = "certo"
command = "certo.exe"
version = "1.9.0"
```

No rebuild, no PATH change, no re-copying the shim. This is the entire
value of the design — switching is a one-line text edit, whether you
make it yourself or `sym use` makes it for you.

## 8. Pin a version per-project

```bash
cd my-project
sym pin certo 1.7.0
```

Writes (or updates, preserving every other line including comments) a
`sym.toml` in the current directory to override the global version for
just that directory tree. Pass a directory as a third argument to pin
somewhere other than the current one: `sym pin certo 1.7.0 C:\path\to\project`.
By hand, that's just:

```toml
# my-project/sym.toml
certo = "1.7.0"
```

Any number of tools can share one file:

```toml
certo = "1.7.0"
flux  = "1.2.0"
```

Running `certo` from inside `my-project` (or any subdirectory under
it) now uses `1.7.0` regardless of the global setting — the shim walks
up from the current directory looking for the nearest `sym.toml`. See
the README's "Project-level pinning" and "Nested projects" sections for
the exact boundary rules (in short: the nearest file found wins
entirely, it doesn't merge with parent files).

**The tool must already be shimmed globally before you can pin it.**
`sym.toml` only overrides which *version* runs — it can't invent a
`package`/`command` mapping that doesn't exist yet in `shims\`. If you
pin a tool that was never shimmed, you'll get a specific error telling
you so (see the error reference below).

## 9. Set up a version alias (`latest`, `lts`, ...)

```bash
sym alias certo latest 1.9.0
```

This points `packages\certo\latest` at `packages\certo\1.9.0` as a
directory junction (not a symlink — junctions don't need admin rights).
`1.9.0` must already be installed and be a real version, not itself an
alias — aliases only resolve one hop, they don't chain. Now
`version = "latest"` works in either a descriptor or a `sym.toml` pin,
exactly like any real version string — the shim doesn't know or care
that it's a junction.

Run the same command again with a different version to repoint an
existing alias — `sym alias certo latest 1.10.0` moves `latest` forward.
This is **not** a plain overwrite: naively deleting the old junction
with an ordinary recursive delete, or moving a new target onto the
junction's own path, both corrupt data (verified directly — see
`src/Junction.cto`), because Windows treats either as an operation on
whatever the junction currently points at rather than on the junction
itself. `sym alias` creates the replacement under a temporary name,
removes only the old junction (never recursing into its target), then
renames the replacement into place, so repointing never touches the
old or new target's actual contents. Leave an alias alone to keep it
frozen instead of repointing it. See the README for the reproducibility
caveat about using a floating alias in a checked-in project pin.

Equivalent by hand:

```powershell
New-Item -ItemType Junction `
  -Path "$env:LOCALAPPDATA\Sym\packages\certo\latest" `
  -Target "$env:LOCALAPPDATA\Sym\packages\certo\1.9.0"
```

— but only for the *first* creation. Repointing by hand needs the same
create-under-temp-name → remove-old-junction-only → rename-into-place
sequence `sym alias` does; a plain re-run of `New-Item -ItemType
Junction` over an existing junction, or `Remove-Item -Recurse` on the
old one first, risks the same corruption described above.

## 10. Shim a multi-binary release (a "toolchain")

If a release exposes several binaries — Certo's ships `certo`,
`certo-fmt`, `certo-lsp`, and more — install them all into the same
version folder, then shim them in one go:

```bash
sym shim add-all certo 1.8.0 "certo*"
```

```
packages\certo\1.8.0\
    certo.exe        -> shim `certo`
    certo-fmt.exe    -> shim `certo-fmt`
    certo-lsp.exe    -> shim `certo-lsp`
    db_users.exe     (doesn't match "certo*": left alone)
```

Each matching `.exe` becomes a shim named after its file, with `package`
and `version` shared across all of them. The pattern uses `*` and `?`,
ignores case, and matches the file name with or without `.exe`; leave it
out to shim every executable in the folder. Releases often contain
executables you don't want on PATH (sample programs, helpers), so a
pattern is usually what you want — and `--dry-run` shows what would happen
without changing anything:

```bash
sym shim add-all certo 1.8.0 "certo*" --dry-run
```

A name that's already shimmed to a *different* package is skipped with a
message rather than overwritten (`sym shim remove <name>` first if you
really want to replace it); re-running for the same package just
re-stamps, so it's safe to repeat after rebuilding the shim. Equivalent by
hand, per binary: `sym shim add certo-fmt certo 1.8.0 certo-fmt.exe`.

`sym use certo 1.9.0` already switches every descriptor sharing that
package together, so `certo` and `certo-fmt` can't end up on different
versions.

### From a zip, in one command

If the release comes as a zip (Certo's `dist\certo-<version>-windows-x64.zip`
holds eight executables plus `docs\`, `examples\`, `README.md` and a
`VERSION` file), `scripts\install-package.ps1` does the whole sequence —
install every executable, alias `latest`, shim them all:

```powershell
.\scripts\install-package.ps1 -Package certo -Source C:\path\to\certo-1.0.73-windows-x64.zip
```

It unpacks to a temporary folder, finds the `.exe` files at the top, works
out the version (`-Version`, else the package's `VERSION` file, else the
archive name `certo-1.0.73-…`), and starts `certo.exe --version` to prove the
package runs *before* installing anything — only that one executable, since
the others needn't accept `--version` and an editor server like `certo-lsp`
would sit waiting for input. Then it runs `sym install` for each file
(verifying each copy), `sym alias certo latest 1.0.73`, and
`sym shim add-all certo latest "*"`, and finishes with `certo --version` through
the shim and a `sym doctor` summary. Only executables are installed; docs
and examples stay in the zip.

Re-running the same version overwrites in place; a newer version is installed
alongside the old, so rolling back is `sym alias certo latest <old-version>`.
Useful options: `-DryRun` (unpack, validate and print the plan, change nothing),
`-ShimPattern certo` (shim only `certo.exe`), `-NoShim`, `-NoAlias` (shims then
point straight at the version), `-Alias <name>`, and `-Sym <path>`. It installs
into `SYM_HOME` if set, else `%LOCALAPPDATA%\Sym`. A source can also be an
already-unpacked folder.

It stops with an explanation rather than guessing when something is off: no
way to tell the version, a version that isn't a single plain folder name
(`..\x`, `a\b`), no executables, or `packages\<pkg>\latest` being an ordinary
folder from an older install (sym won't replace that with an alias; the files
are already installed under their version, so move the folder and re-run, or
use `-Alias`/`-NoAlias`).

## 11. See what's installed and what will run

```bash
sym list                  # every package, its versions and aliases
sym list certo            # just one package
sym which certo           # exactly what typing `certo` here would run
```

`sym list` shows each version folder, each alias with the version it
points at, and which shims currently run each one:

```
certo
  1.8.0
  1.9.0
  latest  -> 1.9.0   (alias)   used by: certo, certo-fmt
```

`sym which <name>` answers "what happens if I type this *here*": the shim
file, its descriptor, whether a project `sym.toml` applies (and which
one), the version that results, the alias it goes through, and the file it
will launch, with a status of `ok`, `NOT INSTALLED` or `MISSING`. It exits
`1` when the shim wouldn't work, so scripts can test it. It works the same
way the shim does — the nearest `sym.toml` wins entirely, a parent's pin is
not consulted — and `tests/commands` runs the real shim next to it to make
sure the two agree.

## 12. Check the install

```bash
sym doctor
```

Audits the whole install and prints `ok`, `warn` or `FAIL` for each check,
then a summary. It exits `1` if anything is wrong (warnings alone don't
fail it). It checks:

- **layout** — the `shim\`, `bin\`, `shims\` and `packages\` folders, the
  master `sym_shim.exe`, and whether `Sym\` and `Sym\bin` are on PATH.
- **shims** — for every descriptor: it's complete, `bin\<name>.exe` exists,
  that file is a copy of the *current* master shim (a different build is a
  warning, with the exact `sym shim add` command to refresh it), and it is
  **not hardlinked** to anything else — the drift that once let a write
  through a shim destroy the real binary — and the version it points at
  is actually installed.
- **aliases** — every alias points at a folder that still exists, and not
  at another alias.
- **orphans and leftovers** — executables in `bin\` with no descriptor, and
  `.tmp`/`.new` files left by an interrupted write.
- **project pins** — the nearest `sym.toml` from where you run it: every
  pinned tool is shimmed and its pinned version installed.

The PATH checks look at the PATH of the shell you ran it from, so a
terminal opened before the installer ran may report a warning that a new
one wouldn't.

## Error reference

| Message | Meaning | Fix |
|---|---|---|
| `no argv[0]` | The OS didn't provide an invocation name at all — shouldn't happen in practice. | Investigate how the process was spawned. |
| `LOCALAPPDATA is not set` | The `LOCALAPPDATA` environment variable is missing and `SYM_HOME` wasn't set either. | Set `SYM_HOME` explicitly, or fix your environment. |
| `no shim descriptor for '<name>'` | Nothing at `shims\<name>.toml` exists, and no `sym.toml` pins that name either. | The tool was never shimmed — do step 6. |
| `'<name>' is pinned to <version> in sym.toml, but has never been shimmed globally ... run 'sym shim add <name> <package> <version>' first` | A `sym.toml` pins a tool with no matching global descriptor. | Do step 6 for that tool name first; the pin alone isn't enough. |
| `malformed shim descriptor <path> (need package, command, version)` | The descriptor is missing one of the three required fields. | Check the file against the format in step 6b. |
| `<package>@<version> is not installed (looked for <path>)` | The resolved version (from the descriptor or a pin) has no matching folder under `packages\`. | Install that version (step 4), fix the typo in the descriptor/pin, or point a version alias there. |

Every error exits with code `127` and prints to stderr, prefixed
`sym-shim: `.

## Testing without touching your real `%LOCALAPPDATA%\Sym`

Set `SYM_HOME` to any directory to redirect everything (`bin` isn't
part of this — only `shims\` and `packages\` are read relative to it).
Useful for trying out a layout before committing to it:

```powershell
$env:SYM_HOME = "C:\scratch\fake_sym_home"
```
