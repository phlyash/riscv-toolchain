#!/usr/bin/env bash

# Download a source archive from the first reachable mirror. The archive is
# written atomically so a failed curl attempt cannot be mistaken for a cache.
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
            mv -f "$partial" "$destination"
            return 0
        fi

        rm -f "$partial"
        echo "mirror failed: $url" >&2
    done

    echo "unable to download $destination from any mirror" >&2
    return 1
}
