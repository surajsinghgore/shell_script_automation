#!/usr/bin/env bash
# ==============================================================================
#  update.sh — you pushed code; bring an environment up to date.
#
#  Before building anything it asks the server what would actually change, and
#  skips environments that are already current — a no-op deploy costs a couple
#  of minutes and leaves a pointless release directory behind.
#
#     ./update.sh              pick from a numbered list
#     ./update.sh 2            pick by number
#     ./update.sh develop      pick by name  -> pulls the develop branch
#     ./update.sh main         pick by name  -> pulls the main branch
#     ./update.sh all          every environment, one after another
#     ./update.sh --check      show what would change, deploy nothing
#     ./update.sh --force dev  deploy even if nothing changed
#     ./update.sh --list       show what is configured, change nothing
#
#  Environments come from the node-deploy.<name>.conf files that
#  ./node-deploy.sh setup created — this script never invents its own.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER="$SCRIPT_DIR/node-deploy.sh"

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1; export MSYS2_ARG_CONV_EXCL='*' ;;
esac

C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
note() { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

usage() { sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

[[ -f "$DEPLOYER" ]] || die "node-deploy.sh not found next to this script ($SCRIPT_DIR)."

# ---- what is configured ------------------------------------------------------
ENVS=()
while IFS= read -r line; do [[ -n "$line" ]] && ENVS+=("$line"); done < <(
  ls -1 "$SCRIPT_DIR"/node-deploy.*.conf 2>/dev/null \
    | sed 's|.*/node-deploy\.||; s|\.conf$||' | sort
)
[[ ${#ENVS[@]} -gt 0 ]] || die "No environments configured yet. Run: ./node-deploy.sh setup"

conf_value() {  # conf_value <env> <KEY>
  sed -n "s/^$2=//p" "$SCRIPT_DIR/node-deploy.$1.conf" 2>/dev/null \
    | head -1 | tr -d "\"'"
}

show_table() {
  printf '\n  %-4s %-24s %-12s %-7s %s\n' "#"   "ENVIRONMENT" "BRANCH" "PORT" "DOMAIN"
  printf '  %-4s %-24s %-12s %-7s %s\n'   "---" "-----------" "------" "----" "------"
  local i=1 e
  for e in "${ENVS[@]}"; do
    printf '  %-4s %-24s %-12s %-7s %s\n' "$i)" "$e" \
      "$(conf_value "$e" GIT_BRANCH)" "$(conf_value "$e" APP_PORT)" "$(conf_value "$e" DOMAIN)"
    i=$(( i + 1 ))
  done
  echo
}

# Sets RESOLVED. Not a command substitution on purpose: `die` inside $( ) would
# only kill the subshell, and the caller would sail on with an empty target.
RESOLVED=""
resolve_choice() {
  local c="$1" e
  if [[ "$c" =~ ^[0-9]+$ ]]; then
    (( c >= 1 && c <= ${#ENVS[@]} )) || die "There is no option $c — pick 1 to ${#ENVS[@]}."
    RESOLVED="${ENVS[$(( c - 1 ))]}"; return 0
  fi
  for e in "${ENVS[@]}"; do
    [[ "$e" == "$c" ]] && { RESOLVED="$e"; return 0; }
  done
  die "No environment called '$c'. Configured: ${ENVS[*]}"
}

# ---- how far behind is this environment? -------------------------------------
# One SSH round trip. Fetches refs only — no checkout, no build, nothing on the
# live site is touched. Sets the CHK_* globals below.
CHK_STATUS="" CHK_FILES=0 CHK_COMMITS=0 CHK_STAT="" CHK_HEAD="" CHK_NEW="" CHK_LIVE="" CHK_LIST=""

check_env() {
  local e="$1" app_dir web_root branch host user pem out
  app_dir="$(conf_value "$e" APP_DIR)";   web_root="$(conf_value "$e" WEB_ROOT)"
  branch="$(conf_value "$e" GIT_BRANCH)"; host="$(conf_value "$e" SERVER_HOST)"
  user="$(conf_value "$e" SSH_USER)";     pem="$(conf_value "$e" PEM_PATH)"

  CHK_STATUS="unknown"; CHK_FILES=0; CHK_COMMITS=0; CHK_STAT=""
  CHK_HEAD=""; CHK_NEW=""; CHK_LIVE=""; CHK_LIST=""

  [[ -n "$pem" && -f "$pem" ]] || { CHK_STATUS="nokey"; return 0; }

  out="$(ssh -i "$pem" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
             -o BatchMode=yes -o LogLevel=ERROR "$user@$host" \
        "APP_DIR=$(printf '%q' "$app_dir") WEB_ROOT=$(printf '%q' "$web_root") BRANCH=$(printf '%q' "$branch") bash -s" <<'REMOTE' 2>/dev/null || true
set -u
if [ ! -d "$APP_DIR/.git" ]; then echo "STATUS=fresh"; exit 0; fi
cd "$APP_DIR" || { echo "STATUS=unknown"; exit 0; }
git fetch origin "$BRANCH" --quiet 2>/dev/null || { echo "STATUS=fetchfail"; exit 0; }

HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
NEW_SHA="$(git rev-parse --short "origin/$BRANCH" 2>/dev/null || echo none)"
LIVE_REL="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"
LIVE_REL="$(basename "${LIVE_REL:-none}")"

echo "HEAD=$HEAD_SHA"
echo "NEW=$NEW_SHA"
echo "LIVE=${LIVE_REL##*-}"

if [ "$HEAD_SHA" = "$NEW_SHA" ]; then
  echo "STATUS=same"
else
  echo "STATUS=behind"
  echo "COMMITS=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)"
  echo "FILES=$(git diff --name-only HEAD "origin/$BRANCH" 2>/dev/null | wc -l | tr -d ' ')"
  echo "STAT=$(git diff --shortstat HEAD "origin/$BRANCH" 2>/dev/null | sed 's/^ *//')"
  git diff --name-status HEAD "origin/$BRANCH" 2>/dev/null | head -12 | sed 's/^/LIST=/'
fi
exit 0
REMOTE
)"

  [[ -z "$out" ]] && { CHK_STATUS="unreachable"; return 0; }
  CHK_STATUS="$( printf '%s\n' "$out" | sed -n 's/^STATUS=//p'  | head -1)"
  CHK_HEAD="$(   printf '%s\n' "$out" | sed -n 's/^HEAD=//p'    | head -1)"
  CHK_NEW="$(    printf '%s\n' "$out" | sed -n 's/^NEW=//p'     | head -1)"
  CHK_LIVE="$(   printf '%s\n' "$out" | sed -n 's/^LIVE=//p'    | head -1)"
  CHK_COMMITS="$(printf '%s\n' "$out" | sed -n 's/^COMMITS=//p' | head -1)"
  CHK_FILES="$(  printf '%s\n' "$out" | sed -n 's/^FILES=//p'   | head -1)"
  CHK_STAT="$(   printf '%s\n' "$out" | sed -n 's/^STAT=//p'    | head -1)"
  CHK_LIST="$(   printf '%s\n' "$out" | sed -n 's/^LIST=//p')"
  [[ -n "$CHK_STATUS" ]] || CHK_STATUS="unknown"
  [[ "$CHK_FILES"   =~ ^[0-9]+$ ]] || CHK_FILES=0
  [[ "$CHK_COMMITS" =~ ^[0-9]+$ ]] || CHK_COMMITS=0
  return 0
}

# Prints the verdict and returns:
#   0 = there are changes, deploy
#   1 = nothing changed — deploying is pointless but harmless, so offer it
#   2 = something is wrong — do not offer, a deploy would just fail too
report_and_decide() {
  local e="$1" pf pc
  case "$CHK_STATUS" in
    fresh)
      note "never deployed — will clone and build"
      return 0 ;;
    nokey)
      warn "$e: the .pem key named in its config is missing — cannot check"
      return 2 ;;
    unreachable|fetchfail|unknown)
      warn "$e: could not reach the server or fetch the branch"
      note "use --force to deploy without this check"
      return 2 ;;
    behind)
      pf="s"; pc="s"
      [[ "$CHK_FILES"   == "1" ]] && pf=""
      [[ "$CHK_COMMITS" == "1" ]] && pc=""
      printf '%s    %s file%s changed in %s commit%s   %s -> %s%s\n' \
        "$C_D" "$CHK_FILES" "$pf" "$CHK_COMMITS" "$pc" "$CHK_HEAD" "$CHK_NEW" "$C_0"
      [[ -n "$CHK_STAT" ]] && note "$CHK_STAT"
      if [[ -n "$CHK_LIST" ]]; then
        printf '%s' "$C_D"
        printf '%s\n' "$CHK_LIST" | sed 's/^/      /'
        [[ "$CHK_FILES" -gt 12 ]] && printf '      … and %s more\n' "$(( CHK_FILES - 12 ))"
        printf '%s' "$C_0"
      fi
      return 0 ;;
    same)
      # HEAD matches the remote, but the LIVE release may be older — which is
      # exactly the state a rollback leaves behind.
      if [[ -n "$CHK_LIVE" && -n "$CHK_HEAD" && "$CHK_LIVE" != "$CHK_HEAD" ]]; then
        warn "$e: code is current ($CHK_HEAD) but the live release is $CHK_LIVE — rolled back?"
        note "deploying will move the site forward to $CHK_HEAD"
        return 0
      fi
      ok "$e is already up to date ($CHK_HEAD) — nothing to deploy"
      return 1 ;;
    *)
      warn "$e: unexpected status '$CHK_STATUS'"
      return 2 ;;
  esac
}

# ---- flags and target --------------------------------------------------------
FORCE=0
CHECK_ONLY=0
ARG="${1:-}"
while :; do
  case "$ARG" in
    --list|-l|list)   show_table; exit 0 ;;
    -h|--help|help)   usage;      exit 0 ;;
    --force|-f)       FORCE=1;      shift || true; ARG="${1:-}" ;;
    --check|-c|check) CHECK_ONLY=1; shift || true; ARG="${1:-}" ;;
    *) break ;;
  esac
done

# --check with no target means "report on everything"
[[ -z "$ARG" && "$CHECK_ONLY" == "1" ]] && ARG="all"

if [[ -z "$ARG" ]]; then
  show_table
  read -r -p "  Which one? (number, name, or 'all'): " ARG
  [[ -n "$ARG" ]] || die "Nothing chosen."
fi

TARGETS=()
if [[ "$ARG" == "all" ]]; then
  TARGETS=("${ENVS[@]}")
else
  resolve_choice "$ARG"
  TARGETS=("$RESOLVED")
fi

# ---- check, then update ------------------------------------------------------
DEPLOYED=() SKIPPED=()
for e in "${TARGETS[@]}"; do
  branch="$(conf_value "$e" GIT_BRANCH)"
  domain="$(conf_value "$e" DOMAIN)"
  step "$e — branch $branch on :$(conf_value "$e" APP_PORT) -> ${domain:-ip only}"

  check_env "$e"
  RC=0; report_and_decide "$e" || RC=$?

  [[ "$CHECK_ONLY" == "1" ]] && continue

  if [[ "$RC" != "0" ]]; then
    if [[ "$FORCE" == "1" ]]; then
      warn "--force: deploying anyway"
    elif [[ "$RC" == "1" && -t 0 ]]; then
      # Nothing changed, but rebuilding is a legitimate thing to want — a build
      # that died halfway, an .env edited by hand, a dependency republished.
      # Ask rather than making them re-run the whole command with --force.
      read -r -p "  Rebuild and republish anyway? (y/N): " a
      if [[ "$a" =~ ^[Yy] ]]; then
        note "rebuilding on request"
      else
        SKIPPED+=("$e"); continue
      fi
    else
      # RC=2 (broken), or no terminal to ask on — skip quietly.
      SKIPPED+=("$e"); continue
    fi
  fi

  printf '\n%s########  deploying %s  ########%s\n' "$C_B" "$e" "$C_0"
  # Stop the chain on failure: pushing a broken build to the next environment
  # too is never what you want.
  "$DEPLOYER" deploy "$e" || die "Failed on '$e'. Any remaining environments were left alone."
  DEPLOYED+=("$e")
done

printf '\n'
if [[ "$CHECK_ONLY" == "1" ]]; then
  ok "Check complete — nothing was deployed."
  exit 0
fi
[[ ${#DEPLOYED[@]} -gt 0 ]] && ok "Deployed: ${DEPLOYED[*]}"
[[ ${#SKIPPED[@]}  -gt 0 ]] && note "Skipped: ${SKIPPED[*]}"
if [[ ${#DEPLOYED[@]} -eq 0 ]]; then
  note "Nothing deployed. Push your commits, then run this again."
else
  note "Bad build live? ./node-deploy.sh rollback <name>"
fi
