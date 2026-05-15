#!/usr/bin/env python3
"""
SPECTER Web — interface web pour le Pentest Toolkit
Backend FastAPI : REST + WebSocket pour streaming temps réel des scans.

Lancement : python3 specter_web.py
Accessible : http://127.0.0.1:8765
"""

import asyncio
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import sys
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
WEB_STATIC = ROOT / "web"

for d in (NMAP_DIR, RECON_DIR, WEB_DIR, AD_DIR, REPORTS, LOGS, LOOT):
    d.mkdir(parents=True, exist_ok=True)

# Token d'auth — généré au lancement, affiché dans la console
TOKEN_FILE = LOGS / ".web_token"
if TOKEN_FILE.exists():
    AUTH_TOKEN = TOKEN_FILE.read_text().strip()
else:
    AUTH_TOKEN = secrets.token_urlsafe(24)
    TOKEN_FILE.write_text(AUTH_TOKEN)
    os.chmod(TOKEN_FILE, 0o600)

BIND_HOST = os.environ.get("SPECTER_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("SPECTER_PORT", "8765"))

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

def b_nmap_stealth(p):    return ["sudo", "nmap", "-sS", "-v", p["target"]]
def b_nmap_ultra(p):      return ["sudo", "nmap", "-sS", "-T2", "-f", "-D", "RND:5", "--data-length", "24", p["target"]]
def b_nmap_aggr(p):       return ["sudo", "nmap", "-A", "-T4", "-v", p["target"]]
def b_nmap_full(p):       return ["sudo", "nmap", "-sT", "-p-", "-v", p["target"]]
def b_nmap_udp(p):        return ["sudo", "nmap", "-sU", "--top-ports", "200", "-v", p["target"]]
def b_nmap_ipv6(p):       return ["sudo", "nmap", "-6", "-v", p["target"]]
def b_nmap_ack(p):        return ["sudo", "nmap", "-sA", "-v", p["target"]]
def b_masscan(p):
    rate = str(int(p.get("rate", 1000)))
    return ["sudo", "masscan", p["target"], "-p", p.get("ports", "1-65535"), "--rate", rate]
def b_rustscan(p):        return ["rustscan", "-a", p["target"], "--ulimit", "5000"]
def b_naabu(p):           return ["naabu", "-host", p["target"], "-silent"]
def b_nse(p):             return ["sudo", "nmap", "--script", p["category"], p["target"]]

def b_ffuf(p):
    url = p["url"].rstrip("/") + "/FUZZ"
    return ["ffuf", "-u", url, "-w", p["wordlist"], "-mc", "200,204,301,302,307,401,403", "-c"]
def b_gobuster(p):        return ["gobuster", "dir", "-u", p["url"], "-w", p["wordlist"], "-q"]
def b_feroxbuster(p):     return ["feroxbuster", "-u", p["url"], "-w", p["wordlist"], "--silent"]
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
    "rustscan":      {"build": b_rustscan,     "dir": NMAP_DIR,  "needs": ["target"], "label": "Rustscan"},
    "naabu":         {"build": b_naabu,        "dir": NMAP_DIR,  "needs": ["target"], "label": "Naabu"},
    "nse":           {"build": b_nse,          "dir": NMAP_DIR,  "needs": ["target", "category"], "label": "Nmap NSE"},
    # Web
    "ffuf":          {"build": b_ffuf,         "dir": WEB_DIR,   "needs": ["url", "wordlist"], "label": "ffuf"},
    "gobuster":      {"build": b_gobuster,     "dir": WEB_DIR,   "needs": ["url", "wordlist"], "label": "Gobuster"},
    "feroxbuster":   {"build": b_feroxbuster,  "dir": WEB_DIR,   "needs": ["url", "wordlist"], "label": "Feroxbuster"},
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
async def api_auth(body: AuthIn):
    if not secrets.compare_digest(body.token, AUTH_TOKEN):
        raise HTTPException(401, "Token invalide")
    return JSONResponse({"ok": True}, headers={
        "Set-Cookie": f"specter_token={AUTH_TOKEN}; Path=/; HttpOnly; SameSite=Strict"
    })


# ─── API : statut & catalogue ─────────────────────────────────────────────

@app.get("/api/status")
async def api_status(_: str = Depends(require_auth)):
    tools_state = {}
    seen = set()
    for k, spec in TOOLS.items():
        argv = spec["build"]({n: "x" for n in spec["needs"]})
        bin_ = argv[0] if argv[0] != "sudo" else argv[1]
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

def main():
    print("\033[36m")
    print("    ╔═════════════════════════════════════════════════════╗")
    print("    ║          SPECTER  WEB  —  Pentest Toolkit           ║")
    print("    ╚═════════════════════════════════════════════════════╝")
    print("\033[0m")
    print(f"  \033[32m●\033[0m URL    : \033[1mhttp://{BIND_HOST}:{BIND_PORT}\033[0m")
    print(f"  \033[33m●\033[0m Token  : \033[1m{AUTH_TOKEN}\033[0m")
    print(f"  \033[2m  (sauvegardé dans {TOKEN_FILE.relative_to(ROOT)})\033[0m")
    print()
    print("  Ouvre l'URL dans ton navigateur et colle le token.")
    print("  Ctrl+C pour arrêter le serveur.\n")
    uvicorn.run(app, host=BIND_HOST, port=BIND_PORT, log_level="warning")


if __name__ == "__main__":
    main()
