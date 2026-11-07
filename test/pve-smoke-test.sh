#!/usr/bin/env bash
# Run this ON THE PROXMOX HOST after install/slopify.sh finished.
# It proves the reboot requirement: services come back on their own and both
# web UIs answer again.
#
#   test/pve-smoke-test.sh <CTID> [--no-reboot]
set -Eeuo pipefail

CTID="${1:-}"
MODE="${2:-}"
[[ -n "$CTID" ]] || { echo "Usage: $0 <CTID> [--no-reboot]" >&2; exit 2; }
pct status "$CTID" >/dev/null 2>&1 || { echo "CT $CTID existiert nicht" >&2; exit 2; }

GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RST=$'\033[0m'
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RST" "$*"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RST" "$*"; exit 1; }
say()  { printf '\n%s%s%s\n' "$BOLD" "$*" "$RST"; }

APP_PORT=$(pct exec "$CTID" -- bash -c "sed -n 's/^APP_PORT=//p' /opt/slopify/.env")
FILES_PORT=$(pct exec "$CTID" -- bash -c "sed -n 's/^FILES_PORT=//p' /etc/default/slopify-files")
IP=$(pct exec "$CTID" -- bash -c "hostname -I | awk '{print \$1}'")
CREDS=$(pct exec "$CTID" -- cat /root/slopify-credentials.txt 2>/dev/null || true)
APP_USER=$(printf '%s\n' "$CREDS" | sed -n 's/^SLOPIFY_USER=//p' | head -n1)
FILES_USER=$(printf '%s\n' "$CREDS" | sed -n 's/^FILES_USER=//p' | head -n1)
FILES_PASS=$(printf '%s\n' "$CREDS" | sed -n 's/^FILES_PASS=//p' | head -n1)
[[ -n "$APP_PORT" && -n "$FILES_PORT" && -n "$IP" ]] || fail "Ports/IP nicht ermittelbar"
echo "CT $CTID · IP $IP · App $APP_PORT · Dateien $FILES_PORT"
echo "Zugangsdaten: /root/slopify-credentials.txt im CT (Slopify-Benutzer: ${APP_USER:-unbekannt}, Dateimanager: ${FILES_USER:-unbekannt})"

# check <url> <name> [expected-code] [tries] [user:pass]
check() {
  local url=$1 name=$2 want=${3:-200} tries=${4:-60} auth=${5:-} i code
  for ((i = 1; i <= tries; i++)); do
    if [[ -n "$auth" ]]; then
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "$auth" "$url" 2>/dev/null || true)
    else
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    fi
    if [[ "$code" == "$want" ]]; then pass "$name erreichbar ($url -> HTTP $code)"; return 0; fi
    sleep 2
  done
  fail "$name antwortet nicht wie erwartet ($url, erwartet HTTP $want, zuletzt ${code:-keine Antwort})"
}

check_files_ui() { # dufs: must be closed (401) and must accept the login (200)
  check "http://$IP:$FILES_PORT/" "Dateimanager ohne Login geschützt" 401 60
  if [[ -n "$FILES_USER" && -n "$FILES_PASS" ]]; then
    check "http://$IP:$FILES_PORT/" "Dateimanager mit Login" 200 20 "$FILES_USER:$FILES_PASS"
  else
    pass "Dateimanager-Login nicht geprüft (Zugangsdaten nicht lesbar)"
  fi
}

check_services() {
  for unit in slopify.service slopify-files.service; do
    state=$(pct exec "$CTID" -- systemctl is-active "$unit" || true)
    [[ "$state" == "active" ]] && pass "$unit = active" || fail "$unit = ${state:-unbekannt}"
  done
}

say "1) Zustand vor dem Reboot"
check_services
check "http://$IP:$APP_PORT/api/healthz" "Slopify"
check_files_ui

if [[ "$MODE" == "--no-reboot" ]]; then
  say "2) Reboot übersprungen (--no-reboot)"
  exit 0
fi

say "2) Container neu starten (wie ein Proxmox-Host-Reboot)"
UPTIME_BEFORE=$(pct exec "$CTID" -- cat /proc/uptime | awk '{print $1}')
pct reboot "$CTID"
for _ in {1..60}; do
  [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] && break
  sleep 1
done
sleep 5
UPTIME_AFTER=$(pct exec "$CTID" -- cat /proc/uptime | awk '{print $1}')
awk -v b="$UPTIME_BEFORE" -v a="$UPTIME_AFTER" 'BEGIN { exit (a < b) ? 0 : 1 }' \
  && pass "Container wurde tatsächlich neu gestartet (uptime $UPTIME_BEFORE s -> $UPTIME_AFTER s)" \
  || fail "Kein Neustart erkennbar (uptime $UPTIME_BEFORE s -> $UPTIME_AFTER s)"

say "3) Nach dem Reboot: Services und Web-UI"
check_services
check "http://$IP:$APP_PORT/api/healthz" "Slopify" 200 120
check_files_ui

say "4) Beweis aus den Logs"
pct exec "$CTID" -- bash -c 'systemctl --no-pager --full status slopify.service slopify-files.service | head -n 30' || true
pct exec "$CTID" -- bash -c "journalctl -u slopify.service -u slopify-files.service --since '-3 min' --no-pager | tail -n 40" || true

printf '\n%sReboot-Test bestanden.%s\n' "$GREEN" "$RST"
