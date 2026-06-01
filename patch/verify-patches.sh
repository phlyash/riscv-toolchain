#!/usr/bin/env bash
# Verify the CloudBEAR/NIIET patches apply cleanly onto their pinned upstream bases.
# For each baremetal-essential component: fetch the pinned base commit (shallow if the
# server allows fetch-by-SHA, else full clone), then `git am -3` the matching patch.
set -u

SCRATCH="${SCRATCH:-/tmp/rv-patch-verify}"
PATCHDIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SCRATCH"
cd "$SCRATCH"

# component | git url | pinned base sha | patch file
COMPONENTS=(
  "binutils|https://sourceware.org/git/binutils-gdb.git|675b9d6|riscv-binutils.patch"
  "gcc|https://github.com/gcc-mirror/gcc.git|cd0059a|riscv-gcc.patch"
  "newlib|https://sourceware.org/git/newlib-cygwin.git|26f7004|riscv-newlib.patch"
)

# Robustness against flaky/proxied networks that cut large transfers:
#  - HTTP/1.1 (avoids "HTTP/2 stream CANCEL")
#  - treeless partial clone (--filter=tree:0): no historical blobs, far less data
#  - big postBuffer + lenient low-speed timeout
#  - up to 4 retries
GIT_ROBUST=(-c http.version=HTTP/1.1 -c http.postBuffer=1048576000 \
            -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=300)

fetch_base () {  # dir url sha
  local dir="$1" url="$2" sha="$3" attempt
  for attempt in 1 2 3 4; do
    echo "  [attempt $attempt] treeless partial clone $url"
    rm -rf "$dir"
    if git "${GIT_ROBUST[@]}" clone --filter=tree:0 --no-checkout --no-tags "$url" "$dir"; then
      if git -C "$dir" "${GIT_ROBUST[@]}" checkout -q "$sha"; then
        echo "  [ok] checked out $sha"
        return 0
      fi
      echo "  [warn] checkout $sha failed (will retry)"
    fi
    sleep 5
  done
  echo "  [FAIL] could not fetch $url @ $sha after retries"
  return 1
}

OVERALL=0
for entry in "${COMPONENTS[@]}"; do
  IFS='|' read -r name url sha patch <<<"$entry"
  echo "==================================================================="
  echo "### $name  (base $sha, patch $patch)"
  echo "==================================================================="
  fetch_base "$name" "$url" "$sha" || { OVERALL=1; continue; }
  if ( cd "$name" && git am -3 "$PATCHDIR/$patch" ); then
    echo "  [PASS] $patch applied cleanly onto $name@$sha"
  else
    echo "  [FAIL] $patch did NOT apply cleanly"
    ( cd "$name" && git am --show-current-patch=raw | head -5; git am --abort )
    OVERALL=1
  fi
done

echo "==================================================================="
if [ "$OVERALL" -eq 0 ]; then echo "ALL PATCHES APPLIED CLEANLY"; else echo "SOME PATCHES FAILED — see above"; fi
exit "$OVERALL"
