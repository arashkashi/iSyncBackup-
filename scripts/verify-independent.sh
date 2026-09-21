#!/bin/bash
# Independent audit of a mirror using ONLY stock macOS/Unix tools — no isync code involved.
# Use it when you want a second, unrelated implementation to confirm that <destination>
# really mirrors <source>.
#
#   usage: scripts/verify-independent.sh <source> <destination> [--hash]
#
# Compares: the set of paths and their types, symlink targets, file sizes, permission bits,
# extended attributes, and (with --hash) the SHA-256 of every regular file.
# Ignores the same macOS housekeeping files isync excludes by default.
set -u
SRC="${1:?source}"; DST="${2:?destination}"; HASH="${3:-}"
IGNORE='(^|/)(\.DS_Store|\.Spotlight-V100|\.fseventsd|\.Trashes|\.TemporaryItems|\.DocumentRevisions-V100|\.isync-tmp-[^/]*|\.isync)(/|$)'
W="$(mktemp -d "${TMPDIR:-/tmp}/isync-verify.XXXXXX")"
fail=0

listing() { # $1 = root, $2 = output file — "path|type|size|mode" for every entry
  ( cd "$1" && find . -mindepth 1 \( -type f -o -type d -o -type l \) -print0 \
      | xargs -0 stat -f '%N|%HT|%z|%Lp' ) 2>/dev/null \
    | grep -Ev "$IGNORE" \
    | awk -F'|' '{ if ($2 == "Directory" || $2 == "Symbolic Link") $3 = "-"; print $1 "|" $2 "|" $3 "|" $4 }' \
    | sort > "$2"
}
links() { # path|target for every symlink
  ( cd "$1" && find . -type l -print0 | xargs -0 -I{} sh -c 'printf "%s|%s\n" "{}" "$(readlink "{}")"' ) 2>/dev/null \
    | grep -Ev "$IGNORE" | sort > "$2"
}
xattrs() { # every xattr name+value, path-prefixed
  ( cd "$1" && find . -mindepth 1 \( -type f -o -type d \) -print0 | xargs -0 xattr -l ) 2>/dev/null \
    | grep -Ev "$IGNORE" | sort > "$2"
}
hashes() {
  ( cd "$1" && find . -type f -print0 | xargs -0 shasum -a 256 ) 2>/dev/null \
    | grep -Ev "$IGNORE" | sort -k2 > "$2"
}

compare() { # label, fileA, fileB
  if diff -u "$2" "$3" > "$W/$1.diff"; then
    printf '  ✔ %-22s %s entries\n' "$1" "$(wc -l < "$2" | tr -d ' ')"
  else
    fail=1
    printf '  ✖ %-22s differences (showing up to 20):\n' "$1"
    grep -E '^[-+][^-+]' "$W/$1.diff" | head -20 | sed 's/^/      /'
  fi
}

echo "Independent verification (find/stat/readlink/xattr/shasum/diff only)"
echo "  source       $SRC"
echo "  destination  $DST"
listing "$SRC" "$W/a.list"; listing "$DST" "$W/b.list"; compare "paths+size+mode" "$W/a.list" "$W/b.list"
links   "$SRC" "$W/a.links"; links   "$DST" "$W/b.links"; compare "symlink targets" "$W/a.links" "$W/b.links"
xattrs  "$SRC" "$W/a.x";     xattrs  "$DST" "$W/b.x";     compare "extended attributes" "$W/a.x" "$W/b.x"
if [ "$HASH" = "--hash" ]; then
  hashes "$SRC" "$W/a.sha"; hashes "$DST" "$W/b.sha"; compare "sha256 of every file" "$W/a.sha" "$W/b.sha"
else
  echo "  · content hashes skipped (add --hash to SHA-256 every file on both sides)"
fi
rm -rf "$W"
if [ $fail -eq 0 ]; then echo "✔ IDENTICAL by independent tools"; else echo "✖ DIFFERENCES FOUND"; fi
exit $fail
