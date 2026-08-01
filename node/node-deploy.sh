#!/usr/bin/env bash
# ==============================================================================
#  node-deploy.sh — one-command deploy for a Node.js API / backend service.
#
#  Runs FROM YOUR LAPTOP. Talks to the server over SSH using your .pem key.
#  Install and build happen ON THE SERVER; pm2 runs your start command and
#  nginx reverse-proxies to it. Each deploy lands in its own release directory
#  and a symlink is flipped, so `rollback` is instant and needs no reinstall.
#
#  Usage:
#     ./node-deploy.sh setup     # first time: asks everything, installs stack
#     ./node-deploy.sh deploy    # every update: pull -> build -> publish -> reload
#     ./node-deploy.sh rollback  # back to the previous release (no rebuild)
#     ./node-deploy.sh releases  # list releases on the server
#     ./node-deploy.sh ssl       # issue/renew HTTPS cert for the domain
#     ./node-deploy.sh env       # upload .env, then rebuild or restart
#     ./node-deploy.sh logs      # tail live app logs (pm2)
#     ./node-deploy.sh status    # pm2 + nginx + release health
#     ./node-deploy.sh restart   # restart the Node process
#     ./node-deploy.sh nginx     # rewrite + reload the nginx server block
#     ./node-deploy.sh ssh       # drop into a shell on the server
#     ./node-deploy.sh config    # re-run the questions / edit answers
#     ./node-deploy.sh envs      # list configured environments
#     ./node-deploy.sh allow-ip  # point the SSH security group rule at your IP
#     ./node-deploy.sh harden    # fail2ban, auto updates, sshd lockdown, swap
#
#  ENVIRONMENTS (production / develop / ...):
#  Setup asks how many. Each gets its own branch, domain, PORT, pm2 process and
#  release history, so they share the server without touching each other.
#
#     ./node-deploy.sh setup            # asks how many, writes each config
#     ./node-deploy.sh setup all        # provision every environment
#     ./node-deploy.sh deploy develop   # act on one environment
#     ./node-deploy.sh deploy all       # act on every environment in turn
#
#  Every environment needs its OWN PORT. Environment variables are read at
#  startup, so a restart applies them — there is no browser bundle to rebuild.
#
#  Answers are cached in ./node-deploy*.conf (chmod 600) — they hold your git
#  token, so never commit them.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE_PINNED="${CONFIG_FILE:-}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/node-deploy.conf}"
ENV_NAME="${DEPLOY_ENV:-}"

list_envs() {
  ls -1 "$SCRIPT_DIR"/node-deploy.*.conf 2>/dev/null \
    | sed 's|.*/node-deploy\.||; s|\.conf$||' || true
}

resolve_config() {
  [[ -n "$CONFIG_FILE_PINNED" ]] && return 0
  local envs; envs="$(list_envs)"
  if [[ -n "$ENV_NAME" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/node-deploy.$ENV_NAME.conf"
    if [[ ! -f "$CONFIG_FILE" && "${CMD:-}" != "setup" && "${CMD:-}" != "config" ]]; then
      die "No such environment '$ENV_NAME'. Configured: $(echo $envs). Run: ./node-deploy.sh setup"
    fi
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/node-deploy.conf" && -z "$envs" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/node-deploy.conf"; return 0
  fi
  local count; count="$(printf '%s\n' "$envs" | grep -c . || true)"
  if [[ "$count" == "1" ]]; then
    ENV_NAME="$envs"; CONFIG_FILE="$SCRIPT_DIR/node-deploy.$ENV_NAME.conf"; return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    printf '\n  ! Several environments exist. Name one, or use "all":\n' >&2
    printf '      %s\n' $envs >&2
    printf '      e.g. ./node-deploy.sh %s %s\n\n' "${CMD:-deploy}" "$(printf '%s\n' "$envs" | head -1)" >&2
    exit 1
  fi
  CONFIG_FILE="$SCRIPT_DIR/node-deploy.conf"
}

# --- Windows / Git Bash compatibility -----------------------------------------
IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    IS_WINDOWS=1; export MSYS_NO_PATHCONV=1; export MSYS2_ARG_CONV_EXCL='*' ;;
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
PEM_PATH=""
SERVER_HOST=""
SSH_USER="ubuntu"
NODE_MAJOR="22"
REPO_URL=""
REPO_PRIVATE="y"
GIT_USER=""
GIT_TOKEN=""
GIT_BRANCH="develop"
APP_NAME="api"
APP_DIR=""           # /home/ubuntu/apps/<APP_NAME>   — the git checkout
WEB_ROOT=""          # /var/www/<APP_NAME>            — releases + current
APP_PORT="3000"      # MUST be unique per environment
INSTALL_CMD="npm ci || npm install"   # keep dev deps: TS/build tooling lives there
START_CMD="npm start"                 # what pm2 runs: npm start, node server.js, ...
BUILD_CMD=""                          # blank = skip; many APIs have no build step
ENV_FILE=""
DOMAIN=""
WWW_ALIAS="n"
SSL_EMAIL=""
SETUP_FIREWALL="y"
SG_ID=""
AWS_REGION=""
KEEP_RELEASES="3"    # Next builds are large; 3 keeps rollback without filling disk
MAX_MEMORY="500M"    # pm2 restarts the process above this
ENV_LABEL=""

CONFIG_KEYS=(PEM_PATH SERVER_HOST SSH_USER NODE_MAJOR REPO_URL REPO_PRIVATE GIT_USER
             GIT_TOKEN GIT_BRANCH APP_NAME APP_DIR WEB_ROOT APP_PORT INSTALL_CMD
             BUILD_CMD START_CMD ENV_FILE DOMAIN WWW_ALIAS SSL_EMAIL SETUP_FIREWALL SG_ID
             AWS_REGION KEEP_RELEASES MAX_MEMORY ENV_LABEL)

load_config() { [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true; }

save_config() {
  : > "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
  {
    echo "# node-deploy.sh config — contains a git token. NEVER commit this file."
    for k in "${CONFIG_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done
  } >> "$CONFIG_FILE"
  ok "Saved answers to $CONFIG_FILE (chmod 600)"
  local root; root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$root" ]] && ! git -C "$SCRIPT_DIR" check-ignore -q "$CONFIG_FILE" 2>/dev/null; then
    echo "$(basename "$CONFIG_FILE")" >> "$root/.gitignore"
    note "added $(basename "$CONFIG_FILE") to .gitignore"
  fi
}

ask() {
  local var="$1" prompt="$2" def="${3:-}" cur ans
  cur="${!var:-}"; [[ -n "$cur" ]] && def="$cur"
  if [[ -n "$def" ]]; then read -r -e -p "  $prompt [$def]: " ans; else read -r -e -p "  $prompt: " ans; fi
  ans="${ans:-$def}"
  [[ "$ans" == "-" ]] && ans=""      # the only way to clear a saved value
  printf -v "$var" '%s' "$ans"
}

ask_secret() {
  local var="$1" prompt="$2" ans cur
  cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    read -r -p "  $prompt [keep existing, press Enter]: " -s ans; echo
    [[ -n "$ans" ]] && printf -v "$var" '%s' "$ans"
    return 0
  fi
  read -r -p "  $prompt: " -s ans; echo
  printf -v "$var" '%s' "$ans"
}

ask_required() {
  local var="$1" prompt="$2" def="${3:-}"
  while :; do
    ask "$var" "$prompt" "$def"
    [[ -n "${!var:-}" ]] && break
    warn "This one can't be empty."
  done
}

# ---- input cleaners ----------------------------------------------------------
normalize_domain() {
  local d="$1"
  d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%%:*}"; d="${d,,}"
  printf '%s' "$d"
}
valid_domain() {
  local d="$1"; [[ -z "$d" ]] && return 0
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}
ask_domain() {
  local var="$1" prompt="$2" clean
  while :; do
    ask "$var" "$prompt"
    clean="$(normalize_domain "${!var}")"
    [[ "$clean" != "${!var}" ]] && { note "using '$clean'"; printf -v "$var" '%s' "$clean"; }
    valid_domain "${!var}" && break
    warn "'${!var}' is not a valid hostname — letters, digits, hyphens and dots only (no underscores)."
    printf -v "$var" '%s' ""
  done
}

# A backend is a listening process, so the port genuinely has to be free.
port_taken_locally() {  # port_taken_locally <port> <this-env>
  local p="$1" me="$2" f e
  for f in "$SCRIPT_DIR"/node-deploy.*.conf; do
    [[ -f "$f" ]] || continue
    e="$(basename "$f" | sed 's|node-deploy\.||; s|\.conf$||')"
    [[ "$e" == "$me" ]] && continue
    [[ "$(sed -n 's/^APP_PORT=//p' "$f" | tr -d "\"'")" == "$p" ]] && { printf '%s' "$e"; return 0; }
  done
  return 1
}

ask_port() {
  local var="$1" prompt="$2" clash
  while :; do
    ask "$var" "$prompt"
    if [[ ! "${!var}" =~ ^[0-9]+$ ]] || (( ${!var} < 1024 || ${!var} > 65535 )); then
      warn "Enter a port number between 1024 and 65535."; printf -v "$var" '%s' ""; continue
    fi
    if clash="$(port_taken_locally "${!var}" "${ENV_LABEL:-}")"; then
      warn "Port ${!var} is already used by the '$clash' environment — each needs its own."
      printf -v "$var" '%s' ""; continue
    fi
    break
  done
}

ask_env_file() {
  ask ENV_FILE "$1"
  [[ -z "$ENV_FILE" ]] && return 0
  ENV_FILE="${ENV_FILE/#\~/$HOME}"
  if [[ "$IS_WINDOWS" == "1" && "$ENV_FILE" =~ ^[A-Za-z]:[\\/] ]]; then
    ENV_FILE="$(cygpath -u "$ENV_FILE" 2>/dev/null || printf '%s' "$ENV_FILE")"
    note "converted to $ENV_FILE"
  fi
  if [[ -d "$ENV_FILE" ]]; then
    if [[ -f "$ENV_FILE/.env" ]]; then ENV_FILE="$ENV_FILE/.env"; note "that is a folder — using $ENV_FILE"
    else warn "$ENV_FILE is a folder with no .env inside — leaving blank (auto-detect)."; ENV_FILE=""; return 0; fi
  fi
  [[ -f "$ENV_FILE" ]] || warn "$ENV_FILE does not exist yet — nothing will be uploaded unless you create it."
}

# --------------------- repo access / branch verification ----------------------
auth_repo_url() {
  if [[ -n "$GIT_TOKEN" && "$REPO_URL" == https://* ]]; then
    printf '%s' "https://${GIT_USER}:${GIT_TOKEN}@${REPO_URL#https://}"
  else
    printf '%s' "$REPO_URL"
  fi
}
# stderr discarded: git echoes the URL (with the token) on failure.
fetch_remote_branches() {
  GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$(auth_repo_url)" 2>/dev/null \
    | sed 's|^[0-9a-f]*[[:space:]]*refs/heads/||'
}
verify_repo_and_branch() {
  local mode="${1:-}" branches count suggest
  command -v git >/dev/null 2>&1 || { warn "git not installed locally — skipping branch check"; return 0; }
  [[ -n "$REPO_URL" ]] || return 0

  step "Verifying repo access and branch '$GIT_BRANCH'"
  branches="$(fetch_remote_branches)"
  if [[ -z "$branches" ]]; then
    warn "Could not read $REPO_URL"
    note "check: URL correct? token expired? token missing Contents:Read on this repo?"
    [[ "$mode" == "strict" ]] && die "Stopped before touching the server. Fix with: ./node-deploy.sh config"
    read -r -p "  Continue anyway? (y/N): " a
    [[ "$a" =~ ^[Yy] ]] || die "Stopped. Run ./node-deploy.sh config."
    return 0
  fi
  count="$(printf '%s\n' "$branches" | grep -c . || true)"
  ok "Repo reachable — $count branch(es) found"

  while ! printf '%s\n' "$branches" | grep -qxF -- "$GIT_BRANCH"; do
    warn "Branch '$GIT_BRANCH' does NOT exist in this repo."
    printf '    available: %s\n' "$(printf '%s\n' "$branches" | head -25 | paste -sd' ' -)"
    [[ "$mode" == "strict" ]] && die "Nothing was deployed. Fix with: ./node-deploy.sh config"
    if   printf '%s\n' "$branches" | grep -qxF -- "main";   then suggest="main"
    elif printf '%s\n' "$branches" | grep -qxF -- "master"; then suggest="master"
    else suggest="$(printf '%s\n' "$branches" | head -1)"; fi
    GIT_BRANCH="$suggest"
    ask GIT_BRANCH "Branch to deploy"
    [[ -n "$GIT_BRANCH" ]] || GIT_BRANCH="$suggest"
  done
  ok "Branch '$GIT_BRANCH' exists"
}

# ------------------------------- ssh plumbing ---------------------------------
init_ssh() {
  [[ -n "$PEM_PATH" && -f "$PEM_PATH" ]] || die "PEM key not found: '$PEM_PATH'. Run: ./node-deploy.sh config"
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

remote() {
  local envs=""
  for k in APP_NAME APP_DIR WEB_ROOT APP_PORT NODE_MAJOR REPO_URL GIT_BRANCH GIT_USER \
           GIT_TOKEN INSTALL_CMD BUILD_CMD START_CMD DOMAIN WWW_ALIAS SSL_EMAIL SSH_USER \
           SETUP_FIREWALL KEEP_RELEASES MAX_MEMORY; do
    envs+="$k=$(printf '%q' "${!k}") "
  done
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_HOST" "$envs bash -s" || return $?
}
remote_tty() { ${TTY_WRAP[@]+"${TTY_WRAP[@]}"} ssh -t "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_HOST" "$@"; }

# ------------------------------- the wizard -----------------------------------
wizard() {
  cat <<'BANNER'

  ┌──────────────────────────────────────────────┐
  │   Node.js API  ->  VPS   deployment setup    │
  └──────────────────────────────────────────────┘
BANNER

  step "1/7  Server access"
  if [[ -z "$PEM_PATH" ]]; then
    local found_pem
    found_pem="$(ls -1 "$SCRIPT_DIR"/*.pem "$SCRIPT_DIR"/../*.pem 2>/dev/null | head -1 || true)"
    [[ -n "$found_pem" ]] && { PEM_PATH="$found_pem"; note "found key: $found_pem"; }
  fi
  ask_required PEM_PATH    "Path to your .pem key"
  PEM_PATH="${PEM_PATH/#\~/$HOME}"
  ask_required SERVER_HOST "Server public IP or DNS"
  ask SSH_USER    "SSH user (ubuntu | ec2-user | root)"

  step "2/7  Git repository"
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
  verify_repo_and_branch

  step "3/7  Application"
  local guess; guess="$(basename -s .git "${REPO_URL:-app}")"
  [[ "$APP_NAME" == "api" && -n "$guess" ]] && APP_NAME="$guess"
  ask APP_NAME    "Site name (pm2 process, /var/www/<name>, nginx config)"
  ask NODE_MAJOR  "Node.js major version"
  ask INSTALL_CMD "Install command (must include devDependencies)"
  ask BUILD_CMD   "Build command (blank = none, e.g. tsc for a TypeScript API)"
  ask START_CMD   "Start command pm2 runs (npm start | node server.js | node dist/main.js)"
  ask_env_file    "Local env file to upload (blank = auto-detect .env.${ENV_LABEL:-production} / .env)"
  APP_DIR="/home/$SSH_USER/apps/$APP_NAME"
  [[ "$SSH_USER" == "root" ]] && APP_DIR="/root/apps/$APP_NAME"
  WEB_ROOT="/var/www/$APP_NAME"

  step "4/7  Port"
  note "each environment is its own process — every one needs its own port"
  ask_port APP_PORT "Port for this environment (nginx proxies to it)"
  ask MAX_MEMORY    "Restart the process if it exceeds (e.g. 500M)"
  note "Checkout:  $APP_DIR"
  note "Releases:  $WEB_ROOT/releases,  live via $WEB_ROOT/current"

  step "5/7  Nginx + domain"
  ask_domain DOMAIN "Domain, e.g. app.example.com ('-' = serve on IP only)"
  if [[ -n "$DOMAIN" ]]; then
    if [[ "$(printf '%s' "$DOMAIN" | tr -cd . | wc -c)" -gt 1 ]]; then
      WWW_ALIAS="n"; note "$DOMAIN is a subdomain — skipping the www alias"
    else
      ask WWW_ALIAS "Also serve www.$DOMAIN? (y/n)"
    fi
  fi

  step "6/7  HTTPS"
  if [[ -n "$DOMAIN" ]]; then
    ask SSL_EMAIL "Email for Let's Encrypt (blank = skip HTTPS for now)"
  else
    note "no domain -> skipping HTTPS"
  fi

  step "7/7  Firewall"
  ask SETUP_FIREWALL "Enable UFW firewall (22/80/443 only)? (y/n)"
  ask SG_ID       "AWS security group id for SSH allowlist (blank = skip 'allow-ip')"
  [[ -n "$SG_ID" ]] && ask AWS_REGION "AWS region (e.g. us-east-1)"

  save_config
}

# ---------------------- multi-environment wizard ------------------------------
ENV_DEFAULT_LABELS=(production develop staging qa uat demo preview)
env_default_label() {
  local i="$1"
  if (( i <= ${#ENV_DEFAULT_LABELS[@]} )); then printf '%s' "${ENV_DEFAULT_LABELS[$((i-1))]}"
  else printf 'env%s' "$i"; fi
}
env_default_branch() {
  case "$1" in production|prod|live|main) printf 'main' ;; *) printf '%s' "$1" ;; esac
}
# The offered default must never already be taken, or pressing Enter loops.
env_free_label() {
  local i="$1" used=" $2 " cand n
  cand="$(env_default_label "$i")"
  [[ "$used" != *" $cand "* ]] && { printf '%s' "$cand"; return 0; }
  for cand in "${ENV_DEFAULT_LABELS[@]}"; do
    [[ "$used" != *" $cand "* ]] && { printf '%s' "$cand"; return 0; }
  done
  n="$i"; while [[ "$used" == *" env$n "* ]]; do n=$((n+1)); done
  printf 'env%s' "$n"
}

multi_env_wizard() {
  local count="$1" i base_name used="" def_label base_port
  for (( i=1; i<=count; i++ )); do
    printf '\n%s========  Environment %s of %s  ========%s\n' "$C_B" "$i" "$count" "$C_0"
    def_label="$(env_free_label "$i" "$used")"
    ENV_LABEL="$def_label"
    while :; do
      ask ENV_LABEL "Name for this environment"
      ENV_LABEL="$(printf '%s' "$ENV_LABEL" | tr -cd 'a-zA-Z0-9._-')"
      [[ -z "$ENV_LABEL" ]] && { warn "Name can't be empty."; ENV_LABEL="$def_label"; continue; }
      [[ " $used " == *" $ENV_LABEL "* ]] && {
        warn "'$ENV_LABEL' is already taken by an earlier environment — pick another."
        ENV_LABEL="$def_label"; continue; }
      break
    done
    used="$used $ENV_LABEL"
    GIT_BRANCH="$(env_default_branch "$ENV_LABEL")"

    if (( i == 1 )); then
      CONFIG_FILE="$SCRIPT_DIR/node-deploy.$ENV_LABEL.conf"
      wizard
      base_name="$(basename -s .git "$REPO_URL")"
      base_port="$APP_PORT"
    else
      ask GIT_BRANCH  "Branch to deploy for $ENV_LABEL"
      verify_repo_and_branch
      APP_NAME="${base_name}-${ENV_LABEL}"
      ask APP_NAME    "Site name for $ENV_LABEL (must differ from the others)"
      APP_DIR="/home/$SSH_USER/apps/$APP_NAME"
      [[ "$SSH_USER" == "root" ]] && APP_DIR="/root/apps/$APP_NAME"
      WEB_ROOT="/var/www/$APP_NAME"
      APP_PORT=$(( base_port + i - 1 ))
      ask_port APP_PORT "Port for $ENV_LABEL (must be unique on the server)"
      DOMAIN=""
      ask_domain DOMAIN "Domain for $ENV_LABEL, e.g. dev.example.com"
      WWW_ALIAS="n"
      if [[ -n "$DOMAIN" && "$(printf '%s' "$DOMAIN" | tr -cd . | wc -c)" -le 1 ]]; then
        ask WWW_ALIAS "Also serve www.$DOMAIN? (y/n)"
      fi
      ENV_FILE=""
      ask_env_file    "Local env file for $ENV_LABEL (blank = auto-detect .env.$ENV_LABEL)"
      note "$ENV_LABEL: branch '$GIT_BRANCH' on port $APP_PORT -> ${DOMAIN:-ip only}"
      CONFIG_FILE="$SCRIPT_DIR/node-deploy.$ENV_LABEL.conf"
      save_config
    fi
  done
  printf '\n'
  ok "Created $count environment configs"
  cmd_envs
  cat <<EOF
  Now provision them on the server:

     ${C_B}./node-deploy.sh setup all${C_0}          (or: setup <name>, one at a time)

  After that, day to day:

     ${C_B}./update.sh develop${C_0}

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
provision() {
  step "Checking system stack (node $NODE_MAJOR, pm2, nginx, certbot, git)"
  remote <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Check-first: nothing is installed, and apt is not even refreshed, unless
# something is genuinely missing.
APT_REFRESHED=0
apt_refresh_once() {
  [ "$APT_REFRESHED" = "1" ] && return 0
  echo "--- refreshing apt package lists"; sudo apt-get update -y -qq; APT_REFRESHED=1
}

MISSING=""
for p in curl git ca-certificates gnupg build-essential ufw; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
  apt_refresh_once; echo "--- installing missing packages:$MISSING"; sudo apt-get install -y -qq $MISSING
else
  echo "[present] curl git ca-certificates gnupg build-essential ufw"
fi

if command -v node >/dev/null 2>&1 && [ "$(node -v | cut -d. -f1)" = "v${NODE_MAJOR}" ]; then
  echo "[present] node $(node -v) / npm $(npm -v)"
else
  if command -v node >/dev/null 2>&1; then
    echo "--- node $(node -v) found but major ${NODE_MAJOR} wanted"
    echo "    WARNING: other apps on this server share this node."
  fi
  apt_refresh_once
  echo "--- installing Node.js ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs
  echo "node $(node -v) / npm $(npm -v)"
fi

if command -v pm2 >/dev/null 2>&1; then
  echo "[present] pm2 $(pm2 -v 2>/dev/null)"
else
  echo "--- installing pm2"
  sudo npm install -g pm2@latest --silent
  sudo env PATH="$PATH:/usr/bin" "$(command -v pm2)" startup systemd -u "$USER" --hp "$HOME" >/dev/null
fi

if command -v nginx >/dev/null 2>&1; then
  echo "[present] $(nginx -v 2>&1)"
  systemctl is-active --quiet nginx || { echo "--- starting nginx"; sudo systemctl enable --now nginx; }
else
  apt_refresh_once; echo "--- installing nginx"; sudo apt-get install -y -qq nginx
  sudo systemctl enable --now nginx
fi

if command -v certbot >/dev/null 2>&1; then
  echo "[present] $(certbot --version 2>&1)"
else
  apt_refresh_once; echo "--- installing certbot"; sudo apt-get install -y -qq certbot python3-certbot-nginx
fi

case "${SETUP_FIREWALL:-n}" in
  [Yy]*)
    if sudo ufw status 2>/dev/null | grep -q '^Status: active' && sudo ufw status | grep -q 'Nginx Full'; then
      echo "[present] ufw active, 22/80/443 already allowed"
    else
      echo "--- configuring firewall"
      sudo ufw allow OpenSSH >/dev/null; sudo ufw allow 'Nginx Full' >/dev/null
      sudo ufw --force enable >/dev/null
    fi ;;
esac

mkdir -p "$(dirname "$APP_DIR")"
sudo mkdir -p "$WEB_ROOT/releases"
sudo chown "$USER":"$USER" "$WEB_ROOT" "$WEB_ROOT/releases"

# ---- clashes with what is already on this box --------------------------------
if [ -n "${DOMAIN:-}" ]; then
  CLASH="$(grep -rlE "^[[:space:]]*server_name[[:space:]].*[[:space:]]${DOMAIN}([[:space:]]|;)" \
           /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "/${APP_NAME}\$" || true)"
  if [ -n "$CLASH" ]; then echo "WARNING: $DOMAIN is already claimed by: $CLASH"; fi
fi

# A port owned by a DIFFERENT process is a hard problem — say so early.
if ss -ltn 2>/dev/null | grep -qE "[:.]${APP_PORT}[[:space:]]"; then
  OWNER="$(pm2 jlist 2>/dev/null | grep -o "\"name\":\"$APP_NAME\"" || true)"
  if [ -z "$OWNER" ]; then
    echo "WARNING: port $APP_PORT is already listening and is not this app's pm2 process."
  fi
fi

echo "--- disk"; df -h / | tail -1
echo "--- memory"; free -m | awk '/^Mem:/{print "  "$2"MB total, "$7"MB available"}'

# Say no here rather than after a 20-second npm install and a 500MB checkout.
# MEASURED from real deploys, at the PEAK rather than the steady state.
# What is still needed depends on what is already on disk: once node_modules
# exists it is already counted as used, and re-checking as though it had to be
# downloaded again refuses deploys that would fit perfectly well.
# A backend is far lighter than a frontend build: a typical Express/Nest API
# checkout measures ~80MB against ~470MB for Next.js, so the numbers here are
# sized to that rather than copied across.
FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
if [ -d "$APP_DIR/node_modules" ]; then
  NEED_TOTAL=250; KIND="redeploy (node_modules already present)"
else
  NEED_TOTAL=500; KIND="first deploy"
fi
if [ "$FREE_MB" -lt "$NEED_TOTAL" ]; then
  echo
  echo "ERROR: ${FREE_MB}MB free on / — a ${KIND} needs about ${NEED_TOTAL}MB:"
  if [ "$NEED_TOTAL" = "500" ]; then
    echo "         ~80MB   node_modules"
    echo "         ~60MB   npm cache growth during install"
  fi
  echo "         ~150MB  working room for the build (if configured)"
  echo "         ~80MB   per kept release (${KEEP_RELEASES:-3} are kept)"
  echo "       It settles back to ~320MB afterwards. Nothing was changed."
  echo
  echo "       Reclaim space:  sudo du -sh /home/*/apps/* /var/www/* | sort -rh | head"
  # Resolve the real device: growpart needs the DISK plus a partition number,
  # not the /dev/root alias, and NVMe names differ from xvd ones.
  ROOTPART="$(findmnt -no SOURCE / 2>/dev/null || echo /dev/root)"
  ROOTDISK="$(lsblk -no PKNAME "$ROOTPART" 2>/dev/null | head -1)"
  PARTNUM="$(printf '%s' "$ROOTPART" | grep -oE '[0-9]+$' || echo 1)"
  if [ -n "$ROOTDISK" ]; then
    echo "       Or grow the EBS volume in the AWS console, then on this server:"
    echo "         sudo growpart /dev/$ROOTDISK $PARTNUM && sudo resize2fs $ROOTPART"
  fi
  exit 1
fi
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

# ------------------------------- deploy ---------------------------------------
deploy_app() {
  step "Deploying $APP_NAME ($GIT_BRANCH) -> $WEB_ROOT/current  :$APP_PORT"
  remote <<'REMOTE'
set -euo pipefail

# ---------- 1. source code ----------------------------------------------------
# The uploaded .env must survive the git step: repos often TRACK a .env, and
# `git reset --hard` silently reverts it to the committed version.
ENV_BAK=""
if [ -f "$APP_DIR/.env" ]; then ENV_BAK="$(mktemp)"; cp "$APP_DIR/.env" "$ENV_BAK"; fi

if [ -d "$APP_DIR/.git" ]; then
  echo "--- pulling latest"
  cd "$APP_DIR"
  git remote set-url origin "$REPO_URL"
  git fetch --all --prune
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
  chmod 600 "$APP_DIR/.env"; rm -f "$ENV_BAK"
fi
SHA="$(git rev-parse --short HEAD)"
echo "commit: $(git log -1 --pretty='%h %s')"

# ---------- 2. dependencies ---------------------------------------------------
echo "--- installing dependencies"
eval "$INSTALL_CMD"

# npm's cache grows by roughly the size of node_modules during a fresh install
# and is pure overhead once the install is done.
# On a tight disk that growth is the difference between a build finishing and
# dying halfway, so reclaim it before building rather than after failing.
FREE_AFTER_INSTALL=$(df -Pm / | awk 'NR==2{print $4}')
if [ "$FREE_AFTER_INSTALL" -lt 300 ]; then
  echo "--- ${FREE_AFTER_INSTALL}MB free after install; clearing the npm cache"
  npm cache clean --force >/dev/null 2>&1 || true
  echo "    now $(df -Pm / | awk 'NR==2{print $4}')MB free"
fi

# ---------- 3. build ----------------------------------------------------------
# Parsed line by line, NOT sourced: a dotenv file legally contains unquoted
# values with spaces and shell metacharacters, which `.` would try to execute.
load_env_file() {
  local file="$1" line key val n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#export }"; key="${key//[[:space:]]/}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$val" in
      '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
      "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"; n=$((n+1))
  done < "$file"
  echo "    loaded $n variables"
}

if [ -f "$APP_DIR/.env" ]; then
  echo "--- loading .env into build environment"
  load_env_file "$APP_DIR/.env"
else
  echo "--- no .env on server (build runs without it)"
fi

# A TypeScript build on a small instance gets OOM-killed without swap,
# surfacing only as a silent "Killed".
TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m  | awk '/^Swap:/{print $2}')
FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
echo "--- ${TOTAL_MB}MB RAM, ${SWAP_MB}MB swap, ${FREE_MB}MB free disk"

# Refuse rather than fill the disk. `next build` writes .next/ plus the release
# copy; running out mid-build leaves a half-written tree AND a full volume,
# which takes every other site on the box down with it.
NEED_MB=200
if [ "$FREE_MB" -lt "$NEED_MB" ]; then
  echo "ERROR: only ${FREE_MB}MB free on / — the build needs about ${NEED_MB}MB."
  echo "       Nothing has been changed. Free space or grow the volume, then retry:"
  echo "         du -sh /home/*/apps/* /var/www/*   # what is using it"
  echo "         ./node-deploy.sh releases <env>    # old releases can be pruned"
  exit 1
fi

# Add swap ONLY if there is genuinely too little and the disk can spare it.
# Never remove working swap first: if the replacement then fails to allocate,
# the box is left with no swap at all and a full disk.
if [ "$TOTAL_MB" -lt 4096 ] && [ "$SWAP_MB" -lt 1024 ]; then
  WANT=2048
  SPARE=$(( FREE_MB - NEED_MB ))          # never eat the build's headroom
  [ "$SPARE" -lt "$WANT" ] && WANT="$SPARE"
  if [ "$WANT" -ge 512 ]; then
    echo "--- adding a ${WANT}MB swapfile for the build"
    # A separate name so an existing /swapfile is never clobbered.
    if sudo fallocate -l "${WANT}M" /swapfile-build 2>/dev/null; then
      sudo chmod 600 /swapfile-build
      sudo mkswap /swapfile-build >/dev/null
      sudo swapon /swapfile-build
      grep -q '^/swapfile-build' /etc/fstab || echo '/swapfile-build none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
      sudo sysctl -w vm.swappiness=10 >/dev/null
    else
      sudo rm -f /swapfile-build
      echo "    could not allocate it — continuing without extra swap"
    fi
  else
    echo "--- too little free disk to add swap safely; continuing without it"
  fi
else
  echo "--- swap is sufficient (${SWAP_MB}MB)"
fi
if [ "$TOTAL_MB" -lt 4096 ]; then
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}"
  echo "--- NODE_OPTIONS=$NODE_OPTIONS"
fi

if [ -n "$BUILD_CMD" ]; then
  echo "--- building: $BUILD_CMD"
  NODE_ENV=production eval "$BUILD_CMD"
else
  echo "--- no build command configured (plain JS API, nothing to compile)"
fi

# ---------- 4. assemble the release -------------------------------------------
# The whole prepared app becomes the release: source, node_modules and any build
# output. .git is excluded — it is often the largest thing in the checkout and
# the running app never needs it.
[ -f "$APP_DIR/package.json" ] || { echo "ERROR: no package.json in $APP_DIR"; exit 1; }

REL="$(date -u +%Y%m%d-%H%M%S)-$SHA"
NEW="$WEB_ROOT/releases/$REL"
echo "--- assembling release $REL"
mkdir -p "$NEW"
tar -C "$APP_DIR" --exclude=./.git -cf - . | tar -C "$NEW" -xf -
[ -f "$NEW/package.json" ] || { echo "ERROR: release is incomplete"; rm -rf "$NEW"; exit 1; }
[ -d "$NEW/node_modules" ] || echo "WARNING: no node_modules in the release — did the install run?"

# Runtime env for pm2, written shell-safe with %q so the wrapper can source it
# without re-introducing the unquoted-value problem.
: > "$WEB_ROOT/.env.export"
chmod 600 "$WEB_ROOT/.env.export"
if [ -f "$APP_DIR/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#export }"; key="${key//[[:space:]]/}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$val" in
      '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
      "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf 'export %s=%q\n' "$key" "$val" >> "$WEB_ROOT/.env.export"
  done < "$APP_DIR/.env"
fi

# Whatever START_CMD is — "npm start", "node server.js", "node dist/main.js" —
# it runs from the release directory with PORT and the uploaded env in scope.
cat > "$WEB_ROOT/start.sh" <<EOS
#!/usr/bin/env bash
cd "$WEB_ROOT/current"
export NODE_ENV=production
export PORT="$APP_PORT"
[ -f "$WEB_ROOT/.env.export" ] && . "$WEB_ROOT/.env.export"
exec $START_CMD
EOS
chmod +x "$WEB_ROOT/start.sh"

cat > "$WEB_ROOT/ecosystem.config.cjs" <<EOS
module.exports = {
  apps: [{
    name: "$APP_NAME",
    script: "$WEB_ROOT/start.sh",
    interpreter: "bash",
    cwd: "$WEB_ROOT",
    instances: 1,
    exec_mode: "fork",
    max_memory_restart: "$MAX_MEMORY",
    autorestart: true,
    env: { NODE_ENV: "production", PORT: "$APP_PORT", HOSTNAME: "127.0.0.1" }
  }]
};
EOS

# ---------- 5. flip and restart -----------------------------------------------
ln -sfn "$NEW" "$WEB_ROOT/.current.tmp"
mv -Tf "$WEB_ROOT/.current.tmp" "$WEB_ROOT/current"
echo "live release: $REL"

echo "--- (re)starting pm2 process"
pm2 startOrRestart "$WEB_ROOT/ecosystem.config.cjs" --update-env
pm2 save >/dev/null

echo "--- health check on 127.0.0.1:$APP_PORT"
OK=0
for i in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$APP_PORT/"; then
    echo "app responded OK"; OK=1; break
  fi
  sleep 2
done
if [ "$OK" != "1" ]; then
  echo "WARNING: no response on :$APP_PORT after 40s — check: pm2 logs $APP_NAME"
fi

# ---------- 6. prune ----------------------------------------------------------
# By NAME, not mtime: release dirs are <timestamp>-<sha>, and `cp -a` preserves
# source timestamps on the new directory so `ls -t` cannot be trusted.
KEEP="${KEEP_RELEASES:-3}"
CUR="$(readlink -f "$WEB_ROOT/current")"
cd "$WEB_ROOT/releases"
ls -1d */ 2>/dev/null | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do
  old="${old%/}"
  [ "$(readlink -f "$old")" = "$CUR" ] && continue
  echo "--- pruning old release $old"
  rm -rf "$WEB_ROOT/releases/$old"
done

df -h / | tail -1
exit 0
REMOTE
  ok "Deploy finished"
}

# ------------------------------- nginx ----------------------------------------
configure_nginx() {
  step "Configuring nginx reverse proxy -> 127.0.0.1:$APP_PORT"
  remote <<'REMOTE'
set -euo pipefail
SERVER_NAMES="_"
ZONE="$(printf '%s' "$APP_NAME" | tr -c 'a-zA-Z0-9' '_' | cut -c1-24)"
if [ -n "$DOMAIN" ]; then
  SERVER_NAMES="$DOMAIN"
  case "$WWW_ALIAS" in [Yy]*) SERVER_NAMES="$DOMAIN www.$DOMAIN";; esac
fi

sudo tee "/etc/nginx/sites-available/$APP_NAME" >/dev/null <<EOS
# A single generous budget: every request here is an API call, and one page in
# the frontend can legitimately fire 20-30 of them in parallel. A page-sized
# limit would reject that as an attack.
limit_req_zone  \$binary_remote_addr zone=${ZONE}_api:10m rate=150r/s;
limit_conn_zone \$binary_remote_addr zone=${ZONE}_cn:10m;

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAMES;

    server_tokens off;
    client_max_body_size 25M;

    access_log /var/log/nginx/$APP_NAME.access.log;
    error_log  /var/log/nginx/$APP_NAME.error.log;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_proxied any;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location ~ /\.(?!well-known) { deny all; }

    # A backend serves no static assets and has no page routes — every path is an
    # API call. So there is nothing to special-case here, and the whole server
    # gets the generous budget that only /api/ needed in the frontend configs.
    # proxy_buffering is off so streamed responses (SSE, downloads, long polls)
    # reach the client as they are produced.
    location / {
        limit_req  zone=${ZONE}_api burst=300 nodelay;
        limit_conn ${ZONE}_cn 100;

        proxy_pass         http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering    off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOS

sudo ln -sfn "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
exit 0
REMOTE
  ok "nginx proxying :80 -> 127.0.0.1:$APP_PORT"
}

# ------------------------------- https ----------------------------------------
resolve_ip() {
  local host="$1" ip=""
  command -v getent   >/dev/null 2>&1 && ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -z "$ip" ]] && command -v dig      >/dev/null 2>&1 && ip="$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
  [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1 && ip="$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
  printf '%s' "$ip"
}

setup_ssl() {
  [[ -n "$DOMAIN" ]]    || { warn "No domain configured — skipping HTTPS."; return 0; }
  [[ -n "$SSL_EMAIL" ]] || { warn "No email configured — skipping HTTPS. Run './node-deploy.sh config' then 'ssl'."; return 0; }
  step "Checking DNS for $DOMAIN"
  local resolved; resolved="$(resolve_ip "$DOMAIN")"
  if [[ -z "$resolved" ]]; then
    warn "$DOMAIN does not resolve yet. Point an A record to $SERVER_HOST, then: ./node-deploy.sh ssl"; return 0
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
exit 0
REMOTE
  ok "HTTPS live at https://$DOMAIN (auto-renew enabled)"
}

# ------------------------------- releases / rollback --------------------------
list_releases() {
  step "Releases on $SERVER_HOST"
  remote <<'REMOTE'
set -euo pipefail
CUR="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || echo none)"
cd "$WEB_ROOT/releases" 2>/dev/null || { echo "no releases yet"; exit 0; }
for d in $(ls -1d */ 2>/dev/null | sort -r); do
  d="${d%/}"; mark="  "
  [ "$(readlink -f "$d")" = "$CUR" ] && mark="->"
  printf '%s %-32s %s\n' "$mark" "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
exit 0
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
for d in $(ls -1d */ 2>/dev/null | sort -r); do
  d="${d%/}"
  [ "$(readlink -f "$d")" = "$CUR" ] && continue
  PREV="$d"; break
done
[ -n "$PREV" ] || { echo "ERROR: no previous release to roll back to"; exit 1; }
[ -f "$WEB_ROOT/releases/$PREV/package.json" ] || { echo "ERROR: $PREV looks incomplete"; exit 1; }
ln -sfn "$WEB_ROOT/releases/$PREV" "$WEB_ROOT/.current.tmp"
mv -Tf "$WEB_ROOT/.current.tmp" "$WEB_ROOT/current"
pm2 restart "$APP_NAME" --update-env >/dev/null
echo "now live: $PREV"
for i in $(seq 1 15); do
  curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$APP_PORT/" && { echo "app responded OK"; break; }
  sleep 2
done
exit 0
REMOTE
  ok "Rolled back"
  note "The next deploy builds from git again and moves forward."
}

# ------------------------------- env ------------------------------------------
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
      develop|dev)     candidates+=("$SCRIPT_DIR/.env.development") ;;
      production|prod) candidates+=("$SCRIPT_DIR/.env.production")  ;;
      staging|stage)   candidates+=("$SCRIPT_DIR/.env.staging")     ;;
    esac
  else
    candidates+=("$SCRIPT_DIR/.env.production")
  fi
  candidates+=("$SCRIPT_DIR/.env")
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# upload_env [quiet|restart]
#   quiet   — used inside setup/deploy; the build runs right after
#   restart — only server-side vars changed, so skip the rebuild
#   (default) full redeploy — reinstall, rebuild if configured, republish
upload_env() {
  local mode="${1:-}" src for_env=""
  [[ -n "${ENV_LABEL:-}" ]] && for_env=" for $ENV_LABEL"
  if ! src="$(find_env_file)"; then
    [[ "$mode" == "quiet" ]] && return 0
    warn "No env file found$for_env (looked for \$ENV_FILE, .env.${ENV_LABEL:-production}, .env)."; return 0
  fi
  if git -C "$SCRIPT_DIR" ls-files --error-unmatch "$src" >/dev/null 2>&1; then
    warn "$(basename "$src") is tracked by git — secrets are in your repo history."
  fi
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
  grep -qE '^[A-Za-z_]*(SECRET|PASSWORD|PRIVATE|_KEY|TOKEN|DATABASE_URL)' "$src" 2>/dev/null && \
    note "credentials in this file stay server-side (chmod 600 here and on the server)"

  case "$mode" in
    quiet)   return 0 ;;
    restart)
      note "restarting only — server-side variables take effect immediately"
      remote <<'REMOTE'
set -euo pipefail
: > "$WEB_ROOT/.env.export"; chmod 600 "$WEB_ROOT/.env.export"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in *=*) ;; *) continue ;; esac
  key="${line%%=*}"; val="${line#*=}"
  key="${key#export }"; key="${key//[[:space:]]/}"
  case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
  case "$val" in
    '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
    "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf 'export %s=%q\n' "$key" "$val" >> "$WEB_ROOT/.env.export"
done < "$APP_DIR/.env"
pm2 restart "$APP_NAME" --update-env >/dev/null
pm2 describe "$APP_NAME" | grep -E 'status|uptime' || true
exit 0
REMOTE
      ok "Restarted with the new environment"
      note "if your build BAKES a value in, use a full deploy instead: ./node-deploy.sh deploy ${ENV_LABEL:-}"
      ;;
    *)
      note "full redeploy — reinstall, rebuild if configured, then republish"
      deploy_app ;;
  esac
}

# ------------------------------- extras ---------------------------------------
allow_ip() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI not installed."
  [[ -n "$SG_ID" ]] || die "No SG_ID configured. Run ./node-deploy.sh config."
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
  for id in $old_ids; do
    aws ec2 revoke-security-group-ingress "${region_args[@]}" \
      --group-id "$SG_ID" --security-group-rule-ids "$id" >/dev/null
  done
  aws ec2 authorize-security-group-ingress "${region_args[@]}" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myip/32,Description=deploy.sh-ssh}]" \
    >/dev/null
  ok "Port 22 now open to $myip/32 only"
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
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOS
sudo sshd -t && sudo systemctl reload ssh
chmod 750 "$APP_DIR" 2>/dev/null || true
[ -f "$APP_DIR/.env" ] && chmod 600 "$APP_DIR/.env"
sudo fail2ban-client status sshd 2>/dev/null | head -5 || true
exit 0
REMOTE
  ok "Server hardened"
  note "You are still logged in — test ssh in a second terminal before closing this one."
}

summary() {
  local url="http://$SERVER_HOST:$APP_PORT"
  [[ -n "$DOMAIN" ]] && url="http://$DOMAIN"
  [[ -n "$DOMAIN" && -n "$SSL_EMAIL" ]] && url="https://$DOMAIN"
  local suffix=""; [[ -n "${ENV_LABEL:-}" ]] && suffix=" $ENV_LABEL"
  cat <<EOF

  ${C_G}Done.${C_0}  Your site$suffix (branch ${C_B}$GIT_BRANCH${C_0}, port ${C_B}$APP_PORT${C_0}): ${C_B}$url${C_0}

  Next time you push code:             ${C_B}./update.sh$suffix${C_0}
  Bad build went live?                 ${C_B}./node-deploy.sh rollback$suffix${C_0}
  Other commands: releases | logs | status | restart | ssl | env | ssh | config | envs
EOF
}

# ------------------------------- commands -------------------------------------
cmd_envs() {
  local envs; envs="$(list_envs)"
  if [[ -z "$envs" ]]; then
    [[ -f "$SCRIPT_DIR/node-deploy.conf" ]] && { echo "  single environment (node-deploy.conf)"; return 0; }
    warn "No environments configured yet. Run: ./node-deploy.sh setup"; return 0
  fi
  printf '\n  %-14s %-12s %-7s %s\n' "ENVIRONMENT" "BRANCH" "PORT" "DOMAIN"
  printf '  %-14s %-12s %-7s %s\n'   "-----------" "------" "----" "------"
  local e f b d p
  while read -r e; do
    [[ -z "$e" ]] && continue
    f="$SCRIPT_DIR/node-deploy.$e.conf"
    b="$(sed -n 's/^GIT_BRANCH=//p' "$f" | tr -d "\"'")"
    d="$(sed -n 's/^DOMAIN=//p'     "$f" | tr -d "\"'")"
    p="$(sed -n 's/^APP_PORT=//p'   "$f" | tr -d "\"'")"
    printf '  %-14s %-12s %-7s %s\n' "$e" "$b" "$p" "${d:-(ip only)}"
  done <<< "$envs"
  echo
}

cmd_setup() {
  if [[ -z "$CONFIG_FILE_PINNED" && ! -f "$CONFIG_FILE" && -z "$(list_envs)" ]]; then
    local n=""
    cat <<'EOF'

  How many environments do you want?

    1   production only          main -> your live domain
    2   + develop                develop -> its own domain
    3   + staging                staging -> its own domain
    4+  qa, uat, demo, preview, then env5, env6, ...

  Each gets its own branch, domain, PORT, pm2 process and release history.
  Note: each environment is a running process — budget roughly
  150 MB of RAM and 320 MB of disk for each one.

EOF
    while :; do
      ask n "Number of environments" "1"
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) && break
      warn "Enter a whole number between 1 and 20."; n=""
    done
    if (( n > 1 )); then multi_env_wizard "$n"; return 0; fi
  fi
  load_config
  [[ -f "$CONFIG_FILE" ]] && { read -r -p "  Config found. Reuse saved answers? (Y/n): " a; [[ "$a" =~ ^[Nn] ]] && wizard || true; } || wizard
  [[ -f "$CONFIG_FILE" ]] || wizard
  init_ssh; preflight; provision; configure_git
  upload_env quiet; deploy_app
  configure_nginx; setup_ssl; summary
}
cmd_deploy()   { load_config; verify_repo_and_branch strict; init_ssh; configure_git; upload_env quiet; deploy_app; summary; }
cmd_rollback() { load_config; init_ssh; rollback; }
cmd_releases() { load_config; init_ssh; list_releases; }
cmd_ssl()      { load_config; init_ssh; configure_nginx; setup_ssl; }
cmd_nginx()    { load_config; init_ssh; configure_nginx; }
cmd_env()      { load_config; init_ssh; upload_env "${ENV_MODE:-}"; }
cmd_allowip()  { load_config; allow_ip; }
cmd_harden()   { load_config; init_ssh; harden_server; }
cmd_config()   { load_config; wizard; }
cmd_ssh()      { load_config; init_ssh; remote_tty "cd '$APP_DIR' 2>/dev/null; exec bash -l"; }
cmd_logs()     { load_config; init_ssh; remote_tty "pm2 logs '$APP_NAME' --lines 100"; }
cmd_restart()  { load_config; init_ssh; remote_tty "pm2 restart '$APP_NAME' --update-env && pm2 status"; }
cmd_status()   {
  load_config; init_ssh
  remote <<'REMOTE'
echo "=== pm2 ==="; pm2 describe "$APP_NAME" 2>/dev/null | grep -E 'status|uptime|restarts|memory|cpu' || echo "not running"
echo; echo "=== live release ==="
echo "$WEB_ROOT/current -> $(readlink -f "$WEB_ROOT/current" 2>/dev/null || echo '(not published yet)')"
echo "kept releases: $(ls -1d "$WEB_ROOT"/releases/*/ 2>/dev/null | wc -l)"
echo; echo "=== port $APP_PORT ==="
curl -fsS -o /dev/null -w "  local HTTP %{http_code} in %{time_total}s\n" --max-time 5 "http://127.0.0.1:$APP_PORT/" || echo "  not responding"
echo; echo "=== nginx ==="; systemctl is-active nginx
echo; echo "=== disk ==="; df -h / | tail -1
echo; echo "=== memory ==="; free -h | head -2
echo; echo "=== last commit ==="; git -C "$APP_DIR" log -1 --pretty='%h %s (%cr)' 2>/dev/null || echo "no repo yet"
exit 0
REMOTE
}

usage() { sed -n '3,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ------------------------------- dispatch -------------------------------------
CMD="${1:-setup}"
ENV_NAME="${2:-${DEPLOY_ENV:-}}"

# Arguments are "<command> <environment>", but "./node-deploy.sh main" reads
# naturally as "act on main" — so catch that instead of complaining that no
# environment was named for a command called "main".
case "$CMD" in
  setup|deploy|rollback|releases|ssl|nginx|env|config|logs|status|restart|ssh|envs|list|allow-ip|allowip|harden|-h|--help|help) ;;
  *)
    if [[ -f "$SCRIPT_DIR/node-deploy.$CMD.conf" ]]; then
      die "'$CMD' is an environment, not a command. Put the command first:
       ./node-deploy.sh setup $CMD      provision it
       ./node-deploy.sh deploy $CMD     build and publish
       ./node-deploy.sh status $CMD     what is running
       ./update.sh $CMD                 the usual one"
    fi
    ;;
esac

if [[ "$ENV_NAME" == "all" ]]; then
  all_envs="$(list_envs)"
  [[ -n "$all_envs" ]] || die "No environments configured. Run: ./node-deploy.sh setup"
  while read -r e; do
    [[ -z "$e" ]] && continue
    printf '\n%s########  %s : %s  ########%s\n' "$C_B" "$CMD" "$e" "$C_0"
    "${BASH_SOURCE[0]}" "$CMD" "$e" || die "Failed on environment '$e'"
  done <<< "$all_envs"
  exit 0
fi

case "$CMD" in
  envs|list|-h|--help|help) : ;;
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
  *) die "Unknown command '$CMD'. Try: ./node-deploy.sh help" ;;
esac
