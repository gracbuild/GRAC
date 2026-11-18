// =====================================================================
// Risk Methodology -- migration 532 (2026-11-12).
// Loaded by Views/Practice/Partials/risk-methodology.cshtml.
//
// Settings -> Risk Methodology. Shows the organisation's PUBLISHED
// methodology read-only; "Start draft" makes an editable copy (of the
// published version, or of a template), Save draft stores it, Publish
// turns it into the next version (sp_risk_methodology_publish checks it
// completely first). Discard throws the draft away.
//
// The risk pages read the published version (risk-centre.js
// loadMethodology); nothing here changes a risk.
//
// Auth: /practice/api/risk-centre/* enforces session + org isolation;
// the writes also need EDIT on this screen (organisation admin).
//
// 574 (2026-11-16): Likelihood and Impact head the Dimensions table as two
// locked rows (always on, required, every stage); only their levels are
// edited -- names, descriptors and how many (2 to 10, numbered 1..n). The
// Risk matrix section below gives every likelihood x impact cell a rating
// and resizes with the levels (3x3, 4x4, 5x5 ...). Publishing a changed
// scale or matrix warns first: risks already assessed are marked
// "Re-assessment needed" and leave the heat maps until assessed again; the
// server refuses while an assessment waits for approval (58349).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/risk-centre";
  const wf   = window.__wfCommon;
  const esc  = v => wf.escape(v);

  const TEMPLATE_LABEL = { ISO31000: "ISO 31000", COSO_ERM: "COSO ERM", ISO27005: "ISO 27005", BLANK: "Blank" };
  // 574: true once the database has 574 (the version carries its scale).
  const hasScale = () => (state.edit?.core?.LIKELIHOOD?.length || 0) > 0 && (state.edit?.core?.IMPACT?.length || 0) > 0;
  // 574: the risk matrix's axes (level rows with these codes; no dimension row).
  const CORE = [
    ["LIKELIHOOD", "Likelihood", "How likely the risk is to happen."],
    ["IMPACT",     "Impact",     "How severe the consequence would be."]
  ];

  // sets = the GET answer; edit = the version on screen (draft, or the
  // published one read-only); editable = a draft exists.
  const state = { orgId: null, sets: null, published: null, draft: null, edit: null, editable: false, openLevels: new Set() };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("rmRoot")) return;
    on("rmPickOrg", "change", ev => { state.orgId = Number(ev.target.value) || null; load(); });
    on("rmReloadBtn", "click", load);
    // Choosing where to start IS starting the draft (no Start button).
    // "Current draft" is what is already on screen, so choosing it does
    // nothing; "From a template" waits for the template.
    on("rmStartFrom", "change", () => {
      syncStartFrom();
      const from = val("rmStartFrom");
      if (from !== "TEMPLATE" && from !== "DRAFT") startDraft();
    });
    on("rmTemplate", "change", startDraft);
    on("rmDiscardBtn", "click", discardDraft);
    on("rmPublishBtn", "click", publish);
    document.getElementById("rmForm").addEventListener("submit", ev => { ev.preventDefault(); saveDraft(); });
    on("rmAddDim", "click", () => { readForm(); addDimension(); render(); });
    on("rmAddBand", "click", () => { readForm(); state.edit.bands.push({ minScore: null, maxScore: null, ratingCode: "" }); render(); });
    on("rmAddArea", "click", () => { readForm(); state.edit.areas.push({ areaCode: "", areaName: "", isNew: true }); render(); });
    on("rmAddAppetite", "click", () => { readForm(); state.edit.appetite.push({ riskCategoryCode: "", maxRatingCode: "", appetiteStatement: "" }); render(); });
    // 574: every cell back to the suggested rating for its likelihood x impact.
    on("rmMatrixDefaults", "click", () => {
      readForm();
      const e = state.edit, nl = e.core.LIKELIHOOD.length, ni = e.core.IMPACT.length;
      e.matrix.forEach(c => { c.ratingCode = defaultRating(c.likelihoodValue, c.impactValue, nl, ni); });
      render();
    });
    ["rmScoringMode", "rmAppetite", "rmQuant", "rmImpactMode"].forEach(id => on(id, "change", () => { readForm(); render(); }));

    const orgs = await wf.loadOrgs();
    if (!orgs.length) {
      document.getElementById("rmPickOrg").innerHTML = `<option value="">No organization</option>`;
      status("You are not mapped to any organization, so there is nothing to configure.");
      return;
    }
    wf.populateOrgSelect("rmPickOrg", orgs);
    state.orgId = Number(document.getElementById("rmPickOrg").value) || null;
    await load();
  }

  // ---- load ----------------------------------------------------------
  async function load() {
    msg("");
    state.sets = state.published = state.draft = state.edit = null;
    state.editable = false;
    state.openLevels.clear();
    document.getElementById("rmForm").hidden = true;
    document.getElementById("rmHistoryPanel").hidden = true;
    if (!state.orgId) { status(""); return; }
    status("Loading...");

    const res = await api("GET", `/methodology?organizationId=${state.orgId}`);
    if (!res.ok) { status(res.error || "The risk methodology could not be loaded.", true); return; }
    state.sets = res.data.sets || {};
    const versions = state.sets.versions || [];
    state.published = versions.find(v => v.status === "Published") || null;
    state.draft     = versions.find(v => v.status === "Draft") || null;
    const shown = state.draft || state.published;
    state.editable = !!state.draft;
    state.edit = shown ? toModel(shown) : null;

    const pub = state.published
      ? `Published: ${state.published.methodologyName ? `<strong>${esc(state.published.methodologyName)}</strong>, ` : ""}version ${esc(state.published.versionNo)} (${esc(state.published.scoringMode)} scoring`
        + `${state.published.templateCode ? `, from ${esc(TEMPLATE_LABEL[state.published.templateCode] || state.published.templateCode)}` : ""})`
        + ` &middot; ${esc(fmtDate(state.published.publishedDt))}${state.published.publishedByName ? ` by ${esc(state.published.publishedByName)}` : ""}.`
      : "No methodology published yet &mdash; the risk pages use likelihood &times; impact only.";
    const draft = state.draft
      ? ` <span class="rm-chip">Draft open</span> Edit below, then Save draft or Publish.`
      : state.published ? " To change it, start a new draft." : " To set one up, start a new draft.";
    status(pub + draft, false, true);

    // "Published version" only when there is one. Both combos go back to
    // "-- choose --", so the next choice is always a change that acts.
    const from = document.getElementById("rmStartFrom");
    const pubOpt = from.querySelector('option[value="PUBLISHED"]');
    pubOpt.hidden = pubOpt.disabled = !state.published;
    // "Current draft" only while a draft is open -- and then it is the
    // selection, matching the draft the form shows.
    const draftOpt = from.querySelector('option[value="DRAFT"]');
    draftOpt.hidden = draftOpt.disabled = !state.draft;
    from.querySelector('option[value=""]').hidden = !!state.draft;
    resetStartFrom();

    renderHistory();
    if (state.edit) { document.getElementById("rmForm").hidden = false; render(); }
  }

  // GET rows -> the editable model of one version.
  function toModel(v) {
    const id = v.methodologyVersionId;
    const mine = rows => (state.sets[rows] || []).filter(x => x.methodologyVersionId === id);
    const levels = mine("levels");
    return {
      scoringMode: v.scoringMode, thirdAxisCode: v.thirdAxisCode || "",
      targetRatingEnabled: !!v.targetRatingEnabled, appetiteEnabled: !!v.appetiteEnabled,
      impactMode: v.impactMode || "Single", trendEnabled: !!v.trendEnabled,
      quantificationEnabled: !!v.quantificationEnabled, currencyCode: v.currencyCode || "", notes: v.notes || "",
      methodologyName: v.methodologyName || "",
      dimensions: mine("dimensions").map(d => ({
        dimensionCode: d.dimensionCode, dimensionName: d.dimensionName, description: d.description || "",
        isEnabled: !!d.isEnabled, isRequired: !!d.isRequired, askInherent: !!d.askInherent,
        askResidual: !!d.askResidual, askReview: !!d.askReview, priorityWeight: Number(d.priorityWeight || 0),
        displayOrder: d.displayOrder || 0, isNew: false,
        levels: levels.filter(l => l.dimensionCode === d.dimensionCode)
          .map(l => ({ levelValue: l.levelValue, levelName: l.levelName, descriptor: l.descriptor || "" }))
      })),
      bands: mine("bands").map(b => ({ minScore: b.minScore, maxScore: b.maxScore, ratingCode: b.ratingCode })),
      appetite: mine("appetite").map(a => ({ riskCategoryCode: a.riskCategoryCode || "", maxRatingCode: a.maxRatingCode, appetiteStatement: a.appetiteStatement || "" })),
      areas: mine("impactAreas").map(a => ({ areaCode: a.areaCode, areaName: a.areaName, isNew: false })),
      // 574
      core: Object.fromEntries(CORE.map(([code]) => [code, levels.filter(l => l.dimensionCode === code)
        .sort((a, b) => a.levelValue - b.levelValue)
        .map(l => ({ levelValue: l.levelValue, levelName: l.levelName, descriptor: l.descriptor || "" }))])),
      matrix: mine("matrix").map(c => ({ likelihoodValue: c.likelihoodValue, impactValue: c.impactValue, ratingCode: c.ratingCode }))
    };
  }

  // ---- render ----------------------------------------------------------
  function render() {
    const e = state.edit;
    const ro = !state.editable;
    setVal("rmScoringMode", e.scoringMode);
    setVal("rmImpactMode", e.impactMode);
    check("rmTarget", e.targetRatingEnabled);
    check("rmAppetite", e.appetiteEnabled);
    check("rmTrend", e.trendEnabled);
    check("rmQuant", e.quantificationEnabled);
    setVal("rmCurrency", e.currencyCode);
    setVal("rmName", e.methodologyName);
    setVal("rmNotes", e.notes);

    const third = document.getElementById("rmThirdAxis");
    third.innerHTML = e.dimensions.map(d => `<option value="${esc(d.dimensionCode)}">${esc(d.dimensionName)}</option>`).join("");
    third.value = e.thirdAxisCode || (e.dimensions[0]?.dimensionCode || "");
    document.getElementById("rmThirdWrap").hidden = e.scoringMode !== "3D";
    document.getElementById("rmCurrencyWrap").hidden = !e.quantificationEnabled;
    document.getElementById("rmBandsPanel").hidden = e.scoringMode !== "3D";
    document.getElementById("rmAppetitePanel").hidden = !e.appetiteEnabled;
    document.getElementById("rmAreasPanel").hidden = e.impactMode === "Single";

    if (!ro && hasScale()) syncMatrix();   // 574
    renderDimensions(ro);
    renderMatrix(ro);        // 574
    renderBands(ro);
    renderAppetite(ro);
    renderAreas(ro);

    document.querySelectorAll("#rmForm input, #rmForm select, #rmForm textarea").forEach(el => { el.disabled = ro || el.hasAttribute("data-off"); });
    ["rmAddDim", "rmAddBand", "rmAddAppetite", "rmAddArea", "rmMatrixDefaults", "rmSaveBtn", "rmDiscardBtn", "rmPublishBtn"]
      .forEach(id => { document.getElementById(id).hidden = ro; });
    // Levels can be looked at even read-only -- except a dimension that is
    // switched off (data-off, 2026-11-17).
    document.querySelectorAll("#rmForm [data-rm-toggle-levels]").forEach(b => { b.disabled = b.hasAttribute("data-off"); });
  }

  function renderDimensions(ro) {
    const body = document.getElementById("rmDimBody");
    const coreBody = document.getElementById("rmCoreBody");   // 2026-11-17: Likelihood & Impact panel
    // A dimension that is not Enabled is never asked anywhere (risk-centre.js
    // drops it), so its Required / Inherent / Residual / Review boxes show
    // unticked and locked (data-off). The stored flags are kept, not read
    // back from these boxes, so ticking Enabled brings the defaults back.
    const box = (field, i, on, off) => off
      ? `<td class="rm-center"><input type="checkbox" data-dim="${i}" data-field="${field}" data-off disabled title="Enable the dimension first" /></td>`
      : `<td class="rm-center"><input type="checkbox" data-dim="${i}" data-field="${field}"${on ? " checked" : ""} /></td>`;
    // 574: Likelihood and Impact -- every box ticked; only the levels
    // change. Values are 1..n in order (the matrix is keyed by them), so a
    // level is added or removed at the top only.
    // 2026-11-17 (sir): the boxes are not disabled; unticking one puts the
    // tick back and says why (data-lock, wired below).
    const lockBox = `<td class="rm-center"><input type="checkbox" checked data-lock title="Always on: likelihood and impact are asked at every stage" /></td>`;
    const coreRows = !hasScale() ? "" : CORE.map(([code, name, descr]) => {
      const lv = state.edit.core[code] || [];
      const open = state.openLevels.has(code);
      const row = `<tr class="rm-core-row">
          ${lockBox}
          <td class="rm-name-cell">
            <div class="rm-name-row"><span class="rm-core-name">${esc(name)}</span><span class="rm-code" title="Risk matrix axis -- fixed">${esc(code)}</span></div>
            <span class="rm-core-desc">${esc(descr)} Always asked; the risk matrix follows its levels.</span>
          </td>
          ${lockBox}${lockBox}${lockBox}${lockBox}
          <td class="rm-center" title="Not weighted: likelihood x impact is the base of every score">&mdash;</td>
          <td><button type="button" class="pm-button ghost" data-rm-toggle-levels="${code}">${lv.length} level${lv.length === 1 ? "" : "s"} <i class="fa-solid fa-chevron-${open ? "up" : "down"}"></i></button></td>
          <td></td>
        </tr>`;
      const levels = !open ? "" : `<tr class="rm-levels"><td></td><td colspan="8">
          <table>
            <thead><tr><th style="width:80px;">Level</th><th>Name</th><th>Descriptor</th><th aria-label="Actions"></th></tr></thead>
            <tbody>${lv.map((l, j) => `<tr>
                <td class="rm-center">${esc(l.levelValue)}</td>
                <td><input class="pm-input" type="text" maxlength="120" data-core="${code}" data-level="${j}" data-field="levelName" value="${esc(l.levelName)}" /></td>
                <td><input class="pm-input" type="text" maxlength="500" data-core="${code}" data-level="${j}" data-field="descriptor" value="${esc(l.descriptor)}" /></td>
                <td>${ro || j !== lv.length - 1 || lv.length <= 2 ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-core="${code}" title="Remove the top level"><i class="fa-solid fa-trash"></i></button>`}</td>
              </tr>`).join("")}</tbody>
          </table>
          ${ro || lv.length >= 10 ? "" : `<button type="button" class="pm-button ghost" data-rm-add-core="${code}" style="margin-top:6px;"><i class="fa-solid fa-plus"></i> Add level</button>`}
          <p class="pm-hint" style="margin:6px 0 0;">Level 1 is the lowest. 2 to 10 levels; adding or removing one resizes the risk matrix.</p>
        </td></tr>`;
      return row + levels;
    }).join("");
    coreBody.innerHTML = coreRows;
    document.getElementById("rmCorePanel").hidden = !hasScale();
    body.innerHTML = (state.edit.dimensions.map((d, i) => {
      // 2026-11-17 (sir): an unticked dimension's levels button is
      // disabled, and its levels are not left open.
      if (!d.isEnabled) state.openLevels.delete(i);
      const open = state.openLevels.has(i);
      const row = `<tr>
          ${box("isEnabled", i, d.isEnabled)}
          <td class="rm-name-cell">
            <div class="rm-name-row">
              <input class="pm-input" type="text" data-dim="${i}" data-field="dimensionName" value="${esc(d.dimensionName)}" maxlength="120" placeholder="Name shown on the risk pages" aria-label="Dimension name" />
              ${d.isNew
                ? `<input class="pm-input rm-code-input" type="text" data-dim="${i}" data-field="dimensionCode" value="${esc(d.dimensionCode)}" maxlength="40" placeholder="CODE" aria-label="Dimension code (A-Z, 0-9, _)" title="Code: A-Z, 0-9 and _. Cannot be changed after publishing." />`
                : `<span class="rm-code" title="Dimension code -- fixed, used by the system">${esc(d.dimensionCode)}</span>`}
            </div>
            <input class="pm-input rm-desc" type="text" data-dim="${i}" data-field="description" value="${esc(d.description)}" maxlength="500" placeholder="What it measures (shown as a tooltip)" aria-label="Description" />
          </td>
          ${box("isRequired", i, d.isRequired, !d.isEnabled)}
          ${box("askInherent", i, d.askInherent, !d.isEnabled)}
          ${box("askResidual", i, d.askResidual, !d.isEnabled)}
          ${box("askReview", i, d.askReview, !d.isEnabled)}
          <td style="width:90px;"><input class="pm-input" type="number" min="0" step="0.25" data-dim="${i}" data-field="priorityWeight" value="${esc(d.priorityWeight)}" /></td>
          <td><button type="button" class="pm-button ghost" data-rm-toggle-levels="${i}"${d.isEnabled ? "" : ` data-off disabled title="Enable the dimension first"`}>${d.levels.length} level${d.levels.length === 1 ? "" : "s"} <i class="fa-solid fa-chevron-${open ? "up" : "down"}"></i></button></td>
          <td>${ro || !d.isNew ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-dim="${i}" title="Remove"><i class="fa-solid fa-trash"></i></button>`}</td>
        </tr>`;
      const levels = !open ? "" : `<tr class="rm-levels"><td></td><td colspan="8">
          <table>
            <thead><tr><th style="width:80px;">Level</th><th>Name</th><th>Descriptor</th><th aria-label="Actions"></th></tr></thead>
            <tbody>${d.levels.map((l, j) => `<tr>
                <td><input class="pm-input" type="number" min="1" max="10" data-dim="${i}" data-level="${j}" data-field="levelValue" value="${esc(l.levelValue)}" /></td>
                <td><input class="pm-input" type="text" maxlength="120" data-dim="${i}" data-level="${j}" data-field="levelName" value="${esc(l.levelName)}" /></td>
                <td><input class="pm-input" type="text" maxlength="500" data-dim="${i}" data-level="${j}" data-field="descriptor" value="${esc(l.descriptor)}" /></td>
                <td>${ro ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-level="${i}:${j}" title="Remove"><i class="fa-solid fa-trash"></i></button>`}</td>
              </tr>`).join("")}</tbody>
          </table>
          ${ro ? "" : `<button type="button" class="pm-button ghost" data-rm-add-level="${i}" style="margin-top:6px;"><i class="fa-solid fa-plus"></i> Add level</button>`}
          <p class="pm-hint" style="margin:6px 0 0;">Level 1 is the lowest risk. Use 1 to 10.</p>
        </td></tr>`;
      return row + levels;
    }).join("") || `<tr><td colspan="9" class="pm-empty">No other dimensions. Add one, or start the draft from a template.</td></tr>`);

    body.querySelectorAll('[data-field="isEnabled"]').forEach(b => b.addEventListener("change", () => { readForm(); render(); }));
    // 2026-11-17: likelihood / impact are always on -- untick, tick back, say so.
    coreBody.querySelectorAll("input[data-lock]").forEach(cb => cb.addEventListener("change", () => {
      cb.checked = true;
      window.gracUi.alert("Likelihood and impact are always asked, at every stage. Only their levels can be changed.",
        { type: "info", title: "Likelihood & Impact" });
    }));
    [coreBody, body].forEach(host => host.querySelectorAll("[data-rm-toggle-levels]").forEach(b => b.addEventListener("click", () => {
      readForm();
      const raw = b.getAttribute("data-rm-toggle-levels");
      const i = /^\d+$/.test(raw) ? Number(raw) : raw;   // 574: LIKELIHOOD / IMPACT
      if (state.openLevels.has(i)) state.openLevels.delete(i); else state.openLevels.add(i);
      render();
    })));
    body.querySelectorAll("[data-rm-remove-dim]").forEach(b => b.addEventListener("click", () => {
      readForm();
      state.edit.dimensions.splice(Number(b.getAttribute("data-rm-remove-dim")), 1);
      state.openLevels.clear();
      render();
    }));
    body.querySelectorAll("[data-rm-add-level]").forEach(b => b.addEventListener("click", () => {
      readForm();
      const d = state.edit.dimensions[Number(b.getAttribute("data-rm-add-level"))];
      const next = d.levels.reduce((m, l) => Math.max(m, Number(l.levelValue) || 0), 0) + 1;
      d.levels.push({ levelValue: Math.min(next, 10), levelName: "", descriptor: "" });
      render();
    }));
    // 574: likelihood / impact levels -- added or removed at the top.
    coreBody.querySelectorAll("[data-rm-add-core]").forEach(b => b.addEventListener("click", () => {
      readForm();
      const lv = state.edit.core[b.getAttribute("data-rm-add-core")];
      if (lv.length < 10) lv.push({ levelValue: lv.length + 1, levelName: "", descriptor: "" });
      syncMatrix();
      render();
    }));
    coreBody.querySelectorAll("[data-rm-remove-core]").forEach(b => b.addEventListener("click", () => {
      readForm();
      const lv = state.edit.core[b.getAttribute("data-rm-remove-core")];
      if (lv.length > 2) lv.pop();
      syncMatrix();
      render();
    }));
    body.querySelectorAll("[data-rm-remove-level]").forEach(b => b.addEventListener("click", () => {
      readForm();
      const [i, j] = b.getAttribute("data-rm-remove-level").split(":").map(Number);
      state.edit.dimensions[i].levels.splice(j, 1);
      render();
    }));
  }

  // 574: bands and appetite use the ratings of the version's own matrix
  // (publish checks them against it). A saved choice the matrix no longer
  // has stays visible, marked, so it is not lost silently.
  function ratingOptions(selected, blank) {
    const list = matrixRatings();
    const missing = selected && !list.some(r => r.ratingCode === selected)
      ? `<option value="${esc(selected)}" selected>${esc(selected)} (not in the risk matrix)</option>` : "";
    return `<option value="">${esc(blank)}</option>` + list
      .map(r => `<option value="${esc(r.ratingCode)}"${r.ratingCode === selected ? " selected" : ""}>${esc(r.ratingName || r.ratingCode)}</option>`).join("") + missing;
  }

  // ---- 574: risk matrix -----------------------------------------------------
  // Every rating the matrix may use (current matrix + earlier versions),
  // lowest first; falls back to the current matrix's ratings.
  function ratingCatalogue() {
    const cat = state.sets.ratingCatalogue || [];
    return cat.length ? cat : (state.sets.ratings || []);
  }
  function matrixRatings() {
    const used = new Set((state.edit?.matrix || []).map(c => c.ratingCode).filter(Boolean));
    const list = ratingCatalogue().filter(r => used.has(r.ratingCode));
    return list.length ? list : (state.sets.ratings || []);
  }
  // Suggested rating for a cell: likelihood x impact as a share of the
  // largest score, spread over the current ratings (lowest first).
  function defaultRating(l, i, nl, ni) {
    const cur = state.sets.ratings || [];
    const list = cur.length ? cur : ratingCatalogue();
    if (!list.length || !nl || !ni) return "";
    const k = list.length;
    return list[Math.min(k - 1, Math.max(0, Math.ceil((l * i) / (nl * ni) * k) - 1))].ratingCode;
  }
  // One cell per likelihood x impact pair: kept where it exists, suggested
  // where the scale grew, dropped where it shrank.
  function syncMatrix() {
    const e = state.edit;
    if (!e || !e.core) return;
    const nl = e.core.LIKELIHOOD.length, ni = e.core.IMPACT.length;
    const by = new Map((e.matrix || []).map(c => [`${c.likelihoodValue}|${c.impactValue}`, c]));
    const out = [];
    for (let l = 1; l <= nl; l++)
      for (let i = 1; i <= ni; i++) {
        const c = by.get(`${l}|${i}`);
        out.push({ likelihoodValue: l, impactValue: i, ratingCode: c ? c.ratingCode : defaultRating(l, i, nl, ni) });
      }
    e.matrix = out;
  }
  // Rows = likelihood, highest first; columns = impact (the heat maps' layout).
  function renderMatrix(ro) {
    const e = state.edit;
    document.getElementById("rmMatrixPanel").hidden = !hasScale();
    if (!hasScale()) return;
    const host = document.getElementById("rmMatrix");
    const L = [...(e.core?.LIKELIHOOD || [])].sort((a, b) => b.levelValue - a.levelValue);
    const I = [...(e.core?.IMPACT || [])].sort((a, b) => a.levelValue - b.levelValue);
    document.getElementById("rmMatrixSize").textContent = L.length && I.length ? `${L.length} × ${I.length}` : "";
    const cat = ratingCatalogue();
    const info = code => cat.find(r => r.ratingCode === code) || {};
    const cell = (l, i) => (e.matrix || []).find(c => c.likelihoodValue === l && c.impactValue === i) || { ratingCode: "" };
    const swatch = hex => `<span class="rm-swatch" style="background:${esc(hex || "transparent")}"></span>`;
    host.innerHTML = `<thead><tr><th class="rm-matrix-corner">Likelihood &darr; / Impact &rarr;</th>`
      + I.map(x => `<th>${esc(x.levelValue)} &middot; ${esc(x.levelName || "")}</th>`).join("") + `</tr></thead><tbody>`
      + L.map(lr => `<tr><th>${esc(lr.levelValue)} &middot; ${esc(lr.levelName || "")}</th>`
          + I.map(ic => {
              const c = cell(lr.levelValue, ic.levelValue), r = info(c.ratingCode);
              return ro
                ? `<td><span class="rm-cell">${swatch(r.colourHex)}${esc(r.ratingName || c.ratingCode || "--")}</span></td>`
                : `<td><span class="rm-cell">${swatch(r.colourHex)}<select class="pm-input" data-mx-l="${lr.levelValue}" data-mx-i="${ic.levelValue}" aria-label="Rating for likelihood ${lr.levelValue}, impact ${ic.levelValue}">`
                  + `<option value="">--</option>`
                  + cat.map(o => `<option value="${esc(o.ratingCode)}"${o.ratingCode === c.ratingCode ? " selected" : ""}>${esc(o.ratingName || o.ratingCode)}</option>`).join("")
                  + `</select></span></td>`;
            }).join("") + `</tr>`).join("")
      + `</tbody>`;
    host.querySelectorAll("select[data-mx-l]").forEach(el => el.addEventListener("change", () => { readForm(); render(); }));
  }

  function renderBands(ro) {
    const e = state.edit;
    const scale = (state.sets.scale || [])[0] || {};
    const third = e.dimensions.find(d => d.dimensionCode === (e.thirdAxisCode || document.getElementById("rmThirdAxis").value));
    const maxThird = third ? third.levels.reduce((m, l) => Math.max(m, Number(l.levelValue) || 0), 0) : 0;
    // 574: the draft's own likelihood / impact scale.
    const nl = e.core?.LIKELIHOOD?.length || scale.maxLikelihood || 0;
    const ni = e.core?.IMPACT?.length || scale.maxImpact || 0;
    const max = nl * ni * maxThird;
    document.getElementById("rmBandsHint").textContent = max
      ? `Score = likelihood × impact × ${third.dimensionName}. Every score from 1 to ${max} must fall in exactly one band.`
      : "Every score from 1 to the maximum must fall in exactly one band.";
    const body = document.getElementById("rmBandBody");
    body.innerHTML = e.bands.map((b, i) => `<tr>
        <td><input class="pm-input" type="number" min="1" data-band="${i}" data-field="minScore" value="${esc(b.minScore ?? "")}" /></td>
        <td><input class="pm-input" type="number" min="1" data-band="${i}" data-field="maxScore" value="${esc(b.maxScore ?? "")}" /></td>
        <td><select class="pm-input" data-band="${i}" data-field="ratingCode">${ratingOptions(b.ratingCode, "-- select --")}</select></td>
        <td>${ro ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-band="${i}" title="Remove"><i class="fa-solid fa-trash"></i></button>`}</td>
      </tr>`).join("") || `<tr><td colspan="4" class="pm-empty">No bands yet.</td></tr>`;
    body.querySelectorAll("[data-rm-remove-band]").forEach(b => b.addEventListener("click", () => {
      readForm(); e.bands.splice(Number(b.getAttribute("data-rm-remove-band")), 1); render();
    }));
  }

  function renderAppetite(ro) {
    const e = state.edit;
    const cats = state.sets.categories || [];
    const body = document.getElementById("rmAppetiteBody");
    body.innerHTML = e.appetite.map((a, i) => `<tr>
        <td><select class="pm-input" data-app="${i}" data-field="riskCategoryCode">
              <option value="">Default (every category)</option>
              ${cats.map(c => `<option value="${esc(c.categoryCode)}"${c.categoryCode === a.riskCategoryCode ? " selected" : ""}>${esc(c.categoryName)}</option>`).join("")}
            </select></td>
        <td><select class="pm-input" data-app="${i}" data-field="maxRatingCode">${ratingOptions(a.maxRatingCode, "-- select --")}</select></td>
        <td><input class="pm-input" type="text" maxlength="1000" data-app="${i}" data-field="appetiteStatement" value="${esc(a.appetiteStatement)}" /></td>
        <td>${ro ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-app="${i}" title="Remove"><i class="fa-solid fa-trash"></i></button>`}</td>
      </tr>`).join("") || `<tr><td colspan="4" class="pm-empty">No appetite set.</td></tr>`;
    body.querySelectorAll("[data-rm-remove-app]").forEach(b => b.addEventListener("click", () => {
      readForm(); e.appetite.splice(Number(b.getAttribute("data-rm-remove-app")), 1); render();
    }));
  }

  function renderAreas(ro) {
    const e = state.edit;
    const body = document.getElementById("rmAreaBody");
    body.innerHTML = e.areas.map((a, i) => `<tr>
        <td style="width:200px;">${a.isNew
          ? `<input class="pm-input" type="text" maxlength="60" data-area="${i}" data-field="areaCode" value="${esc(a.areaCode)}" placeholder="CODE" />`
          : esc(a.areaCode)}</td>
        <td><input class="pm-input" type="text" maxlength="200" data-area="${i}" data-field="areaName" value="${esc(a.areaName)}" /></td>
        <td>${ro ? "" : `<button type="button" class="pm-button ghost" data-rm-remove-area="${i}" title="Remove"><i class="fa-solid fa-trash"></i></button>`}</td>
      </tr>`).join("") || `<tr><td colspan="3" class="pm-empty">No impact areas. Add one, or start the draft from a template.</td></tr>`;
    body.querySelectorAll("[data-rm-remove-area]").forEach(b => b.addEventListener("click", () => {
      readForm(); e.areas.splice(Number(b.getAttribute("data-rm-remove-area")), 1); render();
    }));
  }

  function renderHistory() {
    const rows = state.sets?.history || [];
    document.getElementById("rmHistoryPanel").hidden = !rows.length;
    document.getElementById("rmHistoryBody").innerHTML = rows.map(h => `<tr>
        <td>${esc(h.versionNo)}</td><td>${esc(h.methodologyName || "--")}</td><td>${esc(h.status)}</td><td>${esc(h.scoringMode)}</td>
        <td>${esc(TEMPLATE_LABEL[h.templateCode] || h.templateCode || "--")}</td>
        <td>${esc(fmtDate(h.publishedDt))}</td><td>${esc(h.publishedByName || "--")}</td>
      </tr>`).join("");
  }

  // ---- form -> model -----------------------------------------------------
  function readForm() {
    const e = state.edit;
    if (!e || !state.editable) return;
    e.scoringMode = val("rmScoringMode");
    e.thirdAxisCode = val("rmThirdAxis");
    e.impactMode = val("rmImpactMode");
    e.targetRatingEnabled = isChecked("rmTarget");
    e.appetiteEnabled = isChecked("rmAppetite");
    e.trendEnabled = isChecked("rmTrend");
    e.quantificationEnabled = isChecked("rmQuant");
    e.currencyCode = val("rmCurrency").toUpperCase();
    e.notes = val("rmNotes");
    e.methodologyName = val("rmName");
    document.querySelectorAll("#rmDimBody [data-dim]").forEach(el => {
      const d = e.dimensions[Number(el.getAttribute("data-dim"))];
      if (!d || el.hasAttribute("data-off")) return;
      const f = el.getAttribute("data-field");
      const lv = el.getAttribute("data-level");
      const value = el.type === "checkbox" ? el.checked : el.type === "number" ? (el.value === "" ? null : Number(el.value)) : el.value.trim();
      if (lv != null) { if (d.levels[Number(lv)]) d.levels[Number(lv)][f] = value; }
      else d[f] = f === "dimensionCode" ? String(value).toUpperCase() : value;
    });
    // 574: likelihood / impact level names and the matrix ratings.
    document.querySelectorAll("#rmCoreBody [data-core]").forEach(el => {
      const l = (e.core[el.getAttribute("data-core")] || [])[Number(el.getAttribute("data-level"))];
      if (l) l[el.getAttribute("data-field")] = el.value.trim();
    });
    document.querySelectorAll("#rmMatrix select[data-mx-l]").forEach(el => {
      const c = (e.matrix || []).find(x => x.likelihoodValue === Number(el.getAttribute("data-mx-l"))
                                         && x.impactValue === Number(el.getAttribute("data-mx-i")));
      if (c) c.ratingCode = el.value;
    });
    document.querySelectorAll("#rmBandBody [data-band]").forEach(el => {
      const b = e.bands[Number(el.getAttribute("data-band"))];
      if (b) b[el.getAttribute("data-field")] = el.tagName === "SELECT" ? el.value : (el.value === "" ? null : Number(el.value));
    });
    document.querySelectorAll("#rmAreaBody [data-area]").forEach(el => {
      const a = e.areas[Number(el.getAttribute("data-area"))];
      if (!a) return;
      const f = el.getAttribute("data-field");
      a[f] = f === "areaCode" ? el.value.trim().toUpperCase() : el.value.trim();
    });
    document.querySelectorAll("#rmAppetiteBody [data-app]").forEach(el => {
      const a = e.appetite[Number(el.getAttribute("data-app"))];
      if (a) a[el.getAttribute("data-field")] = el.value.trim();
    });
  }

  function addDimension() {
    state.edit.dimensions.push({
      dimensionCode: "", dimensionName: "", description: "", isEnabled: true, isRequired: false,
      askInherent: true, askResidual: false, askReview: true, priorityWeight: 0,
      displayOrder: (state.edit.dimensions.length + 1) * 10, isNew: true,
      levels: [{ levelValue: 1, levelName: "", descriptor: "" }, { levelValue: 2, levelName: "", descriptor: "" }]
    });
    state.openLevels.add(state.edit.dimensions.length - 1);
  }

  function payload() {
    const e = state.edit;
    return {
      scoringMode: e.scoringMode, thirdAxisCode: e.scoringMode === "3D" ? e.thirdAxisCode : (e.thirdAxisCode || null),
      targetRatingEnabled: e.targetRatingEnabled, appetiteEnabled: e.appetiteEnabled, impactMode: e.impactMode,
      trendEnabled: e.trendEnabled, quantificationEnabled: e.quantificationEnabled,
      currencyCode: e.currencyCode || null, notes: e.notes || null,
      methodologyName: e.methodologyName || null,
      dimensions: e.dimensions.map((d, i) => ({
        dimensionCode: d.dimensionCode, dimensionName: d.dimensionName, description: d.description || null,
        isEnabled: d.isEnabled, isRequired: d.isRequired, askInherent: d.askInherent, askResidual: d.askResidual,
        askReview: d.askReview, priorityWeight: d.priorityWeight || 0, displayOrder: d.displayOrder || (i + 1) * 10,
        levels: d.levels.filter(l => l.levelValue != null || l.levelName)
          .map(l => ({ levelValue: l.levelValue, levelName: l.levelName, descriptor: l.descriptor || null }))
      })),
      bands: e.bands.filter(b => b.minScore != null || b.maxScore != null || b.ratingCode),
      appetite: e.appetite.filter(a => a.maxRatingCode).map(a => ({
        riskCategoryCode: a.riskCategoryCode || null, maxRatingCode: a.maxRatingCode, appetiteStatement: a.appetiteStatement || null })),
      impactAreas: e.areas.filter(a => a.areaCode && a.areaName)
        .map((a, i) => ({ areaCode: a.areaCode, areaName: a.areaName, displayOrder: (i + 1) * 10 })),
      // 574 (only when the version carries its scale)
      ...(!hasScale() ? {} : {
        likelihoodLevels: e.core.LIKELIHOOD.map(l => ({ levelValue: l.levelValue, levelName: l.levelName, descriptor: l.descriptor || null })),
        impactLevels: e.core.IMPACT.map(l => ({ levelValue: l.levelValue, levelName: l.levelName, descriptor: l.descriptor || null })),
        matrix: e.matrix.filter(c => c.ratingCode)
          .map(c => ({ likelihoodValue: c.likelihoodValue, impactValue: c.impactValue, ratingCode: c.ratingCode }))
      })
    };
  }

  // ---- actions -----------------------------------------------------------
  async function startDraft() {
    if (!state.orgId) return;
    // Blank -> template BLANK; Published version -> null (copy); a template -> its code.
    const from = val("rmStartFrom");
    if (!from || (from === "TEMPLATE" && !val("rmTemplate"))) return;
    const template = from === "PUBLISHED" ? null : from === "TEMPLATE" ? val("rmTemplate") : "BLANK";
    if (!template && !state.published) { msg("Nothing is published yet. Start from Blank or a template.", true); resetStartFrom(); return; }
    // Cancel = nothing happens; the combo goes back to "Current draft".
    if (state.draft && !await window.gracUi.confirm("Throw the current draft away and start a new one?")) { resetStartFrom(); return; }
    const res = await api("POST", "/methodology/draft", { organizationId: state.orgId, templateCode: template, replace: !!state.draft });
    if (!res.ok) { msg(res.error, true); resetStartFrom(); return; }
    await load();
    msg(template === "BLANK" ? "Blank draft started: switch on what you need."
      : template ? `Draft started from the ${TEMPLATE_LABEL[template] || template} template.`
      : "Draft started from the published version.");
  }

  // Back to what is on screen: "Current draft" while a draft is open,
  // otherwise "-- choose --".
  function resetStartFrom() {
    document.getElementById("rmStartFrom").value = state.draft ? "DRAFT" : "";
    document.getElementById("rmTemplate").value = "";
    syncStartFrom();
  }

  // The Template combo shows only for "From a template".
  function syncStartFrom() {
    document.getElementById("rmTemplateWrap").hidden = val("rmStartFrom") !== "TEMPLATE";
  }

  async function saveDraft(quiet) {
    if (!state.editable) return false;
    readForm();
    const res = await api("POST", "/methodology/draft/save", { organizationId: state.orgId, draft: payload() });
    if (!res.ok) { msg(res.error, true); return false; }
    if (!quiet) { await load(); msg("Draft saved. Publish it to make it the organization's methodology."); }
    return true;
  }

  async function discardDraft() {
    if (!state.draft) return;
    if (!await window.gracUi.confirm("Discard the draft? The published version stays as it is.")) return;
    const res = await api("POST", "/methodology/draft/discard", { organizationId: state.orgId });
    if (!res.ok) { msg(res.error, true); return; }
    await load();
    msg("Draft discarded.");
  }

  async function publish() {
    if (!state.draft) return;
    // 574: a changed likelihood / impact scale or matrix is warned about
    // first (the server repeats the pending-approval check: 58349).
    readForm();
    const change = scaleChange();
    const chk = (state.sets.publishCheck || [])[0] || {};
    if (change && (chk.pendingApprovals || 0) > 0) {
      const n = chk.pendingApprovals;
      await window.gracUi.alert(`${n} risk assessment${n === 1 ? " is" : "s are"} waiting for approval. Approve or return `
          + `${n === 1 ? "it" : "them"} before changing the likelihood / impact scale or the risk matrix.`,
        { type: "warning", title: "Risk matrix cannot change yet" });
      return;
    }
    const ok = change
      ? await window.gracUi.confirm(`This version changes ${change}.\n\n`
            + `${chk.openAssessedRisks || 0} open risk${chk.openAssessedRisks === 1 ? " was" : "s were"} assessed on the current scale. `
            + `They keep their current ratings, but are marked "Re-assessment needed" and are shown separately on the heat maps `
            + `until they are assessed again on the new scale.\n\nPublish this draft?`,
          { type: "warning", title: "Risk matrix changes", confirmText: "Publish anyway" })
      : await window.gracUi.confirm("Publish this draft? New assessments will use it; risks already assessed keep their version until their next assessment.");
    if (!ok) return;
    if (!await saveDraft(true)) return;
    const res = await api("POST", "/methodology/publish", { organizationId: state.orgId });
    if (!res.ok) { msg(res.error, true); await load(); return; }
    await load();
    msg(`Published as version ${res.data.versionNo}.`);
  }

  // 574: what the draft changes in the scale or the matrix, against the
  // published version (or the organisation's scale when nothing is
  // published) -- "" when nothing.
  function scaleChange() {
    const e = state.edit;
    if (!hasScale()) return "";
    const pub = state.published ? toModel(state.published) : null;
    const scale = (state.sets.scale || [])[0] || {};
    const oldL = pub ? pub.core.LIKELIHOOD.length : (scale.maxLikelihood || 0);
    const oldI = pub ? pub.core.IMPACT.length : (scale.maxImpact || 0);
    const newL = e.core.LIKELIHOOD.length, newI = e.core.IMPACT.length;
    if (oldL !== newL || oldI !== newI) return `the risk matrix from ${oldL} × ${oldI} to ${newL} × ${newI}`;
    if (!pub) return "";
    const key = c => `${c.likelihoodValue}|${c.impactValue}|${c.ratingCode}`;
    const before = new Set(pub.matrix.map(key));
    const changed = e.matrix.filter(c => c.ratingCode && !before.has(key(c))).length;
    return changed ? `the rating of ${changed} risk matrix cell${changed === 1 ? "" : "s"}` : "";
  }

  // ---- helpers ------------------------------------------------------------
  async function api(method, path, body) {
    try {
      const init = { method, credentials: "same-origin" };
      if (body) { init.headers = { "Content-Type": "application/json" }; init.body = JSON.stringify(body); }
      const r = await fetch(U(base + path), init);
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) return { ok: false, error: data.error || `HTTP ${r.status}` };
      return { ok: true, data };
    } catch (err) { return { ok: false, error: err.message }; }
  }
  function on(id, ev, fn) { const el = document.getElementById(id); if (el) el.addEventListener(ev, fn); }
  function status(html, isError, isHtml) {
    const el = document.getElementById("rmStatus");
    if (isHtml) el.innerHTML = html; else el.textContent = html || "";
    el.style.color = isError ? "var(--danger-700)" : "";
  }
  function msg(text, isError) {
    const el = document.getElementById("rmMessage");
    el.textContent = text || "";
    el.style.color = isError ? "var(--danger-700)" : "";
  }
  function fmtDate(v) { if (!v) return "--"; const d = new Date(v); return isNaN(d) ? String(v) : d.toLocaleString(); }
  function check(id, on)  { const el = document.getElementById(id); if (el) el.checked = !!on; }
  function isChecked(id)  { const el = document.getElementById(id); return !!(el && el.checked); }
  function val(id)        { const el = document.getElementById(id); return el ? String(el.value || "").trim() : ""; }
  function setVal(id, v)  { const el = document.getElementById(id); if (el) el.value = v ?? ""; }
})();
