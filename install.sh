#!/bin/bash
#
# Pentest Toolkit — Installer
# Installe l'ensemble des outils nécessaires au CLI principal.
# Compatible Debian/Ubuntu/Kali.
#

set -u

# ─── Couleurs ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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
    if dpkg -s "$1" &> /dev/null; then
        return 0
    fi
    logf "apt install $1"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >> "$INSTALL_LOG" 2>&1
}

# Installe via pip (avec fallback --break-system-packages pour PEP 668)
pip_install() {
    logf "pip install $*"
    python3 -m pip install --upgrade "$@" >> "$INSTALL_LOG" 2>&1 \
        || python3 -m pip install --upgrade --break-system-packages "$@" >> "$INSTALL_LOG" 2>&1
}

# Installe un binaire Go (ProjectDiscovery, etc.) dans /usr/local/bin
go_install_bin() {
    local pkg=$1
    local name
    name=$(basename "${pkg%@*}")
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

install_base() {
    log_phase "DÉPENDANCES DE BASE"
    local pkgs=(
        curl wget git jq bc unzip
        python3 python3-pip python3-venv
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

    # rustscan : binaire .deb depuis GitHub
    if ! have rustscan; then
        log_info "Installation de rustscan..."
        local url
        url=$(curl -s https://api.github.com/repos/RustScan/RustScan/releases/latest \
              | grep -oP '"browser_download_url": "\K[^"]+amd64\.deb' | head -1)
        if [ -n "$url" ]; then
            curl -sL "$url" -o /tmp/rustscan.deb \
                && dpkg -i /tmp/rustscan.deb &> /dev/null \
                && rm -f /tmp/rustscan.deb \
                && log_ok "rustscan installé"
        else
            log_warn "Échec rustscan (release non trouvée)"
        fi
    else
        log_ok "rustscan déjà installé"
    fi

    # naabu (ProjectDiscovery)
    go_install_bin github.com/projectdiscovery/naabu/v2/cmd/naabu@latest
}

install_recon_tools() {
    log_phase "RECONNAISSANCE / OSINT"

    # Apt
    for p in whatweb amass theharvester; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

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

    # feroxbuster (binaire officiel)
    if ! have feroxbuster; then
        log_info "Installation de feroxbuster..."
        curl -sL https://raw.githubusercontent.com/epi052/feroxbuster/main/install-nix.sh \
            | bash -s -- --bin /usr/local/bin &> /dev/null \
            && log_ok "feroxbuster installé" \
            || log_warn "Échec feroxbuster"
    else
        log_ok "feroxbuster déjà installé"
    fi

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

    # Apt
    for p in smbclient ldap-utils smbmap enum4linux responder ldapscripts hashid; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done

    # impacket (suite complète : secretsdump, GetNPUsers, GetUserSPNs, psexec, etc.)
    log_info "Installation d'impacket..."
    if pip_install impacket; then
        log_ok "impacket installé"
    else
        apt_try python3-impacket && log_ok "python3-impacket via apt"
    fi

    # NetExec (successeur de CrackMapExec)
    if ! have nxc && ! have netexec; then
        log_info "Installation de NetExec..."
        if pip_install git+https://github.com/Pennyw0rth/NetExec; then
            log_ok "NetExec installé (binaire: nxc)"
        else
            log_warn "Échec NetExec"
        fi
    else
        log_ok "NetExec déjà installé"
    fi

    # BloodHound python-ingestor
    pip_install bloodhound && log_ok "bloodhound-python installé" || log_warn "Échec bloodhound"

    # ldapdomaindump
    pip_install ldapdomaindump && log_ok "ldapdomaindump installé" || log_warn "Échec ldapdomaindump"

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
    for p in hydra medusa john hashcat hashid crunch seclists; do
        if apt_try "$p"; then log_ok "$p"; else log_warn "Échec apt : $p"; fi
    done
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

    # exploitdb / searchsploit
    if apt_try exploitdb; then log_ok "exploitdb (searchsploit)"; fi

    # CVE tools
    pip_install vulners-lookup && log_ok "vulners-lookup" || log_warn "Échec vulners-lookup"
    pip_install cve-bin-tool && log_ok "cve-bin-tool" || log_warn "Échec cve-bin-tool"
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
    pip_install prowler && log_ok "prowler" || log_warn "Échec prowler"
    pip_install scoutsuite && log_ok "scoutsuite" || log_warn "Échec scoutsuite"
}

install_web_ui() {
    log_phase "INTERFACE WEB (SPECTER WEB)"
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
        nmap masscan rustscan
        subfinder httpx dnsx amass theHarvester whatweb
        ffuf gobuster feroxbuster nuclei nikto dirb sqlmap wapiti wpscan
        impacket-secretsdump nxc kerbrute evil-winrm bloodhound-python responder smbclient
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

# ─── Programme principal ───────────────────────────────────────────────────
main() {
    print_banner
    check_root
    detect_os
    check_disk_space
    update_system

    install_base
    install_go
    install_scan_tools
    install_recon_tools
    install_web_tools
    install_ad_tools
    install_cred_tools
    install_exploit_tools
    install_postexpl_tools
    install_traffic_tools
    install_reporting_tools
    install_cloud_tools
    install_web_ui

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
