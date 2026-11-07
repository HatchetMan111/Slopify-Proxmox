#!/usr/bin/env bash
# Static checks for the installer repo. Runs anywhere (no Proxmox needed).
#   test/lint.sh
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }

echo "== 1. bash syntax =="
for f in install/slopify.sh scripts/install-inside.sh test/*.sh; do
  if bash -n "$f" 2>/tmp/syntax.err; then ok "$f"; else bad "$f"; cat /tmp/syntax.err; fi
done

echo "== 2. shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  for f in install/slopify.sh scripts/install-inside.sh test/*.sh; do
    if shellcheck -S warning "$f"; then ok "$f"; else bad "$f"; fi
  done
else
  echo "  (shellcheck nicht installiert – übersprungen)"
fi

echo "== 3. compose.yml =="
python3 - <<'PY' && ok "compose.yml Struktur" || bad "compose.yml Struktur"
import sys, yaml
d = yaml.safe_load(open('config/compose.yml'))
s = d['services']['slopify']
assert s['network_mode'] == 'host'
assert s['image'].startswith('ghcr.io/lukasbaxter/slopify:')
assert '/music:/music:ro' in s['volumes']
assert s['restart'] == 'unless-stopped'
assert s['environment']['PUID'] == '1000'
PY

echo "== 4. systemd units =="
tmp=$(mktemp -d); cp config/*.service "$tmp/"
out=$(cd "$tmp" && systemd-analyze verify ./slopify.service ./slopify-files.service 2>&1 || true)
rm -rf "$tmp"
if grep -qiE 'Failed to parse|Unknown key|Invalid .*=' <<<"$out"; then
  bad "systemd-analyze verify"; printf '%s\n' "$out"
else
  ok "systemd-analyze verify (nur fehlende Binaries/Units auf diesem Host sind erwartbar)"
fi
grep -q '^Restart=always$' config/slopify.service && ok "slopify.service Restart=always" || bad "Restart=always fehlt"
grep -q '^Restart=always$' config/slopify-files.service && ok "slopify-files.service Restart=always" || bad "Restart=always fehlt"
grep -q '^After=network-online.target' config/slopify.service && ok "After=network-online.target" || bad "After=network-online.target fehlt"
grep -q '^WantedBy=multi-user.target$' config/slopify.service && ok "WantedBy=multi-user.target" || bad "WantedBy fehlt"

echo "== 5. Dry-Run des Installers =="
dry=$(bash install/slopify.sh --dry-run 2>&1)
for needle in \
  'pct create 100' \
  '--features nesting=1\,keyctl=1' \
  'mp0 /srv/slopify/music\,mp=/music' \
  'install-inside.sh' \
  'http://<CT-IP>:8080'
do
  if grep -qF -- "$needle" <<<"$dry"; then ok "dry-run enthält: $needle"; else bad "dry-run fehlt: $needle"; fi
done

echo
printf 'Ergebnis: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
