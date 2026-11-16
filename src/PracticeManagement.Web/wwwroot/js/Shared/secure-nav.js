// =====================================================================
// secure-nav.js  (migration 525, 2026-11-09)
//
// window.gracSecureNav -- opening another screen on ONE record without the
// record's id in the address bar (standing rule: a page URL never shows
// record ids in plain text). The record and its organization travel in
// the encrypted navigation code (?code=) that the gateway mints
// (PracticeManagementGatewayController navigation-code: VIEW on both
// screens, an allowed filter type, 30-minute expiry) and resolves
// (navigation-context: the code must be for the screen that reads it).
//
//   open(sourceArea, targetArea, filterType, id, organizationId, displayCode)
//                       mints the code and navigates; resolves with an
//                       error sentence, or null once it navigates
//   context(targetArea) the record of the ?code= this page was opened
//                       with: { filterType, filterId, organizationId,
//                       displayCode } | { error } | null (no code)
//   attrs(sourceArea, targetArea, filterType, id, organizationId, displayCode)
//                       data-secure-nav attributes for an <a> or <button>;
//                       a click on such an element calls open() (one
//                       delegated handler for the whole page). On an <a>,
//                       its href is the list page, opened (after the reason
//                       is shown) only if the code cannot be minted.
//
// Used by the Third-Party Management screens (tprm-common.js) and the
// dashboards that link into them (management-dashboard.js,
// practice-dashboard.js). Include it before those scripts.
// =====================================================================
(() => {
  "use strict";
  if (window.gracSecureNav) return;

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const GATEWAY = "/practice-management-gateway";
  const CSRF = () => document.querySelector('meta[name="csrf-token"]')?.content
                  || document.querySelector("input[name='__RequestVerificationToken']")?.value || "";
  const pick = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);
  const esc = v => String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  async function open(sourceArea, targetArea, filterType, id, organizationId, displayCode) {
    try {
      const r = await fetch(U(GATEWAY + "/navigation-code"), {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF() },
        body: JSON.stringify({ sourceArea, targetArea, filterType, filterId: Number(id) || 0,
                               organizationId: Number(organizationId) || null, displayCode: displayCode || "" })
      });
      const b = await r.json().catch(() => ({}));
      const code = b.code || b.Code;
      if (!r.ok || !code) return b.message || b.error || `The record could not be opened (HTTP ${r.status}).`;
      window.location.assign(`${U("/Practice/Index/" + targetArea)}?code=${encodeURIComponent(code)}`);
      return null;
    } catch (err) { return err.message; }
  }

  async function context(targetArea) {
    const code = new URLSearchParams(window.location.search).get("code");
    if (!code) return null;
    try {
      const q = new URLSearchParams({ code, targetArea }).toString();
      const r = await fetch(U(`${GATEWAY}/navigation-context?${q}`), { credentials: "same-origin" });
      const b = await r.json().catch(() => ({}));
      if (!r.ok || b.success === false) return { error: b.message || "The link has expired. Open the record from the list." };
      return { filterType: pick(b, "filterType"), filterId: Number(pick(b, "filterId")) || null,
               organizationId: Number(pick(b, "organizationId")) || null, displayCode: pick(b, "displayCode") || "" };
    } catch (err) { return { error: err.message }; }
  }

  function attrs(sourceArea, targetArea, filterType, id, organizationId, displayCode) {
    return ` data-secure-nav="${esc(targetArea)}" data-sn-source="${esc(sourceArea)}" data-sn-type="${esc(filterType)}"`
      + ` data-sn-id="${esc(id)}" data-sn-org="${esc(organizationId ?? "")}"${displayCode ? ` data-sn-display="${esc(displayCode)}"` : ""}`;
  }

  document.addEventListener("click", async ev => {
    const el = ev.target.closest("[data-secure-nav]");
    if (!el || ev.defaultPrevented || ev.button > 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey) return;
    ev.preventDefault();
    const d = el.dataset;
    const err = await open(d.snSource, d.secureNav, d.snType, d.snId, d.snOrg, d.snDisplay);
    if (err) {
      // Say why the record did not open (permission, expired session ...);
      // a link then falls back to its list page.
      window.alert(err);   // window.alert is the app's own dialog (gracUi)
      if (el.tagName === "A" && el.getAttribute("href") && el.getAttribute("href") !== "#") window.location.assign(el.getAttribute("href"));
    }
  });

  window.gracSecureNav = { open, context, attrs };
})();
