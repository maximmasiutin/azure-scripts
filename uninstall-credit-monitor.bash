#!/bin/bash

# uninstall-credit-monitor.bash - Remove monitor-credits systemd service and hook
# Reverses setup-azure-credit-monitor.bash from linux-fishtest-scripts.
#
# Usage:
#   bash uninstall-credit-monitor.bash              # Full uninstall
#   bash uninstall-credit-monitor.bash --dry-run     # Show what would be removed
#   bash uninstall-credit-monitor.bash --keep-repo   # Keep azure-scripts repo
#
# Must run as root.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root"
    exit 1
fi

DRY_RUN=false
KEEP_REPO=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --keep-repo) KEEP_REPO=true ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--keep-repo]"
            echo ""
            echo "  --dry-run    Show what would be removed without doing anything"
            echo "  --keep-repo  Keep the azure-scripts repo clone"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

SERVICE_NAME="monitor-credits"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HOOK_FILE="/opt/fishtest-credit-hook.bash"

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

echo "=== Credit Monitor Uninstall ==="
if [ "$DRY_RUN" = true ]; then
    echo "(DRY RUN - no changes will be made)"
fi
echo ""

# Step 1: Stop and remove service
echo "--- Service: ${SERVICE_NAME} ---"
if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo "  Stopping ${SERVICE_NAME}.service..."
    run_cmd systemctl stop "${SERVICE_NAME}.service"
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo "  Disabling ${SERVICE_NAME}.service..."
    run_cmd systemctl disable "${SERVICE_NAME}.service"
fi
if [ -f "$UNIT_FILE" ]; then
    echo "  Removing $UNIT_FILE"
    run_cmd rm -f "$UNIT_FILE"
    if [ "$DRY_RUN" = false ]; then
        systemctl daemon-reload
    fi
else
    echo "  Unit file not found (already removed or never installed)"
fi
echo ""

# Step 2: Remove hook script
echo "--- Hook script ---"
if [ -f "$HOOK_FILE" ]; then
    echo "  Removing $HOOK_FILE"
    run_cmd rm -f "$HOOK_FILE"
else
    echo "  Hook not found at $HOOK_FILE"
fi
echo ""

# Step 3: Remove azure-scripts repo (if cloned by setup script)
if [ "$KEEP_REPO" = false ]; then
    echo "--- Azure-scripts repo ---"
    # The setup script clones to $HOME/azure-scripts
    # Check common locations
    for user_home in /root /home/*; do
        repo_dir="$user_home/azure-scripts"
        if [ -d "$repo_dir/.git" ]; then
            echo "  Removing $repo_dir"
            run_cmd rm -rf "$repo_dir"
        fi
    done
else
    echo "--- Keeping azure-scripts repo (--keep-repo) ---"
fi
echo ""

echo "=== Uninstall complete ==="
echo ""
echo "The fishtest service itself was NOT modified."
echo "If monitor-credits had stopped fishtest, re-enable it with:"
echo "  systemctl enable --now fishtest.service"
