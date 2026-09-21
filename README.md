# isync — verified folder and drive mirroring for macOS

**A fast, free command-line backup tool for Mac that mirrors a folder or an entire volume onto
another drive, copies only what changed, and proves the result: every copied file is read back
from the destination and SHA-256-checked before the tool says SYNCED.** A modern alternative to
`rsync -a` on macOS — preserves Finder tags, extended attributes, resource forks, permissions and
nanosecond timestamps on APFS — built in Swift with zero dependencies.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue) ![language](https://img.shields.io/badge/Swift-5.9%2B-orange) ![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen) ![tests](https://img.shields.io/badge/tests-21%20unit%20%2B%2064%20e2e-success)

```
isync ~/Pictures /Volumes/BackupDrive/Pictures            # mirror; never deletes without --delete
isync -n --delete ~/Pictures /Volumes/BackupDrive/Pictures    # dry run: see the plan, change nothing
isync --delete ~/Pictures /Volumes/BackupDrive/Pictures       # true mirror, asks before deleting
isync --compare hash ~/Pictures /Volumes/BackupDrive/Pictures # audit: SHA-256 every file, both sides
```

## Who this is for

- **You keep photos, video, music or project archives on an external drive** and want a second
  drive that is an exact copy — with evidence, not hope.
- **You back up one Mac volume to another** (a Thunderbolt/USB SSD, a second internal volume) from
  the terminal or a scheduled job, and you want clear exit codes instead of a GUI.
- **Your `rsync -a` script quietly changed behaviour.** macOS now ships Apple's `openrsync`, which
  drops extended attributes and Finder tags unless you add `-E`, and truncates timestamps to whole
  seconds. See [isync vs rsync](#isync-vs-rsync-on-macos) for measurements.
- **You worry about bit rot / silent corruption on backup drives** and want an audit mode that
  reads every byte on both sides and repairs what differs.
- You want a free, scriptable alternative to Carbon Copy Cloner or ChronoSync for plain
  folder mirroring, and you are comfortable with a command line.

**Not for:** two-way sync, cloud storage, remote machines over SSH (use `rsync` there), or
versioned history with "go back to last Tuesday" (that is Time Machine's job). Direction is always
**source → destination**.

## Contents

- [Build and install](#build-and-install)
- [What "synced" means — the trust model](#what-synced-means--the-trust-model)
- [How it works](#how-it-works)
- [Safety rails](#safety-rails)
- [Exclusions](#exclusions)
- [Exit codes](#exit-codes)
- [Independent verification](#independent-verification)
- [isync vs rsync on macOS](#isync-vs-rsync-on-macos)
- [FAQ](#faq)
- [Testing](#testing)
- [Roadmap](#roadmap)

## Build and install

Requires Xcode or the Command Line Tools (`xcode-select --install`) — nothing else, no Homebrew.

```
make build            # → .build/release/isync
PREFIX=$HOME/.local make install   # → ~/.local/bin/isync, no sudo  (or plain `make install` → /usr/local/bin)
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

## isync vs rsync on macOS

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

## FAQ

### How do I mirror an external drive to another drive on macOS from the terminal?

```
isync -x --delete /Volumes/Archive /Volumes/ArchiveBackup/Archive
```

`-x` stays on the source volume (does not descend into other mounts), `--delete` makes the copy a
true mirror and asks before removing anything. Re-run the same command whenever you like; unchanged
files are not even read, so a rerun of a 60,000-file tree takes about a second and a half.

### Does it preserve Finder tags, extended attributes, resource forks, ACLs and permissions?

Yes, always, via `copyfile(3)` — the same mechanism Finder uses. Modification times are preserved
to the nanosecond on APFS. Symlinks are copied as symlinks, never followed.

### Is `--delete` safe?

It is opt-in, it shows the count and asks for confirmation, and it refuses outright to delete more
than 25 % of the destination (the "source drive was not mounted" accident) unless you pass
`--force`. Type changes (a file replaced by a folder) are handled without `--delete`, since they are
updates, not removals.

### Can it detect bit rot or silent corruption on my backup drive?

`isync --compare hash` reads every byte of every file on both sides and repairs any mismatch. Quick
mode — like rsync and Time Machine — trusts size + modification time for files it did not copy, so
run the hash audit periodically (about 300 MB/s on small files; disk-bound on large ones).

### Why not Time Machine, Carbon Copy Cloner or rsync?

Different jobs. Time Machine keeps versioned history of your boot volume; isync keeps one drive an
exact mirror of another. CCC and ChronoSync are excellent GUI tools; isync is free, scriptable and
prints a verdict you can check in a cron job. Apple's bundled `openrsync` is compared
[below](#isync-vs-rsync-on-macos); upstream rsync remains the right tool for remote machines.

### Does it work with exFAT drives or a NAS/SMB share?

It detects those filesystems and relaxes the comparison (2-second timestamp window, permissions not
compared) so every run does not "fix" things they cannot store. It has been tested extensively on
APFS→APFS; treat other targets as supported-but-less-tested and run `--compare hash` after the
first sync.

### Can I schedule it?

Yes. Exit code 0 means synced, anything else means look. A minimal `launchd` or cron line:

```
isync -q --delete --yes --report ~/backup-report.json /Volumes/Archive /Volumes/Backup/Archive || osascript -e 'display notification "Backup needs attention" with title "isync"'
```

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
