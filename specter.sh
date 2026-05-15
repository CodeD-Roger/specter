#!/bin/bash
#
# SPECTER — Pentest Toolkit CLI
# Workflow red team structuré par phases :
#   Recon → Scan → Web → AD → Creds → Exploit → Post-expl → Traffic → Cloud
#
# Auteur : CodeD-Roger
# Lancement : ./specter.sh
#

# ═══════════════════════════════════════════════════════════════════════════
#                              CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arborescence
SCAN_DIR="$SCRIPT_DIR/scans"
NMAP_DIR="$SCAN_DIR/nmap"
RECON_DIR="$SCAN_DIR/recon"
WEB_DIR="$SCAN_DIR/web"
AD_DIR="$SCAN_DIR/ad"
REPORTS_DIR="$SCRIPT_DIR/reports"
LOGS_DIR="$SCRIPT_DIR/logs"
LOOT_DIR="$SCRIPT_DIR/loot"
WORDLISTS_DIR="$SCRIPT_DIR/wordlists"
SCAN_RESULTS="$LOGS_DIR/scan_results.dat"
ALERT_CONFIG="$LOGS_DIR/alert_thresholds.conf"

mkdir -p "$NMAP_DIR" "$RECON_DIR" "$WEB_DIR" "$AD_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$LOOT_DIR" "$WORDLISTS_DIR"

DATE() { date +%Y%m%d_%H%M%S; }

# Contexte courant (mémorisé entre actions)
target_host=""
target_domain=""

# Options nmap avancées
FRAG_OPTIONS=""
SPOOF_OPTIONS=""
BW_OPTIONS=""
SCAN_OPTIONS=""

# ═══════════════════════════════════════════════════════════════════════════
#                              PALETTE & UI
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Logs colorés
info()  { echo -e "  ${BLUE}[*]${NC} $*"; }
ok()    { echo -e "  ${GREEN}[+]${NC} $*"; }
warn()  { echo -e "  ${YELLOW}[!]${NC} $*"; }
err()   { echo -e "  ${RED}[-]${NC} $*"; }

# Largeur d'affichage (boîtes, séparateurs)
UI_WIDTH=72

# Imprime une ligne horizontale
hr() {
    local char=${1:-─}
    printf "${CYAN}"
    printf "${char}%.0s" $(seq 1 $UI_WIDTH)
    printf "${NC}\n"
}

# Imprime un titre dans une boîte unicode
box() {
    local title=$1
    local color=${2:-$CYAN}
    local inner=$((UI_WIDTH - 2))
    local pad=$(( inner - ${#title} - 2 ))
    (( pad < 0 )) && pad=0

    printf "${color}╔"
    printf '═%.0s' $(seq 1 $inner)
    printf "╗${NC}\n"
    printf "${color}║${NC} ${BOLD}${WHITE}%s${NC}%*s ${color}║${NC}\n" "$title" "$pad" ""
    printf "${color}╚"
    printf '═%.0s' $(seq 1 $inner)
    printf "╝${NC}\n"
}

# Bannière principale
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║   ███████╗██████╗ ███████╗ ██████╗████████╗███████╗██████╗        ║
    ║   ██╔════╝██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗       ║
    ║   ███████╗██████╔╝█████╗  ██║        ██║   █████╗  ██████╔╝       ║
    ║   ╚════██║██╔═══╝ ██╔══╝  ██║        ██║   ██╔══╝  ██╔══██╗       ║
    ║   ███████║██║     ███████╗╚██████╗   ██║   ███████╗██║  ██║       ║
    ║   ╚══════╝╚═╝     ╚══════╝ ╚═════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝       ║
    ║                  P E N T E S T   T O O L K I T                    ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    # Bandeau de contexte
    printf "  ${DIM}Cible:${NC} ${GREEN}${target_host:-<aucune>}${NC}"
    [ -n "$target_domain" ] && printf "  ${DIM}Domaine:${NC} ${GREEN}${target_domain}${NC}"
    printf "  ${DIM}Date:${NC} %s\n\n" "$(date '+%Y-%m-%d %H:%M')"
}

# Imprime un item de menu : "  [X] - Description"
menu_item() {
    local key=$1; shift
    local label=$1; shift
    local desc=${1:-}
    printf "  ${GREEN}${BOLD}[%s]${NC}  ${WHITE}%-22s${NC}" "$key" "$label"
    [ -n "$desc" ] && printf " ${DIM}%s${NC}" "$desc"
    printf "\n"
}

menu_section() {
    printf "\n  ${MAGENTA}${BOLD}── %s${NC}\n" "$*"
}

# Pause générique
pause() {
    echo ""
    read -p "  Appuyez sur Entrée pour continuer..."
}

# ═══════════════════════════════════════════════════════════════════════════
#                              HELPERS
# ═══════════════════════════════════════════════════════════════════════════

have() { command -v "$1" &> /dev/null; }

# Vérifie qu'un outil est dispo, sinon prévient et retourne 1
require_tool() {
    local tool=$1
    if ! have "$tool"; then
        err "Outil manquant : ${BOLD}$tool${NC}"
        warn "Lance ./install.sh pour l'installer"
        pause
        return 1
    fi
    return 0
}

# Demande une cible et la valide (IP, hostname, CIDR)
ask_target() {
    local prompt=${1:-"Cible (IP / hostname / CIDR)"}
    local default=${2:-$target_host}
    local input
    if [ -n "$default" ]; then
        read -p "  ❯ $prompt [${DIM}$default${NC}] : " input
        input=${input:-$default}
    else
        read -p "  ❯ $prompt : " input
    fi
    if [[ ! "$input" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
        err "Cible invalide (caractères autorisés : A-Z a-z 0-9 . : / - _)"
        return 1
    fi
    target_host="$input"
    REPLY_TARGET="$input"
    return 0
}

# Demande un domaine (pour subfinder, amass, etc.)
ask_domain() {
    local input
    if [ -n "$target_domain" ]; then
        read -p "  ❯ Domaine [${DIM}$target_domain${NC}] : " input
        input=${input:-$target_domain}
    else
        read -p "  ❯ Domaine cible (ex: example.com) : " input
    fi
    if [[ ! "$input" =~ ^[A-Za-z0-9.-]+$ ]]; then
        err "Domaine invalide"
        return 1
    fi
    target_domain="$input"
    REPLY_DOMAIN="$input"
    return 0
}

# Demande une URL
ask_url() {
    local input
    read -p "  ❯ URL cible (ex: https://example.com) : " input
    local url_re='^https?://[A-Za-z0-9._:/?&=#%~+-]+$'
    if [[ ! "$input" =~ $url_re ]]; then
        err "URL invalide"
        return 1
    fi
    REPLY_URL="$input"
    return 0
}

# Demande une wordlist, propose les classiques
ask_wordlist() {
    local default=""
    for c in /usr/share/wordlists/dirb/common.txt \
             /usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt \
             /usr/share/seclists/Discovery/Web-Content/common.txt; do
        if [ -f "$c" ]; then default=$c; break; fi
    done
    local input
    if [ -n "$default" ]; then
        read -p "  ❯ Wordlist [${DIM}$default${NC}] : " input
        input=${input:-$default}
    else
        read -p "  ❯ Chemin de la wordlist : " input
    fi
    if [ ! -f "$input" ]; then
        err "Wordlist introuvable : $input"
        return 1
    fi
    REPLY_WORDLIST="$input"
    return 0
}

# Lance une commande, log la sortie dans un fichier, et affiche un résumé
run_logged() {
    local label=$1; shift
    local outfile=$1; shift
    info "Exécution : $label"
    info "Sortie    : $outfile"
    hr "─"
    "$@" 2>&1 | tee "$outfile"
    hr "─"
    ok "Terminé. Résultats : $outfile"
}

# Taille humaine
_human_size() {
    local bytes=$1
    if   (( bytes < 1024 ));         then printf "%dB"   "$bytes"
    elif (( bytes < 1048576 ));      then printf "%.1fKB" "$(echo "$bytes/1024" | bc -l)"
    elif (( bytes < 1073741824 ));   then printf "%.1fMB" "$(echo "$bytes/1048576" | bc -l)"
    else                                  printf "%.1fGB" "$(echo "$bytes/1073741824" | bc -l)"
    fi
}

# Colorise les sorties de scan (ports, sévérité, CVE…)
colorize_output() {
    sed -E \
        -e "s/(open[[:space:]])/$(printf "${GREEN}")\1$(printf "${NC}")/g" \
        -e "s/(closed[[:space:]])/$(printf "${RED}")\1$(printf "${NC}")/g" \
        -e "s/(filtered[[:space:]])/$(printf "${YELLOW}")\1$(printf "${NC}")/g" \
        -e "s/(VULNERABLE[^[:space:]]*)/$(printf "${RED}${BOLD}")\1$(printf "${NC}")/gI" \
        -e "s/(\\[CRITICAL\\]|\\[HIGH\\])/$(printf "${RED}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/(\\[MEDIUM\\])/$(printf "${YELLOW}")\1$(printf "${NC}")/g" \
        -e "s/(\\[LOW\\]|\\[INFO\\])/$(printf "${BLUE}")\1$(printf "${NC}")/g" \
        -e "s/(CVE-[0-9]{4}-[0-9]+)/$(printf "${MAGENTA}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/(Nmap scan report for[^|]*)/$(printf "${CYAN}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/^(PORT[[:space:]]+STATE.*)/$(printf "${BOLD}${WHITE}")\1$(printf "${NC}")/" \
        -e "s/(Host is up[^|]*)/$(printf "${GREEN}")\1$(printf "${NC}")/g"
}

# Construit le tableau d'options avancées si elles ont été configurées
_extra_opts() {
    local -a opts=()
    local -a tmp
    [ -n "$FRAG_OPTIONS"  ] && { read -r -a tmp <<< "$FRAG_OPTIONS";  opts+=("${tmp[@]}"); }
    [ -n "$SPOOF_OPTIONS" ] && { read -r -a tmp <<< "$SPOOF_OPTIONS"; opts+=("${tmp[@]}"); }
    [ -n "$BW_OPTIONS"    ] && { read -r -a tmp <<< "$BW_OPTIONS";    opts+=("${tmp[@]}"); }
    [ -n "$SCAN_OPTIONS"  ] && { read -r -a tmp <<< "$SCAN_OPTIONS";  opts+=("${tmp[@]}"); }
    printf '%s\n' "${opts[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
#                       1. RECONNAISSANCE / OSINT
# ═══════════════════════════════════════════════════════════════════════════

recon_menu() {
    while true; do
        show_banner
        box "🔎 RECONNAISSANCE / OSINT" "$BLUE"
        menu_section "Sous-domaines"
        menu_item 1 "subfinder"      "énum passive rapide"
        menu_item 2 "amass"          "énum active + passive"
        menu_item 3 "assetfinder"    "alternative rapide"
        menu_section "DNS"
        menu_item 4 "dnsx"           "résolution massive"
        menu_item 5 "dig / whois"    "lookup classique"
        menu_section "HTTP probing & fingerprint"
        menu_item 6 "httpx"          "probe live (titre, code, techno)"
        menu_item 7 "whatweb"        "fingerprint techno"
        menu_item 8 "katana"         "crawler web moderne"
        menu_section "OSINT / Emails"
        menu_item 9  "theHarvester"  "emails, sous-domaines, OSINT"
        menu_item 10 "waybackurls"   "URLs historiques wayback"
        menu_section "Pipeline"
        menu_item 11 "FULL RECON"    "subfinder→dnsx→httpx (auto)"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1)  tool_subfinder ;;
            2)  tool_amass ;;
            3)  tool_assetfinder ;;
            4)  tool_dnsx ;;
            5)  tool_dig_whois ;;
            6)  tool_httpx ;;
            7)  tool_whatweb ;;
            8)  tool_katana ;;
            9)  tool_theharvester ;;
            10) tool_waybackurls ;;
            11) pipeline_full_recon ;;
            r)  return ;;
            *)  err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_subfinder() {
    require_tool subfinder || return
    ask_domain || return
    local out="$RECON_DIR/subfinder_${REPLY_DOMAIN}_$(DATE).txt"
    run_logged "subfinder -d $REPLY_DOMAIN" "$out" subfinder -d "$REPLY_DOMAIN" -silent
    pause
}

tool_amass() {
    require_tool amass || return
    ask_domain || return
    local out="$RECON_DIR/amass_${REPLY_DOMAIN}_$(DATE).txt"
    run_logged "amass enum -passive -d $REPLY_DOMAIN" "$out" amass enum -passive -d "$REPLY_DOMAIN"
    pause
}

tool_assetfinder() {
    require_tool assetfinder || return
    ask_domain || return
    local out="$RECON_DIR/assetfinder_${REPLY_DOMAIN}_$(DATE).txt"
    run_logged "assetfinder $REPLY_DOMAIN" "$out" assetfinder --subs-only "$REPLY_DOMAIN"
    pause
}

tool_dnsx() {
    require_tool dnsx || return
    read -p "  ❯ Fichier de domaines (ou entrée pour saisir une cible) : " input
    local out="$RECON_DIR/dnsx_$(DATE).txt"
    if [ -n "$input" ] && [ -f "$input" ]; then
        run_logged "dnsx -l $input -resp" "$out" dnsx -l "$input" -resp -silent
    else
        ask_target "Domaine ou IP" || return
        run_logged "dnsx -d $REPLY_TARGET" "$out" bash -c "echo '$REPLY_TARGET' | dnsx -resp -silent"
    fi
    pause
}

tool_dig_whois() {
    ask_target "Domaine ou IP" || return
    local out="$RECON_DIR/dig_whois_${REPLY_TARGET}_$(DATE).txt"
    {
        echo "═══ DIG ANY ═══"; dig +noall +answer "$REPLY_TARGET" ANY 2>&1
        echo ""; echo "═══ DIG MX ═══"; dig +short MX "$REPLY_TARGET" 2>&1
        echo ""; echo "═══ DIG NS ═══"; dig +short NS "$REPLY_TARGET" 2>&1
        echo ""; echo "═══ WHOIS ═══"; whois "$REPLY_TARGET" 2>&1 | head -60
    } | tee "$out" | colorize_output
    ok "Résultats : $out"
    pause
}

tool_httpx() {
    require_tool httpx || return
    read -p "  ❯ Fichier d'hôtes (ou entrée pour une cible) : " input
    local out="$RECON_DIR/httpx_$(DATE).txt"
    if [ -n "$input" ] && [ -f "$input" ]; then
        run_logged "httpx -l $input" "$out" httpx -l "$input" -title -status-code -tech-detect -silent
    else
        ask_target "URL ou hôte" || return
        run_logged "httpx $REPLY_TARGET" "$out" bash -c "echo '$REPLY_TARGET' | httpx -title -status-code -tech-detect -silent"
    fi
    pause
}

tool_whatweb() {
    require_tool whatweb || return
    ask_url || return
    local out="$RECON_DIR/whatweb_$(DATE).txt"
    run_logged "whatweb $REPLY_URL" "$out" whatweb -v "$REPLY_URL"
    pause
}

tool_katana() {
    require_tool katana || return
    ask_url || return
    local out="$RECON_DIR/katana_$(DATE).txt"
    run_logged "katana -u $REPLY_URL" "$out" katana -u "$REPLY_URL" -silent
    pause
}

tool_theharvester() {
    require_tool theHarvester || return
    ask_domain || return
    local out="$RECON_DIR/theharvester_${REPLY_DOMAIN}_$(DATE).txt"
    run_logged "theHarvester -d $REPLY_DOMAIN -b all" "$out" theHarvester -d "$REPLY_DOMAIN" -b all -l 200
    pause
}

tool_waybackurls() {
    require_tool waybackurls || return
    ask_domain || return
    local out="$RECON_DIR/waybackurls_${REPLY_DOMAIN}_$(DATE).txt"
    run_logged "waybackurls $REPLY_DOMAIN" "$out" bash -c "echo '$REPLY_DOMAIN' | waybackurls"
    pause
}

pipeline_full_recon() {
    require_tool subfinder || return
    require_tool dnsx || return
    require_tool httpx || return
    ask_domain || return
    local dom=$REPLY_DOMAIN
    local ts=$(DATE)
    local subs="$RECON_DIR/${dom}_subs_${ts}.txt"
    local live="$RECON_DIR/${dom}_live_${ts}.txt"
    local probe="$RECON_DIR/${dom}_probe_${ts}.txt"

    box "🚀 PIPELINE FULL RECON : $dom" "$MAGENTA"
    info "Étape 1/3 — subfinder"
    subfinder -d "$dom" -silent > "$subs"
    ok "$(wc -l < "$subs") sous-domaines trouvés"

    info "Étape 2/3 — dnsx (résolution)"
    dnsx -l "$subs" -silent > "$live"
    ok "$(wc -l < "$live") sous-domaines vivants"

    info "Étape 3/3 — httpx (probe)"
    httpx -l "$live" -title -status-code -tech-detect -silent > "$probe"
    ok "$(wc -l < "$probe") serveurs web actifs"

    echo ""
    box "📊 Résultats" "$GREEN"
    head -30 "$probe" | colorize_output
    echo ""
    ok "Sous-domaines : $subs"
    ok "Vivants       : $live"
    ok "Probe web     : $probe"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       2. SCAN RÉSEAU
# ═══════════════════════════════════════════════════════════════════════════

scan_menu() {
    while true; do
        show_banner
        box "🛰️  SCAN RÉSEAU" "$BLUE"
        menu_section "Nmap — types de scan"
        menu_item 1 "SYN furtif"     "défaut, rapide"
        menu_item 2 "Ultra discret"  "T2 + fragmentation + leurres"
        menu_item 3 "Agressif (-A)"  "OS + versions + scripts"
        menu_item 4 "Full TCP"       "tous les ports (1-65535)"
        menu_item 5 "UDP"            "services UDP"
        menu_item 6 "IPv6"           "scan IPv6"
        menu_item 7 "ACK"            "détection règles firewall"
        menu_section "Scans rapides"
        menu_item 8  "masscan"       "ultra-rapide"
        menu_item 9  "rustscan"      "Rust + nmap"
        menu_item 10 "naabu"         "ProjectDiscovery"
        menu_section "NSE"
        menu_item 11 "Scripts NSE"   "vuln, auth, discovery..."
        menu_section "Résultats"
        menu_item 12 "Voir les scans" "explorer les résultats"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1)  nmap_scan stealth ;;
            2)  nmap_scan ultra ;;
            3)  nmap_scan aggressive ;;
            4)  nmap_scan fulltcp ;;
            5)  nmap_scan udp ;;
            6)  nmap_scan ipv6 ;;
            7)  nmap_scan ack ;;
            8)  tool_masscan ;;
            9)  tool_rustscan ;;
            10) tool_naabu ;;
            11) nse_menu ;;
            12) view_scan_results "$NMAP_DIR" "Nmap" ;;
            r)  return ;;
            *)  err "Option invalide"; sleep 1 ;;
        esac
    done
}

nmap_scan() {
    require_tool nmap || return
    local kind=$1
    ask_target || return
    local target=$REPLY_TARGET
    local out="$NMAP_DIR/${kind}_${target//\//_}_$(DATE).txt"
    local -a base=(sudo nmap -v)
    local -a extra; mapfile -t extra < <(_extra_opts)

    case $kind in
        stealth)
            read -p "  ❯ Timing T0-T5 (entrée pour défaut) : " t
            local -a cmd=("${base[@]}" -sS)
            [[ $t =~ ^[0-5]$ ]] && cmd+=("-T$t")
            run_logged "Nmap SYN $target" "$out" "${cmd[@]}" "${extra[@]}" "$target"
            ;;
        ultra)
            run_logged "Nmap ultra-discret $target" "$out" \
                "${base[@]}" -sS -T2 -f -D RND:5 --data-length 24 "$target"
            ;;
        aggressive)
            run_logged "Nmap agressif -A $target" "$out" \
                "${base[@]}" -A -T4 "${extra[@]}" "$target"
            ;;
        fulltcp)
            run_logged "Nmap Full TCP $target" "$out" \
                "${base[@]}" -sT -p- "${extra[@]}" "$target"
            ;;
        udp)
            run_logged "Nmap UDP $target" "$out" \
                "${base[@]}" -sU --top-ports 200 "${extra[@]}" "$target"
            ;;
        ipv6)
            run_logged "Nmap IPv6 $target" "$out" \
                "${base[@]}" -6 "${extra[@]}" "$target"
            ;;
        ack)
            run_logged "Nmap ACK $target" "$out" \
                "${base[@]}" -sA "${extra[@]}" "$target"
            ;;
    esac
    pause
}

tool_masscan() {
    require_tool masscan || return
    ask_target || return
    read -p "  ❯ Ports (défaut: 1-65535) : " ports
    ports=${ports:-1-65535}
    read -p "  ❯ Taux pps (défaut: 1000) : " rate
    rate=${rate:-1000}
    local out="$NMAP_DIR/masscan_${REPLY_TARGET//\//_}_$(DATE).txt"
    run_logged "masscan $REPLY_TARGET -p $ports --rate=$rate" "$out" \
        sudo masscan "$REPLY_TARGET" -p "$ports" --rate="$rate"
    pause
}

tool_rustscan() {
    require_tool rustscan || return
    ask_target || return
    local out="$NMAP_DIR/rustscan_${REPLY_TARGET//\//_}_$(DATE).txt"
    run_logged "rustscan -a $REPLY_TARGET" "$out" rustscan -a "$REPLY_TARGET" --ulimit 5000
    pause
}

tool_naabu() {
    require_tool naabu || return
    ask_target || return
    local out="$NMAP_DIR/naabu_${REPLY_TARGET//\//_}_$(DATE).txt"
    run_logged "naabu -host $REPLY_TARGET" "$out" naabu -host "$REPLY_TARGET" -silent
    pause
}

# ─── NSE ───────────────────────────────────────────────────────────────────

nse_menu() {
    while true; do
        show_banner
        box "🧠 SCRIPTS NSE (Nmap)" "$BLUE"
        menu_item 1 "vuln"          "détection vulnérabilités"
        menu_item 2 "exploit"       "tentatives d'exploitation"
        menu_item 3 "auth"          "tests d'authentification"
        menu_item 4 "discovery"     "découverte réseau"
        menu_item 5 "safe"          "scripts non intrusifs"
        menu_item 6 "all"           "tous (long et bruyant)"
        menu_item 7 "custom"        "script personnalisé"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) nse_scan vuln ;;
            2) nse_scan exploit ;;
            3) nse_scan auth ;;
            4) nse_scan discovery ;;
            5) nse_scan safe ;;
            6) nse_scan all ;;
            7) nse_scan_custom ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

nse_scan() {
    require_tool nmap || return
    local category=$1
    ask_target || return
    local out="$NMAP_DIR/nse_${category}_${REPLY_TARGET//\//_}_$(DATE).txt"
    run_logged "Nmap NSE --script $category" "$out" sudo nmap --script "$category" "$REPLY_TARGET"
    pause
}

nse_scan_custom() {
    require_tool nmap || return
    read -p "  ❯ Nom du script NSE (ex: http-enum,smb-vuln-*) : " script
    if [[ ! "$script" =~ ^[A-Za-z0-9_,.\*-]+$ ]]; then
        err "Nom invalide"; pause; return
    fi
    ask_target || return
    local out="$NMAP_DIR/nse_custom_$(DATE).txt"
    run_logged "Nmap NSE custom $script" "$out" sudo nmap --script "$script" "$REPLY_TARGET"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       3. WEB APPLICATION
# ═══════════════════════════════════════════════════════════════════════════

web_menu() {
    while true; do
        show_banner
        box "🌐 WEB APPLICATION" "$BLUE"
        menu_section "Fuzzing / brute-force"
        menu_item 1 "ffuf"          "fuzzer rapide (recommandé)"
        menu_item 2 "feroxbuster"   "récursif (Rust)"
        menu_item 3 "gobuster"      "directories / DNS"
        menu_item 4 "dirb"          "classique"
        menu_section "Vulnérabilités"
        menu_item 5 "nuclei"        "templates ⭐"
        menu_item 6 "nikto"         "scanner web"
        menu_item 7 "wapiti"        "scanner auto"
        menu_section "Spécialisés"
        menu_item 8  "sqlmap"       "SQL injection"
        menu_item 9  "wpscan"       "WordPress"
        menu_item 10 "sslscan"      "TLS / SSL"
        menu_section "Résultats"
        menu_item 11 "Voir les scans" "explorer les résultats"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1)  tool_ffuf ;;
            2)  tool_feroxbuster ;;
            3)  tool_gobuster ;;
            4)  tool_dirb ;;
            5)  tool_nuclei ;;
            6)  tool_nikto ;;
            7)  tool_wapiti ;;
            8)  tool_sqlmap ;;
            9)  tool_wpscan ;;
            10) tool_sslscan ;;
            11) view_scan_results "$WEB_DIR" "Web" ;;
            r)  return ;;
            *)  err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_ffuf() {
    require_tool ffuf || return
    ask_url || return
    ask_wordlist || return
    local url="${REPLY_URL%/}/FUZZ"
    local out="$WEB_DIR/ffuf_$(DATE).txt"
    run_logged "ffuf $url" "$out" ffuf -u "$url" -w "$REPLY_WORDLIST" -mc 200,204,301,302,307,401,403 -c
    pause
}

tool_feroxbuster() {
    require_tool feroxbuster || return
    ask_url || return
    ask_wordlist || return
    local out="$WEB_DIR/feroxbuster_$(DATE).txt"
    run_logged "feroxbuster $REPLY_URL" "$out" feroxbuster -u "$REPLY_URL" -w "$REPLY_WORDLIST" --silent
    pause
}

tool_gobuster() {
    require_tool gobuster || return
    ask_url || return
    ask_wordlist || return
    local out="$WEB_DIR/gobuster_$(DATE).txt"
    run_logged "gobuster dir $REPLY_URL" "$out" gobuster dir -u "$REPLY_URL" -w "$REPLY_WORDLIST" -q
    pause
}

tool_dirb() {
    require_tool dirb || return
    ask_url || return
    local wl=""
    [ -f /usr/share/wordlists/dirb/common.txt ] && wl=/usr/share/wordlists/dirb/common.txt
    local out="$WEB_DIR/dirb_$(DATE).txt"
    if [ -n "$wl" ]; then
        run_logged "dirb $REPLY_URL $wl" "$out" dirb "$REPLY_URL" "$wl"
    else
        run_logged "dirb $REPLY_URL" "$out" dirb "$REPLY_URL"
    fi
    pause
}

tool_nuclei() {
    require_tool nuclei || return
    ask_url || return
    local out="$WEB_DIR/nuclei_$(DATE).txt"
    info "Sévérité (critical,high,medium,low) — entrée pour all"
    read -p "  ❯ Sévérité : " sev
    if [ -n "$sev" ]; then
        run_logged "nuclei -u $REPLY_URL -severity $sev" "$out" nuclei -u "$REPLY_URL" -severity "$sev" -silent
    else
        run_logged "nuclei -u $REPLY_URL" "$out" nuclei -u "$REPLY_URL" -silent
    fi
    pause
}

tool_nikto() {
    require_tool nikto || return
    ask_url || return
    local out="$WEB_DIR/nikto_$(DATE).txt"
    run_logged "nikto -h $REPLY_URL" "$out" nikto -h "$REPLY_URL"
    pause
}

tool_wapiti() {
    require_tool wapiti || return
    ask_url || return
    local out="$WEB_DIR/wapiti_$(DATE)"
    run_logged "wapiti -u $REPLY_URL" "$out.txt" wapiti -u "$REPLY_URL" -f txt -o "$out.txt"
    pause
}

tool_sqlmap() {
    require_tool sqlmap || return
    ask_url || return
    local out="$WEB_DIR/sqlmap_$(DATE).txt"
    info "Mode : 1) Wizard  2) Auto (--batch)  3) Custom"
    read -p "  ❯ Choix [2] : " m; m=${m:-2}
    case $m in
        1) sqlmap -u "$REPLY_URL" --wizard | tee "$out" ;;
        2) sqlmap -u "$REPLY_URL" --batch --level=3 --risk=2 | tee "$out" ;;
        3) read -p "  ❯ Options sqlmap : " opts
           sqlmap -u "$REPLY_URL" $opts | tee "$out" ;;
    esac
    pause
}

tool_wpscan() {
    require_tool wpscan || return
    ask_url || return
    local out="$WEB_DIR/wpscan_$(DATE).txt"
    run_logged "wpscan --url $REPLY_URL" "$out" wpscan --url "$REPLY_URL" --random-user-agent
    pause
}

tool_sslscan() {
    require_tool sslscan || return
    ask_target "Hôte:port (ex: example.com:443)" || return
    local out="$WEB_DIR/sslscan_$(DATE).txt"
    run_logged "sslscan $REPLY_TARGET" "$out" sslscan "$REPLY_TARGET"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       4. ACTIVE DIRECTORY / WINDOWS
# ═══════════════════════════════════════════════════════════════════════════

ad_menu() {
    while true; do
        show_banner
        box "🏢 ACTIVE DIRECTORY / WINDOWS" "$BLUE"
        menu_section "Énumération SMB / AD"
        menu_item 1 "NetExec (nxc)"   "couteau suisse SMB/AD ⭐"
        menu_item 2 "smbclient"        "shell SMB classique"
        menu_item 3 "smbmap"           "permissions partages"
        menu_item 4 "enum4linux"       "énum SMB/RPC"
        menu_section "Kerberos"
        menu_item 5 "kerbrute"         "énum users / brute-force"
        menu_item 6 "GetNPUsers"       "AS-REP roasting (impacket)"
        menu_item 7 "GetUserSPNs"      "Kerberoasting (impacket)"
        menu_section "LDAP"
        menu_item 8  "ldapdomaindump"  "dump complet LDAP"
        menu_item 9  "ldapsearch"      "requêtes LDAP custom"
        menu_section "BloodHound / Mapping"
        menu_item 10 "bloodhound-python" "ingest pour BloodHound"
        menu_section "Empoisonnement / Shell"
        menu_item 11 "Responder"       "LLMNR/NBT-NS/MDNS poisoning"
        menu_item 12 "evil-winrm"      "shell WinRM"
        menu_section "Post-compromission"
        menu_item 13 "secretsdump"     "extraction hashes/secrets"
        menu_item 14 "psexec / wmiexec" "exécution distante"
        menu_section "Résultats"
        menu_item 15 "Voir les scans"  "explorer les résultats"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1)  tool_netexec ;;
            2)  tool_smbclient ;;
            3)  tool_smbmap ;;
            4)  tool_enum4linux ;;
            5)  tool_kerbrute ;;
            6)  tool_getnpusers ;;
            7)  tool_getuserspns ;;
            8)  tool_ldapdomaindump ;;
            9)  tool_ldapsearch ;;
            10) tool_bloodhound_python ;;
            11) tool_responder ;;
            12) tool_evilwinrm ;;
            13) tool_secretsdump ;;
            14) tool_psexec_wmiexec ;;
            15) view_scan_results "$AD_DIR" "AD" ;;
            r)  return ;;
            *)  err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_netexec() {
    local bin
    if have nxc; then bin=nxc
    elif have netexec; then bin=netexec
    elif have crackmapexec; then bin=crackmapexec
    else err "NetExec / nxc / crackmapexec manquant"; pause; return; fi

    info "Protocole : 1) smb  2) ldap  3) winrm  4) mssql  5) ssh  6) ftp"
    read -p "  ❯ Choix [1] : " p; p=${p:-1}
    local proto
    case $p in
        1) proto=smb ;; 2) proto=ldap ;; 3) proto=winrm ;;
        4) proto=mssql ;; 5) proto=ssh ;; 6) proto=ftp ;;
        *) err "Invalide"; pause; return ;;
    esac
    ask_target || return
    read -p "  ❯ User (entrée si null) : " u
    read -p "  ❯ Pass ou hash (entrée si null) : " pw
    local out="$AD_DIR/nxc_${proto}_$(DATE).txt"
    if [ -n "$u" ]; then
        run_logged "$bin $proto $REPLY_TARGET -u $u" "$out" $bin "$proto" "$REPLY_TARGET" -u "$u" -p "$pw"
    else
        run_logged "$bin $proto $REPLY_TARGET" "$out" $bin "$proto" "$REPLY_TARGET"
    fi
    pause
}

tool_smbclient() {
    require_tool smbclient || return
    ask_target || return
    read -p "  ❯ User (entrée pour anonyme) : " u
    if [ -n "$u" ]; then
        smbclient -L "//$REPLY_TARGET" -U "$u"
    else
        smbclient -L "//$REPLY_TARGET" -N
    fi
    pause
}

tool_smbmap() {
    require_tool smbmap || return
    ask_target || return
    local out="$AD_DIR/smbmap_$(DATE).txt"
    run_logged "smbmap -H $REPLY_TARGET" "$out" smbmap -H "$REPLY_TARGET"
    pause
}

tool_enum4linux() {
    require_tool enum4linux || return
    ask_target || return
    local out="$AD_DIR/enum4linux_$(DATE).txt"
    run_logged "enum4linux -a $REPLY_TARGET" "$out" enum4linux -a "$REPLY_TARGET"
    pause
}

tool_kerbrute() {
    require_tool kerbrute || return
    ask_domain || return
    ask_target "DC IP" || return
    read -p "  ❯ Fichier liste d'users : " userlist
    [ ! -f "$userlist" ] && { err "Liste introuvable"; pause; return; }
    local out="$AD_DIR/kerbrute_$(DATE).txt"
    run_logged "kerbrute userenum $REPLY_DOMAIN" "$out" \
        kerbrute userenum -d "$REPLY_DOMAIN" --dc "$REPLY_TARGET" "$userlist"
    pause
}

tool_getnpusers() {
    if ! have impacket-GetNPUsers && ! have GetNPUsers.py; then
        err "impacket manquant"; pause; return
    fi
    local bin
    have impacket-GetNPUsers && bin=impacket-GetNPUsers || bin=GetNPUsers.py
    ask_domain || return
    read -p "  ❯ Fichier liste d'users : " userlist
    [ ! -f "$userlist" ] && { err "Liste introuvable"; pause; return; }
    ask_target "DC IP" || return
    local out="$AD_DIR/asreproast_$(DATE).txt"
    run_logged "AS-REP roasting" "$out" $bin "${REPLY_DOMAIN}/" -no-pass -usersfile "$userlist" -dc-ip "$REPLY_TARGET"
    pause
}

tool_getuserspns() {
    if ! have impacket-GetUserSPNs && ! have GetUserSPNs.py; then
        err "impacket manquant"; pause; return
    fi
    local bin
    have impacket-GetUserSPNs && bin=impacket-GetUserSPNs || bin=GetUserSPNs.py
    ask_domain || return
    read -p "  ❯ User : " u
    read -s -p "  ❯ Password : " pw; echo
    ask_target "DC IP" || return
    local out="$AD_DIR/kerberoast_$(DATE).txt"
    run_logged "Kerberoasting" "$out" $bin "${REPLY_DOMAIN}/${u}:${pw}" -dc-ip "$REPLY_TARGET" -request
    pause
}

tool_ldapdomaindump() {
    require_tool ldapdomaindump || return
    ask_target "DC IP" || return
    read -p "  ❯ User (DOMAIN\\user) : " u
    read -s -p "  ❯ Password : " pw; echo
    local out_dir="$AD_DIR/ldapdump_$(DATE)"
    mkdir -p "$out_dir"
    ldapdomaindump -u "$u" -p "$pw" -o "$out_dir" "$REPLY_TARGET"
    ok "Dump LDAP : $out_dir"
    pause
}

tool_ldapsearch() {
    require_tool ldapsearch || return
    ask_target "LDAP host" || return
    read -p "  ❯ Base DN (ex: dc=example,dc=com) : " base
    local out="$AD_DIR/ldapsearch_$(DATE).txt"
    run_logged "ldapsearch -x -b $base" "$out" ldapsearch -x -H "ldap://$REPLY_TARGET" -b "$base"
    pause
}

tool_bloodhound_python() {
    require_tool bloodhound-python || return
    ask_domain || return
    read -p "  ❯ User : " u
    read -s -p "  ❯ Password : " pw; echo
    ask_target "DC IP" || return
    local out_dir="$AD_DIR/bloodhound_$(DATE)"
    mkdir -p "$out_dir"
    (cd "$out_dir" && bloodhound-python -u "$u" -p "$pw" -d "$REPLY_DOMAIN" -ns "$REPLY_TARGET" -c All)
    ok "Données BloodHound : $out_dir"
    pause
}

tool_responder() {
    require_tool responder || return
    read -p "  ❯ Interface (ex: eth0) : " iface
    [ -z "$iface" ] && { err "Interface requise"; pause; return; }
    info "Ctrl+C pour arrêter Responder."
    sudo responder -I "$iface" -wd
    pause
}

tool_evilwinrm() {
    require_tool evil-winrm || return
    ask_target "IP cible" || return
    read -p "  ❯ User : " u
    read -s -p "  ❯ Password (ou hash NT) : " pw; echo
    if [[ "$pw" =~ ^[a-fA-F0-9]{32}$ ]]; then
        evil-winrm -i "$REPLY_TARGET" -u "$u" -H "$pw"
    else
        evil-winrm -i "$REPLY_TARGET" -u "$u" -p "$pw"
    fi
    pause
}

tool_secretsdump() {
    local bin
    if have impacket-secretsdump; then bin=impacket-secretsdump
    elif have secretsdump.py; then bin=secretsdump.py
    else err "impacket manquant"; pause; return; fi
    ask_target "IP cible" || return
    read -p "  ❯ User : " u
    read -s -p "  ❯ Password (ou hash) : " pw; echo
    read -p "  ❯ Domaine (entrée si workgroup) : " d
    local target="$REPLY_TARGET"
    local out="$LOOT_DIR/secretsdump_$(DATE).txt"
    if [[ "$pw" =~ ^[a-fA-F0-9]{32}:[a-fA-F0-9]{32}$ ]]; then
        run_logged "secretsdump (pass-the-hash)" "$out" $bin "${d}/${u}@${target}" -hashes "$pw"
    else
        run_logged "secretsdump" "$out" $bin "${d:+$d/}${u}:${pw}@${target}"
    fi
    pause
}

tool_psexec_wmiexec() {
    info "1) psexec  2) wmiexec  3) smbexec  4) atexec"
    read -p "  ❯ Choix [2] : " m; m=${m:-2}
    local bin
    case $m in
        1) for b in impacket-psexec psexec.py; do have "$b" && bin=$b && break; done ;;
        2) for b in impacket-wmiexec wmiexec.py; do have "$b" && bin=$b && break; done ;;
        3) for b in impacket-smbexec smbexec.py; do have "$b" && bin=$b && break; done ;;
        4) for b in impacket-atexec atexec.py; do have "$b" && bin=$b && break; done ;;
    esac
    [ -z "${bin:-}" ] && { err "impacket manquant"; pause; return; }
    ask_target || return
    read -p "  ❯ User : " u
    read -s -p "  ❯ Password : " pw; echo
    $bin "${u}:${pw}@${REPLY_TARGET}"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       5. CREDENTIALS / BRUTE-FORCE
# ═══════════════════════════════════════════════════════════════════════════

cred_menu() {
    while true; do
        show_banner
        box "🔑 CREDENTIALS / BRUTE-FORCE" "$BLUE"
        menu_section "Brute-force services"
        menu_item 1 "hydra"          "ssh, ftp, http, rdp..."
        menu_item 2 "medusa"         "alternative"
        menu_section "Hash cracking"
        menu_item 3 "john"           "John the Ripper"
        menu_item 4 "hashcat"        "GPU cracking"
        menu_item 5 "hashid"         "identification de hash"
        menu_section "Wordlists"
        menu_item 6 "rockyou"        "ouvrir rockyou.txt"
        menu_item 7 "crunch"         "générer une wordlist"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) tool_hydra ;;
            2) tool_medusa ;;
            3) tool_john ;;
            4) tool_hashcat ;;
            5) tool_hashid ;;
            6) tool_rockyou ;;
            7) tool_crunch ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_hydra() {
    require_tool hydra || return
    info "Service (ex: ssh, ftp, http-post-form, smb, rdp)..."
    read -p "  ❯ Service : " svc
    ask_target || return
    read -p "  ❯ Fichier users (ou user unique avec -l) : " ul
    read -p "  ❯ Fichier passwords : " pl
    [ ! -f "$ul" ] && [ ! -f "$pl" ] && { err "Au moins une liste valide requise"; pause; return; }
    local out="$LOOT_DIR/hydra_${svc}_$(DATE).txt"
    if [ -f "$ul" ] && [ -f "$pl" ]; then
        run_logged "hydra $svc" "$out" hydra -L "$ul" -P "$pl" "$REPLY_TARGET" "$svc"
    elif [ -f "$pl" ]; then
        read -p "  ❯ User : " u
        run_logged "hydra $svc" "$out" hydra -l "$u" -P "$pl" "$REPLY_TARGET" "$svc"
    fi
    pause
}

tool_medusa() {
    require_tool medusa || return
    read -p "  ❯ Module (ex: ssh, ftp, smbnt) : " mod
    ask_target || return
    read -p "  ❯ Fichier users : " ul
    read -p "  ❯ Fichier passwords : " pl
    local out="$LOOT_DIR/medusa_$(DATE).txt"
    run_logged "medusa $mod" "$out" medusa -h "$REPLY_TARGET" -U "$ul" -P "$pl" -M "$mod"
    pause
}

tool_john() {
    require_tool john || return
    read -p "  ❯ Fichier de hashes : " hf
    [ ! -f "$hf" ] && { err "Fichier introuvable"; pause; return; }
    read -p "  ❯ Format (entrée pour auto-détecter) : " fmt
    if [ -n "$fmt" ]; then
        john --format="$fmt" "$hf"
    else
        john "$hf"
    fi
    info "Pour voir : john --show $hf"
    pause
}

tool_hashcat() {
    require_tool hashcat || return
    read -p "  ❯ Fichier de hashes : " hf
    [ ! -f "$hf" ] && { err "Fichier introuvable"; pause; return; }
    read -p "  ❯ Mode hashcat (ex: 1000=NTLM, 22000=WPA, 0=MD5) : " mode
    read -p "  ❯ Wordlist : " wl
    [ ! -f "$wl" ] && { err "Wordlist introuvable"; pause; return; }
    local out="$LOOT_DIR/hashcat_$(DATE).txt"
    hashcat -m "$mode" "$hf" "$wl" -o "$out"
    ok "Résultats : $out"
    pause
}

tool_hashid() {
    require_tool hashid || return
    read -p "  ❯ Hash à identifier : " h
    hashid -m "$h"
    pause
}

tool_rockyou() {
    if [ -f /usr/share/wordlists/rockyou.txt ]; then
        ok "Disponible : /usr/share/wordlists/rockyou.txt"
        ls -lh /usr/share/wordlists/rockyou.txt
    elif [ -f /usr/share/wordlists/rockyou.txt.gz ]; then
        warn "rockyou.txt.gz présent — décompresser ? (o/n)"
        read -p "  ❯ " yn
        [[ "$yn" =~ ^[oOyY]$ ]] && sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz && ok "Décompressé"
    else
        err "rockyou non trouvé"
    fi
    pause
}

tool_crunch() {
    require_tool crunch || return
    read -p "  ❯ Min length : " mn
    read -p "  ❯ Max length : " mx
    read -p "  ❯ Charset (ex: abc123) : " cs
    local out="$WORDLISTS_DIR/crunch_${mn}_${mx}_$(DATE).txt"
    crunch "$mn" "$mx" "$cs" -o "$out"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       6. EXPLOITATION
# ═══════════════════════════════════════════════════════════════════════════

exploit_menu() {
    while true; do
        show_banner
        box "💣 EXPLOITATION" "$BLUE"
        menu_item 1 "Metasploit"     "msfconsole"
        menu_item 2 "searchsploit"   "ExploitDB local"
        menu_item 3 "vulners-lookup" "recherche CVE en ligne"
        menu_item 4 "cve-bin-tool"   "scanner CVE sur binaires"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) tool_metasploit ;;
            2) tool_searchsploit ;;
            3) tool_vulners ;;
            4) tool_cvebin ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_metasploit() {
    require_tool msfconsole || return
    info "Lancement de msfconsole — Ctrl+D pour quitter"
    sudo msfconsole
}

tool_searchsploit() {
    require_tool searchsploit || return
    read -p "  ❯ Termes de recherche : " q
    [ -z "$q" ] && { err "Vide"; pause; return; }
    searchsploit $q
    pause
}

tool_vulners() {
    require_tool vulners-lookup || return
    read -p "  ❯ Produit ou CVE : " q
    vulners-lookup "$q"
    pause
}

tool_cvebin() {
    require_tool cve-bin-tool || return
    read -p "  ❯ Chemin du binaire ou répertoire : " path
    [ ! -e "$path" ] && { err "Introuvable"; pause; return; }
    local out="$LOOT_DIR/cvebin_$(DATE).html"
    cve-bin-tool -f html -o "$out" "$path"
    ok "Rapport : $out"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       7. POST-EXPLOITATION / PIVOTING
# ═══════════════════════════════════════════════════════════════════════════

postexpl_menu() {
    while true; do
        show_banner
        box "🚇 POST-EXPLOITATION / PIVOTING" "$BLUE"
        menu_item 1 "chisel"        "tunneling HTTP/SOCKS"
        menu_item 2 "ligolo-ng"     "tunneling avancé"
        menu_item 3 "proxychains"   "router des commandes via proxy"
        menu_item 4 "socat"         "redirection de ports"
        menu_item 5 "Serveur HTTP"  "python3 -m http.server"
        menu_item 6 "Serveur SMB"   "impacket-smbserver"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) tool_chisel ;;
            2) tool_ligolo ;;
            3) tool_proxychains ;;
            4) tool_socat ;;
            5) tool_http_server ;;
            6) tool_smb_server ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_chisel() {
    require_tool chisel || return
    info "1) Server (côté attaquant)  2) Client (côté victime)"
    read -p "  ❯ Choix : " m
    case $m in
        1) read -p "  ❯ Port d'écoute : " p
           chisel server -p "$p" --reverse ;;
        2) read -p "  ❯ Hôte attaquant: " h
           read -p "  ❯ Port : " p
           read -p "  ❯ Mapping (ex: R:127.0.0.1:1080:socks) : " map
           chisel client "$h:$p" "$map" ;;
    esac
    pause
}

tool_ligolo() {
    require_tool ligolo-proxy || return
    info "Démarrage du proxy ligolo (Ctrl+C pour stopper)"
    ligolo-proxy -selfcert
    pause
}

tool_proxychains() {
    if have proxychains4; then
        info "Édite /etc/proxychains4.conf si besoin"
        read -p "  ❯ Commande à lancer : " cmd
        proxychains4 $cmd
    elif have proxychains; then
        read -p "  ❯ Commande à lancer : " cmd
        proxychains $cmd
    else
        err "proxychains manquant"
    fi
    pause
}

tool_socat() {
    require_tool socat || return
    info "Exemple : redirection TCP 8080 vers 192.168.1.10:80"
    read -p "  ❯ Listen (ex: TCP-LISTEN:8080,fork) : " l
    read -p "  ❯ Forward (ex: TCP:192.168.1.10:80) : " f
    socat "$l" "$f"
    pause
}

tool_http_server() {
    read -p "  ❯ Port [8000] : " p; p=${p:-8000}
    info "Serveur HTTP sur le port $p — Ctrl+C pour stopper"
    cd "$LOOT_DIR" && python3 -m http.server "$p"
    pause
}

tool_smb_server() {
    if ! have impacket-smbserver && ! have smbserver.py; then
        err "impacket manquant"; pause; return
    fi
    local bin
    have impacket-smbserver && bin=impacket-smbserver || bin=smbserver.py
    read -p "  ❯ Nom du partage [share] : " name; name=${name:-share}
    info "Partage SMB '$name' sur $LOOT_DIR — Ctrl+C pour stopper"
    $bin "$name" "$LOOT_DIR" -smb2support
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       8. CAPTURE & ANALYSE TRAFIC
# ═══════════════════════════════════════════════════════════════════════════

traffic_menu() {
    while true; do
        show_banner
        box "📡 CAPTURE & ANALYSE TRAFIC" "$BLUE"
        menu_item 1 "Wireshark (GUI)"  "interface graphique"
        menu_item 2 "tshark"           "Wireshark en CLI"
        menu_item 3 "tcpdump"          "capture rapide"
        menu_item 4 "Responder"        "LLMNR/NBT-NS poisoning"
        menu_item 5 "ettercap"         "MITM"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) tool_wireshark ;;
            2) tool_tshark ;;
            3) tool_tcpdump ;;
            4) tool_responder ;;
            5) tool_ettercap ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_wireshark() {
    require_tool wireshark || return
    info "Lancement de Wireshark (GUI)..."
    if [ -n "${SUDO_USER:-}" ] || [ "$EUID" -ne 0 ]; then
        # Préférer sans sudo si l'utilisateur est dans le groupe wireshark
        if groups 2>/dev/null | grep -q wireshark; then
            wireshark &> /dev/null &
        else
            warn "Tu n'es pas dans le groupe wireshark — lancement en sudo"
            sudo wireshark &> /dev/null &
        fi
    else
        wireshark &> /dev/null &
    fi
    sleep 2
    ok "Wireshark lancé en arrière-plan"
    pause
}

tool_tshark() {
    require_tool tshark || return
    read -p "  ❯ Interface (ex: eth0) : " iface
    read -p "  ❯ Filtre BPF (ex: 'port 80', entrée pour aucun) : " filt
    local out="$LOGS_DIR/capture_$(DATE).pcap"
    info "Capture en cours — Ctrl+C pour stopper"
    if [ -n "$filt" ]; then
        sudo tshark -i "$iface" -w "$out" -f "$filt"
    else
        sudo tshark -i "$iface" -w "$out"
    fi
    ok "Capture : $out"
    pause
}

tool_tcpdump() {
    require_tool tcpdump || return
    read -p "  ❯ Interface (ex: eth0) : " iface
    read -p "  ❯ Filtre (entrée pour aucun) : " filt
    local out="$LOGS_DIR/tcpdump_$(DATE).pcap"
    info "Capture en cours — Ctrl+C pour stopper"
    sudo tcpdump -i "$iface" -w "$out" $filt
    ok "Capture : $out"
    pause
}

tool_ettercap() {
    require_tool ettercap || return
    info "ettercap en mode texte — Ctrl+C pour stopper"
    sudo ettercap -T
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       9. CLOUD
# ═══════════════════════════════════════════════════════════════════════════

cloud_menu() {
    while true; do
        show_banner
        box "☁️  CLOUD" "$BLUE"
        menu_item 1 "prowler"      "audit AWS/Azure/GCP"
        menu_item 2 "scoutsuite"   "audit multi-cloud"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) tool_prowler ;;
            2) tool_scoutsuite ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tool_prowler() {
    require_tool prowler || return
    info "Configure tes credentials AWS/Azure/GCP avant"
    read -p "  ❯ Provider (aws/azure/gcp) [aws] : " p; p=${p:-aws}
    prowler "$p"
    pause
}

tool_scoutsuite() {
    if have scout; then
        local bin=scout
    elif have scoutsuite; then
        local bin=scoutsuite
    else
        err "scoutsuite manquant"; pause; return
    fi
    read -p "  ❯ Provider (aws/azure/gcp) [aws] : " p; p=${p:-aws}
    $bin "$p"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       10. EXPLORATEUR DE RÉSULTATS
# ═══════════════════════════════════════════════════════════════════════════

view_scan_results() {
    local dir=$1
    local label=$2
    while true; do
        show_banner
        box "📁 RÉSULTATS — $label" "$MAGENTA"

        # Liste triée du plus récent au plus ancien
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$dir" -maxdepth 2 -type f -not -name '.gitkeep' -printf '%T@ %p\0' 2>/dev/null \
                 | sort -z -rn | sed -z 's/^[0-9.]* //')

        if [ ${#files[@]} -eq 0 ]; then
            warn "Aucun scan dans $dir"
            pause
            return
        fi

        printf "  ${BOLD}${WHITE}%-4s %-44s %10s %16s${NC}\n" "N°" "Fichier" "Taille" "Date"
        hr "─"
        local i name size date_h short
        for i in "${!files[@]}"; do
            name=$(basename "${files[$i]}")
            size=$(stat -c%s "${files[$i]}" 2>/dev/null || wc -c < "${files[$i]}")
            date_h=$(date -r "${files[$i]}" "+%Y-%m-%d %H:%M" 2>/dev/null)
            short="$name"
            (( ${#short} > 44 )) && short="${short:0:41}..."
            printf "  ${GREEN}%-4s${NC} %-44s ${CYAN}%10s${NC} ${DIM}%16s${NC}\n" \
                   "$((i+1))" "$short" "$(_human_size "$size")" "$date_h"
        done
        hr "─"
        echo ""
        echo -e "  ${BOLD}Actions :${NC} ${GREEN}[N°]${NC} ouvrir   ${YELLOW}[S]${NC} supprimer   ${RED}[R]${NC} retour"
        echo ""
        read -p "  ❯ Choix : " c

        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#files[@]} )); then
            display_scan_file "${files[$((c-1))]}"
        elif [[ "$c" =~ ^[Ss]$ ]]; then
            delete_scan_files "$dir" "$label"
        elif [[ "$c" =~ ^[Rr]$ ]]; then
            return
        else
            err "Invalide"; sleep 1
        fi
    done
}

display_scan_file() {
    local file=$1
    local name=$(basename "$file")
    local size fmtime
    size=$(stat -c%s "$file" 2>/dev/null || wc -c < "$file")
    fmtime=$(date -r "$file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

    clear
    box "📄 $name" "$CYAN"
    echo -e "  ${DIM}Taille  :${NC} $(_human_size "$size")"
    echo -e "  ${DIM}Modifié :${NC} $fmtime"
    echo -e "  ${DIM}Chemin  :${NC} $file"
    hr "─"
    echo ""

    if have less; then
        colorize_output < "$file" | less -R
    else
        colorize_output < "$file"
    fi
    hr "─"
    pause
}

delete_scan_files() {
    local dir=$1
    local label=$2
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 2 -type f -not -name '.gitkeep' -print0)

    [ ${#files[@]} -eq 0 ] && { warn "Rien à supprimer"; sleep 1; return; }

    echo ""
    for i in "${!files[@]}"; do
        printf "  %d - %s\n" "$((i+1))" "$(basename "${files[$i]}")"
    done
    echo ""
    read -p "  ❯ N° à supprimer (* pour tout, R pour annuler) : " c
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#files[@]} )); then
        rm -- "${files[$((c-1))]}"
        ok "Supprimé : ${files[$((c-1))]}"
    elif [[ "$c" == "*" ]]; then
        find "$dir" -maxdepth 2 -type f -not -name '.gitkeep' -delete
        ok "Tous les fichiers supprimés"
    fi
    sleep 1
}

# ═══════════════════════════════════════════════════════════════════════════
#                       11. REPORTING
# ═══════════════════════════════════════════════════════════════════════════

reporting_menu() {
    while true; do
        show_banner
        box "📊 REPORTING & EXPORT" "$BLUE"
        menu_item 1 "Rapport HTML"      "génération web"
        menu_item 2 "Rapport XML"       "format structuré"
        menu_item 3 "Export CSV"        "tableur"
        menu_item 4 "Export JSON"       "machine-readable"
        menu_item 5 "Export PDF"        "diffusion"
        menu_item 6 "Lister rapports"   "explorer les rapports"
        menu_item 7 "Stats globales"    "vulnérabilités agrégées"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) generate_html_report ;;
            2) generate_xml_report ;;
            3) export_csv ;;
            4) export_json ;;
            5) export_pdf ;;
            6) view_scan_results "$REPORTS_DIR" "Rapports" ;;
            7) show_global_stats ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

count_vulnerabilities() {
    local severity=$1
    [ -f "$SCAN_RESULTS" ] && grep -c "SEVERITY:$severity" "$SCAN_RESULTS" || echo 0
}

generate_summary() {
    local crit hi med lo
    crit=$(count_vulnerabilities critical)
    hi=$(count_vulnerabilities high)
    med=$(count_vulnerabilities medium)
    lo=$(count_vulnerabilities low)
    cat << EOF
    <div class="summary">
        <h3>Vulnérabilités découvertes</h3>
        <ul>
            <li class="vuln-critical">Critiques: $crit</li>
            <li class="vuln-high">Élevées: $hi</li>
            <li class="vuln-medium">Moyennes: $med</li>
            <li class="vuln-low">Faibles: $lo</li>
        </ul>
        <p>Total: $((crit + hi + med + lo))</p>
    </div>
EOF
}

generate_html_report() {
    read -p "  ❯ Nom du rapport (sans extension) : " name
    [ -z "$name" ] && { err "Vide"; pause; return; }
    local out="$REPORTS_DIR/${name}_$(DATE).html"
    cat > "$out" << EOF
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Rapport — $name</title>
<style>
    :root { color-scheme: dark; }
    body { font-family: 'Segoe UI', system-ui, sans-serif; background: #0f1419; color: #e6e6e6; margin: 0; padding: 40px; }
    .container { max-width: 1100px; margin: auto; }
    h1 { color: #00d9ff; border-bottom: 2px solid #00d9ff; padding-bottom: 10px; }
    h2 { color: #ffaa00; margin-top: 30px; }
    .meta { background: #1a1f29; padding: 15px; border-radius: 8px; }
    .summary ul { list-style: none; padding: 0; }
    .summary li { padding: 8px 12px; margin: 4px 0; border-radius: 4px; background: #1a1f29; }
    .vuln-critical { border-left: 4px solid #ff3860; }
    .vuln-high     { border-left: 4px solid #ff8800; }
    .vuln-medium   { border-left: 4px solid #ffdd33; }
    .vuln-low      { border-left: 4px solid #48c774; }
    code { background: #1a1f29; padding: 2px 6px; border-radius: 4px; }
</style>
</head>
<body>
<div class="container">
    <h1>🛡️ Rapport de pentest — $name</h1>
    <div class="meta">
        <p><strong>Date :</strong> $(date)</p>
        <p><strong>Cible :</strong> <code>${target_host:-Non spécifié}</code></p>
        <p><strong>Domaine :</strong> <code>${target_domain:-N/A}</code></p>
    </div>
    <h2>Résumé</h2>
    $(generate_summary)
    <h2>Notes</h2>
    <p>Rapport généré automatiquement par Pentest Toolkit.</p>
</div>
</body>
</html>
EOF
    ok "Rapport HTML : $out"
    pause
}

generate_xml_report() {
    read -p "  ❯ Nom : " name
    [ -z "$name" ] && { err "Vide"; pause; return; }
    local out="$REPORTS_DIR/${name}_$(DATE).xml"
    cat > "$out" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<pentest_report>
    <metadata>
        <name>$name</name>
        <date>$(date)</date>
        <target>${target_host:-N/A}</target>
        <domain>${target_domain:-N/A}</domain>
    </metadata>
    <summary>
        <critical>$(count_vulnerabilities critical)</critical>
        <high>$(count_vulnerabilities high)</high>
        <medium>$(count_vulnerabilities medium)</medium>
        <low>$(count_vulnerabilities low)</low>
    </summary>
</pentest_report>
EOF
    ok "Rapport XML : $out"
    pause
}

export_csv() {
    local out="$REPORTS_DIR/export_$(DATE).csv"
    echo "Severity,Name,Description,Solution" > "$out"
    if [ -f "$SCAN_RESULTS" ]; then
        while IFS='|' read -r s n d sol; do
            echo "\"$s\",\"$n\",\"$d\",\"$sol\"" >> "$out"
        done < "$SCAN_RESULTS"
    fi
    ok "CSV : $out"
    pause
}

export_json() {
    local out="$REPORTS_DIR/export_$(DATE).json"
    {
        echo "{"
        echo "  \"target\": \"${target_host:-}\","
        echo "  \"domain\": \"${target_domain:-}\","
        echo "  \"date\": \"$(date)\","
        echo "  \"summary\": {"
        echo "    \"critical\": $(count_vulnerabilities critical),"
        echo "    \"high\":     $(count_vulnerabilities high),"
        echo "    \"medium\":   $(count_vulnerabilities medium),"
        echo "    \"low\":      $(count_vulnerabilities low)"
        echo "  }"
        echo "}"
    } > "$out"
    ok "JSON : $out"
    pause
}

export_pdf() {
    require_tool wkhtmltopdf || return
    read -p "  ❯ Nom du PDF : " name
    [ -z "$name" ] && { err "Vide"; pause; return; }
    local tmp="$REPORTS_DIR/.tmp_$(DATE).html"
    local out="$REPORTS_DIR/${name}_$(DATE).pdf"
    cat > "$tmp" << EOF
<!DOCTYPE html><html><body>
<h1>Rapport — $name</h1>
<p>Date: $(date)</p>
<p>Cible: ${target_host:-N/A}</p>
$(generate_summary)
</body></html>
EOF
    wkhtmltopdf "$tmp" "$out" 2>/dev/null
    rm -f "$tmp"
    ok "PDF : $out"
    pause
}

show_global_stats() {
    box "📈 STATISTIQUES GLOBALES" "$MAGENTA"
    local crit hi med lo
    crit=$(count_vulnerabilities critical)
    hi=$(count_vulnerabilities high)
    med=$(count_vulnerabilities medium)
    lo=$(count_vulnerabilities low)
    printf "  ${RED}${BOLD}Critiques :${NC} %d\n" "$crit"
    printf "  ${YELLOW}${BOLD}Élevées   :${NC} %d\n" "$hi"
    printf "  ${BLUE}${BOLD}Moyennes  :${NC} %d\n" "$med"
    printf "  ${GREEN}${BOLD}Faibles   :${NC} %d\n" "$lo"
    echo ""
    printf "  ${BOLD}Total :${NC} %d\n" "$((crit + hi + med + lo))"
    echo ""
    info "Fichiers de scan :"
    printf "    Nmap   : %d\n" "$(find "$NMAP_DIR" -maxdepth 2 -type f -not -name '.gitkeep' 2>/dev/null | wc -l)"
    printf "    Recon  : %d\n" "$(find "$RECON_DIR" -maxdepth 2 -type f -not -name '.gitkeep' 2>/dev/null | wc -l)"
    printf "    Web    : %d\n" "$(find "$WEB_DIR" -maxdepth 2 -type f -not -name '.gitkeep' 2>/dev/null | wc -l)"
    printf "    AD     : %d\n" "$(find "$AD_DIR" -maxdepth 2 -type f -not -name '.gitkeep' 2>/dev/null | wc -l)"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       12. OPTIONS AVANCÉES NMAP
# ═══════════════════════════════════════════════════════════════════════════

advanced_menu() {
    while true; do
        show_banner
        box "⚙️  OPTIONS AVANCÉES NMAP" "$BLUE"
        echo -e "  ${DIM}État actuel :${NC}"
        echo -e "    FRAG  : ${CYAN}${FRAG_OPTIONS:-(aucun)}${NC}"
        echo -e "    SPOOF : ${CYAN}${SPOOF_OPTIONS:-(aucun)}${NC}"
        echo -e "    BW    : ${CYAN}${BW_OPTIONS:-(aucun)}${NC}"
        echo -e "    SCAN  : ${CYAN}${SCAN_OPTIONS:-(aucun)}${NC}"
        echo ""
        menu_item 1 "Fragmentation"   "-f, --mtu, --data-length"
        menu_item 2 "Spoofing/leurres" "-D, -S, --spoof-mac"
        menu_item 3 "Bande passante"   "--min-rate, -T"
        menu_item 4 "Scan options"     "-sV, --script, -6, -oA"
        menu_item 5 "Reset"            "vider toutes les options"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) config_frag ;;
            2) config_spoof ;;
            3) config_bw ;;
            4) config_scan ;;
            5) FRAG_OPTIONS=""; SPOOF_OPTIONS=""; BW_OPTIONS=""; SCAN_OPTIONS=""
               ok "Reset"; sleep 1 ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

config_frag() {
    echo "  1) -f   2) -ff   3) --data-length N   4) --mtu N"
    read -p "  ❯ Choix : " c
    case $c in
        1) FRAG_OPTIONS="-f" ;;
        2) FRAG_OPTIONS="-ff" ;;
        3) read -p "  ❯ Taille : " n; FRAG_OPTIONS="--data-length $n" ;;
        4) read -p "  ❯ MTU : " n; FRAG_OPTIONS="--mtu $n" ;;
    esac
}
config_spoof() {
    echo "  1) -D RND:5   2) -S <IP>   3) --spoof-mac <MAC>   4) -D <ips>"
    read -p "  ❯ Choix : " c
    case $c in
        1) SPOOF_OPTIONS="-D RND:5" ;;
        2) read -p "  ❯ IP src : " ip; SPOOF_OPTIONS="-S $ip" ;;
        3) read -p "  ❯ MAC : " m; SPOOF_OPTIONS="--spoof-mac $m" ;;
        4) read -p "  ❯ Liste IPs : " l; SPOOF_OPTIONS="-D $l" ;;
    esac
}
config_bw() {
    echo "  1) --min-rate N   2) -T<0-5>   3) --min-parallelism N"
    read -p "  ❯ Choix : " c
    case $c in
        1) read -p "  ❯ rate : " r; BW_OPTIONS="--min-rate $r" ;;
        2) read -p "  ❯ -T (0-5) : " t; BW_OPTIONS="-T$t" ;;
        3) read -p "  ❯ N : " n; BW_OPTIONS="--min-parallelism $n" ;;
    esac
}
config_scan() {
    echo "  1) -sV --version-intensity 9   2) --script <name>   3) -6   4) -oA <base>"
    read -p "  ❯ Choix : " c
    case $c in
        1) SCAN_OPTIONS="-sV --version-intensity 9" ;;
        2) read -p "  ❯ script : " s; SCAN_OPTIONS="--script=$s" ;;
        3) SCAN_OPTIONS="-6" ;;
        4) read -p "  ❯ base : " b; SCAN_OPTIONS="-oA $b" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
#                       13. MONITORING
# ═══════════════════════════════════════════════════════════════════════════

monitoring_menu() {
    while true; do
        show_banner
        box "📟 MONITORING" "$BLUE"
        menu_item 1 "Statut des scans"   "processus actifs"
        menu_item 2 "Ressources système" "CPU / RAM / disque"
        menu_item 3 "Logs en temps réel" "syslog filtré"
        menu_item 4 "Alertes"            "seuils & notifications"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) mon_scan_status ;;
            2) mon_resources ;;
            3) mon_realtime_logs ;;
            4) alerts_menu ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

mon_scan_status() {
    box "Processus de scan actifs" "$MAGENTA"
    ps aux | grep -E "nmap|masscan|rustscan|nuclei|ffuf" | grep -v grep || echo "  Aucun"
    echo ""
    info "Derniers scans :"
    find "$SCAN_DIR" -type f -not -name '.gitkeep' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -5 | awk '{print "    " $2}'
    pause
}

mon_resources() {
    box "Ressources" "$MAGENTA"
    echo -e "${BOLD}CPU & charge${NC}"; uptime
    echo ""; echo -e "${BOLD}RAM${NC}"; free -h
    echo ""; echo -e "${BOLD}Disque${NC}"; df -h | head -5
    pause
}

mon_realtime_logs() {
    box "Logs temps réel (Ctrl+C pour quitter)" "$MAGENTA"
    local log=""
    for c in /var/log/syslog /var/log/messages /var/log/auth.log; do
        [ -r "$c" ] && log=$c && break
    done
    trap ' ' INT
    if [ -n "$log" ]; then
        tail -f "$log" | grep --line-buffered -iE "nmap|masscan|nuclei|hydra"
    else
        journalctl -f 2>/dev/null | grep --line-buffered -iE "nmap|masscan|nuclei|hydra"
    fi
    trap - INT
}

# ─── Alertes ───────────────────────────────────────────────────────────────

load_alert_thresholds() {
    if [ -f "$ALERT_CONFIG" ]; then
        source "$ALERT_CONFIG"
    else
        alert_critical_threshold=5
        alert_major_threshold=10
        alert_ports_threshold=20
        save_alert_thresholds
    fi
}

save_alert_thresholds() {
    cat > "$ALERT_CONFIG" << EOF
alert_critical_threshold=$alert_critical_threshold
alert_major_threshold=$alert_major_threshold
alert_ports_threshold=$alert_ports_threshold
EOF
}

count_open_ports() {
    find "$NMAP_DIR" -type f -name '*.txt' 2>/dev/null \
        | xargs grep -h -E "^[0-9]+/(tcp|udp).*open" 2>/dev/null | wc -l
}

alerts_menu() {
    while true; do
        show_banner
        box "🚨 ALERTES" "$BLUE"
        echo -e "  Seuils actuels :"
        echo -e "    Critiques : ${RED}$alert_critical_threshold${NC}"
        echo -e "    Majeures  : ${YELLOW}$alert_major_threshold${NC}"
        echo -e "    Ports     : ${BLUE}$alert_ports_threshold${NC}"
        echo ""
        menu_item 1 "Voir alertes actives"
        menu_item 2 "Configurer seuils"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) show_active_alerts ;;
            2) configure_thresholds ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

show_active_alerts() {
    local found=0
    local crit hi ports
    crit=$(count_vulnerabilities critical)
    hi=$(count_vulnerabilities high)
    ports=$(count_open_ports)

    box "Alertes" "$RED"
    if (( crit > alert_critical_threshold )); then
        echo -e "  ${RED}[!] $crit vulnérabilités critiques (seuil $alert_critical_threshold)${NC}"
        found=1
    fi
    if (( hi > alert_major_threshold )); then
        echo -e "  ${YELLOW}[!] $hi vulnérabilités majeures (seuil $alert_major_threshold)${NC}"
        found=1
    fi
    if (( ports > alert_ports_threshold )); then
        echo -e "  ${YELLOW}[!] $ports ports ouverts (seuil $alert_ports_threshold)${NC}"
        found=1
    fi
    (( found == 0 )) && echo -e "  ${GREEN}Aucune alerte active${NC}"
    pause
}

configure_thresholds() {
    read -p "  ❯ Seuil critiques [$alert_critical_threshold] : " v
    [[ "$v" =~ ^[0-9]+$ ]] && alert_critical_threshold=$v
    read -p "  ❯ Seuil majeures [$alert_major_threshold] : " v
    [[ "$v" =~ ^[0-9]+$ ]] && alert_major_threshold=$v
    read -p "  ❯ Seuil ports [$alert_ports_threshold] : " v
    [[ "$v" =~ ^[0-9]+$ ]] && alert_ports_threshold=$v
    save_alert_thresholds
    ok "Seuils mis à jour"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                       14. SETTINGS
# ═══════════════════════════════════════════════════════════════════════════

settings_menu() {
    while true; do
        show_banner
        box "🛠️  PARAMÈTRES" "$BLUE"
        echo -e "  Cible courante  : ${GREEN}${target_host:-(aucune)}${NC}"
        echo -e "  Domaine courant : ${GREEN}${target_domain:-(aucun)}${NC}"
        echo ""
        menu_item 1 "Changer cible (IP/hostname)"
        menu_item 2 "Changer domaine"
        menu_item 3 "Effacer contexte"
        menu_item 4 "Vérifier outils installés"
        menu_item 5 "Mettre à jour nuclei templates"
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) ask_target ;;
            2) ask_domain ;;
            3) target_host=""; target_domain=""; ok "Contexte effacé"; sleep 1 ;;
            4) tools_check ;;
            5) have nuclei && nuclei -update-templates || err "nuclei manquant"; pause ;;
            r) return ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

tools_check() {
    box "État des outils" "$MAGENTA"
    local groups=(
        "RECON:subfinder amass assetfinder dnsx httpx whatweb katana theHarvester waybackurls"
        "SCAN:nmap masscan rustscan naabu"
        "WEB:ffuf feroxbuster gobuster dirb nuclei nikto wapiti sqlmap wpscan sslscan"
        "AD:nxc smbclient smbmap enum4linux kerbrute impacket-secretsdump bloodhound-python ldapdomaindump responder evil-winrm"
        "CREDS:hydra medusa john hashcat hashid crunch"
        "EXPLOIT:msfconsole searchsploit vulners-lookup cve-bin-tool"
        "POST:chisel ligolo-proxy proxychains4 socat"
        "TRAFFIC:wireshark tshark tcpdump ettercap"
        "REPORT:wkhtmltopdf pandoc"
    )
    for g in "${groups[@]}"; do
        local name="${g%%:*}"
        local tools="${g##*:}"
        echo -e "\n  ${BOLD}${MAGENTA}── $name${NC}"
        for t in $tools; do
            if have "$t"; then
                printf "    ${GREEN}✓${NC} %s\n" "$t"
            else
                printf "    ${RED}✗${NC} %s\n" "$t"
            fi
        done
    done
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                           MENU PRINCIPAL
# ═══════════════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        show_banner
        box "🛡️  MENU PRINCIPAL — PENTEST TOOLKIT" "$CYAN"
        menu_section "Workflow red team"
        menu_item 1 "Reconnaissance"      "OSINT, sous-domaines, DNS, HTTP"
        menu_item 2 "Scan réseau"         "nmap, masscan, NSE"
        menu_item 3 "Web application"     "fuzzing, vuln, sqlmap"
        menu_item 4 "Active Directory"    "SMB, Kerberos, BloodHound"
        menu_item 5 "Credentials"         "brute-force, hash cracking"
        menu_item 6 "Exploitation"        "Metasploit, exploitdb, CVE"
        menu_item 7 "Post-expl/Pivoting"  "chisel, ligolo, serveurs"
        menu_item 8 "Traffic / Capture"   "wireshark, tcpdump, responder"
        menu_item 9 "Cloud"               "prowler, scoutsuite"
        menu_section "Outils transverses"
        menu_item A "Options avancées"    "nmap timing, frag, spoof"
        menu_item B "Reporting & export"  "HTML/PDF/CSV/JSON"
        menu_item C "Monitoring"          "ressources, logs, alertes"
        menu_item W "Serveur Web"         "interface graphique navigateur"
        menu_item S "Paramètres"          "cible, vérif outils"
        echo ""
        menu_item Q "Quitter"
        echo ""
        read -p "  ❯ Choix : " c
        case ${c,,} in
            1) recon_menu ;;
            2) scan_menu ;;
            3) web_menu ;;
            4) ad_menu ;;
            5) cred_menu ;;
            6) exploit_menu ;;
            7) postexpl_menu ;;
            8) traffic_menu ;;
            9) cloud_menu ;;
            a) advanced_menu ;;
            b) reporting_menu ;;
            c) monitoring_menu ;;
            w) web_server_menu ;;
            s) settings_menu ;;
            q) echo -e "\n  ${CYAN}À la prochaine.${NC}\n"; exit 0 ;;
            *) err "Option invalide"; sleep 1 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
#                       SERVEUR WEB (SPECTER WEB)
# ═══════════════════════════════════════════════════════════════════════════

WEB_PID_FILE="$LOGS_DIR/.web_server.pid"

web_server_menu() {
    while true; do
        show_banner
        box "🌐 SERVEUR WEB — SPECTER" "$BLUE"
        local running=0
        if [ -f "$WEB_PID_FILE" ] && kill -0 "$(cat "$WEB_PID_FILE")" 2>/dev/null; then
            running=1
            echo -e "  État : ${GREEN}● actif${NC} (PID $(cat "$WEB_PID_FILE"))"
        else
            echo -e "  État : ${RED}● arrêté${NC}"
            rm -f "$WEB_PID_FILE"
        fi
        local host="${SPECTER_HOST:-127.0.0.1}"
        local port="${SPECTER_PORT:-8765}"
        echo -e "  URL  : ${CYAN}http://${host}:${port}${NC}"
        echo ""

        if (( running )); then
            menu_item 1 "Ouvrir dans le navigateur"
            menu_item 2 "Afficher le token"
            menu_item 3 "Voir les logs"
            menu_item 4 "Arrêter le serveur"
        else
            menu_item 1 "Démarrer le serveur"
            menu_item 2 "Démarrer en arrière-plan"
            menu_item 3 "Configurer host/port"
        fi
        echo ""
        menu_item R "Retour"
        echo ""
        read -p "  ❯ Choix : " c

        if (( running )); then
            case ${c,,} in
                1) web_open_browser ;;
                2) web_show_token ;;
                3) web_view_logs ;;
                4) web_stop ;;
                r) return ;;
                *) err "Option invalide"; sleep 1 ;;
            esac
        else
            case ${c,,} in
                1) web_start_foreground ;;
                2) web_start_background ;;
                3) web_configure ;;
                r) return ;;
                *) err "Option invalide"; sleep 1 ;;
            esac
        fi
    done
}

web_check_deps() {
    if ! have python3; then
        err "python3 manquant"
        return 1
    fi
    if ! python3 -c "import fastapi, uvicorn" 2>/dev/null; then
        warn "Dépendances Python manquantes (fastapi, uvicorn)"
        read -p "  ❯ Les installer maintenant via pip ? (o/n) : " yn
        if [[ "$yn" =~ ^[oOyY]$ ]]; then
            python3 -m pip install --upgrade fastapi 'uvicorn[standard]' websockets \
                || python3 -m pip install --upgrade --break-system-packages fastapi 'uvicorn[standard]' websockets \
                || { err "Échec installation"; return 1; }
        else
            return 1
        fi
    fi
    if [ ! -f "$SCRIPT_DIR/specter_web.py" ]; then
        err "specter_web.py manquant"
        return 1
    fi
    return 0
}

web_start_foreground() {
    web_check_deps || { pause; return; }
    info "Lancement du serveur (Ctrl+C pour stopper)..."
    cd "$SCRIPT_DIR" && python3 specter_web.py
    pause
}

web_start_background() {
    web_check_deps || { pause; return; }
    info "Lancement en arrière-plan..."
    local log="$LOGS_DIR/web_server.log"
    nohup python3 "$SCRIPT_DIR/specter_web.py" > "$log" 2>&1 &
    echo $! > "$WEB_PID_FILE"
    sleep 1
    if kill -0 "$(cat "$WEB_PID_FILE")" 2>/dev/null; then
        ok "Serveur démarré (PID $(cat "$WEB_PID_FILE"))"
        ok "Logs : $log"
        # Affiche le token
        sleep 1
        if [ -f "$LOGS_DIR/.web_token" ]; then
            echo ""
            echo -e "  ${BOLD}Token :${NC} ${YELLOW}$(cat "$LOGS_DIR/.web_token")${NC}"
        fi
    else
        err "Échec du démarrage. Voir $log"
        rm -f "$WEB_PID_FILE"
    fi
    pause
}

web_stop() {
    if [ -f "$WEB_PID_FILE" ]; then
        local pid=$(cat "$WEB_PID_FILE")
        if kill -TERM "$pid" 2>/dev/null; then
            ok "Serveur arrêté (PID $pid)"
        else
            warn "Processus déjà terminé"
        fi
        rm -f "$WEB_PID_FILE"
    fi
    pause
}

web_open_browser() {
    local host="${SPECTER_HOST:-127.0.0.1}"
    local port="${SPECTER_PORT:-8765}"
    local url="http://${host}:${port}"
    if have xdg-open; then xdg-open "$url" &> /dev/null &
    elif have open; then open "$url" &> /dev/null &
    else info "Ouvre manuellement : $url"
    fi
    pause
}

web_show_token() {
    if [ -f "$LOGS_DIR/.web_token" ]; then
        echo ""
        echo -e "  ${BOLD}Token :${NC} ${YELLOW}$(cat "$LOGS_DIR/.web_token")${NC}"
    else
        err "Token introuvable (lance le serveur d'abord)"
    fi
    pause
}

web_view_logs() {
    local log="$LOGS_DIR/web_server.log"
    if [ -f "$log" ]; then
        if have less; then less "$log"
        else tail -50 "$log"; fi
    else
        warn "Aucun log"
    fi
    pause
}

web_configure() {
    read -p "  ❯ Host (défaut 127.0.0.1) : " h
    read -p "  ❯ Port (défaut 8765) : " p
    [ -n "$h" ] && export SPECTER_HOST="$h"
    [ -n "$p" ] && export SPECTER_PORT="$p"
    ok "Configuration : ${SPECTER_HOST:-127.0.0.1}:${SPECTER_PORT:-8765}"
    warn "Bind 0.0.0.0 exposerait le serveur sur le réseau — token requis mais sois prudent"
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#                              ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

load_alert_thresholds
main_menu
