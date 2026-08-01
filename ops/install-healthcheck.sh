#!/usr/bin/env bash
# ==============================================================================
#  install-healthcheck.sh — put healthcheck.sh on the server and schedule it.
#
#  Runs FROM YOUR LAPTOP. Reads the server address and key from whichever
#  deployment config it can find, so there is nothing to pass.
#
#     ./ops/install-healthcheck.sh            install / update, every 15 min
#     ./ops/install-healthcheck.sh --run      install, then run it once now
#     ./ops/install-healthcheck.sh --remove   uninstall the cron entry
#     ./ops/install-healthcheck.sh --tail     show the last 20 log lines
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1; export MSYS2_ARG_CONV_EXCL='*' ;;
esac

C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
note() { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

# Any deployment config will do — they all point at the same server.
CONF="$(ls -1 "$ROOT"/*/*.conf 2>/dev/null | grep -vE '\.bak$' | head -1 || true)"
[[ -n "$CONF" ]] || die "No deployment config found. Run a setup first."

val() { sed -n "s/^$1=//p" "$CONF" | head -1 | tr -d "\"'"; }
HOST="$(val SERVER_HOST)"; USER="$(val SSH_USER)"; PEM="$(val PEM_PATH)"
[[ -n "$HOST" && -f "$PEM" ]] || die "Could not read server details from $(basename "$CONF")."

SSH=(ssh -i "$PEM" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o LogLevel=ERROR)
note "using $(basename "$CONF") -> $USER@$HOST"

case "${1:-}" in
  --remove)
    step "Removing the health check"
    "${SSH[@]}" "$USER@$HOST" 'crontab -l 2>/dev/null | grep -v healthcheck.sh | crontab - ; rm -f ~/ops/healthcheck.sh; echo removed'
    ok "Uninstalled"; exit 0 ;;
  --tail)
    "${SSH[@]}" "$USER@$HOST" 'sudo tail -20 /var/log/healthcheck.log 2>/dev/null || echo "no log yet"'
    exit 0 ;;
esac

step "Installing healthcheck.sh on $HOST"
"${SSH[@]}" "$USER@$HOST" 'mkdir -p ~/ops'
scp -i "$PEM" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
    "$SCRIPT_DIR/healthcheck.sh" "$USER@$HOST:~/ops/healthcheck.sh" >/dev/null
"${SSH[@]}" "$USER@$HOST" 'chmod +x ~/ops/healthcheck.sh
sudo touch /var/log/healthcheck.log
sudo chown "$USER":"$USER" /var/log/healthcheck.log 2>/dev/null || sudo chmod 666 /var/log/healthcheck.log
# Replace any previous entry rather than stacking duplicates.
( crontab -l 2>/dev/null | grep -v healthcheck.sh ; echo "*/15 * * * * $HOME/ops/healthcheck.sh >/dev/null 2>&1" ) | crontab -
echo "cron:"; crontab -l | grep healthcheck.sh | sed "s/^/  /"'
ok "Installed — runs every 15 minutes"

if [[ "${1:-}" == "--run" ]]; then
  step "Running it once now"
  "${SSH[@]}" "$USER@$HOST" '~/ops/healthcheck.sh; echo "exit: $?"; echo; echo "--- log ---"; tail -15 /var/log/healthcheck.log'
fi

note "see results:   ./ops/install-healthcheck.sh --tail"
note "on the server: journalctl -t healthcheck --since '1 hour ago'"
