// =====================================================================
// Technology Catalogue (migration 425) -- asset makes and models
// (BRD 4.2, 4.3, 4.6, 4.8) and, from migration 426, firmware products,
// releases and compatibility (BRD 4.4); from 427, operating systems
// (BRD 4.5) on the same product / release / compatibility dialogs (KIND
// below says what differs). Loaded by asset-tech-catalog.cshtml.
// Every rule (duplicates, date sequence, reason for milestone overwrite,
// identity lock after approval, source evidence to submit, segregation
// of duties, shared-catalogue scope, concurrency) is enforced by the
// procedures; this screen only mirrors them and shows their messages.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/tech-catalog";
  const root = document.getElementById("atcRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const PLATFORM = root.dataset.platformAdmin === "1";

  const LIFECYCLE = {
    PLANNED:         { label: "Planned",         cls: "atc-plain" },
    CURRENT:         { label: "Current",         cls: "atc-ok" },
    LEGACY:          { label: "Legacy",          cls: "atc-warn" },
    APPROACHING_EOS: { label: "Approaching EOS", cls: "atc-warn" },
    UNSUPPORTED:     { label: "Unsupported",     cls: "atc-bad" },
    RETIRED:         { label: "Retired",         cls: "atc-muted" }
  };
  const APPROVAL = {
    DRAFT:            { label: "Draft",            cls: "atc-plain" },
    PENDING_APPROVAL: { label: "Pending Approval", cls: "atc-warn" },
    APPROVED:         { label: "Approved",         cls: "atc-ok" },
    WITHDRAWN:        { label: "Withdrawn",        cls: "atc-muted" }
  };
  const FW_STATUS = {
    DRAFT:       { label: "Draft",       cls: "atc-plain" },
    APPROVED:    { label: "Approved",    cls: "atc-info" },
    RECOMMENDED: { label: "Recommended", cls: "atc-ok" },
    SUPPORTED:   { label: "Supported",   cls: "atc-ok" },
    DEPRECATED:  { label: "Deprecated",  cls: "atc-warn" },
    EOS:         { label: "EOS",         cls: "atc-bad" },
    EOL:         { label: "EOL",         cls: "atc-bad" },
    WITHDRAWN:   { label: "Withdrawn",   cls: "atc-muted" }
  };
  // Status moves the 426 rules allow from each status (reason-required ones flagged).
  const FW_NEXT = {
    DRAFT:       [["APPROVED", 0], ["WITHDRAWN", 1]],
    APPROVED:    [["RECOMMENDED", 0], ["SUPPORTED", 0], ["DEPRECATED", 0], ["EOS", 0], ["EOL", 0], ["WITHDRAWN", 1]],
    RECOMMENDED: [["SUPPORTED", 0], ["DEPRECATED", 0], ["EOS", 0], ["EOL", 0], ["WITHDRAWN", 1]],
    SUPPORTED:   [["RECOMMENDED", 0], ["DEPRECATED", 0], ["EOS", 0], ["EOL", 0], ["WITHDRAWN", 1]],
    DEPRECATED:  [["EOS", 0], ["EOL", 0], ["WITHDRAWN", 1]],
    EOS:         [["EOL", 0], ["WITHDRAWN", 1]],
    EOL:         [["WITHDRAWN", 1]],
    WITHDRAWN:   [["DRAFT", 1]]
  };
  const COMPAT = {
    CERTIFIED:   { label: "Certified",   cls: "atc-ok" },
    SUPPORTED:   { label: "Supported",   cls: "atc-ok" },
    CONDITIONAL: { label: "Conditional", cls: "atc-warn" },
    UNSUPPORTED: { label: "Unsupported", cls: "atc-bad" },
    UNKNOWN:     { label: "Unknown",     cls: "atc-plain" }
  };
  const OS_STATUS = {
    DRAFT:            { label: "Draft",            cls: "atc-plain" },
    APPROVED:         { label: "Approved",         cls: "atc-info" },
    SUPPORTED:        { label: "Supported",        cls: "atc-ok" },
    EXTENDED_SUPPORT: { label: "Extended Support", cls: "atc-warn" },
    APPROACHING_EOS:  { label: "Approaching EOS",  cls: "atc-warn" },
    EOS:              { label: "EOS",              cls: "atc-bad" },
    UNSUPPORTED:      { label: "Unsupported",      cls: "atc-bad" }
  };
  // Status moves the 427 rules allow (reason-required ones flagged).
  const OS_NEXT = {
    DRAFT:            [["APPROVED", 0]],
    APPROVED:         [["SUPPORTED", 0], ["EXTENDED_SUPPORT", 0], ["APPROACHING_EOS", 0], ["EOS", 0], ["UNSUPPORTED", 0]],
    SUPPORTED:        [["EXTENDED_SUPPORT", 0], ["APPROACHING_EOS", 0], ["EOS", 0], ["UNSUPPORTED", 0]],
    EXTENDED_SUPPORT: [["APPROACHING_EOS", 0], ["EOS", 0], ["UNSUPPORTED", 0]],
    APPROACHING_EOS:  [["EXTENDED_SUPPORT", 1], ["EOS", 0], ["UNSUPPORTED", 0]],
    EOS:              [["UNSUPPORTED", 0]],
    UNSUPPORTED:      []
  };
  // What differs between the firmware (426) and operating-system (427) catalogues.
  const KIND = {
    fw: {
      path: "/firmware", noun: "firmware", STATUS: null, NEXT: null,
      productFilter: "atcFwProductFilter", statusFilter: "atcFwStatusFilter", productBody: "atcProductBody", releaseBody: "atcReleaseBody",
      locked: "product, version, build, branch and edition", endDates: ["atcFrEng", "atcFrStd", "atcFrSec", "atcFrEol"]
    },
    os: {
      path: "/os", noun: "operating-system", STATUS: null, NEXT: null,
      productFilter: "atcOsProductFilter", statusFilter: "atcOsStatusFilter", productBody: "atcOsProductBody", releaseBody: "atcOsReleaseBody",
      locked: "product, edition, version, build and architecture", endDates: ["atcFrMain", "atcFrExt", "atcFrSecUpd", "atcFrEol"]
    }
  };
  const MILESTONE = {
    ANNOUNCEMENT_DATE: "Announcement", RELEASE_DATE: "Release", END_OF_SALE_DATE: "End of sale",
    END_STANDARD_SUPPORT: "End of standard support", END_SECURITY_SUPPORT: "End of security support",
    END_EXTENDED_SUPPORT: "End of extended support", END_OF_LIFE_DATE: "End of life", LIFECYCLE_STATUS: "Lifecycle status",
    END_ENGINEERING_SUPPORT: "Engineering support end", END_SECURITY_FIX: "Security fix end",
    END_MAINSTREAM_SUPPORT: "Mainstream support end", END_SECURITY_UPDATES: "Security update end"
  };
  KIND.fw.STATUS = FW_STATUS; KIND.fw.NEXT = FW_NEXT;
  KIND.os.STATUS = OS_STATUS; KIND.os.NEXT = OS_NEXT;

  // kind = "fw" | "os": which catalogue the open product / release / compatibility dialog belongs to.
  const state = { organizationId: null, data: null, fw: null, os: null, make: null, model: null, kind: "fw", product: null, release: null, compat: null };
  const canChange = row => CAN_EDIT && (!row || !row.isShared || PLATFORM);

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    bind();
    document.getElementById("atcModelLifeFilter").innerHTML = `<option value="">All lifecycle statuses</option>`
      + Object.entries(LIFECYCLE).map(([k, v]) => `<option value="${k}">${v.label}</option>`).join("");
    Object.values(KIND).forEach(k => {
      document.getElementById(k.statusFilter).innerHTML = `<option value="">All statuses</option>`
        + Object.entries(k.STATUS).map(([c, v]) => `<option value="${c}">${v.label}</option>`).join("");
    });
    await populateOrgs();
    const sel = document.getElementById("atcOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.organizationId = Number(sel.value) || null;
    await load();
  }

  async function populateOrgs() {
    const sel = document.getElementById("atcOrg");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        if (!value) return;
        const o = document.createElement("option");
        o.value = value; o.textContent = String(row.organizationName ?? row.OrganizationName ?? value);
        sel.appendChild(o);
      });
    } catch (_) { /* placeholder stays */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bind() {
    document.getElementById("atcOrg").addEventListener("change", e => { state.organizationId = Number(e.target.value) || null; load(); });
    document.getElementById("atcRefresh").addEventListener("click", () => load());
    let t = null;
    document.getElementById("atcSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(render, 250); });
    ["atcModelMakeFilter", "atcModelLifeFilter", "atcModelApprovalFilter"].forEach(id => document.getElementById(id).addEventListener("change", render));
    document.querySelectorAll("[data-atc-tab]").forEach(b => b.addEventListener("click", () => selectTab("atc-tab", b.dataset.atcTab, "atc-panel")));
    document.querySelectorAll("[data-atc-mtab]").forEach(b => b.addEventListener("click", () => selectTab("atc-mtab", b.dataset.atcMtab, "atc-mpanel")));
    document.querySelectorAll("[data-atc-rtab]").forEach(b => b.addEventListener("click", () => selectTab("atc-rtab", b.dataset.atcRtab, "atc-rpanel")));
    Object.entries(KIND).forEach(([kind, k]) => {
      [k.productFilter, k.statusFilter].forEach(id => document.getElementById(id).addEventListener("change", render));
      document.getElementById(k.productBody).addEventListener("click", ev => {
        const b = ev.target.closest("[data-atc-product]");
        if (b) openProduct(kind, state[kind].products.find(p => p.productId === Number(b.dataset.atcProduct)));
      });
      document.getElementById(k.releaseBody).addEventListener("click", ev => {
        const tr = ev.target.closest("tr[data-atc-release]");
        if (tr) openRelease(kind, Number(tr.dataset.atcRelease));
      });
    });
    document.getElementById("atcAddProduct")?.addEventListener("click", () => openProduct("fw", null));
    document.getElementById("atcAddRelease")?.addEventListener("click", () => openRelease("fw", null));
    document.getElementById("atcAddOsProduct")?.addEventListener("click", () => openProduct("os", null));
    document.getElementById("atcAddOsRelease")?.addEventListener("click", () => openRelease("os", null));
    document.getElementById("atcProductForm").addEventListener("submit", saveProduct);
    document.getElementById("atcReleaseForm").addEventListener("submit", saveRelease);
    document.getElementById("atcCompatForm").addEventListener("submit", saveCompat);
    document.getElementById("atcAddCompat").addEventListener("click", () => openCompat(null));
    document.getElementById("atcCompatBody").addEventListener("click", onCompatAction);
    document.getElementById("atcFcType").addEventListener("change", () => fillCompatPickers(null, false));
    document.getElementById("atcFcMake").addEventListener("change", () => fillCompatModels(null));
    document.getElementById("atcAddMake")?.addEventListener("click", () => openMake(null));
    document.getElementById("atcAddModel")?.addEventListener("click", () => openModel(null));
    document.getElementById("atcMakeBody").addEventListener("click", ev => {
      const b = ev.target.closest("[data-atc-make]");
      if (b) openMake(state.data.makes.find(m => m.makeId === Number(b.dataset.atcMake)));
    });
    document.getElementById("atcModelBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-atc-model]");
      if (tr) openModel(Number(tr.dataset.atcModel));
    });
    document.getElementById("atcMakeForm").addEventListener("submit", saveMake);
    document.getElementById("atcModelForm").addEventListener("submit", saveModel);
    document.getElementById("atcMdMake").addEventListener("change", () => fillModelTypes(null));
    document.querySelectorAll("[data-close-atc]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAtc).hidden = true; }));
    document.addEventListener("keydown", ev => {
      if (ev.key !== "Escape") return;
      // Close the top-most modal only (compatibility sits above the release modal).
      const open = ["atcCompatModal", "atcProductModal", "atcReleaseModal", "atcMakeModal", "atcModelModal"].find(id => !document.getElementById(id).hidden);
      if (open) document.getElementById(open).hidden = true;
    });
  }

  function selectTab(attr, tab, panelAttr) {
    document.querySelectorAll(`[data-${attr}]`).forEach(b => {
      const on = b.getAttribute(`data-${attr}`) === tab; b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll(`[data-${panelAttr}]`).forEach(p => { p.hidden = p.getAttribute(`data-${panelAttr}`) !== tab; });
  }

  // ------------------------------------------------------------------ load + render
  async function load(message) {
    const mk = document.getElementById("atcMakeBody"), md = document.getElementById("atcModelBody");
    if (!state.organizationId) { mk.innerHTML = md.innerHTML = empty(9, "Select an organization."); return; }
    mk.innerHTML = md.innerHTML = empty(9, "Loading...");
    const [res, fw, os] = await Promise.all([
      api("GET", `?organizationId=${state.organizationId}`),
      api("GET", `/firmware?organizationId=${state.organizationId}`),
      api("GET", `/os?organizationId=${state.organizationId}`)
    ]);
    if (!res.ok) { mk.innerHTML = md.innerHTML = empty(9, res.error); return; }
    state.data = res.data.data;
    state.fw = fw.ok ? fw.data.data : { products: [], releases: [], error: fw.error };
    state.os = os.ok ? os.data.data : { products: [], releases: [], error: os.error };
    Object.entries(KIND).forEach(([kind, k]) => {
      const pf = document.getElementById(k.productFilter), pkeep = pf.value;
      pf.innerHTML = `<option value="">All products</option>` + state[kind].products.map(p => `<option value="${p.productId}">${esc(productLabel(p))}</option>`).join("");
      pf.value = state[kind].products.some(p => String(p.productId) === pkeep) ? pkeep : "";
    });
    const f = document.getElementById("atcModelMakeFilter"), keep = f.value;
    f.innerHTML = `<option value="">All makes</option>` + state.data.makes.map(m => `<option value="${m.makeId}">${esc(m.makeName)}</option>`).join("");
    f.value = state.data.makes.some(m => String(m.makeId) === keep) ? keep : "";
    render();
    if (message) showMessage(message, "success");
  }

  function render() {
    const d = state.data;
    if (!d) return;
    const q = val("atcSearch").toLowerCase();
    const hit = (...xs) => !q || xs.some(x => String(x || "").toLowerCase().includes(q));
    document.getElementById("atcMakeBody").innerHTML = d.makes.filter(m => hit(m.makeName, m.legalName, m.aliases)).map(m => `
      <tr>
        <td>${esc(m.makeName)}${m.aliases ? `<div class="atc-code">${esc(m.aliases)}</div>` : ""}</td>
        <td>${esc(m.legalName || "--")}</td>
        <td>${scopeChip(m.isShared)}</td>
        <td>${esc(m.assetTypeIds ? String(m.assetTypeIds).split(",").length : 0)}</td>
        <td>${esc(m.modelCount)}</td>
        <td>${esc(m.verifiedDate ? fmtDate(m.verifiedDate) + (m.verifiedBy ? " - " + m.verifiedBy : "") : "--")}</td>
        <td>v${esc(m.versionNo)}</td>
        <td><span class="atc-chip ${m.status === "Active" ? "atc-ok" : "atc-muted"}">${esc(m.status)}</span></td>
        <td><button type="button" class="pm-button icon" data-atc-make="${m.makeId}" title="${canChange(m) ? "Edit" : "View"}" aria-label="${canChange(m) ? "Edit" : "View"}"><i class="fa-solid ${canChange(m) ? "fa-pen" : "fa-eye"}"></i></button></td>
      </tr>`).join("") || empty(9, "No makes yet.");

    const fm = val("atcModelMakeFilter"), fl = val("atcModelLifeFilter"), fa = val("atcModelApprovalFilter");
    document.getElementById("atcModelBody").innerHTML = d.models
      .filter(m => (!fm || String(m.makeId) === fm) && (!fl || m.lifecycleStatus === fl) && (!fa || m.statusCode === fa)
        && hit(m.modelName, m.modelNumber, m.makeName, m.variant)).map(m => `
      <tr class="pm-row-clickable" data-atc-model="${m.modelId}">
        <td>${esc(m.modelName)}${m.variant ? " " + esc(m.variant) : ""}<div class="atc-code">${esc(m.modelNumber || m.modelCode)}${m.hardwareRevision ? " rev " + esc(m.hardwareRevision) : ""}</div></td>
        <td>${esc(m.makeName)}</td>
        <td>${esc(m.assetTypeName)}</td>
        <td>${chip(LIFECYCLE, m.lifecycleStatus)}</td>
        <td>${esc(fmtDate(m.releaseDate) || "--")}</td>
        <td>${esc(fmtDate(m.endStandardSupportDate) || "--")}</td>
        <td>${esc(fmtDate(m.endOfLifeDate) || "--")}</td>
        <td>${chip(APPROVAL, m.statusCode)}</td>
        <td>${scopeChip(m.isShared)}</td>
      </tr>`).join("") || empty(9, "No models match.");

    Object.keys(KIND).forEach(kind => renderCatalog(kind, hit));
  }

  // Products + releases of one catalogue (firmware or operating systems).
  function renderCatalog(kind, hit) {
    const k = KIND[kind], cat = state[kind] || { products: [], releases: [] };
    document.getElementById(k.productBody).innerHTML = cat.error ? empty(6, cat.error) : cat.products.filter(p => hit(p.productName, p.publisherName, p.family)).map(p => `
      <tr>
        <td>${esc((p.family ? p.family + " / " : "") + p.productName)}<div class="atc-code">${esc(p.productCode)}</div></td>
        <td>${esc(p.publisherName)}</td>
        <td>${esc(p.releaseCount)}</td>
        <td>${scopeChip(p.isShared)}</td>
        <td><span class="atc-chip ${p.status === "Active" ? "atc-ok" : "atc-muted"}">${esc(p.status)}</span></td>
        <td><button type="button" class="pm-button icon" data-atc-product="${p.productId}" title="${canChange(p) ? "Edit" : "View"}" aria-label="${canChange(p) ? "Edit" : "View"}"><i class="fa-solid ${canChange(p) ? "fa-pen" : "fa-eye"}"></i></button></td>
      </tr>`).join("") || empty(6, `No ${k.noun} products yet.`);
    const fp = val(k.productFilter), fs = val(k.statusFilter);
    const rows = cat.releases.filter(r => (!fp || String(r.productId) === fp) && (!fs || r.statusCode === fs)
      && hit(r.version, r.productName, r.publisherName, r.build, r.edition));
    const compat = r => `${esc(r.approvedCompatCount)} approved / ${esc(r.compatCount)}`;
    document.getElementById(k.releaseBody).innerHTML = rows.map(r => kind === "fw" ? `
      <tr class="pm-row-clickable" data-atc-release="${r.releaseId}">
        <td>${esc(r.version)}${r.build ? " build " + esc(r.build) : ""}<div class="atc-code">${esc([r.branchTrain, r.edition].filter(Boolean).join(" / ") || r.releaseCode)}</div></td>
        <td>${esc(r.publisherName + " " + r.productName)}</td>
        <td>${esc(fmtDate(r.releaseDate) || "--")}</td>
        <td>${esc(fmtDate(r.standardSupportEndDate) || "--")}</td>
        <td>${esc(fmtDate(r.endOfLifeDate) || "--")}</td>
        <td>${esc(r.upgradeUrgency || "--")}</td>
        <td>${compat(r)}</td>
        <td>${chip(k.STATUS, r.statusCode)}</td>
        <td>${scopeChip(r.isShared)}</td>
      </tr>` : `
      <tr class="pm-row-clickable" data-atc-release="${r.releaseId}">
        <td>${esc([r.edition, r.version].filter(Boolean).join(" "))}${r.build ? " build " + esc(r.build) : ""}<div class="atc-code">${esc(r.architecture || r.releaseCode)}</div></td>
        <td>${esc(r.publisherName + " " + r.productName)}</td>
        <td>${esc(fmtDate(r.releaseDate) || "--")}</td>
        <td>${esc(fmtDate(r.mainstreamSupportEndDate) || "--")}</td>
        <td>${esc(fmtDate(r.extendedSupportEndDate) || "--")}</td>
        <td>${esc(fmtDate(r.endOfLifeDate) || "--")}</td>
        <td>${r.isApprovedBaseline ? `<span class="atc-chip atc-ok">Baseline</span>` : "--"}</td>
        <td>${compat(r)}</td>
        <td>${chip(k.STATUS, r.statusCode)}</td>
        <td>${scopeChip(r.isShared)}</td>
      </tr>`).join("") || empty(10, `No ${k.noun} releases match.`);
  }

  // ------------------------------------------------------------------ makes
  function openMake(row) {
    state.make = row;
    const editable = canChange(row);
    document.getElementById("atcMakeTitle").textContent = row ? (editable ? `Edit make: ${row.makeName}` : row.makeName) : "Add make";
    const v = (id, x) => setVal(id, x ?? "");
    v("atcMkName", row?.makeName); v("atcMkLegal", row?.legalName); v("atcMkAliases", row?.aliases);
    v("atcMkPortal", row?.supportPortalUrl); v("atcMkAdvisory", row?.securityAdvisoryUrl); v("atcMkContact", row?.supportContact);
    v("atcMkRegion", row?.supportRegion); v("atcMkOwner", row?.ownerName); v("atcMkSource", row?.authoritativeSource);
    v("atcMkVerified", isoDate(row?.verifiedDate)); v("atcMkVerifier", row?.verifiedBy); v("atcMkEffective", isoDate(row?.effectiveDate));
    v("atcMkStatus", row?.status || "Active");
    const chosen = new Set(String(row?.assetTypeIds || "").split(",").filter(Boolean));
    document.getElementById("atcMkTypes").innerHTML = state.data.assetTypes.map(t =>
      `<option value="${t.assetTypeId}"${chosen.has(String(t.assetTypeId)) ? " selected" : ""}>${esc(t.path + " / " + t.assetTypeName)}</option>`).join("");
    document.getElementById("atcMkSharedWrap").hidden = !(PLATFORM && !row);
    document.getElementById("atcMkShared").checked = false;
    document.getElementById("atcMkMeta").textContent = row ? `Code ${row.makeCode} - version ${row.versionNo} - ${row.isShared ? "shared catalogue" : "this organization"}` : "";
    document.querySelectorAll("#atcMakeForm input, #atcMakeForm select").forEach(el => { el.disabled = !editable; });
    document.getElementById("atcMakeSave").hidden = !editable;
    modalMessage("atcMakeMessage", "");
    document.getElementById("atcMakeModal").hidden = false;
  }

  async function saveMake(ev) {
    ev.preventDefault();
    const row = state.make;
    if (!canChange(row)) return;
    const name = val("atcMkName");
    if (!name) { modalMessage("atcMakeMessage", "The make name is required."); return; }
    const res = await api("POST", "/makes", {
      organizationId: state.organizationId,
      shared: row ? !!row.isShared : (PLATFORM && document.getElementById("atcMkShared").checked),
      makeId: row ? row.makeId : null, makeName: name,
      legalName: val("atcMkLegal") || null, aliases: val("atcMkAliases") || null,
      supportPortalUrl: val("atcMkPortal") || null, securityAdvisoryUrl: val("atcMkAdvisory") || null,
      supportContact: val("atcMkContact") || null, supportRegion: val("atcMkRegion") || null,
      ownerName: val("atcMkOwner") || null, authoritativeSource: val("atcMkSource") || null,
      verifiedDate: val("atcMkVerified") || null, verifiedBy: val("atcMkVerifier") || null,
      effectiveDate: val("atcMkEffective") || null, status: val("atcMkStatus"),
      assetTypeIds: Array.from(document.getElementById("atcMkTypes").selectedOptions).map(o => Number(o.value)),
      expectedRecordVersion: row ? row.recordVersion : null
    });
    if (!res.ok) { modalMessage("atcMakeMessage", res.error); if (res.status === 409) await load(); return; }
    document.getElementById("atcMakeModal").hidden = true;
    await load(`Make "${name}" saved.`);
  }

  // ------------------------------------------------------------------ models
  async function openModel(id) {
    let detail = null;
    if (id) {
      const res = await api("GET", `/models/${id}?organizationId=${state.organizationId}`);
      if (!res.ok) { showMessage(res.error, "error"); return; }
      detail = res.data.data;
    }
    state.model = detail;
    const m = detail?.model || null;
    const editable = canChange(m);
    const approved = m?.statusCode === "APPROVED";
    document.getElementById("atcModelTitle").textContent = m ? `${m.makeName} ${m.modelName}${m.variant ? " " + m.variant : ""}` : "Add model";
    document.getElementById("atcMdMeta").innerHTML = m
      ? `${chip(APPROVAL, m.statusCode)} ${scopeChip(m.isShared)} <span class="atc-code">${esc(m.modelCode)}</span>${approved ? " - identity fields are locked once approved." : ""}`
      : "New models start as Draft. Add the source reference, then submit for approval.";
    const makes = state.data.makes.filter(k => k.status === "Active" || k.makeId === m?.makeId);
    document.getElementById("atcMdMake").innerHTML = `<option value="">Select</option>` + makes.map(k => `<option value="${k.makeId}">${esc(k.makeName)}${k.isShared ? "" : " (organization)"}</option>`).join("");
    setVal("atcMdMake", m?.makeId ?? "");
    fillModelTypes(m);
    document.getElementById("atcMdLife").innerHTML = Object.entries(LIFECYCLE).map(([k, v]) => `<option value="${k}">${v.label}</option>`).join("");
    document.getElementById("atcMdCrit").innerHTML = `<option value="">None</option>` + state.data.criticality.map(c => `<option value="${c.criticalityId}">${esc(c.criticalityName)}</option>`).join("");
    const v = (elId, x) => setVal(elId, x ?? "");
    v("atcMdName", m?.modelName); v("atcMdNumber", m?.modelNumber); v("atcMdFamily", m?.familySeries); v("atcMdVariant", m?.variant);
    v("atcMdSku", m?.sku); v("atcMdLife", m?.lifecycleStatus || "CURRENT");
    v("atcMdAnnounce", isoDate(m?.announcementDate)); v("atcMdRelease", isoDate(m?.releaseDate)); v("atcMdEos", isoDate(m?.endOfSaleDate));
    v("atcMdEss", isoDate(m?.endStandardSupportDate)); v("atcMdSec", isoDate(m?.endSecuritySupportDate));
    v("atcMdExt", isoDate(m?.endExtendedSupportDate)); v("atcMdEol", isoDate(m?.endOfLifeDate));
    v("atcMdArch", m?.architecture); v("atcMdHw", m?.hardwareRevision); v("atcMdSpecs", m?.specifications);
    v("atcMdSource", m?.sourceReference); v("atcMdVerified", isoDate(m?.verifiedDate)); v("atcMdVerifier", m?.verifiedBy);
    v("atcMdCrit", m?.criticalityId); v("atcMdLead", m?.replacementLeadTimeDays); v("atcMdRisk", m?.lifecycleRisk);
    v("atcMdControls", m?.controls); v("atcMdReason", "");
    document.getElementById("atcMdReasonWrap").hidden = !m;
    document.getElementById("atcMdSharedWrap").hidden = !(PLATFORM && !m);
    document.getElementById("atcMdShared").checked = false;
    document.querySelectorAll("#atcModelForm input, #atcModelForm select, #atcModelForm textarea").forEach(el => {
      el.disabled = !editable || (approved && el.hasAttribute("data-identity"));
    });
    document.getElementById("atcModelSave").hidden = !editable;
    renderModelActions(m);
    document.getElementById("atcMdEvents").innerHTML = (detail?.lifecycleEvents || []).map(e => `
      <tr><td>${esc(dateTime(e.enteredDt))}</td><td>${esc(MILESTONE[e.milestoneCode] || e.milestoneCode)}</td>
          <td>${esc(labelFor(e.milestoneCode, e.beforeValue))}</td><td>${esc(labelFor(e.milestoneCode, e.afterValue))}</td>
          <td>${esc(e.reason || "")}</td><td>${esc(e.enteredBy || "")}</td></tr>`).join("") || empty(6, "No lifecycle changes recorded.");
    document.getElementById("atcMdHistory").innerHTML = (detail?.history || []).map(x => `
      <tr><td>${esc(dateTime(x.transitionedAt))}</td><td>${esc(x.fromStatus || "--")}</td><td>${esc(x.toStatus)}</td>
          <td>${esc(x.actorName || (x.actorEmployeeId ? "Employee #" + x.actorEmployeeId : "System"))}</td>
          <td>${esc(x.reasonText || x.reasonCode || "")}</td></tr>`).join("") || empty(5, "No history.");
    const fwBody = document.getElementById("atcMdFirmware"), osBody = document.getElementById("atcMdOs");
    fwBody.innerHTML = empty(7, m ? "Loading..." : "Save the model first.");
    osBody.innerHTML = empty(8, m ? "Loading..." : "Save the model first.");
    modalMessage("atcModelMessage", "");
    selectTab("atc-mtab", "details", "atc-mpanel");
    document.getElementById("atcModelModal").hidden = false;
    if (m) {
      const fr = await api("GET", `/models/${m.modelId}/firmware?organizationId=${state.organizationId}`);
      fwBody.innerHTML = !fr.ok ? empty(7, fr.error) : (fr.data.data || []).map(f => `
        <tr><td>${esc(f.publisherName + " " + f.productName + " " + f.version)}${f.build ? " build " + esc(f.build) : ""}</td>
            <td>${chip(FW_STATUS, f.releaseStatusCode)}</td><td>${chip(COMPAT, f.compatStatus)}</td>
            <td>${esc(matchLabel(f.matchLevel))}</td>
            <td>${f.hardwareRevisionMatch ? esc(f.hardwareRevision || "Any") : `<span class="atc-chip atc-warn">Other: ${esc(f.hardwareRevision)}</span>`}</td>
            <td>${esc(f.upgradePath || "")}</td><td>${esc(fmtDate(f.endOfLifeDate) || "--")}</td></tr>`).join("") || empty(7, "No approved compatible firmware.");
      const orr = await api("GET", `/models/${m.modelId}/os?organizationId=${state.organizationId}`);
      osBody.innerHTML = !orr.ok ? empty(8, orr.error) : (orr.data.data || []).map(o => `
        <tr><td>${esc([o.publisherName, o.productName, o.edition, o.version].filter(Boolean).join(" "))}${o.build ? " build " + esc(o.build) : ""}</td>
            <td>${chip(OS_STATUS, o.releaseStatusCode)}</td><td>${o.isApprovedBaseline ? `<span class="atc-chip atc-ok">Baseline</span>` : "--"}</td>
            <td>${esc(matchLabel(o.matchLevel))}</td>
            <td>${o.architectureMatch ? esc(o.processorArchitecture || "Any") : `<span class="atc-chip atc-warn">Other: ${esc(o.processorArchitecture)}</span>`}</td>
            <td>${esc(o.minFirmwareName || "--")}</td><td>${esc(o.exclusions || "")}</td><td>${esc(fmtDate(o.endOfLifeDate) || "--")}</td></tr>`).join("") || empty(8, "No approved compatible operating systems.");
    }
  }

  // Asset types offered: the make's supported types when it lists any, else all selectable types.
  function fillModelTypes(m) {
    const make = state.data.makes.find(k => String(k.makeId) === val("atcMdMake"));
    const supported = new Set(String(make?.assetTypeIds || "").split(",").filter(Boolean));
    let types = state.data.assetTypes.filter(t => !supported.size || supported.has(String(t.assetTypeId)));
    const current = m?.assetTypeId ?? (Number(val("atcMdType")) || null);
    if (m && !types.some(t => t.assetTypeId === m.assetTypeId)) types = [{ assetTypeId: m.assetTypeId, assetTypeName: m.assetTypeName, path: "(not selectable now)" }].concat(types);
    document.getElementById("atcMdType").innerHTML = `<option value="">Select</option>` + types.map(t => `<option value="${t.assetTypeId}">${esc(t.path + " / " + t.assetTypeName)}</option>`).join("");
    setVal("atcMdType", types.some(t => t.assetTypeId === current) ? current : "");
  }

  function renderModelActions(m) {
    const host = document.getElementById("atcMdActions"), a = [];
    if (m) {
      const scopeOk = !m.isShared || PLATFORM;
      const add = (label, icon, fn, primary) => a.push({ label, icon, fn, primary });
      if (scopeOk && CAN_EDIT) {
        if (m.statusCode === "DRAFT") {
          add("Submit for Approval", "fa-paper-plane", () => transition("PENDING_APPROVAL"), true);
          add("Discard", "fa-trash-can", () => transition("WITHDRAWN", "Why is this draft being discarded?"));
        }
        if (m.statusCode === "APPROVED") add("Withdraw", "fa-ban", () => transition("WITHDRAWN", "Why is this model being withdrawn?"));
        if (m.statusCode === "WITHDRAWN") add("Reopen", "fa-rotate-left", () => transition("DRAFT", "Why is this model being reopened?"));
      }
      if (scopeOk && CAN_APPROVE && m.statusCode === "PENDING_APPROVAL") {
        add("Approve", "fa-circle-check", () => transition("APPROVED", null, "Approve this model for the catalogue?"), true);
        add("Return", "fa-rotate-left", () => transition("DRAFT", "Why is this model being returned?"));
      }
    }
    host.innerHTML = a.map((x, i) => `<button type="button" class="pm-button${x.primary ? " primary" : ""}" data-atc-act="${i}"><i class="fa-solid ${x.icon}"></i> ${esc(x.label)}</button>`).join("");
    host.querySelectorAll("[data-atc-act]").forEach(b => b.addEventListener("click", () => a[Number(b.dataset.atcAct)].fn()));
  }

  async function transition(toStatusCode, reasonQuestion, confirmQuestion) {
    const m = state.model?.model;
    if (!m) return;
    let reasonText = null;
    if (reasonQuestion) {
      reasonText = await window.gracUi.promptRequired(reasonQuestion, { title: "Reason required", inputLabel: "Reason" });
      if (reasonText === null) return;
    } else if (confirmQuestion && !await window.gracUi.confirm(confirmQuestion)) return;
    const res = await api("POST", `/models/${m.modelId}/transition`, {
      organizationId: state.organizationId, shared: !!m.isShared, toStatusCode, reasonText, expectedRecordVersion: m.recordVersion
    });
    if (!res.ok) { modalMessage("atcModelMessage", res.error); if (res.status === 409) await openModel(m.modelId); return; }
    await load(`Model moved to ${APPROVAL[toStatusCode]?.label || toStatusCode}.`);
    await openModel(m.modelId);
  }

  async function saveModel(ev) {
    ev.preventDefault();
    const m = state.model?.model || null;
    if (!canChange(m)) return;
    if (!val("atcMdMake") || !val("atcMdType") || !val("atcMdName")) { modalMessage("atcModelMessage", "Make, asset type and model name are required."); return; }
    const d = id => val(id) || null;
    const release = d("atcMdRelease");
    if (release && ["atcMdEos", "atcMdEss", "atcMdSec", "atcMdExt", "atcMdEol"].some(id => d(id) && d(id) < release)) {
      modalMessage("atcModelMessage", "End-of-sale, end-of-support and end-of-life dates cannot precede the release date."); return;
    }
    const res = await api("POST", "/models", {
      organizationId: state.organizationId,
      shared: m ? !!m.isShared : (PLATFORM && document.getElementById("atcMdShared").checked),
      modelId: m ? m.modelId : null, makeId: Number(val("atcMdMake")), assetTypeId: Number(val("atcMdType")),
      modelName: val("atcMdName"), modelNumber: d("atcMdNumber"), familySeries: d("atcMdFamily"), variant: d("atcMdVariant"),
      sku: d("atcMdSku"), announcementDate: d("atcMdAnnounce"), releaseDate: release, endOfSaleDate: d("atcMdEos"),
      endStandardSupportDate: d("atcMdEss"), endSecuritySupportDate: d("atcMdSec"), endExtendedSupportDate: d("atcMdExt"),
      endOfLifeDate: d("atcMdEol"), architecture: d("atcMdArch"), hardwareRevision: d("atcMdHw"), specifications: d("atcMdSpecs"),
      sourceReference: d("atcMdSource"), verifiedDate: d("atcMdVerified"), verifiedBy: d("atcMdVerifier"),
      criticalityId: Number(val("atcMdCrit")) || null,
      replacementLeadTimeDays: val("atcMdLead") === "" ? null : Number(val("atcMdLead")),
      lifecycleRisk: d("atcMdRisk"), controls: d("atcMdControls"), lifecycleStatus: val("atcMdLife"),
      changeReason: d("atcMdReason"), expectedRecordVersion: m ? m.recordVersion : null
    });
    if (!res.ok) { modalMessage("atcModelMessage", res.error); if (res.status === 409) await openModel(m.modelId); return; }
    await load(`Model "${val("atcMdName")}" saved.`);
    await openModel(res.data.id || (m && m.modelId));
  }

  // ------------------------------------------------------------------ products (firmware / OS)
  // Shows the dialog fields of one catalogue: data-kind="fw" or "os".
  function showKind(formId, kind) {
    document.querySelectorAll(`#${formId} [data-kind]`).forEach(el => { el.hidden = el.dataset.kind !== kind; });
  }

  function openProduct(kind, row) {
    state.kind = kind; state.product = row;
    const k = KIND[kind], editable = canChange(row);
    showKind("atcProductForm", kind);
    document.getElementById("atcProductTitle").textContent = row ? (editable ? `Edit product: ${row.productName}` : row.productName) : `Add ${k.noun} product`;
    const makes = state.data.makes.filter(x => x.status === "Active" || x.makeId === row?.publisherMakeId);
    document.getElementById("atcFpMake").innerHTML = `<option value="">Select</option>` + makes.map(x => `<option value="${x.makeId}">${esc(x.makeName)}${x.isShared ? "" : " (organization)"}</option>`).join("");
    setVal("atcFpMake", row?.publisherMakeId ?? ""); setVal("atcFpName", row?.productName ?? ""); setVal("atcFpFamily", row?.family ?? "");
    setVal("atcFpDesc", row?.description ?? ""); setVal("atcFpStatus", row?.status || "Active");
    document.getElementById("atcFpSharedWrap").hidden = !(PLATFORM && !row);
    document.getElementById("atcFpShared").checked = false;
    document.querySelectorAll("#atcProductForm input, #atcProductForm select, #atcProductForm textarea").forEach(el => { el.disabled = !editable; });
    document.getElementById("atcProductSave").hidden = !editable;
    modalMessage("atcProductMessage", "");
    document.getElementById("atcProductModal").hidden = false;
  }

  async function saveProduct(ev) {
    ev.preventDefault();
    const row = state.product, kind = state.kind;
    if (!canChange(row)) return;
    if (!val("atcFpMake") || !val("atcFpName")) { modalMessage("atcProductMessage", "Publisher and product name are required."); return; }
    const res = await api("POST", `${KIND[kind].path}/products`, {
      organizationId: state.organizationId,
      shared: row ? !!row.isShared : (PLATFORM && document.getElementById("atcFpShared").checked),
      productId: row ? row.productId : null, publisherMakeId: Number(val("atcFpMake")), productName: val("atcFpName"),
      family: kind === "os" ? (val("atcFpFamily") || null) : undefined,
      description: val("atcFpDesc") || null, status: val("atcFpStatus"), expectedRecordVersion: row ? row.recordVersion : null
    });
    if (!res.ok) { modalMessage("atcProductMessage", res.error); if (res.status === 409) await load(); return; }
    document.getElementById("atcProductModal").hidden = true;
    await load(`Product "${val("atcFpName")}" saved.`);
  }

  // ------------------------------------------------------------------ releases (firmware / OS)
  async function openRelease(kind, id) {
    const k = KIND[kind];
    let detail = null;
    if (id) {
      const res = await api("GET", `${k.path}/releases/${id}?organizationId=${state.organizationId}`);
      if (!res.ok) { showMessage(res.error, "error"); return; }
      detail = res.data.data;
    }
    const sameOpen = !document.getElementById("atcReleaseModal").hidden && state.kind === kind && detail
      && state.release?.release?.releaseId === detail.release.releaseId;
    state.kind = kind; state.release = detail;
    const r = detail?.release || null;
    const editable = canChange(r);
    const locked = r && r.statusCode !== "DRAFT";
    showKind("atcReleaseForm", kind);
    document.getElementById("atcReleaseTitle").textContent = r ? `${r.publisherName} ${r.productName} ${[r.edition, r.version].filter(Boolean).join(" ")}` : `Add ${k.noun} release`;
    document.getElementById("atcFrMeta").innerHTML = r
      ? `${chip(k.STATUS, r.statusCode)} ${scopeChip(r.isShared)} <span class="atc-code">${esc(r.releaseCode)}</span>${locked ? ` - ${k.locked} are locked once approved.` : ""}`
      : "New releases start as Draft. Add the source reference; another person approves.";
    const products = state[kind].products.filter(p => p.status === "Active" || p.productId === r?.productId);
    document.getElementById("atcFrProduct").innerHTML = `<option value="">Select</option>` + products.map(p => `<option value="${p.productId}">${esc(productLabel(p))}${p.isShared ? "" : " (organization)"}</option>`).join("");
    const v = (elId, x) => setVal(elId, x ?? "");
    v("atcFrProduct", r?.productId ?? val(k.productFilter)); v("atcFrVersion", r?.version); v("atcFrBuild", r?.build);
    v("atcFrEdition", r?.edition); v("atcFrRelease", isoDate(r?.releaseDate)); v("atcFrEol", isoDate(r?.endOfLifeDate));
    v("atcFrSource", r?.sourceReference); v("atcFrVerified", isoDate(r?.verifiedDate)); v("atcFrReason", "");
    // firmware (426)
    v("atcFrBranch", r?.branchTrain); v("atcFrEng", isoDate(r?.engineeringSupportEndDate)); v("atcFrStd", isoDate(r?.standardSupportEndDate));
    v("atcFrSec", isoDate(r?.securityFixEndDate)); v("atcFrVulns", r?.knownVulnerabilities); v("atcFrMinSafe", r?.minimumSafeVersion);
    v("atcFrUrgency", r?.upgradeUrgency); v("atcFrPackage", r?.packageLocation); v("atcFrChecksum", r?.checksum);
    v("atcFrSignature", r?.signature); v("atcFrNotes", r?.releaseNotes); v("atcFrReviewer", r?.reviewer);
    // operating system (427)
    v("atcFrArch", r?.architecture); v("atcFrMain", isoDate(r?.mainstreamSupportEndDate)); v("atcFrExt", isoDate(r?.extendedSupportEndDate));
    v("atcFrSecUpd", isoDate(r?.securityUpdateEndDate)); v("atcFrChannel", r?.servicingChannel); v("atcFrFeature", r?.featureVersion);
    v("atcFrPatch", r?.patchLevel); v("atcFrLatestBuild", r?.latestApprovedBuild); v("atcFrMinBuild", r?.minimumCompliantBuild);
    v("atcFrVerifiedBy", r?.verifiedBy); v("atcFrException", r?.exceptionNote); v("atcFrReplacementPath", r?.replacementPath);
    document.getElementById("atcFrBaseline").checked = !!r?.isApprovedBaseline;
    if (kind === "os") {
      const others = state.os.releases.filter(x => x.releaseId !== r?.releaseId);
      document.getElementById("atcFrReplacement").innerHTML = `<option value="">None</option>` + others.map(x =>
        `<option value="${x.releaseId}">${esc([x.productName, x.edition, x.version, x.architecture].filter(Boolean).join(" "))}</option>`).join("");
      v("atcFrReplacement", r?.replacementReleaseId);
    }
    document.getElementById("atcFrReasonWrap").hidden = !r;
    document.getElementById("atcFrSharedWrap").hidden = !(PLATFORM && !r);
    document.getElementById("atcFrShared").checked = false;
    document.querySelectorAll("#atcReleaseForm input, #atcReleaseForm select, #atcReleaseForm textarea").forEach(el => {
      el.disabled = !editable || (locked && el.hasAttribute("data-identity"));
    });
    document.getElementById("atcReleaseSave").hidden = !editable;
    renderReleaseActions(r);
    renderCompat(detail);
    document.getElementById("atcFrEvents").innerHTML = (detail?.lifecycleEvents || []).map(e => `
      <tr><td>${esc(dateTime(e.enteredDt))}</td><td>${esc(MILESTONE[e.milestoneCode] || e.milestoneCode)}</td>
          <td>${esc(labelFor(e.milestoneCode, e.beforeValue))}</td><td>${esc(labelFor(e.milestoneCode, e.afterValue))}</td>
          <td>${esc(e.reason || "")}</td><td>${esc(e.enteredBy || "")}</td></tr>`).join("") || empty(6, "No lifecycle changes recorded.");
    document.getElementById("atcFrHistory").innerHTML = (detail?.history || []).map(x => `
      <tr><td>${esc(dateTime(x.transitionedAt))}</td><td>${esc(x.fromStatus || "--")}</td><td>${esc(x.toStatus)}</td>
          <td>${esc(x.actorName || (x.actorEmployeeId ? "Employee #" + x.actorEmployeeId : "System"))}</td>
          <td>${esc(x.reasonText || x.reasonCode || "")}</td></tr>`).join("") || empty(5, "No history.");
    modalMessage("atcReleaseMessage", "");
    if (sameOpen) return;   // reload of the open release keeps the current tab
    selectTab("atc-rtab", "details", "atc-rpanel");
    document.getElementById("atcReleaseModal").hidden = false;
  }

  function renderReleaseActions(r) {
    const k = KIND[state.kind], host = document.getElementById("atcFrActions"), a = [];
    if (r && (!r.isShared || PLATFORM)) {
      (k.NEXT[r.statusCode] || []).forEach(([to, needsReason]) => {
        const approve = to === "APPROVED";
        if (approve ? !CAN_APPROVE : !CAN_EDIT) return;
        const label = approve ? "Approve" : to === "DRAFT" ? "Reopen" : to === "WITHDRAWN" ? "Withdraw" : `Mark ${k.STATUS[to].label}`;
        const question = !needsReason ? null : to === "DRAFT" ? "Why is this release being reopened?"
          : to === "WITHDRAWN" ? "Why is this release being withdrawn?" : `Why is this release moving to ${k.STATUS[to].label}?`;
        a.push({ label, primary: approve, fn: () => releaseTransition(to, question, approve ? `Approve this ${k.noun} release?` : null) });
      });
    }
    host.innerHTML = a.map((x, i) => `<button type="button" class="pm-button${x.primary ? " primary" : ""}" data-atc-ract="${i}">${esc(x.label)}</button>`).join("");
    host.querySelectorAll("[data-atc-ract]").forEach(b => b.addEventListener("click", () => a[Number(b.dataset.atcRact)].fn()));
  }

  async function releaseTransition(toStatusCode, reasonQuestion, confirmQuestion) {
    const r = state.release?.release, kind = state.kind, k = KIND[kind];
    if (!r) return;
    let reasonText = null;
    if (reasonQuestion) {
      reasonText = await window.gracUi.promptRequired(reasonQuestion, { title: "Reason required", inputLabel: "Reason" });
      if (reasonText === null) return;
    } else if (confirmQuestion && !await window.gracUi.confirm(confirmQuestion)) return;
    const res = await api("POST", `${k.path}/releases/${r.releaseId}/transition`, {
      organizationId: state.organizationId, shared: !!r.isShared, toStatusCode, reasonText, expectedRecordVersion: r.recordVersion
    });
    if (!res.ok) { modalMessage("atcReleaseMessage", res.error); if (res.status === 409) await openRelease(kind, r.releaseId); return; }
    await load(`Release moved to ${k.STATUS[toStatusCode]?.label || toStatusCode}.`);
    await openRelease(kind, r.releaseId);
  }

  async function saveRelease(ev) {
    ev.preventDefault();
    const r = state.release?.release || null, kind = state.kind, k = KIND[kind];
    if (!canChange(r)) return;
    if (!val("atcFrProduct") || !val("atcFrVersion")) { modalMessage("atcReleaseMessage", "Product and version are required."); return; }
    const d = id => val(id) || null;
    const release = d("atcFrRelease");
    if (release && k.endDates.some(id => d(id) && d(id) < release)) {
      modalMessage("atcReleaseMessage", "Support-end and end-of-life dates cannot precede the release date."); return;
    }
    const common = {
      organizationId: state.organizationId,
      shared: r ? !!r.isShared : (PLATFORM && document.getElementById("atcFrShared").checked),
      releaseId: r ? r.releaseId : null, productId: Number(val("atcFrProduct")), version: val("atcFrVersion"),
      build: d("atcFrBuild"), edition: d("atcFrEdition"), releaseDate: release, endOfLifeDate: d("atcFrEol"),
      sourceReference: d("atcFrSource"), verifiedDate: d("atcFrVerified"), changeReason: d("atcFrReason"),
      expectedRecordVersion: r ? r.recordVersion : null
    };
    const body = kind === "fw" ? {
      ...common, branchTrain: d("atcFrBranch"), engineeringSupportEndDate: d("atcFrEng"), standardSupportEndDate: d("atcFrStd"),
      securityFixEndDate: d("atcFrSec"), knownVulnerabilities: d("atcFrVulns"), minimumSafeVersion: d("atcFrMinSafe"),
      upgradeUrgency: d("atcFrUrgency"), packageLocation: d("atcFrPackage"), checksum: d("atcFrChecksum"),
      signature: d("atcFrSignature"), releaseNotes: d("atcFrNotes"), reviewer: d("atcFrReviewer")
    } : {
      ...common, architecture: d("atcFrArch"), mainstreamSupportEndDate: d("atcFrMain"), extendedSupportEndDate: d("atcFrExt"),
      securityUpdateEndDate: d("atcFrSecUpd"), servicingChannel: d("atcFrChannel"), featureVersion: d("atcFrFeature"),
      patchLevel: d("atcFrPatch"), latestApprovedBuild: d("atcFrLatestBuild"), minimumCompliantBuild: d("atcFrMinBuild"),
      verifiedBy: d("atcFrVerifiedBy"), isApprovedBaseline: document.getElementById("atcFrBaseline").checked,
      exceptionNote: d("atcFrException"), replacementReleaseId: Number(val("atcFrReplacement")) || null,
      replacementPath: d("atcFrReplacementPath")
    };
    const res = await api("POST", `${k.path}/releases`, body);
    if (!res.ok) { modalMessage("atcReleaseMessage", res.error); if (res.status === 409) await openRelease(kind, r.releaseId); return; }
    await load(`Release "${val("atcFrVersion")}" saved.`);
    await openRelease(kind, res.data.id || (r && r.releaseId));
  }

  // ------------------------------------------------------------------ compatibility (firmware / OS)
  // A compatibility row may be added when the user can change rows of that
  // scope: an organization row on any visible release, a shared row only by
  // the platform administrator on a shared release.
  function renderCompat(detail) {
    const r = detail?.release, kind = state.kind;
    document.getElementById("atcAddCompat").hidden = !(r && CAN_EDIT);
    const btn = (act, id, icon, title) => `<button type="button" class="pm-button icon" data-atc-cact="${act}" data-atc-cid="${id}" title="${title}" aria-label="${title}"><i class="fa-solid ${icon}"></i></button>`;
    const conditions = c => kind === "fw"
      ? `${chip(COMPAT, c.compatStatus)} ${esc(c.hardwareRevision ? "rev " + c.hardwareRevision : "any revision")}${c.effectiveFrom || c.effectiveTo ? esc(` - ${c.effectiveFrom ? fmtDate(c.effectiveFrom) : "always"} to ${c.effectiveTo ? fmtDate(c.effectiveTo) : "open"}`) : ""}`
      : esc([c.processorArchitecture ? "arch " + c.processorArchitecture : "any architecture",
             c.minFirmwareName ? "min firmware " + c.minFirmwareName : null, c.exclusions ? "excludes: " + c.exclusions : null].filter(Boolean).join(" - "));
    document.getElementById("atcCompatBody").innerHTML = !r ? empty(6, "Save the release first.") : (detail.compatibility || []).map(c => {
      const own = canChange(c);
      return `<tr class="${c.isActive ? "" : "atc-muted-row"}">
        <td>${esc(c.assetTypeName)}</td><td>${esc(c.makeName || "Any")}</td>
        <td>${esc(c.modelName ? c.modelName + (c.modelVariant ? " " + c.modelVariant : "") : "Any")}</td>
        <td>${conditions(c)}</td>
        <td>${c.isActive ? chip({ DRAFT: { label: "Draft", cls: "atc-plain" }, APPROVED: { label: "Approved", cls: "atc-ok" } }, c.approvalStatus) : `<span class="atc-chip atc-muted">Inactive</span>`} ${scopeChip(c.isShared)}</td>
        <td>${own ? btn("edit", c.compatId, "fa-pen", "Edit") : btn("view", c.compatId, "fa-eye", "View")}${own && CAN_APPROVE && c.isActive && c.approvalStatus === "DRAFT" ? btn("approve", c.compatId, "fa-circle-check", "Approve") : ""}</td>
      </tr>`;
    }).join("") || empty(6, "No compatibility records yet.");
  }

  async function onCompatAction(ev) {
    const b = ev.target.closest("[data-atc-cact]");
    if (!b) return;
    const c = (state.release?.compatibility || []).find(x => x.compatId === Number(b.dataset.atcCid));
    if (!c) return;
    if (b.dataset.atcCact !== "approve") { openCompat(c); return; }
    if (!await window.gracUi.confirm("Approve this compatibility record? Approved rows drive recommendations.")) return;
    const kind = state.kind;
    const res = await api("POST", `${KIND[kind].path}/compatibility/${c.compatId}/approve`, {
      organizationId: state.organizationId, shared: !!c.isShared, expectedRecordVersion: c.recordVersion
    });
    if (!res.ok) { modalMessage("atcReleaseMessage", res.error); return; }
    await openRelease(kind, state.release.release.releaseId);
    modalMessage("atcReleaseMessage", "Compatibility record approved.");
    await load();
  }

  function openCompat(c) {
    const r = state.release?.release, kind = state.kind;
    if (!r) return;
    state.compat = c;
    const editable = canChange(c);
    showKind("atcCompatForm", kind);
    document.getElementById("atcCompatTitle").textContent = c ? (editable ? "Edit compatibility" : "Compatibility") : `Add compatibility for ${r.version}`;
    document.getElementById("atcFcStatus").innerHTML = Object.entries(COMPAT).map(([key, x]) => `<option value="${key}">${x.label}</option>`).join("");
    fillCompatPickers(c, true);
    setVal("atcFcEvidence", c?.evidence ?? ""); setVal("atcFcReviewer", c?.reviewer ?? "");
    // firmware (426)
    setVal("atcFcHw", c?.hardwareRevision ?? ""); setVal("atcFcStatus", c?.compatStatus || "SUPPORTED");
    setVal("atcFcPath", c?.upgradePath ?? ""); setVal("atcFcFrom", isoDate(c?.effectiveFrom)); setVal("atcFcTo", isoDate(c?.effectiveTo));
    // operating system (427)
    setVal("atcFcArch", c?.processorArchitecture ?? ""); setVal("atcFcPrereq", c?.firmwarePrerequisite ?? ""); setVal("atcFcExclusions", c?.exclusions ?? "");
    if (kind === "os") {
      const fws = (state.fw?.releases || []).filter(x => !["DRAFT", "WITHDRAWN"].includes(x.statusCode) || x.releaseId === c?.minFirmwareReleaseId);
      document.getElementById("atcFcMinFw").innerHTML = `<option value="">None</option>` + fws.map(x =>
        `<option value="${x.releaseId}">${esc(x.publisherName + " " + x.productName + " " + x.version)}</option>`).join("");
      setVal("atcFcMinFw", c?.minFirmwareReleaseId ?? "");
    }
    document.getElementById("atcFcActive").checked = c ? !!c.isActive : true;
    // A shared row is possible only on a shared release, by the platform administrator.
    document.getElementById("atcFcSharedWrap").hidden = !(PLATFORM && !c && r.isShared);
    document.getElementById("atcFcShared").checked = false;
    document.querySelectorAll("#atcCompatForm input, #atcCompatForm select").forEach(el => { el.disabled = !editable; });
    document.getElementById("atcCompatSave").hidden = !editable;
    modalMessage("atcCompatMessage", c && c.approvalStatus === "APPROVED" && editable ? "Saving changes returns this approved record to Draft for re-approval." : "");
    document.getElementById("atcCompatModal").hidden = false;
  }

  function fillCompatPickers(c, refillTypes) {
    const typeSel = document.getElementById("atcFcType");
    if (refillTypes) {
      let types = state.data.assetTypes.slice();
      if (c && !types.some(t => t.assetTypeId === c.assetTypeId)) types = [{ assetTypeId: c.assetTypeId, assetTypeName: c.assetTypeName, path: "(not selectable now)" }].concat(types);
      typeSel.innerHTML = `<option value="">Select</option>` + types.map(t => `<option value="${t.assetTypeId}">${esc(t.path + " / " + t.assetTypeName)}</option>`).join("");
      setVal("atcFcType", c?.assetTypeId ?? "");
    }
    const type = Number(val("atcFcType")) || null;
    // Makes offered: those listing this asset type as supported, or listing none.
    const makes = state.data.makes.filter(k => (k.status === "Active" || k.makeId === c?.makeId)
      && (!k.assetTypeIds || !type || String(k.assetTypeIds).split(",").includes(String(type)) || k.makeId === c?.makeId));
    document.getElementById("atcFcMake").innerHTML = `<option value="">Any make</option>` + makes.map(k => `<option value="${k.makeId}">${esc(k.makeName)}</option>`).join("");
    setVal("atcFcMake", c?.makeId ?? "");
    fillCompatModels(c);
  }

  function fillCompatModels(c) {
    const type = Number(val("atcFcType")) || null, make = Number(val("atcFcMake")) || null;
    const models = state.data.models.filter(m => (!type || m.assetTypeId === type) && (!make || m.makeId === make)
      && (m.statusCode !== "WITHDRAWN" || m.modelId === c?.modelId));
    document.getElementById("atcFcModel").innerHTML = `<option value="">Any model</option>` + models.map(m =>
      `<option value="${m.modelId}">${esc(m.makeName + " " + m.modelName + (m.variant ? " " + m.variant : ""))}</option>`).join("");
    setVal("atcFcModel", c?.modelId ?? "");
  }

  async function saveCompat(ev) {
    ev.preventDefault();
    const r = state.release?.release, c = state.compat, kind = state.kind;
    if (!r || !canChange(c)) return;
    if (!val("atcFcType")) { modalMessage("atcCompatMessage", "Select the asset type."); return; }
    if (kind === "fw" && val("atcFcFrom") && val("atcFcTo") && val("atcFcTo") < val("atcFcFrom")) { modalMessage("atcCompatMessage", "Effective To cannot be before Effective From."); return; }
    const common = {
      organizationId: state.organizationId,
      shared: c ? !!c.isShared : (PLATFORM && r.isShared && document.getElementById("atcFcShared").checked),
      compatId: c ? c.compatId : null, releaseId: r.releaseId, assetTypeId: Number(val("atcFcType")),
      makeId: Number(val("atcFcMake")) || null, modelId: Number(val("atcFcModel")) || null,
      evidence: val("atcFcEvidence") || null, reviewer: val("atcFcReviewer") || null,
      isActive: document.getElementById("atcFcActive").checked, expectedRecordVersion: c ? c.recordVersion : null
    };
    const body = kind === "fw" ? {
      ...common, hardwareRevision: val("atcFcHw") || null, compatStatus: val("atcFcStatus"), upgradePath: val("atcFcPath") || null,
      effectiveFrom: val("atcFcFrom") || null, effectiveTo: val("atcFcTo") || null
    } : {
      ...common, processorArchitecture: val("atcFcArch") || null, minFirmwareReleaseId: Number(val("atcFcMinFw")) || null,
      firmwarePrerequisite: val("atcFcPrereq") || null, exclusions: val("atcFcExclusions") || null
    };
    const res = await api("POST", `${KIND[kind].path}/compatibility`, body);
    if (!res.ok) { modalMessage("atcCompatMessage", res.error); return; }
    document.getElementById("atcCompatModal").hidden = true;
    await openRelease(kind, r.releaseId);
    modalMessage("atcReleaseMessage", "Compatibility record saved as Draft.");
    await load();
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the Asset Configuration API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, error: err.message }; }
  }
  function productLabel(p) { return [p.publisherName, p.family, p.productName].filter(Boolean).join(" "); }
  function matchLabel(level) { return { MODEL: "This model", MAKE: "Make + asset type", ASSET_TYPE: "Asset type" }[level] || level; }
  function labelFor(code, v) { return code === "LIFECYCLE_STATUS" ? (LIFECYCLE[v]?.label || v || "--") : (v ? fmtDate(v) : "--"); }
  function chip(map, code) { const s = map[code] || { label: code || "", cls: "atc-plain" }; return `<span class="atc-chip ${s.cls}">${esc(s.label)}</span>`; }
  function scopeChip(shared) { return shared ? `<span class="atc-chip atc-info">Shared</span>` : `<span class="atc-chip atc-plain">Organization</span>`; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("atcMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function modalMessage(id, text) { const el = document.getElementById(id); el.textContent = text || ""; el.hidden = !text; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v ?? ""; }
  function isoDate(v) { return v ? String(v).substring(0, 10) : ""; }
  function fmtDate(v) { return !v ? "" : (window.gracFormatDisplayDate ? window.gracFormatDisplayDate(v) : isoDate(v)); }
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
