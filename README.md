# sym-shim

A single generic shim binary, in Certo, for a version-manager `PATH`
trick: one tiny executable, copied under many names, that resolves the
active version of whatever it was invoked as and re-execs it — with real
stdin/stdout/stderr passthrough and exact exit-code propagation.

`src/sym.cto` builds a small `sym` CLI implementing the management side
— `install`/`uninstall`/`use`/`shim add`/`shim remove`/`shim list`/`pin` — that
writes and reads exactly the files described below. `install` can take
an already-obtained local file, or fetch a real GitHub release itself
(with checksum verification) given a `sources\<package>.toml` — see
"Fetching a package" below.

This README covers the design; for step-by-step setup see
[docs/USAGE.md](docs/USAGE.md), and for a line-by-line explanation of
`src/sym_shim.cto` see [docs/CODE-WALKTHROUGH.md](docs/CODE-WALKTHROUGH.md).

## Layout it expects

```
%LOCALAPPDATA%\Sym\
    shim\
        sym_shim.exe     ← the master build artifact — never on PATH itself,
                             never invoked directly; every entry in bin\ below
                             is a copy of this one file, renamed
    bin\
        certo.exe        ← copy of shim\sym_shim.exe, named "certo"
        flux.exe         ← copy of shim\sym_shim.exe, named "flux"
    shims\
        certo.toml       ← which version "certo" currently resolves to
        flux.toml
    packages\
        certo\
            1.7.0\certo.exe
            1.8.0\certo.exe
```

Only `%LOCALAPPDATA%\Sym\bin` needs to be on `PATH`. `shim\sym_shim.exe`
deliberately lives outside it — it's the one-time build output that
every per-tool copy is stamped from, not something meant to run under
its own name. Keeping it here (rather than wherever it happened to be
built) means adding a new tool never requires recompiling from Certo
source: `sym shim add <name> <package> <version>` just copies
`shim\sym_shim.exe` to `bin\<name>.exe` and writes the descriptor — no
`PATH` change, ever. Switching versions (`sym use certo 1.7`) is a
single-line edit to `shims\certo.toml`; the shim binary itself never
changes.

Every `sym` command takes `package` and `version` as two plain,
space-separated arguments (`sym use certo 1.9.0`), never joined as
`certo@1.9.0`. This wasn't the original design — it changed after a
real failure using `sym` from inside Ion-win: its shell treats `@`
followed by a digit as a variable-expansion sequence (like `$1` in
other shells), so `certo@1.9.0` silently became `certo.9.0` before
`sym` ever saw it, with a shell-level "variable does not exist" error
on top. Splitting into two arguments removes the character shells have
opinions about, rather than working around any one shell's expansion
rules.

## Descriptor format (`shims\<name>.toml`)

Flat `key = "value"` lines only — no nesting, no arrays. `#` starts a
comment; blank lines are ignored.

```toml
package = "certo"
command = "certo.exe"
version = "1.8.0"
```

`SYM_HOME` overrides `%LOCALAPPDATA%\Sym` (mainly for testing).

### Write safety

Every place `sym` rewrites a descriptor or `sym.toml` (`shim add`,
`use`, `pin`) writes to a `.tmp` file in the same directory first, then
renames it over the real target, rather than writing the target
in-place. `renameFile` — added to Certo's stdlib for this — is atomic
when both paths are on the same volume, which a same-directory `.tmp`
file always is, so a `sym_shim` process reading that exact path can
never observe a half-written file mid-update. Verified directly: write
a target file, write new content to a temp file, rename over the
target, confirm the target now has the new content and the temp file
is gone.

## Toolchains (a release with more than one binary)

Certo's own release ships several binaries — `certo`, `certo-fmt`,
`certo-lsp`, `xeq`, and more — and Rust's is bigger still (`rustc`,
`cargo`, `rustfmt`, `clippy`, `rust-analyzer`, ...). Fronting all of
them needs **no shim changes**: a toolchain is just several descriptors
that share `package` and `version` but each name their own `command`,
all reading from one shared version directory:

```
packages\certo\1.8.0\
    certo.exe
    certo-fmt.exe
```

```toml
# shims\certo.toml
package = "certo"
command = "certo.exe"
version = "1.8.0"
```

```toml
# shims\certo-fmt.toml
package = "certo"
command = "certo-fmt.exe"
version = "1.8.0"
```

Verified: `certo.exe` and `certo-fmt.exe`, shimmed independently like
this, each resolve to their own binary inside the same
`packages\certo\1.8.0\` folder. `package`, `command`, and `version`
were already three independent fields per descriptor — nothing stopped
several descriptors from agreeing on two of them while differing on the
third. This mirrors how `rustup` treats a toolchain as one coordinated
bundle rather than versioning `rustc` and `cargo` separately.

That leaves exactly one real problem, and it belongs to whatever
installs packages, not the shim:

- **Coherent switching.** `sym use certo 1.9.0` needs to move every
  descriptor with `package = "certo"` to `1.9.0` together, so `certo`
  and `certo-fmt` never end up on different versions. This needs no
  extra bookkeeping beyond what already exists — since every descriptor
  already records its own `package`, switching just means scanning
  `shims\*.toml` for matches and rewriting all of them. `src/sym.cto`'s
  `use` command does exactly this today.
- **First install still needs a manifest.** Before any descriptors
  exist, something has to know that `certo@1.8.0` exposes `certo`,
  `certo-fmt`, `certo-lsp`, `xeq`, etc., so it knows which names to shim
  and which binaries to place in that shared version folder — that has
  to come from a release manifest (or, for Certo specifically, its own
  workspace member list) rather than being inferred.

## Version aliases (`latest`, `lts`, ...)

Both `version` in a shim descriptor and a pin in `sym.toml` can be a
named alias instead of an exact version, with **no shim code involved
at all** — a version string is just an opaque path segment to the
shim, so `version = "latest"` only works because `packages\certo\latest`
is a real directory. Concretely, that means a directory junction:

```
packages\certo\
    1.9.0\certo.exe
    latest\          ← junction (sym alias, no admin rights needed,
                        unlike a symlink) pointing at 1.9.0
```

`sym alias certo latest 1.9.0` creates or repoints it; `sym uninstall`
refuses to run on an alias name rather than deleting through it (see
"Repointing an alias safely" below for why that distinction matters).

Once that junction exists, `version = "latest"` in `shims\certo.toml`
and `certo = "latest"` in `sym.toml` both resolve correctly — verified
against a real junction, both from the global descriptor and from a
project pin. `lts` works identically; it's just another junction name.

This is deliberately pushed entirely onto whatever installs packages,
not the shim, for the same reason `package`/`command` identity lives in
the global descriptor rather than being inferred: the shim only
resolves, it never decides. It also sidesteps a real problem the shim
has no way to solve on its own — there's no way to tell, from a
directory name alone, which installed version was ever considered an
"LTS" release; only the installer has that knowledge. Whether the alias
is *live* (the junction gets re-pointed as new versions are installed,
so it silently tracks forward) or *frozen* (resolved once to a concrete
version and never updated) is entirely up to how the installer manages
it — the shim can't tell the difference and doesn't need to.

One caveat worth calling out even though nothing here enforces it: a
*live* floating alias inside a checked-in `sym.toml` undermines the
reproducibility pinning exists for in the first place — two people
building the same project at different times could silently get
different versions. Fine for a global default; worth avoiding in a
project pin meant to be reproducible.

### Repointing an alias safely

Repointing an alias (`sym alias certo latest 1.10.0` when `latest`
already exists) can't be a plain overwrite. Two naive approaches were
tried and verified broken before landing on the real implementation
(`src/Junction.cto`):

- **Moving the new version's directory onto the alias's own path**
  (`Move-Item v2 -Destination active`, or the equivalent rename) doesn't
  repoint the junction at all — Windows treats a junction's path as the
  directory it points *at* for this kind of operation, so it silently
  merges the new version's files into the *old* target instead. The
  alias keeps pointing at the old version, which now has a stray
  subdirectory holding what should've been the new one.
- **Deleting the old junction with an ordinary recursive delete**
  (`removeDir`, `Remove-Item -Recurse`, `rm -rf`) doesn't delete the
  junction — Windows' directory-enumeration APIs follow a junction
  transparently, so a recursive delete recurses straight through it and
  destroys every file inside whatever it points at, leaving that
  version's directory empty. This is the same class of bug that
  motivated `copyBytes`/`writeBytesAtomic` above, just for directories
  instead of files, and it's why `sym uninstall` now refuses to run on
  an alias name (see "Remove an installed version" in USAGE.md).

The safe sequence, verified directly (create a junction, seed both the
old and new targets with marker files, repoint, confirm both targets'
files survive untouched and the alias resolves to the new one): create
the replacement junction under a temporary name, delete *only* the old
junction — a non-recursive delete of the reparse point itself, which
touches nothing inside whatever it targets — then rename the
replacement into place. There's a brief window between the delete and
the rename where the alias doesn't exist at all; a reader hitting that
window gets a clean "not found" instead of silently corrupted or merged
data, which is the same fail-safe-not-silently tradeoff
`writeBytesAtomic` makes for files.

## Fetching a package (`sym install <package> <version>`, no local file)

`sym install` takes an already-downloaded file if you give it one; if
you don't, it fetches instead, using a per-package config that says how:

```toml
# sources\certo.toml
provider = "github-release"
repo = "rjreeves/Certo"
tag = "v{version}"                  # template; defaults to "{version}" if omitted
asset = "certo-windows-x86_64.zip"  # template, may also embed {version}
archive = "tar"                     # "tar" | "none" (raw binary, no extraction)
binary_path = "certo.exe"           # where the real binary lands inside the archive
```

`{version}` is substituted via `Text.replace` into `tag`/`asset`
(`github-release`) or `url` (see below), and into `binary_path`
regardless of provider. Two providers exist:

- **`github-release`** builds `https://github.com/<repo>/releases/download/<tag>/<asset>`
  — verified against a real, sizeable (2 MB) GitHub release asset served
  through its actual redirect to a CDN, byte-for-byte matching an
  independent fetch by hash.
- **`url`** is a fully-specified template for everything else — GitLab,
  a project's own server, an npm tarball URL — with no structure
  assumed beyond `{version}` substitution:
  ```toml
  provider = "url"
  url = "https://example.com/downloads/mytool-{version}-windows.zip"
  archive = "tar"
  binary_path = "mytool.exe"
  ```
  Verified against a real `.tar.gz` asset fetched by a fully pre-composed
  URL (no repo/tag/asset fields involved at all) — everything downstream
  of the URL is identical regardless of which provider built it.

Named providers that would compose a URL from structured fields the way
`github-release` does — `gitlab-release`, `npm` — aren't implemented:
their real URL shapes aren't something to guess at without a concrete
target to verify against, the same way `github-release` and `url` were
both grounded in real fetches rather than assumed.

Downloaded with `Http.get`, then extracted (if `archive = "tar"`) with
the `tar` binary Windows has shipped since 10 (1803) — via
`Process.execInherit`, the same primitive that runs every shimmed tool
— rather than teaching Certo to decode archive formats itself; that's a
much bigger addition than this project's other stdlib patches for
something the OS already does. One `tar -xf` handles `.zip`, `.tar`,
and `.tar.gz`/`.tgz` alike, verified against a real asset of each, so
`archive` doesn't need a value per format. `binary_path` is then copied
from the extracted tree into `packages\<package>\<version>\`, exactly
like the local-file path.

Downloading a real binary and hashing it both depend on the same
binary-safety property: `HttpResponse.body()` is `Text` and silently
truncates at the first embedded `0x00` byte (confirmed with a real
file — see the stdlib gaps section), so both the download and the
integrity check go through `Bytes` the whole way — `bodyBytes()` for
the response, `Crypto.sha256Bytes`/`Bytes.toHex` for hashing it, never
converting through `Text` in between.

### Checksum verification

A checksum is per-*version*, but a source config is per-*package* —
one file, many versions — so the expected hash lives in a sibling file,
keyed by version, reusing the exact same flat-file lookup `sym.toml`
already uses:

```toml
# sources\certo\checksums.toml
1.7.0 = "aaa111..."
1.8.0 = "bbb222..."
```

This is a deliberate choice over trusting a checksum file published
alongside the release itself: a pinned, separately-maintained hash
gives real tamper detection (the expected value doesn't come from
wherever the binary came from), whereas a fetched sidecar only catches
network corruption — an attacker controlling the release could change
both the binary and its published checksum together. The cost is
curation: someone has to add a line per new version.

If a version has no entry in `checksums.toml` — or the file doesn't
exist at all — install proceeds anyway, but prints a visible warning
that the download is unverified, rather than either silently skipping
verification or refusing to install any version that was never
explicitly recorded. A mismatch is fatal and installs nothing: verified
by fetching a real release with a deliberately wrong pinned hash and
confirming no file was written.

Extraction temp files under `Sym\tmp\` are cleaned up (deleted archive,
removed extraction directory) once the binary's been copied out —
verified against a real fetch, `tmp\` is empty afterward. Cleanup is
best-effort: a failure there doesn't fail the install, since the actual
install already succeeded by that point.

## Uninstalling a package (`sym uninstall <package> <version>`)

```bash
sym uninstall certo 1.7.0
```

Removes `packages\certo\1.7.0\` outright — recursively, including every
file in it — regardless of how many shimmed names' descriptors still
reference that package/version, the same way `rm` doesn't care who else
references a file. Nothing shimmed gets touched: a descriptor or
`sym.toml` pin still pointing at a now-uninstalled version just hits the
ordinary "is not installed" error the next time that shim runs, same as
if the version had never been placed there at all. Uninstalling a
version that's already gone is a no-op (prints a message, exits `0`),
not an error — verified by running it twice in a row.

## Project-level pinning (`sym.toml`)

A project can pin different versions than the global `sym use` by
putting a single `sym.toml` in its root — one file per project, listing
every tool that project cares about:

```toml
# project-a/sym.toml
certo = "1.7.0"
flux  = "1.2.0"
```

```toml
# project-b/sym.toml
certo = "1.8.0"
```

Each shim only reads its own line: `certo.exe` looks for a `certo =`
line and ignores `flux =`, and vice versa, so any number of tools can
share one file without stepping on each other. A `[tools]` header is
allowed for readability if you want one — the parser has no section
support, so it's silently skipped as a line with no `=` in it, same as
any other unrecognized line.

Only exact versions are supported (`certo = "1.7.0"`, not `^1.7` or
`>=1.7.0`) — a shim should resolve deterministically, not run a semver
solver, so there's no range/constraint syntax.

The shim walks up from the current directory looking for the nearest
`sym.toml`. The first one found is the project boundary:

- if it has a line for the invoked tool name, that version wins;
- if it exists but doesn't mention that tool, the shim stops climbing
  there anyway (that's still the project root) and falls back to the
  global `sym use` version — it will not skip past it to check a
  grandparent directory's `sym.toml`;
- if none is found before the filesystem root, the global version applies.

Only the version is pinned this way — `package` and `command` still come
from the global shim descriptor (`shims\<name>.toml`), since that's what
`sym shim add` wrote when the tool was first shimmed.

### Nested projects (monorepos)

A nested package with its own `sym.toml` overrides an ancestor's pin for
the same tool, since it's simply the nearer file found while climbing:

```toml
# monorepo/sym.toml
certo = "1.8.0"
```

```toml
# monorepo/packages/backend/sym.toml
certo = "1.7.0"
```

Invoking `certo` from `monorepo/packages/backend` resolves to `1.7.0`;
from `monorepo` itself (or any other sibling package without its own
pin), it resolves to `1.8.0`. This is "nearest file wins," not
"innermost value across all files wins": each `sym.toml` is a complete,
self-contained boundary. A nested file that pins `flux` but says
nothing about `certo` does **not** cause the climb to continue past it
to the root's `certo` pin — that case falls straight to the global
default instead (see the boundary rule above). This deliberately
matches `asdf`'s `.tool-versions` behavior rather than a cascading
workspace-inheritance model, so a pin never reaches further up the tree
than reading one file would suggest.

### When a pin and the global descriptor conflict

There's only one axis of override — version — and only one direction:
a project can narrow the global default, never redefine what a tool
name means. Concretely:

- The global descriptor (`shims\<name>.toml`) is mandatory and defines
  identity (`package`, `command`). `sym.toml` can never substitute for
  it or change what a name resolves to.
- If the global descriptor exists, `sym.toml`'s pinned version (if any)
  wins over the descriptor's `version`; otherwise the descriptor's
  version applies.
- If the global descriptor is **missing** but `sym.toml` pins that tool
  anyway, the shim doesn't silently ignore the pin — it fails with a
  specific message naming the orphaned pin (`'flux' is pinned to 1.2.0
  in sym.toml, but has never been shimmed globally ... run 'sym shim
  add flux <package> 1.2.0' first`) rather than the generic "no shim
  descriptor" error, since that would give no hint the pin exists at all.
- Whichever version wins, "is it actually installed" is checked the
  same way regardless of where the version came from.

## Build

```
certo src/sym_shim.cto -o sym_shim.exe
```

Copy (or hardlink) `sym_shim.exe` to `%LOCALAPPDATA%\Sym\bin\<name>.exe`
for each tool it should front. At runtime it reads its own `argv[0]`
to figure out which name it was invoked as.

`certo` itself needs to come from a pinned commit, not Certo's `master`
branch or its one existing release — see [docs/USAGE.md](docs/USAGE.md)'s
Prerequisites section for the exact command and why.

## Stdlib gaps this surfaced

Building a *transparent* shim exposed several real gaps in Certo's
compiler, fixed or worked around here:

1. **`Stdlib.Process` had no inherited-stdio exec.** `Process.exec` only
   ever ran commands through `system()`/`popen()`, capturing stdout/stderr
   to temp files and returning them after the child exits — no live
   streaming, no real stdin. That's fatal for a shim (no progress bars,
   no interactive prompts, wrong stdout/stderr interleaving). Added
   `Process.execInherit(cmd, args): Int` to the compiler
   (`crates/stdlib/src/process.rs`, plus `seed.rs`/`effects_seed.rs`
   registration) — `CreateProcess` with inherited stdio handles on
   Windows, `fork`/`execvp` on POSIX — so the child is truly attached to
   the shim's own console. Verified with a real child process: live
   interleaved output, forwarded stdin, and exact exit code (7) round-tripped
   through the shim. This is upstream in [rjreeves/Certo](https://github.com/rjreeves/Certo).

2. **`??` does not short-circuit.** `a ?? b` is documented as returning
   `a` unwrapped when `Some`, else `b` — but the compiler evaluates `b`
   unconditionally regardless of `a`. Confirmed with a minimal repro (an
   `[io]` side effect on the right-hand side runs even when the left is
   `Some(...)`). This breaks the common "unwrap-or-fail" idiom. Routed
   around it in `sym_shim.cto` via `match` (which *does* short-circuit
   correctly) instead of fixing the compiler, per instruction — worth
   fixing in `certo-codegen` separately since it likely affects other code
   relying on `??`.

3. **`Path.stem` doesn't strip the directory**, only the extension — so
   `Path.stem("C:\foo\bar.exe")` returns `C:\foo\bar` instead of `bar`.
   Worked around with `Path.stem(Path.basename(path))`; not fixed upstream.

4. **No way to get the current working directory.** Needed for project-level
   pinning (walking up from cwd looking for `sym.toml`) — there was no
   `cwd()`-equivalent in the stdlib at all. Added `getCurrentDir(): Text`
   to the compiler (`crates/stdlib/src/env.rs`, plus `seed.rs`
   registration) — `GetCurrentDirectoryA` on Windows, `getcwd` on POSIX.
   Left unmarked `[io]`, matching `getEnv`'s existing convention (reads
   process-local state that's static for the run, absent a `setCurrentDir`
   primitive, which doesn't exist either). Verified from two different
   working directories.

5. **`HttpResponse` had no binary-safe way to read a response body.**
   `.body(): Text` is NUL-terminated like everything else Text-typed, so
   any response containing an embedded `0x00` byte — any real binary,
   an executable or an archive — gets silently truncated. Confirmed with
   a real download: `github.com/favicon.ico`'s first byte is `0x00`, so
   `.body()` returned an *empty* string while `.bodyLength()` correctly
   reported 6518. The internal buffer was already binary-safe (length-
   tracked, never truncated while reading off the wire); it just had no
   accessor exposing that. Added `HttpResponse.bodyBytes(): Bytes` to
   the compiler (`crates/stdlib/src/http.rs`, plus `seed.rs`
   registration), copying the same already-correct buffer into a real
   `Bytes` value. Verified against a real 2 MB GitHub release asset
   (fetched through its actual redirect to a CDN): SHA-256 hash and
   byte size both matched an independent `Invoke-WebRequest` fetch
   exactly. This was necessary groundwork for `sym install`'s fetch
   path (see "Fetching a package" above), which needs to download and
   hash real binaries without corrupting them.

6. **No way to atomically replace a file.** Needed for the write-safety
   work above — `writeFile` truncates and rewrites in place, so a reader
   could observe a half-written file mid-update; the standard fix is
   write-to-temp-then-rename, which only works if the rename itself is
   atomic. Added `renameFile(from, to): Bool` to the compiler
   (`crates/stdlib/src/file.rs`, plus `seed.rs` registration) —
   `MoveFileExA` with `MOVEFILE_REPLACE_EXISTING` on Windows (atomic on
   the same volume), `rename()` on POSIX (already atomic there).
   Verified directly: write a target file, write new content to a
   `.tmp` file, rename over the target, confirm the target has the new
   content and the temp file is gone.

7. **No recursive directory removal at all.** Needed for `sym
   uninstall` (deleting `packages\<package>\<version>\`, which can
   contain more than one file for a toolchain) and for cleaning up
   fetch/extraction temp directories. Added `removeDir(path): Bool` —
   walks and deletes contents before removing the directory itself,
   continuing past individual failures rather than stopping at the
   first one so a partially-removable tree still gets cleaned up as
   much as possible. Verified against a real nested tree (a
   subdirectory plus files at two levels): everything gone afterward,
   confirmed independently on the real filesystem, not just via Certo's
   own `fileExists`.
