#!/bin/bash

# Couleurs pour une meilleure lisibilité
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' 

# Répertoire du script (résolu une seule fois, utilisable partout)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Variables globales pour le stockage des résultats
SCAN_DIR="$SCRIPT_DIR/scans"
NSE_SCAN_DIR="$SCAN_DIR"
REPORTS_DIR="$SCRIPT_DIR/reports"
LOGS_DIR="$SCRIPT_DIR/logs"
SCAN_RESULTS="$SCRIPT_DIR/logs/scan_results.dat"

# Création des répertoires nécessaires
mkdir -p "$SCAN_DIR" "$REPORTS_DIR" "$LOGS_DIR"

# Horodatage commun
DATE=$(date +%Y%m%d_%H%M%S)

# Hôte cible courant (mémorisé pour les rapports)
target_host=""

# Fonction pour afficher le titre
show_header() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   ██████╗ ███████╗███╗   ██╗████████╗███████╗███████╗████████╗   ║
    ║   ██╔══██╗██╔════╝████╗  ██║╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝   ║
    ║   ██████╔╝█████╗  ██╔██╗ ██║   ██║   █████╗  ███████╗   ██║      ║
    ║   ██╔═══╝ ██╔══╝  ██║╚██╗██║   ██║   ██╔══╝  ╚════██║   ██║      ║
    ║   ██║     ███████╗██║ ╚████║   ██║   ███████╗███████║   ██║      ║
    ║   ╚═╝     ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚══════╝   ╚═╝      ║
    ║                                                                   ║
    ║                       T O O L K I T                               ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Menu des outils complémentaires
complementary_tools_menu() {
    show_header
    echo -e "${YELLOW}=== OUTILS COMPLÉMENTAIRES ===${NC}"
    echo ""
    echo "1. Wireshark"
    echo "2. Metasploit"
    echo "3. Nikto"
    echo "4. Dirb"
    echo "5. SQLmap"
    echo -e "${RED}R${NC} - Retour au menu principal"
    echo ""
    read -p "Choisissez un outil: " tool_choice

    case $tool_choice in
        1)
            echo "Lancement de Wireshark..."
            sudo wireshark &
            sleep 2
            complementary_tools_menu
            ;;
        2)
            echo "Lancement de Metasploit..."
            sudo msfconsole
            complementary_tools_menu
            ;;
        3)
            echo "Lancement de Nikto..."
            read -p "Entrez l'URL cible: " target
            if [ -n "$target" ]; then
                nikto -h "$target"
            else
                echo -e "${RED}URL vide${NC}"
            fi
            read -p "Appuyez sur Entrée pour continuer"
            complementary_tools_menu
            ;;
        4)
            echo "Lancement de Dirb..."
            if ! command -v dirb &> /dev/null; then
                echo -e "${RED}Dirb n'est pas installé. Lancez install.sh.${NC}"
                sleep 2
                complementary_tools_menu
                return
            fi
            read -p "Entrez l'URL cible: " target
            if [ -n "$target" ]; then
                dirb "$target"
            else
                echo -e "${RED}URL vide${NC}"
            fi
            read -p "Appuyez sur Entrée pour continuer"
            complementary_tools_menu
            ;;
        5)
            echo "Lancement de SQLmap..."
            read -p "Entrez l'URL cible: " target
            if [ -n "$target" ]; then
                sqlmap -u "$target" --wizard
            else
                echo -e "${RED}URL vide${NC}"
            fi
            read -p "Appuyez sur Entrée pour continuer"
            complementary_tools_menu
            ;;
        [Rr]) main_menu ;;
        *) echo "Option invalide" ; sleep 2 ; complementary_tools_menu ;;
    esac
}

# Menu de reporting
reporting_menu() {
    show_header
    echo -e "${YELLOW}=== ANALYSE ET REPORTING ===${NC}"
    echo ""
    echo "1. Générer un rapport HTML"
    echo "2. Générer un rapport XML"
    echo "3. Voir les rapports existants"
    echo "4. Analyser les résultats"
    echo "5. Exporter les données"
    echo -e "${RED}R${NC} - Retour au menu principal"
    echo ""
    read -p "Choisissez une option: " report_choice

    case $report_choice in
        1) 
            generate_html_report
            ;;
        2)
            generate_xml_report
            ;;
        3)
            list_existing_reports
            ;;
        4)
            analyze_results
            ;;
        5)
            export_data
            ;;
        [Rr])
            main_menu
            ;;
        *)
            echo -e "${RED}Option invalide${NC}"
            sleep 2
            reporting_menu
            ;;
    esac
}

# Fonction pour générer un rapport HTML
generate_html_report() {
    clear
    echo -e "${CYAN}=== Génération du Rapport HTML ===${NC}"
    
    # Créer le répertoire des rapports s'il n'existe pas
    mkdir -p "$REPORTS_DIR"
    
    # Demander le nom du rapport
    read -p "Nom du rapport (sans extension): " report_name
    
    if [ -z "$report_name" ]; then
    echo -e "${RED}Nom de rapport invalide${NC}"
    sleep 2
    reporting_menu
    return
fi
    
    report_file="$REPORTS_DIR/${report_name}_$(date +%Y%m%d_%H%M%S).html"
    
    echo "Génération du rapport HTML..."
    
    # Création du rapport HTML avec un template basique
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Rapport de Pentest - $report_name</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; }
        .section { margin: 20px 0; }
        .vuln-critical { color: red; }
        .vuln-high { color: orange; }
        .vuln-medium { color: yellow; }
        .vuln-low { color: green; }
    </style>
</head>
<body>
    <h1>Rapport de Pentest - $report_name</h1>
    <div class="section">
        <h2>Informations générales</h2>
        <p>Date: $(date)</p>
        <p>Cible: ${target_host:-Non spécifié}</p>
    </div>
    <div class="section">
        <h2>Résumé des découvertes</h2>
        $(generate_summary)
    </div>
    <div class="section">
        <h2>Détails des vulnérabilités</h2>
        $(generate_vulnerabilities_details)
    </div>
</body>
</html>
EOF

    echo -e "${GREEN}Rapport généré avec succès: $report_file${NC}"
    sleep 2
    reporting_menu
}

# Fonction pour générer un rapport XML
generate_xml_report() {
    clear
    echo -e "${CYAN}=== Génération du Rapport XML ===${NC}"
    
    mkdir -p "$REPORTS_DIR"
    read -p "Nom du rapport (sans extension): " report_name
    
   if [ -z "$report_name" ]; then
    echo -e "${RED}Nom de rapport invalide${NC}"
    sleep 2
    reporting_menu
    return
fi
    
    report_file="$REPORTS_DIR/${report_name}_$(date +%Y%m%d_%H%M%S).xml"
    
    echo "Génération du rapport XML..."
    
    cat > "$report_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<pentest_report>
    <metadata>
        <name>$report_name</name>
        <date>$(date)</date>
        <target>${target_host:-Non spécifié}</target>
    </metadata>
    <findings>
        $(generate_xml_findings)
    </findings>
</pentest_report>
EOF

    echo -e "${GREEN}Rapport généré avec succès: $report_file${NC}"
    sleep 2
    reporting_menu
}

# Fonction pour lister les rapports existants
list_existing_reports() {
    clear
    echo -e "${CYAN}=== Rapports Existants ===${NC}"
    echo ""
    
    if [ ! -d "$REPORTS_DIR" ] || [ -z "$(ls -A "$REPORTS_DIR" 2>/dev/null)" ]; then
        echo "Aucun rapport trouvé"
        sleep 2
        reporting_menu
        return
    fi
    
    echo "Rapports disponibles:"
    echo "--------------------"
    ls -lt "$REPORTS_DIR" | grep -E "\.(html|xml)$" | while read -r line; do
        echo "$line"
    done
    
    echo ""
    echo "1. Ouvrir un rapport"
    echo "2. Supprimer un rapport"
    echo "3. Retour"
    
    read -p "Choix: " choice
    
    case $choice in
        1)
            read -p "Nom du rapport à ouvrir: " report_name
            if [ -f "$REPORTS_DIR/$report_name" ]; then
                xdg-open "$REPORTS_DIR/$report_name" 2>/dev/null || echo "Impossible d'ouvrir le rapport"
            else
                echo "Rapport non trouvé"
            fi
            ;;
        2)
            read -p "Nom du rapport à supprimer: " report_name
            if [ -f "$REPORTS_DIR/$report_name" ]; then
                rm "$REPORTS_DIR/$report_name"
                echo "Rapport supprimé"
            else
                echo "Rapport non trouvé"
            fi
            ;;
        3)
            reporting_menu
            return
            ;;
    esac
    
    sleep 2
    list_existing_reports
}

# Fonction pour analyser les résultats
analyze_results() {
    clear
    echo -e "${CYAN}=== Analyse des Résultats ===${NC}"
    echo ""
    echo "1. Statistiques générales"
    echo "2. Analyse des vulnérabilités"
    echo "3. Tendances"
    echo "4. Retour"
    
    read -p "Choix: " analyze_choice
    
    case $analyze_choice in
        1)
            show_general_statistics
            ;;
        2)
            analyze_vulnerabilities
            ;;
        3)
            show_trends
            ;;
        4)
            reporting_menu
            return
            ;;
        *)
            echo "Option invalide"
            ;;
    esac
    
    sleep 2
    analyze_results
}

# Fonction pour exporter les données
export_data() {
    clear
    echo -e "${CYAN}=== Export des Données ===${NC}"
    echo ""
    echo "1. Export CSV"
    echo "2. Export JSON"
    echo "3. Export PDF"
    echo "4. Retour"
    
    read -p "Choix: " export_choice
    
    case $export_choice in
        1)
            export_to_csv
            ;;
        2)
            export_to_json
            ;;
        3)
            export_to_pdf
            ;;
        4)
            reporting_menu
            return
            ;;
        *)
            echo "Option invalide"
            ;;
    esac
    
    sleep 2
    export_data
}
# Fonction pour générer un résumé des découvertes
generate_summary() {
    local summary=""
    
    # Compter les vulnérabilités par niveau de gravité
    local critical=$(count_vulnerabilities "critical")
    local high=$(count_vulnerabilities "high")
    local medium=$(count_vulnerabilities "medium")
    local low=$(count_vulnerabilities "low")
    
    # Générer le HTML pour le résumé
    cat << EOF
    <div class="summary">
        <h3>Vulnérabilités découvertes</h3>
        <ul>
            <li class="vuln-critical">Critiques: $critical</li>
            <li class="vuln-high">Élevées: $high</li>
            <li class="vuln-medium">Moyennes: $medium</li>
            <li class="vuln-low">Faibles: $low</li>
        </ul>
        <p>Total des vulnérabilités: $((critical + high + medium + low))</p>
        <p>Scan effectué le: $(date)</p>
    </div>
EOF
}

# Fonction pour compter les vulnérabilités par niveau
count_vulnerabilities() {
    local severity=$1
    local count=0

    # Lire le fichier de résultats des scans
    if [ -f "$SCAN_RESULTS" ]; then
        count=$(grep -c "SEVERITY:$severity" "$SCAN_RESULTS")
    fi

    echo "$count"
}

# Raccourcis utilisés par show_active_alerts
count_critical_vulnerabilities() { count_vulnerabilities "critical"; }
count_major_vulnerabilities()    { count_vulnerabilities "high"; }

# Compte les ports ouverts dans les scans Nmap les plus récents
count_open_ports() {
    local count=0
    if [ -d "$SCAN_DIR" ]; then
        count=$(grep -h -E "^[0-9]+/(tcp|udp).*open" "$SCAN_DIR"/*.txt 2>/dev/null | wc -l)
    fi
    echo "$count"
}

# Fonction pour générer les détails des vulnérabilités
generate_vulnerabilities_details() {
    if [ ! -f "$SCAN_RESULTS" ]; then
        echo "<p>Aucun résultat de scan disponible</p>"
        return
    fi
    
    echo "<div class='vulnerabilities'>"
    
    # Lire et formater chaque vulnérabilité
    while IFS='|' read -r severity name description solution; do
        cat << EOF
        <div class="vuln-item vuln-${severity}">
            <h4>$name</h4>
            <p><strong>Sévérité:</strong> $severity</p>
            <p><strong>Description:</strong> $description</p>
            <p><strong>Solution:</strong> $solution</p>
        </div>
EOF
    done < "$SCAN_RESULTS"
    
    echo "</div>"
}

# Fonction pour générer les résultats en XML
generate_xml_findings() {
    if [ ! -f "$SCAN_RESULTS" ]; then
        echo "<finding>Aucun résultat disponible</finding>"
        return
    fi
    
    while IFS='|' read -r severity name description solution; do
        cat << EOF
        <finding>
            <severity>$severity</severity>
            <name>$name</name>
            <description>$description</description>
            <solution>$solution</solution>
        </finding>
EOF
    done < "$SCAN_RESULTS"
}

# Fonction pour afficher les statistiques générales
show_general_statistics() {
    clear
    echo -e "${CYAN}=== Statistiques Générales ===${NC}"
    echo ""
    
    local critical=$(count_vulnerabilities "critical")
    local high=$(count_vulnerabilities "high")
    local medium=$(count_vulnerabilities "medium")
    local low=$(count_vulnerabilities "low")
    
    echo "Résumé des vulnérabilités:"
    echo -e "${RED}Critiques: $critical${NC}"
    echo -e "${YELLOW}Élevées: $high${NC}"
    echo -e "${CYAN}Moyennes: $medium${NC}"
    echo -e "${GREEN}Faibles: $low${NC}"
    
    echo ""
    echo "Total: $((critical + high + medium + low))"
    
    read -p "Appuyez sur Entrée pour continuer..."
}

# Fonction pour analyser les vulnérabilités
analyze_vulnerabilities() {
    clear
    echo -e "${CYAN}=== Analyse des Vulnérabilités ===${NC}"
    echo ""
    
    if [ ! -f "$SCAN_RESULTS" ]; then
        echo "Aucun résultat de scan disponible"
        read -p "Appuyez sur Entrée pour continuer..."
        return
    fi
    
    # Analyse des types de vulnérabilités les plus communes
    echo "Top 5 des vulnérabilités les plus fréquentes:"
    echo "----------------------------------------"
    grep -E "NAME:" "$SCAN_RESULTS" | sort | uniq -c | sort -rn | head -5
    
    echo ""
    read -p "Appuyez sur Entrée pour continuer..."
}

# Fonction pour afficher les tendances
show_trends() {
    clear
    echo -e "${CYAN}=== Tendances des Vulnérabilités ===${NC}"
    echo ""
    
    # Comparer avec les scans précédents
    local previous_scan="$REPORTS_DIR/previous_scan.dat"
    local current_scan="$SCAN_RESULTS"
    
    if [ ! -f "$previous_scan" ] || [ ! -f "$current_scan" ]; then
        echo "Données insuffisantes pour l'analyse des tendances"
        read -p "Appuyez sur Entrée pour continuer..."
        return
    fi
    
    # Analyse des changements
    echo "Changements depuis le dernier scan:"
    diff "$previous_scan" "$current_scan" | grep -E "^[<>]" | sort | uniq -c
    
    echo ""
    read -p "Appuyez sur Entrée pour continuer..."
}

# Fonction pour exporter en CSV
export_to_csv() {
    local export_file="$REPORTS_DIR/export_$(date +%Y%m%d_%H%M%S).csv"
    
    echo "Severity,Name,Description,Solution" > "$export_file"
    
    if [ -f "$SCAN_RESULTS" ]; then
        while IFS='|' read -r severity name description solution; do
            echo "$severity,$name,$description,$solution" >> "$export_file"
        done < "$SCAN_RESULTS"
        
        echo -e "${GREEN}Export CSV créé: $export_file${NC}"
    else
        echo -e "${RED}Aucune donnée à exporter${NC}"
    fi
    
    sleep 2
}

# Fonction pour exporter en JSON
export_to_json() {
    local export_file="$REPORTS_DIR/export_$(date +%Y%m%d_%H%M%S).json"
    
    echo "{" > "$export_file"
    echo "  \"findings\": [" >> "$export_file"
    
    if [ -f "$SCAN_RESULTS" ]; then
        local first=true
        while IFS='|' read -r severity name description solution; do
            if [ "$first" = true ]; then
                first=false
            else
                echo "," >> "$export_file"
            fi
            
            cat << EOF >> "$export_file"
    {
      "severity": "$severity",
      "name": "$name",
      "description": "$description",
      "solution": "$solution"
    }
EOF
        done < "$SCAN_RESULTS"
    fi
    
    echo "  ]" >> "$export_file"
    echo "}" >> "$export_file"
    
    echo -e "${GREEN}Export JSON créé: $export_file${NC}"
    sleep 2
}

# Fonction pour exporter en PDF
export_to_pdf() {
    # Vérifier si wkhtmltopdf est installé
    if ! command -v wkhtmltopdf &> /dev/null; then
        echo -e "${RED}wkhtmltopdf n'est pas installé. Installation nécessaire pour la génération PDF${NC}"
        sleep 2
        return
    fi

    local temp_html="$REPORTS_DIR/temp_report_${DATE}.html"
    local export_file="$REPORTS_DIR/export_$(date +%Y%m%d_%H%M%S).pdf"

    # Construire un rapport HTML autonome (sans appels interactifs)
    {
        cat << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Rapport de Pentest</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; }
        .section { margin: 20px 0; }
        .vuln-critical { color: red; }
        .vuln-high { color: orange; }
        .vuln-medium { color: yellow; }
        .vuln-low { color: green; }
    </style>
</head>
<body>
    <h1>Rapport de Pentest</h1>
    <div class="section">
        <h2>Informations générales</h2>
        <p>Date: $(date)</p>
        <p>Cible: ${target_host:-Non spécifié}</p>
    </div>
    <div class="section">
        <h2>Résumé des découvertes</h2>
        $(generate_summary)
    </div>
    <div class="section">
        <h2>Détails des vulnérabilités</h2>
        $(generate_vulnerabilities_details)
    </div>
</body>
</html>
EOF
    } > "$temp_html"

    wkhtmltopdf "$temp_html" "$export_file"
    rm -f "$temp_html"

    echo -e "${GREEN}Export PDF créé: $export_file${NC}"
    sleep 2
}

# Menu des options avancées
advanced_options_menu() {
    show_header
    echo -e "${YELLOW}=== OPTIONS AVANCÉES ===${NC}"
    echo ""
    echo "1. Configuration des timeouts"
    echo "2. Options de fragmentation"
    echo "3. Spooling et leurres"
    echo "4. Configuration du bandwidth"
    echo "5. Options avancées de scan"
    echo -e "${RED}R${NC} - Retour au menu principal"
    echo ""
    read -p "Choisissez une option: " advanced_choice

    case $advanced_choice in
        1) timeout_config ;;
        2) fragmentation_config ;;
        3) spoof_config ;;
        4) bandwidth_config ;;
        5) advanced_scan_config ;;
        [Rr]) main_menu ;;
        *) echo "Option invalide" ; sleep 2 ; advanced_options_menu ;;
    esac
}

# Configuration des timeouts
timeout_config() {
    show_header
    echo -e "${YELLOW}=== CONFIGURATION DES TIMEOUTS ===${NC}"
    echo ""
    echo "1. Initial RTT timeout: (défaut: 1000ms)"
    echo "2. Min RTT timeout: (défaut: 100ms)"
    echo "3. Max RTT timeout: (défaut: 10000ms)"
    echo "4. Scan delay: (défaut: 0ms)"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " timeout_choice
    case $timeout_choice in
        1)
            read -p "Entrez la valeur (en ms): " initial_rtt
            echo "Initial RTT configuré à ${initial_rtt}ms"
            sleep 2
            timeout_config
            ;;
        2)
            read -p "Entrez la valeur (en ms): " min_rtt
            echo "Min RTT configuré à ${min_rtt}ms"
            sleep 2
            timeout_config
            ;;
        3)
            read -p "Entrez la valeur (en ms): " max_rtt
            echo "Max RTT configuré à ${max_rtt}ms"
            sleep 2
            timeout_config
            ;;
        4)
            read -p "Entrez la valeur (en ms): " scan_delay
            echo "Scan delay configuré à ${scan_delay}ms"
            sleep 2
            timeout_config
            ;;
        [Rr]) advanced_options_menu ;;
        *) echo "Option invalide" ; sleep 2 ; timeout_config ;;
    esac
}

# Configuration de la fragmentation
fragmentation_config() {
    show_header
    echo -e "${YELLOW}=== OPTIONS DE FRAGMENTATION ===${NC}"
    echo ""
    echo "1. Activer la fragmentation (-f)"
    echo "2. Double fragmentation (-ff)"
    echo "3. Taille des paquets personnalisée"
    echo "4. MTU personnalisé"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " frag_choice
    case $frag_choice in
        1)
            echo "Fragmentation simple activée"
            FRAG_OPTIONS="-f"
            sleep 2
            fragmentation_config
            ;;
        2)
            echo "Double fragmentation activée"
            FRAG_OPTIONS="-ff"
            sleep 2
            fragmentation_config
            ;;
        3)
            read -p "Entrez la taille des paquets (8-1500 bytes): " packet_size
            echo "Taille des paquets configurée à ${packet_size} bytes"
            FRAG_OPTIONS="--data-length ${packet_size}"
            sleep 2
            fragmentation_config
            ;;
        4)
            read -p "Entrez la valeur MTU (8-1500): " mtu_size
            echo "MTU configuré à ${mtu_size}"
            FRAG_OPTIONS="--mtu ${mtu_size}"
            sleep 2
            fragmentation_config
            ;;
        [Rr]) advanced_options_menu ;;
        *) echo "Option invalide" ; sleep 2 ; fragmentation_config ;;
    esac
}

# Configuration du spoofing et des leurres
spoof_config() {
    show_header
    echo -e "${YELLOW}=== SPOOFING ET LEURRES ===${NC}"
    echo ""
    echo "1. Décoy aléatoire"
    echo "2. IP source personnalisée"
    echo "3. MAC source personnalisée"
    echo "4. Configuration des leurres multiples"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " spoof_choice
    case $spoof_choice in
        1)
            echo "Configuration des decoys aléatoires..."
            SPOOF_OPTIONS="-D RND:5"
            sleep 2
            spoof_config
            ;;
        2)
            read -p "Entrez l'IP source: " source_ip
            echo "IP source configurée à ${source_ip}"
            SPOOF_OPTIONS="-S ${source_ip}"
            sleep 2
            spoof_config
            ;;
        3)
            read -p "Entrez l'adresse MAC source: " source_mac
            echo "MAC source configurée à ${source_mac}"
            SPOOF_OPTIONS="--spoof-mac ${source_mac}"
            sleep 2
            spoof_config
            ;;
        4)
            read -p "Entrez les IPs des leurres (séparées par des virgules): " decoys
            echo "Leurres configurés: ${decoys}"
            SPOOF_OPTIONS="-D ${decoys}"
            sleep 2
            spoof_config
            ;;
        [Rr]) advanced_options_menu ;;
        *) echo "Option invalide" ; sleep 2 ; spoof_config ;;
    esac
}

# Configuration de la bande passante
bandwidth_config() {
    show_header
    echo -e "${YELLOW}=== CONFIGURATION DU BANDWIDTH ===${NC}"
    echo ""
    echo "1. Limitation de bande passante"
    echo "2. Taux de paquets"
    echo "3. Parallélisme des sondes"
    echo "4. Configuration agressive"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " bw_choice
    case $bw_choice in
        1)
            read -p "Entrez la limite de bande passante (en KB/s): " bw_limit
            echo "Bande passante limitée à ${bw_limit} KB/s"
            BW_OPTIONS="--min-rate ${bw_limit}"
            sleep 2
            bandwidth_config
            ;;
        2)
            read -p "Entrez le taux de paquets par seconde: " packet_rate
            echo "Taux configuré à ${packet_rate} paquets/s"
            BW_OPTIONS="--min-parallelism ${packet_rate}"
            sleep 2
            bandwidth_config
            ;;
        3)
            read -p "Entrez le nombre de sondes parallèles: " parallel_probes
            echo "Parallélisme configuré à ${parallel_probes} sondes"
            BW_OPTIONS="--min-hostgroup ${parallel_probes}"
            sleep 2
            bandwidth_config
            ;;
        4)
            echo "Configuration agressive activée"
            BW_OPTIONS="-T4"
            sleep 2
            bandwidth_config
            ;;
        [Rr]) advanced_options_menu ;;
        *) echo "Option invalide" ; sleep 2 ; bandwidth_config ;;
    esac
}

# Configuration avancée des scans
advanced_scan_config() {
    show_header
    echo -e "${YELLOW}=== OPTIONS AVANCÉES DE SCAN ===${NC}"
    echo ""
    echo "1. Version détection agressive"
    echo "2. Scan de scripts personnalisés"
    echo "3. Configuration IPv6"
    echo "4. Options de sortie personnalisées"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " adv_scan_choice
    case $adv_scan_choice in
        1)
            echo "Version détection agressive activée"
            SCAN_OPTIONS="-sV --version-intensity 9"
            sleep 2
            advanced_scan_config
            ;;
        2)
            read -p "Entrez le chemin du script personnalisé: " custom_script
            echo "Script personnalisé configuré: ${custom_script}"
            SCAN_OPTIONS="--script=${custom_script}"
            sleep 2
            advanced_scan_config
            ;;
        3)
            echo "Configuration IPv6 activée"
            SCAN_OPTIONS="-6"
            sleep 2
            advanced_scan_config
            ;;
        4)
            read -p "Entrez le format de sortie (normal/xml/script/grepable): " output_format
            echo "Format de sortie configuré à ${output_format}"
            SCAN_OPTIONS="-oA scan_${DATE}"
            sleep 2
            advanced_scan_config
            ;;
        [Rr]) advanced_options_menu ;;
        *) echo "Option invalide" ; sleep 2 ; advanced_scan_config ;;
    esac
}

# Menu de monitoring
monitoring_menu() {
    show_header
    echo -e "${YELLOW}=== MONITORING ===${NC}"
    echo ""
    echo "1. Statut des scans"
    echo "2. Utilisation des ressources"
    echo "3. Logs en temps réel"
    echo "4. Alertes"
    echo -e "${RED}R${NC} - Retour au menu précédent"
    echo ""
    read -p "Choisissez une option: " monitoring_choice

    case $monitoring_choice in
        1) scan_status ;;
        2) resource_usage ;;
        3) real_time_logs ;;
        4) alerts ;;
        [Rr]) main_menu ;;
        *) echo "Option invalide" ; sleep 2 ; monitoring_menu ;;
    esac
}

nmap_menu() {
    show_header
    echo -e "${YELLOW}=== MENU SCANS NMAP ===${NC}"
    echo ""
    echo "1. Scan furtif (SYN)"
    echo "2. Scan ultra discret"
    echo "3. Scan agressif complet"
    echo "4. Scan Full TCP"
    echo "5. Scan UDP"
    echo "6. Scan IPv6"
    echo "7. Scan ACK"
    echo "8. Voir/Supprimer les scans existants"
    echo -e "${RED}R${NC} - Retour au menu principal"
    echo ""
    read -p "Choisissez un type de scan: " scan_choice

    case $scan_choice in
        1) stealth_scan ;;
        2) ultra_stealth_scan ;;
        3) aggressive_scan ;;
        4) full_tcp_scan ;;
        5) udp_scan ;;
        6) ipv6_scan ;;
        7) ack_scan ;;
        8) view_scan_results "Nmap" ;;
        [Rr]) main_menu ;;
        *) echo "Option invalide" ; sleep 2 ; nmap_menu ;;
    esac
}


# Fonction pour le menu principal
main_menu() {
    show_header
    echo -e "${GREEN}[A]${NC} - Scans NMAP"
    echo -e "${GREEN}[B]${NC} - Scripts NSE"
    echo -e "${GREEN}[C]${NC} - Options avancées"
    echo -e "${GREEN}[D]${NC} - Analyse et Reporting"
    echo -e "${GREEN}[E]${NC} - Outils complémentaires"
    echo -e "${GREEN}[M]${NC} - Monitoring"
    echo -e "${RED}[Q]${NC} - Quitter"
    echo ""
    read -p "Choisissez une option: " choice

    case $choice in
        [Aa]) nmap_menu ;;
        [Bb]) nse_menu ;;
        [Cc]) advanced_options_menu ;;
        [Dd]) reporting_menu ;;
        [Ee]) complementary_tools_menu ;;
        [Mm]) monitoring_menu ;;
        [Qq]) exit 0 ;;
        *) echo "Option invalide" ; sleep 2 ; main_menu ;;
    esac
}

# Menu des scripts NSE
nse_menu() {
    show_header
    echo -e "${YELLOW}=== MENU SCRIPTS NSE ===${NC}"
    echo ""
    echo "1. Scripts de vulnérabilités"
    echo "2. Scripts d'exploitation"
    echo "3. Scripts d'authentification"
    echo "4. Scripts de découverte"
    echo "5. Scripts sûrs uniquement"
    echo "6. Tous les scripts"
    echo "7. Scripts personnalisés"
    echo "8. Voir le résultat des scans existants"

    echo -e "${RED}R${NC} - Retour au menu principal"
    
    read -p "Choisissez une option: " nse_choice
    case $nse_choice in
        1) nse_scan "vuln" ;;
        2) nse_scan "exploit" ;;
        3) nse_scan "auth" ;;
        4) nse_scan "discovery" ;;
        5) nse_scan "safe" ;;
        6) nse_scan "all" ;;
        7) custom_nse_scan ;;
        8) view_scan_results "NSE" ;;
        [Rr]) main_menu ;;
        *) echo "Option invalide" ; sleep 2 ; nse_menu ;;
    esac

}

# Couleurs en gras pour le visuel
BOLD='\033[1m'
DIM='\033[2m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'

# Renvoie la taille humaine d'un fichier (KB, MB, ...)
_human_size() {
    local bytes=$1
    if   (( bytes < 1024 ));         then printf "%dB"   "$bytes"
    elif (( bytes < 1048576 ));      then printf "%.1fKB" "$(echo "$bytes/1024" | bc -l)"
    elif (( bytes < 1073741824 ));   then printf "%.1fMB" "$(echo "$bytes/1048576" | bc -l)"
    else                                  printf "%.1fGB" "$(echo "$bytes/1073741824" | bc -l)"
    fi
}

# Colorise une sortie nmap : ports open/closed/filtered, sévérités, headers
_colorize_scan_output() {
    sed -E \
        -e "s/(open[[:space:]])/$(printf "${GREEN}")\1$(printf "${NC}")/g" \
        -e "s/(closed[[:space:]])/$(printf "${RED}")\1$(printf "${NC}")/g" \
        -e "s/(filtered[[:space:]])/$(printf "${YELLOW}")\1$(printf "${NC}")/g" \
        -e "s/(VULNERABLE[^[:space:]]*)/$(printf "${RED}${BOLD}")\1$(printf "${NC}")/gI" \
        -e "s/(CRITICAL|HIGH)/$(printf "${RED}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/(MEDIUM|WARNING)/$(printf "${YELLOW}")\1$(printf "${NC}")/g" \
        -e "s/(LOW|INFO)/$(printf "${BLUE}")\1$(printf "${NC}")/g" \
        -e "s/(CVE-[0-9]{4}-[0-9]+)/$(printf "${MAGENTA}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/(Nmap scan report for[^|]*)/$(printf "${CYAN}${BOLD}")\1$(printf "${NC}")/g" \
        -e "s/^(PORT[[:space:]]+STATE.*)/$(printf "${BOLD}${WHITE}")\1$(printf "${NC}")/" \
        -e "s/(Host is up[^|]*)/$(printf "${GREEN}")\1$(printf "${NC}")/g"
}

# Affiche un en-tête joli en boîte unicode
_print_box() {
    local title=$1
    local width=${2:-70}
    local pad=$(( width - ${#title} - 4 ))
    (( pad < 0 )) && pad=0
    printf "${CYAN}┌"
    printf '─%.0s' $(seq 1 $((width - 2)))
    printf "┐${NC}\n"
    printf "${CYAN}│${BOLD}${WHITE} %s %s${CYAN}│${NC}\n" "$title" "$(printf ' %.0s' $(seq 1 $pad))"
    printf "${CYAN}└"
    printf '─%.0s' $(seq 1 $((width - 2)))
    printf "┘${NC}\n"
}

view_scan_results() {
    local scan_type=${1:-Nmap}  # "Nmap" ou "NSE"
    show_header

    local scan_dir
    local icon
    if [ "$scan_type" == "Nmap" ]; then
        scan_dir="$SCAN_DIR"
        icon="🛰️ "
    else
        scan_dir="$NSE_SCAN_DIR"
        icon="🔍"
    fi

    _print_box "${icon} RÉSULTATS DES SCANS ${scan_type^^}" 70
    echo ""

    # Liste des fichiers (tri du plus récent au plus ancien)
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$scan_dir" -maxdepth 1 -type f -not -name '.gitkeep' -printf '%T@ %p\0' 2>/dev/null \
             | sort -z -rn | sed -z 's/^[0-9.]* //')

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}⚠  Aucun scan enregistré dans ${DIM}$scan_dir${NC}"
        echo ""
        read -p "  Appuyez sur Entrée pour revenir..."
        [[ "$scan_type" == "Nmap" ]] && nmap_menu || nse_menu
        return
    fi

    # Table d'en-tête
    printf "  ${BOLD}${WHITE}%-4s %-42s %10s %16s${NC}\n" "N°" "Fichier" "Taille" "Date"
    printf "  ${DIM}%s${NC}\n" "────────────────────────────────────────────────────────────────────────────"

    local i name size date_h
    for i in "${!files[@]}"; do
        name=$(basename "${files[$i]}")
        size=$(stat -c%s "${files[$i]}" 2>/dev/null || wc -c < "${files[$i]}")
        date_h=$(date -r "${files[$i]}" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c%y "${files[$i]}" 2>/dev/null | cut -d. -f1)
        # Tronque le nom si trop long
        local short_name="$name"
        if (( ${#short_name} > 42 )); then
            short_name="${short_name:0:39}..."
        fi
        printf "  ${GREEN}%-4s${NC} %-42s ${CYAN}%10s${NC} ${DIM}%16s${NC}\n" \
               "$((i+1))" "$short_name" "$(_human_size "$size")" "$date_h"
    done

    printf "  ${DIM}%s${NC}\n" "────────────────────────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}Actions :${NC} ${GREEN}[N°]${NC} afficher  ${YELLOW}[S]${NC} supprimer  ${RED}[R]${NC} retour"
    echo ""
    read -p "  ❯ Votre choix : " file_choice

    if [[ "$file_choice" =~ ^[0-9]+$ ]] && [ "$file_choice" -ge 1 ] && [ "$file_choice" -le "${#files[@]}" ]; then
        local selected_path="${files[$((file_choice-1))]}"
        local selected_file
        selected_file=$(basename "$selected_path")
        local fsize fmtime fmtime_h
        fsize=$(stat -c%s "$selected_path" 2>/dev/null || wc -c < "$selected_path")
        fmtime_h=$(date -r "$selected_path" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c%y "$selected_path" 2>/dev/null | cut -d. -f1)

        clear
        _print_box "📄 $selected_file" 70
        echo -e "  ${DIM}Taille  :${NC} $(_human_size "$fsize")"
        echo -e "  ${DIM}Modifié :${NC} $fmtime_h"
        echo -e "  ${DIM}Chemin  :${NC} $selected_path"
        echo ""
        printf "${CYAN}"
        printf '─%.0s' $(seq 1 70)
        printf "${NC}\n"

        # Affichage avec coloration via less si disponible, sinon stdout direct
        if command -v less &> /dev/null; then
            _colorize_scan_output < "$selected_path" | less -R
        else
            _colorize_scan_output < "$selected_path"
        fi

        printf "${CYAN}"
        printf '─%.0s' $(seq 1 70)
        printf "${NC}\n"
        echo ""
        read -p "  Appuyez sur Entrée pour revenir à la liste..."
        view_scan_results "$scan_type"
        return
    elif [[ "$file_choice" =~ ^[Ss]$ ]]; then
        delete_scan_file "$scan_type"
        return
    elif [[ "$file_choice" =~ ^[Rr]$ ]]; then
        [[ "$scan_type" == "Nmap" ]] && nmap_menu || nse_menu
        return
    else
        echo -e "  ${RED}✗ Option invalide${NC}"
        sleep 1
        view_scan_results "$scan_type"
        return
    fi
}
delete_scan_file() {
    local scan_type=$1  # "Nmap" ou "NSE"
    local scan_dir

    if [ "$scan_type" == "Nmap" ]; then
        scan_dir="$SCAN_DIR"
    else
        scan_dir="$NSE_SCAN_DIR"
    fi

    echo "Suppression dans : $scan_dir"

    # Vérifier si des fichiers existent avant suppression
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$(basename "$f")")
    done < <(find "$scan_dir" -maxdepth 1 -type f -not -name '.gitkeep' -print0 2>/dev/null)

    if [ ${#files[@]} -eq 0 ]; then
        echo "Aucun fichier à supprimer."
        sleep 2
        view_scan_results "$scan_type"
        return
    fi

    echo "Fichiers disponibles :"
    for i in "${!files[@]}"; do
        echo "$((i+1)) - ${files[$i]}"
    done

    echo ""
    read -p "Entrez le numéro du fichier à supprimer (ou '*' pour tout supprimer, 'R' pour retour) : " delete_choice

    if [[ "$delete_choice" =~ ^[0-9]+$ ]]; then
        if (( delete_choice >= 1 && delete_choice <= ${#files[@]} )); then
            local selected_file="${files[$((delete_choice-1))]}"
            rm -- "$scan_dir/$selected_file"
            echo -e "${GREEN}Fichier supprimé : $selected_file${NC}"
        else
            echo -e "${RED}Numéro invalide. Veuillez choisir un fichier existant.${NC}"
        fi
    elif [[ "$delete_choice" == "*" ]]; then
        find "$scan_dir" -maxdepth 1 -type f -not -name '.gitkeep' -delete
        echo -e "${GREEN}Tous les fichiers ont été supprimés.${NC}"
    elif [[ "$delete_choice" =~ ^[Rr]$ ]]; then
        view_scan_results "$scan_type"
        return
    else
        echo -e "${RED}Option invalide.${NC}"
    fi

    sleep 2
    view_scan_results "$scan_type"
}



# Valide une cible (IPv4, IPv6, hostname, CIDR) pour éviter l'injection shell
validate_target() {
    local t=$1
    if [[ "$t" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
        return 0
    fi
    echo -e "${RED}Cible invalide. Caractères autorisés : lettres, chiffres, . : / - _${NC}"
    return 1
}

# Construit le tableau d'options avancées si elles ont été configurées
_extra_opts() {
    local -a opts=()
    [ -n "$FRAG_OPTIONS"  ] && read -r -a tmp <<< "$FRAG_OPTIONS"  && opts+=("${tmp[@]}")
    [ -n "$SPOOF_OPTIONS" ] && read -r -a tmp <<< "$SPOOF_OPTIONS" && opts+=("${tmp[@]}")
    [ -n "$BW_OPTIONS"    ] && read -r -a tmp <<< "$BW_OPTIONS"    && opts+=("${tmp[@]}")
    [ -n "$SCAN_OPTIONS"  ] && read -r -a tmp <<< "$SCAN_OPTIONS"  && opts+=("${tmp[@]}")
    printf '%s\n' "${opts[@]}"
}

# Fonctions pour les types de scans spécifiques
full_tcp_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN FULL TCP ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"
    local output_file="$SCAN_DIR/full_tcp_${DATE}.txt"
    local -a extra; mapfile -t extra < <(_extra_opts)
    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -sT -p- -v "${extra[@]}" "$target" | tee "$output_file"
    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

udp_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN UDP ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"
    local output_file="$SCAN_DIR/udp_${DATE}.txt"
    local -a extra; mapfile -t extra < <(_extra_opts)
    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -sU -v "${extra[@]}" "$target" | tee "$output_file"
    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

ipv6_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN IPv6 ===${NC}"
    read -p "Entrez l'adresse IPv6 cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"
    local output_file="$SCAN_DIR/ipv6_${DATE}.txt"
    local -a extra; mapfile -t extra < <(_extra_opts)
    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -6 -v "${extra[@]}" "$target" | tee "$output_file"
    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

ack_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN ACK ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"
    local output_file="$SCAN_DIR/ack_${DATE}.txt"
    local -a extra; mapfile -t extra < <(_extra_opts)
    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -sA -v "${extra[@]}" "$target" | tee "$output_file"
    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

# Fonction pour le scan furtif
stealth_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN FURTIF (SYN) ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"
    read -p "Vitesse du scan (0-5): " timing
    read -p "Fragmenter les paquets? (o/n): " fragment

    local -a cmd=(sudo nmap -sS -v)
    [[ $timing =~ ^[0-5]$ ]] && cmd+=("-T$timing")
    [[ $fragment == "o" ]] && cmd+=("-f")
    local -a extra; mapfile -t extra < <(_extra_opts)

    local output_file="$SCAN_DIR/stealth_scan_${DATE}.txt"

    echo -e "${BLUE}Exécution du scan...${NC}"
    "${cmd[@]}" "${extra[@]}" "$target" | tee "$output_file"

    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

# Fonction pour le scan ultra discret
ultra_stealth_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN ULTRA DISCRET ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"

    local output_file="$SCAN_DIR/ultra_stealth_${DATE}.txt"

    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -sS -T2 -f -D RND:5 --data-length 24 "$target" | tee "$output_file"

    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

# Fonction pour le scan agressif
aggressive_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN AGRESSIF ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nmap_menu; return; }
    target_host="$target"

    local output_file="$SCAN_DIR/aggressive_${DATE}.txt"
    local -a extra; mapfile -t extra < <(_extra_opts)

    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap -A -T4 -v "${extra[@]}" "$target" | tee "$output_file"

    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nmap_menu
}

# Fonction pour le statut des scans
scan_status() {
    show_header
    echo -e "${YELLOW}=== STATUT DES SCANS ===${NC}"
    echo ""
    ps aux | grep nmap | grep -v grep
    echo ""
    echo -e "${BLUE}Scans récents :${NC}"
    ls -lt "$SCAN_DIR" | head -n 5
    echo ""
    read -p "Appuyez sur Entrée pour continuer"
    monitoring_menu
}

# Fonction pour l'utilisation des ressources
resource_usage() {
    show_header
    echo -e "${YELLOW}=== UTILISATION DES RESSOURCES ===${NC}"
    echo ""
    echo -e "${BLUE}Utilisation CPU :${NC}"
    top -bn1 | head -n 5
    echo ""
    echo -e "${BLUE}Utilisation mémoire :${NC}"
    free -h
    echo ""
    echo -e "${BLUE}Espace disque :${NC}"
    df -h
    echo ""
    read -p "Appuyez sur Entrée pour continuer"
    monitoring_menu
}

# Fonction pour les logs en temps réel
real_time_logs() {
    show_header
    echo -e "${YELLOW}=== LOGS EN TEMPS RÉEL ===${NC}"
    echo -e "${BLUE}Appuyez sur Ctrl+C pour revenir au menu${NC}"
    echo ""

    # Choix de la source de logs selon ce qui est disponible
    local log_file=""
    for candidate in /var/log/syslog /var/log/messages /var/log/auth.log; do
        if [ -r "$candidate" ]; then
            log_file="$candidate"
            break
        fi
    done

    # On capture Ctrl+C pour ne pas tuer le script
    trap ' ' INT
    if [ -n "$log_file" ]; then
        tail -f "$log_file" | grep --line-buffered -i nmap
    else
        echo -e "${RED}Aucun fichier de log lisible trouvé. Tentative via journalctl...${NC}"
        journalctl -f 2>/dev/null | grep --line-buffered -i nmap
    fi
    trap - INT

    monitoring_menu
}

# Configuration des seuils d'alerte
ALERT_CONFIG="$HOME/.config/pentest_tools/alert_thresholds.conf"

# Fonction pour configurer les seuils d'alerte
configure_alert_thresholds() {
    clear
    echo -e "${YELLOW}=== Configuration des Seuils d'Alerte ===${NC}"
    echo ""
    echo "1. Seuil de vulnérabilités critiques (actuel: ${alert_critical_threshold:-5})"
    echo "2. Seuil de vulnérabilités majeures (actuel: ${alert_major_threshold:-10})"
    echo "3. Seuil de ports ouverts (actuel: ${alert_ports_threshold:-20})"
    echo "4. Retour"
    
    read -p "Choisissez une option: " threshold_choice
    
    case $threshold_choice in
        1)
            read -p "Nouveau seuil pour les vulnérabilités critiques: " new_critical
            if [[ "$new_critical" =~ ^[0-9]+$ ]]; then
                alert_critical_threshold=$new_critical
                save_alert_thresholds
                echo -e "${GREEN}Seuil mis à jour${NC}"
            else
                echo -e "${RED}Valeur invalide${NC}"
            fi
            sleep 2
            configure_alert_thresholds
            ;;
        2)
            read -p "Nouveau seuil pour les vulnérabilités majeures: " new_major
            if [[ "$new_major" =~ ^[0-9]+$ ]]; then
                alert_major_threshold=$new_major
                save_alert_thresholds
                echo -e "${GREEN}Seuil mis à jour${NC}"
            else
                echo -e "${RED}Valeur invalide${NC}"
            fi
            sleep 2
            configure_alert_thresholds
            ;;
        3)
            read -p "Nouveau seuil pour les ports ouverts: " new_ports
            if [[ "$new_ports" =~ ^[0-9]+$ ]]; then
                alert_ports_threshold=$new_ports
                save_alert_thresholds
                echo -e "${GREEN}Seuil mis à jour${NC}"
            else
                echo -e "${RED}Valeur invalide${NC}"
            fi
            sleep 2
            configure_alert_thresholds
            ;;
        4)
            alerts
            ;;
        *)
            echo -e "${RED}Option invalide${NC}"
            sleep 2
            configure_alert_thresholds
            ;;
    esac
}

# Fonction pour sauvegarder les seuils d'alerte
save_alert_thresholds() {
    mkdir -p "$(dirname "$ALERT_CONFIG")"
    cat > "$ALERT_CONFIG" << EOF
alert_critical_threshold=$alert_critical_threshold
alert_major_threshold=$alert_major_threshold
alert_ports_threshold=$alert_ports_threshold
EOF
}

# Fonction pour charger les seuils d'alerte
load_alert_thresholds() {
    if [ -f "$ALERT_CONFIG" ]; then
        source "$ALERT_CONFIG"
    else
        # Valeurs par défaut
        alert_critical_threshold=5
        alert_major_threshold=10
        alert_ports_threshold=20
        save_alert_thresholds
    fi
}

# Modification de la fonction alerts existante
alerts() {
    show_header
    echo -e "${YELLOW}=== ALERTES ===${NC}"
    echo ""
    echo "1. Voir les alertes actives"
    echo "2. Configurer les seuils d'alerte"
    echo "3. Activer les notifications"
    echo "4. Désactiver les notifications"
    echo "5. Envoyer une notification"
    echo "6. Configurer les notifications"
    echo -e "${RED}R${NC} - Retour"
    
    read -p "Choisissez une option: " alert_choice
    case $alert_choice in
        1) 
            show_active_alerts
            sleep 2
            alerts
            ;;
        2)
            configure_alert_thresholds
            ;;
        3)
            enable_notifications
            sleep 2
            alerts
            ;;
        4)
            disable_notifications
            sleep 2
            alerts
            ;;
        5)
            read -p "Entrez le message de notification: " message
            send_notification "$message"
            sleep 2
            alerts
            ;;
        6)
            configure_notifications
            alerts
            ;;
        [Rr]) 
            monitoring_menu
            ;;
        *)
            echo "Option invalide"
            sleep 2
            alerts
            ;;
    esac
}

# Fonction pour afficher les alertes actives
show_active_alerts() {
    clear
    echo -e "${YELLOW}=== Alertes Actives ===${NC}"
    echo ""
    
    # Vérifier les seuils et afficher les alertes appropriées
    local alerts_found=0
    
    if [ "$(count_critical_vulnerabilities)" -gt "$alert_critical_threshold" ]; then
        echo -e "${RED}[ALERTE] Nombre de vulnérabilités critiques supérieur au seuil${NC}"
        alerts_found=1
    fi
    
    if [ "$(count_major_vulnerabilities)" -gt "$alert_major_threshold" ]; then
        echo -e "${YELLOW}[ALERTE] Nombre de vulnérabilités majeures supérieur au seuil${NC}"
        alerts_found=1
    fi
    
    if [ "$(count_open_ports)" -gt "$alert_ports_threshold" ]; then
        echo -e "${YELLOW}[ALERTE] Nombre de ports ouverts supérieur au seuil${NC}"
        alerts_found=1
    fi
    
    if [ $alerts_found -eq 0 ]; then
        echo "Aucune alerte active"
    fi
}


# Fonctions de notification
enable_notifications() {
    echo "Notifications activées."
}

disable_notifications() {
    echo "Notifications désactivées."
}

send_notification() {
    local message=$1
    echo "Notification: $message"
}

configure_notifications() {
    echo "Configuration des notifications."
}

# Fonction pour les scans NSE
nse_scan() {
    local script_type=$1
    show_header
    echo -e "${YELLOW}=== SCAN NSE: $script_type ===${NC}"
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nse_menu; return; }
    target_host="$target"

    local -a cmd=(sudo nmap)
    case $script_type in
        vuln|exploit|auth|discovery|safe|all)
            cmd+=(--script "$script_type")
            ;;
    esac

    local output_file="$SCAN_DIR/nse_${script_type}_${DATE}.txt"

    echo -e "${BLUE}Exécution du scan...${NC}"
    "${cmd[@]}" "$target" | tee "$output_file"

    echo ""
    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nse_menu
}

# Fonction pour les scans NSE personnalisés
custom_nse_scan() {
    show_header
    echo -e "${YELLOW}=== SCAN NSE PERSONNALISÉ ===${NC}"
    read -p "Entrez le nom du script NSE: " script_name
    read -p "Entrez l'adresse IP cible: " target
    validate_target "$target" || { sleep 2; nse_menu; return; }
    target_host="$target"

    # On accepte seulement des noms de scripts simples (lettres, chiffres, -, _, ,)
    if ! [[ "$script_name" =~ ^[A-Za-z0-9_,.\*-]+$ ]]; then
        echo -e "${RED}Nom de script invalide.${NC}"
        sleep 2
        nse_menu
        return
    fi

    local output_file="$SCAN_DIR/nse_custom_${DATE}.txt"

    echo -e "${BLUE}Exécution du scan...${NC}"
    sudo nmap --script "$script_name" "$target" | tee "$output_file"

    echo -e "${GREEN}Scan terminé. Résultats sauvegardés dans: $output_file${NC}"
    read -p "Appuyez sur Entrée pour continuer"
    nse_menu
}

# Point d'entrée du script
load_alert_thresholds
main_menu
