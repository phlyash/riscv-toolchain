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
        printf 'complete archive\n' > "$output"
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

[ "$(cat "$destination")" = "complete archive" ] ||
    fail "the successful mirror did not replace the partial download"

[ ! -e "$destination.part" ] ||
    fail "temporary partial download was left behind"

echo "PASS: fetch_source falls back to the next mirror"
