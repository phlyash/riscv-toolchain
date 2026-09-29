#!/usr/bin/env bash

# Download a source archive from the first reachable mirror. The archive is
# written atomically so a failed curl attempt cannot be mistaken for a cache.
# A mirror that answers HTTP 200 with something other than a readable tar
# archive (an HTML error or bot-check page, a truncated file) is skipped too.

# Succeed when $1 is a complete tar archive in the compression its name says.
fetch_source_archive_ok() {
    local archive="$1"
    local name="$2"
    local decompress

    case "$name" in
        *.tar.gz|*.tgz) decompress="gzip -dc" ;;
        *.tar.xz) decompress="xz -dc" ;;
        *.tar.bz2) decompress="bzip2 -dc" ;;
        *.tar) decompress="cat" ;;
        *) return 0 ;;
    esac

    local entries
    # pipefail in a subshell: a corrupt stream must fail even when the
    # caller did not enable it. wc reads everything, so nothing in the
    # pipe is killed early. An empty listing is not an archive either.
    entries="$(
        set -o pipefail
        $decompress < "$archive" 2>/dev/null | tar -tf - 2>/dev/null | wc -l
    )" || return 1
    [ "$entries" -gt 0 ]
}

fetch_source() {
    local destination="$1"
    shift

    local curl_bin="${FETCH_CURL:-curl}"
    local partial="${destination}.part"
    local url

    if [ "$#" -eq 0 ]; then
        echo "fetch_source: no mirrors provided for $destination" >&2
        return 2
    fi

    rm -f "$partial"

    for url in "$@"; do
        echo "download: $url" >&2

        if "$curl_bin" \
            --ipv4 \
            -fL \
            --retry 4 \
            --retry-delay 3 \
            --connect-timeout 30 \
            "$url" \
            -o "$partial"; then
            if fetch_source_archive_ok "$partial" "$destination"; then
                mv -f "$partial" "$destination"
                return 0
            fi
            echo "not a valid archive: $url" >&2
        fi

        rm -f "$partial"
        echo "mirror failed: $url" >&2
    done

    echo "unable to download $destination from any mirror" >&2
    return 1
}
