/* ════════════════════════════════════════════════════════════════════════
   SPECTER WEB — frontend logic
   ═══════════════════════════════════════════════════════════════════════ */

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

let TOKEN = localStorage.getItem("specter_token") || "";
let CATALOG = {};
let STATUS = null;
let CURRENT_WS = null;

// ─── Auth ──────────────────────────────────────────────────────────────

async function tryLogin(token) {
    try {
        const r = await fetch("/api/auth", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ token }),
        });
        if (!r.ok) {
            let detail = `HTTP ${r.status}`;
            try {
                const j = await r.json();
                if (j && j.detail) detail = j.detail;
            } catch {}
            return { ok: false, error: detail };
        }
        return { ok: true };
    } catch (e) {
        console.error("tryLogin network error:", e);
        return { ok: false, error: "Erreur réseau : " + e.message };
    }
}

async function api(path, opts = {}) {
    const headers = { ...(opts.headers || {}), "X-Specter-Token": TOKEN };
    if (opts.body && !(opts.body instanceof FormData)) {
        headers["Content-Type"] = "application/json";
    }
    const r = await fetch(path, { ...opts, headers });
    if (!r.ok) {
        const err = await r.json().catch(() => ({ detail: r.statusText }));
        throw new Error(err.detail || r.statusText);
    }
    return r.json();
}

// ─── Init ──────────────────────────────────────────────────────────────

window.addEventListener("DOMContentLoaded", async () => {
    console.log("[SPECTER] Init...");
    $("#login-btn").addEventListener("click", doLogin);
    $("#token-input").addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
            e.preventDefault();
            doLogin();
        }
    });

    // Tente auto-login si token déjà stocké (mais n'empêche pas le formulaire de marcher)
    if (TOKEN) {
        console.log("[SPECTER] Auto-login attempt with stored token...");
        const r = await tryLogin(TOKEN);
        if (r.ok) {
            console.log("[SPECTER] Auto-login OK");
            return launchApp();
        }
        console.log("[SPECTER] Auto-login failed:", r.error, "— resetting");
        localStorage.removeItem("specter_token");
        TOKEN = "";
    }
    $("#token-input").focus();
});

async function doLogin() {
    const btn = $("#login-btn");
    const input = $("#token-input");
    const errEl = $("#login-error");

    const t = input.value.trim();
    errEl.textContent = "";

    if (!t) {
        errEl.textContent = "Saisis le token affiché dans la console.";
        input.focus();
        return;
    }

    // Visual feedback : loading
    btn.disabled = true;
    const originalLabel = btn.textContent;
    btn.textContent = "Connexion…";
    console.log("[SPECTER] doLogin: posting token...");

    try {
        const r = await tryLogin(t);
        if (!r.ok) {
            errEl.textContent = r.error || "Token invalide";
            input.select();
            return;
        }
        TOKEN = t;
        localStorage.setItem("specter_token", t);
        console.log("[SPECTER] Login OK, launching app");
        launchApp();
    } catch (e) {
        errEl.textContent = "Erreur inattendue : " + e.message;
        console.error("[SPECTER] doLogin error:", e);
    } finally {
        btn.disabled = false;
        btn.textContent = originalLabel;
    }
}

function updateTicker(label, text) {
    const tl = document.getElementById("sbo-tick-label");
    const tv = document.getElementById("sbo-tick-val");
    if (tl) tl.textContent = label;
    if (tv) tv.textContent = text || "";
}

async function launchApp() {
    $("#login").hidden = true;
    $("#app").hidden = false;
    setupNavigation();
    setupExecPanel();
    setupModal();
    setupPipeline();
    setupTabs();
    setupLogout();

    try {
        CATALOG = await api("/api/catalog");
        renderToolGrids();
        await refreshStatus();
        renderReconSection();
        renderScanSection();
        renderWebSection();
        renderAdSection();
        await refreshRecent();
    } catch (e) {
        console.error(e);
        alert("Erreur d'initialisation : " + e.message);
    }
}

// ─── Navigation ────────────────────────────────────────────────────────

function setupNavigation() {
    $$(".nav-item").forEach((el) => {
        el.addEventListener("click", () => switchView(el.dataset.view));
    });
}

async function switchView(name) {
    $$(".nav-item").forEach((n) => n.classList.toggle("active", n.dataset.view === name));
    $$(".view").forEach((v) => v.classList.toggle("active", v.dataset.view === name));

    if (name === "dashboard") {
        await refreshStatus();
        await refreshRecent();
    } else if (name === "results") {
        loadFiles(currentCategory);
    } else if (name === "reports") {
        loadReports();
    } else if (name === "tools") {
        renderToolsStatus();
    }
}

// ─── Status & dashboard ────────────────────────────────────────────────

async function refreshStatus() {
    STATUS = await api("/api/status");
    $("#stat-nmap").textContent = STATUS.counts.nmap;
    $("#stat-recon").textContent = STATUS.counts.recon;
    $("#stat-web").textContent = STATUS.counts.web;
    $("#stat-ad").textContent = STATUS.counts.ad;
    $("#stat-reports").textContent = STATUS.counts.reports;
}

async function refreshRecent() {
    const container = $("#recent-files");
    container.innerHTML = "";
    const cats = ["nmap", "recon", "web", "ad"];
    let all = [];
    for (const c of cats) {
        try {
            const r = await api(`/api/files?category=${c}`);
            r.files.slice(0, 3).forEach((f) => all.push({ ...f, category: c }));
        } catch {}
    }
    all.sort((a, b) => b.mtime - a.mtime);
    if (all.length === 0) {
        container.innerHTML = '<div class="empty">Aucun scan pour le moment.</div>';
        return;
    }
    all.slice(0, 10).forEach((f) => container.appendChild(buildFileItem(f)));
}

// ─── Tool grids ────────────────────────────────────────────────────────

const PHASE_TOOLS = {
    recon: ["subfinder", "amass", "assetfinder", "dnsx", "httpx", "whatweb", "katana", "theharvester"],
    scan: ["nmap-stealth", "nmap-ultra", "nmap-aggr", "nmap-full", "nmap-udp", "nmap-ipv6",
           "nmap-ack", "masscan", "rustscan", "naabu", "nse"],
    web: ["ffuf", "gobuster", "feroxbuster", "dirb", "nuclei", "nikto", "wapiti",
          "sqlmap", "wpscan", "sslscan"],
    ad: ["smbclient", "smbmap", "enum4linux", "nxc"],
};

function renderToolGrids() {
    for (const [phase, list] of Object.entries(PHASE_TOOLS)) {
        if (phase === "recon") continue; // handled by renderReconSection
        if (phase === "scan")  continue; // handled by renderScanSection
        if (phase === "web")   continue; // handled by renderWebSection
        if (phase === "ad")    continue; // handled by renderAdSection
        const grid = $(`#${phase}-tools`);
        if (!grid) continue;
        grid.innerHTML = "";
        for (const t of list) {
            const spec = CATALOG[t];
            if (!spec) continue;
            grid.appendChild(buildToolCard(t, spec));
        }
    }
}

// ─── Recon pipeline ────────────────────────────────────────────────────

const RECON_PIPELINE = [
    { id: 1, label: "Discovery",      desc: "Énumération des sous-domaines & OSINT",  tools: ["subfinder", "amass", "assetfinder", "theharvester"] },
    { id: 2, label: "DNS Resolution", desc: "Résolution et validation DNS",             tools: ["dnsx"] },
    { id: 3, label: "HTTP Probing",   desc: "Sondage des services HTTP/HTTPS actifs",  tools: ["httpx", "whatweb"] },
    { id: 4, label: "Crawling",       desc: "Exploration et cartographie des endpoints", tools: ["katana"] },
];

const TOOL_BINARY_MAP = {
    // recon
    subfinder: "subfinder", amass: "amass", assetfinder: "assetfinder",
    dnsx: "dnsx", httpx: "httpx", whatweb: "whatweb",
    katana: "katana", theharvester: "theHarvester",
    // scan
    "nmap-stealth": "nmap", "nmap-ultra": "nmap", "nmap-aggr": "nmap",
    "nmap-full": "nmap", "nmap-udp": "nmap", "nmap-ipv6": "nmap",
    "nmap-ack": "nmap", masscan: "masscan", rustscan: "rustscan",
    naabu: "naabu", nse: "nmap",
    // web
    ffuf: "ffuf", gobuster: "gobuster", feroxbuster: "feroxbuster",
    dirb: "dirb", nuclei: "nuclei", nikto: "nikto", wapiti: "wapiti",
    sqlmap: "sqlmap", wpscan: "wpscan", sslscan: "sslscan",
    // ad — nxc can be installed as nxc, netexec or crackmapexec
    smbclient: "smbclient", smbmap: "smbmap", enum4linux: "enum4linux",
    nxc: ["nxc", "netexec", "crackmapexec"],
};

function isToolAvailable(toolId) {
    if (!STATUS || !STATUS.tools) return null;
    const bin = TOOL_BINARY_MAP[toolId];
    if (bin == null) return null;
    if (Array.isArray(bin)) return bin.some(b => STATUS.tools[b] === true);
    return STATUS.tools[bin] === true;
}

function renderReconSection() {
    const container = document.getElementById("recon-tools");
    if (!container) return;
    container.innerHTML = "";
    container.className = "recon-pipeline";

    for (const stage of RECON_PIPELINE) {
        const stageEl = document.createElement("div");
        stageEl.className = "recon-stage";

        const header = document.createElement("div");
        header.className = "recon-stage-header";
        header.innerHTML = `
            <div class="recon-stage-num">${stage.id}</div>
            <div>
                <div class="recon-stage-label">${stage.label}</div>
                <div class="recon-stage-desc">${stage.desc}</div>
            </div>`;
        stageEl.appendChild(header);

        const grid = document.createElement("div");
        grid.className = "recon-stage-grid";
        for (const toolId of stage.tools) {
            const spec = CATALOG[toolId];
            if (!spec) continue;
            grid.appendChild(buildPipelineCard(toolId, spec, 'recon'));
        }
        stageEl.appendChild(grid);
        container.appendChild(stageEl);
    }

    setupSharedReconInputs();
}

function buildPipelineCard(name, spec, prefix) {
    const available = isToolAvailable(name);
    const card = document.createElement("div");
    card.className = "tool-card recon-tool-card" + (available === false ? " unavailable" : "");
    card.id = `${prefix}-card-${name}`;

    // Header
    const head = document.createElement("div");
    head.className = "tool-card-header";
    let badge;
    if (available === false) {
        badge = `<span class="tool-badge ko">non installé</span>`;
    } else if (available === true) {
        badge = `<span class="tool-badge ok">prêt</span>`;
    } else {
        badge = `<span class="tool-badge">${name}</span>`;
    }
    head.innerHTML = `
        <div class="tool-card-title">${spec.label}</div>
        <div class="recon-card-badges">
            ${badge}
            <span class="tool-result-badge" id="result-${prefix}-${name}" hidden></span>
        </div>`;
    card.appendChild(head);

    // Inputs
    const form = document.createElement("div");
    form.className = "form-grid";
    const inputs = {};
    for (const need of spec.needs) {
        const id = `f-${prefix}-${name}-${need}`;
        const lbl = document.createElement("label");
        lbl.setAttribute("for", id);
        lbl.textContent = labelFor(need);
        form.appendChild(lbl);
        const inp = document.createElement("input");
        inp.id = id;
        inp.placeholder = placeholderFor(need);
        inp.setAttribute(`data-${prefix}-field`, need);
        form.appendChild(inp);
        inputs[need] = inp;
    }
    for (const opt of optionalsFor(name)) {
        const id = `f-${prefix}-${name}-${opt}`;
        const lbl = document.createElement("label");
        lbl.setAttribute("for", id);
        lbl.textContent = labelFor(opt);
        form.appendChild(lbl);
        const inp = document.createElement("input");
        inp.id = id;
        inp.placeholder = placeholderFor(opt);
        form.appendChild(inp);
        inputs[opt] = inp;
    }
    card.appendChild(form);

    // Mini output (collapsible)
    const miniOut = document.createElement("pre");
    miniOut.className = "tool-mini-out";
    miniOut.id = `mini-out-${prefix}-${name}`;
    miniOut.hidden = true;
    card.appendChild(miniOut);

    // Footer
    const footer = document.createElement("div");
    footer.className = "recon-card-footer";

    const toggleBtn = document.createElement("button");
    toggleBtn.className = "btn-ghost recon-toggle-btn";
    toggleBtn.textContent = "▾ Sortie";
    toggleBtn.id = `toggle-out-${prefix}-${name}`;
    toggleBtn.hidden = true;
    toggleBtn.addEventListener("click", () => {
        miniOut.hidden = !miniOut.hidden;
        toggleBtn.textContent = miniOut.hidden ? "▾ Sortie" : "▴ Masquer";
    });

    const launchBtn = document.createElement("button");
    launchBtn.className = "btn-primary recon-launch-btn";
    launchBtn.id = `launch-${prefix}-${name}`;
    launchBtn.textContent = "▶ Lancer";
    if (available === false) launchBtn.disabled = true;

    launchBtn.addEventListener("click", () => {
        const params = {};
        for (const k of Object.keys(inputs)) {
            const v = document.getElementById(`f-${prefix}-${name}-${k}`).value.trim();
            if (v) params[k] = v;
        }
        runTool(name, spec.label, params, miniOut, card);
    });

    footer.appendChild(toggleBtn);
    footer.appendChild(launchBtn);
    card.appendChild(footer);

    return card;
}

function setupSharedReconInputs() {
    const domainInp = document.getElementById("recon-domain");
    const urlInp    = document.getElementById("recon-url");

    function fillDomain(val) {
        document.querySelectorAll("#recon-tools input[data-recon-field='domain']").forEach(i => i.value = val);
        document.querySelectorAll("#recon-tools input[data-recon-field='target']").forEach(i => { if (!i.value) i.value = val; });
    }
    function fillUrl(val) {
        document.querySelectorAll("#recon-tools input[data-recon-field='url']").forEach(i => i.value = val);
    }

    if (domainInp) domainInp.addEventListener("input", e => {
        fillDomain(e.target.value);
        if (urlInp && !urlInp.value && e.target.value) {
            const url = "https://" + e.target.value;
            urlInp.value = url;
            fillUrl(url);
        }
    });
    if (urlInp) urlInp.addEventListener("input", e => fillUrl(e.target.value));
}

// ─── Scan réseau pipeline ──────────────────────────────────────────────

const SCAN_PIPELINE = [
    { id: 1, label: "Découverte rapide",   desc: "Port scanning ultra-rapide — trouve les ports ouverts en secondes",    tools: ["rustscan", "naabu", "masscan"] },
    { id: 2, label: "Scan furtif",          desc: "Scans discrets conçus pour éviter la détection IDS/IPS",              tools: ["nmap-stealth", "nmap-ultra"] },
    { id: 3, label: "Énumération détaillée", desc: "Services, OS, versions, firewalls — analyse approfondie des ports",  tools: ["nmap-aggr", "nmap-full", "nmap-udp", "nmap-ipv6", "nmap-ack"] },
    { id: 4, label: "Scripts NSE",          desc: "Exécution de scripts Nmap ciblés (vuln, exploit, auth, safe...)",     tools: ["nse"] },
];

function renderScanSection() {
    const container = document.getElementById("scan-tools");
    if (!container) return;
    container.innerHTML = "";
    container.className = "recon-pipeline";

    for (const stage of SCAN_PIPELINE) {
        const stageEl = document.createElement("div");
        stageEl.className = "recon-stage";

        const header = document.createElement("div");
        header.className = "recon-stage-header";
        header.innerHTML = `
            <div class="recon-stage-num">${stage.id}</div>
            <div>
                <div class="recon-stage-label">${stage.label}</div>
                <div class="recon-stage-desc">${stage.desc}</div>
            </div>`;
        stageEl.appendChild(header);

        const grid = document.createElement("div");
        grid.className = "recon-stage-grid";
        for (const toolId of stage.tools) {
            const spec = CATALOG[toolId];
            if (!spec) continue;
            grid.appendChild(buildPipelineCard(toolId, spec, 'scan'));
        }
        stageEl.appendChild(grid);
        container.appendChild(stageEl);
    }

    setupSharedScanInputs();
}

function setupSharedScanInputs() {
    const targetInp = document.getElementById("scan-target");
    if (!targetInp) return;
    targetInp.addEventListener("input", e => {
        document.querySelectorAll("#scan-tools input[data-scan-field='target']").forEach(i => i.value = e.target.value);
    });
}

// ─── Web application pipeline ──────────────────────────────────────────

const WEB_PIPELINE = [
    { id: 1, label: "Fuzzing & Discovery",      desc: "Énumération de répertoires, fichiers et endpoints cachés",          tools: ["ffuf", "gobuster", "feroxbuster", "dirb"] },
    { id: 2, label: "Scan de vulnérabilités",   desc: "Détection automatisée de failles connues (CVE, misconfigs...)",     tools: ["nuclei", "nikto", "wapiti"] },
    { id: 3, label: "Exploitation ciblée",       desc: "Injection SQL et audit CMS WordPress",                              tools: ["sqlmap", "wpscan"] },
    { id: 4, label: "Audit SSL/TLS",             desc: "Analyse des protocoles, certificats et chiffrements",              tools: ["sslscan"] },
];

function renderWebSection() {
    const container = document.getElementById("web-tools");
    if (!container) return;
    container.innerHTML = "";
    container.className = "recon-pipeline";

    for (const stage of WEB_PIPELINE) {
        const stageEl = document.createElement("div");
        stageEl.className = "recon-stage";

        const header = document.createElement("div");
        header.className = "recon-stage-header";
        header.innerHTML = `
            <div class="recon-stage-num">${stage.id}</div>
            <div>
                <div class="recon-stage-label">${stage.label}</div>
                <div class="recon-stage-desc">${stage.desc}</div>
            </div>`;
        stageEl.appendChild(header);

        const grid = document.createElement("div");
        grid.className = "recon-stage-grid";
        for (const toolId of stage.tools) {
            const spec = CATALOG[toolId];
            if (!spec) continue;
            grid.appendChild(buildPipelineCard(toolId, spec, 'web'));
        }
        stageEl.appendChild(grid);
        container.appendChild(stageEl);
    }

    setupSharedWebInputs();
}

function setupSharedWebInputs() {
    const urlInp      = document.getElementById("web-url");
    const wordlistInp = document.getElementById("web-wordlist");

    if (urlInp) urlInp.addEventListener("input", e => {
        const val = e.target.value;
        document.querySelectorAll("#web-tools input[data-web-field='url']").forEach(i => i.value = val);
        // Auto-derive hostname:port for sslscan
        try {
            const u = new URL(val);
            const port = u.port || (u.protocol === "https:" ? "443" : "80");
            const target = `${u.hostname}:${port}`;
            document.querySelectorAll("#web-tools input[data-web-field='target']").forEach(i => i.value = target);
        } catch {}
    });

    if (wordlistInp) wordlistInp.addEventListener("input", e => {
        document.querySelectorAll("#web-tools input[data-web-field='wordlist']").forEach(i => i.value = e.target.value);
    });
}

// ─── Active Directory pipeline ────────────────────────────────────────

const AD_PIPELINE = [
    { id: 1, label: "SMB",                   desc: "Énumération des partages et permissions SMB",                       tools: ["smbclient", "smbmap"] },
    { id: 2, label: "Énumération système",   desc: "Utilisateurs, groupes, politiques, RID cycling via enum4linux",    tools: ["enum4linux"] },
    { id: 3, label: "Multi-protocoles",      desc: "Authentification et énumération via SMB, LDAP, WinRM, MSSQL...",   tools: ["nxc"] },
];

function renderAdSection() {
    const container = document.getElementById("ad-tools");
    if (!container) return;
    container.innerHTML = "";
    container.className = "recon-pipeline";

    for (const stage of AD_PIPELINE) {
        const stageEl = document.createElement("div");
        stageEl.className = "recon-stage";

        const header = document.createElement("div");
        header.className = "recon-stage-header";
        header.innerHTML = `
            <div class="recon-stage-num">${stage.id}</div>
            <div>
                <div class="recon-stage-label">${stage.label}</div>
                <div class="recon-stage-desc">${stage.desc}</div>
            </div>`;
        stageEl.appendChild(header);

        const grid = document.createElement("div");
        grid.className = "recon-stage-grid";
        for (const toolId of stage.tools) {
            const spec = CATALOG[toolId];
            if (!spec) continue;
            grid.appendChild(buildPipelineCard(toolId, spec, 'ad'));
        }
        stageEl.appendChild(grid);
        container.appendChild(stageEl);
    }

    setupSharedAdInputs();
}

function setupSharedAdInputs() {
    const targetInp   = document.getElementById("ad-target");
    const userInp     = document.getElementById("ad-user");
    const passwordInp = document.getElementById("ad-password");

    if (targetInp) targetInp.addEventListener("input", e => {
        document.querySelectorAll("#ad-tools input[data-ad-field='target']").forEach(i => i.value = e.target.value);
    });
    if (userInp) userInp.addEventListener("input", e => {
        document.querySelectorAll("#ad-tools input[data-ad-field='user']").forEach(i => i.value = e.target.value);
    });
    if (passwordInp) passwordInp.addEventListener("input", e => {
        document.querySelectorAll("#ad-tools input[data-ad-field='password']").forEach(i => i.value = e.target.value);
    });
}

function buildToolCard(name, spec) {
    const card = document.createElement("div");
    card.className = "tool-card";
    const head = document.createElement("div");
    head.className = "tool-card-header";
    head.innerHTML = `
        <div class="tool-card-title">${spec.label}</div>
        <div class="tool-badge">${name}</div>`;
    card.appendChild(head);

    const form = document.createElement("div");
    form.className = "form-grid";
    const inputs = {};
    for (const need of spec.needs) {
        const id = `f-${name}-${need}`;
        form.innerHTML += `<label for="${id}">${labelFor(need)}</label>`;
        const inp = document.createElement("input");
        inp.id = id;
        inp.placeholder = placeholderFor(need);
        form.appendChild(inp);
        inputs[need] = inp;
    }
    // Champs optionnels selon outil
    const opts = optionalsFor(name);
    for (const opt of opts) {
        const id = `f-${name}-${opt}`;
        form.innerHTML += `<label for="${id}">${labelFor(opt)}</label>`;
        const inp = document.createElement("input");
        inp.id = id;
        inp.placeholder = placeholderFor(opt);
        form.appendChild(inp);
        inputs[opt] = inp;
    }
    card.appendChild(form);

    const btn = document.createElement("button");
    btn.className = "btn-primary";
    btn.textContent = "▶ Lancer";
    btn.style.width = "100%";
    btn.addEventListener("click", () => {
        const params = {};
        for (const k of Object.keys(inputs)) {
            const v = document.getElementById(`f-${name}-${k}`).value.trim();
            if (v) params[k] = v;
        }
        runTool(name, spec.label, params);
    });
    card.appendChild(btn);
    return card;
}

function labelFor(k) {
    return ({
        target: "Cible", url: "URL", domain: "Domaine",
        wordlist: "Wordlist", category: "Catégorie",
        protocol: "Protocole", user: "User", password: "Pass",
        severity: "Sévérité", rate: "Rate", ports: "Ports",
    })[k] || k;
}
function placeholderFor(k) {
    return ({
        target: "192.168.1.0/24 ou example.com",
        url: "https://example.com",
        domain: "example.com",
        wordlist: "/usr/share/wordlists/dirb/common.txt",
        category: "vuln, exploit, auth, safe...",
        protocol: "smb / ldap / winrm / mssql",
        user: "username",
        password: "password / hash",
        severity: "critical,high,medium",
        rate: "1000",
        ports: "1-65535",
    })[k] || "";
}
function optionalsFor(name) {
    if (name === "smbclient" || name === "nxc") return ["user", "password"];
    if (name === "nuclei") return ["severity"];
    if (name === "masscan") return ["ports", "rate"];
    return [];
}

// ─── Live execution via WebSocket ──────────────────────────────────────

function setupExecPanel() {
    $("#exec-close").addEventListener("click", () => {
        $("#exec-panel").hidden = true;
        if (CURRENT_WS) CURRENT_WS.close();
    });
    $("#exec-cancel").addEventListener("click", () => {
        if (CURRENT_WS) {
            CURRENT_WS.send(JSON.stringify({ action: "cancel" }));
        }
    });
}

function setupLogout() {
    const btn = document.getElementById("logout-btn");
    if (!btn) return;
    btn.addEventListener("click", () => {
        localStorage.removeItem("specter_token");
        document.cookie = "specter_token=; Max-Age=0; path=/";
        TOKEN = "";
        location.reload();
    });
}

function runTool(tool, label, params, miniOutputEl = null, cardEl = null) {
    $("#exec-panel").hidden = false;
    $("#exec-title").textContent = `▶ ${label}`;
    $("#exec-cmd").textContent = "Initialisation...";
    $("#exec-output").innerHTML = "";

    // Card running state
    if (cardEl) {
        cardEl.classList.remove("done");
        cardEl.classList.add("running");
        const lb = cardEl.querySelector(".recon-launch-btn");
        if (lb) { lb.disabled = true; lb.textContent = "…"; }
        const rb = cardEl.querySelector(".tool-result-badge");
        if (rb) rb.hidden = true;
    }
    if (miniOutputEl) miniOutputEl.innerHTML = "";

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${proto}//${location.host}/ws/run`);
    CURRENT_WS = ws;

    ws.onopen = () => {
        ws.send(JSON.stringify({ token: TOKEN, tool, params }));
    };
    ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        const out = $("#exec-output");
        if (msg.type === "start") {
            $("#exec-cmd").textContent = msg.cmd;
            updateTicker("RUNNING", msg.cmd);
            appendLine(out, `[+] Démarrage — sortie : ${msg.outfile}`, "sev-low");
        } else if (msg.type === "line") {
            appendLine(out, msg.data, classifyLine(msg.data));
            if (miniOutputEl) {
                appendLine(miniOutputEl, msg.data, classifyLine(msg.data));
                miniOutputEl.scrollTop = miniOutputEl.scrollHeight;
            }
        } else if (msg.type === "info") {
            appendLine(out, "[i] " + msg.msg, "sev-medium");
        } else if (msg.type === "error") {
            appendLine(out, "[!] " + msg.msg, "sev-critical");
        } else if (msg.type === "end") {
            appendLine(out, `\n[✓] Terminé (code ${msg.code}) — ${msg.outfile}`, "open");
            updateTicker("TERMINÉ", label);
            setTimeout(() => updateTicker("STATUS", "Prêt"), 4000);
            if (cardEl) {
                cardEl.classList.remove("running");
                cardEl.classList.add("done");
                const lb = cardEl.querySelector(".recon-launch-btn");
                if (lb) { lb.disabled = false; lb.textContent = "↺ Relancer"; }
                const tb = cardEl.querySelector(".recon-toggle-btn");
                if (tb) tb.hidden = false;
                if (miniOutputEl) {
                    const count = miniOutputEl.children.length;
                    const rb = cardEl.querySelector(".tool-result-badge");
                    if (rb && count > 0) { rb.textContent = count + " lignes"; rb.hidden = false; }
                }
            }
            refreshStatus();
            refreshRecent();
        }
        out.scrollTop = out.scrollHeight;
    };
    ws.onerror = () => appendLine($("#exec-output"), "[!] Erreur WebSocket", "sev-critical");
    ws.onclose = () => {
        CURRENT_WS = null;
        if (cardEl) {
            cardEl.classList.remove("running");
            const lb = cardEl.querySelector(".recon-launch-btn");
            if (lb && lb.textContent === "…") { lb.disabled = false; lb.textContent = "▶ Lancer"; }
        }
    };
}

function appendLine(container, text, klass) {
    const line = document.createElement("div");
    if (klass) line.className = klass;
    line.textContent = text;
    container.appendChild(line);
}

function classifyLine(line) {
    if (/VULNERABLE/i.test(line)) return "vuln";
    if (/CVE-\d{4}-\d+/i.test(line)) return "cve";
    if (/\[critical\]/i.test(line)) return "sev-critical";
    if (/\[high\]/i.test(line)) return "sev-high";
    if (/\[medium\]/i.test(line)) return "sev-medium";
    if (/\[low\]|\[info\]/i.test(line)) return "sev-low";
    if (/\bopen\b/.test(line) && /\/(tcp|udp)/.test(line)) return "open";
    if (/\bfiltered\b/.test(line)) return "filtered";
    if (/\bclosed\b/.test(line)) return "closed";
    return "";
}

// ─── Pipeline FULL RECON ───────────────────────────────────────────────

function setupPipeline() {
    $("#pipeline-run").addEventListener("click", async () => {
        const dom = $("#pipeline-domain").value.trim();
        if (!dom) return;
        const out = $("#pipeline-output");
        out.hidden = false;
        out.textContent = "Lancement du pipeline...\n";
        try {
            const r = await api("/api/pipeline/recon", {
                method: "POST",
                body: JSON.stringify({ domain: dom }),
            });
            out.textContent =
                `[+] Pipeline terminé\n` +
                `    Sous-domaines : ${r.counts.subs} → ${r.subs}\n` +
                `    Vivants       : ${r.counts.live} → ${r.live}\n` +
                `    Probe HTTP    : ${r.counts.probe} → ${r.probe}\n`;
            refreshStatus();
            refreshRecent();
        } catch (e) {
            out.textContent = "[!] Erreur : " + e.message;
        }
    });
}

// ─── Files tab ─────────────────────────────────────────────────────────

let currentCategory = "nmap";

function setupTabs() {
    $$(".tab").forEach((t) => {
        t.addEventListener("click", () => {
            $$(".tab").forEach((x) => x.classList.remove("active"));
            t.classList.add("active");
            currentCategory = t.dataset.cat;
            loadFiles(currentCategory);
        });
    });
}

async function loadFiles(category) {
    const container = $("#files-list");
    container.innerHTML = '<div class="empty">Chargement…</div>';
    try {
        const r = await api(`/api/files?category=${category}`);
        container.innerHTML = "";
        if (r.files.length === 0) {
            container.innerHTML = '<div class="empty">Aucun fichier dans cette catégorie.</div>';
            return;
        }
        r.files.forEach((f) => container.appendChild(buildFileItem(f)));
    } catch (e) {
        container.innerHTML = `<div class="empty">Erreur : ${e.message}</div>`;
    }
}

async function loadReports() {
    const container = $("#reports-list");
    container.innerHTML = '<div class="empty">Chargement…</div>';
    try {
        const r = await api(`/api/files?category=reports`);
        container.innerHTML = "";
        if (r.files.length === 0) {
            container.innerHTML = '<div class="empty">Aucun rapport.</div>';
            return;
        }
        r.files.forEach((f) => container.appendChild(buildFileItem(f)));
    } catch (e) {
        container.innerHTML = `<div class="empty">Erreur : ${e.message}</div>`;
    }
}

function buildFileItem(f) {
    const item = document.createElement("div");
    item.className = "file-item";
    item.innerHTML = `
        <div class="file-name">${f.name}</div>
        <div class="file-size">${humanSize(f.size)}</div>
        <div class="file-date">${new Date(f.mtime * 1000).toLocaleString()}</div>
        <div class="file-actions">
            <button class="btn-ghost" data-act="view">Ouvrir</button>
        </div>`;
    item.addEventListener("click", (e) => {
        if (e.target.dataset.act === "view" || e.target === item || e.target.classList.contains("file-name")) {
            openFile(f.path);
        }
    });
    return item;
}

function humanSize(b) {
    if (b < 1024) return b + " B";
    if (b < 1048576) return (b / 1024).toFixed(1) + " KB";
    if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB";
    return (b / 1073741824).toFixed(1) + " GB";
}

// ─── File viewer modal ─────────────────────────────────────────────────

let currentFilePath = null;

function setupModal() {
    $("#file-close").addEventListener("click", () => $("#file-modal").hidden = true);
    $("#file-delete").addEventListener("click", async () => {
        if (!currentFilePath) return;
        if (!confirm("Supprimer ce fichier ?")) return;
        try {
            await api(`/api/file?path=${encodeURIComponent(currentFilePath)}`, { method: "DELETE" });
            $("#file-modal").hidden = true;
            refreshStatus();
            if ($("#files-list").offsetParent) loadFiles(currentCategory);
            if ($("#reports-list").offsetParent) loadReports();
            refreshRecent();
        } catch (e) {
            alert("Erreur : " + e.message);
        }
    });
}

async function openFile(path) {
    try {
        const r = await api(`/api/file?path=${encodeURIComponent(path)}`);
        currentFilePath = path;
        $("#file-modal-name").textContent = r.name;
        $("#file-modal-meta").textContent =
            `${humanSize(r.size)} — ${new Date(r.mtime * 1000).toLocaleString()} — ${path}`;
        $("#file-modal-content").innerHTML = "";
        // Coloriser ligne par ligne
        r.content.split("\n").forEach((line) => {
            appendLine($("#file-modal-content"), line, classifyLine(line));
        });
        $("#file-modal").hidden = false;
    } catch (e) {
        alert("Erreur : " + e.message);
    }
}

// ─── Tools status view ─────────────────────────────────────────────────

function renderToolsStatus() {
    const container = $("#tools-status");
    container.innerHTML = "";
    if (!STATUS) return;
    const entries = Object.entries(STATUS.tools).sort((a, b) => a[0].localeCompare(b[0]));
    entries.forEach(([tool, available]) => {
        const div = document.createElement("div");
        div.className = `tool-status ${available ? "ok" : "ko"}`;
        div.innerHTML = `<span>${available ? "✓" : "✗"}</span> ${tool}`;
        container.appendChild(div);
    });
}
