# 👻 SPECTER — Pentest Toolkit

Toolkit red team complet structuré par phases, en CLI et avec une interface web.

```
   ███████╗██████╗ ███████╗ ██████╗████████╗███████╗██████╗
   ██╔════╝██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗
   ███████╗██████╔╝█████╗  ██║        ██║   █████╗  ██████╔╝
   ╚════██║██╔═══╝ ██╔══╝  ██║        ██║   ██╔══╝  ██╔══██╗
   ███████║██║     ███████╗╚██████╗   ██║   ███████╗██║  ██║
   ╚══════╝╚═╝     ╚══════╝ ╚═════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
```

---

## 🎯 Workflow couvert (par phase)

| Phase | Outils principaux |
|---|---|
| 🔎 **Reconnaissance** | subfinder, amass, assetfinder, httpx, dnsx, katana, whatweb, theHarvester, waybackurls |
| 🛰️ **Scan réseau** | nmap (7 modes), masscan, naabu, NSE (vuln/exploit/auth/discovery/safe/custom) |
| 🌐 **Web** | ffuf, gobuster, dirb, nuclei, nikto, wapiti, sqlmap, wpscan, sslscan |
| 🏢 **Active Directory** | NetExec (nxc), impacket complet, BloodHound, kerbrute, evil-winrm, responder, enum4linux-ng, smbmap, ldapdomaindump |
| 🔑 **Credentials** | hydra, medusa, john, hashcat, hashid, crunch, SecLists, rockyou |
| 💣 **Exploitation** | Metasploit, searchsploit, cve-bin-tool, vulners |
| 🚇 **Post-exploitation** | chisel, ligolo-ng, proxychains, socat, serveurs HTTP/SMB |
| 📡 **Capture trafic** | wireshark, tshark, tcpdump, responder, ettercap |
| ☁️ **Cloud** | prowler, scoutsuite |
| 📊 **Reporting** | HTML (thème dark), XML, CSV, JSON, PDF |

---

## 🚀 Installation

### 1️⃣ Cloner et préparer

```bash
git clone https://github.com/CodeD-Roger/Pentest-Toolkit.git
cd Pentest-Toolkit
sudo chmod +x install.sh specter.sh
```

### 2️⃣ Installer (tout par défaut)

```bash
sudo ./install.sh
```

### 🔧 Installation sélective

L'installer accepte plusieurs flags pour personnaliser l'installation :

```bash
sudo ./install.sh --help              # Aide complète
sudo ./install.sh --list              # Liste les 11 groupes installables
sudo ./install.sh --skip cloud,ad     # Installe tout sauf le cloud et l'AD
sudo ./install.sh --only web,recon    # Installe SEULEMENT le web et la recon
sudo ./install.sh --skip nuclei,amass # Skip à l'outil près
sudo ./install.sh --interactive       # Menu à cases à cocher (whiptail)
```

| Groupe | Contenu |
|---|---|
| `scan` | nmap, masscan, naabu |
| `recon` | subfinder, amass, httpx, dnsx, theHarvester, ... |
| `web` | ffuf, gobuster, dirb, nuclei, nikto, sqlmap, wpscan, ... |
| `ad` | NetExec, impacket, BloodHound, kerbrute, evil-winrm, ... |
| `creds` | hydra, john, hashcat, SecLists, ... |
| `exploit` | Metasploit, searchsploit, cve-bin-tool |
| `postexpl` | chisel, ligolo-ng, proxychains |
| `traffic` | wireshark, tshark, tcpdump, ettercap |
| `reporting` | wkhtmltopdf, pandoc |
| `cloud` | prowler, scoutsuite |
| `web-ui` | fastapi, uvicorn, websockets (pour le serveur web) |

> Les dépendances de base (curl, git, python3, go, pipx) sont **toujours** installées — elles sont prérequises.

> L'installer est **idempotent** : le relancer skip ce qui est déjà installé. Les erreurs apt/pip sont logguées dans `logs/install.log`.

---

## 🖥️ Lancer le CLI

```bash
./specter.sh
```

Menu principal structuré par phases red team. La cible et le domaine sont **mémorisés entre les outils** (plus besoin de retaper).

Le viewer de résultats colore automatiquement les ports (open/closed/filtered), les sévérités (critical/high/medium/low) et les CVE.

---

## 🌐 Lancer l'interface web

### Accès local uniquement (loopback, défaut)

```bash
python3 specter_web.py
```

Accessible sur `http://127.0.0.1:8765` depuis la même machine.

### Accès réseau (depuis d'autres machines)

```bash
# Le plus simple — bind 0.0.0.0 + HTTPS activé automatiquement
python3 specter_web.py --listen-all

# Forcer HTTPS même en loopback
python3 specter_web.py --https

# Désactiver HTTPS (DÉCONSEILLÉ — flux en clair)
python3 specter_web.py --listen-all --no-https
```

Le serveur affiche **toutes les IPs locales** sur lesquelles il est joignable, plus l'empreinte SHA-256 du certificat pour vérification manuelle.

Ouvre `https://<IP>:<port>` depuis ton navigateur. Comme le certificat est self-signed, le navigateur affichera un avertissement à la première visite — clique **"Avancé"** → **"Continuer vers ce site"**. C'est normal.

### Depuis le CLI SPECTER

Menu principal → **[W] Serveur Web** :
1. `Démarrer (loopback 127.0.0.1)` — local uniquement
2. `Démarrer en mode réseau (0.0.0.0)` — accessible depuis le LAN
3. `Démarrer en arrière-plan` — daemon
4. `Configurer host/port`

### Fonctionnalités web

- **Dashboard** avec stats globales et pipeline FULL RECON 1-clic (subfinder → dnsx → httpx)
- **Streaming temps réel** des scans via WebSocket (colorisation live)
- **Explorateur de résultats** unifié (Nmap, Recon, Web, AD, Loot)
- **Modal viewer** avec colorisation des sorties (open/closed/filtered, CVE, sévérités)
- **Auth par token** (généré au 1er run, stocké dans `logs/.web_token`)

### 🔐 Sécurité de l'interface web

| Mécanisme | État |
|---|---|
| **HTTPS auto** | Activé automatiquement dès qu'on bind hors loopback (cert self-signed) |
| **Token long** | 24 bytes URL-safe (~144 bits d'entropie) — bruteforce non viable |
| **Rate-limit** | Max 5 tentatives ratées par IP par minute, puis blocage 5 min |
| **WebSocket** | Bascule automatiquement en `wss://` quand le serveur est en HTTPS |
| **Headers** | `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, HSTS en HTTPS |
| **Cookie** | `HttpOnly` + `SameSite=Strict` + `Secure` en HTTPS |
| **CSP des inputs** | Validation regex stricte (URL, domaine, IP, ports, sévérité) |
| **Path traversal** | Tous les accès fichiers vérifiés sous `ROOT` |

**Recommandation pour un vrai red team engagement** : préfère un **tunnel SSH** plutôt que d'exposer le serveur sur le LAN :

```bash
# Sur ta machine cliente :
ssh -L 8765:127.0.0.1:8765 user@machine-pentest
# Puis ouvre http://127.0.0.1:8765 dans ton navigateur local
```

Le serveur reste en loopback (le plus sûr), et le trafic est chiffré par SSH (auth par clé recommandée).

---

## 📁 Structure du projet

```
Pentest-Toolkit/
├── specter.sh            # CLI principal
├── specter_web.py        # Backend FastAPI
├── install.sh            # Installer (avec --skip/--only/--interactive)
├── web/                  # Frontend (HTML/CSS/JS dark theme)
│   ├── index.html
│   ├── style.css
│   └── app.js
├── scans/
│   ├── nmap/             # Scans Nmap, masscan, naabu, NSE
│   ├── recon/            # Sous-domaines, DNS, OSINT, HTTP probing
│   ├── web/              # ffuf, nuclei, nikto, sqlmap, ...
│   └── ad/               # NetExec, BloodHound, enum4linux, ...
├── reports/              # Rapports HTML/PDF/CSV/JSON/XML générés
├── logs/                 # Logs d'install, token web, alertes
├── loot/                 # Hashes, credentials, secretsdump
└── wordlists/            # Wordlists custom (crunch, etc.)
```

---

## 🛠 Prérequis

- **Système** : Debian, Ubuntu (testé sur 24.04 LTS), Kali
- **Espace disque** : **6 Go minimum** recommandé (l'installer abort sous 3 Go)
- **Privilèges** : root pour `install.sh` (apt, configuration système)

---

## ⚠️ Avertissement

⚠️ **À utiliser uniquement sur des systèmes et réseaux pour lesquels tu as une autorisation écrite explicite.**

L'usage de ces outils sur des systèmes tiers sans consentement est **illégal** dans la plupart des juridictions et peut entraîner des poursuites pénales.

---

## 📷 Captures d'écran

| **Menu principal** | **Visualisation des scans** |
|-------------------|---------------------------|
| ![image](https://github.com/user-attachments/assets/4ab775d8-77e7-454d-a4a6-5fc89632a05f) | ![image](https://github.com/user-attachments/assets/857345bb-ad97-47b3-a4c2-0b582ed53868) |

| **Scan NSE** | **Monitoring** |
|-------------|--------------|
| ![image](https://github.com/user-attachments/assets/f8694f60-79ab-46fc-a166-13cb45b13858) | ![image](https://github.com/user-attachments/assets/605ac2f1-9ea4-4323-becc-666642e75ce2) |
