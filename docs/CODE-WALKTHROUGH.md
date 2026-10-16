# Code walkthrough: `src/sym_shim.cto`

A line-by-line explanation of how the shim works, why it's written the
way it is, and the compiler quirks that shaped it. Cross-references use
the line numbers in the current file; if you've edited it, the numbers
will drift but the structure won't.

## The one-sentence version

Read your own invoked name from `argv[0]`, find the descriptor that
says which real binary that name currently means, optionally let a
project's `sym.toml` override just the version, then replace yourself
with that real binary — stdin, stdout, stderr, and exit code all
passed through untouched.

## Imports (lines 3–9)

```certo
import Stdlib.Core
import Stdlib.Text
import Stdlib.File
import Stdlib.Path
import Stdlib.Env
import Stdlib.Process
import Stdlib.Collections
```

Each maps to exactly the primitives used below: `Core` for
`println`/`eprintln`/`arg`/`argCount`/`Option`, `Text` for the string
manipulation the TOML-subset parser needs, `File` for `readFile`/
`fileExists`, `Path` for OS-correct path joining, `Env` for
`getEnv`/`getCurrentDir`, `Process` for `execInherit`/`quit`,
`Collections` for the `List<Text>` that holds forwarded arguments.

## `fatal` (lines 11–15)

```certo
fn fatal(msg: Text): Unit [io] = {
    eprintln("sym-shim: " ++ msg)
    flush()
    Process.quit(127)
}
```

Every failure path in the shim funnels through here. Three things
matter:

- **`eprintln`, not `println`** — errors go to stderr, so they don't
  get mixed into stdout a caller might be parsing.
- **`flush()` before quitting.** Certo's `println`/`eprintln` are
  buffered; without an explicit flush, output can still be sitting in
  a buffer when `Process.quit` tears the process down, and never
  reach the terminal. This was found empirically — an early version
  without the flush produced messages that appeared out of order
  relative to a child process's own output.
- **Exit code `127`** — the conventional "command not found" exit
  code in POSIX shells, reused here for every fatal shim condition
  since they're all variations on "couldn't figure out what to run."

## `unwrapOrFatal` (lines 17–28) — working around a real compiler bug

```certo
// `??` eagerly evaluates its right-hand side even when the left side is
// `Some(...)` (confirmed compiler bug, reported separately) — so an
// [io]-effecting fallback like `fatal` must be reached through `match`,
// which is verified to only run the arm that's actually taken.
fn unwrapOrFatal(opt: Text?, msg: Text): Text [io] =
    match opt {
        Some(v) => v
        None => {
            fatal(msg)
            ""
        }
    }
```

The obvious way to write "unwrap this `Option`, or fail with a
message" in a language with a `??` null-coalescing operator is
`opt ?? fatal(msg)`. That doesn't work here — not because of a typo,
but because Certo's `??` was found (via a minimal reproduction outside
this project) to evaluate **both** sides unconditionally and only
choose which value to keep afterward, rather than short-circuiting the
right-hand side when the left is already `Some`. Concretely:

```certo
let x: Text? = Some("present")
let result = x ?? sideEffectingFallback()   // sideEffectingFallback() RUNS ANYWAY
```

If `sideEffectingFallback` were `fatal`, the process would exit
immediately even when the value was already present. `match`, by
contrast, only ever evaluates the arm that's actually selected — this
was verified the same way, with a `println` inside a `None` arm that
never fires when the value is `Some`. `unwrapOrFatal` exists purely to
give the rest of the file a clean call-site (`unwrapOrFatal(x, "msg")`
instead of a `match` block every time) without ever going near the
broken operator.

The `None` arm's trailing `""` after calling `fatal` looks unreachable
— and at runtime it is, since `fatal` calls `Process.quit` which never
returns — but Certo's type checker still requires every branch of a
`Text`-returning function to produce a `Text`, with no notion of a
"never returns" type. It's dead code that exists to satisfy the type
checker, not a real fallback value.

## `stripQuotes` (lines 30–33)

```certo
fn stripQuotes(s: Text): Text =
    if Text.startsWith(s, "\"") and Text.endsWith(s, "\"") and Text.len(s) >= 2
    then Text.slice(s, 1, Text.len(s) - 1)
    else s
```

The descriptor format allows `version = "1.8.0"` or `version = 1.8.0`
— quotes are optional. If a value is wrapped in a matching pair of
`"` characters, strip them; otherwise leave it alone. The `Text.len(s)
>= 2` guard exists so a single stray `"` character doesn't get treated
as both the opening and closing quote and get sliced into an empty
string.

## `KeyValue` and `parseKVLine` (lines 35–49) — the TOML subset

```certo
type KeyValue = { key: Text, value: Text }

fn parseKVLine(line: Text): KeyValue? = {
    let trimmed = Text.trim(line)
    if Text.len(trimmed) == 0 or Text.startsWith(trimmed, "#") then None
    else match Text.indexOf(trimmed, "=") {
        Some(eq) => Some(KeyValue {
            key: Text.trim(Text.slice(trimmed, 0, eq)),
            value: stripQuotes(Text.trim(Text.slice(trimmed, eq + 1, Text.len(trimmed))))
        })
        None => None
    }
}
```

Certo's stdlib has no TOML parser, so this file implements the
smallest subset that both `shims\<name>.toml` descriptors and
`sym.toml` pin files actually need: flat `key = value` lines, `#`
full-line comments, and blank lines — no sections, no arrays, no
nesting. A line is parsed by finding its **first** `=` character (via
`Text.indexOf`, which returns the byte offset as an `Int?`) and
slicing the line into everything before it (the key) and everything
after (the value, with optional surrounding quotes stripped). Blank
lines and comment lines return `None` rather than being an error —
they're not malformed, they're just not data.

Note the record-construction syntax: `Some(KeyValue { key: ..., value:
... })`, with the type name immediately preceding the `{`. An earlier
attempt at `Some({ key: ..., value: ... })` — a bare anonymous record
literal with no type name — failed to parse; Certo requires the
constructor name.

## `findKeyIn` (lines 51–62)

```certo
fn findKeyIn(content: Text, wantedKey: Text): Text? = {
    var result: Text? = None
    for line in Text.split(content, "\n") {
        match parseKVLine(line) {
            Some(kv) => {
                if kv.key == wantedKey then { result = Some(kv.value) } else {}
            }
            None => {}
        }
    }
    result
}
```

Given a whole file's contents, split it into lines and scan every one
looking for a key match, keeping the last match found in a mutable
`var`. This is what lets one `sym.toml` file list any number of tools
(`certo = "1.7.0"` / `flux = "1.2.0"` / ...) — each shim invocation
calls this with its own name as `wantedKey` and simply ignores every
line that isn't relevant to it. There's no early exit on finding a
match; the loop always runs to completion, which is harmless here
since descriptor/pin files are a handful of lines at most.

## `climbForPin` (lines 64–78) — project-level pin resolution

```certo
fn climbForPin(dir: Text, toolName: Text): Text? = {
    let candidate = Path.join(dir, "sym.toml")
    match readFile(candidate) {
        Some(content) => findKeyIn(content, toolName)
        None => {
            let parent = Path.dirname(dir)
            if parent == dir then None
            else climbForPin(parent, toolName)
        }
    }
}
```

Recursive directory walk, one call per level. At each `dir`:

1. Try to read `dir\sym.toml`.
2. **If it exists**, the search stops here — return whatever
   `findKeyIn` finds for `toolName` in *this* file, `Some` or `None`,
   without ever looking at any ancestor directory. This is the
   "project boundary" rule: the nearest `sym.toml` is authoritative for
   whatever it lists, even if that means returning `None` for a tool
   it doesn't mention while a grandparent's file would have matched.
   This deliberately mirrors `asdf`'s `.tool-versions` behavior rather
   than a cascading/merging model.
3. **If it doesn't exist**, compute the parent directory
   (`Path.dirname`) and recurse into it — unless `parent == dir`,
   which is the termination condition for reaching the filesystem root
   (`Path.dirname` of a root is the root itself on both Windows drive
   roots and POSIX `/`), in which case the search gives up and returns
   `None`.

The recursion depth is bounded by the depth of the filesystem path
you're running from, which is small enough that Certo's non-tail-call
stack usage was never a concern in testing.

## `collectArgs` (lines 80–82)

```certo
fn collectArgs(i: Int, n: Int, acc: List<Text>): List<Text> =
    if i >= n then acc
    else collectArgs(i + 1, n, List.push(acc, arg(i) ?? ""))
```

Builds the `List<Text>` of arguments to forward to the real binary, by
reading `arg(i)` for every index from `i` up to (but excluding)
`argCount()`. Called as `collectArgs(1, argCount(), List.empty())` —
starting at index `1`, not `0`, because `arg(0)` is the invocation
name itself (`argv[0]` in C terms), which the shim consumes for its
own name resolution and never forwards.

The `arg(i) ?? ""` here is **not** a violation of the `??`-bug
avoidance described above — the fallback (`""`) is a pure literal with
no side effect, so it makes no observable difference whether it's
evaluated eagerly or lazily. The rule this file follows throughout is:
`match` for any `??` whose fallback has an effect (like `fatal`),
plain `??` where the fallback is inert.

## `main` (lines 84–165) — the full resolution pipeline

### Step 1: who am I? (lines 86–87)

```certo
let exeName = Path.stem(Path.basename(unwrapOrFatal(arg(0), "no argv[0]")))
```

`arg(0)` gives the full invocation path (e.g.
`C:\Users\...\Sym\bin\certo.exe`). `Path.basename` strips the
directory, leaving `certo.exe`; `Path.stem` is supposed to additionally
strip the extension, leaving `certo` — but a second real compiler bug
was found here: `Path.stem` applied directly to a full path only
strips the extension, **not** the directory, returning
`C:\Users\...\Sym\bin\certo` instead of `certo`. The workaround is
exactly what's shown: call `Path.basename` first to remove the
directory, then `Path.stem` on the result, which only ever has to
strip an extension from a bare filename — the one thing it does
correctly.

### Step 2: where's the data store? (lines 88–92)

```certo
let localAppData = unwrapOrFatal(getEnv("LOCALAPPDATA"), "LOCALAPPDATA is not set")
let symHome = match getEnv("SYM_HOME") {
    Some(v) => v
    None => Path.join(localAppData, "Sym")
}
```

`SYM_HOME` is an explicit override, checked first — mainly so tests
(and this repo's own verification work) can point the shim at a
scratch directory without touching the real `%LOCALAPPDATA%`. If it's
unset, the default is `%LOCALAPPDATA%\Sym`. Note `localAppData` is
computed unconditionally even though it's only used in the `None`
branch — a minor inefficiency (an environment lookup that might go
unused) traded for simplicity, since environment lookups are cheap and
this runs once per invocation.

### Step 3: check for a project pin *before* requiring the global descriptor (lines 94–116)

```certo
let pinnedVersion = climbForPin(getCurrentDir(), exeName)

let descriptorPath = Path.join(Path.join(symHome, "shims"), exeName ++ ".toml")
let content = match readFile(descriptorPath) {
    Some(c) => c
    None => match pinnedVersion {
        Some(v) => {
            fatal(
                "'" ++ exeName ++ "' is pinned to " ++ v ++ " in sym.toml, but has never " ++
                "been shimmed globally (no " ++ descriptorPath ++ ") -- run 'sym shim add " ++
                exeName ++ " <package> " ++ v ++ "' first"
            )
            ""
        }
        None => {
            fatal("no shim descriptor for '" ++ exeName ++ "' (expected " ++ descriptorPath ++ ")")
            ""
        }
    }
}
```

This ordering is deliberate and was a specific fix, not the original
design. `pinnedVersion` is computed first so that if the global
descriptor turns out to be missing, the error message can distinguish
two genuinely different situations:

- **No pin and no descriptor**: the tool was simply never shimmed.
  Generic message.
- **A pin exists, but no descriptor**: someone wrote `certo = "1.7.0"`
  in a `sym.toml` for a tool that was never `sym shim add`-ed
  globally. Without checking the pin first, this would produce the
  same generic "no shim descriptor" message, giving no hint that a pin
  exists at all — a genuinely confusing failure mode to debug blind.
  Checking the pin first lets the error name the orphaned pin and
  suggest the exact fix.

Either way, `getCurrentDir()` is called unconditionally at the top of
this block — it's the primitive added to Certo's stdlib specifically
for this feature (see "Stdlib additions" below), since nothing in the
language could previously answer "what directory is this process
running in."

### Step 4: parse the descriptor (lines 118–140)

```certo
var package = ""
var command = ""
var version = ""

for line in Text.split(content, "\n") {
    let trimmed = Text.trim(line)
    if Text.len(trimmed) == 0 or Text.startsWith(trimmed, "#") then {}
    else {
        match Text.indexOf(trimmed, "=") {
            Some(eq) => {
                let key = Text.trim(Text.slice(trimmed, 0, eq))
                let value = stripQuotes(Text.trim(Text.slice(trimmed, eq + 1, Text.len(trimmed))))
                match key {
                    "package" => { package = value }
                    "command" => { command = value }
                    "version" => { version = value }
                    _ => {}
                }
            }
            None => {}
        }
    }
}
```

This duplicates the parsing logic in `parseKVLine`/`findKeyIn` rather
than reusing them, because the three fields here have fixed, known
names (unlike a `sym.toml`'s arbitrary tool names) and are collected
into three separate mutable variables rather than looked up by a
single key. It was left as its own loop rather than refactored to
share code with `findKeyIn`, since both are small, independently
correct, and a shared abstraction wasn't obviously simpler than the
duplication.

Note the `match key { "package" => ...; ... }` structure rather than an
`if/else if` chain — an earlier version tried `if key == "package"
then package = value else if ...`, which failed to parse. Assignment
statements as the direct body of an `if`/`then` without braces isn't
valid Certo syntax; wrapping each in `{ }`, or restructuring as a
`match` (as done here), both work. `match` was chosen for readability
with three cases.

After the loop, a completeness check (lines 142–144) rejects a
descriptor missing any of the three required fields with a single
`fatal` call naming all three, rather than three separate checks.

### Step 5: resolve the effective version (lines 146–152)

```certo
let effectiveVersion = match pinnedVersion {
    Some(v) => v
    None => version
}
```

The one place the project pin actually overrides anything: if
`climbForPin` found a value, use it; otherwise fall back to the
version parsed from the global descriptor. `package` and `command` are
never subject to this override — they always come from the global
descriptor, by construction, since `sym.toml` lines are only ever
`toolname = version`, with no way to express a package or command
override at all.

### Step 6: does it actually exist? (lines 154–158)

```certo
let target = Path.join(Path.join(Path.join(Path.join(symHome, "packages"), package), effectiveVersion), command)

if !fileExists(target) then
    fatal(package ++ "@" ++ effectiveVersion ++ " is not installed (looked for " ++ target ++ ")")
else {}
```

Four nested `Path.join` calls build `symHome\packages\<package>\<effectiveVersion>\<command>`
one segment at a time — there's no variadic `Path.join` taking more
than two arguments in the stdlib. `effectiveVersion` is treated as an
opaque string the whole way through: nothing here distinguishes a real
version number like `1.8.0` from an alias like `latest` that happens
to be a directory junction rather than a real versioned folder — the
filesystem resolves that transparently, so the shim's logic doesn't
need to know or care.

### Step 7: forward everything and become the real process (lines 160–164)

```certo
let forwardedArgs = collectArgs(1, argCount(), List.empty())

flush()
let code = Process.execInherit(target, forwardedArgs, "")
Process.quit(code)
```

`flush()` here exists for the same reason as in `fatal`: anything the
shim itself printed (nothing, on the successful path, but the
principle held during debugging when diagnostic prints were added
temporarily) needs to be pushed out before the child process starts
writing to the same shared console — otherwise buffered shim output
can appear interleaved incorrectly relative to the child's own output.

`Process.execInherit` is the other stdlib addition this project
required (below) — it launches `target` with `forwardedArgs` (the
trailing `""` is its working-directory argument; empty means "inherit
the shim's own"), with the
child's stdin/stdout/stderr connected directly to the shim's own (not
captured, not buffered, not replayed afterward), and blocks until the
child exits, returning its real exit code as an `Int`. `Process.quit`
then terminates the shim with that exact code, so from the outside —
to whatever invoked the shim, or to a script checking `$?`/`%ERRORLEVEL%`
— the shim is indistinguishable from having run the real binary
directly.

That "indistinguishable" has to hold for Ctrl+C too, and it did not at
first. Windows delivers Ctrl+C to every process attached to the console,
so the shim and the real program both receive it. The shim is an ordinary
program with the default handler, so it died on the spot — while a program
that handles Ctrl+C itself (a shell cancelling its running command) carried
on behind it, orphaned, still reading the terminal, its exit status lost.
Measured with a test program in a hidden console: Ctrl+C at 1.8s, shim
gone at 1.8s, real program running until 6.2s. `Process.execInherit` now
ignores Ctrl+C in the waiting parent and restores it afterwards (see
"Stdlib additions" below for why that must happen *after* the child is
started), so the program decides and the shim returns its real exit code.
`tests/ctrl-c` runs the scenarios — baseline without the shim, then through
it with a program that handles Ctrl+C and one that doesn't — and fails
against a shim built without the fix.

## Stdlib additions this project required

Two primitives didn't exist in Certo's standard library before this
project needed them. Both live in the Certo compiler repository
([rjreeves/Certo](https://github.com/rjreeves/Certo)), not in this one.

### `Process.execInherit(cmd: Text, args: List<Text>, workingDir: Text): Int`

Added in `crates/stdlib/src/process.rs`. Before this, `Stdlib.Process`
only offered `Process.exec`, which runs the child via `system()`/
`popen()`, redirects its stdout and stderr to temporary files, and
reads them back **after the process has already exited** — meaning no
live streaming (a long-running build's output would appear all at
once, at the end, instead of progressively), no real stdin connection,
and no way to preserve the interleaving between stdout and stderr. For
a shim, whose entire purpose is to be invisible, that's disqualifying:
progress bars, interactive prompts, and colored output would all break
or appear wrong.

`Process.execInherit`'s C implementation instead uses `CreateProcess`
on Windows with `STARTF_USESTDHANDLES`, explicitly wiring the child's
stdin/stdout/stderr to `GetStdHandle` results — i.e., the shim's own
handles — then `WaitForSingleObject` followed by
`GetExitCodeProcess` to retrieve the real exit code. On POSIX, the
equivalent is `fork` + `execvp` (which inherits the parent's file
descriptors by default, no extra wiring needed) + `waitpid` +
`WIFEXITED`/`WEXITSTATUS`. The POSIX branch exists for completeness and
consistency with the rest of the stdlib file (which already has
`#ifdef _WIN32`/`#else` pairs throughout) — it's untested by this
project, which only targets Windows.

The third parameter, `workingDir`, was added upstream later; this
project always passes `""` (inherit the shim's own directory), since a
shimmed tool must run exactly where it was invoked.

**Ctrl+C is ignored while waiting, but only after the child exists.**
`execInherit` calls `SetConsoleCtrlHandler(NULL, TRUE)` between
`CreateProcess` and the wait, and `(NULL, FALSE)` after it (on POSIX,
`SIGINT` and `SIGQUIT` are ignored the same way, as `system(3)` does). The
order matters: the "ignore Ctrl+C" flag is inherited by processes created
while it is set, so setting it first would stop a child that relies on the
default handler from dying on Ctrl+C. Certo's own test pins that ordering.
Ctrl+Break is left alone as the way to force-stop a launcher.

**Argument quoting matters here and used to be wrong.** On Windows the
args list has to be flattened into the single command-line string
`CreateProcess` takes, and the child re-splits it with
`CommandLineToArgvW`'s rules: backslashes are literal *unless* they
precede a double quote, in which case they must be doubled (and the
same for backslashes right before the closing quote). The original
`append_arg` only escaped `"`, so an argument ending in a backslash —
`lume run "C:\my dir\"` — had its closing quote swallowed, merging
that argument with the next ones into one garbled string. Fixed
upstream in Certo commit `749dc02`; `tests/arg-forwarding/` pushes eight
tricky arguments (trailing backslash, embedded quote, backslash before
a quote, empty, UNC-style path) through a real shim into an echo
program and diffs what arrives, so a compiler regression can't quietly
reintroduce it. Shims stamped from a `sym_shim.exe` built by an older
compiler carry the old runtime — re-run `sym shim add` for each after
rebuilding.

### `getCurrentDir(): Text`

Added in `crates/stdlib/src/env.rs`, alongside the existing
`getEnv`/`setEnv`/`unsetEnv`. There was previously no way to read a
Certo process's own working directory at all — needed here specifically
for `climbForPin` to know where to start walking upward from.
Implemented via `GetCurrentDirectoryA` on Windows (called once with a
zero-length buffer to get the required size, then again to fill it) and
`getcwd` on POSIX (retried with a doubling buffer on `ERANGE`, the
standard pattern for that API). Deliberately left without an `[io]`
effect annotation, matching the existing convention for `getEnv`: both
read process-local state that's static for the lifetime of a run,
absent any `setCurrentDir` primitive (which doesn't exist either) that
could change it mid-process.

## Compiler bugs found and *not* fixed

Two more issues were found and deliberately left as-is in the
compiler, worked around only in this file:

1. **`??` doesn't short-circuit** — described in detail under
   `unwrapOrFatal` above. Left unfixed because fixing it means
   reworking codegen for a core operator used throughout existing
   Certo code, which is out of scope for a shim project and carries
   real regression risk elsewhere.
2. **`Path.stem` doesn't strip the directory** — described under "who
   am I?" above. Left unfixed for the same reason: small, easily
   worked around locally, not worth the risk of changing shared stdlib
   behavior other code might already depend on (however unlikely, given
   the bug).
