// =====================================================================
// window.gracEvidencePicker -- THE "Select from Evidence Center" picker
// (migration 476, Phase 1).
//
// Pairs with Views/Practice/Partials/_evidence-picker-dialog.cshtml.
// Include that partial once on a page, load this script, and any screen
// on that page can open the picker. Phase 1 caller: Operationalize
// (resolve-workspace.cshtml); Phase 2: Task completion.
//
// USAGE
//   window.gracEvidencePicker.open({
//     context:       "Evidence: Access review report",   // shown on top
//     typeId:        12,            // default filter (the row's type); optional
//     typeName:      "Report",      // label for the filter
//     load:  async ({ search, typeId, pageNumber, pageSize }) =>
//              ({ ok, rows, totalRows, error }),         // the host's endpoint
//     link:  async row => ({ ok, error, message })       // the host links it
//   });
//   Resolves when the dialog closes: { linked: true, message } after a
//   successful link, otherwise { linked: false }.
//
// The host passes the two calls, so the picker knows nothing about which
// record it is linking to -- the endpoint does (and checks the caller).
// Rows are the sp_evidence_link_candidates columns (either key case).
// =====================================================================
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);
  const esc = v => String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const date = v => v ? String(v).substring(0, 10) : "";

  let opts = null, rows = [], pager = null, resolver = null, result = { linked: false }, timer = null, wired = false;

  function wire() {
    if (wired) return;
    wired = true;
    pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "gepPager", onChange: load }) : null;
    $("gepClose").addEventListener("click", close);
    $("gepCancel").addEventListener("click", close);
    $("gepDialog").addEventListener("cancel", e => { e.preventDefault(); close(); });
    $("gepSearch").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(() => { pager?.reset(true); load(); }, 300); });
    $("gepSearch").addEventListener("keydown", e => { if (e.key === "Enter") e.preventDefault(); });
    $("gepSameType").addEventListener("change", () => { pager?.reset(true); load(); });
    $("gepBody").addEventListener("click", async e => {
      const b = e.target.closest("[data-gep-link]");
      if (!b) return;
      const row = rows.find(r => String(F(r, "evidenceItemId")) === b.getAttribute("data-gep-link"));
      if (!row) return;
      b.disabled = true;
      message("Linking...", "info");
      const res = await opts.link(row).catch(err => ({ ok: false, error: err.message }));
      if (!res || !res.ok) { b.disabled = false; message((res && res.error) || "Could not link the evidence."); return; }
      result = { linked: true, message: res.message };
      close();
    });
  }

  function open(options) {
    if (!$("gepDialog")) {
      console.error("gracEvidencePicker: include Partials/_evidence-picker-dialog on this page.");
      return Promise.resolve({ linked: false });
    }
    wire();
    opts = options || {};
    result = { linked: false };
    rows = [];
    $("gepContext").textContent = opts.context || "";
    $("gepSearch").value = "";
    const hasType = Number(opts.typeId) > 0;
    $("gepTypeWrap").hidden = !hasType;
    $("gepSameType").checked = hasType;
    $("gepTypeLabel").textContent = hasType ? `Only ${opts.typeName || "the same evidence type"}` : "";
    message("");
    pager?.reset(true);
    const dlg = $("gepDialog");
    if (!dlg.open) dlg.showModal();
    load();
    return new Promise(resolve => { resolver = resolve; });
  }

  function close() {
    const dlg = $("gepDialog");
    if (dlg && dlg.open) dlg.close();
    if (resolver) { const r = resolver; resolver = null; r(result); }
  }

  async function load() {
    if (!opts) return;
    const body = $("gepBody");
    body.innerHTML = empty("Loading...");
    const res = await opts.load({
      search: $("gepSearch").value.trim() || null,
      typeId: $("gepSameType").checked && Number(opts.typeId) > 0 ? Number(opts.typeId) : null,
      pageNumber: pager ? pager.page() : 1,
      pageSize: pager ? pager.size() : 10
    }).catch(err => ({ ok: false, error: err.message }));
    if (!res || !res.ok) { body.innerHTML = empty((res && res.error) || "Could not load the Evidence Center."); pager?.clear(); return; }
    rows = res.rows || [];
    pager?.setTotal(res.totalRows, rows.length);
    body.innerHTML = rows.map(r => {
      const linkable = F(r, "linkable") === true || F(r, "linkable") === 1;
      const st = F(r, "validityState");
      const badge = st === "Expired" ? '<span class="pm-badge gep-expired">Expired</span>'
                  : st === "Expiring" ? '<span class="pm-badge gep-expiring">Expiring</span>' : "";
      return `<tr>
        <td>${esc(F(r, "evidenceTitle"))}<div class="gep-sub">${esc(F(r, "fileName") || "")}</div></td>
        <td>${esc(F(r, "evidenceType") || "--")}</td>
        <td>${esc(F(r, "ownerName") || "--")}</td>
        <td>${st === "NoExpiry" ? "No expiry" : esc(date(F(r, "validTo")))} ${badge}</td>
        <td>v${esc(F(r, "currentVersionNo"))}</td>
        <td>${esc(F(r, "usedInCount") ?? 0)}</td>
        <td>${linkable
              ? `<button type="button" class="pm-button small" data-gep-link="${esc(F(r, "evidenceItemId"))}"><i class="fa-solid fa-link" aria-hidden="true"></i> Link</button>`
              : `<span class="gep-sub">${esc(F(r, "notLinkableReason") || "")}</span>`}</td>
      </tr>`;
    }).join("") || empty($("gepSameType").checked
        ? "Nothing of this type in the Evidence Center that you can see. Clear the type filter, or upload the file instead."
        : "Nothing in the Evidence Center that you can see. Upload the file instead.");
  }

  function message(text, kind) {
    const el = $("gepMessage");
    el.textContent = text || "";
    el.classList.toggle("info", kind === "info");
    el.hidden = !text;
  }

  function empty(text) { return `<tr><td colspan="7" class="pm-empty">${esc(text)}</td></tr>`; }

  window.gracEvidencePicker = { open, close };
})();
