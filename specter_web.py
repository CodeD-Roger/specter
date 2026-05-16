#!/usr/bin/env python3
"""
SPECTER Web — interface web pour le Pentest Toolkit
Backend FastAPI : REST + WebSocket pour streaming temps réel des scans.

Lancement : python3 specter_web.py
Accessible : http://127.0.0.1:8765
"""

import argparse
import asyncio
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from collections import defaultdict, deque
from datetime import datetime
from pathlib import Path
from typing import Optional

try:
    from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Request, Depends
    from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
    from fastapi.staticfiles import StaticFiles
    from pydantic import BaseModel
    import uvicorn
except ImportError:
    print("[!] Dépendances manquantes. Installe-les avec :")
    print("    pip install fastapi 'uvicorn[standard]' websockets")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════
#                              CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

ROOT = Path(__file__).resolve().parent
SCANS = ROOT / "scans"
NMAP_DIR = SCANS / "nmap"
RECON_DIR = SCANS / "recon"
WEB_DIR = SCANS / "web"
AD_DIR = SCANS / "ad"
REPORTS = ROOT / "reports"
LOGS = ROOT / "logs"
LOOT = ROOT / "loot"
WORDLISTS_DIR = ROOT / "wordlists"
WEB_STATIC = ROOT / "web"

for d in (NMAP_DIR, RECON_DIR, WEB_DIR, AD_DIR, REPORTS, LOGS, LOOT, WORDLISTS_DIR):
    d.mkdir(parents=True, exist_ok=True)

# Token d'auth — généré au lancement, affiché dans la console
TOKEN_FILE = LOGS / ".web_token"
if TOKEN_FILE.exists():
    AUTH_TOKEN = TOKEN_FILE.read_text().strip()
else:
    AUTH_TOKEN = secrets.token_urlsafe(24)
    TOKEN_FILE.write_text(AUTH_TOKEN)
    os.chmod(TOKEN_FILE, 0o600)

# Bind par défaut sur loopback. Override possible via :
#   - flags CLI : --host 0.0.0.0 --port 8765
#   - env vars  : SPECTER_HOST=0.0.0.0 SPECTER_PORT=8765
#   - alias     : --listen-all (équivalent à --host 0.0.0.0)
BIND_HOST = os.environ.get("SPECTER_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("SPECTER_PORT", "8765"))
USE_HTTPS = False  # mis à True via --https ou --listen-all si on bind sur le réseau
CERT_FILE = LOGS / "specter_cert.pem"
KEY_FILE = LOGS / "specter_key.pem"


def ensure_self_signed_cert():
    """Génère un certificat self-signed via openssl si absent.
    Retourne (cert_path, key_path) ou None en cas d'échec."""
    if CERT_FILE.exists() and KEY_FILE.exists():
        return CERT_FILE, KEY_FILE
    if not shutil.which("openssl"):
        print("[!] openssl absent — impossible de générer le certificat", file=sys.stderr)
        return None
    print("[*] Génération d'un certificat TLS self-signed (valide 365 jours)...")
    try:
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:4096",
            "-keyout", str(KEY_FILE), "-out", str(CERT_FILE),
            "-days", "365", "-nodes",
            "-subj", "/CN=SPECTER",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:0.0.0.0",
        ], check=True, capture_output=True)
        os.chmod(KEY_FILE, 0o600)
        os.chmod(CERT_FILE, 0o644)
        print(f"[+] Certificat : {CERT_FILE.relative_to(ROOT)}")
        return CERT_FILE, KEY_FILE
    except subprocess.CalledProcessError as e:
        print(f"[!] Échec génération cert : {e.stderr.decode()}", file=sys.stderr)
        return None


def get_local_ips():
    """Retourne les IPs IPv4 non-loopback de la machine."""
    ips = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    # Fallback : socket UDP "connecté" pour découvrir l'IP sortante
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip not in ips and not ip.startswith("127."):
            ips.append(ip)
    except Exception:
        pass
    return ips

# Validation : on n'autorise QUE des caractères sûrs dans les inputs cibles
TARGET_RE = re.compile(r"^[A-Za-z0-9._:/\-]+$")
URL_RE = re.compile(r"^https?://[A-Za-z0-9._:/?&=#%~+\-]+$")
DOMAIN_RE = re.compile(r"^[A-Za-z0-9.\-]+$")


# ═══════════════════════════════════════════════════════════════════════════
#                            CATALOGUE D'OUTILS
# ═══════════════════════════════════════════════════════════════════════════
# Chaque entrée : nom logique → (binaire, builder de commande, dossier de sortie)
# Le builder reçoit un dict de params validés et retourne une liste argv.

def _bool(v): return str(v).lower() in ("1", "true", "yes", "on", "o")


def b_subfinder(p):       return ["subfinder", "-d", p["domain"], "-silent"]
def b_amass(p):           return ["amass", "enum", "-passive", "-d", p["domain"]]
def b_assetfinder(p):     return ["assetfinder", "--subs-only", p["domain"]]
def b_dnsx(p):            return ["bash", "-c", f"echo {shlex.quote(p['target'])} | dnsx -resp -silent"]
def b_httpx(p):           return ["bash", "-c", f"echo {shlex.quote(p['target'])} | httpx -title -status-code -tech-detect -silent"]
def b_whatweb(p):         return ["whatweb", "-v", p["url"]]
def b_katana(p):          return ["katana", "-u", p["url"], "-silent"]
def b_theharvester(p):    return ["theHarvester", "-d", p["domain"], "-b", "all", "-l", "200"]

def b_nmap_stealth(p):    return ["sudo", "-n", "nmap", "-sS", "-v", p["target"]]
def b_nmap_ultra(p):      return ["sudo", "-n", "nmap", "-sS", "-T2", "-f", "-D", "RND:5", "--data-length", "24", p["target"]]
def b_nmap_aggr(p):       return ["sudo", "-n", "nmap", "-A", "-T4", "-v", p["target"]]
def b_nmap_full(p):       return ["sudo", "-n", "nmap", "-sT", "-p-", "-v", p["target"]]
def b_nmap_udp(p):        return ["sudo", "-n", "nmap", "-sU", "--top-ports", "200", "-v", p["target"]]
def b_nmap_ipv6(p):       return ["sudo", "-n", "nmap", "-6", "-v", p["target"]]
def b_nmap_ack(p):        return ["sudo", "-n", "nmap", "-sA", "-v", p["target"]]
def b_masscan(p):
    rate = str(int(p.get("rate", 1000)))
    return ["sudo", "-n", "masscan", p["target"], "-p", p.get("ports", "1-65535"), "--rate", rate]
def b_naabu(p):           return ["naabu", "-host", p["target"], "-silent"]
def b_nse(p):             return ["sudo", "-n", "nmap", "--script", p["category"], p["target"]]

def b_ffuf(p):
    url = p["url"].rstrip("/") + "/FUZZ"
    return ["ffuf", "-u", url, "-w", p["wordlist"], "-mc", "200,204,301,302,307,401,403", "-c"]
def b_gobuster(p):        return ["gobuster", "dir", "-u", p["url"], "-w", p["wordlist"], "-q"]
def b_dirb(p):
    wl = p.get("wordlist") or "/usr/share/wordlists/dirb/common.txt"
    return ["dirb", p["url"], wl] if Path(wl).exists() else ["dirb", p["url"]]
def b_nuclei(p):
    cmd = ["nuclei", "-u", p["url"], "-silent"]
    if p.get("severity"):
        cmd += ["-severity", p["severity"]]
    return cmd
def b_nikto(p):           return ["nikto", "-h", p["url"]]
def b_wapiti(p):          return ["wapiti", "-u", p["url"], "-f", "txt"]
def b_sqlmap(p):          return ["sqlmap", "-u", p["url"], "--batch", "--level=3", "--risk=2"]
def b_wpscan(p):          return ["wpscan", "--url", p["url"], "--random-user-agent"]
def b_sslscan(p):         return ["sslscan", p["target"]]

def b_smbclient(p):
    if p.get("user"):
        return ["smbclient", "-L", f"//{p['target']}", "-U", p["user"]]
    return ["smbclient", "-L", f"//{p['target']}", "-N"]
def b_smbmap(p):          return ["smbmap", "-H", p["target"]]
def b_enum4linux(p):      return ["enum4linux", "-a", p["target"]]
def b_nxc(p):
    bin_ = "nxc" if shutil.which("nxc") else ("netexec" if shutil.which("netexec") else "crackmapexec")
    cmd = [bin_, p["protocol"], p["target"]]
    if p.get("user"):
        cmd += ["-u", p["user"]]
        if p.get("password"):
            cmd += ["-p", p["password"]]
    return cmd


TOOLS = {
    # Recon
    "subfinder":     {"build": b_subfinder,    "dir": RECON_DIR, "needs": ["domain"], "label": "Subfinder"},
    "amass":         {"build": b_amass,        "dir": RECON_DIR, "needs": ["domain"], "label": "Amass"},
    "assetfinder":   {"build": b_assetfinder,  "dir": RECON_DIR, "needs": ["domain"], "label": "Assetfinder"},
    "dnsx":          {"build": b_dnsx,         "dir": RECON_DIR, "needs": ["target"], "label": "DNSx"},
    "httpx":         {"build": b_httpx,        "dir": RECON_DIR, "needs": ["target"], "label": "HTTPx"},
    "whatweb":       {"build": b_whatweb,      "dir": RECON_DIR, "needs": ["url"],    "label": "WhatWeb"},
    "katana":        {"build": b_katana,       "dir": RECON_DIR, "needs": ["url"],    "label": "Katana"},
    "theharvester":  {"build": b_theharvester, "dir": RECON_DIR, "needs": ["domain"], "label": "theHarvester"},
    # Scan
    "nmap-stealth":  {"build": b_nmap_stealth, "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap SYN (furtif)"},
    "nmap-ultra":    {"build": b_nmap_ultra,   "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap ultra discret"},
    "nmap-aggr":     {"build": b_nmap_aggr,    "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap agressif -A"},
    "nmap-full":     {"build": b_nmap_full,    "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap Full TCP"},
    "nmap-udp":      {"build": b_nmap_udp,     "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap UDP"},
    "nmap-ipv6":     {"build": b_nmap_ipv6,    "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap IPv6"},
    "nmap-ack":      {"build": b_nmap_ack,     "dir": NMAP_DIR,  "needs": ["target"], "label": "Nmap ACK"},
    "masscan":       {"build": b_masscan,      "dir": NMAP_DIR,  "needs": ["target"], "label": "Masscan"},
    "naabu":         {"build": b_naabu,        "dir": NMAP_DIR,  "needs": ["target"], "label": "Naabu"},
    "nse":           {"build": b_nse,          "dir": NMAP_DIR,  "needs": ["target", "category"], "label": "Nmap NSE"},
    # Web
    "ffuf":          {"build": b_ffuf,         "dir": WEB_DIR,   "needs": ["url", "wordlist"], "label": "ffuf"},
    "gobuster":      {"build": b_gobuster,     "dir": WEB_DIR,   "needs": ["url", "wordlist"], "label": "Gobuster"},
    "dirb":          {"build": b_dirb,         "dir": WEB_DIR,   "needs": ["url"], "label": "Dirb"},
    "nuclei":        {"build": b_nuclei,       "dir": WEB_DIR,   "needs": ["url"], "label": "Nuclei"},
    "nikto":         {"build": b_nikto,        "dir": WEB_DIR,   "needs": ["url"], "label": "Nikto"},
    "wapiti":        {"build": b_wapiti,       "dir": WEB_DIR,   "needs": ["url"], "label": "Wapiti"},
    "sqlmap":        {"build": b_sqlmap,       "dir": WEB_DIR,   "needs": ["url"], "label": "SQLmap"},
    "wpscan":        {"build": b_wpscan,       "dir": WEB_DIR,   "needs": ["url"], "label": "WPScan"},
    "sslscan":       {"build": b_sslscan,      "dir": WEB_DIR,   "needs": ["target"], "label": "SSLscan"},
    # AD
    "smbclient":     {"build": b_smbclient,    "dir": AD_DIR,    "needs": ["target"], "label": "smbclient"},
    "smbmap":        {"build": b_smbmap,       "dir": AD_DIR,    "needs": ["target"], "label": "smbmap"},
    "enum4linux":    {"build": b_enum4linux,   "dir": AD_DIR,    "needs": ["target"], "label": "enum4linux"},
    "nxc":           {"build": b_nxc,          "dir": AD_DIR,    "needs": ["target", "protocol"], "label": "NetExec"},
}


# ═══════════════════════════════════════════════════════════════════════════
#                       INSTALL / UNINSTALL RECIPES
# ═══════════════════════════════════════════════════════════════════════════
# Chaque entrée mappe l'identifiant outil (clé de TOOLS) ou le binaire système
# (valeur de TOOL_BINARY_MAP côté front) à des commandes shell d'install et de
# désinstallation. Les commandes sont exécutées via `sudo -n bash -c "..."`.
# Les recettes sont cohérentes avec install.sh : apt-get, pipx, go install,
# git clone + wrapper /usr/local/bin.

INSTALL_RECIPES = {
    # ── Recon ────────────────────────────────────────────────────────────
    "subfinder": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest",
        "uninstall": "rm -f /usr/local/bin/subfinder",
    },
    "amass": {
        "install":   "GOBIN=/usr/local/bin go install github.com/owasp-amass/amass/v4/...@master",
        "uninstall": "rm -f /usr/local/bin/amass",
    },
    "assetfinder": {
        "install":   "GOBIN=/usr/local/bin go install github.com/tomnomnom/assetfinder@latest",
        "uninstall": "rm -f /usr/local/bin/assetfinder",
    },
    "dnsx": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest",
        "uninstall": "rm -f /usr/local/bin/dnsx",
    },
    "httpx": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/httpx/cmd/httpx@latest",
        "uninstall": "rm -f /usr/local/bin/httpx",
    },
    "whatweb": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y whatweb",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y whatweb",
    },
    "katana": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/katana/cmd/katana@latest",
        "uninstall": "rm -f /usr/local/bin/katana",
    },
    "theHarvester": {
        "install":   "([ -d /opt/theHarvester ] || git clone --depth 1 https://github.com/laramies/theHarvester.git /opt/theHarvester) && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force /opt/theHarvester",
        "uninstall": "PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx uninstall theHarvester; rm -rf /opt/theHarvester",
    },
    # ── Scan ─────────────────────────────────────────────────────────────
    "nmap": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y nmap",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y nmap",
    },
    "masscan": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y masscan",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y masscan",
    },
    "naabu": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/naabu/v2/cmd/naabu@latest",
        "uninstall": "rm -f /usr/local/bin/naabu",
    },
    # ── Web ──────────────────────────────────────────────────────────────
    "ffuf": {
        "install":   "GOBIN=/usr/local/bin go install github.com/ffuf/ffuf/v2@latest",
        "uninstall": "rm -f /usr/local/bin/ffuf",
    },
    "gobuster": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y gobuster",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y gobuster",
    },
    "dirb": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y dirb",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y dirb",
    },
    "nuclei": {
        "install":   "GOBIN=/usr/local/bin go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest && nuclei -update-templates -silent || true",
        "uninstall": "rm -f /usr/local/bin/nuclei",
    },
    "nikto": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y nikto",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y nikto",
    },
    "wapiti": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y wapiti",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y wapiti",
    },
    "sqlmap": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y sqlmap",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y sqlmap",
    },
    "wpscan": {
        "install":   "gem install wpscan --no-document",
        "uninstall": "gem uninstall -aIx wpscan",
    },
    "sslscan": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y sslscan",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y sslscan",
    },
    # ── AD ───────────────────────────────────────────────────────────────
    "smbclient": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y smbclient",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y smbclient",
    },
    "smbmap": {
        "install":   "DEBIAN_FRONTEND=noninteractive apt-get install -y smbmap",
        "uninstall": "DEBIAN_FRONTEND=noninteractive apt-get remove -y smbmap",
    },
    "enum4linux": {
        "install":   "([ -d /opt/enum4linux-ng ] || git clone --depth 1 https://github.com/cddmp/enum4linux-ng.git /opt/enum4linux-ng) && printf '#!/bin/bash\\nexec python3 /opt/enum4linux-ng/enum4linux-ng.py \"$@\"\\n' > /usr/local/bin/enum4linux && chmod +x /usr/local/bin/enum4linux",
        "uninstall": "rm -f /usr/local/bin/enum4linux /usr/local/bin/enum4linux-ng && rm -rf /opt/enum4linux-ng",
    },
    "nxc": {
        "install":   "PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force git+https://github.com/Pennyw0rth/NetExec",
        "uninstall": "PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx uninstall netexec || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx uninstall NetExec",
    },
}


# ═══════════════════════════════════════════════════════════════════════════
#                              VALIDATION
# ═══════════════════════════════════════════════════════════════════════════

def validate_params(tool: str, params: dict) -> dict:
    if tool not in TOOLS:
        raise HTTPException(404, f"Outil inconnu : {tool}")
    spec = TOOLS[tool]
    out = {}
    for need in spec["needs"]:
        if need not in params or not params[need]:
            raise HTTPException(400, f"Paramètre manquant : {need}")
        val = str(params[need]).strip()
        if need == "url":
            if not URL_RE.match(val):
                raise HTTPException(400, f"URL invalide : {val}")
        elif need == "domain":
            if not DOMAIN_RE.match(val):
                raise HTTPException(400, f"Domaine invalide : {val}")
        elif need == "target":
            if not TARGET_RE.match(val):
                raise HTTPException(400, f"Cible invalide : {val}")
        elif need == "wordlist":
            if not Path(val).is_file():
                raise HTTPException(400, f"Wordlist introuvable : {val}")
        elif need == "category":
            if not re.match(r"^[A-Za-z0-9_,.\*-]+$", val):
                raise HTTPException(400, f"Catégorie invalide : {val}")
        elif need == "protocol":
            if val not in ("smb", "ldap", "winrm", "mssql", "ssh", "ftp"):
                raise HTTPException(400, f"Protocole invalide : {val}")
        out[need] = val
    # Champs optionnels passe-tels-quels (peu de surface d'injection vu shlex)
    for opt in ("user", "password", "severity", "rate", "ports"):
        if opt in params and params[opt]:
            v = str(params[opt])
            if opt in ("severity",) and not re.match(r"^[a-z,]+$", v):
                raise HTTPException(400, f"Sévérité invalide")
            if opt in ("ports",) and not re.match(r"^[0-9,\-]+$", v):
                raise HTTPException(400, f"Ports invalides")
            if opt in ("rate",) and not re.match(r"^[0-9]+$", v):
                raise HTTPException(400, f"Rate invalide")
            out[opt] = v
    return out


# ═══════════════════════════════════════════════════════════════════════════
#                              FASTAPI APP
# ═══════════════════════════════════════════════════════════════════════════

app = FastAPI(title="SPECTER Web", version="1.0")


# ─── Rate limiting (anti-brute force) ─────────────────────────────────────
# Limite : 5 tentatives ratées par IP par minute sur /api/auth
AUTH_ATTEMPTS = defaultdict(deque)   # ip → deque[timestamp]
AUTH_BLOCKED  = defaultdict(float)   # ip → timestamp jusqu'à laquelle bloqué
AUTH_MAX_PER_MIN = 5
AUTH_BLOCK_DURATION = 300            # 5 minutes de blocage si dépassé


def get_client_ip(request: Request) -> str:
    # On ne lit PAS X-Forwarded-For : pas de reverse proxy attendu, sinon
    # un attaquant peut le spoofer pour bypasser le rate-limit.
    return request.client.host if request.client else "unknown"


def check_rate_limit(ip: str) -> Optional[float]:
    """Retourne None si OK, ou un nombre de secondes restantes si bloqué."""
    now = time.time()
    blocked_until = AUTH_BLOCKED.get(ip, 0)
    if blocked_until > now:
        return blocked_until - now
    # Nettoie les attempts > 60s
    attempts = AUTH_ATTEMPTS[ip]
    while attempts and now - attempts[0] > 60:
        attempts.popleft()
    if len(attempts) >= AUTH_MAX_PER_MIN:
        AUTH_BLOCKED[ip] = now + AUTH_BLOCK_DURATION
        return AUTH_BLOCK_DURATION
    return None


def register_auth_failure(ip: str):
    AUTH_ATTEMPTS[ip].append(time.time())


# ─── Headers de sécurité sur toutes les réponses ──────────────────────────
@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
    # HSTS uniquement si on est sur HTTPS
    if USE_HTTPS:
        response.headers["Strict-Transport-Security"] = "max-age=31536000"
    return response


def require_auth(request: Request):
    """Auth via header X-Specter-Token, query ?token=, ou cookie."""
    token = (
        request.headers.get("X-Specter-Token")
        or request.query_params.get("token")
        or request.cookies.get("specter_token")
    )
    if not token or not secrets.compare_digest(token, AUTH_TOKEN):
        raise HTTPException(401, "Token invalide")
    return token


# ─── Static frontend ──────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index():
    idx = WEB_STATIC / "index.html"
    if not idx.exists():
        return HTMLResponse("<h1>web/index.html manquant</h1>", status_code=500)
    return FileResponse(idx)


# Statique : CSS, JS, etc.
if WEB_STATIC.exists():
    app.mount("/static", StaticFiles(directory=str(WEB_STATIC)), name="static")


# ─── API : auth ───────────────────────────────────────────────────────────

class AuthIn(BaseModel):
    token: str

@app.post("/api/auth")
async def api_auth(body: AuthIn, request: Request):
    ip = get_client_ip(request)

    # Rate-limit check
    remaining = check_rate_limit(ip)
    if remaining is not None:
        raise HTTPException(429, f"Trop de tentatives. Réessaie dans {int(remaining)}s.")

    if not secrets.compare_digest(body.token, AUTH_TOKEN):
        register_auth_failure(ip)
        raise HTTPException(401, "Token invalide")

    # Auth OK → reset des compteurs pour cette IP
    AUTH_ATTEMPTS.pop(ip, None)
    AUTH_BLOCKED.pop(ip, None)

    cookie_flags = "Path=/; HttpOnly; SameSite=Strict"
    if USE_HTTPS:
        cookie_flags += "; Secure"
    return JSONResponse({"ok": True}, headers={
        "Set-Cookie": f"specter_token={AUTH_TOKEN}; {cookie_flags}"
    })


# ─── API : statut & catalogue ─────────────────────────────────────────────

@app.get("/api/status")
async def api_status(_: str = Depends(require_auth)):
    tools_state = {}
    seen = set()
    for k, spec in TOOLS.items():
        argv = spec["build"]({n: "x" for n in spec["needs"]})
        # Skip past "sudo" and any flags (e.g. "-n") to find the real binary
        i = 0
        if argv[i] == "sudo":
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                i += 1
        bin_ = argv[i]
        if bin_ == "bash":  # pipeline
            bin_ = argv[-1].split("|")[-1].strip().split()[0]
        if bin_ in seen:
            continue
        seen.add(bin_)
        tools_state[bin_] = shutil.which(bin_) is not None
    return {
        "ok": True,
        "host": BIND_HOST,
        "port": BIND_PORT,
        "date": datetime.now().isoformat(timespec="seconds"),
        "tools": tools_state,
        "counts": {
            "nmap": len([f for f in NMAP_DIR.glob("*") if f.is_file() and f.name != ".gitkeep"]),
            "recon": len([f for f in RECON_DIR.glob("*") if f.is_file() and f.name != ".gitkeep"]),
            "web": len([f for f in WEB_DIR.glob("*") if f.is_file() and f.name != ".gitkeep"]),
            "ad": len([f for f in AD_DIR.glob("*") if f.is_file() and f.name != ".gitkeep"]),
            "reports": len([f for f in REPORTS.glob("*") if f.is_file() and f.name != ".gitkeep"]),
        },
    }


@app.get("/api/catalog")
async def api_catalog(_: str = Depends(require_auth)):
    return {k: {"label": v["label"], "needs": v["needs"]} for k, v in TOOLS.items()}


# ─── API : fichiers de scan ───────────────────────────────────────────────

CATEGORY_DIRS = {
    "nmap": NMAP_DIR, "recon": RECON_DIR, "web": WEB_DIR,
    "ad": AD_DIR, "reports": REPORTS, "loot": LOOT,
    "wordlists": WORDLISTS_DIR,
}

@app.get("/api/files")
async def api_files(category: str = "nmap", _: str = Depends(require_auth)):
    if category not in CATEGORY_DIRS:
        raise HTTPException(400, "Catégorie inconnue")
    d = CATEGORY_DIRS[category]
    files = []
    for f in d.rglob("*"):
        if f.is_file() and f.name != ".gitkeep":
            files.append({
                "name": f.name,
                "path": str(f.relative_to(ROOT)),
                "size": f.stat().st_size,
                "mtime": f.stat().st_mtime,
            })
    files.sort(key=lambda x: x["mtime"], reverse=True)
    return {"files": files}


@app.get("/api/file")
async def api_file(path: str, _: str = Depends(require_auth)):
    # Sécurité : on s'assure que le chemin est sous ROOT et dans une cat connue
    target = (ROOT / path).resolve()
    if not str(target).startswith(str(ROOT.resolve())) or not target.is_file():
        raise HTTPException(404, "Fichier introuvable")
    if target.stat().st_size > 5 * 1024 * 1024:
        raise HTTPException(413, "Fichier trop volumineux (>5 Mo)")
    return {
        "name": target.name,
        "size": target.stat().st_size,
        "mtime": target.stat().st_mtime,
        "content": target.read_text(errors="replace"),
    }


@app.delete("/api/file")
async def api_file_delete(path: str, _: str = Depends(require_auth)):
    target = (ROOT / path).resolve()
    if not str(target).startswith(str(ROOT.resolve())) or not target.is_file():
        raise HTTPException(404, "Fichier introuvable")
    if target.name == ".gitkeep":
        raise HTTPException(400, "Refusé")
    target.unlink()
    return {"ok": True}


@app.get("/api/download")
async def api_download(path: str, _: str = Depends(require_auth)):
    target = (ROOT / path).resolve()
    if not str(target).startswith(str(ROOT.resolve())) or not target.is_file():
        raise HTTPException(404, "Fichier introuvable")
    if target.name == ".gitkeep":
        raise HTTPException(400, "Refusé")
    return FileResponse(
        target,
        filename=target.name,
        media_type="application/octet-stream",
    )


# ─── WebSocket : exécution streaming ──────────────────────────────────────

RUNNING_JOBS = {}  # job_id → asyncio.subprocess.Process

@app.websocket("/ws/run")
async def ws_run(ws: WebSocket):
    await ws.accept()
    # Auth : premier message doit contenir le token
    try:
        first = await asyncio.wait_for(ws.receive_json(), timeout=5)
    except Exception:
        await ws.close(code=1008, reason="Auth timeout")
        return
    if not first.get("token") or not secrets.compare_digest(first["token"], AUTH_TOKEN):
        await ws.send_json({"type": "error", "msg": "Auth refusée"})
        await ws.close(code=1008)
        return

    tool = first.get("tool")
    params = first.get("params", {})

    try:
        validated = validate_params(tool, params)
        spec = TOOLS[tool]
        argv = spec["build"](validated)
    except HTTPException as e:
        await ws.send_json({"type": "error", "msg": e.detail})
        await ws.close()
        return

    # Fichier de sortie
    safe_target = re.sub(r"[^A-Za-z0-9._-]", "_", str(
        validated.get("target") or validated.get("url") or validated.get("domain") or "scan"
    ))[:50]
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_file = spec["dir"] / f"{tool}_{safe_target}_{ts}.txt"

    job_id = secrets.token_hex(6)
    await ws.send_json({
        "type": "start",
        "job_id": job_id,
        "cmd": " ".join(shlex.quote(a) for a in argv),
        "outfile": str(out_file.relative_to(ROOT)),
    })

    # Lancement subprocess
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            preexec_fn=os.setsid if os.name != "nt" else None,
        )
    except FileNotFoundError as e:
        await ws.send_json({"type": "error", "msg": f"Outil introuvable : {argv[0]}"})
        await ws.close()
        return
    except Exception as e:
        await ws.send_json({"type": "error", "msg": str(e)})
        await ws.close()
        return

    RUNNING_JOBS[job_id] = proc

    # Streaming ligne par ligne dans output file + websocket
    try:
        with open(out_file, "w", errors="replace") as fout:
            while True:
                # Vérifie un message "cancel" sans bloquer
                try:
                    msg = await asyncio.wait_for(ws.receive_text(), timeout=0.01)
                    if msg and json.loads(msg).get("action") == "cancel":
                        if proc.returncode is None:
                            try:
                                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                            except Exception:
                                proc.terminate()
                            await ws.send_json({"type": "info", "msg": "Annulation demandée"})
                except asyncio.TimeoutError:
                    pass
                except WebSocketDisconnect:
                    if proc.returncode is None:
                        try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                        except Exception: proc.terminate()
                    return

                line = await proc.stdout.readline()
                if not line:
                    break
                decoded = line.decode(errors="replace").rstrip("\n")
                fout.write(decoded + "\n")
                fout.flush()
                await ws.send_json({"type": "line", "data": decoded})

        rc = await proc.wait()
        await ws.send_json({"type": "end", "code": rc, "outfile": str(out_file.relative_to(ROOT))})
    except WebSocketDisconnect:
        if proc.returncode is None:
            try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception: proc.terminate()
    finally:
        RUNNING_JOBS.pop(job_id, None)
        try:
            await ws.close()
        except Exception:
            pass


# ─── WebSocket : install / désinstall outils ──────────────────────────────

@app.get("/api/install/recipes")
async def api_install_recipes(_: str = Depends(require_auth)):
    """Liste des outils pour lesquels une recette install/uninstall existe."""
    return {"recipes": sorted(INSTALL_RECIPES.keys())}


@app.websocket("/ws/manage")
async def ws_manage(ws: WebSocket):
    """Stream un install ou uninstall d'outil. Protocole identique à /ws/run :
    premier message {token, tool, action: "install"|"uninstall"}, puis messages
    {type: "start"|"line"|"info"|"error"|"end"}."""
    await ws.accept()
    try:
        first = await asyncio.wait_for(ws.receive_json(), timeout=5)
    except Exception:
        await ws.close(code=1008, reason="Auth timeout")
        return
    if not first.get("token") or not secrets.compare_digest(first["token"], AUTH_TOKEN):
        await ws.send_json({"type": "error", "msg": "Auth refusée"})
        await ws.close(code=1008)
        return

    tool = first.get("tool")
    action = first.get("action")
    if action not in ("install", "uninstall"):
        await ws.send_json({"type": "error", "msg": "Action invalide"})
        await ws.close()
        return
    if tool not in INSTALL_RECIPES:
        await ws.send_json({"type": "error", "msg": f"Pas de recette pour : {tool}"})
        await ws.close()
        return

    recipe = INSTALL_RECIPES[tool][action]
    # On exécute via `sudo -n bash -c "..."`. Le -n échoue immédiatement si
    # sudo a besoin d'un mot de passe (pas d'attente interactive).
    argv = ["sudo", "-n", "bash", "-c", recipe]

    job_id = secrets.token_hex(6)
    await ws.send_json({
        "type": "start",
        "job_id": job_id,
        "cmd": f"{action} {tool}",
        "outfile": "",
    })

    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            preexec_fn=os.setsid if os.name != "nt" else None,
        )
    except Exception as e:
        await ws.send_json({"type": "error", "msg": str(e)})
        await ws.close()
        return

    RUNNING_JOBS[job_id] = proc

    try:
        while True:
            try:
                msg = await asyncio.wait_for(ws.receive_text(), timeout=0.01)
                if msg and json.loads(msg).get("action") == "cancel":
                    if proc.returncode is None:
                        try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                        except Exception: proc.terminate()
                        await ws.send_json({"type": "info", "msg": "Annulation demandée"})
            except asyncio.TimeoutError:
                pass
            except WebSocketDisconnect:
                if proc.returncode is None:
                    try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                    except Exception: proc.terminate()
                return

            line = await proc.stdout.readline()
            if not line:
                break
            decoded = line.decode(errors="replace").rstrip("\n")
            await ws.send_json({"type": "line", "data": decoded})

        rc = await proc.wait()
        if rc != 0 and action == "install":
            # Hint utile si sudo passwordless n'est pas configuré
            await ws.send_json({"type": "info",
                "msg": "Astuce : si sudo demande un mot de passe, configure sudoers passwordless ou lance manuellement : sudo " + recipe})
        await ws.send_json({"type": "end", "code": rc, "outfile": ""})
    except WebSocketDisconnect:
        if proc.returncode is None:
            try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception: proc.terminate()
    finally:
        RUNNING_JOBS.pop(job_id, None)
        try:
            await ws.close()
        except Exception:
            pass


# ─── Wordlists : catalogue + détection + téléchargement ──────────────────

# Dossiers communs où chercher les wordlists déjà installées sur le système
WORDLIST_SCAN_DIRS = [
    "/usr/share/wordlists",
    "/usr/share/seclists",
    "/usr/share/dirb/wordlists",
    "/usr/share/dirbuster/wordlists",
    "/usr/share/wfuzz/wordlist",
    "/usr/share/john",
    str(WORDLISTS_DIR),
]

# Catalogue de wordlists téléchargeables
WORDLIST_CATALOG = {
    "rockyou": {
        "name": "rockyou.txt",
        "description": "Le célèbre wordlist de mots de passe (~14M lignes, fuite RockYou 2009)",
        "url": "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt",
        "size_mb": 134,
        "filename": "rockyou.txt",
        "category": "Mots de passe",
    },
    "passwords-top10k": {
        "name": "Top 10000 mots de passe",
        "description": "Les 10 000 mots de passe les plus utilisés (SecLists)",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-top-10000.txt",
        "size_mb": 0.08,
        "filename": "passwords-top10k.txt",
        "category": "Mots de passe",
    },
    "passwords-top1m": {
        "name": "Top 1M mots de passe",
        "description": "Le million de mots de passe les plus utilisés (~9 Mo)",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-top-1000000.txt",
        "size_mb": 9,
        "filename": "passwords-top1m.txt",
        "category": "Mots de passe",
    },
    "dirb-common": {
        "name": "dirb / common.txt",
        "description": "Liste basique de répertoires/fichiers web (4 614 entrées)",
        "url": "https://raw.githubusercontent.com/v0re/dirb/master/wordlists/common.txt",
        "size_mb": 0.04,
        "filename": "dirb-common.txt",
        "category": "Web / Directory",
    },
    "dirbuster-medium": {
        "name": "DirBuster directory-list 2.3 medium",
        "description": "Wordlist OWASP DirBuster (~220 K entrées)",
        "url": "https://raw.githubusercontent.com/daviddias/node-dirbuster/master/lists/directory-list-2.3-medium.txt",
        "size_mb": 1.9,
        "filename": "dirbuster-2.3-medium.txt",
        "category": "Web / Directory",
    },
    "raft-large-dirs": {
        "name": "RAFT large directories",
        "description": "Liste large de directories pour fuzzing web (~62 K)",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/raft-large-directories.txt",
        "size_mb": 0.6,
        "filename": "raft-large-directories.txt",
        "category": "Web / Directory",
    },
    "raft-large-files": {
        "name": "RAFT large files",
        "description": "Liste large de noms de fichiers pour fuzzing web",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/raft-large-files.txt",
        "size_mb": 0.4,
        "filename": "raft-large-files.txt",
        "category": "Web / Directory",
    },
    "subdomains-top5k": {
        "name": "Sous-domaines Top 5000",
        "description": "Top 5 000 sous-domaines les plus fréquents (subdomain enum)",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/subdomains-top1million-5000.txt",
        "size_mb": 0.04,
        "filename": "subdomains-top5k.txt",
        "category": "Sous-domaines",
    },
    "subdomains-top110k": {
        "name": "Sous-domaines Top 110000",
        "description": "Top 110 K sous-domaines (~1 Mo)",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/subdomains-top1million-110000.txt",
        "size_mb": 1.0,
        "filename": "subdomains-top110k.txt",
        "category": "Sous-domaines",
    },
    "xss-payloads": {
        "name": "XSS payloads (Jhaddix)",
        "description": "Payloads XSS pour fuzzing applicatif",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Fuzzing/XSS/XSS-Jhaddix.txt",
        "size_mb": 0.03,
        "filename": "xss-payloads-jhaddix.txt",
        "category": "Fuzzing",
    },
    "sqli-auth-bypass": {
        "name": "SQL injection auth bypass",
        "description": "Payloads SQLi pour bypass d'authentification",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Fuzzing/SQLi/Generic-SQLi.txt",
        "size_mb": 0.01,
        "filename": "sqli-generic.txt",
        "category": "Fuzzing",
    },
    "lfi-payloads": {
        "name": "LFI / Path traversal",
        "description": "Payloads Local File Inclusion / path traversal",
        "url": "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Fuzzing/LFI/LFI-Jhaddix.txt",
        "size_mb": 0.01,
        "filename": "lfi-payloads.txt",
        "category": "Fuzzing",
    },
}


def scan_installed_wordlists():
    """Parcourt WORDLIST_SCAN_DIRS et retourne la liste des fichiers texte trouvés."""
    seen = set()
    found = []
    for base in WORDLIST_SCAN_DIRS:
        bp = Path(base)
        if not bp.is_dir():
            continue
        try:
            for f in bp.rglob("*"):
                if not f.is_file():
                    continue
                # Ignore extensions binaires évidentes
                if f.suffix.lower() in (".gz", ".zip", ".7z", ".bz2", ".xz"):
                    # rockyou.txt.gz est très commun sur Kali → on l'inclut quand même
                    if f.name not in ("rockyou.txt.gz",):
                        continue
                key = str(f.resolve())
                if key in seen:
                    continue
                seen.add(key)
                try:
                    size = f.stat().st_size
                except OSError:
                    continue
                found.append({
                    "name": f.name,
                    "path": str(f),
                    "size": size,
                    "source": base,
                })
        except (PermissionError, OSError):
            continue
    found.sort(key=lambda x: (-x["size"], x["name"]))
    return found


@app.get("/api/wordlists")
async def api_wordlists(_: str = Depends(require_auth)):
    """Retourne les wordlists installées localement + le catalogue téléchargeable."""
    installed = scan_installed_wordlists()
    installed_names = {w["name"].lower() for w in installed}
    catalog = []
    for k, v in WORDLIST_CATALOG.items():
        local = WORDLISTS_DIR / v["filename"]
        catalog.append({
            "id": k,
            "name": v["name"],
            "description": v["description"],
            "size_mb": v["size_mb"],
            "filename": v["filename"],
            "category": v["category"],
            "installed": local.is_file() or v["filename"].lower() in installed_names,
            "local_path": str(local) if local.is_file() else None,
        })
    return {"installed": installed, "catalog": catalog}


class WordlistDownloadIn(BaseModel):
    id: str

@app.post("/api/wordlists/download")
async def api_wordlists_download(body: WordlistDownloadIn, _: str = Depends(require_auth)):
    if body.id not in WORDLIST_CATALOG:
        raise HTTPException(404, "Wordlist inconnue")
    entry = WORDLIST_CATALOG[body.id]
    dest = WORDLISTS_DIR / entry["filename"]
    if dest.is_file() and dest.stat().st_size > 0:
        return {"ok": True, "path": str(dest), "size": dest.stat().st_size, "skipped": True}

    import urllib.request
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        # urlretrieve-like, en streaming pour gérer les gros fichiers
        req = urllib.request.Request(entry["url"], headers={"User-Agent": "specter-web/1.0"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            if resp.status != 200:
                raise HTTPException(502, f"Téléchargement échoué (HTTP {resp.status})")
            with open(tmp, "wb") as fout:
                while True:
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    fout.write(chunk)
        tmp.rename(dest)
    except HTTPException:
        if tmp.exists(): tmp.unlink()
        raise
    except Exception as e:
        if tmp.exists(): tmp.unlink()
        raise HTTPException(502, f"Téléchargement échoué : {e}")

    return {"ok": True, "path": str(dest), "size": dest.stat().st_size}


# ─── Pipeline FULL RECON ──────────────────────────────────────────────────

class PipelineIn(BaseModel):
    domain: str

@app.post("/api/pipeline/recon")
async def api_pipeline_recon(body: PipelineIn, _: str = Depends(require_auth)):
    """Lance subfinder → dnsx → httpx en chaîne (synchrone, court)."""
    if not DOMAIN_RE.match(body.domain):
        raise HTTPException(400, "Domaine invalide")
    if not all(shutil.which(b) for b in ("subfinder", "dnsx", "httpx")):
        raise HTTPException(400, "subfinder/dnsx/httpx requis")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    dom = body.domain
    subs = RECON_DIR / f"{dom}_subs_{ts}.txt"
    live = RECON_DIR / f"{dom}_live_{ts}.txt"
    probe = RECON_DIR / f"{dom}_probe_{ts}.txt"

    # subfinder
    p = await asyncio.create_subprocess_exec("subfinder", "-d", dom, "-silent",
                                              stdout=asyncio.subprocess.PIPE,
                                              stderr=asyncio.subprocess.DEVNULL)
    out, _e = await p.communicate()
    subs.write_bytes(out)

    # dnsx
    p = await asyncio.create_subprocess_exec("dnsx", "-l", str(subs), "-silent",
                                              stdout=asyncio.subprocess.PIPE,
                                              stderr=asyncio.subprocess.DEVNULL)
    out, _e = await p.communicate()
    live.write_bytes(out)

    # httpx
    p = await asyncio.create_subprocess_exec("httpx", "-l", str(live), "-title",
                                              "-status-code", "-tech-detect", "-silent",
                                              stdout=asyncio.subprocess.PIPE,
                                              stderr=asyncio.subprocess.DEVNULL)
    out, _e = await p.communicate()
    probe.write_bytes(out)

    return {
        "subs": str(subs.relative_to(ROOT)),
        "live": str(live.relative_to(ROOT)),
        "probe": str(probe.relative_to(ROOT)),
        "counts": {
            "subs": len(subs.read_text().splitlines()),
            "live": len(live.read_text().splitlines()),
            "probe": len(probe.read_text().splitlines()),
        },
    }


# ═══════════════════════════════════════════════════════════════════════════
#                              ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

def parse_args():
    p = argparse.ArgumentParser(
        prog="specter_web",
        description="SPECTER Web — interface web pour le Pentest Toolkit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemples:
  python3 specter_web.py                            # bind 127.0.0.1:8765 (HTTP loopback)
  python3 specter_web.py --listen-all               # bind 0.0.0.0 + HTTPS auto
  python3 specter_web.py --https                    # forcer HTTPS (même en loopback)
  python3 specter_web.py --listen-all --no-https    # forcer HTTP réseau (DÉCONSEILLÉ)
  python3 specter_web.py -H 0.0.0.0 -p 9000         # bind explicite
""",
    )
    p.add_argument("-H", "--host", default=None,
                   help=f"Adresse de bind (défaut: {BIND_HOST})")
    p.add_argument("-p", "--port", type=int, default=None,
                   help=f"Port d'écoute (défaut: {BIND_PORT})")
    p.add_argument("--listen-all", action="store_true",
                   help="Bind sur 0.0.0.0 (active HTTPS automatiquement)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--https", action="store_true",
                   help="Force HTTPS (auto-génère un certificat self-signed)")
    g.add_argument("--no-https", action="store_true",
                   help="Force HTTP même en mode réseau (DÉCONSEILLÉ)")
    return p.parse_args()


def main():
    global BIND_HOST, BIND_PORT, USE_HTTPS
    args = parse_args()

    # CLI flags > env vars > défauts
    if args.listen_all:
        BIND_HOST = "0.0.0.0"
    if args.host:
        BIND_HOST = args.host
    if args.port:
        BIND_PORT = args.port

    # Décide HTTPS :
    # - --https → ON
    # - --no-https → OFF
    # - sinon : ON automatiquement dès qu'on bind hors loopback
    on_network = (BIND_HOST == "0.0.0.0"
                  or (BIND_HOST not in ("127.0.0.1", "localhost")
                      and not BIND_HOST.startswith("127.")))
    if args.https:
        USE_HTTPS = True
    elif args.no_https:
        USE_HTTPS = False
    else:
        USE_HTTPS = on_network  # auto

    # Génère cert si HTTPS
    cert_pair = None
    if USE_HTTPS:
        cert_pair = ensure_self_signed_cert()
        if cert_pair is None:
            print("\033[31m[!] HTTPS demandé mais impossible de générer le certificat.\033[0m")
            print("\033[31m    Installe openssl ou utilise --no-https à tes risques.\033[0m")
            sys.exit(1)

    scheme = "https" if USE_HTTPS else "http"

    # Banner
    print("\033[36m")
    print("    ╔═════════════════════════════════════════════════════╗")
    print("    ║          SPECTER  WEB  —  Pentest Toolkit           ║")
    print("    ╚═════════════════════════════════════════════════════╝")
    print("\033[0m")

    # URLs d'accès
    if BIND_HOST == "0.0.0.0":
        print(f"  \033[32m●\033[0m URL local  : \033[1m{scheme}://127.0.0.1:{BIND_PORT}\033[0m")
        for ip in get_local_ips():
            print(f"  \033[32m●\033[0m URL réseau : \033[1m{scheme}://{ip}:{BIND_PORT}\033[0m")
    else:
        print(f"  \033[32m●\033[0m URL    : \033[1m{scheme}://{BIND_HOST}:{BIND_PORT}\033[0m")
        if BIND_HOST in ("127.0.0.1", "localhost") and not USE_HTTPS:
            print("  \033[2m         (loopback HTTP — utilise --listen-all pour réseau + HTTPS)\033[0m")

    print(f"  \033[33m●\033[0m Token  : \033[1m{AUTH_TOKEN}\033[0m")
    print(f"  \033[2m         (sauvegardé dans {TOKEN_FILE.relative_to(ROOT)})\033[0m")

    if USE_HTTPS:
        print()
        print("  \033[33m🔒 HTTPS activé (certificat self-signed)\033[0m")
        print("  \033[2m   Le navigateur affichera un avertissement à la première visite.\033[0m")
        print("  \033[2m   Clique 'Avancé' → 'Continuer vers ce site' — c'est normal.\033[0m")
        print(f"  \033[2m   Empreinte cert : {get_cert_fingerprint()}\033[0m")
    elif on_network:
        print()
        print("  \033[31m⚠  ATTENTION : serveur en HTTP exposé sur le réseau\033[0m")
        print("  \033[31m   Le token et toutes les données circulent EN CLAIR.\033[0m")
        print("  \033[31m   Active HTTPS avec --https ou utilise un tunnel SSH.\033[0m")

    print()
    print("  Ouvre l'URL dans ton navigateur et colle le token.")
    print("  Ctrl+C pour arrêter le serveur.\n")

    # Lancement uvicorn
    kwargs = dict(host=BIND_HOST, port=BIND_PORT, log_level="warning")
    if cert_pair:
        kwargs["ssl_certfile"] = str(cert_pair[0])
        kwargs["ssl_keyfile"] = str(cert_pair[1])
    uvicorn.run(app, **kwargs)


def get_cert_fingerprint():
    """Retourne l'empreinte SHA-256 du cert pour vérification manuelle."""
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", str(CERT_FILE), "-noout", "-fingerprint", "-sha256"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip().split("=", 1)[-1]
    except Exception:
        return "n/a"


if __name__ == "__main__":
    main()
