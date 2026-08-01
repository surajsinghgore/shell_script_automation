#!/usr/bin/env bash
# ==============================================================================
#  healthcheck.sh — runs ON THE SERVER from cron. Checks every site this box
#  serves and shouts if one is down or the disk is filling.
#
#  Install:  ./ops/install-healthcheck.sh        (from your laptop)
#  Manually: /home/ubuntu/ops/healthcheck.sh
#  Log:      /var/log/healthcheck.log
#
#  It discovers sites from nginx's own config rather than a list you have to
#  maintain, so a site added tomorrow is checked tomorrow.
# ==============================================================================

set -uo pipefail

LOG=/var/log/healthcheck.log
DISK_WARN_PCT=90
STAMP="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
PROBLEMS=()

log() { printf '%s %s\n' "$STAMP" "$*" >> "$LOG"; }

# ---- every server_name nginx is configured to answer for ---------------------
# -R, not -r: entries in sites-enabled are symlinks into sites-available, and
# lowercase -r skips symlinks entirely, so this silently found nothing.
SITES="$(grep -RhoP '(?<=server_name\s)[^;]+' /etc/nginx/sites-enabled/ 2>/dev/null \
  | tr ' ' '\n' | grep -vE '^\s*$|^_$|^www\.' | sort -u)"

for host in $SITES; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/" 2>/dev/null)"
  # Anything that answers is alive. 4xx can be a legitimate route response;
  # 000 (no answer) and 5xx are what actually indicate a broken deploy.
  case "$code" in
    000)     PROBLEMS+=("$host UNREACHABLE"); log "FAIL $host no response" ;;
    5*)      PROBLEMS+=("$host HTTP $code");  log "FAIL $host HTTP $code" ;;
    *)       log "ok   $host HTTP $code" ;;
  esac
done

# ---- pm2 processes that should be online -------------------------------------
# Parsed from `pm2 jlist`, not the table: the pretty output uses box-drawing
# characters, its column order shifts between pm2 versions, and modules like
# pm2-logrotate appear in a second table. JSON has none of those problems.
if command -v pm2 >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  while IFS='=' read -r name status; do
    [ -z "$name" ] && continue
    if [ "$status" != "online" ]; then
      PROBLEMS+=("pm2:$name $status"); log "FAIL pm2 $name is $status"
    else
      log "ok   pm2 $name online"
    fi
  done < <(pm2 jlist 2>/dev/null | node -e '
    let s="";
    process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a=[]; try{a=JSON.parse(s)}catch(e){}
      for(const p of a) console.log(p.name+"="+((p.pm2_env||{}).status||"unknown"));
    });' 2>/dev/null || true)
fi

# ---- disk --------------------------------------------------------------------
PCT="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
FREE="$(df -Pm / | awk 'NR==2{print $4}')"
if [ "${PCT:-0}" -ge "$DISK_WARN_PCT" ]; then
  PROBLEMS+=("disk ${PCT}% (${FREE}MB free)")
  log "FAIL disk ${PCT}% full, ${FREE}MB free"
else
  log "ok   disk ${PCT}% (${FREE}MB free)"
fi

# ---- report ------------------------------------------------------------------
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  printf '%s PROBLEMS: %s\n' "$STAMP" "${PROBLEMS[*]}" >> "$LOG"
  # cron mails stdout to the local user if a mail transport exists; harmless if
  # not, and `journalctl -t healthcheck` picks it up either way.
  logger -t healthcheck "PROBLEMS: ${PROBLEMS[*]}"
  echo "healthcheck: ${PROBLEMS[*]}"
  exit 1
fi

logger -t healthcheck "all ok"
exit 0
