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
    setupDashboard();

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
        el.addEventListener("click", () => {
            switchView(el.dataset.view);
            closeSidebar();
        });
    });
    setupSidebarDrawer();
}

function setupSidebarDrawer() {
    const sbo = document.getElementById("sbo");
    const backdrop = document.getElementById("sidebar-backdrop");
    const toggle = document.getElementById("sidebar-toggle");
    if (!sbo || !backdrop || !toggle) return;
    toggle.addEventListener("click", () => {
        sbo.classList.toggle("open");
        backdrop.classList.toggle("open");
    });
    backdrop.addEventListener("click", closeSidebar);
}

function closeSidebar() {
    document.getElementById("sbo")?.classList.remove("open");
    document.getElementById("sidebar-backdrop")?.classList.remove("open");
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
    $("#stat-nmap").textContent    = STATUS.counts.nmap;
    $("#stat-recon").textContent   = STATUS.counts.recon;
    $("#stat-web").textContent     = STATUS.counts.web;
    $("#stat-ad").textContent      = STATUS.counts.ad;
    $("#stat-reports").textContent = STATUS.counts.reports;
}

// ─── Dashboard jobs registry ───────────────────────────────────────────

const ACTIVE_JOBS = new Map(); // id → { label, module, target, startMs, el }
let JOB_COUNTER = 0;

function addDashJob(label, module = "scan", target = "") {
    const id = ++JOB_COUNTER;
    const startMs = Date.now();
    const container = $("#dash-jobs-list");
    container.querySelector(".dsh-job-empty")?.remove();

    const el = document.createElement("div");
    el.className = "dsh-job";
    el.dataset.jobId = id;
    el.innerHTML = `
        <div class="dsh-job-r1">
            <span class="dsh-job-dot"></span>
            <span class="dsh-job-cmd">${escHtml(label)}</span>
            <button class="dsh-job-stop" data-stop="${id}">STOP</button>
        </div>
        <div class="dsh-job-meta">
            <span>module · <span class="dsh-job-meta-tag">${escHtml(module)}</span></span>
            <span>cible · <span class="dsh-job-meta-tag">${escHtml(target || "—")}</span></span>
            <span>durée · <span class="dsh-job-meta-tag dsh-elapsed">0s</span></span>
        </div>
        <div class="dsh-job-bar-wrap">
            <div class="dsh-job-bar"><div class="dsh-job-bar-fill" style="width:2%"></div></div>
            <div class="dsh-job-pct dsh-pct">—</div>
        </div>`;
    container.appendChild(el);
    el.querySelector(`[data-stop="${id}"]`).addEventListener("click", () => removeDashJob(id));

    const timer = setInterval(() => {
        const s = Math.floor((Date.now() - startMs) / 1000);
        const eEl = el.querySelector(".dsh-elapsed");
        if (eEl) eEl.textContent = s < 60 ? `${s}s` : `${Math.floor(s/60)}m${s%60}s`;
        const fill = el.querySelector(".dsh-job-bar-fill");
        if (fill) fill.style.width = Math.min(90, 2 + s * 0.6) + "%";
    }, 1000);

    ACTIVE_JOBS.set(id, { label, module, target, startMs, el, timer });
    updateJobCount();
    return id;
}

function removeDashJob(id) {
    const job = ACTIVE_JOBS.get(id);
    if (!job) return;
    clearInterval(job.timer);
    job.el.remove();
    ACTIVE_JOBS.delete(id);
    if (ACTIVE_JOBS.size === 0) {
        const container = $("#dash-jobs-list");
        if (!container.querySelector(".dsh-job-empty")) {
            container.innerHTML = '<div class="dsh-job-empty">Aucun job actif.<br><span class="k">Lance un scan depuis un module.</span></div>';
        }
    }
    updateJobCount();
}

function updateJobCount() {
    const n = ACTIVE_JOBS.size;
    const el = $("#dash-jobs-count");
    if (el) el.textContent = `${n} actif`;
    updateNavBadges();
}

function updateNavBadges() {
    const counts = { recon: 0, scan: 0, web: 0, ad: 0 };
    for (const job of ACTIVE_JOBS.values()) {
        if (counts.hasOwnProperty(job.module)) counts[job.module]++;
    }
    $$(".sbo-item-badge[data-badge]").forEach((b) => {
        const n = counts[b.dataset.badge] || 0;
        if (n > 0) { b.textContent = String(n); b.hidden = false; }
        else { b.hidden = true; }
    });
}

function escHtml(s) {
    return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

// ─── Dashboard target chip ─────────────────────────────────────────────

function setupDashboard() {
    const display = $("#dash-target-display");
    const input   = $("#dash-target-input");
    const editBtn = $("#dash-target-edit-btn");

    function startEdit() {
        input.value = display.textContent === "—" ? "" : display.textContent;
        display.style.display = "none";
        input.style.display = "block";
        input.focus();
    }
    function commitEdit() {
        const v = input.value.trim();
        if (v) display.textContent = v;
        display.style.display = "";
        input.style.display = "none";
    }
    editBtn?.addEventListener("click", () => {
        if (input.style.display === "block") commitEdit(); else startEdit();
    });
    input?.addEventListener("blur", commitEdit);
    input?.addEventListener("keydown", (e) => { if (e.key === "Enter") commitEdit(); if (e.key === "Escape") { input.style.display = "none"; display.style.display = ""; } });

    // Quick launch rows → navigate to module
    $$(".dsh-launch-row").forEach(row => {
        row.addEventListener("click", () => switchView(row.dataset.nav));
    });

    // Recent "Tout voir" → go to results
    $("#dash-recent-all")?.addEventListener("click", (e) => { e.preventDefault(); switchView("results"); });
}

async function refreshRecent() {
    const tbody = $("#dash-recent-tbody");
    if (!tbody) return;
    const moduleColor = { nmap: "#00d4ff", recon: "#9b87ff", web: "#3ade7e", ad: "#ffb86b" };
    const moduleLabel = { nmap: "SCAN", recon: "RECON", web: "WEB", ad: "AD" };
    const cats = ["nmap", "recon", "web", "ad"];
    let all = [];
    for (const c of cats) {
        try {
            const r = await api(`/api/files?category=${c}`);
            r.files.slice(0, 4).forEach((f) => all.push({ ...f, category: c }));
        } catch {}
    }
    all.sort((a, b) => b.mtime - a.mtime);
    if (all.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="dsh-tbl-empty">Aucun scan pour le moment.</td></tr>';
        return;
    }
    tbody.innerHTML = "";
    all.slice(0, 10).forEach((f) => {
        const age = formatAge(f.mtime);
        const size = formatSize(f.size);
        const col = moduleColor[f.category] || "#a8a8b4";
        const lbl = moduleLabel[f.category] || f.category.toUpperCase();
        const target = f.name.replace(/\.[^.]+$/, "").replace(/_/g, " ");
        const tr = document.createElement("tr");
        tr.innerHTML = `
            <td><div class="dsh-tbl-name">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 1.5 H10 L13 4.5 V14.5 H3 Z"/><path d="M10 1.5 V4.5 H13"/><line x1="5" y1="8" x2="11" y2="8"/><line x1="5" y1="10.5" x2="11" y2="10.5"/></svg>
                ${escHtml(f.name)}
            </div></td>
            <td><span class="dsh-tag" style="color:${col}">${lbl}</span></td>
            <td class="dsh-tbl-target">${escHtml(target)}</td>
            <td class="dsh-tbl-size">${size}</td>
            <td class="dsh-tbl-when">${age}</td>
            <td class="dsh-tbl-action">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M9 2 H14 V7"/><line x1="14" y1="2" x2="8" y2="8"/><path d="M14 9.5 V13.5 H2.5 V2 H6.5"/></svg>
            </td>`;
        tr.addEventListener("click", () => navigateToFile(f.category, f.name));
        tbody.appendChild(tr);
    });
}

function formatAge(mtime) {
    if (!mtime) return "—";
    const d = Math.floor((Date.now() / 1000 - mtime));
    if (d < 60) return `il y a ${d}s`;
    if (d < 3600) return `il y a ${Math.floor(d/60)}min`;
    if (d < 86400) return `il y a ${Math.floor(d/3600)}h`;
    return `il y a ${Math.floor(d/86400)}j`;
}

function formatSize(bytes) {
    if (!bytes) return "—";
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes/1024).toFixed(1)} KB`;
    return `${(bytes/1048576).toFixed(1)} MB`;
}

function navigateToFile(category, name) {
    switchView("results");
    currentCategory = category;
    $$(".tab").forEach(t => t.classList.toggle("active", t.dataset.cat === category));
    setTimeout(() => loadFiles(category), 100);
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

function guessModule(tool) {
    if (!tool) return "scan";
    if (["subfinder","amass","assetfinder","dnsx","httpx","whatweb","katana","theharvester"].includes(tool)) return "recon";
    if (["ffuf","gobuster","feroxbuster","dirb","nuclei","nikto","wapiti","sqlmap","wpscan","sslscan"].includes(tool)) return "web";
    if (["smbclient","smbmap","enum4linux","nxc"].includes(tool)) return "ad";
    return "scan";
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

    const module = guessModule(tool);
    const target = params?.target || params?.domain || params?.url || "";
    const jobId = addDashJob(label, module, target);

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
            removeDashJob(jobId);
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
        removeDashJob(jobId);
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
        const btn = $("#pipeline-run");
        out.hidden = false;
        out.textContent = "Lancement du pipeline...\n";
        btn.disabled = true;
        btn.textContent = "En cours…";
        const jobId = addDashJob(`Full Recon: ${dom}`, "recon", dom);
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
            const lastEl = $("#dash-pipeline-last");
            if (lastEl) lastEl.textContent = "à l'instant";
            refreshStatus();
            refreshRecent();
        } catch (e) {
            out.textContent = "[!] Erreur : " + e.message;
        } finally {
            removeDashJob(jobId);
            btn.disabled = false;
            btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor" stroke="none"><path d="M4 2 L13 8 L4 14 Z"/></svg> Lancer';
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
