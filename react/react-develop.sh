#!/usr/bin/env bash
# ==============================================================================
#  react-develop.sh — Vercel-style one-command deploy for a React (Vite/CRA) SPA.
#
#  Runs FROM YOUR LAPTOP. Talks to the server over SSH using your .pem key.
#  The build happens ON THE SERVER, and nginx serves the built files from disk —
#  no pm2, no Node process, no port. That is how static frontends are served in
#  production. Each deploy lands in its own release dir and a symlink is flipped,
#  so the site is never half-published and `rollback` is instant.
#
#  Usage:
#     ./react-develop.sh setup     # first time: asks everything, installs stack
#     ./react-develop.sh deploy    # every update after that: pull -> build -> publish
#     ./react-develop.sh rollback  # flip back to the previous release (no rebuild)
#     ./react-develop.sh ssl       # issue/renew HTTPS cert for your domain
#     ./react-develop.sh env       # upload local .env, then REBUILD (vite bakes vars in)
#     ./react-develop.sh releases  # list the releases on the server
#     ./react-develop.sh logs      # tail this site's nginx access/error logs
#     ./react-develop.sh status    # live release + nginx health
#     ./react-develop.sh restart   # reload nginx (there is no app process)
#     ./react-develop.sh nginx     # rewrite + reload the nginx server block
#     ./react-develop.sh ssh       # drop into a shell on the server
#     ./react-develop.sh config    # re-run the questions / edit answers
#     ./react-develop.sh allow-ip  # point the SSH security group rule at your current IP
#     ./react-develop.sh harden    # fail2ban, auto security updates, sshd lockdown, swap
#
#  ENVIRONMENTS (production / develop / ...):
#  On the first run setup asks how many you want. Two is the usual industry
#  setup — main/master on the live domain, develop on a staging domain:
#
#     production   main branch      ->  app.example.com
#     develop      develop branch   ->  dev.example.com
#
#  Each gets its own react-develop.<name>.conf, nginx server block, /var/www dir
#  and checkout, so they share the server without touching each other.
#
#     ./react-develop.sh setup                # asks how many, writes each config
#     ./react-develop.sh setup all            # provision every environment
#     ./react-develop.sh deploy develop       # act on one environment
#     ./react-develop.sh deploy all           # act on every environment in turn
#     ./react-develop.sh envs                 # list what is configured
#
#  Answers are cached in ./react-develop*.conf (chmod 600) so you answer once.
#  Those files hold your git token — never commit them.
#
#  A DIFFERENT PROJECT on the same server: give it its own config file.
#     CONFIG_FILE=./portal.conf ./react-develop.sh setup
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# An explicit CONFIG_FILE=... in the environment always wins and disables the
# environment-name resolution below (that is how a second, unrelated project
# shares this script).
CONFIG_FILE_PINNED="${CONFIG_FILE:-}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/react-develop.conf}"

# Multi-environment support: each environment gets react-develop.<name>.conf.
# A single-environment react-develop.conf still works with no name given.
ENV_NAME="${DEPLOY_ENV:-}"

list_envs() {
  ls -1 "$SCRIPT_DIR"/react-develop.*.conf 2>/dev/null \
    | sed 's|.*/react-develop\.||; s|\.conf$||' || true
}

resolve_config() {
  [[ -n "$CONFIG_FILE_PINNED" ]] && return 0
  local envs; envs="$(list_envs)"
  if [[ -n "$ENV_NAME" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/react-develop.$ENV_NAME.conf"
    # setup/config are allowed to create an environment that does not exist yet;
    # every other command needs one that is already configured.
    if [[ ! -f "$CONFIG_FILE" && "${CMD:-}" != "setup" && "${CMD:-}" != "config" ]]; then
      die "No such environment '$ENV_NAME'. Configured: $(echo $envs). Run: ./react-develop.sh setup"
    fi
    return 0
  fi
  # no name given: a lone config wins, otherwise make the user say which
  if [[ -f "$SCRIPT_DIR/react-develop.conf" && -z "$envs" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/react-develop.conf"; return 0
  fi
  local count; count="$(printf '%s\n' "$envs" | grep -c . || true)"
  if [[ "$count" == "1" ]]; then
    ENV_NAME="$envs"; CONFIG_FILE="$SCRIPT_DIR/react-develop.$ENV_NAME.conf"; return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    printf '\n  ! Several environments exist. Name one, or use "all":\n' >&2
    printf '      %s\n' $envs >&2
    printf '      e.g. ./react-develop.sh %s %s\n\n' "${CMD:-deploy}" "$(printf '%s\n' "$envs" | head -1)" >&2
    exit 1
  fi
  CONFIG_FILE="$SCRIPT_DIR/react-develop.conf"
}

# --- Windows / Git Bash compatibility -----------------------------------------
# MSYS rewrites anything that looks like a unix path into a Windows path, which
# would mangle remote paths like /home/ubuntu/apps/... inside our ssh commands.
IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    IS_WINDOWS=1
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac
TTY_WRAP=()
if [[ "$IS_WINDOWS" == "1" ]] && command -v winpty >/dev/null 2>&1; then TTY_WRAP=(winpty); fi

# ------------------------------- pretty output --------------------------------
C_B=$'\033[36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
note() { printf '%s    %s%s\n' "$C_D" "$*" "$C_0"; }

# ------------------------------- config defaults ------------------------------
PEM_PATH=""          # /path/to/key.pem
SERVER_HOST=""       # EC2 public IP or DNS
SSH_USER="ubuntu"    # ubuntu (Ubuntu AMI) / ec2-user (Amazon Linux) / root
NODE_MAJOR="22"
REPO_URL=""          # https://github.com/user/repo.git
REPO_PRIVATE="y"
GIT_USER=""          # github username (only needed for private repos)
GIT_TOKEN=""         # github personal access token (repo:read scope)
GIT_BRANCH="develop"
APP_NAME="stepu"
APP_DIR=""           # /home/ubuntu/apps/<APP_NAME>  — the git checkout
WEB_ROOT=""          # /var/www/<APP_NAME>           — releases + current symlink
INSTALL_CMD="npm ci || npm install"   # NO --omit=dev: vite/tsc are devDependencies
BUILD_CMD="npm run build"
STATIC_DIR=""        # build output dir; blank = auto-detect dist/ build/ out/
ENV_FILE=""          # local path to your production env file (blank = auto-detect)
DOMAIN=""            # example.com   (blank = access by IP only)
WWW_ALIAS="y"
SSL_EMAIL=""
API_PROXY_PORT=""    # blank = none. Set to e.g. 5000 to proxy /api/ to a backend
SETUP_FIREWALL="y"
SG_ID=""             # sg-0abc123... (for ./react-develop.sh allow-ip)
AWS_REGION=""        # ap-south-1, us-east-1, ...
KEEP_RELEASES="5"    # how many old builds to keep on disk for rollback
ENV_LABEL=""         # production, develop, ... (blank for single-env setups)

CONFIG_KEYS=(PEM_PATH SERVER_HOST SSH_USER NODE_MAJOR REPO_URL REPO_PRIVATE GIT_USER
             GIT_TOKEN GIT_BRANCH APP_NAME APP_DIR WEB_ROOT INSTALL_CMD BUILD_CMD
             STATIC_DIR ENV_FILE DOMAIN WWW_ALIAS SSL_EMAIL API_PROXY_PORT
             SETUP_FIREWALL SG_ID AWS_REGION KEEP_RELEASES ENV_LABEL)

load_config() { [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true; }

save_config() {
  : > "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
  {
    echo "# react-develop.sh config — contains a git token. NEVER commit this file."
    for k in "${CONFIG_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done
  } >> "$CONFIG_FILE"
  ok "Saved answers to $CONFIG_FILE (chmod 600)"
  # Only add a rule if the config is not already ignored — a blanket "*.conf"
  # covers every per-project config, so don't pile up redundant lines.
  if [[ -d "$SCRIPT_DIR/.git" ]] && ! git -C "$SCRIPT_DIR" check-ignore -q "$CONFIG_FILE" 2>/dev/null; then
    echo "$(basename "$CONFIG_FILE")" >> "$SCRIPT_DIR/.gitignore"
    note "added $(basename "$CONFIG_FILE") to .gitignore"
  fi
}

ask() {  # ask VAR "Question" ["default"]
  local var="$1" prompt="$2" def="${3:-}" cur ans
  cur="${!var:-}"; [[ -n "$cur" ]] && def="$cur"
  if [[ -n "$def" ]]; then read -r -e -p "  $prompt [$def]: " ans; else read -r -e -p "  $prompt: " ans; fi
  ans="${ans:-$def}"
  # Enter keeps the saved value, so "-" is the only way to clear one back to
  # empty — without it a wrong answer like API_PROXY_PORT=y can never be undone.
  [[ "$ans" == "-" ]] && ans=""
  printf -v "$var" '%s' "$ans"
}

# ---- input cleaners: accept what people actually paste ------------------------

# https://host/path, host/, HOST  ->  host      ("" means no domain)
normalize_domain() {
  local d="$1"
  d="${d#http://}"; d="${d#https://}"   # scheme
  d="${d%%/*}"                          # any path
  d="${d%%:*}"                          # any port
  d="${d,,}"                            # lowercase
  printf '%s' "$d"
}

# Hostnames allow letters, digits, hyphens and dots. NOT underscores — DNS will
# never resolve develop_site.example.com, which is why this is enforced here.
valid_domain() {
  local d="$1"
  [[ -z "$d" ]] && return 0
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

ask_domain() {  # ask_domain VAR "Question"
  local var="$1" prompt="$2" clean
  while :; do
    ask "$var" "$prompt"
    clean="$(normalize_domain "${!var}")"
    if [[ "$clean" != "${!var}" ]]; then
      note "using '$clean'"
      printf -v "$var" '%s' "$clean"
    fi
    valid_domain "${!var}" && break
    warn "'${!var}' is not a valid hostname — letters, digits, hyphens and dots only (no underscores)."
    printf -v "$var" '%s' ""
  done
}

ask_port() {  # ask_port VAR "Question"
  local var="$1" prompt="$2"
  while :; do
    ask "$var" "$prompt"
    [[ -z "${!var}" ]] && break
    [[ "${!var}" =~ ^[0-9]+$ ]] && (( ${!var} >= 1 && ${!var} <= 65535 )) && break
    warn "That is not a port. Enter a number like 5000, or '-' for none."
    printf -v "$var" '%s' ""
  done
}

ask_env_file() {  # ask_env_file "Question"
  ask ENV_FILE "$1"
  [[ -z "$ENV_FILE" ]] && return 0
  ENV_FILE="${ENV_FILE/#\~/$HOME}"
  # A path pasted from Explorer (C:\Users\...) is meaningless to Git Bash.
  if [[ "$IS_WINDOWS" == "1" && "$ENV_FILE" =~ ^[A-Za-z]:[\\/] ]]; then
    ENV_FILE="$(cygpath -u "$ENV_FILE" 2>/dev/null || printf '%s' "$ENV_FILE")"
    note "converted to $ENV_FILE"
  fi
  # A folder was given instead of a file — take the .env inside it if there is one.
  if [[ -d "$ENV_FILE" ]]; then
    if [[ -f "$ENV_FILE/.env" ]]; then
      ENV_FILE="$ENV_FILE/.env"; note "that is a folder — using $ENV_FILE"
    else
      warn "$ENV_FILE is a folder and has no .env inside — leaving blank (auto-detect)."
      ENV_FILE=""; return 0
    fi
  fi
  [[ -f "$ENV_FILE" ]] || warn "$ENV_FILE does not exist yet — nothing will be uploaded unless you create it."
}

ask_secret() {  # ask_secret VAR "Question"
  local var="$1" prompt="$2"
  local ans cur
  cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    read -r -p "  $prompt [keep existing, press Enter]: " -s ans; echo
    [[ -n "$ans" ]] && printf -v "$var" '%s' "$ans"
    return 0
  fi
  read -r -p "  $prompt: " -s ans; echo
  printf -v "$var" '%s' "$ans"
}

ask_required() {  # like ask, but will not accept an empty answer
  local var="$1" prompt="$2" def="${3:-}"
  while :; do
    ask "$var" "$prompt" "$def"
    [[ -n "${!var:-}" ]] && break
    warn "This one can't be empty."
  done
}

# --------------------- repo access / branch verification ----------------------
# Asks the git host what branches actually exist, using your token, so a typo or
# an expired token is caught HERE — not after provisioning a server and running
# a five-minute npm install.

# Read-only, never persisted, never printed: the token would be in the string.
auth_repo_url() {
  if [[ -n "$GIT_TOKEN" && "$REPO_URL" == https://* ]]; then
    printf '%s' "https://${GIT_USER}:${GIT_TOKEN}@${REPO_URL#https://}"
  else
    printf '%s' "$REPO_URL"
  fi
}

# Branch names, one per line. Empty output means the repo could not be read.
# stderr is discarded on purpose — git echoes the URL (with the token) on error.
fetch_remote_branches() {
  GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$(auth_repo_url)" 2>/dev/null \
    | sed 's|^[0-9a-f]*[[:space:]]*refs/heads/||'
}

# verify_repo_and_branch [strict]
#   default — offers to re-enter the branch (used from the wizard)
#   strict  — fails outright (used from deploy, where prompting would stall a
#             `deploy all` run halfway through)
verify_repo_and_branch() {
  local mode="${1:-}" branches count
  command -v git >/dev/null 2>&1 || { warn "git not installed locally — skipping branch check"; return 0; }
  [[ -n "$REPO_URL" ]] || return 0

  step "Verifying repo access and branch '$GIT_BRANCH'"
  branches="$(fetch_remote_branches)"

  if [[ -z "$branches" ]]; then
    warn "Could not read $REPO_URL"
    note "check: URL correct? token expired? token missing Contents:Read on this repo?"
    note "a private repo with no token will also land here"
    if [[ "$mode" == "strict" ]]; then
      die "Stopped before touching the server. Fix with: ./react-develop.sh config"
    fi
    read -r -p "  Continue anyway? (y/N): " a
    [[ "$a" =~ ^[Yy] ]] || die "Stopped. Run ./react-develop.sh config to fix the repo URL or token."
    return 0
  fi

  count="$(printf '%s\n' "$branches" | grep -c . || true)"
  ok "Repo reachable — $count branch(es) found"

  while ! printf '%s\n' "$branches" | grep -qxF -- "$GIT_BRANCH"; do
    warn "Branch '$GIT_BRANCH' does NOT exist in this repo."
    printf '    available: %s\n' "$(printf '%s\n' "$branches" | head -25 | paste -sd' ' -)"
    [[ "$count" -gt 25 ]] && note "(showing first 25 of $count)"
    if [[ "$mode" == "strict" ]]; then
      die "Nothing was deployed. Fix the branch with: ./react-develop.sh config"
    fi
    # Offer a branch that actually exists. Re-offering the rejected value would
    # mean pressing Enter resubmits it, looping forever with no way out.
    local suggest
    if printf '%s\n' "$branches" | grep -qxF -- "main"; then       suggest="main"
    elif printf '%s\n' "$branches" | grep -qxF -- "master"; then    suggest="master"
    else suggest="$(printf '%s\n' "$branches" | head -1)"; fi
    GIT_BRANCH="$suggest"
    ask GIT_BRANCH "Branch to deploy"
    [[ -n "$GIT_BRANCH" ]] || GIT_BRANCH="$suggest"
  done
  ok "Branch '$GIT_BRANCH' exists"
}

# ------------------------------- ssh plumbing ---------------------------------
init_ssh() {
  [[ -n "$PEM_PATH" && -f "$PEM_PATH" ]] || die "PEM key not found: '$PEM_PATH'. Run: ./react-develop.sh config"
  chmod 600 "$PEM_PATH" 2>/dev/null || true
  if [[ "$IS_WINDOWS" == "1" ]]; then
    local winpem winuser
    winpem="$(cygpath -w "$PEM_PATH" 2>/dev/null || true)"
    winuser="${USERNAME:-$(whoami 2>/dev/null || true)}"
    if [[ -n "$winpem" && -n "$winuser" ]] && command -v icacls >/dev/null 2>&1; then
      icacls "$winpem" /inheritance:r /grant:r "${winuser}:(R)" >/dev/null 2>&1 \
        && note "locked down key permissions via icacls"
    fi
  fi
  SSH_OPTS=(-i "$PEM_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20
            -o ServerAliveInterval=30 -o LogLevel=ERROR)
}

# Runs a script (from stdin) on the server with our config exported as env vars.
remote() {
  local envs=""
  for k in APP_NAME APP_DIR WEB_ROOT NODE_MAJOR REPO_URL GIT_BRANCH GIT_USER GIT_TOKEN \
           INSTALL_CMD BUILD_CMD STATIC_DIR DOMAIN WWW_ALIAS SSL_EMAIL SSH_USER \
           API_PROXY_PORT SETUP_FIREWALL KEEP_RELEASES; do
    envs+="$k=$(printf '%q' "${!k}") "
  done
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_HOST" "$envs bash -s" || return $?
}

remote_tty() { ${TTY_WRAP[@]+"${TTY_WRAP[@]}"} ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_HOST" "$@"; }

# ------------------------------- the wizard -----------------------------------
wizard() {
  cat <<'BANNER'

  ┌──────────────────────────────────────────────┐
  │   React SPA  ->  VPS   deployment setup      │
  └──────────────────────────────────────────────┘
BANNER

  step "1/6  Server access"
  if [[ -z "$PEM_PATH" ]]; then
    local found_pem
    found_pem="$(ls -1 "$SCRIPT_DIR"/*.pem 2>/dev/null | head -1 || true)"
    if [[ -n "$found_pem" ]]; then
      PEM_PATH="$found_pem"
      note "found key: $(basename "$found_pem")"
    fi
  fi
  ask_required PEM_PATH    "Path to your .pem key"
  PEM_PATH="${PEM_PATH/#\~/$HOME}"
  ask_required SERVER_HOST "Server public IP or DNS"
  ask SSH_USER    "SSH user (ubuntu | ec2-user | root)"

  step "2/6  Git repository"
  ask_required REPO_URL "Repo HTTPS URL (https://github.com/you/repo.git)"
  ask REPO_PRIVATE "Is the repo private? (y/n)"
  if [[ "$REPO_PRIVATE" =~ ^[Yy] ]]; then
    ask GIT_USER   "GitHub username"
    ask_secret GIT_TOKEN "GitHub token (PAT with 'repo' / Contents:Read)"
    [[ -n "$GIT_TOKEN" ]] || die "A token is required for a private repo."
  else
    GIT_USER=""; GIT_TOKEN=""
  fi
  ask GIT_BRANCH  "Branch to deploy"
  verify_repo_and_branch          # catches a bad URL, dead token or typo'd branch now

  step "3/6  React app"
  local guess; guess="$(basename -s .git "${REPO_URL:-app}")"
  [[ "$APP_NAME" == "stepu" && -n "$guess" ]] && APP_NAME="$guess"
  ask APP_NAME    "Site name (used for /var/www/<name> and the nginx config)"
  ask NODE_MAJOR  "Node.js major version (for the build)"
  ask INSTALL_CMD "Install command (must include devDependencies)"
  ask BUILD_CMD   "Build command"
  ask STATIC_DIR  "Build output dir (blank = auto-detect dist / build / out)"
  ask_env_file    "Local env file to upload (blank = auto-detect .env.${ENV_LABEL:-production} / .env)"
  APP_DIR="/home/$SSH_USER/apps/$APP_NAME"
  [[ "$SSH_USER" == "root" ]] && APP_DIR="/root/apps/$APP_NAME"
  WEB_ROOT="/var/www/$APP_NAME"
  note "Source checkout: $APP_DIR"
  note "Served from:     $WEB_ROOT/current"

  step "4/6  Nginx + domain"
  ask_domain DOMAIN "Domain, e.g. app.example.com ('-' = serve on IP only)"
  if [[ -n "$DOMAIN" ]]; then
    # www. only makes sense on an apex domain; on a subdomain certbot would be
    # asked for a www.<subdomain> cert that has no DNS record and fail.
    if [[ "$(printf '%s' "$DOMAIN" | tr -cd . | wc -c)" -gt 1 ]]; then
      WWW_ALIAS="n"
      note "$DOMAIN is a subdomain — skipping the www alias"
    else
      ask WWW_ALIAS "Also serve www.$DOMAIN? (y/n)"
    fi
  fi
  ask_port API_PROXY_PORT "Proxy /api/ to a backend port on this server ('-' = no)"

  step "5/6  HTTPS"
  if [[ -n "$DOMAIN" ]]; then
    ask SSL_EMAIL "Email for Let's Encrypt (blank = skip HTTPS for now)"
  else
    note "no domain -> skipping HTTPS"
  fi

  step "6/6  Firewall"
  ask SETUP_FIREWALL "Enable UFW firewall (22/80/443 only)? (y/n)"
  ask SG_ID       "AWS security group id for SSH allowlist (blank = skip 'allow-ip')"
  [[ -n "$SG_ID" ]] && ask AWS_REGION "AWS region (e.g. us-east-1)"

  save_config
}

# ---------------------- multi-environment wizard ------------------------------
# Any number of environments. The first few get the names teams normally use;
# past that they fall back to env5, env6, ... Server, key, repo and token are
# asked ONCE for environment 1 and inherited by the rest — only what genuinely
# differs (name, branch, domain) is asked again.
ENV_DEFAULT_LABELS=(production develop staging qa uat demo preview)

env_default_label() {  # env_default_label <1-based index>
  local i="$1"
  if (( i <= ${#ENV_DEFAULT_LABELS[@]} )); then
    printf '%s' "${ENV_DEFAULT_LABELS[$((i - 1))]}"
  else
    printf 'env%s' "$i"
  fi
}

env_default_branch() {  # the branch that conventionally goes with a name
  case "$1" in
    production|prod|live|main) printf 'main' ;;
    *)                         printf '%s' "$1" ;;
  esac
}

# The offered default must never be a name already taken, or pressing Enter
# would be rejected and re-offer the same rejected value forever.
env_free_label() {  # env_free_label <index> <space-separated used names>
  local i="$1" used=" $2 " cand n
  cand="$(env_default_label "$i")"
  [[ "$used" != *" $cand "* ]] && { printf '%s' "$cand"; return 0; }
  for cand in "${ENV_DEFAULT_LABELS[@]}"; do
    [[ "$used" != *" $cand "* ]] && { printf '%s' "$cand"; return 0; }
  done
  n="$i"
  while [[ "$used" == *" env$n "* ]]; do n=$(( n + 1 )); done
  printf 'env%s' "$n"
}

multi_env_wizard() {
  local count="$1" i base_name used="" def_label
  for (( i=1; i<=count; i++ )); do
    printf '\n%s========  Environment %s of %s  ========%s\n' "$C_B" "$i" "$count" "$C_0"

    # Each environment MUST get a distinct name: it is the config filename, so a
    # repeat would silently overwrite the environment configured a moment ago.
    def_label="$(env_free_label "$i" "$used")"
    ENV_LABEL="$def_label"
    while :; do
      ask ENV_LABEL "Name for this environment"
      ENV_LABEL="$(printf '%s' "$ENV_LABEL" | tr -cd 'a-zA-Z0-9._-')"
      if [[ -z "$ENV_LABEL" ]]; then
        warn "Name can't be empty."; ENV_LABEL="$def_label"; continue
      fi
      if [[ " $used " == *" $ENV_LABEL "* ]]; then
        warn "'$ENV_LABEL' is already taken by an earlier environment — pick another."
        ENV_LABEL="$def_label"; continue
      fi
      break
    done
    used="$used $ENV_LABEL"
    GIT_BRANCH="$(env_default_branch "$ENV_LABEL")"

    if (( i == 1 )); then
      CONFIG_FILE="$SCRIPT_DIR/react-develop.$ENV_LABEL.conf"
      wizard                                   # full question set, saves itself
      base_name="$(basename -s .git "$REPO_URL")"
    else
      # everything not asked here is inherited from environment 1
      ask GIT_BRANCH  "Branch to deploy for $ENV_LABEL"
      verify_repo_and_branch      # repo/token already proven by env 1; check the branch
      APP_NAME="${base_name}-${ENV_LABEL}"
      ask APP_NAME    "Site name for $ENV_LABEL (must differ from the others)"
      APP_DIR="/home/$SSH_USER/apps/$APP_NAME"
      [[ "$SSH_USER" == "root" ]] && APP_DIR="/root/apps/$APP_NAME"
      WEB_ROOT="/var/www/$APP_NAME"
      DOMAIN=""
      ask_domain DOMAIN "Domain for $ENV_LABEL, e.g. dev.example.com"
      WWW_ALIAS="n"
      if [[ -n "$DOMAIN" && "$(printf '%s' "$DOMAIN" | tr -cd . | wc -c)" -le 1 ]]; then
        ask WWW_ALIAS "Also serve www.$DOMAIN? (y/n)"
      fi
      API_PROXY_PORT=""
      ask_port API_PROXY_PORT "Proxy /api/ to a backend port for $ENV_LABEL ('-' = no)"
      ENV_FILE=""
      ask_env_file    "Local env file for $ENV_LABEL (blank = auto-detect .env.$ENV_LABEL)"
      note "$ENV_LABEL: branch '$GIT_BRANCH' -> $WEB_ROOT/current"
      CONFIG_FILE="$SCRIPT_DIR/react-develop.$ENV_LABEL.conf"
      save_config
    fi
  done

  printf '\n'
  ok "Created $count environment configs"
  cmd_envs
  cat <<EOF
  Now provision them on the server:

     ${C_B}./react-develop.sh setup all${C_0}          (or: setup <name>, one at a time)

  After that, day to day:

     ${C_B}./react-develop.sh deploy develop${C_0}
     ${C_B}./react-develop.sh deploy production${C_0}

EOF
}

# ------------------------------- preflight ------------------------------------
preflight() {
  step "Checking connection to $SSH_USER@$SERVER_HOST"
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$SSH_USER@$SERVER_HOST" 'echo connected' >/dev/null 2>&1 \
    || die "SSH failed. Check: key path, security group allows port 22 from your IP, correct user ($SSH_USER)."
  ok "SSH works"
  remote <<'REMOTE' || die "Passwordless sudo is not available for $SSH_USER."
sudo -n true 2>/dev/null
REMOTE
  ok "sudo works"
}

# ------------------------------- provision ------------------------------------
# No pm2 here: a React build is static files. Node is installed only to run the
# build, nginx is what actually serves the site.
provision() {
  step "Checking system stack (node $NODE_MAJOR, nginx, certbot, git)"
  remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Everything below is check-first: nothing is installed, and apt is not even
# refreshed, unless something is genuinely missing. Re-running this on a server
# that already hosts another site is a fast no-op instead of a re-install.
APT_REFRESHED=0
apt_refresh_once() {
  [ "$APT_REFRESHED" = "1" ] && return 0
  echo "--- refreshing apt package lists"
  sudo apt-get update -y -qq
  APT_REFRESHED=1
}

# ---------- base packages ----------
MISSING=""
for p in curl git ca-certificates gnupg build-essential ufw; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
  apt_refresh_once
  echo "--- installing missing packages:$MISSING"
  sudo apt-get install -y -qq $MISSING
else
  echo "[present] curl git ca-certificates gnupg build-essential ufw"
fi

# ---------- node ----------
# Reinstall only on a MAJOR version mismatch; a newer patch/minor is fine.
if command -v node >/dev/null 2>&1 && [ "$(node -v | cut -d. -f1)" = "v${NODE_MAJOR}" ]; then
  echo "[present] node $(node -v) / npm $(npm -v)"
else
  if command -v node >/dev/null 2>&1; then
    echo "--- node $(node -v) found but major version ${NODE_MAJOR} wanted"
    echo "    WARNING: other apps on this server share this node. Upgrading affects them too."
  fi
  apt_refresh_once
  echo "--- installing Node.js ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs
  echo "node $(node -v) / npm $(npm -v)"
fi

# ---------- nginx ----------
if command -v nginx >/dev/null 2>&1; then
  echo "[present] $(nginx -v 2>&1)"
  systemctl is-active --quiet nginx || { echo "--- nginx installed but stopped; starting"; sudo systemctl enable --now nginx; }
else
  apt_refresh_once
  echo "--- installing nginx"
  sudo apt-get install -y -qq nginx
  sudo systemctl enable --now nginx
fi

# ---------- certbot ----------
if command -v certbot >/dev/null 2>&1; then
  echo "[present] $(certbot --version 2>&1)"
else
  apt_refresh_once
  echo "--- installing certbot"
  sudo apt-get install -y -qq certbot python3-certbot-nginx
fi

# ---------- firewall ----------
case "${SETUP_FIREWALL:-n}" in
  [Yy]*)
    if sudo ufw status 2>/dev/null | grep -q '^Status: active' \
       && sudo ufw status | grep -q 'Nginx Full'; then
      echo "[present] ufw active, 22/80/443 already allowed"
    else
      echo "--- configuring firewall"
      sudo ufw allow OpenSSH >/dev/null
      sudo ufw allow 'Nginx Full' >/dev/null
      sudo ufw --force enable >/dev/null
    fi
    ;;
esac

# ---------- this site's directories ----------
mkdir -p "$(dirname "$APP_DIR")"
sudo mkdir -p "$WEB_ROOT/releases"

# ---------- warn about clashes with sites already on this box ----------
# Each site gets its own nginx server block, /var/www dir and checkout, so many
# projects coexist happily — but two sites answering to the same name do not.
if [ -n "${DOMAIN:-}" ]; then
  CLASH="$(grep -rlE "^[[:space:]]*server_name[[:space:]].*[[:space:]]${DOMAIN}([[:space:]]|;)" \
           /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "/${APP_NAME}\$" || true)"
  if [ -n "$CLASH" ]; then
    echo "WARNING: $DOMAIN is already claimed by: $CLASH"
  fi
fi

# The remote script's exit status is this block's status. A trailing test that
# happens to be false would fail the whole deploy, so end deliberately on 0.
exit 0
REMOTE
  ok "Server stack ready"
}

# ------------------------------- git credentials ------------------------------
configure_git() {
  [[ -z "$GIT_TOKEN" ]] && return 0
  step "Storing git credentials on server (for private repo pulls)"
  remote <<'REMOTE'
set -euo pipefail
host=$(echo "$REPO_URL" | sed -E 's#https?://([^/]+)/.*#\1#')
git config --global credential.helper store
git config --global --add safe.directory "$APP_DIR"
umask 077
printf 'https://%s:%s@%s\n' "$GIT_USER" "$GIT_TOKEN" "$host" > "$HOME/.git-credentials"
chmod 600 "$HOME/.git-credentials"
REMOTE
  ok "Credentials stored at ~/.git-credentials (chmod 600)"
}

# ------------------------------- deploy (the loop) ----------------------------
# fetch -> install -> build -> publish a new release -> flip the symlink.
deploy_app() {
  step "Deploying $APP_NAME ($GIT_BRANCH) -> $WEB_ROOT/current"
  remote <<'REMOTE'
set -euo pipefail

# ---------- 1. source code ----------------------------------------------------
# The .env we uploaded has to survive the git step. Plenty of repos TRACK a
# .env, and `git reset --hard` silently reverts it to the committed version —
# which is how a deploy ends up built with the wrong URLs and no error anywhere.
ENV_BAK=""
if [ -f "$APP_DIR/.env" ]; then ENV_BAK="$(mktemp)"; cp "$APP_DIR/.env" "$ENV_BAK"; fi

if [ -d "$APP_DIR/.git" ]; then
  echo "--- pulling latest"
  cd "$APP_DIR"
  git remote set-url origin "$REPO_URL"
  git fetch --all --prune
  # -f because a tracked .env we overwrote would otherwise block the checkout;
  # it is backed up above and restored below.
  git checkout -f "$GIT_BRANCH"
  git reset --hard "origin/$GIT_BRANCH"
else
  echo "--- cloning"
  rm -rf "$APP_DIR"
  git clone --branch "$GIT_BRANCH" "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

if [ -n "$ENV_BAK" ]; then
  if ! cmp -s "$ENV_BAK" "$APP_DIR/.env" 2>/dev/null; then
    cp "$ENV_BAK" "$APP_DIR/.env"
    echo "--- restored the uploaded .env (the repo ships its own, which git had put back)"
  fi
  chmod 600 "$APP_DIR/.env"
  rm -f "$ENV_BAK"
fi
SHA="$(git rev-parse --short HEAD)"
echo "commit: $(git log -1 --pretty='%h %s')"

# ---------- 2. dependencies ---------------------------------------------------
# Full install on purpose. vite / tsc / the react plugin live in devDependencies,
# so "--omit=dev" would make the build fail with "vite: not found".
echo "--- installing dependencies"
eval "$INSTALL_CMD"

# ---------- 3. build ----------------------------------------------------------
# Vite inlines VITE_* variables into the bundle AT BUILD TIME, so .env has to be
# in the environment here — after the build it is irrelevant.
#
# Parsed line by line, NOT sourced. A dotenv file legally holds unquoted values
# with spaces and shell metacharacters:
#     VITE_APP_NAME=Suraj Singh Weather
#     VITE_APP_TAGLINE=7-day & hourly forecasts
# `. .env` would run "Singh" as a command and background on the "&". Vite's own
# parser accepts all of it, so the deploy must too.
load_env_file() {
  local file="$1" line key val n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                       # tolerate CRLF files
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#export }"
    key="${key//[[:space:]]/}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$val" in                             # drop matching surrounding quotes
      '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
      "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
    n=$((n + 1))
  done < "$file"
  echo "    loaded $n variables"
}

if [ -f "$APP_DIR/.env" ]; then
  echo "--- loading .env into build environment"
  load_env_file "$APP_DIR/.env"
else
  echo "--- no .env on server (build runs without it)"
fi

# Bundlers are memory hungry. On a 1 GB instance "tsc -b && vite build" gets
# OOM-killed, which surfaces only as a silent "Killed".
TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m  | awk '/^Swap:/{print $2}')
FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')

# Stop before filling the disk — running out mid-build leaves a half-written
# tree and a full volume, which takes every other site on the box down too.
if [ "$FREE_MB" -lt 400 ]; then
  echo "ERROR: only ${FREE_MB}MB free on / — not enough to build safely. Nothing changed."
  echo "       sudo du -sh /home/*/apps/* /var/www/* | sort -rh | head"
  exit 1
fi

# Only add swap if the disk can spare it, and never touch swap that already
# works: losing it is worse than not upgrading it.
if [ "$TOTAL_MB" -lt 2048 ] && [ "$SWAP_MB" -lt 512 ] && [ "$FREE_MB" -gt 2600 ]; then
  echo "--- only ${TOTAL_MB}MB RAM and no swap; adding a 2G swapfile for the build"
  if sudo fallocate -l 2G /swapfile 2>/dev/null; then
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    sudo sysctl -w vm.swappiness=10 >/dev/null
  else
    sudo rm -f /swapfile
    echo "    could not allocate it — continuing without extra swap"
  fi
fi
if [ "$TOTAL_MB" -lt 2048 ]; then
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1536}"
  echo "--- NODE_OPTIONS=$NODE_OPTIONS"
fi

echo "--- building: $BUILD_CMD"
NODE_ENV=production eval "$BUILD_CMD"

# ---------- 4. locate the build output ----------------------------------------
SRC=""
for d in "${STATIC_DIR:-}" dist build out; do
  [ -n "$d" ] && [ -d "$APP_DIR/$d" ] && { SRC="$APP_DIR/$d"; break; }
done
[ -n "$SRC" ] || { echo "ERROR: no build output found (looked for '${STATIC_DIR:-}', dist/, build/, out/)"; exit 1; }
[ -f "$SRC/index.html" ] || { echo "ERROR: $SRC has no index.html — that is not a built SPA"; exit 1; }

# ---------- 5. publish atomically ---------------------------------------------
# Copy into a fresh release dir, then swap the "current" symlink in one atomic
# rename. Visitors are never served a half-copied directory, and the previous
# release stays on disk so "rollback" needs no rebuild.
REL="$(date -u +%Y%m%d-%H%M%S)-$SHA"
NEW="$WEB_ROOT/releases/$REL"
echo "--- publishing $(basename "$SRC")/ -> $NEW"
sudo mkdir -p "$NEW"
sudo cp -a "$SRC/." "$NEW/"
sudo chown -R www-data:www-data "$NEW"
sudo chmod -R a+rX "$NEW"

sudo ln -sfn "$NEW" "$WEB_ROOT/.current.tmp"
sudo mv -Tf "$WEB_ROOT/.current.tmp" "$WEB_ROOT/current"
echo "live release: $REL ($(sudo find "$NEW" -type f | wc -l) files)"
# the "deploying…" stand-in from the first nginx setup is dead weight now
sudo rm -rf "$WEB_ROOT/releases/placeholder"

# ---------- 6. prune old releases ---------------------------------------------
# Ordered by NAME, not mtime: release dirs are named <timestamp>-<sha> so a
# reverse name sort is newest-first, and unlike `ls -t` it cannot be thrown off
# by `cp -a` preserving the source tree's timestamps on the new directory.
KEEP="${KEEP_RELEASES:-5}"
CUR="$(readlink -f "$WEB_ROOT/current")"
cd "$WEB_ROOT/releases"
ls -1d */ 2>/dev/null | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
  old="${old%/}"
  [ "$(readlink -f "$old")" = "$CUR" ] && continue
  echo "--- pruning old release $old"
  sudo rm -rf "$WEB_ROOT/releases/$old"
done

# Pruning is housekeeping — the site is already live at this point. Never let a
# non-zero status from it report the deploy as failed.
exit 0
REMOTE
  ok "Deploy finished"
}

# ------------------------------- nginx ----------------------------------------
configure_nginx() {
  step "Configuring nginx to serve $WEB_ROOT/current"
  remote <<'REMOTE'
set -euo pipefail
SERVER_NAMES="_"
ZONE="$(printf '%s' "$APP_NAME" | tr -c 'a-zA-Z0-9' '_' | cut -c1-24)"
if [ -n "$DOMAIN" ]; then
  SERVER_NAMES="$DOMAIN"
  case "$WWW_ALIAS" in [Yy]*) SERVER_NAMES="$DOMAIN www.$DOMAIN";; esac
fi

# Optional: let the SPA and a backend API share one domain, so the browser makes
# same-origin calls and there is no CORS to configure.
# Written with a quoted heredoc so nginx's own $variables survive verbatim; the
# port is substituted afterwards. It is then interpolated into the server block
# below, where no further backslash processing happens.
API_BLOCK=""
if [ -n "${API_PROXY_PORT:-}" ]; then
  API_BLOCK=$(cat <<'EOB'
    location /api/ {
        proxy_pass         http://127.0.0.1:__API_PORT__;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
EOB
)
  API_BLOCK="${API_BLOCK//__API_PORT__/$API_PROXY_PORT}"
fi

sudo mkdir -p "$WEB_ROOT/releases"
# First run: nginx must not fail its config test because "current" is missing.
if [ ! -e "$WEB_ROOT/current" ]; then
  sudo mkdir -p "$WEB_ROOT/releases/placeholder"
  echo '<!doctype html><title>deploying…</title>' | sudo tee "$WEB_ROOT/releases/placeholder/index.html" >/dev/null
  sudo ln -sfn "$WEB_ROOT/releases/placeholder" "$WEB_ROOT/current"
fi

sudo tee "/etc/nginx/sites-available/$APP_NAME" >/dev/null <<EOS
limit_req_zone \$binary_remote_addr zone=${ZONE}_rl:10m rate=30r/s;

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAMES;

    root $WEB_ROOT/current;
    index index.html;

    server_tokens off;
    client_max_body_size 5M;

    access_log /var/log/nginx/$APP_NAME.access.log;
    error_log  /var/log/nginx/$APP_NAME.error.log;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location ~ /\.(?!well-known) { deny all; }

$API_BLOCK

    # Hashed bundles: content-addressed, so cache them forever. Exempt from the
    # rate limit — one page load pulls dozens of them.
    location ~* \.(js|css|woff2?|ttf|eot|png|jpg|jpeg|gif|svg|ico|webp|avif|map)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files \$uri =404;
    }

    # index.html must never be cached, or users keep running the old bundle
    # after a deploy because their browser never re-fetches the new asset names.
    location = /index.html {
        add_header Cache-Control "no-cache, must-revalidate";
    }

    # Client-side routing: /dashboard, /city/paris etc. are not files on disk,
    # they must fall through to the SPA entry point instead of 404-ing.
    location / {
        limit_req zone=${ZONE}_rl burst=60 nodelay;
        try_files \$uri \$uri/ /index.html;
    }
}
EOS

sudo ln -sfn "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx

echo "--- checking nginx serves the site"
curl -fsS -o /dev/null --max-time 5 -H "Host: ${DOMAIN:-localhost}" http://127.0.0.1/ \
  && echo "site responded OK" || echo "WARNING: nginx did not serve the site"
REMOTE
  ok "nginx serving $WEB_ROOT/current on :80"
}

# ------------------------------- https ----------------------------------------
resolve_ip() {  # cross-platform: linux, wsl, git bash, macos
  local host="$1" ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
  fi
  if [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1; then
    ip="$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
  fi
  if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
    ip="$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
  fi
  if [[ -z "$ip" ]] && command -v ping >/dev/null 2>&1; then
    ip="$(ping -c1 -w1 "$host" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  fi
  printf '%s' "$ip"
}

setup_ssl() {
  [[ -n "$DOMAIN" ]]    || { warn "No domain configured — skipping HTTPS."; return 0; }
  [[ -n "$SSL_EMAIL" ]] || { warn "No email configured — skipping HTTPS. Run './react-develop.sh config' then './react-develop.sh ssl'."; return 0; }

  step "Checking DNS for $DOMAIN"
  local resolved; resolved="$(resolve_ip "$DOMAIN")"
  if [[ -z "$resolved" ]]; then
    warn "$DOMAIN does not resolve yet. Point an A record to $SERVER_HOST, wait, then: ./react-develop.sh ssl"; return 0
  elif [[ "$resolved" != "$SERVER_HOST" ]]; then
    warn "$DOMAIN resolves to $resolved, not $SERVER_HOST. Certbot will likely fail."
    read -r -p "  Continue anyway? (y/N): " a; [[ "$a" =~ ^[Yy] ]] || return 0
  else
    ok "DNS points at this server"
  fi

  step "Requesting Let's Encrypt certificate"
  remote <<'REMOTE'
set -euo pipefail
ARGS="-d $DOMAIN"
case "$WWW_ALIAS" in [Yy]*) ARGS="$ARGS -d www.$DOMAIN";; esac
sudo certbot --nginx $ARGS --non-interactive --agree-tos -m "$SSL_EMAIL" --redirect
sudo systemctl reload nginx
sudo systemctl list-timers | grep -i certbot || true
REMOTE
  ok "HTTPS live at https://$DOMAIN (auto-renew enabled)"
}

# ------------------------------- rollback -------------------------------------
list_releases() {
  step "Releases on $SERVER_HOST"
  remote <<'REMOTE'
set -euo pipefail
CUR="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || echo none)"
cd "$WEB_ROOT/releases" 2>/dev/null || { echo "no releases yet"; exit 0; }
for d in $(ls -1d */ 2>/dev/null | sort -r); do
  d="${d%/}"
  mark="  "
  [ "$(readlink -f "$d")" = "$CUR" ] && mark="->"
  printf '%s %-32s %s\n' "$mark" "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
REMOTE
}

rollback() {
  step "Rolling back to the previous release"
  remote <<'REMOTE'
set -euo pipefail
cd "$WEB_ROOT/releases" 2>/dev/null || { echo "ERROR: no releases dir"; exit 1; }
CUR="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"
[ -n "$CUR" ] || { echo "ERROR: nothing is published yet — deploy first"; exit 1; }
PREV=""
# newest-first by name; the first entry that is not the live one is the previous
for d in $(ls -1d */ 2>/dev/null | sort -r); do
  d="${d%/}"
  [ "$(readlink -f "$d")" = "$CUR" ] && continue
  [ "$d" = "placeholder" ] && continue
  PREV="$d"; break
done
[ -n "$PREV" ] || { echo "ERROR: no previous release to roll back to"; exit 1; }
[ -f "$WEB_ROOT/releases/$PREV/index.html" ] || { echo "ERROR: $PREV has no index.html"; exit 1; }
sudo ln -sfn "$WEB_ROOT/releases/$PREV" "$WEB_ROOT/.current.tmp"
sudo mv -Tf "$WEB_ROOT/.current.tmp" "$WEB_ROOT/current"
sudo systemctl reload nginx
echo "now live: $PREV"
REMOTE
  ok "Rolled back"
  note "The next './react-develop.sh deploy' will build from git again and move forward."
}

# ------------------------------- extras ---------------------------------------
# Which local env file gets uploaded for THIS environment.
# Auto-detection is environment-aware: .env.<label> wins over the generic .env,
# so production and develop never silently ship the same API URLs. An explicit
# ENV_FILE in the config always overrides the search.
find_env_file() {
  local f candidates=()
  if [[ -n "$ENV_FILE" ]]; then
    f="${ENV_FILE/#\~/$HOME}"
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    return 1
  fi
  if [[ -n "${ENV_LABEL:-}" ]]; then
    candidates+=("$SCRIPT_DIR/.env.$ENV_LABEL")
    case "$ENV_LABEL" in
      develop|dev)      candidates+=("$SCRIPT_DIR/.env.development") ;;
      production|prod)  candidates+=("$SCRIPT_DIR/.env.production")  ;;
      staging|stage)    candidates+=("$SCRIPT_DIR/.env.staging")     ;;
    esac
  else
    candidates+=("$SCRIPT_DIR/.env.production")
  fi
  candidates+=("$SCRIPT_DIR/.env")     # shared fallback, used only if nothing above exists
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# upload_env [quiet]
#   quiet — used inside setup/deploy: upload only, the build runs right after.
#   plain — used by './react-develop.sh env': upload AND rebuild, because Vite
#           bakes VITE_* into the bundle at build time. Restarting nothing would
#           change nothing; the app must be built again to pick up new values.
upload_env() {
  local quiet="${1:-}" src for_env=""
  [[ -n "${ENV_LABEL:-}" ]] && for_env=" for $ENV_LABEL"
  if ! src="$(find_env_file)"; then
    [[ "$quiet" == "quiet" ]] && return 0
    warn "No env file found$for_env (looked for \$ENV_FILE, .env.${ENV_LABEL:-production}, .env)."; return 0
  fi

  if git -C "$SCRIPT_DIR" ls-files --error-unmatch "$src" >/dev/null 2>&1; then
    warn "$(basename "$src") is tracked by git — secrets are in your repo history."
  fi

  # Falling back to the shared .env across several environments is almost always
  # a mistake: every environment would build with the same API URLs.
  if [[ -n "${ENV_LABEL:-}" && "$(basename "$src")" == ".env" ]]; then
    warn "$ENV_LABEL is using the shared .env — create .env.$ENV_LABEL to give it its own values."
  fi

  step "Uploading $(basename "$src")$for_env -> $APP_DIR/.env"
  remote <<'REMOTE'
mkdir -p "$APP_DIR"
REMOTE
  scp "${SSH_OPTS[@]}" "$src" "$SSH_USER@$SERVER_HOST:$APP_DIR/.env" >/dev/null
  remote <<'REMOTE'
chmod 600 "$APP_DIR/.env"
echo "keys on server:"
grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$APP_DIR/.env" | sed 's/^/  /' || true
REMOTE
  ok "Env uploaded (values hidden)"
  if grep -qE '^VITE_' "$src" 2>/dev/null; then
    warn "VITE_* values are compiled into the JS bundle and readable by anyone who opens the site. Never put real secrets there."
  fi
  if [[ "$quiet" != "quiet" ]]; then
    note "rebuilding so the new values are baked into the bundle"
    deploy_app
  fi
}

allow_ip() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI not installed. brew install awscli  (or)  pip install awscli"
  [[ -n "$SG_ID" ]] || die "No SG_ID configured. Run ./react-develop.sh config and enter your security group id."
  local region_args=(); [[ -n "$AWS_REGION" ]] && region_args=(--region "$AWS_REGION")

  step "Finding your current public IP"
  local myip; myip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" \
    || die "Could not determine your public IP."
  ok "Your IP: $myip"

  step "Updating SSH rule on $SG_ID"
  local old_ids
  old_ids="$(aws ec2 describe-security-group-rules "${region_args[@]}" \
      --filters "Name=group-id,Values=$SG_ID" \
      --query "SecurityGroupRules[?Description=='deploy.sh-ssh'].SecurityGroupRuleId" \
      --output text 2>/dev/null || true)"

  if [[ -n "$old_ids" ]]; then
    for id in $old_ids; do
      aws ec2 revoke-security-group-ingress "${region_args[@]}" \
        --group-id "$SG_ID" --security-group-rule-ids "$id" >/dev/null
    done
    note "removed previous deploy.sh-ssh rule(s)"
  fi

  aws ec2 authorize-security-group-ingress "${region_args[@]}" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myip/32,Description=deploy.sh-ssh}]" \
    >/dev/null
  ok "Port 22 now open to $myip/32 only"
  warn "Any OTHER ssh rules you created by hand are untouched — remove 0.0.0.0/0 in the console."
}

harden_server() {
  step "Hardening $SERVER_HOST"
  remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "--- fail2ban + unattended security upgrades"
sudo apt-get install -y -qq fail2ban unattended-upgrades
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOS'
[sshd]
enabled  = true
maxretry = 4
findtime = 10m
bantime  = 2h
EOS
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

echo "--- sshd lockdown (keys only, no root login)"
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOS'
PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOS
sudo sshd -t && sudo systemctl reload ssh

echo "--- swap (protects builds on 1 GB instances)"
if ! sudo swapon --show | grep -q swapfile; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  sudo sysctl -w vm.swappiness=10 >/dev/null
fi
free -h | head -3

echo "--- app dir permissions"
chmod 750 "$APP_DIR" 2>/dev/null || true
[ -f "$APP_DIR/.env" ] && chmod 600 "$APP_DIR/.env"

echo "--- fail2ban status"
sudo fail2ban-client status sshd 2>/dev/null | head -5 || true
REMOTE
  ok "Server hardened"
  note "You are still logged in — open a second terminal and test ssh before closing this one."
}

summary() {
  local url="http://$SERVER_HOST"
  [[ -n "$DOMAIN" ]] && url="http://$DOMAIN"
  [[ -n "$DOMAIN" && -n "$SSL_EMAIL" ]] && url="https://$DOMAIN"
  local suffix=""; [[ -n "${ENV_LABEL:-}" ]] && suffix=" $ENV_LABEL"
  cat <<EOF

  ${C_G}Done.${C_0}  Your site$suffix (branch ${C_B}$GIT_BRANCH${C_0}): ${C_B}$url${C_0}

  Next time you push code, just run:   ${C_B}./react-develop.sh deploy$suffix${C_0}
  Bad build went live?                 ${C_B}./react-develop.sh rollback$suffix${C_0}
  Other commands: releases | logs | status | ssl | env | ssh | config | envs
EOF
}

# ------------------------------- commands -------------------------------------
cmd_setup() {
  # Nothing configured at all: ask how many environments before anything else.
  if [[ -z "$CONFIG_FILE_PINNED" && ! -f "$CONFIG_FILE" && -z "$(list_envs)" ]]; then
    local n=""
    cat <<'EOF'

  How many environments do you want?

    1   production only          main -> your live domain
    2   + develop                develop -> its own domain
    3   + staging                staging -> its own domain
    4+  qa, uat, demo, preview, then env5, env6, ...

  Each gets its own branch, domain, nginx block, /var/www dir and release
  history. You name them yourself — the above are just the defaults offered.

EOF
    while :; do
      ask n "Number of environments" "1"
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) && break
      warn "Enter a whole number between 1 and 20."
      n=""
    done
    if (( n > 1 )); then
      multi_env_wizard "$n"
      return 0
    fi
  fi
  load_config
  [[ -f "$CONFIG_FILE" ]] && { read -r -p "  Config found. Reuse saved answers? (Y/n): " a; [[ "$a" =~ ^[Nn] ]] && wizard || true; } || wizard
  [[ -f "$CONFIG_FILE" ]] || wizard
  init_ssh; preflight; provision; configure_git
  configure_nginx          # server block first, so the very first build has a home
  upload_env quiet; deploy_app
  setup_ssl; summary
}
cmd_envs() {
  local envs; envs="$(list_envs)"
  if [[ -z "$envs" ]]; then
    [[ -f "$SCRIPT_DIR/react-develop.conf" ]] \
      && { echo "  single environment (react-develop.conf)"; return 0; }
    warn "No environments configured yet. Run: ./react-develop.sh setup"; return 0
  fi
  printf '\n  %-14s %-12s %s\n' "ENVIRONMENT" "BRANCH" "DOMAIN"
  printf '  %-14s %-12s %s\n'   "-----------" "------" "------"
  local e f b d
  while read -r e; do
    [[ -z "$e" ]] && continue
    f="$SCRIPT_DIR/react-develop.$e.conf"
    b="$(sed -n 's/^GIT_BRANCH=//p' "$f" | tr -d "\"'")"
    d="$(sed -n 's/^DOMAIN=//p'     "$f" | tr -d "\"'")"
    printf '  %-14s %-12s %s\n' "$e" "$b" "${d:-(ip only)}"
  done <<< "$envs"
  echo
}
cmd_deploy()   { load_config; verify_repo_and_branch strict; init_ssh; configure_git; upload_env quiet; deploy_app; summary; }
cmd_rollback() { load_config; init_ssh; rollback; }
cmd_releases() { load_config; init_ssh; list_releases; }
cmd_ssl()      { load_config; init_ssh; configure_nginx; setup_ssl; }
cmd_nginx()    { load_config; init_ssh; configure_nginx; }
cmd_env()      { load_config; init_ssh; upload_env; }
cmd_allowip()  { load_config; allow_ip; }
cmd_harden()   { load_config; init_ssh; harden_server; }
cmd_config()   { load_config; wizard; }
cmd_ssh()      { load_config; init_ssh; remote_tty "cd '$APP_DIR' 2>/dev/null; exec bash -l"; }
cmd_logs()     {
  load_config; init_ssh
  remote_tty "sudo tail -f /var/log/nginx/'$APP_NAME'.access.log /var/log/nginx/'$APP_NAME'.error.log"
}
cmd_restart()  {
  load_config; init_ssh
  remote_tty "sudo nginx -t && sudo systemctl reload nginx && echo 'nginx reloaded'"
}
cmd_status()   {
  load_config; init_ssh
  remote <<'REMOTE'
echo "=== live release ==="
echo "root: $WEB_ROOT/current -> $(readlink -f "$WEB_ROOT/current" 2>/dev/null || echo '(not published yet)')"
sudo find "$WEB_ROOT/current/" -type f 2>/dev/null | wc -l | sed 's/^/files: /'
sudo du -sh "$WEB_ROOT/current/" 2>/dev/null | awk '{print "size: "$1}'
echo "kept releases: $(ls -1d "$WEB_ROOT"/releases/*/ 2>/dev/null | wc -l)"
echo; echo "=== nginx ==="; systemctl is-active nginx
echo; echo "=== disk ==="; df -h / | tail -1
echo; echo "=== memory ==="; free -h | head -2
echo; echo "=== last commit ==="; git -C "$APP_DIR" log -1 --pretty='%h %s (%cr)' 2>/dev/null || echo "no repo yet"
REMOTE
}

usage() { sed -n '3,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ------------------------------- dispatch -------------------------------------
CMD="${1:-setup}"
ENV_NAME="${2:-${DEPLOY_ENV:-}}"

# "all" runs the command against every configured environment, one after another
if [[ "$ENV_NAME" == "all" ]]; then
  all_envs="$(list_envs)"
  [[ -n "$all_envs" ]] || die "No environments configured. Run: ./react-develop.sh setup"
  while read -r e; do
    [[ -z "$e" ]] && continue
    printf '\n%s########  %s : %s  ########%s\n' "$C_B" "$CMD" "$e" "$C_0"
    "${BASH_SOURCE[0]}" "$CMD" "$e" || die "Failed on environment '$e'"
  done <<< "$all_envs"
  exit 0
fi

case "$CMD" in
  envs|list|-h|--help|help) : ;;   # these do not act on a single environment
  *) resolve_config ;;
esac

case "$CMD" in
  setup)    cmd_setup    ;;
  deploy)   cmd_deploy   ;;
  rollback) cmd_rollback ;;
  releases) cmd_releases ;;
  ssl)      cmd_ssl      ;;
  nginx)    cmd_nginx    ;;
  env)      cmd_env      ;;
  config)   cmd_config   ;;
  logs)     cmd_logs     ;;
  status)   cmd_status   ;;
  restart)  cmd_restart  ;;
  ssh)      cmd_ssh      ;;
  envs|list) cmd_envs    ;;
  allow-ip|allowip) cmd_allowip ;;
  harden)   cmd_harden   ;;
  -h|--help|help) usage ;;
  *) die "Unknown command '$CMD'. Try: ./react-develop.sh help" ;;
esac
