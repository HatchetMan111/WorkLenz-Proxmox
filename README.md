# Worklenz auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Worklenz-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für Worklenz — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/Worklenz/worklenz`. Das Install-Script nutzt deren
> offizielle Docker-Images (`chamikajaycey/worklenz-frontend:3.2.0`,
> `chamikajaycey/worklenz-backend:3.2.0`) plus `postgres:15`,
> `chrislusf/seaweedfs:4.41` und `nginx:alpine` — alles läuft vollständig lokal.

Worklenz (All-in-one Projektmanagement: Tasks, Board/Gantt, Ressourcen,
Zeiterfassung, Finanzen, Client-Portal) läuft in einem
unprivilegierten LXC-Container mit Docker Compose: Web-UI primär auf Port **80**
(Nginx), Frontend direkt auf **5000**, API auf **3000**, Portal auf **5174**,
S3 auf **8333**. systemd-Service mit `Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `worklenz` |
| Zweck | All-in-one Projektmanagement (Tasks, Ressourcen, Zeit, Finanzen, Portal) |
| Tech-Stack | React/Express (Docker) + PostgreSQL 15 + SeaweedFS + Nginx |
| Upstream-Repo | `https://github.com/Worklenz/worklenz` |
| Web UI | `https://<LXC-IP>` (Nginx, primär, self-signed — Browser-Warnung bestätigen) + `http://<LXC-IP>:5000` (Frontend direkt), bind `0.0.0.0` via Docker-Ports |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 20 GB Disk (Minimum — 7+ Dienste, mit 2 GB OOM) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | `nesting=1,keyctl=1` (Docker-Voraussetzung), unprivilegiert |

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WorkLenz-Proxmox/main/install/worklenz.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=8192 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WorkLenz-Proxmox/main/install/worklenz.sh)"
bash worklenz.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --storage local-lvm
bash worklenz.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `worklenz` (`onboot: 1`, unprivilegiert, `nesting=1,keyctl=1`),
3. installiert im Container Docker + Compose-Plugin, klont Upstream nach `/opt/worklenz`,
   legt `.env` mit zufälligen Secrets (`openssl rand -hex 32`) und URLs auf die
   aktuelle Container-IP an, erzeugt bei Bedarf ein self-signed SSL-Zertifikat
   (`nginx/ssl/`, wie Upstream-`manage.sh`), schreibt die systemd-Unit,
   `systemctl enable --now worklenz`,
4. verifiziert `systemctl is-active worklenz` + HTTP auf `127.0.0.1:80/health`,
   `127.0.0.1:5000` und `127.0.0.1:3000/public/health` und gibt die finalen
   URLs + Container-IP aus. (`:80/` leitet per Upstream-Config auf HTTPS um —
   darum prüft der Installer bewusst `/health`, das ohne Redirect 200 liefert.)

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active worklenz = active).
[OK]    Nginx antwortet (HTTP 200 auf localhost:80/health).
[OK]    Frontend antwortet (HTTP 200 auf localhost:5000).
[OK]    Backend antwortet (HTTP 200 auf localhost:3000/public/health).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Worklenz – All-in-one Projektmanagement
  Container    : CT 100 (Hostname: worklenz, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 20 GB Disk
  Web-UI       : https://192.168.1.100 (self-signed – Warnung bestätigen)
  Health       : http://192.168.1.100:80/health
  Frontend     : http://192.168.1.100:5000
  Erst-Login   : admin@worklenz.local / Apw-... (nur jetzt angezeigt – nach Login ändern!)
  API          : http://192.168.1.100:3000
  Portal       : http://192.168.1.100:5174
  S3           : http://192.168.1.100:8333
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status worklenz  (im Container via: pct enter 100)
  Stack        : cd /opt/worklenz && docker compose ps / docker compose logs -f (im Container)
  Update       : Skript erneut laufen lassen (idempotent, zieht neueste Images + restart)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 90 && curl -fs http://192.168.1.100:80/health >/dev/null && curl -fs http://192.168.1.100:5000 >/dev/null
  Log          : /tmp/worklenz-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90   # Erster Start nach Reboot: Docker + 7 Dienste + DB-Init brauchen ~60–90 s
pct exec $CT -- systemctl is-active worklenz   # muss: active
pct exec $CT -- docker ps --format '{{.Names}} {{.Status}}'
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):80/health >/dev/null && echo NGINX-OK
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):5000 >/dev/null && echo FRONTEND-OK
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):3000/public/health >/dev/null && echo BACKEND-OK
# Hinweis: https://<LXC-IP> braucht curl -k (self-signed):
curl -kfs https://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1) >/dev/null && echo WEBUI-OK
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash worklenz.sh --ctid 100
# zieht neueste Images, macht git pull in /opt/worklenz, schreibt .env-URLs neu
# (Secrets + DB-Volume bleiben erhalten), danach systemctl restart worklenz.
```

Manuell im Container:

```bash
pct enter 100
cd /opt/worklenz && docker compose pull && docker compose up -d
systemctl restart worklenz && systemctl status worklenz --no-pager --full
curl -fs http://127.0.0.1:80/health >/dev/null && echo NGINX-OK
curl -fs http://127.0.0.1:5000 >/dev/null && echo FRONTEND-OK
curl -fs http://127.0.0.1:3000/public/health >/dev/null && echo BACKEND-OK
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/worklenz-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl -u worklenz -n 100`,
  `systemctl status worklenz`, `docker ps -a`, `docker compose logs --tail=100` —
  niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x worklenz.sh --ctid 100
DEBUG=1 bash worklenz.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/worklenz-install-*.log
pct exec 100 -- journalctl -u worklenz --no-pager -n 100
pct exec 100 -- docker compose -f /opt/worklenz/docker-compose.yml logs --tail=100 --no-color
```

## 6. Dateien in diesem Paket

```text
WorkLenz-Proxmox/               # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/worklenz.sh         # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/worklenz.service    # systemd-Unit (Restart=always, After=network-online.target + docker.service)
└── README.md                   # diese Datei
```

`install/worklenz.sh` bettet die Unit-Vorlage aus `systemd/worklenz.service` ein,
damit der Einzeiler ohne weitere Dateien auskommt. Der Compose-Stack aus Upstream
(`frontend`, `backend`, `client-portal`, `postgres:15`, `seaweedfs`, `nginx`,
`db-backup`) wird im Container unter `/opt/worklenz/` per Git-Checkout bereitgestellt.

## 7. Hinweise

- **Warum Docker statt nativem Build?** Upstream baut Frontend+Backend+Portal per
  `npm ci + build` — nativ im LXC wären das mehrere GB Build-Deps und 10–20 Minuten
  Bauzeit. Die offiziellen Images sind der dokumentierte Self-Host-Weg
  (`docker compose up -d`) und machen den Installer idempotent und schnell.
- **Warum 4 GB / 20 GB?** Frontend + Backend (je Node) + Portal + Postgres +
  SeaweedFS + Nginx + Backup brauchen real ~3 GB RAM und ~8 GB Images. Mit 2 GB/8 GB
  droht OOM bzw. volle Disk — darum warnt das Skript bei kleineren Werten.
- **LXC statt VM:** Mit `nesting=1,keyctl=1` läuft Docker stabil im unprivilegierten
  LXC — keine VM nötig (kein Kernel-/GPU-Bedarf). Nur wenn der Host kein nesting
  erlaubt oder dedizierte Kernel-Features nötig sind, auf VM wechseln (gleicher
  Inhalt in Debian-12-VM, 2–4 vCPU / 4–8 GB / 30 GB).
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen lassen —
  er erkennt die neue IP und schreibt `DOMAIN`/`VITE_API_URL`/`FRONTEND_URL`/
  `S3_PUBLIC_URL` in `/opt/worklenz/.env` neu (Secrets bleiben). Für stabile URLs
  DHCP-Reservierung oder statische IP einrichten.
- **Kein TLS im Erstinstall:** Der Installer erzeugt ein self-signed Zertifikat
  (`nginx/ssl/`, wie Upstream-`manage.sh`) — im Browser die Warnung bestätigen.
  Echtes TLS optional später via Upstream-`manage.sh ssl` (Let's Encrypt).
- **Backend-Worker-Fehler (`import_jobs`/`task_export_jobs does not exist)?**
  Das ist Upstream-Rauschen aus dem laufenden 3.2.0-Backend gegen das
  Main-Branch-Basis-Schema — tritt mit Upstreams eigenem `quick-setup.sh`
  identisch auf, betrifft nur Hintergrund-Worker-Ticks, nicht die Web-UI.
  Kein Installer-Fehler; ggf. Upstream-Issue prüfen.
- Erster Start zieht ~3–4 GB Images + DB-Init — Web UI kann 2–5 Minuten brauchen
  (beide Ports werden bis zu 240 s gepollt).

## 8. Anmeldung – Erst-Login aus der Ausgabe-Box

Der Installer legt beim Erstlauf automatisch einen Admin-Account über
Worklenz' eigene Signup-API an und druckt ihn **genau einmal** in der
Schluss-Box (danach steht er zusätzlich im Install-Log — sicher verwahren):

```text
  Erst-Login   : admin@worklenz.local / Apw-... (nur jetzt angezeigt – nach Login ändern!)
```

- Im Browser auf `https://<LXC-IP>` (Warnung bestätigen) mit diesen Daten
  anmelden, danach unter Profil **Passwort ändern**.
- Eigene Werte (idempotent, Re-Run legt nichts doppelt an):
  ```bash
  bash worklenz.sh --ctid 100 --admin-email ich@domain.tld --admin-name "Mein Name"
  bash worklenz.sh --ctid 100 --admin-email ich@domain.tld --admin-password 'Starkes-Passwort!9A'
  # als ENV: ADMIN_EMAIL=.. ADMIN_PASSWORD=.. ADMIN_NAME=.. bash worklenz.sh --ctid 100
  ```
  Passwort-Policy (Upstream, sonst schlägt die Anlage fehl): mind. 8 Zeichen,
  Klein- + Großbuchstabe + Ziffer + Sonderzeichen aus `@$!%*?&#`; Name mind.
  4 Zeichen. Das generierte Default-Passwort erfüllt das immer.
- Bereits angelegt (Re-Run-Marker `/opt/worklenz/.admin-created`): kein neuer
  Account, die Box zeigt die Mail mit Hinweis auf den Erstlauf. Passwort
  vergessen → per Login-Maske „Passwort zurücksetzen" (braucht SMTP, siehe
  unten) oder Account neu anlegen.
- Manuelle Registrierung geht jederzeit parallel (`Sign up` im Browser, das
  erste Konto wird Owner) — gleiche Policy wie oben; genau daran scheitert
  übrigens ein manuelles „Failed to validate signup details" fast immer
  (zu schwaches Passwort oder Name < 4 Zeichen).
- Mailversand (Einladungen/Reset) braucht SMTP in `/opt/worklenz/.env`
  (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `EMAIL_FROM`),
  danach im Container `docker compose up -d && systemctl restart worklenz`.
