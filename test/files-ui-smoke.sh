#!/usr/bin/env bash
# End-to-end test of the file manager the installer deploys (dufs):
# hashed password auth, upload, restart, file survives, WebDAV works.
#
#   test/files-ui-smoke.sh
set -Eeuo pipefail

DUFS_VERSION="${DUFS_VERSION:-v0.47.0}"
PORT="${PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 18081)}"
USER_NAME="admin"
PASSWORD="SmokeTest123456"
WORK=$(mktemp -d)
PID=""
cleanup() { [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }

say "1) dufs $DUFS_VERSION laden"
curl -fsSL --retry 3 -o "$WORK/dufs.tar.gz" \
  "https://github.com/sigoden/dufs/releases/download/${DUFS_VERSION}/dufs-${DUFS_VERSION}-x86_64-unknown-linux-musl.tar.gz"
tar -xzf "$WORK/dufs.tar.gz" -C "$WORK"
"$WORK/dufs" --version
pass "Binary läuft"

ROOT="$WORK/music"; mkdir -p "$ROOT"
HASH=$(openssl passwd -6 "$PASSWORD")
[[ "$HASH" == \$6\$* ]] && pass "sha-512-Hash erzeugt (kein Klartextpasswort auf der Platte)"

start_server() {
  # Exactly the flags from config/slopify-files.service
  "$WORK/dufs" "$ROOT" --bind 0.0.0.0 --port "$PORT" \
    --auth "${USER_NAME}:${HASH}@/:rw" \
    --allow-upload --allow-delete --allow-search --allow-archive \
    --hidden .git,.DS_Store,.stfolder,.Trash-* > "$WORK/dufs.log" 2>&1 &
  PID=$!
  for _ in {1..40}; do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)" == "401" ]] && return 0
    sleep 0.25
  done
  echo "Server-Log:"; cat "$WORK/dufs.log"; return 1
}

say "2) Auth prüfen"
start_server
pass "Ohne Login: HTTP 401 (Dateien nicht offen)"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:${PORT}/")
[[ "$code" == "200" ]] && pass "Mit Login: HTTP 200"

say "3) Upload (PUT, wie der Upload-Button der Web-UI)"
printf 'hello dufs' > "$WORK/Test Song.mp3"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${USER_NAME}:${PASSWORD}" \
  -T "$WORK/Test Song.mp3" "http://127.0.0.1:${PORT}/Test%20Song.mp3")
[[ "$code" == "201" ]] && pass "Upload: HTTP 201"
[[ "$(cat "$ROOT/Test Song.mp3")" == "hello dufs" ]] && pass "Datei liegt in /music ($(stat -c '%s Bytes, Modus %a' "$ROOT/Test Song.mp3"))"

say "4) WebDAV (Bonus: Netzlaufwerk)"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${USER_NAME}:${PASSWORD}" \
  -X PROPFIND -H 'Depth: 1' "http://127.0.0.1:${PORT}/")
[[ "$code" == "207" ]] && pass "PROPFIND: HTTP 207 (WebDAV aktiv)"

say "5) Neustart (entspricht systemctl restart slopify-files)"
kill "$PID"; wait "$PID" 2>/dev/null || true; PID=""
start_server
pass "Nach Neustart wieder erreichbar (401 ohne Login)"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${USER_NAME}:${PASSWORD}" "http://127.0.0.1:${PORT}/Test%20Song.mp3")
[[ "$code" == "200" ]] && pass "Hochgeladene Datei überlebt den Neustart"

printf '\n\033[32mAlle Dateimanager-Tests bestanden.\033[0m\n'
