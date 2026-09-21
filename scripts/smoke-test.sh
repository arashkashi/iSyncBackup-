#!/bin/bash
# End-to-end test: builds fixtures with the awkward cases a macOS backup meets, syncs them,
# then proves the result with independent tools (diff -r, xattr, stat, shasum).
set -u
cd "$(dirname "$0")/.."

ISYNC="${ISYNC:-$(swift build -c release --show-bin-path 2>/dev/null)/isync}"
if [ ! -x "$ISYNC" ]; then swift build -c release >/dev/null || exit 1; ISYNC="$(swift build -c release --show-bin-path)/isync"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/isync-test.XXXXXX")"
SRC="$WORK/src"; DST="$WORK/dst"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✖ $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { "$ISYNC" --no-color "$@" 2>&1; }

echo "work dir: $WORK"
mkdir -p "$SRC/docs/nested/deep" "$SRC/Photos" "$SRC/empty-dir" "$DST"

# --- fixtures ---------------------------------------------------------------------------------
echo "hello" > "$SRC/docs/a.txt"
printf 'AAAA' > "$SRC/docs/same-size-1.bin"
head -c 3000000 /dev/urandom > "$SRC/Photos/big.bin"                # multi-chunk? no: small. see below
head -c 9000000 /dev/urandom > "$SRC/Photos/bigger.bin"             # > 2 chunks of 4 MiB
: > "$SRC/docs/zero.txt"                                            # empty file
echo "linked" > "$SRC/docs/nested/target.txt"
ln -s target.txt "$SRC/docs/nested/link"                            # relative symlink
ln -s /nonexistent/absolute "$SRC/docs/nested/deep/dangling"        # dangling symlink must be copied as-is
xattr -w com.example.tag "purple" "$SRC/docs/a.txt"                 # extended attribute
xattr -w com.apple.metadata:_kMDItemUserTags "tagged" "$SRC/Photos/big.bin"
chmod 640 "$SRC/docs/a.txt"; chmod 700 "$SRC/docs/nested"
touch -t 202001020304.05 "$SRC/docs/a.txt"
mkfifo "$SRC/docs/a-fifo"                                           # special file: must be skipped, not fatal
touch "$SRC/.DS_Store" "$SRC/docs/.DS_Store"                        # default-excluded
echo "Unicode 🙂 ünïcödé" > "$SRC/docs/ünïcödé 🙂.txt"

echo
echo "1) initial sync into empty destination"
out="$(run --report "$WORK/r1.json" "$SRC" "$DST")"; rc=$?
echo "$out" | tail -3
check "exit 0"                                   '[ $rc -eq 0 ]'
check "diff -r shows no differences (ignoring fifo/.DS_Store)" \
      'diff -r --exclude=a-fifo --exclude=.DS_Store "$SRC" "$DST" >/dev/null 2>&1'
check "xattr preserved"                          '[ "$(xattr -p com.example.tag "$DST/docs/a.txt")" = "purple" ]'
check "tags xattr preserved"                     '[ "$(xattr -p com.apple.metadata:_kMDItemUserTags "$DST/Photos/big.bin")" = "tagged" ]'
check "mode preserved (640)"                     '[ "$(stat -f %Lp "$DST/docs/a.txt")" = "640" ]'
check "dir mode preserved (700)"                 '[ "$(stat -f %Lp "$DST/docs/nested")" = "700" ]'
check "mtime preserved exactly"                  '[ "$(stat -f %Fm "$SRC/docs/a.txt")" = "$(stat -f %Fm "$DST/docs/a.txt")" ]'
check "dir mtime preserved"                      '[ "$(stat -f %Fm "$SRC/docs/nested/deep")" = "$(stat -f %Fm "$DST/docs/nested/deep")" ]'
check "relative symlink kept as symlink"         '[ "$(readlink "$DST/docs/nested/link")" = "target.txt" ]'
check "dangling symlink kept"                    '[ "$(readlink "$DST/docs/nested/deep/dangling")" = "/nonexistent/absolute" ]'
check "empty dir created"                        '[ -d "$DST/empty-dir" ]'
check "empty file copied"                        '[ -f "$DST/docs/zero.txt" ] && [ ! -s "$DST/docs/zero.txt" ]'
check "fifo skipped, not copied"                 '[ ! -e "$DST/docs/a-fifo" ]'
check ".DS_Store excluded"                       '[ ! -e "$DST/.DS_Store" ] && [ ! -e "$DST/docs/.DS_Store" ]'
check "unicode name copied"                      '[ -f "$DST/docs/ünïcödé 🙂.txt" ]'
check "big file digest matches"                  '[ "$(shasum -a 256 < "$SRC/Photos/bigger.bin")" = "$(shasum -a 256 < "$DST/Photos/bigger.bin")" ]'
check "no temp files left behind"                '[ -z "$(find "$DST" -name ".isync-tmp-*")" ]'
check "report says verified == copied"           'python3 -c "import json,sys; r=json.load(open(sys.argv[1])); c=r[\"counts\"]; sys.exit(0 if c[\"verified\"]==c[\"filesCopied\"]>0 and r[\"exitCode\"]==0 else 1)" "$WORK/r1.json"'

echo
echo "2) second run: nothing to do, nothing re-read"
out="$(run --report "$WORK/r2.json" "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "exit 0"                                   '[ $rc -eq 0 ]'
check "zero copies"                              'python3 -c "import json,sys; c=json.load(open(sys.argv[1]))[\"counts\"]; sys.exit(0 if c[\"filesCopied\"]==0 and c[\"hashedIdentical\"]==0 and c[\"directoriesCreated\"]==0 else 1)" "$WORK/r2.json"'
check "verdict says already mirrors"             'echo "$out" | grep -q "already mirrors"'

echo
echo "3) changes: same-size edit, touch-only, new file, deleted file, mode change, symlink retarget, extra in dest"
printf 'BBBB' > "$SRC/docs/same-size-1.bin"; touch -t 202101010000.00 "$SRC/docs/same-size-1.bin"   # same size, new content
touch "$SRC/Photos/big.bin"                                          # mtime changed, content identical
echo "new" > "$SRC/docs/new.txt"
rm "$SRC/docs/zero.txt"                                              # gone from source
chmod 600 "$SRC/docs/nested/target.txt"                              # metadata only
ln -sfn deep "$SRC/docs/nested/link"                                 # symlink retarget
echo "junk" > "$DST/extra.txt"; mkdir -p "$DST/extra-dir/sub"; echo "j" > "$DST/extra-dir/sub/f"
cp "$SRC/docs/a.txt" "$DST/docs/A.TXT" 2>/dev/null                   # case-insensitive FS: same file, just checks no phantom
out="$(run -n "$SRC" "$DST")"; rc=$?
check "dry run exit 0"                           '[ $rc -eq 0 ]'
check "dry run lists same-size-1 as changed"     'echo "$out" | grep -q "same-size-1.bin.*would copy\|same-size-1.bin.*content changed"'
check "dry run: big.bin identical by hash"       'echo "$out" | grep -q "big.bin.*identical by SHA-256"'
check "dry run changed nothing"                  '[ ! -e "$DST/docs/new.txt" ] && [ -e "$DST/docs/zero.txt" ]'

out="$(run --report "$WORK/r3.json" "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "exit 0 without --delete"                  '[ $rc -eq 0 ]'
check "same-size content updated"                '[ "$(cat "$DST/docs/same-size-1.bin")" = "BBBB" ]'
check "new file copied"                          '[ -f "$DST/docs/new.txt" ]'
check "mode-only change applied"                 '[ "$(stat -f %Lp "$DST/docs/nested/target.txt")" = "600" ]'
check "symlink retargeted"                       '[ "$(readlink "$DST/docs/nested/link")" = "deep" ]'
check "extraneous kept without --delete"         '[ -f "$DST/extra.txt" ] && [ -f "$DST/docs/zero.txt" ]'
check "reported extraneous > 0"                  'python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"counts\"][\"extraneousLeft\"]>0 else 1)" "$WORK/r3.json"'
check "touch-only file not recopied"             'python3 -c "import json,sys; c=json.load(open(sys.argv[1]))[\"counts\"]; sys.exit(0 if c[\"hashedIdentical\"]>=1 else 1)" "$WORK/r3.json"'

echo
echo "4) --delete with confirmation via --yes"
out="$(run --delete --yes "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "exit 0"                                   '[ $rc -eq 0 ]'
check "extraneous removed"                       '[ ! -e "$DST/extra.txt" ] && [ ! -e "$DST/extra-dir" ] && [ ! -e "$DST/docs/zero.txt" ]'
check "trees identical"                          'diff -r --exclude=a-fifo --exclude=.DS_Store "$SRC" "$DST" >/dev/null 2>&1'

echo
echo "5) type changes: file→dir, dir→file, symlink→file"
rm "$SRC/docs/new.txt"; mkdir "$SRC/docs/new.txt"; echo "inside" > "$SRC/docs/new.txt/inner"
rm -rf "$SRC/empty-dir"; echo "now a file" > "$SRC/empty-dir"
rm "$SRC/docs/nested/link"; echo "was a link" > "$SRC/docs/nested/link"
out="$(run --delete --yes "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "exit 0"                                   '[ $rc -eq 0 ]'
check "file→dir"                                 '[ -d "$DST/docs/new.txt" ] && [ -f "$DST/docs/new.txt/inner" ]'
check "dir→file"                                 '[ -f "$DST/empty-dir" ]'
check "symlink→file"                             '[ ! -L "$DST/docs/nested/link" ] && [ -f "$DST/docs/nested/link" ]'
check "trees identical"                          'diff -r --exclude=a-fifo --exclude=.DS_Store "$SRC" "$DST" >/dev/null 2>&1'

echo
echo "6) audit mode detects silent corruption in destination (same size, same mtime)"
m="$(stat -f %m "$DST/Photos/big.bin")"
printf 'X' | dd of="$DST/Photos/big.bin" bs=1 seek=1000 conv=notrunc 2>/dev/null
touch -t "$(date -r "$m" +%Y%m%d%H%M.%S)" "$DST/Photos/big.bin"
touch -r "$SRC/Photos/big.bin" "$DST/Photos/big.bin"                # restore exact mtime
out="$(run "$SRC" "$DST")"; rc=$?
check "quick mode does NOT notice (by design)"   '[ $rc -eq 0 ] && ! cmp -s "$SRC/Photos/big.bin" "$DST/Photos/big.bin"'
out="$(run --compare hash --report "$WORK/r6.json" "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "hash mode repairs it"                     '[ $rc -eq 0 ] && cmp -s "$SRC/Photos/big.bin" "$DST/Photos/big.bin"'
check "report shows exactly 1 copy"              'python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"counts\"][\"filesCopied\"]==1 else 1)" "$WORK/r6.json"'

echo
echo "7) safety: refuse to delete most of the destination; refuse nested source"
mkdir -p "$WORK/small-src" "$WORK/big-dst"; for i in $(seq 1 120); do echo $i > "$WORK/big-dst/f$i"; done
out="$(run --delete --yes "$WORK/small-src" "$WORK/big-dst")"; rc=$?
check "refuses (exit 1)"                         '[ $rc -eq 1 ] && echo "$out" | grep -q Refusing'
check "nothing deleted"                          '[ "$(ls "$WORK/big-dst" | wc -l)" -eq 120 ]'
out="$(run --delete --yes --force "$WORK/small-src" "$WORK/big-dst")"; rc=$?
check "--force allows it"                        '[ $rc -eq 0 ] && [ -z "$(ls "$WORK/big-dst")" ]'
out="$(run "$SRC/docs" "$SRC")"; rc=$?
check "source inside destination refused"        '[ $rc -eq 1 ]'
# destination inside source: the backup folder must be excluded from the scan and --delete must
# only ever touch things inside the backup folder, never the source's own files.
N="$WORK/nest-src"; mkdir -p "$N/sub/deeper"; echo a > "$N/sub/f"; echo b > "$N/top.txt"; echo c > "$N/sub/deeper/g"
out="$(run --delete --yes "$N" "$N/backup")"; rc=$?
check "dest-inside-source: exit 0"               '[ $rc -eq 0 ]'
check "dest-inside-source: source intact"        '[ -f "$N/sub/f" ] && [ -f "$N/top.txt" ] && [ -f "$N/sub/deeper/g" ]'
check "dest-inside-source: mirrored"             '[ -f "$N/backup/sub/f" ] && [ -f "$N/backup/top.txt" ] && [ -f "$N/backup/sub/deeper/g" ]'
check "dest-inside-source: not recursive"        '[ ! -e "$N/backup/backup" ]'
echo stale > "$N/backup/stale.txt"; rm "$N/top.txt"
out="$(run --delete --yes "$N" "$N/backup")"; rc=$?
check "dest-inside-source: 2nd run exit 0"       '[ $rc -eq 0 ]'
check "dest-inside-source: extraneous removed inside backup only" '[ ! -e "$N/backup/stale.txt" ] && [ ! -e "$N/backup/top.txt" ] && [ -f "$N/sub/f" ] && [ -f "$N/sub/deeper/g" ]'
check "dest-inside-source: still not recursive"  '[ ! -e "$N/backup/backup" ]'
out="$(run "$SRC" "$SRC")"; rc=$?
check "same dir refused"                         '[ $rc -eq 1 ]'

echo
echo "8) unreadable source file → error, run continues, exit 2, no bogus 'SYNCED'"
echo "secret" > "$SRC/docs/locked.txt"; chmod 000 "$SRC/docs/locked.txt"
echo "fine" > "$SRC/docs/fine.txt"
out="$(run "$SRC" "$DST")"; rc=$?
echo "$out" | tail -1
check "exit 2"                                   '[ $rc -eq 2 ]'
check "other file still copied"                  '[ -f "$DST/docs/fine.txt" ]'
check "verdict NOT SYNCED"                       'echo "$out" | grep -q "NOT SYNCED"'
chmod 644 "$SRC/docs/locked.txt"

echo
echo "9) uchg (immutable) file in destination gets replaced"
echo "v1" > "$SRC/docs/imm.txt"; run "$SRC" "$DST" >/dev/null
chflags uchg "$DST/docs/imm.txt"; echo "v2" > "$SRC/docs/imm.txt"
out="$(run "$SRC" "$DST")"; rc=$?
check "exit 0"                                   '[ $rc -eq 0 ]'
check "content replaced"                         '[ "$(cat "$DST/docs/imm.txt")" = "v2" ]'
chflags nouchg "$DST/docs/imm.txt" 2>/dev/null

echo
echo "10) .isyncignore and --exclude"
mkdir -p "$SRC/node_modules/x"; echo "m" > "$SRC/node_modules/x/m.js"; echo "t" > "$SRC/docs/scratch.tmp"
printf 'node_modules/\n*.tmp\n' > "$SRC/.isyncignore"
out="$(run "$SRC" "$DST")"; rc=$?
check "node_modules excluded"                    '[ ! -e "$DST/node_modules" ]'
check "*.tmp excluded"                           '[ ! -e "$DST/docs/scratch.tmp" ]'
check ".isyncignore itself copied"               '[ -f "$DST/.isyncignore" ]'

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ $FAIL -eq 0 ]; then rm -rf "$WORK"; else echo "fixtures kept at $WORK"; fi
[ $FAIL -eq 0 ]
