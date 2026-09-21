# isync — verified one-way folder mirroring for macOS

`isync` makes a destination folder (or volume) an exact mirror of a source folder, transferring
only what changed, and does not say **SYNCED** unless it has evidence for it.

```
isync ~/Documents /Volumes/Backup/Documents          # mirror; never deletes without --delete
isync --delete ~/Documents /Volumes/Backup/Documents # true mirror, asks before deleting
isync -n --delete ~/Documents /Volumes/Backup/Documents   # dry run: show the plan, change nothing
isync --compare hash ~/Documents /Volumes/Backup/Documents   # audit: SHA-256 every file on both sides
```

Zero dependencies: a single Swift binary using only Apple's system frameworks. Direction is always
**source → destination**; it is a backup tool, not a two-way sync.

## Build

Requires Xcode (or the Command Line Tools) — nothing else.

```
make build            # → .build/release/isync
make install          # → /usr/local/bin/isync   (PREFIX=~/bin make install for a user install)
make test             # unit tests
make smoke            # end-to-end tests on a temporary fixture tree
```

## What "synced" means — the trust model

The final line of every run is a verdict. Its wording states exactly what was checked.

| Mode | How a file on both sides is judged unchanged | What is proven when the run says SYNCED |
|---|---|---|
| `--compare quick` (default) | same size **and** identical mtime (nanosecond-exact on APFS→APFS) **and** same permissions/flags. If only the mtime differs, both sides are SHA-256 hashed before deciding. | Every file that was copied was **re-read from the destination disk** (page cache bypassed) and its SHA-256 matched what was read from the source. Files judged unchanged were **not** read — that judgement rests on size+mtime. |
| `--compare hash` | SHA-256 of both sides, always. | Every file on both sides was read and compared. This is the audit mode. |
| `--no-verify` | as quick | Copies were not re-read. Fastest; use when the destination is a trustworthy local disk and speed matters more. |

Honest limits:

* **Quick mode is a heuristic.** A file whose content changed while its size and mtime stayed
  identical (a deliberately back-dated write, or bit rot on the *destination*) is invisible to it —
  the same is true of `rsync`, Time Machine and every other incremental tool. Run `--compare hash`
  periodically (it is fast: ~500 MB/s on small files, disk-bound on large ones) to catch it.
* **Verification proves the copy reached the drive**, not that the drive will still return it in
  five years. For that, keep more than one backup.
* **Read-back bypasses the OS page cache** (`F_NOCACHE`), so it reads what the filesystem stored,
  but a drive's own write cache can still be between you and the platters/cells. A final
  `F_FULLFSYNC` on the destination asks the drive to flush that cache before the verdict is printed.

## How it works

1. **Scan** source and destination in parallel (`readdir` + `lstat`, symlinks never followed).
2. **Plan** — a pure diff producing ordered actions: removals for type changes (file↔dir↔symlink),
   `mkdir`s, file work, deletions (children before parents), directory metadata (deepest first).
   Big files are scheduled first so all workers stay busy to the end.
3. **Execute** file work on a pool of workers (`--jobs`, default = cores, max 8). Each copy:
   stream source → temp file in the destination directory, hashing the bytes on the way →
   `fsync` → atomic `rename()` over the target → copy permissions, flags, times, ACLs and
   extended attributes (`copyfile(3)` — Finder tags, resource forks, quarantine info) →
   re-read and compare. **A crash at any point leaves either the old file or the complete new one,
   never a partial one.** If verification fails, the bad destination file is deleted so the next
   run cannot mistake it for a good copy.
4. **Verdict** + optional JSON report (`--report run.json`) listing every error and every count.

Names are matched the way the volume matches them: on case-insensitive APFS/HFS+ (the default),
`Readme.md` and `README.MD` are the same file, so no phantom copy/delete pairs.

## Safety rails

* Nothing is ever deleted from the destination without `--delete`.
* `--delete` asks for confirmation (skip with `--yes`) and **refuses** to remove more than 25 % of
  the destination unless you pass `--force` — the classic "source disk wasn't mounted, backup got
  wiped" accident cannot happen by default.
* `--delete` is also refused when the source scan had errors, since "missing from the source"
  cannot be trusted then.
* Source inside destination → refused. Destination inside source → excluded from the scan.
* Errors (unreadable files, permission denied…) never abort the run; everything else is synced,
  every error is listed, the verdict is **NOT SYNCED** and the exit code is 2.
* Ctrl-C finishes the current chunk, removes temp files, and reports what was completed.
* Sockets, FIFOs and device nodes are reported as skipped, never copied.

## Exclusions

Default: `.DS_Store .Spotlight-V100 .fseventsd .Trashes .TemporaryItems .DocumentRevisions-V100`
and a few more volume-housekeeping items (`--no-default-excludes` to keep them).
Add your own with `--exclude PATTERN` or a `.isyncignore` file in the source root:

```
# name patterns match anywhere; path patterns are relative to the root
node_modules/
*.tmp
Library/Caches/*
```

`-x` / `--one-file-system` stops at mount points when backing up a whole volume.

## Exit codes

| code | meaning |
|---|---|
| 0 | synced (per the mode's guarantee), or dry run finished |
| 1 | bad arguments, or refused to start (safety rail) |
| 2 | finished with errors — **not** synced |
| 3 | synced, but some files changed *while* being copied; run again |
| 130 | interrupted |

## Independent verification

Trust should not rest on one implementation. `scripts/verify-independent.sh <src> <dst> [--hash]`
audits a mirror using only `find`, `stat`, `readlink`, `xattr`, `shasum` and `diff` — no isync
code at all. Use it whenever you want a second opinion.

## Why not just rsync?

macOS 26 ships Apple's `openrsync`, not the upstream rsync 3.x. Measured on the same 62,490-entry /
1.9 GB tree, APFS→APFS, Apple silicon:

| | `openrsync -aE` | `isync` (fsync + read-back verify) |
|---|---|---|
| first copy | 37.4 s | 22.7 s |
| no-op rerun | 7.3 s | 1.5 s |
| full-content audit of both sides | 82 s (`-aEc`, MD4 checksums, single-threaded) | 6.0 s (`--compare hash`, SHA-256, 8 workers) |
| xattrs / tags / resource forks | only with `-E`; silently dropped with plain `-a` | always |
| mtime | truncated to whole seconds | nanosecond-exact |
| copy verified by re-reading the destination | no | yes |
| atomic temp+rename | yes | yes, plus per-file fsync |
| refuses to wipe the destination | only via `--max-delete` | yes, by default |
| machine-readable report | no | JSON |

The two tools' outputs were cross-checked with `diff -rq` and found identical. `rsync` remains the
right choice when the far end is a remote machine over SSH; `isync` is for local disks and mounted
volumes where you want certainty and speed.

## Testing

* `swift test` — 21 unit tests on the planner (case folding, mtime windows, type conflicts,
  delete ordering, flag masking, ignore rules).
* `scripts/smoke-test.sh` — 64 end-to-end checks on a fixture tree: xattrs, modes, exact mtimes,
  symlinks (relative, dangling, retargeted), unicode names, empty files/dirs, FIFOs, immutable
  files, same-size edits, touch-only changes, type changes in both directions, extraneous items with
  and without `--delete`, silent-corruption detection in audit mode, unreadable files, every
  safety refusal, destination-inside-source with `--delete`, `.isyncignore`.

## Roadmap

* `--trash`: move deleted items into `.isync/trash/<timestamp>/` instead of unlinking.
* Hard-link preservation (`nlink > 1` is already recorded per entry).
* Persistent manifest in the destination for bit-rot detection without re-reading the source.
* A SwiftUI front end over `ISyncCore` (the engine is a separate library target for this reason).
