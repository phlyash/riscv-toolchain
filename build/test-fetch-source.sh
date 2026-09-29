#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$ROOT/build/fetch-source.sh" ] ||
    fail "build/fetch-source.sh is missing"

mkdir -p "$TMP/fixture/source"
printf 'source file\n' > "$TMP/fixture/source/README"
tar -cJf "$TMP/good.tar.xz" -C "$TMP/fixture" source
tar -czf "$TMP/good.tar.gz" -C "$TMP/fixture" source
export FETCH_TEST_GOOD_XZ="$TMP/good.tar.xz"
export FETCH_TEST_GOOD_GZ="$TMP/good.tar.gz"

cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

printf '%s\n' "$url" >> "$FETCH_TEST_ATTEMPTS"

case "$url" in
    https://bad.example/source.tar.xz)
        printf 'partial download\n' > "$output"
        exit 22
        ;;
    https://good.example/source.tar.xz)
        cp "$FETCH_TEST_GOOD_XZ" "$output"
        ;;
    https://html.example/source.tar.gz)
        # HTTP 200 with a bot-check page instead of the archive.
        printf '<html><body>checking your browser</body></html>\n' > "$output"
        ;;
    https://truncated.example/source.tar.gz)
        head -c 64 "$FETCH_TEST_GOOD_GZ" > "$output"
        ;;
    https://good.example/source.tar.gz)
        cp "$FETCH_TEST_GOOD_GZ" "$output"
        ;;
    *)
        echo "unexpected URL: $url" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$TMP/curl"

export FETCH_TEST_ATTEMPTS="$TMP/attempts"
export FETCH_CURL="$TMP/curl"

# shellcheck source=fetch-source.sh
source "$ROOT/build/fetch-source.sh"

destination="$TMP/source.tar.xz"
fetch_source "$destination" \
    https://bad.example/source.tar.xz \
    https://good.example/source.tar.xz

expected_attempts="$(printf '%s\n' \
    https://bad.example/source.tar.xz \
    https://good.example/source.tar.xz)"
actual_attempts="$(cat "$FETCH_TEST_ATTEMPTS")"

[ "$actual_attempts" = "$expected_attempts" ] ||
    fail "mirrors were not tried in order"

cmp -s "$destination" "$FETCH_TEST_GOOD_XZ" ||
    fail "the successful mirror did not replace the partial download"

[ ! -e "$destination.part" ] ||
    fail "temporary partial download was left behind"

echo "PASS: fetch_source falls back to the next mirror"

: > "$FETCH_TEST_ATTEMPTS"
destination="$TMP/source.tar.gz"
fetch_source "$destination" \
    https://html.example/source.tar.gz \
    https://truncated.example/source.tar.gz \
    https://good.example/source.tar.gz 2>/dev/null

expected_attempts="$(printf '%s\n' \
    https://html.example/source.tar.gz \
    https://truncated.example/source.tar.gz \
    https://good.example/source.tar.gz)"
[ "$(cat "$FETCH_TEST_ATTEMPTS")" = "$expected_attempts" ] ||
    fail "invalid archives did not fall back to the next mirror"

cmp -s "$destination" "$FETCH_TEST_GOOD_GZ" ||
    fail "an invalid archive was accepted"

[ ! -e "$destination.part" ] ||
    fail "temporary partial download was left behind"

: > "$FETCH_TEST_ATTEMPTS"
rm -f "$TMP/only-html.tar.gz"
if fetch_source "$TMP/only-html.tar.gz" \
    https://html.example/source.tar.gz 2>/dev/null; then
    fail "an HTML page was accepted as the only mirror"
fi
[ ! -e "$TMP/only-html.tar.gz" ] ||
    fail "a rejected download was left at the destination"

echo "PASS: fetch_source rejects HTTP 200 responses that are not archives"
