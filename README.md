# Slopify-Proxmox

Ein Einzeiler, der **Slopify** als LXC auf Proxmox VE installiert – inklusive
**Dateimanager mit Upload direkt in den Musikordner**.

Repository: <https://github.com/HatchetMan111/Slopify-Proxmox>

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Slopify-Proxmox/main/install/slopify.sh)"
```

> Genau dieser Befehl funktioniert so, ohne Anpassung.

| | |
|---|---|
| **Web-App (Slopify)** | `http://<CT-IP>:8080` |
| **Dateien / Musik-Upload** | `http://<CT-IP>:8081` |
| **Musik auf dem Host** | `/srv/slopify/music` (per Bind-Mount als `/music`) |
| **Läuft** | Debian-12-LXC, Docker, systemd, `onboot: 1` |
| **Braucht** | Proxmox VE 8/9, root, Internet nur während der Installation |

---

## Was hier eigentlich installiert wird

Dieses Repo ist **kein Fork** von Slopify, sondern ein Deployment-Wrapper:

* **[Slopify](https://github.com/lukasbaxter/slopify)** (AGPL-3.0) – der
  Musikserver, als offizielles Image `ghcr.io/lukasbaxter/slopify`. Web-App,
  Android/iPhone/Mac/Windows-Clients, Chromecast/BluOS, Home-Assistant-Integration.
* **[dufs](https://github.com/sigoden/dufs)** (MIT/Apache-2.0) –
  die Weboberfläche, mit der du Musik in `/music` hochlädst, umbenennst,
  löschst, durchsuchst. Läuft als derselbe Linux-Benutzer (uid 1000) wie der
  Musikserver, damit hochgeladene Dateien sofort lesbar sind. Zusätzlich
  spricht dufs **WebDAV** – du kannst den Ordner also auch als Netzlaufwerk
  einbinden (Windows/macOS/Linux).
* **Dieses Repo** (MIT) – Install-Script, Compose-Datei, systemd-Units, Tests.

Alles läuft lokal. Nach der Installation braucht nichts mehr eine Cloud:
Slopify liest nur deine Dateien, dufs auch.

---

## Voraussetzungen

* Proxmox VE 8.x oder 9.x, Shell als `root`
* **amd64** (Slopify wird nicht als arm64-Image veröffentlicht)
* Internet auf dem PVE-Host **nur während der Installation** (Template, Docker,
  Image ~350 MB, dufs-Binary)
* freier Platz für die Musik – am besten eine eigene Platte/ein Dataset,
  nicht das Host-Root

> **Abweichung von der ursprünglichen Vorgabe „4–8 GB Disk":** Das Image ist
> mit ~350 MB klein, aber dazu kommen Docker, SQLite-Datenbank (~1,7 GB bei
> 27k Songs inkl. Lyrics/History), Cover, Song-Heads und der Transcode-Cache
> (8 GB Default). Mit 8 GB wird es nach dem ersten Scan eng. Das Script
> verlangt deshalb **mindestens 16 GB** und nimmt standardmäßig **24 GB**
> (32 GB sind bequem). `--disk` überschreibt das.

---

## Schnellstart

### 1. Auf dem Proxmox-Host

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Slopify-Proxmox/main/install/slopify.sh)"
```

Alternative ohne `curl` (wie in der Vorgabe):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Slopify-Proxmox/main/install/slopify.sh)"
```

Das Script fragt nichts und nimmt die Defaults. Es legt den nächsten freien
CT (ab 100) an, installiert alles, prüft die Web-UI und gibt am Ende URLs,
Zugangsdaten und Logpfad aus.

### 2. Mit eigenen Werten

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Slopify-Proxmox/main/install/slopify.sh)" \
  -s -- --id 121 --music-path /tank/music --ip 192.168.1.50/24 --gw 192.168.1.1 --ram 4096
```

Aus einem lokalen Checkout (ohne GitHub):

```bash
git clone https://github.com/HatchetMan111/Slopify-Proxmox.git
cd Slopify-Proxmox
bash install/slopify.sh --dry-run     # zeigt nur, was passieren würde
bash install/slopify.sh               # echte Installation
```

### 3. Danach

1. `http://<CT-IP>:8081` öffnen → mit dem ausgegebenen Login anmelden →
   Musik hochladen oder Ordner anlegen (Drag & Drop geht).
2. `http://<CT-IP>:8080` öffnen → mit `admin` + Initialpasswort anmelden →
   **Passwort ändern** (Slopify erzwingt das), Accounts für die Familie anlegen.
3. **Settings › Tasks › „Scan library"** starten (oder CT einmal neu starten –
   der Scan läuft auch beim Boot). Danach sind die Songs da.

---

## Was das Script macht

| Schritt | Aktion |
|---|---|
| 0 | Prüft root, `/etc/pve`, `pct`, `pveam`, Architektur, Ports, Disk-Größe |
| 1 | Wählt Storage (`local-lvm`, sonst `local`) und Debian-12-Template (lädt es bei Bedarf) |
| 2 | Lädt Compose-Datei, Units und In-Container-Installer aus diesem Repo |
| 3 | `pct create` mit `nesting=1,keyctl=1` (Docker im LXC), `onboot=1`, unprivileged |
| 4 | Legt `/srv/slopify/music` an und bindet ihn als `/music` ein (rw, für Uploads) |
| 5 | Startet den CT, wartet auf IPv4 + DNS |
| 6 | Im CT: Docker CE + Compose, uid 1000, `/opt/slopify`, dufs, Units, Start |
| 7 | Prüft vom Host aus `/api/healthz` und den Dateimanager per HTTP (401 ohne Login, 200 mit Login) |
| 8 | Gibt URLs, Logins, Logpfad und nächste Schritte aus |

**Idempotent:** Derselbe Aufruf mit derselben `--id` aktualisiert die
Installation (Image neu ziehen, Units neu schreiben, Dienste neu starten).
Daten unter `/opt/slopify/data` und Passwörter bleiben erhalten. Ein fremder
CT mit derselben ID wird **nicht** angefasst (Hostname-Prüfung).

### Optionen

| Flag | Default | Bedeutung |
|---|---|---|
| `--id N` | nächste freie ≥ 100 | CT-ID |
| `--hostname` | `slopify` | Hostname (Schutz gegen fremde CTs) |
| `--cores` | `2` | vCPUs |
| `--ram` | `2048` | MB RAM (Minimum 1024) |
| `--disk` | `24` | GB Root-Disk (Minimum 16) |
| `--storage` | auto | `local-lvm`, sonst `local` |
| `--bridge` | `vmbr0` | Netzwerk-Bridge |
| `--ip` / `--gw` | DHCP | statische Adresse, z. B. `192.168.1.50/24` |
| `--music-path` | `/srv/slopify/music` | Host-Ordner für `/music`, oder `none` (Musik im CT) |
| `--app-port` | `8080` | Slopify-Port |
| `--files-port` | `8081` | Port des Dateimanagers |
| `--tag` | `latest` | Slopify-Image-Tag (für kontrollierte Updates; siehe Hinweis unten) |
| `--tz` | `Europe/Berlin` | Zeitzone (Tasks/Scan) |
| `--language` | `de` | App-Sprache |
| `--admin-pass` | generiert | Initialpasswort Slopify |
| `--files-user` / `--files-pass` | `admin` / generiert | Login Dateimanager |
| `--debug` | – | `bash -x`, voller Trace im Log |
| `--dry-run` | – | nichts verändern, nur Befehle zeigen |
| `--uninstall` | – | CT zerstören (Musik auf dem Host bleibt) |
| `--yes` | – | keine Rückfrage beim Löschen |

Beide Passwörter landen in `/root/slopify-credentials.txt` **im Container**
und werden am Ende ausgegeben. Erlaubte Zeichen: `A-Z a-z 0-9 . _ @ % + = : , / -`
(wegen der `.env`-Datei).

---

## Ports & Firewall

| Port | Dienst | Erreichbar von |
|---|---|---|
| 8080/tcp | Slopify (Web + Apps + API) | LAN |
| 8081/tcp | dufs (Upload-UI + WebDAV) | LAN |

Im LXC ist keine Firewall aktiv; falls doch (`ufw` aktiv), öffnet das Script
beide Ports. Auf dem Proxmox-Host selbst muss nichts freigegeben werden.
**Nicht** direkt ins Internet stellen – für Fernzugriff einen Reverse-Proxy
mit HTTPS davor (WebSockets auf `/api/ws`, kein Buffering).

---

## Musik hinzufügen (der Sinn des Dateimanagers)

* **Upload:** `http://<CT-IP>:8081` → `admin` + Passwort → Dateien/Ordner
  hochladen. Landet direkt in `/music`, also auch in `/srv/slopify/music`
  auf dem Host.
* **Per SSH/SMB:** einfach Dateien nach `/srv/slopify/music` kopieren – der
  Bind-Mount ist derselbe Ordner.
* **Danach scannen:** Settings › Tasks › „Scan library" (oder CT neu starten).
  Der tägliche Scan läuft standardmäßig um 04:00.
* **Formate:** flac, mp3, m4a, aac, ogg, opus, wav, aiff, wma, ape, wv.
  **`.webm`/`.mp4` werden ignoriert** – typisch für `yt-dlp -x` ohne
  `--audio-format`. Vor dem Scan umwandeln (`ffmpeg -i in.webm -c:a libmp3lame out.mp3`)
  oder gleich `yt-dlp -x --audio-format mp3 --embed-metadata` nutzen.
* **Tags:** Slopify liest Tags, keine Dateinamen. Ohne Artist/Album-Tags
  landest du unter „Unknown Artist" und das Album heißt wie der Ordner.
  Ein Tagging-Durchgang (beets/Picard) vor dem ersten Scan spart Arbeit.
* Der Musikordner ist für Slopify **read-only** gemountet; schreiben darf nur
  der Dateimanager. `SAVE_TO_LIBRARY` ist deshalb bewusst aus.

---

## Clients & Home Assistant

* Browser: `http://<CT-IP>:8080`
* Android: APK aus den [Slopify-Releases](https://github.com/lukasbaxter/slopify/releases)
* iPhone/iPad: Safari → „Zum Home-Bildschirm"
* Mac/Windows: Releases
* **Home Assistant:** HACS → Custom Repository
  `https://github.com/lukasbaxter/slopify` (Typ *Integration*) → Download →
  Neustart. Der Server meldet sich per mDNS selbst an (`network_mode: host`
  ist dafür schon gesetzt). Danach: ein `media_player` pro Person und pro
  Lautsprecher, Medienbrowser, `play_media`, Sprachsteuerung.
  Nicht gewünscht? Dann in `/opt/slopify/.env` `MDNS=0` ergänzen und
  `systemctl restart slopify`.

---

## Update, Backup, Löschen

```bash
# Update (neues Image, gleiche Daten)
bash install/slopify.sh --id 100

# oder im Container:
pct exec 100 -- bash -c 'cd /opt/slopify && docker compose pull && systemctl restart slopify'

# Backup (nur die Datenbank/Accounts/Playlists, ohne Cache)
pct exec 100 -- bash -c 'systemctl stop slopify && \
  tar czf /root/slopify-data-$(date +%F).tar.gz -C /opt/slopify \
  --exclude=data/heads --exclude=data/transcodes --exclude=data/songs --exclude=data/models data && \
  systemctl start slopify'

# Deinstallieren (Musik bleibt auf dem Host)
bash install/slopify.sh --id 100 --uninstall --yes
```

Die Datenbank wandert nur vorwärts: vor einem Update ein Backup ziehen.
Zusätzlich den CT per Proxmox-Backup (`vzdump`) sichern; die Musik im
Host-Ordner braucht kein Backup (sie ist deine Quelle).

> **Image-Tags können hinter den GitHub-Releases zurückliegen.** Beispiel vom
> 07.11.2026: Release `v0.1.162` war veröffentlicht, ein Image-Tag
> `v0.1.162` aber noch nicht (die Registry endete bei `v0.1.161`). Der
> Installer nimmt deshalb standardmäßig `latest`. Wenn du pinnen willst,
> vorher prüfen:
> `docker pull ghcr.io/lukasbaxter/slopify:v0.1.161` – erst dann `--tag` setzen.

---

## Fehlersuche

Das Script ist absichtlich gesprächig. Bei einem Fehler bekommst du **nicht**
nur die letzte Zeile, sondern:

* Exit-Code, Zeile, Befehl
* `pct config`, `pvesm status`, `pveversion`
* `systemctl status` beider Units im Container
* `journalctl` der letzten 120 Zeilen
* `docker compose ps -a` + `logs --tail=120`
* `df -h`, `free -m`
* den Pfad zum vollständigen Log (`/var/log/slopify-lxc/latest.log`)

Und den Befehl für den vollen Trace:

```bash
bash -x install/slopify.sh --id 100 --debug
```

| Symptom | Ursache / Lösung |
|---|---|
| `pct create` scheitert: „storage does not support container rootdir" | `--storage` auf einen Container-Storage setzen (`pvesm status`) |
| `VM 100 already exists on node ...` | Die ID gehört zu einer **VM**, nicht zu einem Container. Das Script erkennt das jetzt im Preflight, überspringt solche IDs bei der automatischen Wahl und nennt eine freie Alternative (`--id 101`) |
| Docker startet nicht, `overlay2`-Fehler | Rootfs liegt auf ZFS; das Script fällt automatisch auf `vfs` zurück (langsamer). Besser: CT auf LVM-thin legen |
| `Failed to convert whiteout file ... operation not permitted` beim Image-Pull | overlay2 kann im LXC/ZFS keine Whiteouts schreiben. Das Script merkt das am fehlgeschlagenen Pull und stellt **automatisch** auf `vfs` um (braucht ~2× Image-Platz). Dauerhaft: CT auf LVM-thin oder `{"storage-driver":"vfs"}` in `/etc/docker/daemon.json` |
| `MUSIC_DIR` leer / „Permission denied" | Host-Ordner muss uid **101000** (unprivileged CT) gehören – macht das Script; bei eigenem Mount `chown 101000:101000` |
| Web-UI nicht erreichbar | `pct exec 100 -- systemctl status slopify`; Port-Kollision im LAN? `--app-port` ändern |
| Dateimanager antwortet nicht | `pct exec 100 -- journalctl -u slopify-files -n 50`; meist ein Rechte-Problem auf `/music` |
| Nach dem Upload fehlen Songs | Scan starten (Settings › Tasks), Format prüfen (`.webm` wird ignoriert) |
| Chromecast wird nicht gefunden | `network_mode: host` ist gesetzt; LXC muss auf `vmbr0` liegen (kein NAT), AP-Isolation prüfen |

---

## Tests

### Auf jedem Rechner (ohne Proxmox)

```bash
bash test/lint.sh              # Syntax, ShellCheck, Compose, Units, Dry-Run
bash test/files-ui-smoke.sh    # echter Upload + Login + Neustart
```

`lint.sh` prüft u. a., dass der Dry-Run `pct create`, `--features
nesting=1,keyctl=1` und den `mp0`-Mount erzeugt, und dass beide Units
`Restart=always` + `After=network-online.target` haben.
`files-ui-smoke.sh` lädt dufs, startet es **mit exakt den Flags aus der
systemd-Unit** (sha-512-Hash, Upload/Delete/Search), prüft, dass ohne Login
HTTP 401 kommt, lädt eine Datei per PUT hoch (derselbe Weg wie der
Upload-Button), prüft WebDAV (PROPFIND 207) und dass die Datei einen Neustart
überlebt.

### Auf dem Proxmox-Host (der geforderte Reboot-Test)

```bash
bash test/pve-smoke-test.sh 100
```

Ablauf: Services aktiv → beide Web-UI antworten → `pct reboot` → warten →
prüfen, dass die Uptime tatsächlich zurückgesetzt wurde → Services wieder
aktiv → beide Web-UI antworten erneut → `systemctl status` + `journalctl`
der letzten Minuten werden ausgegeben.

Erwartete Ausgabe (gekürzt):

```
CT 100 · IP 192.168.1.50 · App 8080 · Dateien 8081
Zugangsdaten: /root/slopify-credentials.txt im CT (Slopify-Benutzer: admin, Dateimanager: admin)

1) Zustand vor dem Reboot
  PASS slopify.service = active
  PASS slopify-files.service = active
  PASS Slopify erreichbar (http://192.168.1.50:8080/api/healthz -> HTTP 200)
  PASS Dateimanager ohne Login geschützt erreichbar (http://192.168.1.50:8081/ -> HTTP 401)
  PASS Dateimanager mit Login erreichbar (http://192.168.1.50:8081/ -> HTTP 200)

2) Container neu starten (wie ein Proxmox-Host-Reboot)
  PASS Container wurde tatsächlich neu gestartet (uptime 812 s -> 9 s)

3) Nach dem Reboot: Services und Web-UI
  PASS slopify.service = active
  PASS slopify-files.service = active
  PASS Slopify erreichbar (http://192.168.1.50:8080/api/healthz -> HTTP 200)
  PASS Dateimanager ohne Login geschützt erreichbar (http://192.168.1.50:8081/ -> HTTP 401)
  PASS Dateimanager mit Login erreichbar (http://192.168.1.50:8081/ -> HTTP 200)

4) Beweis aus den Logs
  ...
Reboot-Test bestanden.
```

### Lokal bereits durchgeführter End-to-End-Test

In der Entwicklungsumgebung (Ubuntu-KVM, kein `pct`) wurde `scripts/install-inside.sh`
**unverändert** in einem Debian-12-Container mit systemd als PID 1 ausgeführt –
also genau der Teil, der später im LXC läuft. Ergebnis (07.11.2026):

```
==> 3/9  Docker CE            Docker 29.1.3 + compose 2.40.3 installiert, Daemon läuft
==> 6/9  Image laden          ghcr.io/lukasbaxter/slopify:latest gepullt (222 MB Download)
==> 7/9  Dateimanager         dufs 0.47.0, sha-512-Hash, kein Klartextpasswort
==> 8/9  systemd              slopify.service + slopify-files.service enabled + gestartet
==> 9/9  Verifikation         Slopify healthz HTTP 200 · dufs ohne Login 401 · mit Login 200
```

Reboot-Test im simulierten LXC (`docker restart`, systemd bootet neu):

```
StartedAt vorher : 09:08:11Z
StartedAt danach : 09:08:42Z        -> Container wirklich neu gestartet
systemd          : running
services         : slopify.service active · slopify-files.service active
Slopify healthz  : HTTP 200
dufs anonym      : HTTP 401
dufs mit Login   : HTTP 200
hochgeladene Datei nach Reboot: HTTP 200
Slopify-Log      : scan done: {"files":1,...}   -> Upload ist nach dem Reboot sichtbar
```

Zusätzlich wurde die Compose-Datei direkt gegen das echte Image getestet
(`docker compose up`, `/api/healthz` → `{"ok":true}`, UI HTTP 200, Scanner findet
eine Test-WAV: `files:1, added:1`) und beide echten systemd-Units wurden auf
einem systemd-Host gestartet, gestoppt und neu gestartet.

> Was hier **nicht** getestet werden konnte: `pct create`, der Bind-Mount und
> `pct reboot` – dafür braucht es echte Proxmox-Hardware. Genau diese Schritte
> prüft `test/pve-smoke-test.sh` auf deinem Host.

---

## Repo-Layout

```
install/slopify.sh          # Einzeiler-Entrypoint (Host, Proxmox)
scripts/install-inside.sh   # läuft im Container (Docker, Slopify, dufs, Units)
config/compose.yml          # Slopify-Stack (host network, /music ro, /data rw)
config/slopify.service      # systemd: docker compose up im Vordergrund
config/slopify-files.service# systemd: dufs auf /music (Auth, Upload, WebDAV)
test/lint.sh                # statische Checks + Dry-Run
test/files-ui-smoke.sh      # Upload/Login/WebDAV/Restart-Test
test/pve-smoke-test.sh      # Reboot-Test auf dem Proxmox-Host
.github/workflows/ci.yml    # CI: beides bei jedem Push
```

---

## Repository & Updates

Das Repo ist öffentlich: <https://github.com/HatchetMan111/Slopify-Proxmox>

```bash
git clone https://github.com/HatchetMan111/Slopify-Proxmox.git
cd Slopify-Proxmox
```

Änderungen an `scripts/` oder `config/` werden **beim nächsten Install-Lauf**
wirksam, weil `install/slopify.sh` die Payload-Dateien immer frisch aus
`main` lädt (`REPO_RAW`). Lokal testen, ohne zu pushen:

```bash
SLOPIFY_LOCAL_DIR=$(pwd) bash install/slopify.sh --dry-run
```

Eigene Forks: `SLOPIFY_REPO_RAW=https://raw.githubusercontent.com/DEINNAME/DEINREPO/main`
setzen – dann werden Script und Payload aus deinem Fork geladen.

---

## Grenzen & bewusste Entscheidungen

* **Docker im LXC** ist von Proxmox nicht offiziell supported, mit
  `nesting=1,keyctl=1` + ext4-Rootfs aber zuverlässig. Wenn du absolute Ruhe
  willst: dasselbe Compose in einer 2-GB-VM.
* **2 GB RAM** reichen für Scan + 2 gleichzeitige Transcodes. Bei vielen
  parallelen Hörern `--ram 4096` und `TRANSCODE_CONCURRENCY` in
  `/opt/slopify/.env` erhöhen.
* **Ein Musikordner.** Slopify hat genau ein `MUSIC_DIR`. Mehrere Platten
  bindest du als Unterordner in `/music` ein (mehrere `mpX`-Mounts) –
  Symlinks werden vom Scanner ignoriert.
* **Kein GPU-Lyrics-Sync** (Whisper) im LXC. LrcLib-Lyrics funktionieren.
* **dufs statt Eigenbau-UI:** ein statisches Binary, aktiv gepflegt, sha-512-
  Auth, Upload/Delete/Search und WebDAV ohne Datenbank. Ursprünglich war
  File Browser geplant – das Projekt ist aber seit 2026-09-01 **archiviert**
  (keine Security-Fixes mehr) und wurde deshalb ersetzt.
* Der Container ist **unprivileged**; der Host-Ordner gehört deshalb
  `101000:101000`.

---

## Lizenz

Die Skripte in diesem Repo: **MIT** (siehe `LICENSE`).
Installiert werden Slopify (**AGPL-3.0**) und dufs (**MIT/Apache-2.0**);
beide werden unverändert als offizielle Images/Binaries verwendet.
