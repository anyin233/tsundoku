#!/usr/bin/env bash
# One-command first-time installer for usbdebug.koplugin over USB Mass Storage or MTP.
# Run once while the Kindle is exited out of KOReader (in stock USB/MTP mode),
# then reopen KOReader. Subsequent deploys can use USB SSH directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USBDEBUG_ROOT="$(cd "$SCRIPT_DIR/../resources/usbdebug" && pwd)"
PLUGIN_DIR="$USBDEBUG_ROOT/usbdebug.koplugin"

if [[ ! -x "$PLUGIN_DIR/bin/armv7/usbdebugd" ]]; then
    if command -v go >/dev/null 2>&1; then
        echo "Prebuilt daemon binaries not found; running build_usbdebug.sh..."
        "$SCRIPT_DIR/build_usbdebug.sh"
    else
        echo "error: $PLUGIN_DIR/bin/armv7/usbdebugd is missing and Go is not installed." >&2
        exit 1
    fi
fi

# 1. Legacy USB Mass Storage Kindle check
for mount_candidate in \
    /Volumes/Kindle \
    /media/*/Kindle \
    /run/media/*/*/Kindle \
    /mnt/kindle
do
    if [[ -d "$mount_candidate/koreader/plugins" ]]; then
        dest="$mount_candidate/koreader/plugins/usbdebug.koplugin"
        echo "Detected USB Mass Storage Kindle at $mount_candidate"
        mkdir -p "$dest"
        COPYFILE_DISABLE=1 tar -C "$PLUGIN_DIR" \
            --exclude='.DS_Store' \
            --exclude='._*' \
            -cf - . | tar -C "$dest" -xf -
        sync 2>/dev/null || true
        echo "Installed usbdebug.koplugin -> $dest"
        echo "Safely eject the Kindle and open KOReader to start USB debugging."
        exit 0
    fi
done

# 2. MTP-era Kindle (PW6, Scribe, Colorsoft, KT6, FW 5.16.3+)
mkdir -p "$USBDEBUG_ROOT/build"
mtp_tool="$USBDEBUG_ROOT/build/mtp_tool"

if [[ ! -x "$mtp_tool" ]] || [[ "$USBDEBUG_ROOT/tools/mtp_tool.c" -nt "$mtp_tool" ]]; then
    if ! command -v clang >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
        echo "error: C compiler (clang/gcc) not found to build $USBDEBUG_ROOT/tools/mtp_tool.c" >&2
        exit 1
    fi
    cc="$(command -v clang || command -v gcc)"
    cflags=()
    ldflags=()
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libmtp; then
        read -ra cflags <<<"$(pkg-config --cflags libmtp)"
        read -ra ldflags <<<"$(pkg-config --libs libmtp)"
    elif [[ -d /opt/homebrew/include ]] && [[ -f /opt/homebrew/lib/libmtp.dylib ]]; then
        cflags=(-I/opt/homebrew/include)
        ldflags=(-L/opt/homebrew/lib -lmtp)
    elif [[ -d /usr/local/include ]] && [[ -f /usr/local/lib/libmtp.dylib ]]; then
        cflags=(-I/usr/local/include)
        ldflags=(-L/usr/local/lib -lmtp)
    else
        cflags=()
        ldflags=(-lmtp)
    fi
    echo "Compiling resources/usbdebug/tools/mtp_tool.c -> build/mtp_tool..."
    "$cc" -O2 -Wall "${cflags[@]}" "$USBDEBUG_ROOT/tools/mtp_tool.c" "${ldflags[@]}" -o "$mtp_tool"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    pkill -9 ptpcamerad 2>/dev/null || true
    sleep 0.2
fi

echo "Uploading usbdebug.koplugin via MTP -> /koreader/plugins/usbdebug.koplugin ..."
"$mtp_tool" put-dir "$PLUGIN_DIR" /koreader/plugins/usbdebug.koplugin
echo ""
echo "Done! Reopen KOReader on your Kindle — usbdebug.koplugin will start automatically."
