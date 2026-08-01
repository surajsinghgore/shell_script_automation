#!/usr/bin/env bash
# ==============================================================================
#  edit-env.sh — change an environment's variables and make them take effect.
#
#  Opens that environment's .env in your editor (Notepad on Windows), waits for
#  you to save and close it, shows what changed, then uploads it and REBUILDS.
#
#     ./edit-env.sh              pick from a numbered list
#     ./edit-env.sh develop      edit develop's variables
#     ./edit-env.sh 2            pick by number
#     ./edit-env.sh --show main  print main's file, change nothing
#
#  RESTART OR REBUILD
#  Next.js has two kinds of variable and they cost very different amounts:
#     NEXT_PUBLIC_*  compiled into the browser bundle at BUILD time -> rebuild
#     everything else read by the server at RUNTIME                 -> restart
#  A restart is seconds, a rebuild is minutes. This works out which keys you
#  actually changed and does the cheaper one, rather than always rebuilding.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER="$SCRIPT_DIR/next-deploy.sh"

IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; export MSYS_NO_PATHCONV=1 ;;
esac

C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
note() { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

[[ -f "$DEPLOYER" ]] || die "next-deploy.sh not found next to this script."

ENVS=()
while IFS= read -r l; do [[ -n "$l" ]] && ENVS+=("$l"); done < <(
  ls -1 "$SCRIPT_DIR"/next-deploy.*.conf 2>/dev/null \
    | sed 's|.*/next-deploy\.||; s|\.conf$||' | sort
)
[[ ${#ENVS[@]} -gt 0 ]] || die "No environments configured. Run: ./next-deploy.sh setup"

conf_value() { sed -n "s/^$2=//p" "$SCRIPT_DIR/next-deploy.$1.conf" 2>/dev/null | head -1 | tr -d "\"'"; }

show_table() {
  printf '\n  %-4s %-24s %-12s %s\n' "#" "ENVIRONMENT" "BRANCH" "ENV FILE"
  printf '  %-4s %-24s %-12s %s\n' "---" "-----------" "------" "--------"
  local i=1 e f
  for e in "${ENVS[@]}"; do
    f=".env.$e"; [[ -f "$SCRIPT_DIR/$f" ]] || f=".env.$e  (will be created)"
    printf '  %-4s %-24s %-12s %s\n' "$i)" "$e" "$(conf_value "$e" GIT_BRANCH)" "$f"
    i=$(( i + 1 ))
  done
  echo
}

# Sets RESOLVED — not via $( ), where `die` would only kill the subshell.
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

# Blocks until the editor is closed — that is the whole point, we must not
# upload a half-typed file. Notepad and nano both behave; a GUI editor that
# forks (code, subl) would return instantly, so those are launched with a wait
# flag where one exists.
open_editor() {
  local f="$1"
  if   [[ -n "${VISUAL:-}" ]]; then "$VISUAL" "$f"
  elif [[ -n "${EDITOR:-}" ]]; then "$EDITOR" "$f"
  elif [[ "$IS_WINDOWS" == "1" ]]; then
    note "opening Notepad — save and close it to continue"
    notepad "$(cygpath -w "$f")" || true
  elif command -v nano >/dev/null 2>&1; then nano "$f"
  elif command -v vi   >/dev/null 2>&1; then vi   "$f"
  else die "No editor found. Set EDITOR=... and try again."
  fi
}

# ---- pick --------------------------------------------------------------------
ARG="${1:-}"
case "$ARG" in
  -h|--help|help) usage; exit 0 ;;
  --list|-l|list) show_table; exit 0 ;;
  --show)
    [[ -n "${2:-}" ]] || die "Usage: ./edit-env.sh --show <environment>"
    resolve_choice "$2"
    f="$SCRIPT_DIR/.env.$RESOLVED"
    [[ -f "$f" ]] || die "$f does not exist yet."
    printf '\n--- %s ---\n' "$f"; cat "$f"; exit 0 ;;
esac

if [[ -z "$ARG" ]]; then
  show_table
  read -r -p "  Which environment's variables? (number or name): " ARG
  [[ -n "$ARG" ]] || die "Nothing chosen."
fi
resolve_choice "$ARG"
ENV_NAME="$RESOLVED"
ENV_PATH="$SCRIPT_DIR/.env.$ENV_NAME"
DOMAIN="$(conf_value "$ENV_NAME" DOMAIN)"

# ---- seed the file if it does not exist yet ----------------------------------
if [[ ! -f "$ENV_PATH" ]]; then
  warn ".env.$ENV_NAME does not exist yet."
  SEED=""
  for c in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../reactjs/my-app/.env" "$SCRIPT_DIR/../reactjs/my-app/.env.example"; do
    [[ -f "$c" ]] && { SEED="$c"; break; }
  done
  if [[ -n "$SEED" ]]; then
    read -r -p "  Start from $(basename "$SEED")? (Y/n): " a
    [[ "$a" =~ ^[Nn] ]] || { cp "$SEED" "$ENV_PATH"; note "copied $SEED"; }
  fi
  [[ -f "$ENV_PATH" ]] || { printf '# %s environment\n' "$ENV_NAME" > "$ENV_PATH"; note "created an empty file"; }
fi

# ---- edit --------------------------------------------------------------------
BEFORE="$(mktemp)"; cp "$ENV_PATH" "$BEFORE"
step "Editing .env.$ENV_NAME   (branch $(conf_value "$ENV_NAME" GIT_BRANCH) -> ${DOMAIN:-ip only})"
open_editor "$ENV_PATH"

if cmp -s "$BEFORE" "$ENV_PATH"; then
  rm -f "$BEFORE"
  ok "No changes — nothing to deploy."
  exit 0
fi

step "What changed"
# diff exits 1 when files differ, which is the normal case here.
diff -u "$BEFORE" "$ENV_PATH" | sed -n '3,$p' | sed 's/^/  /' || true

# Which KEYS were touched — added, removed or edited on either side. This is
# what decides between a restart and a rebuild below.
# `|| true` is load-bearing: diff exits 1 whenever the files differ, which is
# ALWAYS the case here, and under `set -o pipefail` that non-zero status becomes
# the assignment's status and `set -e` then kills the script — silently, right
# after printing the diff. Every grep in the chain can legitimately match
# nothing too, with the same effect.
CHANGED_KEYS="$(
  diff "$BEFORE" "$ENV_PATH" 2>/dev/null \
    | grep -E '^[<>]' \
    | sed -E 's/^[<>][[:space:]]*//; s/^export[[:space:]]+//' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' \
    | cut -d= -f1 | sort -u || true
)"
rm -f "$BEFORE"

# A stray quote or a missing = would otherwise surface as a broken build.
BAD="$(grep -nvE '^[[:space:]]*($|#|(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=)' "$ENV_PATH" || true)"
if [[ -n "$BAD" ]]; then
  warn "These lines are not KEY=value and will be ignored:"
  printf '%s\n' "$BAD" | sed 's/^/      /'
fi
# Only NEXT_PUBLIC_* reach the browser. Everything else stays on the server, so
# unlike a React SPA it is legitimate to keep real secrets in this file.
if grep -qE '^[[:space:]]*NEXT_PUBLIC_.*(SECRET|PASSWORD|PRIVATE|_KEY|TOKEN)' "$ENV_PATH"; then
  warn "A NEXT_PUBLIC_* name looks secret — those are compiled into the browser"
  warn "bundle and readable by anyone. Drop the NEXT_PUBLIC_ prefix to keep it server-side."
fi

# Next.js splits its variables in two, and they need different work to apply:
#   NEXT_PUBLIC_*  compiled into the browser bundle at BUILD time -> rebuild
#   everything else read by the server at RUNTIME               -> restart
# A restart takes seconds; a rebuild takes minutes. Work out which is needed
# rather than always doing the expensive one.
step "Applying to $ENV_NAME"
PUBLIC_CHANGED=0
if [[ -n "$CHANGED_KEYS" ]] && printf '%s\n' "$CHANGED_KEYS" | grep -q '^NEXT_PUBLIC_'; then
  PUBLIC_CHANGED=1
fi

if [[ "$PUBLIC_CHANGED" == "1" ]]; then
  note "NEXT_PUBLIC_* changed:"
  printf '%s\n' "$CHANGED_KEYS" | grep '^NEXT_PUBLIC_' | sed 's/^/      /'
  note "those are compiled into the browser bundle, so this needs a full rebuild"
  DEFAULT_ACTION="rebuild"
else
  note "only server-side variables changed — a restart is enough (seconds, not minutes)"
  DEFAULT_ACTION="restart"
fi

if [[ "$DEFAULT_ACTION" == "rebuild" ]]; then
  read -r -p "  Rebuild and publish $ENV_NAME now? (Y/n): " a
  [[ "$a" =~ ^[Nn] ]] && { warn "Saved locally but NOT applied. Run: ./edit-env.sh $ENV_NAME"; exit 0; }
  "$DEPLOYER" env "$ENV_NAME"
  ok "$ENV_NAME rebuilt with the new variables"
else
  read -r -p "  Restart $ENV_NAME now? (Y/n, or 'b' to rebuild anyway): " a
  case "$a" in
    [Nn]*) warn "Saved locally but NOT applied. Run: ./edit-env.sh $ENV_NAME"; exit 0 ;;
    [Bb]*) "$DEPLOYER" env "$ENV_NAME";            ok "$ENV_NAME rebuilt" ;;
    *)     ENV_MODE=restart "$DEPLOYER" env "$ENV_NAME"; ok "$ENV_NAME restarted with the new environment" ;;
  esac
fi
[[ -n "$DOMAIN" ]] && note "check: https://$DOMAIN"
