#!/usr/bin/env bash
# =============================================================================
#  slopify-lxc – in-container installer
#  Runs INSIDE the Debian LXC. Called by install/slopify.sh, but it is also
#  safe to re-run by hand:  bash /root/slopify-payload/install-inside.sh
#
#  Installs:  Docker CE + compose plugin
#             Slopify (ghcr.io/lukasbaxter/slopify)  -> port ${APP_PORT}
#             dufs (upload UI + WebDAV for /music)  -> port ${FILES_PORT}
#             systemd units slopify.service / slopify-files.service
# =============================================================================
set -Eeuo pipefail

# --- inputs (exported by the host installer, all overridable) ----------------
APP_PORT="${APP_PORT:-8080}"
FILES_PORT="${FILES_PORT:-8081}"
TZ="${TZ:-Europe/Berlin}"
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
PAYLOAD_DIR="${PAYLOAD_DIR:-/root/slopify-payload}"
MUSIC_DIR="${MUSIC_DIR:-/music}"
APP_DIR=/opt/slopify
INSTALL_LOG=/var/log/slopify-install.log

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi
msg()   { printf '%s[slopify]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()    { printf '%s[   ok   ]%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn()  { printf '%s[ warn  ]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
step()  { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die()   { printf '%s[ fail  ]%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

mkdir -p "$(dirname "$INSTALL_LOG")"
exec > >(tee -a "$INSTALL_LOG") 2>&1

# --- error handling: everything, not just the last line ---------------------
on_error() {
  local code=$1 line=$2 cmd=$3
  trap - ERR
  {
    printf '\n%s================ INSTALLATIONSFEHLER ================%s\n' "$C_ERR" "$C_RESET"
    printf 'Exit-Code : %s\n' "$code"
    printf 'Ort       : %s\n' "$line"
    printf 'Befehl    : %s\n' "$cmd"
    printf 'Logdatei  : %s\n' "$INSTALL_LOG"
    printf '\n--- systemd: slopify / slopify-files ---\n'
    systemctl --no-pager --full status slopify.service slopify-files.service 2>&1 | head -n 80 || true
    printf '\n--- journal (letzte 120 Zeilen) ---\n'
    journalctl -u slopify.service -u slopify-files.service -n 120 --no-pager 2>&1 || true
    printf '\n--- docker compose ps / logs ---\n'
    ( cd "$APP_DIR" && docker compose --env-file "$APP_DIR/.env" -f "$APP_DIR/compose.yml" ps -a 2>&1 ) || true
    ( cd "$APP_DIR" && docker compose --env-file "$APP_DIR/.env" -f "$APP_DIR/compose.yml" logs --tail=120 2>&1 ) || true
    printf '\n--- docker info / disk / memory ---\n'
    docker info 2>&1 | tail -n 25 || true
    df -h / /var/lib/docker 2>&1 || true
    free -m 2>&1 || true
    printf '\nVollständiges Log: %s\n' "$INSTALL_LOG"
    printf 'Erneut mit Shell-Trace: bash -x %s\n' "$0"
    printf '%s=====================================================%s\n' "$C_ERR" "$C_RESET"
  } >&2
  exit "$code"
}
trap 'on_error $? "$(caller 0 2>/dev/null || echo "?" )" "$BASH_COMMAND"' ERR

retry() { # retry <attempts> <sleep> <cmd...>
  local attempts=$1 delay=$2; shift 2
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      printf '%s[ fail  ]%s nach %d Versuchen: %s\n' "$C_ERR" "$C_RESET" "$n" "$*" >&2
      return 1
    fi
    printf '%s[ retry ]%s Versuch %d/%d fehlgeschlagen, %ss Pause: %s\n' "$C_WARN" "$C_RESET" "$n" "$attempts" "$delay" "$*"
    sleep "$delay"; n=$((n + 1))
  done
}

wait_http() { # wait_http <url> <name> [tries]
  local url=$1 name=$2 tries=${3:-150} i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null; then
      ok "$name antwortet ($url)"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_status() { # wait_status <url> <expected-code> <name> [tries] [curl-auth]
  local url=$1 want=$2 name=$3 tries=${4:-60} auth=${5:-} i code
  for ((i = 1; i <= tries; i++)); do
    if [[ -n "$auth" ]]; then
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' -u "$auth" "$url" 2>/dev/null || true)
    else
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null || true)
    fi
    if [[ "$code" == "$want" ]]; then
      ok "$name antwortet mit HTTP $want"
      return 0
    fi
    sleep 2
  done
  return 1
}

# overlay2 inside an LXC on ZFS (or inside a sandboxed nested daemon) can fail
# with "failed to convert whiteout file ...: operation not permitted". vfs is
# slower and needs more space, but it always works.
set_storage_vfs() {
  local cur
  cur=$(docker info -f '{{.Driver}}' 2>/dev/null || true)
  [[ "$cur" == "vfs" ]] && return 0
  mkdir -p /etc/docker
  printf '{\n  "storage-driver": "vfs"\n}\n' > /etc/docker/daemon.json
  systemctl stop docker.socket 2>/dev/null || true
  systemctl restart docker.service
  for i in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || die "Docker startet mit storage-driver vfs nicht (journalctl -u docker)."
  ok "Storage-Driver auf vfs umgestellt (langsamer, aber robust in LXC/ZFS)"
}

# ---------------------------------------------------------------------------
step "1/9  System prüfen"
[[ -f /etc/debian_version ]] || die "Dieses Script erwartet Debian im Container (gefunden: $(cat /etc/os-release 2>/dev/null | head -1))."
ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == "amd64" ]] || die "Slopify wird nur als amd64-Image veröffentlicht (gefunden: $ARCH)."
[[ -d "$PAYLOAD_DIR" ]] || die "Payload-Verzeichnis $PAYLOAD_DIR fehlt – bitte das Host-Script erneut ausführen."
for f in compose.yml slopify.service slopify-files.service; do
  [[ -s "$PAYLOAD_DIR/$f" ]] || die "Payload-Datei fehlt oder ist leer: $PAYLOAD_DIR/$f"
done
ok "Debian $ARCH, Payload vollständig"
printf 'APP_PORT=%s FILES_PORT=%s TAG=%s\n' "$APP_PORT" "$FILES_PORT" "$SLOPIFY_TAG"

# ---------------------------------------------------------------------------
step "2/9  Basis-Pakete"
export DEBIAN_FRONTEND=noninteractive
retry 5 5 apt-get -o DPkg::Lock::Timeout=300 update -qq
retry 5 5 apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
  ca-certificates curl gnupg jq openssl tar gzip nano less htop >/dev/null
ok "Basis-Pakete installiert"

# ---------------------------------------------------------------------------
step "3/9  Docker CE"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) + compose $(docker compose version --short) bereits vorhanden"
else
  install -m 0755 -d /etc/apt/keyrings
  retry 5 5 curl -fsSL --retry 3 -o /etc/apt/keyrings/docker.asc \
    https://download.docker.com/linux/debian/gpg
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ -n "${VERSION_CODENAME:-}" ]] || die "VERSION_CODENAME nicht ermittelbar (/etc/os-release)."
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
    "$ARCH" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  retry 5 5 apt-get -o DPkg::Lock::Timeout=300 update -qq
  retry 3 10 apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  ok "Docker installiert"
fi
systemctl enable --now docker.service >/dev/null 2>&1 || true
for i in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || die "Docker-Daemon startet nicht (systemctl status docker / journalctl -u docker)."

DRIVER=$(docker info -f '{{.Driver}}' 2>/dev/null || true)
if [[ -z "$DRIVER" ]]; then
  warn "Docker meldet keinen Storage-Treiber – versuche Fallback vfs (langsamer, aber robust auf ZFS-Rootfs)."
  set_storage_vfs
  DRIVER=$(docker info -f '{{.Driver}}' 2>/dev/null || true)
  [[ -n "$DRIVER" ]] || die "Docker-Daemon läuft nicht, auch nicht mit vfs. Siehe journalctl -u docker."
fi
ok "Docker-Daemon läuft (storage-driver: $DRIVER)"

# ---------------------------------------------------------------------------
step "4/9  Benutzer und Verzeichnisse"
# uid/gid 1000 is what the Slopify image runs as (PUID/PGID). The file manager
# runs as the same user, so uploads are immediately readable by the server.
if getent passwd 1000 >/dev/null; then
  MEDIA_USER=$(getent passwd 1000 | cut -d: -f1)
  if getent group 1000 >/dev/null; then
    MEDIA_GROUP=$(getent group 1000 | cut -d: -f1)
  else
    MEDIA_GROUP="$MEDIA_USER"
  fi
else
  if getent group 1000 >/dev/null; then
    useradd -u 1000 -g 1000 -M -d /opt/slopify -s /usr/sbin/nologin slopify
  else
    useradd -u 1000 -U -M -d /opt/slopify -s /usr/sbin/nologin slopify
  fi
  MEDIA_USER=slopify
  MEDIA_GROUP=slopify
fi

install -d -m 0755 "$APP_DIR" "$APP_DIR/data"
install -d -m 0755 /etc/default
[[ -d "$MUSIC_DIR" ]] || install -d -m 0775 "$MUSIC_DIR"
chown 1000:1000 "$MUSIC_DIR" "$APP_DIR/data"
ok "Benutzer $MEDIA_USER (uid 1000), Verzeichnisse vorbereitet"

# ---------------------------------------------------------------------------
step "5/9  Slopify konfigurieren"
install -m 0644 "$PAYLOAD_DIR/compose.yml" "$APP_DIR/compose.yml"

# Keep an existing password on re-runs so the family does not get locked out.
ENV_FILE_PASS=""
if [[ -f "$APP_DIR/.env" ]]; then
  ENV_FILE_PASS=$(sed -n 's/^ADMIN_PASS=//p' "$APP_DIR/.env" | head -n1)
fi
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$ENV_FILE_PASS"
fi
[[ -n "$ADMIN_PASS" ]] || die "ADMIN_PASS ist leer – das Host-Script muss ein Passwort übergeben."

{
  printf '# written by slopify-lxc – safe to edit, then: systemctl restart slopify\n'
  printf 'SLOPIFY_TAG=%s\n' "$SLOPIFY_TAG"
  printf 'APP_PORT=%s\n' "$APP_PORT"
  printf 'TZ=%s\n' "$TZ"
  printf 'LANGUAGE=%s\n' "$LANGUAGE"
  printf 'ADMIN_USER=%s\n' "$ADMIN_USER"
  printf 'ADMIN_PASS=%s\n' "$ADMIN_PASS"
  printf 'TRANSCODE_CACHE_GB=%s\n' "$TRANSCODE_CACHE_GB"
  printf 'TRANSCODE_CONCURRENCY=%s\n' "$TRANSCODE_CONCURRENCY"
  printf 'SCAN_PAUSE_MS=%s\n' "$SCAN_PAUSE_MS"
} > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
chown -R 1000:1000 "$APP_DIR/data"

( cd "$APP_DIR" && docker compose --env-file .env -f compose.yml config --quiet ) \
  || die "compose.yml/.env ist ungültig (siehe Ausgabe oben)."
ok "Compose-Konfiguration gültig (Musik: $MUSIC_DIR, Daten: $APP_DIR/data)"

# ---------------------------------------------------------------------------
step "6/9  Slopify-Image laden (~350 MB, beim ersten Mal inkl. Basis-Image)"
if ! ( cd "$APP_DIR" && retry 3 15 docker compose --env-file .env -f compose.yml pull ); then
  warn "Pull mit storage-driver '$DRIVER' fehlgeschlagen (typisch: overlay2 auf ZFS im LXC)."
  warn "Wechsle auf vfs und versuche es erneut – das kann etwas länger dauern."
  set_storage_vfs
  DRIVER=vfs
  ( cd "$APP_DIR" && retry 3 15 docker compose --env-file .env -f compose.yml pull ) \
    || die "Image konnte auch mit vfs nicht geladen werden (siehe Ausgabe oben)."
fi
ok "Image bereit"

# ---------------------------------------------------------------------------
step "7/9  Dateimanager (dufs) für den Musikordner"
DUFS_WANT="${DUFS_VERSION#v}"
DUFS_URL="https://github.com/sigoden/dufs/releases/download/${DUFS_VERSION}/dufs-${DUFS_VERSION}-x86_64-unknown-linux-musl.tar.gz"
if command -v dufs >/dev/null 2>&1 && dufs --version 2>/dev/null | grep -qF "$DUFS_WANT"; then
  ok "dufs $DUFS_VERSION bereits installiert"
else
  tmp=$(mktemp -d)
  retry 3 5 curl -fsSL --retry 3 -o "$tmp/dufs.tar.gz" "$DUFS_URL"
  tar -xzf "$tmp/dufs.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/dufs" /usr/local/bin/dufs
  rm -rf "$tmp"
  ok "dufs $(dufs --version | awk '{print $2}') installiert"
fi

# dufs takes sha-512 crypt hashes, so the password is never stored in clear.
[[ -n "$FILES_ADMIN_PASS" ]] || die "FILES_ADMIN_PASS ist leer – kann den Dateimanager nicht absichern."
AUTH_HASH=$(openssl passwd -6 "$FILES_ADMIN_PASS")
[[ "$AUTH_HASH" == \$6\$* ]] || die "openssl lieferte keinen sha-512-Hash (erwartet: \$6\$...)."
{
  printf 'FILES_PORT=%s\n' "$FILES_PORT"
  printf 'DUFS_AUTH=%s:%s@/:rw\n' "$FILES_ADMIN_USER" "$AUTH_HASH"
} > /etc/default/slopify-files
chmod 600 /etc/default/slopify-files
chown root:root /etc/default/slopify-files
ok "Zugang für $FILES_ADMIN_USER eingerichtet (sha-512, kein Klartextpasswort)"

# ---------------------------------------------------------------------------
step "8/9  systemd-Services"
install -m 0644 "$PAYLOAD_DIR/slopify.service" /etc/systemd/system/slopify.service
install -m 0644 "$PAYLOAD_DIR/slopify-files.service" /etc/systemd/system/slopify-files.service
# The unit ships with User=slopify; if uid 1000 belongs to another account,
# point the service at that one instead of failing.
sed -i "s/^User=slopify$/User=${MEDIA_USER}/; s/^Group=slopify$/Group=${MEDIA_GROUP}/" \
  /etc/systemd/system/slopify-files.service
systemctl daemon-reload
systemctl enable slopify.service slopify-files.service >/dev/null
systemctl restart slopify-files.service
systemctl restart slopify.service
ok "slopify.service und slopify-files.service enabled + gestartet"

# Open the ports if the image ships ufw in active mode (it normally does not).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${APP_PORT}/tcp" >/dev/null || true
  ufw allow "${FILES_PORT}/tcp" >/dev/null || true
  ok "ufw: Ports ${APP_PORT} und ${FILES_PORT} freigegeben"
fi

# ---------------------------------------------------------------------------
step "9/9  Verifikation"
sleep 2
systemctl is-active --quiet slopify.service || die "slopify.service ist nicht aktiv."
systemctl is-active --quiet slopify-files.service || die "slopify-files.service ist nicht aktiv."
ok "Beide Services aktiv"

wait_http "http://127.0.0.1:${APP_PORT}/api/healthz" "Slopify" 150 \
  || die "Slopify antwortet nicht auf Port ${APP_PORT} (Details oben, journalctl -u slopify)."
wait_status "http://127.0.0.1:${FILES_PORT}/" 401 "Dateimanager (ohne Login)" 60 \
  || die "Dateimanager antwortet nicht oder ist NICHT passwortgeschützt (Port ${FILES_PORT}, journalctl -u slopify-files)."
wait_status "http://127.0.0.1:${FILES_PORT}/" 200 "Dateimanager (mit Login)" 20 "${FILES_ADMIN_USER}:${FILES_ADMIN_PASS}" \
  || die "Login am Dateimanager funktioniert nicht (Port ${FILES_PORT}, journalctl -u slopify-files)."

{
  printf 'SLOPIFY_USER=%s\n' "$ADMIN_USER"
  printf 'SLOPIFY_PASS=%s\n' "$ADMIN_PASS"
  printf 'FILES_USER=%s\n' "$FILES_ADMIN_USER"
  printf 'FILES_PASS=%s\n' "$FILES_ADMIN_PASS"
} > /root/slopify-credentials.txt
chmod 600 /root/slopify-credentials.txt

CT_IP=$(hostname -I | awk '{print $1}')
cat <<EOF

${C_BOLD}Slopify ist installiert.${C_RESET}
  Web-App      : http://${CT_IP}:${APP_PORT}
  Dateien/Musik: http://${CT_IP}:${FILES_PORT}   (Login: ${FILES_ADMIN_USER})
  Musikordner  : ${MUSIC_DIR}
  Daten        : ${APP_DIR}/data
  Zugangsdaten : /root/slopify-credentials.txt

Nächste Schritte:
  1. Musik über den Dateimanager hochladen/kopieren.
  2. In Slopify: Settings › Tasks › "Scan library" (oder Neustart des Containers).
  3. Admin-Passwort ändern – Slopify erzwingt das beim ersten Login.
EOF
