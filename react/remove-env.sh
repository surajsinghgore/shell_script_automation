#!/usr/bin/env bash
# ==============================================================================
#  remove-env.sh — delete an environment.
#
#     ./remove-env.sh              pick from a numbered list
#     ./remove-env.sh develop      remove the develop environment
#     ./remove-env.sh 2            pick by number
#     ./remove-env.sh --dry-run 2  show exactly what would go, delete nothing
#
#  It shows everything that will be destroyed, then makes you TYPE THE NAME to
#  confirm. Local files and the server side are asked about separately, so you
#  can drop a config without taking a live site down.
#
#  NOT touched: the Let's Encrypt certificate (harmless to keep, and re-issuing
#  burns rate limit), other sites, and the ClinicCare backend.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER="$SCRIPT_DIR/react-develop.sh"

IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; export MSYS_NO_PATHCONV=1; export MSYS2_ARG_CONV_EXCL='*' ;;
esac

C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
note() { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

usage() { sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

[[ -f "$DEPLOYER" ]] || die "react-develop.sh not found next to this script."

ENVS=()
while IFS= read -r l; do [[ -n "$l" ]] && ENVS+=("$l"); done < <(
  ls -1 "$SCRIPT_DIR"/react-develop.*.conf 2>/dev/null \
    | sed 's|.*/react-develop\.||; s|\.conf$||' | sort
)
[[ ${#ENVS[@]} -gt 0 ]] || die "No environments configured — nothing to remove."

conf_value() { sed -n "s/^$2=//p" "$SCRIPT_DIR/react-develop.$1.conf" 2>/dev/null | head -1 | tr -d "\"'"; }

show_table() {
  printf '\n  %-4s %-24s %-12s %s\n' "#" "ENVIRONMENT" "BRANCH" "DOMAIN"
  printf '  %-4s %-24s %-12s %s\n' "---" "-----------" "------" "------"
  local i=1 e
  for e in "${ENVS[@]}"; do
    printf '  %-4s %-24s %-12s %s\n' "$i)" "$e" "$(conf_value "$e" GIT_BRANCH)" "$(conf_value "$e" DOMAIN)"
    i=$(( i + 1 ))
  done
  echo
}

RESOLVED=""
resolve_choice() {
  local c="$1" e
  if [[ "$c" =~ ^[0-9]+$ ]]; then
    (( c >= 1 && c <= ${#ENVS[@]} )) || die "There is no option $c — pick 1 to ${#ENVS[@]}."
    RESOLVED="${ENVS[$(( c - 1 ))]}"; return 0
  fi
  for e in "${ENVS[@]}"; do [[ "$e" == "$c" ]] && { RESOLVED="$e"; return 0; }; done
  die "No environment called '$c'. Configured: ${ENVS[*]}"
}

# ---- pick --------------------------------------------------------------------
DRY=0
ARG="${1:-}"
case "$ARG" in
  -h|--help|help) usage; exit 0 ;;
  --list|-l|list) show_table; exit 0 ;;
  --dry-run|-n)   DRY=1; ARG="${2:-}" ;;
esac

if [[ -z "$ARG" ]]; then
  show_table
  read -r -p "  Remove which environment? (number or name): " ARG
  [[ -n "$ARG" ]] || die "Nothing chosen."
fi
resolve_choice "$ARG"
ENV_NAME="$RESOLVED"

CONF="$SCRIPT_DIR/react-develop.$ENV_NAME.conf"
ENVF="$SCRIPT_DIR/.env.$ENV_NAME"
APP_NAME="$(conf_value "$ENV_NAME" APP_NAME)"
APP_DIR="$(conf_value "$ENV_NAME" APP_DIR)"
WEB_ROOT="$(conf_value "$ENV_NAME" WEB_ROOT)"
DOMAIN="$(conf_value "$ENV_NAME" DOMAIN)"
SERVER_HOST="$(conf_value "$ENV_NAME" SERVER_HOST)"
SSH_USER="$(conf_value "$ENV_NAME" SSH_USER)"
PEM_PATH="$(conf_value "$ENV_NAME" PEM_PATH)"

[[ ${#ENVS[@]} -eq 1 ]] && warn "This is your only configured environment."

# ---- show the blast radius ---------------------------------------------------
step "Removing environment: $ENV_NAME"
cat <<EOF

  ${C_Y}On your laptop${C_0}
    $CONF
    $([[ -f "$ENVF" ]] && echo "$ENVF" || echo "(no .env.$ENV_NAME)")

  ${C_Y}On $SERVER_HOST${C_0}
    /etc/nginx/sites-available/$APP_NAME   and its sites-enabled symlink
    $WEB_ROOT                              (every release of the built site)
    $APP_DIR                               (checkout + node_modules)
    /var/log/nginx/$APP_NAME.*.log

  ${C_Y}Kept${C_0}
    the TLS certificate for ${DOMAIN:-(none)}
    every other site on this server

EOF

if [[ "$DRY" == "1" ]]; then
  ok "Dry run — nothing was deleted."
  exit 0
fi

[[ -n "$DOMAIN" ]] && warn "https://$DOMAIN will stop working."
printf '\n  Type the environment name (%s) to confirm: ' "$ENV_NAME"
read -r CONFIRM
[[ "$CONFIRM" == "$ENV_NAME" ]] || die "Did not match — nothing was deleted."

# ---- server side (optional) --------------------------------------------------
read -r -p "  Also delete the site from the server? (y/N): " DO_SERVER
if [[ "$DO_SERVER" =~ ^[Yy] ]]; then
  [[ -n "$SERVER_HOST" && -n "$PEM_PATH" && -f "$PEM_PATH" ]] \
    || die "Cannot reach the server (PEM '$PEM_PATH' missing). Re-run and answer N to remove local files only."
  step "Deleting $APP_NAME from $SERVER_HOST"
  ssh -i "$PEM_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o LogLevel=ERROR \
      "$SSH_USER@$SERVER_HOST" \
      "APP_NAME=$(printf '%q' "$APP_NAME") APP_DIR=$(printf '%q' "$APP_DIR") WEB_ROOT=$(printf '%q' "$WEB_ROOT") bash -s" <<'REMOTE'
set -uo pipefail

# Refuse to run with an empty path — "rm -rf $WEB_ROOT/" with WEB_ROOT unset
# would be catastrophic.
case "${WEB_ROOT:-}" in /var/www/?*) ;; *) echo "ERROR: refusing, WEB_ROOT='${WEB_ROOT:-}'"; exit 1 ;; esac
case "${APP_DIR:-}"  in /home/?*|/root/?*) ;; *) echo "ERROR: refusing, APP_DIR='${APP_DIR:-}'"; exit 1 ;; esac
[ -n "${APP_NAME:-}" ] || { echo "ERROR: APP_NAME empty"; exit 1; }

echo "--- disabling the nginx site"
sudo rm -f "/etc/nginx/sites-enabled/$APP_NAME"
sudo rm -f "/etc/nginx/sites-available/$APP_NAME"

if sudo nginx -t 2>/dev/null; then
  sudo systemctl reload nginx
  echo "nginx reloaded"
else
  echo "WARNING: nginx config test failed — NOT reloading. Run 'sudo nginx -t' on the server."
fi

echo "--- removing $WEB_ROOT"
sudo rm -rf "$WEB_ROOT"
echo "--- removing $APP_DIR"
rm -rf "$APP_DIR" 2>/dev/null || sudo rm -rf "$APP_DIR"
echo "--- removing logs"
sudo rm -f "/var/log/nginx/$APP_NAME."*.log

echo "--- remaining sites"
ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/    /' || echo "    (none)"
df -h / | tail -1
exit 0
REMOTE
  ok "Server side removed"
else
  note "server untouched — the site keeps serving until you remove it by hand"
fi

# ---- local side --------------------------------------------------------------
step "Removing local files"
[[ -f "$CONF" ]] && { rm -f "$CONF"; note "deleted $(basename "$CONF")"; }
if [[ -f "$ENVF" ]]; then
  read -r -p "  Delete $(basename "$ENVF") too? (y/N): " a
  [[ "$a" =~ ^[Yy] ]] && { rm -f "$ENVF"; note "deleted $(basename "$ENVF")"; } \
                      || note "kept $(basename "$ENVF")"
fi
rm -f "$CONF.bak"

ok "Environment '$ENV_NAME' removed"
step "Still configured"
"$DEPLOYER" envs || true
