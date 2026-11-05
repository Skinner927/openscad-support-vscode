# Patched OpenSCAD language server

`server/openscad-lsp-linux` and `server/openscad-lsp.exe` in this fork are **not**
Leathong's stock 2.0.1 servers. They are builds of a community fork of the server plus
a small crash fix, committed here as binaries so the extension can be packaged
without a Rust checkout.

| | |
|---|---|
| Source repo | https://github.com/KarimAziev/openscad-LSP (branch `master`) |
| Base commit | `a37e55a` (2026-10-03, "feat: add --check CLI for saved SCAD diagnostics") |
| Local patch | [`openscad-lsp-fork.patch`](openscad-lsp-fork.patch) |
| Reports | `OpenSCAD-LSP 2.0.2` (`--version`) |
| Toolchain | rustc 1.99.1, built 2026-11-05 on Linux x86-64 |

| File | Target | How built | SHA-256 |
|---|---|---|---|
| `openscad-lsp-linux` | `x86_64-unknown-linux-gnu` (glibc, dynamically linked) | `cargo build --release` | `634aa1006b93899726c7385a22d975185b1493266f52be8108739b998cca6d1d` |
| `openscad-lsp.exe` | `x86_64-pc-windows-gnu` (links only Windows system DLLs / UCRT) | cross-compiled: `cargo zigbuild --release` (cargo-zigbuild 0.19.8, zig 0.13.0, `llvm-dlltool-18` as `x86_64-w64-mingw32-dlltool`) | `36d838acb9844142f3ffed2ff1e7895adb189c41ee79dfc3148642dc3e0b40a2` |

**`media/builtins.scad`** (passed to the server as `--builtin`) was also a dangling
symlink to the sibling checkout (`../../openscad-lsp/src/builtins`). It is now a copy
of the fork's `src/builtins` at the same commit, the same text compiled into the
binaries, so hover docs match whether or not the file is found.

**The binaries are committed as plain git blobs, not Git LFS.** GitHub refuses LFS
uploads to a public fork whose upstream has no LFS objects, and this repo is a fork
of `Leathong/openscad-support-vscode`. Each rebuild adds about 13 MB to history.

**macOS is not bundled.** `server/openscad-lsp` is still upstream's symlink to a
sibling checkout that doesn't exist here. It is excluded from the VSIX, so the
language server won't start on macOS.

**The Windows binary has not been run.** It was cross-compiled on Linux. It is a
valid PE32+ console executable, imports only standard Windows DLLs, and contains
the patch (checked by its log strings), but no test suite or editor session has
exercised it on Windows.

## The bug

Stock 2.0.1 crashes with:

```
thread 'main' panicked at src/server/parse_code.rs:64:70:
called `Option::unwrap()` on a `None` value
```

The extension only reconnects to port 3245 and never respawns the server, so after
the crash, go-to-definition, hover and completion stay dead until
`Developer: Reload Window`.

Cause: the server caches the text of every file it has seen, including files it read
from disk while following `include <...>`. In stock 2.0.1:

1. `didOpen` returns early if the file is already cached, so the editor's current text
   is ignored, and `didClose` never clears the cache.
2. If the file changed on disk in the meantime (git checkout, a script, an editor
   agent), the editor's `didChange` ranges point at text the server doesn't have.
3. `ParsedCode::edit` calls `find_offset(...).unwrap()`, and `find_offset` returns
   `None` (column past end of line) or slices out of range (line past end of file).
   Either way, the server panics.

## The fix

1. **The fork** (KarimAziev/openscad-LSP) always replaces the cached text on
   `didOpen` and watches workspace `.scad` files for changes on disk. This removes
   the trigger.
2. **The local patch** (`openscad-lsp-fork.patch`) makes any remaining desync
   non-fatal:
   - `utils.rs` `find_offset`: returns `None` for a line past the end, instead
     of slicing out of range.
   - `parse_code.rs` `ParsedCode::edit`: if an edit range doesn't fit the cached
     text, or start > end, it logs
     `[error] ignoring out-of-sync edit to <uri>: ...` to the OpenSCAD-LSP output
     channel, skips the rest of that batch, and reparses the current text from
     scratch so the syntax tree stays consistent.

```diff
--- a/src/server/parse_code.rs
+++ b/src/server/parse_code.rs
@@ -100,8 +100,27 @@ impl ParsedCode {
         let mut old_tree = Some(&mut self.tree);
         for event in events {
             if let Some(range) = event.range {
-                let start_ofs = find_offset(&self.code, range.start).unwrap();
-                let end_ofs = find_offset(&self.code, range.end).unwrap();
+                let (start_ofs, end_ofs) = match (
+                    find_offset(&self.code, range.start),
+                    find_offset(&self.code, range.end),
+                ) {
+                    (Some(s), Some(e)) if s <= e => (s, e),
+                    _ => {
+                        // Our copy of the document is out of sync with the client
+                        // (e.g. the file changed on disk while we held a stale copy).
+                        // Skip the rest of this batch rather than panic; the next
+                        // didOpen or file-watcher refresh resyncs the text. Drop the
+                        // incremental tree so the reparse below matches `self.code`.
+                        err_to_console!(
+                            "ignoring out-of-sync edit to {}: range {:?} does not fit the cached text ({} bytes)",
+                            self.url,
+                            range,
+                            self.code.len()
+                        );
+                        old_tree = None;
+                        break;
+                    }
+                };
                 self.code.replace_range(start_ofs..end_ofs, &event.text);
 
                 let new_end_position = match event.text.rfind('\n') {
--- a/src/server/utils.rs
+++ b/src/server/utils.rs
@@ -20,7 +20,9 @@ macro_rules! err_to_console {
 pub(crate) fn find_offset(text: &str, pos: Position) -> Option<usize> {
     let mut offset = 0;
     for _ in 0..pos.line {
-        offset += text[offset..].find('\n').unwrap_or_default() + 1;
+        // A line past the end of `text` means the client's view has diverged
+        // from ours; report it instead of slicing out of range.
+        offset += text[offset..].find('\n')? + 1;
     }
 
     let mut chars = text[offset..].chars();
```

## Verification (2026-11-05, Linux binary)

| Check | Stock 2.0.1 | Fork, unpatched | Fork + patch |
|---|---|---|---|
| Stale-cache repro (file changed on disk, reopened, edited) | panics | survives | survives |
| Direct out-of-range edits: column past end, line past end, start > end | all panic | not run | all survive and log `[error]` |
| Cross-file go-to-definition through `include` | OK | not run | OK |
| `cargo test --release` | n/a | n/a | 53 passed, 0 failed |
| Real use in VSCodium (F12 across included files) | crashed | n/a | works |

## Known limitation

LSP positions are UTF-16 code units, but `find_offset` counts Unicode scalar values.
Characters outside the Basic Multilingual Plane (e.g. emoji) in a `.scad` file can
make edit offsets wrong. With the patch this no longer crashes; the edit is skipped
or misplaced until the next resync.

## Rebuilding

```bash
git clone https://github.com/KarimAziev/openscad-LSP ~/src/openscad-LSP
cd ~/src/openscad-LSP
git checkout a37e55a
git apply /path/to/this/repo/server/openscad-lsp-fork.patch
cargo build --release
cp target/release/openscad-lsp /path/to/this/repo/server/openscad-lsp-linux
```

Windows, cross-compiled from Linux:

```bash
rustup target add x86_64-pc-windows-gnu
cargo install --locked cargo-zigbuild --version 0.19.8
python3 -m venv ~/.zigvenv && ~/.zigvenv/bin/pip install ziglang==0.13.0
mkdir -p ~/.zigshim && ln -sf "$(command -v llvm-dlltool-18)" ~/.zigshim/x86_64-w64-mingw32-dlltool
PATH="$HOME/.zigshim:$HOME/.zigvenv/bin:$PATH" cargo zigbuild --release --target x86_64-pc-windows-gnu
cp target/x86_64-pc-windows-gnu/release/openscad-lsp.exe /path/to/this/repo/server/openscad-lsp.exe
```

Without the dlltool shim, the build fails in `windows-sys` with
`error calling dlltool 'x86_64-w64-mingw32-dlltool'`.

Then update the commit, rustc version and SHA-256s above, and run `make install`.
