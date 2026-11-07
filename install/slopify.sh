#!/usr/bin/env bash
# =============================================================================
#  slopify-lxc – one-shot Proxmox VE installer for Slopify
#
#  Creates a Debian LXC, installs Docker + Slopify + dufs, wires
#  systemd units, and verifies that both web UIs answer.
#
#  Quick start (root on the Proxmox host):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/slopify-lxc/main/install/slopify.sh)"
#
#  Everything is configurable:
#     ... | bash -s -- --id 121 --music-path /tank/music --ram 4096 --disk 32
#
#  Flags: --help
# =============================================================================
set -Eeuo pipefail

APP_NAME="slopify"
APP_TITLE="Slopify"
# Where the payload files (compose.yml, units, in-container installer) live.
REPO_RAW="${SLOPIFY_REPO_RAW:-https://raw.githubusercontent.com/YOUR_GITHUB_USER/slopify-lxc/main}"

# --- defaults (override with flags or environment) ---------------------------
CT_ID="${CT_ID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-slopify}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
# The Slopify image alone is ~4.5 GB. 8 GB is not enough for image + Docker +
# database + caches; 24 GB is the honest minimum, 32 GB is comfortable.
DISK_GB="${DISK_GB:-24}"
STORAGE="${STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
CT_CIDR="${CT_CIDR:-}"          # empty = DHCP
CT_GW="${CT_GW:-}"
MUSIC_PATH="${MUSIC_PATH:-/srv/slopify/music}"
APP_PORT="${APP_PORT:-8080}"
FILES_PORT="${FILES_PORT:-8081}"
TZ_VALUE="${TZ_VALUE:-Europe/Berlin}"
LANGUAGE="${LANGUAGE:-de}"
SLOPIFY_TAG="${SLOPIFY_TAG:-latest}"
DUFS_VERSION="${DUFS_VERSION:-v0.47.0}"
TRANSCODE_CACHE_GB="${TRANSCODE_CACHE_GB:-8}"
TRANSCODE_CONCURRENCY="${TRANSCODE_CONCURRENCY:-2}"
SCAN_PAUSE_MS="${SCAN_PAUSE_MS:-20}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
FILES_ADMIN_USER="${FILES_ADMIN_USER:-admin}"
FILES_ADMIN_PASS="${FILES_ADMIN_PASS:-}"

DRY_RUN=0
DEBUG=0
UNINSTALL=0
ASSUME_YES=0

# --- output ------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi
msg()  { printf '%s[%s]%s %s\n' "$C_INFO" "$APP_NAME" "$C_RESET" "$*"; }
ok()   { printf '%s[   ok   ]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s[ warn  ]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die()  { printf '%s[ fail  ]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}${APP_TITLE} – Proxmox VE installer${C_RESET}

Usage: bash install/slopify.sh [options]

  --id N              Container ID (default: next free >= 100)
  --hostname NAME     Container hostname (default: $CT_HOSTNAME)
  --cores N           vCPUs (default: $CORES)
  --ram MB            RAM in MB (default: $RAM_MB)
  --disk GB           Root disk in GB (default: $DISK_GB, min 16)
  --storage NAME      Storage for the root disk (default: auto -> local-lvm/local)
  --bridge NAME       Network bridge (default: $BRIDGE)
  --ip CIDR           Static address, e.g. 192.168.1.50/24 (default: DHCP)
  --gw IP             Gateway for the static address
  --music-path PATH   Host folder shared as /music, or "none" to keep music
                      on the container disk (default: $MUSIC_PATH)
  --app-port N        Slopify port (default: $APP_PORT)
  --files-port N      Dateimanager-Port (default: $FILES_PORT)
  --tz TZ             Timezone (default: $TZ_VALUE)
  --language XX       App language (default: $LANGUAGE)
  --tag TAG           Slopify image tag (default: $SLOPIFY_TAG)
  --admin-pass PASS   Initial Slopify admin password (default: generated)
  --files-user USER   Login des Dateimanagers (default: $FILES_ADMIN_USER)
  --files-pass PASS   Passwort des Dateimanagers (default: generated)
  --debug             Run with bash -x and keep the full trace
  --dry-run           Print every step without touching the host
  --uninstall         Destroy the container (music folder on the host is kept)
  --yes               Do not ask for confirmation (uninstall)
  -h, --help          This help

Re-running with the same --id is safe (idempotent): it updates the stack,
keeps passwords and data, and restarts the services.
EOF
}

# --- logging -----------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  LOG_DIR=/var/log/slopify-lxc
else
  LOG_DIR="${TMPDIR:-/tmp}/slopify-lxc-logs"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
ln -sfn "$LOG_FILE" "$LOG_DIR/latest.log" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

# --- argument parsing (before the trap so --help works) ----------------------
ORIG_ARGS=$(printf '%q ' "$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)            CT_ID="$2"; shift 2 ;;
    --hostname)      CT_HOSTNAME="$2"; shift 2 ;;
    --cores)         CORES="$2"; shift 2 ;;
    --ram)           RAM_MB="$2"; shift 2 ;;
    --disk)          DISK_GB="$2"; shift 2 ;;
    --storage)       STORAGE="$2"; shift 2 ;;
    --bridge)        BRIDGE="$2"; shift 2 ;;
    --ip)            CT_CIDR="$2"; shift 2 ;;
    --gw)            CT_GW="$2"; shift 2 ;;
    --music-path)    MUSIC_PATH="$2"; shift 2 ;;
    --app-port)      APP_PORT="$2"; shift 2 ;;
    --files-port)    FILES_PORT="$2"; shift 2 ;;
    --tz|--timezone) TZ_VALUE="$2"; shift 2 ;;
    --language)      LANGUAGE="$2"; shift 2 ;;
    --tag)           SLOPIFY_TAG="$2"; shift 2 ;;
    --admin-pass)    ADMIN_PASS="$2"; shift 2 ;;
    --files-user)    FILES_ADMIN_USER="$2"; shift 2 ;;
    --files-pass)    FILES_ADMIN_PASS="$2"; shift 2 ;;
    --debug)         DEBUG=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

if [[ $DEBUG -eq 1 ]]; then
  PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
fi

# --- error handling: full chain, never just one line -------------------------
on_error() {
  local code=$1 line=$2 cmd=$3
  trap - ERR
  {
    printf '\n%s================ INSTALLATIONSFEHLER ================%s\n' "$C_ERR" "$C_RESET"
    printf 'Exit-Code : %s\n' "$code"
    printf 'Ort       : %s\n' "$line"
    printf 'Befehl    : %s\n' "$cmd"
    printf 'CT-ID     : %s\n' "${CT_ID:-<noch nicht vergeben>}"
    printf 'Logdatei  : %s\n' "$LOG_FILE"
    printf '\n--- Proxmox ---\n'
    pveversion 2>&1 || true
    printf '\n--- pvesm status ---\n'
    pvesm status 2>&1 || true
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" >/dev/null 2>&1; then
      printf '\n--- pct config %s ---\n' "$CT_ID"
      pct config "$CT_ID" 2>&1 || true
      printf '\n--- systemd (Container) ---\n'
      pct exec "$CT_ID" -- bash -c 'systemctl --no-pager --full status slopify.service slopify-files.service 2>&1 | head -n 80' || true
      printf '\n--- journal (Container, letzte 120 Zeilen) ---\n'
      pct exec "$CT_ID" -- bash -c 'journalctl -u slopify.service -u slopify-files.service -n 120 --no-pager 2>&1' || true
      printf '\n--- docker compose (Container) ---\n'
      pct exec "$CT_ID" -- bash -c 'cd /opt/slopify 2>/dev/null && docker compose --env-file .env -f compose.yml ps -a 2>&1; docker compose --env-file .env -f compose.yml logs --tail=120 2>&1' || true
      printf '\n--- Platz / RAM (Container) ---\n'
      pct exec "$CT_ID" -- bash -c 'df -h / /var/lib/docker 2>&1; free -m 2>&1' || true
      printf '\n--- Installer-Log (Container, letzte 80 Zeilen) ---\n'
      pct exec "$CT_ID" -- bash -c 'tail -n 80 /var/log/slopify-install.log 2>&1' || true
    fi
    printf '\nNächster Schritt: erneut mit vollem Trace ausführen:\n'
    printf '  bash -x %s %s\n' "$0" "$ORIG_ARGS"
    printf '%s=====================================================%s\n' "$C_ERR" "$C_RESET"
  } >&2
  exit "$code"
}
trap 'on_error $? "$(caller 0 2>/dev/null || echo "?" )" "$BASH_COMMAND"' ERR

# --- helpers -----------------------------------------------------------------
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  %s[dry-run]%s' "$C_WARN" "$C_RESET"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 )); }
valid_id()   { [[ "$1" =~ ^[0-9]+$ ]] && (( 100 <= $1 && $1 <= 999999 )); }

fetch_payload() { # fetch_payload <relative/path> <destination>
  local rel=$1 dest=$2
  if [[ -n "${SLOPIFY_LOCAL_DIR:-}" && -f "$SLOPIFY_LOCAL_DIR/$rel" ]]; then
    cp "$SLOPIFY_LOCAL_DIR/$rel" "$dest"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$REPO_RAW/$rel" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$REPO_RAW/$rel" || true
  fi
  if [[ ! -s "$dest" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "DRY-RUN: $rel nicht ladbar (Repo-Platzhalter?) – benutze Platzhalter."
      printf '# dry-run placeholder\n' > "$dest"
      return 0
    fi
    die "Download fehlgeschlagen oder leer: $REPO_RAW/$rel – GitHub-Benutzer/Repo in REPO_RAW korrekt?"
  fi
}

next_free_id() {
  local id
  for ((id = 100; id < 1000; id++)); do
    if ! pct status "$id" >/dev/null 2>&1; then printf '%s\n' "$id"; return 0; fi
  done
  return 1
}

# --- local checkout auto-detection (bash install/slopify.sh) -----------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || echo "")"
if [[ -z "${SLOPIFY_LOCAL_DIR:-}" && -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../scripts/install-inside.sh" ]]; then
  SLOPIFY_LOCAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# --- preflight ---------------------------------------------------------------
step "0/8  Vorprüfung"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
  [[ -d /etc/pve ]] || die "Das sieht nicht nach einem Proxmox-Host aus (/etc/pve fehlt)."
  command -v pct >/dev/null 2>&1 || die "pct nicht gefunden – bitte auf dem PVE-Host ausführen."
  command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden – bitte auf dem PVE-Host ausführen."
  [[ "$(uname -m)" == "x86_64" ]] || warn "Slopify wird nur als amd64-Image veröffentlicht (Host: $(uname -m))."
else
  warn "DRY-RUN: es wird nichts verändert."
fi

valid_port "$APP_PORT" || die "Ungültiger --app-port: $APP_PORT"
valid_port "$FILES_PORT" || die "Ungültiger --files-port: $FILES_PORT"
[[ "$APP_PORT" != "$FILES_PORT" ]] || die "App- und Datei-Port müssen unterschiedlich sein."
if [[ ! "$RAM_MB" =~ ^[0-9]+$ ]] || (( RAM_MB < 1024 )); then die "--ram muss >= 1024 sein."; fi
if [[ ! "$CORES" =~ ^[0-9]+$ ]] || (( CORES < 1 )); then die "--cores muss >= 1 sein."; fi
if [[ ! "$DISK_GB" =~ ^[0-9]+$ ]] || (( DISK_GB < 16 )); then
  die "--disk muss >= 16 GB sein (Slopify-Image allein ~4,5 GB)."
fi
[[ -z "$CT_ID" ]] || valid_id "$CT_ID" || die "--id muss zwischen 100 und 999999 liegen."

# Passwords end up in /opt/slopify/.env – keep them shell/ini-safe.
PW_RE='^[A-Za-z0-9._@%+=:,/-]+$'
if [[ -n "$ADMIN_PASS" && ! "$ADMIN_PASS" =~ $PW_RE ]]; then
  die "--admin-pass darf nur A-Z a-z 0-9 . _ @ % + = : , / - enthalten."
fi
if [[ -n "$FILES_ADMIN_PASS" && ! "$FILES_ADMIN_PASS" =~ $PW_RE ]]; then
  die "--files-pass darf nur A-Z a-z 0-9 . _ @ % + = : , / - enthalten."
fi

if [[ $DRY_RUN -eq 1 && -z "$CT_ID" ]]; then
  CT_ID=100
  warn "DRY-RUN: nehme CT-ID 100 an."
fi

# --- uninstall ---------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  step "Deinstallation"
  [[ -n "$CT_ID" ]] || die "Für --uninstall bitte die CT-ID angeben: --id <ID> --uninstall"
  if [[ $DRY_RUN -eq 1 ]]; then run pct destroy "$CT_ID" --force; exit 0; fi
  pct status "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID existiert nicht."
  if [[ $ASSUME_YES -eq 0 ]]; then
    printf 'CT %s (%s) wird gelöscht. Musikordner %s auf dem Host bleibt erhalten.\n' \
      "$CT_ID" "$CT_HOSTNAME" "$MUSIC_PATH"
    read -r -p "Wirklich? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || die "Abgebrochen."
  fi
  pct stop "$CT_ID" >/dev/null 2>&1 || true
  run pct destroy "$CT_ID" --force
  ok "CT $CT_ID entfernt. Musik unter $MUSIC_PATH ist unverändert."
  exit 0
fi

if [[ -z "$CT_ID" ]]; then
  CT_ID=$(next_free_id) || die "Keine freie CT-ID gefunden."
  ok "Freie CT-ID: $CT_ID"
fi


# existing container? -> reuse, but never touch a foreign one
CT_EXISTS=0
if [[ $DRY_RUN -eq 0 ]] && pct status "$CT_ID" >/dev/null 2>&1; then
  CT_EXISTS=1
  EXISTING_HOSTNAME=$(pct config "$CT_ID" | sed -n 's/^hostname: //p')
  if [[ "$EXISTING_HOSTNAME" != "$CT_HOSTNAME" ]]; then
    die "CT $CT_ID existiert bereits, heißt aber '$EXISTING_HOSTNAME' (erwartet: '$CT_HOSTNAME'). Nichts wurde verändert. Andere --id wählen."
  fi
  ok "CT $CT_ID existiert bereits – Update-Modus (Daten und Passwörter bleiben erhalten)"
else
  ok "Neuer Container wird angelegt (ID ${CT_ID})"
fi
ok "Vorprüfung abgeschlossen"

# --- storage + template ------------------------------------------------------
step "1/8  Storage und Template"
if [[ -z "$STORAGE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    STORAGE=local-lvm
  elif pvesm status -storage local-lvm >/dev/null 2>&1; then
    STORAGE=local-lvm
  elif pvesm status -storage local >/dev/null 2>&1; then
    STORAGE=local
  else
    die "Kein passender Storage gefunden. Bitte --storage angeben (pvesm status)."
  fi
fi
if [[ $DRY_RUN -eq 0 ]]; then
  pvesm status -storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' nicht verfügbar (pvesm status)."
fi

TEMPLATE=""
if [[ $DRY_RUN -eq 0 ]]; then
  TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/ {print $1}' | sort -V | tail -1)
  if [[ -z "$TEMPLATE" ]]; then
    msg "Debian-12-Template fehlt – lade es nach (pveam update)."
    pveam update >/dev/null
    AVAILABLE=$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $1}' | sort -V | tail -1)
    [[ -n "$AVAILABLE" ]] || die "Kein debian-12-standard-Template verfügbar (pveam available --section system)."
    pveam download "$TEMPLATE_STORAGE" "$AVAILABLE"
    TEMPLATE="$TEMPLATE_STORAGE:vztmpl/$AVAILABLE"
  fi
else
  TEMPLATE="$TEMPLATE_STORAGE:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
fi
ok "Storage: $STORAGE · Template: $TEMPLATE"

# --- payload -----------------------------------------------------------------
step "2/8  Payload vorbereiten"
PAYLOAD_DIR=$(mktemp -d)
cleanup() { rm -rf "$PAYLOAD_DIR"; }
trap 'cleanup' EXIT
PAYLOAD_FILES=(scripts/install-inside.sh config/compose.yml config/slopify.service config/slopify-files.service)
for rel in "${PAYLOAD_FILES[@]}"; do
  fetch_payload "$rel" "$PAYLOAD_DIR/$(basename "$rel")"
done
ok "4 Dateien bereit ($([[ -n "${SLOPIFY_LOCAL_DIR:-}" ]] && echo "lokales Repo" || echo "$REPO_RAW"))"

# --- create / configure container -------------------------------------------
step "3/8  Container erstellen und konfigurieren"
if [[ $CT_EXISTS -eq 0 ]]; then
  NET_CONF="ip=dhcp"
  if [[ -n "$CT_CIDR" ]]; then
    NET_CONF="ip=${CT_CIDR}"
    [[ -n "$CT_GW" ]] && NET_CONF+=",gw=${CT_GW}"
  fi
  run pct create "$CT_ID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap "$((RAM_MB / 2))" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CONF}" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 1 \
    --tags "slopify,music" \
    --description "Slopify music server + upload UI (slopify-lxc)"
  ok "CT $CT_ID angelegt (${CORES} vCPU, ${RAM_MB} MB RAM, ${DISK_GB} GB Disk, ${BRIDGE})"
else
  run pct set "$CT_ID" --onboot 1 --cores "$CORES" --memory "$RAM_MB" || \
    warn "Ressourcen konnten nicht live angepasst werden – greift beim nächsten Neustart des CT."
  run pct set "$CT_ID" --features nesting=1,keyctl=1 || \
    warn "Features konnten nicht gesetzt werden (laufender CT?) – bitte CT einmal neu starten."
  ok "Bestehender CT aktualisiert (Features, Autostart, Ressourcen)"
fi

if [[ "$MUSIC_PATH" != "none" ]]; then
  [[ "$MUSIC_PATH" = /* ]] || die "--music-path muss ein absoluter Pfad sein (oder 'none')."
  [[ "$MUSIC_PATH" != *,* ]] || die "--music-path darf kein Komma enthalten (Proxmox-Mountpoint-Syntax)."
fi

# --- music folder ------------------------------------------------------------
step "4/8  Musikordner einbinden"
MP_CHANGED=0
if [[ "$MUSIC_PATH" == "none" ]]; then
  warn "--music-path none: Musik liegt auf der Container-Disk (Uploads verbrauchen CT-Platz)."
else
  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$MUSIC_PATH"
    # unprivileged LXC: container uid 1000 == host uid 101000
    chown 101000:101000 "$MUSIC_PATH"
    chmod 0775 "$MUSIC_PATH"
  else
    run mkdir -p "$MUSIC_PATH"
  fi

  EXISTING_MP=""
  if [[ $DRY_RUN -eq 0 ]]; then
    EXISTING_MP=$(pct config "$CT_ID" | sed -n 's/^mp0: //p')
  fi

  if [[ -z "$EXISTING_MP" ]]; then
    # Adding a mount point to a running container is unreliable; stop it and
    # let step 5 start it again with the mount in place.
    if [[ $DRY_RUN -eq 0 ]] && [[ "$(pct status "$CT_ID" | awk '{print $2}')" == "running" ]]; then
      msg "CT läuft – wird für den neuen Mountpoint kurz gestoppt."
      pct stop "$CT_ID"
    fi
    run pct set "$CT_ID" --mp0 "$MUSIC_PATH,mp=/music"
    MP_CHANGED=1
    ok "Host-Ordner $MUSIC_PATH -> /music (rw, für Uploads)"
  elif [[ "$EXISTING_MP" == "$MUSIC_PATH"* ]]; then
    ok "Mountpoint unverändert: $EXISTING_MP"
  else
    die "CT $CT_ID hat bereits mp0 = '$EXISTING_MP'. Erwartet: '$MUSIC_PATH'. Nichts geändert – bitte --music-path '$EXISTING_MP' verwenden oder den Mountpoint manuell entfernen."
  fi
fi

# --- start container ---------------------------------------------------------
step "5/8  Container starten"
if [[ $DRY_RUN -eq 0 ]]; then
  if [[ "$(pct status "$CT_ID" | awk '{print $2}')" != "running" ]]; then
    run pct start "$CT_ID"
  elif [[ $MP_CHANGED -eq 1 ]]; then
    msg "Mountpoint wurde hinzugefügt – Container wird neu gestartet."
    run pct reboot "$CT_ID"
  fi

  for i in {1..60}; do
    [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" == "running" ]] && break
    sleep 2
  done
  [[ "$(pct status "$CT_ID" | awk '{print $2}')" == "running" ]] || die "CT $CT_ID startet nicht (pct status)."

  msg "Warte auf Netzwerk im Container ..."
  for i in {1..90}; do
    if pct exec "$CT_ID" -- bash -c 'ip -4 -o addr show dev eth0 2>/dev/null | grep -q "inet "' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  pct exec "$CT_ID" -- bash -c 'ip -4 -o addr show dev eth0 | grep -q "inet "' \
    || die "Container hat keine IPv4-Adresse (DHCP/Bridge prüfen: pct config $CT_ID)."

  for i in {1..30}; do
    pct exec "$CT_ID" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1' && break
    sleep 2
  done
  ok "Container läuft und hat Netz"
else
  run pct status "$CT_ID"
fi

# --- push payload + run installer -------------------------------------------
step "6/8  Installation im Container"
if [[ $DRY_RUN -eq 0 ]]; then
  pct exec "$CT_ID" -- mkdir -p /root/slopify-payload
  for rel in "${PAYLOAD_FILES[@]}"; do
    pct push "$CT_ID" "$PAYLOAD_DIR/$(basename "$rel")" "/root/slopify-payload/$(basename "$rel")" --perms 0644
  done
  ok "Payload in den Container kopiert"

  # Preserve passwords on re-runs.
  CREDS_FILE_CONTENT=""
  if pct exec "$CT_ID" -- test -f /root/slopify-credentials.txt >/dev/null 2>&1; then
    CREDS_FILE_CONTENT=$(pct exec "$CT_ID" -- cat /root/slopify-credentials.txt || true)
  fi
  ENV_ADMIN_PASS=""
  if pct exec "$CT_ID" -- test -f /opt/slopify/.env >/dev/null 2>&1; then
    ENV_ADMIN_PASS=$(pct exec "$CT_ID" -- sed -n 's/^ADMIN_PASS=//p' /opt/slopify/.env | head -n1 || true)
  fi
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS=$(printf '%s\n' "$CREDS_FILE_CONTENT" | sed -n 's/^SLOPIFY_PASS=//p' | head -n1)
  fi
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$ENV_ADMIN_PASS"
  fi
  if [[ -z "$FILES_ADMIN_PASS" ]]; then
    FILES_ADMIN_PASS=$(printf '%s\n' "$CREDS_FILE_CONTENT" | sed -n 's/^FILES_PASS=//p' | head -n1)
  fi
  [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS=$(gen_pass)
  [[ -n "$FILES_ADMIN_PASS" ]] || FILES_ADMIN_PASS=$(gen_pass)

  PCT_ENV=(
    env
    "APP_PORT=$APP_PORT"
    "FILES_PORT=$FILES_PORT"
    "TZ=$TZ_VALUE"
    "LANGUAGE=$LANGUAGE"
    "SLOPIFY_TAG=$SLOPIFY_TAG"
    "DUFS_VERSION=$DUFS_VERSION"
    "TRANSCODE_CACHE_GB=$TRANSCODE_CACHE_GB"
    "TRANSCODE_CONCURRENCY=$TRANSCODE_CONCURRENCY"
    "SCAN_PAUSE_MS=$SCAN_PAUSE_MS"
    "ADMIN_USER=$ADMIN_USER"
    "ADMIN_PASS=$ADMIN_PASS"
    "FILES_ADMIN_USER=$FILES_ADMIN_USER"
    "FILES_ADMIN_PASS=$FILES_ADMIN_PASS"
    "MUSIC_DIR=/music"
  )
  run pct exec "$CT_ID" -- "${PCT_ENV[@]}" bash /root/slopify-payload/install-inside.sh
else
  run pct exec "$CT_ID" -- env "APP_PORT=$APP_PORT" "FILES_PORT=$FILES_PORT" bash /root/slopify-payload/install-inside.sh
fi

# --- verify from the host ----------------------------------------------------
step "7/8  Verifikation vom Host"
CT_ADDR=""
if [[ $DRY_RUN -eq 0 ]]; then
  CT_ADDR=$(pct exec "$CT_ID" -- bash -c "hostname -I | awk '{print \$1}'")
  [[ -n "$CT_ADDR" ]] || die "Keine IP-Adresse des Containers ermittelbar."

  # check_http_code <url> <expected-code> <name> [user:pass]
  check_http_code() {
    local url=$1 want=$2 name=$3 auth=${4:-} i code
    for ((i = 1; i <= 45; i++)); do
      if [[ -n "$auth" ]]; then
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "$auth" "$url" 2>/dev/null || true)
      else
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
      fi
      if [[ "$code" == "$want" ]]; then ok "$name erreichbar: $url -> HTTP $code"; return 0; fi
      sleep 2
    done
    printf '%s[ fail  ]%s %s: erwartet HTTP %s, zuletzt %s\n' \
      "$C_ERR" "$C_RESET" "$url" "$want" "${code:-keine Antwort}" >&2
    return 1
  }
  check_http_code "http://${CT_ADDR}:${APP_PORT}/api/healthz" 200 "Slopify" \
    || die "Slopify antwortet nicht unter http://${CT_ADDR}:${APP_PORT}/api/healthz"
  # dufs must reject anonymous access (401) and accept the configured login (200).
  check_http_code "http://${CT_ADDR}:${FILES_PORT}/" 401 "Dateimanager (ohne Login geschützt)" \
    || die "Dateimanager unter http://${CT_ADDR}:${FILES_PORT}/ ist nicht erreichbar oder NICHT passwortgeschützt."
  check_http_code "http://${CT_ADDR}:${FILES_PORT}/" 200 "Dateimanager (mit Login)" "${FILES_ADMIN_USER}:${FILES_ADMIN_PASS}" \
    || die "Login am Dateimanager unter http://${CT_ADDR}:${FILES_PORT}/ funktioniert nicht."

  ONBOOT=$(pct config "$CT_ID" | sed -n 's/^onboot: //p')
  [[ "$ONBOOT" == "1" ]] && ok "onboot=1 (CT startet nach Host-Reboot automatisch)" \
    || warn "onboot ist nicht 1 – bitte prüfen: pct config $CT_ID"
else
  CT_ADDR="<CT-IP>"
fi

# --- summary -----------------------------------------------------------------
step "8/8  Fertig"
if [[ $DRY_RUN -eq 0 ]]; then
  ADMIN_PASS_SHOWN=$(printf '%s\n' "$ADMIN_PASS")
  FILES_PASS_SHOWN=$(printf '%s\n' "$FILES_ADMIN_PASS")
else
  ADMIN_PASS_SHOWN="<generiert>"
  FILES_PASS_SHOWN="<generiert>"
fi

cat <<EOF

${C_BOLD}╭──────────────────────────────────────────────────────────────╮
│  ${APP_TITLE} läuft auf CT ${CT_ID}
╰──────────────────────────────────────────────────────────────╯${C_RESET}

  Web-App        : http://${CT_ADDR}:${APP_PORT}
  Dateien/Musik  : http://${CT_ADDR}:${FILES_PORT}
  Musik (Host)   : ${MUSIC_PATH}
  Daten/Backup   : ${APP_DIR:-/opt/slopify}/data  (im Container)

  Login Slopify  : ${ADMIN_USER} / ${ADMIN_PASS_SHOWN}
  Login Dateien  : ${FILES_ADMIN_USER} / ${FILES_PASS_SHOWN}
  (auch gespeichert unter /root/slopify-credentials.txt im Container)

  Nächste Schritte:
    1. http://${CT_ADDR}:${FILES_PORT} öffnen und Musik hochladen
    2. Slopify öffnen, Passwort ändern, Accounts anlegen
    3. Settings › Tasks › "Scan library" starten

  Update:      Script mit --id ${CT_ID} erneut ausführen
  Logs:        pct exec ${CT_ID} -- journalctl -u slopify -f
  Deinstall:   Script mit --id ${CT_ID} --uninstall --yes
  Log dieser Installation: ${LOG_FILE}

EOF
