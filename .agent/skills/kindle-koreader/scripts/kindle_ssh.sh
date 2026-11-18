#!/usr/bin/env bash
# SSH command runner and clean macOS/Linux -> Kindle .koplugin tar deployer.
# Avoids BatchMode=yes (which breaks KOReader's passwordless Dropbear) and
# strips macOS AppleDouble (._*) resource forks on FAT32 /mnt/us.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${KINDLE_HOST:-}"
PORT="${KINDLE_PORT:-2222}"
USER_NAME="${KINDLE_USER:-root}"

usage() {
    cat >&2 <<'EOF'
Usage:
  [KINDLE_HOST=192.168.x.x] kindle_ssh.sh exec "<remote command>"
  [KINDLE_HOST=192.168.x.x] kindle_ssh.sh deploy <local_plugin_dir> <remote_plugin_dir>
EOF
    exit 2
}

if [[ $# -lt 2 ]]; then
    usage
fi

if [[ -z "$HOST" ]]; then
    HOST="$(python3 -B "$SCRIPT_DIR/kindle_usb_bridge.py" host --port "$PORT")"
fi

SSH_OPTS=(
    -o LogLevel=error
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
    -p "$PORT"
)

export SSH_ASKPASS_REQUIRE=never
SSH_CMD=(ssh "${SSH_OPTS[@]}")
if command -v sshpass >/dev/null 2>&1; then
    SSH_CMD=(sshpass -p "${KINDLE_PASSWORD:-}" "${SSH_CMD[@]}")
fi

subcmd="$1"
shift

case "$subcmd" in
    exec)
        exec "${SSH_CMD[@]}" "${USER_NAME}@${HOST}" "$@"
        ;;
    deploy)
        if [[ $# -lt 2 ]]; then
            usage
        fi
        local_dir="$1"
        remote_dir="$2"
        if [[ ! -d "$local_dir" ]]; then
            echo "error: local directory not found: $local_dir" >&2
            exit 1
        fi
        COPYFILE_DISABLE=1 tar -C "$local_dir" \
            --exclude='.DS_Store' \
            --exclude='._*' \
            -czf - . | "${SSH_CMD[@]}" "${USER_NAME}@${HOST}" \
            "mkdir -p '$remote_dir' && tar -C '$remote_dir' -xzf - && find '$remote_dir/bin' -type f -exec chmod +x {} + 2>/dev/null || true"
        echo "Deployed $local_dir -> ${USER_NAME}@${HOST}:${remote_dir}"
        ;;
    *)
        usage
        ;;
esac
