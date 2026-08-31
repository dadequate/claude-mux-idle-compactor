#!/usr/bin/env bash
# install.sh -- wires idle-compactor.sh into launchd so it runs every 15
# minutes. NOT run automatically by anything in this repo -- run this by
# hand when you're ready, and only go --live after reviewing a day of
# --dry-run log output.
#
# launchd, not crontab: on macOS, launchd is the idiomatic way to run a
# recurring background job (check `ls ~/Library/LaunchAgents` -- most
# machines already have several). Adapt this to systemd/cron/whatever your
# platform's idiom is if you're not on macOS.
#
# Usage:
#   setup/install.sh --dry-run   Install the job in --dry-run mode (logs only,
#                                 sends nothing). Validate this for a day
#                                 before going live.
#   setup/install.sh --live      Install the job in live mode (sends real
#                                 /compact commands). Only run this after
#                                 reviewing a day of --dry-run log output.
#   setup/install.sh --uninstall Unload and remove the launchd job.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/bin/idle-compactor.sh"
TEMPLATE="$REPO_DIR/setup/com.example.claude-mux-idle-compactor.plist.template"
# Customize this label if you're running more than one instance, or just
# prefer your own reverse-DNS namespace.
LABEL="com.example.claude-mux-idle-compactor"
PLIST_DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"

usage() {
    echo "usage: $0 --dry-run | --live | --uninstall" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

case "$1" in
    --uninstall)
        if launchctl list "$LABEL" >/dev/null 2>&1; then
            launchctl unload "$PLIST_DEST" 2>/dev/null || true
        fi
        rm -f "$PLIST_DEST"
        echo "Uninstalled $LABEL."
        exit 0
        ;;
    --dry-run)
        extra_arg_sed=(-e 's#__EXTRA_ARG_LINE__#        <string>--dry-run</string>#')
        mode_desc="DRY-RUN (logs only, sends nothing)"
        ;;
    --live)
        # Delete the whole placeholder line rather than substitute into it --
        # BSD sed (macOS) chokes on a literal embedded newline in a
        # replacement string, which a naive "replace with empty string"
        # approach here would otherwise require.
        extra_arg_sed=(-e '/__EXTRA_ARG_LINE__/d')
        mode_desc="LIVE (will send real /compact commands into idle sessions)"
        ;;
    *)
        usage
        ;;
esac

mkdir -p "$LOG_DIR"

sed \
    -e "s#__SCRIPT_PATH__#${SCRIPT_PATH}#g" \
    -e "s#__LOG_DIR__#${LOG_DIR}#g" \
    "${extra_arg_sed[@]}" \
    "$TEMPLATE" > "$PLIST_DEST"

# Reload cleanly if it's already loaded (e.g. switching dry-run -> live)
if launchctl list "$LABEL" >/dev/null 2>&1; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi
launchctl load "$PLIST_DEST"

echo "Installed $LABEL -- mode: $mode_desc"
echo "Plist: $PLIST_DEST"
echo "Runs every 15 minutes. Logs: $HOME/Library/Logs/claude-mux-idle-compactor.log"
echo "Uninstall any time with: $0 --uninstall"
