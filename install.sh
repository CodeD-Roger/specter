#!/bin/bash
#
# Pentest Toolkit — Installer
# Installe l'ensemble des outils nécessaires au CLI principal.
# Compatible Debian/Ubuntu/Kali.
#

set -u

# ─── Couleurs ──────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ─── Bannière ──────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║   ██████╗ ███████╗███╗   ██╗████████╗███████╗███████╗████████╗    ║
    ║   ██╔══██╗██╔════╝████╗  ██║╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝    ║
    ║   ██████╔╝█████╗  ██╔██╗ ██║   ██║   █████╗  ███████╗   ██║       ║
    ║   ██╔═══╝ ██╔══╝  ██║╚██╗██║   ██║   ██╔══╝  ╚════██║   ██║       ║
    ║   ██║     ███████╗██║ ╚████║   ██║   ███████╗███████║   ██║       ║
    ║   ╚═╝     ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚══════╝   ╚═╝       ║
    ║                                                                   ║
    ║                  T O O L K I T  ─  I N S T A L L                  ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ─── Helpers ───────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[*]${NC} $*"; }
log_ok()      { echo -e "${GREEN}[+]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_err()     { echo -e "${RED}[-]${NC} $*"; }
log_phase()   { echo -e "\n${MAGENTA}${BOLD}══ $* ══${NC}"; }

have() { command -v "$1" &> /dev/null; }

# Log de débogage (apt, pip, downloads…) — toujours visible dans logs/install.log
INSTALL_LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs/install.log"
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null
: > "$INSTALL_LOG" 2>/dev/null

logf() { echo "[$(date '+%H:%M:%S')] $*" >> "$INSTALL_LOG" 2>/dev/null; }

# Tente d'installer un paquet apt ; logge les erreurs dans logs/install.log
apt_try() {
    # Skip si --skip <nom>
    if declare -F should_skip_tool > /dev/null && should_skip_tool "$1"; then
        log_warn "Skip outil : $1"
        return 1
    fi
    if dpkg -s "$1" &> /dev/null; then
        return 0
    fi
    logf "apt install $1"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >> "$INSTALL_LOG" 2>&1
}

# Installe via pip (avec fallback --break-system-packages pour PEP 668)
pip_install() {
    logf "pip install $*"
    python3 -m pip install --upgrade --break-system-packages "$@" >> "$INSTALL_LOG" 2>&1
}

# Installe une application Python isolée via pipx (idéal pour outils CLI complexes
# comme NetExec qui ont des dépendances conflictuelles avec les paquets apt).
pipx_install() {
    logf "pipx install $*"
    if ! have pipx; then
        log_warn "pipx manquant, fallback sur pip"
        pip_install "$@"
        return
    fi
    pipx install --force "$@" >> "$INSTALL_LOG" 2>&1
}

# Git clone d'un repo dans /opt et création d'un wrapper dans /usr/local/bin
git_install_tool() {
    local repo=$1     # https://github.com/...
    local name=$2     # nom du dossier dans /opt + wrapper
    local entry=$3    # chemin relatif vers le script principal (ex: Responder.py)
    local opt_dir="/opt/$name"

    if have "${name,,}" || [ -d "$opt_dir" ]; then
        log_ok "$name déjà installé"
        return 0
    fi
    log_info "Clone de $name depuis $repo"
    git clone --depth 1 "$repo" "$opt_dir" >> "$INSTALL_LOG" 2>&1 || {
        log_warn "Échec clone $name"
        return 1
    }
    if [ -n "$entry" ] && [ -f "$opt_dir/$entry" ]; then
        cat > "/usr/local/bin/${name,,}" << WRAPPER
#!/bin/bash
exec python3 "$opt_dir/$entry" "\$@"
WRAPPER
        chmod +x "/usr/local/bin/${name,,}"
    fi
    log_ok "$name installé dans $opt_dir"
}

# Installe un binaire Go (ProjectDiscovery, etc.) dans /usr/local/bin
go_install_bin() {
    local pkg=$1
    local name
    name=$(basename "${pkg%@*}")
    # Skip si --skip <nom>
    if declare -F should_skip_tool > /dev/null && should_skip_tool "$name"; then
        log_warn "Skip outil : $name"
        return 1
    fi
    if have "$name"; then
        log_ok "$name déjà installé"
        return 0
    fi
    if ! have go; then
        log_warn "Go non installé, impossible d'installer $name"
        return 1
    fi
    log_info "Installation de $name via go install..."
    GOBIN=/usr/local/bin go install "$pkg" 2>/dev/null \
        || GOPATH=/tmp/go GOBIN=/usr/local/bin go install "$pkg"
}

# ─── Prérequis ─────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Ce script doit être exécuté en tant que root (sudo ./install.sh)"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_ok "OS détecté : $NAME $VERSION_ID"
    else
        log_err "Impossible de détecter l'OS"
        exit 1
    fi
}

check_disk_space() {
    local avail_kb
    avail_kb=$(df --output=avail / 2>/dev/null | tail -1)
    local avail_gb=$((avail_kb / 1024 / 1024))
    log_info "Espace libre sur / : ${avail_gb} Go"
    if (( avail_gb < 3 )); then
        log_err "Moins de 3 Go libres — l'installation va échouer."
        log_err "Libère de l'espace ou étends le LV avant de relancer."
        exit 1
    elif (( avail_gb < 6 )); then
        log_warn "Espace serré (${avail_gb} Go) — il faut idéalement >6 Go pour tout installer."
    fi
}

update_system() {
    log_phase "MISE À JOUR DU SYSTÈME"
    if ! apt-get update; then
        log_err "Échec de apt-get update — vérifie ta connexion"
        exit 1
    fi
    apt-get upgrade -y &> /dev/null || true
    apt_try software-properties-common
    apt_try ca-certificates
    apt_try gnupg
}

# ─── Installations par catégorie ───────────────────────────────────────────

setup_pipx() {
    # Quand on est root, pipx installe dans /root/.local par défaut → on force
    # un emplacement global accessible par tous.
    export PIPX_HOME="/opt/pipx"
    export PIPX_BIN_DIR="/usr/local/bin"
    mkdir -p "$PIPX_HOME" "$PIPX_BIN_DIR"
}

install_base() {
    log_phase "DÉPENDANCES DE BASE"
    local pkgs=(
        curl wget git jq bc unzip
        python3 python3-pip python3-venv pipx
        ruby ruby-dev build-essential
        libpq-dev libpcap-dev libsqlite3-dev
        zlib1g-dev liblzma-dev libcurl4-openssl-dev libssl-dev libffi-dev
        ncat netcat-openbsd whois dnsutils tor
        less file coreutils
    )
    for p in "${pkgs[@]}"; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec : $p"; fi
    done
}

install_go() {
    log_phase "GO (pour ProjectDiscovery & co)"
    if have go; then
        log_ok "go déjà installé : $(go version)"
        return
    fi
    if apt_try golang-go; then
        log_ok "golang-go installé via apt"
    else
        log_warn "Échec apt — tentative d'installation manuelle"
        local GO_VER="1.22.5"
        wget -q "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -O /tmp/go.tar.gz \
            && tar -C /usr/local -xzf /tmp/go.tar.gz \
            && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
            && rm -f /tmp/go.tar.gz \
            && log_ok "Go installé manuellement"
    fi
}

install_scan_tools() {
    log_phase "SCAN RÉSEAU"
    for p in nmap masscan; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec : $p"; fi
    done

    # naabu (ProjectDiscovery)
    go_install_bin github.com/projectdiscovery/naabu/v2/cmd/naabu@latest
}

install_recon_tools() {
    log_phase "RECONNAISSANCE / OSINT"

    # Apt (whatweb est dispo, amass/theharvester ne le sont pas sur Ubuntu noble)
    if apt_try whatweb; then log_ok "whatweb"; else log_warn "Échec apt : whatweb"; fi

    # amass via go (n'est plus dans apt Ubuntu)
    go_install_bin github.com/owasp-amass/amass/v4/...@master

    # theHarvester via git + pipx (le paquet theHarvester sur PyPI est obsolète/cassé)
    if ! have theHarvester; then
        log_info "Installation de theHarvester via git..."
        if [ ! -d /opt/theHarvester ]; then
            git clone --depth 1 https://github.com/laramies/theHarvester.git /opt/theHarvester \
                >> "$INSTALL_LOG" 2>&1
        fi
        if [ -d /opt/theHarvester ]; then
            pipx_install /opt/theHarvester && log_ok "theHarvester via pipx" \
                || log_warn "Échec theHarvester"
        else
            log_warn "Échec clone theHarvester"
        fi
    else
        log_ok "theHarvester déjà installé"
    fi

    # ProjectDiscovery suite via go
    go_install_bin github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    go_install_bin github.com/projectdiscovery/httpx/cmd/httpx@latest
    go_install_bin github.com/projectdiscovery/dnsx/cmd/dnsx@latest
    go_install_bin github.com/projectdiscovery/katana/cmd/katana@latest

    # assetfinder (Tom Hudson)
    go_install_bin github.com/tomnomnom/assetfinder@latest

    # waybackurls
    go_install_bin github.com/tomnomnom/waybackurls@latest
}

install_web_tools() {
    log_phase "WEB / FUZZING / VULN"

    # Apt
    for p in nikto dirb gobuster sqlmap wapiti; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

    # ffuf via go (le paquet apt est souvent ancien)
    go_install_bin github.com/ffuf/ffuf/v2@latest

    # nuclei + templates
    go_install_bin github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
    if have nuclei; then
        log_info "Mise à jour des templates nuclei..."
        nuclei -update-templates -silent 2>/dev/null || true
    fi

    # WPScan (gem)
    if ! have wpscan; then
        log_info "Installation de WPScan (gem)..."
        gem install wpscan --no-document &> /dev/null \
            && log_ok "wpscan installé" \
            || log_warn "Échec wpscan"
    else
        log_ok "wpscan déjà installé"
    fi
}

install_ad_tools() {
    log_phase "ACTIVE DIRECTORY / WINDOWS"

    # Apt (les paquets vraiment dispos sur Ubuntu noble)
    for p in smbclient ldap-utils smbmap ldapscripts hashid; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

    # enum4linux-ng via git (n'est pas sur PyPI sous ce nom)
    if ! have enum4linux-ng && ! have enum4linux; then
        log_info "Installation d'enum4linux-ng via git..."
        if [ ! -d /opt/enum4linux-ng ]; then
            git clone --depth 1 https://github.com/cddmp/enum4linux-ng.git /opt/enum4linux-ng \
                >> "$INSTALL_LOG" 2>&1
        fi
        if [ -f /opt/enum4linux-ng/enum4linux-ng.py ]; then
            cat > /usr/local/bin/enum4linux-ng << 'WRAPPER'
#!/bin/bash
exec python3 /opt/enum4linux-ng/enum4linux-ng.py "$@"
WRAPPER
            chmod +x /usr/local/bin/enum4linux-ng
            log_ok "enum4linux-ng installé"
        else
            log_warn "Échec enum4linux-ng"
        fi
    else
        log_ok "enum4linux(-ng) déjà présent"
    fi

    # Responder via git (n'est plus dans apt Ubuntu)
    if ! have responder && [ ! -d /opt/Responder ]; then
        log_info "Installation de Responder via git clone..."
        git clone --depth 1 https://github.com/lgandx/Responder.git /opt/Responder >> "$INSTALL_LOG" 2>&1
        if [ -f /opt/Responder/Responder.py ]; then
            cat > /usr/local/bin/responder << 'WRAPPER'
#!/bin/bash
exec sudo python3 /opt/Responder/Responder.py "$@"
WRAPPER
            chmod +x /usr/local/bin/responder
            log_ok "Responder installé (wrapper /usr/local/bin/responder)"
        else
            log_warn "Échec Responder"
        fi
    else
        log_ok "Responder déjà installé"
    fi

    # impacket : via apt (python3-impacket) ou pipx en fallback
    if apt_try python3-impacket; then
        log_ok "python3-impacket via apt"
    else
        log_info "Installation d'impacket via pipx..."
        pipx_install impacket && log_ok "impacket via pipx" || log_warn "Échec impacket"
    fi

    # NetExec via pipx (évite les conflits avec pyparsing/dnspython système)
    if ! have nxc; then
        log_info "Installation de NetExec via pipx (peut prendre 1-2 min)..."
        if pipx_install git+https://github.com/Pennyw0rth/NetExec; then
            log_ok "NetExec installé (binaire: nxc)"
        else
            log_warn "Échec NetExec"
        fi
    else
        log_ok "NetExec déjà installé"
    fi

    # BloodHound python ingestor via pipx
    if ! have bloodhound-python; then
        pipx_install bloodhound && log_ok "bloodhound-python via pipx" || log_warn "Échec bloodhound"
    else
        log_ok "bloodhound-python déjà installé"
    fi

    # ldapdomaindump via pipx
    if ! have ldapdomaindump; then
        pipx_install ldapdomaindump && log_ok "ldapdomaindump via pipx" || log_warn "Échec ldapdomaindump"
    else
        log_ok "ldapdomaindump déjà installé"
    fi

    # kerbrute (binaire GitHub)
    if ! have kerbrute; then
        log_info "Installation de kerbrute..."
        local kurl
        kurl=$(curl -s https://api.github.com/repos/ropnop/kerbrute/releases/latest \
               | grep -oP '"browser_download_url": "\K[^"]+linux_amd64' | head -1)
        if [ -n "$kurl" ]; then
            curl -sL "$kurl" -o /usr/local/bin/kerbrute \
                && chmod +x /usr/local/bin/kerbrute \
                && log_ok "kerbrute installé"
        else
            log_warn "Échec kerbrute"
        fi
    else
        log_ok "kerbrute déjà installé"
    fi

    # evil-winrm
    if ! have evil-winrm; then
        log_info "Installation de evil-winrm..."
        gem install evil-winrm --no-document &> /dev/null \
            && log_ok "evil-winrm installé" \
            || log_warn "Échec evil-winrm"
    else
        log_ok "evil-winrm déjà installé"
    fi
}

install_cred_tools() {
    log_phase "CREDENTIALS / BRUTE-FORCE"
    for p in hydra medusa john hashcat hashid crunch; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

    # SecLists : énorme (~1.5 Go), donc via git clone (optionnel)
    if [ ! -d /usr/share/seclists ] && [ ! -d /opt/SecLists ]; then
        local avail_kb
        avail_kb=$(df --output=avail / 2>/dev/null | tail -1)
        local avail_gb=$((avail_kb / 1024 / 1024))
        if (( avail_gb > 3 )); then
            log_info "Clone de SecLists dans /opt/SecLists (~1.5 Go)..."
            git clone --depth 1 https://github.com/danielmiessler/SecLists.git /opt/SecLists \
                >> "$INSTALL_LOG" 2>&1 \
                && ln -sf /opt/SecLists /usr/share/seclists \
                && log_ok "SecLists installé" \
                || log_warn "Échec SecLists"
        else
            log_warn "Espace insuffisant pour SecLists, skip"
        fi
    else
        log_ok "SecLists déjà installé"
    fi

    # Lien vers rockyou si présent
    if [ -f /usr/share/wordlists/rockyou.txt.gz ] && [ ! -f /usr/share/wordlists/rockyou.txt ]; then
        gunzip -k /usr/share/wordlists/rockyou.txt.gz && log_ok "rockyou.txt décompressé"
    fi
}

install_exploit_tools() {
    log_phase "EXPLOITATION"

    # Metasploit
    if have msfconsole; then
        log_ok "Metasploit déjà installé"
    else
        log_info "Installation de Metasploit..."
        if apt_try metasploit-framework; then
            log_ok "metasploit-framework via apt"
        else
            log_warn "apt a échoué, tentative via script officiel..."
            curl -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb \
                -o /tmp/msfinstall \
                && chmod +x /tmp/msfinstall \
                && /tmp/msfinstall \
                && rm -f /tmp/msfinstall \
                && log_ok "Metasploit installé"
        fi
        if apt_try postgresql; then
            systemctl start postgresql &> /dev/null
            systemctl enable postgresql &> /dev/null
            msfdb init &> /dev/null || true
        fi
    fi

    # exploitdb / searchsploit : pas dans apt Ubuntu, via git
    if ! have searchsploit; then
        log_info "Installation d'exploitdb (searchsploit) via git..."
        if [ ! -d /opt/exploitdb ]; then
            git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb \
                >> "$INSTALL_LOG" 2>&1
        fi
        if [ -f /opt/exploitdb/searchsploit ]; then
            ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
            log_ok "searchsploit installé"
        else
            log_warn "Échec searchsploit"
        fi
    else
        log_ok "searchsploit déjà installé"
    fi

    # CVE tools : vulners-lookup n'existe pas, on utilise le client vulners directement
    pipx_install vulners && log_ok "vulners (client Python)" || log_warn "Échec vulners"
    pipx_install cve-bin-tool && log_ok "cve-bin-tool via pipx" || log_warn "Échec cve-bin-tool"
}

install_postexpl_tools() {
    log_phase "POST-EXPLOITATION / PIVOTING"

    apt_try proxychains4 && log_ok "proxychains4" || apt_try proxychains && log_ok "proxychains"
    apt_try socat && log_ok "socat"

    # chisel
    if ! have chisel; then
        log_info "Installation de chisel..."
        local curl_url
        curl_url=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest \
                   | grep -oP '"browser_download_url": "\K[^"]+linux_amd64\.gz' | head -1)
        if [ -n "$curl_url" ]; then
            curl -sL "$curl_url" -o /tmp/chisel.gz \
                && gunzip -f /tmp/chisel.gz \
                && mv /tmp/chisel /usr/local/bin/chisel \
                && chmod +x /usr/local/bin/chisel \
                && log_ok "chisel installé"
        else
            log_warn "Échec chisel"
        fi
    else
        log_ok "chisel déjà installé"
    fi

    # ligolo-ng (agent + proxy)
    if ! have ligolo-proxy; then
        log_info "Installation de ligolo-ng..."
        local lurl
        lurl=$(curl -s https://api.github.com/repos/nicocha30/ligolo-ng/releases/latest \
               | grep -oP '"browser_download_url": "\K[^"]+proxy_[^"]+linux_amd64\.tar\.gz' | head -1)
        if [ -n "$lurl" ]; then
            curl -sL "$lurl" -o /tmp/ligolo.tar.gz \
                && tar -xzf /tmp/ligolo.tar.gz -C /tmp/ \
                && mv /tmp/proxy /usr/local/bin/ligolo-proxy 2>/dev/null \
                && chmod +x /usr/local/bin/ligolo-proxy \
                && rm -f /tmp/ligolo.tar.gz \
                && log_ok "ligolo-ng (proxy) installé"
        else
            log_warn "Échec ligolo-ng"
        fi
    else
        log_ok "ligolo-proxy déjà installé"
    fi
}

install_traffic_tools() {
    log_phase "CAPTURE & ANALYSE TRAFIC"
    for p in wireshark tshark tcpdump sslscan ettercap-text-only; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

    # Autoriser les utilisateurs non-root à capturer (wireshark/tshark)
    if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" &> /dev/null; then
        groupadd wireshark &> /dev/null || true
        usermod -aG wireshark "$SUDO_USER" &> /dev/null || true
        if [ -x /usr/bin/dumpcap ]; then
            chgrp wireshark /usr/bin/dumpcap
            chmod 750 /usr/bin/dumpcap
            setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap 2>/dev/null || true
        fi
        log_ok "Utilisateur $SUDO_USER ajouté au groupe wireshark (relogin requis)"
    fi
}

install_reporting_tools() {
    log_phase "REPORTING / RENDU"
    for p in wkhtmltopdf pandoc; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done
}

install_cloud_tools() {
    log_phase "CLOUD (OPTIONNEL)"
    pipx_install prowler && log_ok "prowler via pipx" || log_warn "Échec prowler"
    pipx_install scoutsuite && log_ok "scoutsuite via pipx" || log_warn "Échec scoutsuite"
}

install_web_ui() {
    log_phase "INTERFACE WEB (SPECTER WEB)"
    # Les deps web restent en pip système (besoin d'être importables par specter_web.py)
    if pip_install fastapi "uvicorn[standard]" websockets pydantic; then
        log_ok "Dépendances Python web installées (fastapi, uvicorn, websockets)"
    else
        log_warn "Échec installation des deps web — interface web indisponible"
    fi
}

# ─── Setup final ───────────────────────────────────────────────────────────
setup_directories() {
    log_phase "ARBORESCENCE PROJET"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "$script_dir"/{scans,reports,logs,loot,wordlists}
    mkdir -p "$script_dir/scans"/{nmap,recon,web,ad}

    if [ -n "${SUDO_USER:-}" ] && id "$SUDO_USER" &> /dev/null; then
        chown -R "$SUDO_USER:$SUDO_USER" "$script_dir"/{scans,reports,logs,loot,wordlists}
    fi
    log_ok "Répertoires créés sous $script_dir"
}

verify_installations() {
    log_phase "VÉRIFICATION FINALE"
    local checks=(
        nmap masscan
        subfinder httpx dnsx amass theHarvester whatweb
        ffuf gobuster nuclei nikto dirb sqlmap wapiti wpscan
        impacket-secretsdump nxc kerbrute evil-winrm bloodhound-python responder smbclient
        enum4linux-ng smbmap hashid
        hydra john hashcat
        msfconsole searchsploit
        chisel ligolo-proxy proxychains4
        wireshark tshark tcpdump
        wkhtmltopdf
    )
    local ok=0 ko=0
    for t in "${checks[@]}"; do
        if have "$t"; then
            log_ok "$t"
            ok=$((ok+1))
        else
            log_warn "MANQUANT : $t"
            ko=$((ko+1))
        fi
    done
    echo ""
    echo -e "${BOLD}${GREEN}Outils OK : $ok${NC}  ${BOLD}${YELLOW}Manquants : $ko${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════
#                       SÉLECTION DES GROUPES / OUTILS
# ═══════════════════════════════════════════════════════════════════════════

# Listes globales remplies par le parsing d'arguments
declare -a SKIP_LIST=()
declare -a ONLY_LIST=()
INTERACTIVE=0

# Groupes installables (base et go sont toujours installés)
declare -a INSTALLABLE_GROUPS=(scan recon web ad creds exploit postexpl traffic reporting cloud web-ui)

# Description courte de chaque groupe
group_desc() {
    case $1 in
        scan)      echo "Scan réseau (nmap, masscan, naabu)" ;;
        recon)     echo "Reconnaissance (subfinder, amass, httpx, dnsx, theHarvester...)" ;;
        web)       echo "Web (ffuf, gobuster, dirb, nuclei, nikto, sqlmap, wpscan...)" ;;
        ad)        echo "Active Directory (NetExec, impacket, BloodHound, kerbrute, evil-winrm...)" ;;
        creds)     echo "Credentials (hydra, john, hashcat, SecLists)" ;;
        exploit)   echo "Exploitation (Metasploit, searchsploit, cve-bin-tool)" ;;
        postexpl)  echo "Post-exploitation (chisel, ligolo-ng, proxychains)" ;;
        traffic)   echo "Capture trafic (wireshark, tshark, tcpdump, ettercap)" ;;
        reporting) echo "Reporting (wkhtmltopdf, pandoc)" ;;
        cloud)     echo "Cloud (prowler, scoutsuite)" ;;
        web-ui)    echo "Interface web SPECTER (fastapi, uvicorn, websockets)" ;;
        *)         echo "" ;;
    esac
}

# Renvoie 0 (vrai) si le groupe doit être skippé
should_skip_group() {
    local g=$1
    # Mode --only : on installe SEULEMENT ce qui est dans ONLY_LIST
    if [ ${#ONLY_LIST[@]} -gt 0 ]; then
        local found=0
        for o in "${ONLY_LIST[@]}"; do
            [ "$o" = "$g" ] && found=1 && break
        done
        (( found == 0 )) && return 0
    fi
    # Mode --skip : on saute si présent dans SKIP_LIST
    for s in "${SKIP_LIST[@]}"; do
        [ "$s" = "$g" ] && return 0
    done
    return 1
}

# Renvoie 0 si un outil individuel doit être skippé
should_skip_tool() {
    local t=$1
    for s in "${SKIP_LIST[@]}"; do
        [ "$s" = "$t" ] && return 0
    done
    return 1
}

# Marque un groupe comme skippé (pour le log)
phase_skipped() {
    echo -e "\n${YELLOW}${BOLD}── SKIP groupe : $1 ── ${DIM}($(group_desc "$1"))${NC}"
}

# ─── Help / List / Interactive ─────────────────────────────────────────────

show_help() {
    cat << EOF
${BOLD}SPECTER Toolkit — Installer${NC}

${BOLD}USAGE${NC}
    sudo ./install.sh [OPTIONS]

${BOLD}DESCRIPTION${NC}
    Installe le toolkit SPECTER. Par défaut, installe TOUS les outils.
    Utilise --skip ou --only pour contrôler ce qui est installé.

${BOLD}OPTIONS${NC}
    -h, --help              Affiche cette aide
    -l, --list              Liste les groupes et leurs outils
    -i, --interactive       Sélection interactive (menu à cases à cocher)
    -s, --skip <LISTE>      Groupes ou outils à NE PAS installer (séparés par virgule)
    -o, --only <LISTE>      Groupes à installer (exclusif, séparés par virgule)

${BOLD}GROUPES DISPONIBLES${NC}
    scan, recon, web, ad, creds, exploit, postexpl, traffic, reporting, cloud, web-ui

${BOLD}EXEMPLES${NC}
    ${GREEN}sudo ./install.sh${NC}
        Installe tout

    ${GREEN}sudo ./install.sh --skip cloud,reporting${NC}
        Installe tout sauf le cloud et le reporting

    ${GREEN}sudo ./install.sh --only web,recon${NC}
        Installe uniquement les phases web et reconnaissance

    ${GREEN}sudo ./install.sh --skip nuclei,amass${NC}
        Installe tout sauf ces 2 outils

    ${GREEN}sudo ./install.sh --interactive${NC}
        Lance le menu interactif (whiptail)

${BOLD}NOTES${NC}
    - Les dépendances de base (curl, git, python3, go) sont toujours installées.
    - --skip et --only sont mutuellement exclusifs ; si les deux sont fournis,
      --only l'emporte.
EOF
}

show_list() {
    echo -e "${BOLD}${CYAN}Groupes installables :${NC}\n"
    for g in "${INSTALLABLE_GROUPS[@]}"; do
        printf "  ${GREEN}%-10s${NC} ${DIM}%s${NC}\n" "$g" "$(group_desc "$g")"
    done
    echo ""
    echo -e "${DIM}Pour skipper un groupe : sudo ./install.sh --skip <nom>${NC}"
    echo -e "${DIM}Pour n'installer que certains : sudo ./install.sh --only <nom,...>${NC}"
}

run_interactive() {
    if ! have whiptail; then
        log_warn "whiptail manquant — fallback sur sélection texte"
        echo ""
        echo -e "${BOLD}Coche les groupes à installer (espace pour toggle, entrée pour valider)${NC}"
        local chosen=()
        for g in "${INSTALLABLE_GROUPS[@]}"; do
            read -p "  Installer ${BOLD}$g${NC} ? ($(group_desc "$g")) [O/n] " yn
            if [[ ! "$yn" =~ ^[nN]$ ]]; then
                chosen+=("$g")
            fi
        done
        ONLY_LIST=("${chosen[@]}")
        return
    fi

    # Whiptail checklist
    local items=()
    for g in "${INSTALLABLE_GROUPS[@]}"; do
        items+=("$g" "$(group_desc "$g")" "ON")
    done
    local result
    result=$(whiptail --title "SPECTER Installer" \
        --checklist "Sélectionne les groupes à installer (Espace pour toggle, Tab pour OK)" \
        20 78 11 \
        "${items[@]}" \
        3>&1 1>&2 2>&3) || { echo "Annulé."; exit 0; }
    # Result : "scan" "recon" "web" → split en array
    ONLY_LIST=()
    for word in $result; do
        ONLY_LIST+=("${word//\"/}")
    done
    if [ ${#ONLY_LIST[@]} -eq 0 ]; then
        echo "Aucun groupe sélectionné, abandon."
        exit 0
    fi
}

# ─── Parsing des arguments ─────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)         show_help; exit 0 ;;
            -l|--list)         show_list; exit 0 ;;
            -i|--interactive)  INTERACTIVE=1; shift ;;
            -s|--skip)
                IFS=',' read -ra SKIP_LIST <<< "$2"
                shift 2
                ;;
            -o|--only)
                IFS=',' read -ra ONLY_LIST <<< "$2"
                shift 2
                ;;
            --skip=*)
                IFS=',' read -ra SKIP_LIST <<< "${1#*=}"
                shift
                ;;
            --only=*)
                IFS=',' read -ra ONLY_LIST <<< "${1#*=}"
                shift
                ;;
            *)
                log_err "Option inconnue : $1"
                echo "Utilise --help pour l'aide."
                exit 1
                ;;
        esac
    done
}

# ─── Programme principal ───────────────────────────────────────────────────

# Exécute une phase si pas skippée
run_phase() {
    local group=$1
    local fn=$2
    if should_skip_group "$group"; then
        phase_skipped "$group"
        return
    fi
    "$fn"
}

main() {
    parse_args "$@"

    print_banner
    check_root
    detect_os
    check_disk_space

    # En mode interactif, on demande maintenant ce qu'il faut installer
    if (( INTERACTIVE )); then
        run_interactive
    fi

    # Affiche le plan d'install
    echo -e "\n${BOLD}${CYAN}Plan d'installation :${NC}"
    if [ ${#ONLY_LIST[@]} -gt 0 ]; then
        echo -e "  Mode ${BOLD}--only${NC}, groupes : ${GREEN}${ONLY_LIST[*]}${NC}"
    elif [ ${#SKIP_LIST[@]} -gt 0 ]; then
        echo -e "  Mode ${BOLD}--skip${NC}, exclusions : ${YELLOW}${SKIP_LIST[*]}${NC}"
    else
        echo -e "  Mode ${BOLD}complet${NC} (tous les groupes)"
    fi
    sleep 1

    update_system

    # Phases toujours installées (prérequis)
    install_base
    setup_pipx
    install_go

    # Phases optionnelles via --skip / --only
    run_phase scan      install_scan_tools
    run_phase recon     install_recon_tools
    run_phase web       install_web_tools
    run_phase ad        install_ad_tools
    run_phase creds     install_cred_tools
    run_phase exploit   install_exploit_tools
    run_phase postexpl  install_postexpl_tools
    run_phase traffic   install_traffic_tools
    run_phase reporting install_reporting_tools
    run_phase cloud     install_cloud_tools
    run_phase web-ui    install_web_ui

    setup_directories
    verify_installations

    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   Installation terminée                    ║${NC}"
    echo -e "${GREEN}${BOLD}║   CLI : ./specter.sh                       ║${NC}"
    echo -e "${GREEN}${BOLD}║   Web : python3 specter_web.py             ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════╝${NC}"
}

main "$@"
