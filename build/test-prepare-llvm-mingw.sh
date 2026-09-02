#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck source=prepare-llvm-mingw.sh
source "$ROOT/build/prepare-llvm-mingw.sh"

[ "$LLVM_MINGW_VERSION" = 20260616 ] ||
    fail "unexpected llvm-mingw version pin"
[ "$LLVM_MINGW_VARIANT" = msvcrt ] ||
    fail "unexpected llvm-mingw CRT variant"
[ "$LLVM_MINGW_ASSET" = \
    llvm-mingw-20260616-msvcrt-ubuntu-22.04-x86_64.tar.xz ] ||
    fail "unexpected llvm-mingw asset pin"
[ "$LLVM_MINGW_SHA256" = \
    a1f7968b48ba8d949194d6dee6c76f3cd0f61cba91658599af2c2c834a55ab87 ] ||
    fail "unexpected llvm-mingw SHA-256 pin"

good="$TMP/good.tar.xz"
printf 'fixture archive\n' > "$good"
digest="$(sha256_file "$good")"
verify_archive "$good" "$digest" ||
    fail "a matching checksum was rejected"

if verify_archive "$good" \
    0000000000000000000000000000000000000000000000000000000000000000; then
    fail "a checksum mismatch was accepted"
fi

required_tools='bin/x86_64-w64-mingw32-clang
bin/x86_64-w64-mingw32-clang++
bin/x86_64-w64-mingw32-windres
bin/llvm-ar
bin/llvm-ranlib
bin/llvm-strip'

make_tool_root() {
    local root="$1" tool

    mkdir -p "$root/bin"
    while IFS= read -r tool; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$root/$tool"
        chmod +x "$root/$tool"
    done <<<"$required_tools"
}

validation_root="$TMP/validation-root"
make_tool_root "$validation_root"
validate_root "$validation_root" ||
    fail "a complete llvm-mingw root was rejected"

while IFS= read -r tool; do
    rm -f "$validation_root/$tool"
    if validate_root "$validation_root" >/dev/null 2>&1; then
        fail "llvm-mingw root without $tool was accepted"
    fi
    printf '#!/usr/bin/env bash\nexit 0\n' > "$validation_root/$tool"
    chmod +x "$validation_root/$tool"
done <<<"$required_tools"

fixture_parent="$TMP/archive-source"
fixture_root="$fixture_parent/llvm-mingw-fixture-msvcrt-linux"
fixture_archive="$TMP/fixture.tar.xz"
make_tool_root "$fixture_root"
tar -cJf "$fixture_archive" -C "$fixture_parent" \
    llvm-mingw-fixture-msvcrt-linux
fixture_digest="$(sha256_file "$fixture_archive")"

attempts="$TMP/download-attempts"
fake_curl="$TMP/curl"
cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[ -n "$output" ]
printf 'download\n' >> "$LLVM_MINGW_TEST_ATTEMPTS"
cp "$LLVM_MINGW_TEST_ARCHIVE" "$output"
EOF
chmod +x "$fake_curl"

run_fixture_main() {
    local work="$1"
    local expected_digest="$2"

    WORK="$work" \
    FETCH_CURL="$fake_curl" \
    LLVM_MINGW_TEST_ATTEMPTS="$attempts" \
    LLVM_MINGW_TEST_ARCHIVE="$fixture_archive" \
        main \
            fixture \
            msvcrt \
            fixture.tar.xz \
            "$expected_digest" \
            https://fixture.invalid/fixture.tar.xz
}

work="$TMP/work"
installed="$(run_fixture_main "$work" "$fixture_digest")" ||
    fail "valid llvm-mingw fixture installation failed"
[ "$installed" = "$work/llvm-mingw-fixture-msvcrt" ] ||
    fail "bootstrap printed an unexpected installation root: $installed"
[ -f "$installed/.complete" ] ||
    fail "bootstrap did not create its completion marker"
validate_root "$installed" ||
    fail "bootstrap installed an incomplete llvm-mingw root"
[ "$(wc -l < "$attempts")" -eq 1 ] ||
    fail "bootstrap did not download exactly once"

second="$(run_fixture_main "$work" "$fixture_digest")" ||
    fail "idempotent llvm-mingw reuse failed"
[ "$second" = "$installed" ] ||
    fail "idempotent reuse changed the installation root"
[ "$(wc -l < "$attempts")" -eq 1 ] ||
    fail "completed llvm-mingw root was downloaded again"

bad_work="$TMP/bad-work"
set +e
run_fixture_main "$bad_work" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    >/dev/null 2>&1
bad_status=$?
set -e

[ "$bad_status" -ne 0 ] ||
    fail "bootstrap accepted an archive with the wrong checksum"
[ ! -e "$bad_work/llvm-mingw-fixture-msvcrt" ] ||
    fail "checksum failure left a final llvm-mingw root"
if find "$bad_work" -maxdepth 1 -name '.llvm-mingw-fixture-msvcrt.*' \
    -print -quit | grep -q .; then
    fail "checksum failure left an extraction directory"
fi

echo "PASS: llvm-mingw bootstrap is pinned, verified, atomic, and reusable"
