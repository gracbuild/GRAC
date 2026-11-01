// =====================================================================
// window.gracPracticeDetails -- the read-only "Practice Details" card
// (2026-10-08).
//
// Pairs with Views/Practice/Partials/_practice-details-panel.cshtml.
// Moved out of practice-view.cshtml (renderPractice / frameworkChips /
// sourceStatementChips) so the Operationalize workspace can show the same
// card above its instance facts without a second copy of the field list.
//
//   const res = await window.gracPracticeDetails.load({
//       practiceId, organizationId, organizationRequirementId });
//   // res = { ok, status, practice }  (practice null when not found)
//   window.gracPracticeDetails.render(res.practice);
//   // optional: extra label/value rows from the host page, drawn after
//   // Active Instances (Operationalize adds the instance's Department):
//   window.gracPracticeDetails.render(res.practice,
//       { extraRows: [["Department", "ISM"]] });
//
// Data: GET /practice/api/workflow/practice-configure/detail
// (PracticeConfigureController.GetPractice -> sp_practice_detail_get).
// =====================================================================
(function () {
  "use strict";

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const esc = v => (window.__wfCommon ? window.__wfCommon.escape(v)
    : String(v ?? "").replace(/[&<>"']/g, c =>
        ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c]));

  // camelCase or PascalCase, whichever the serializer produced.
  const P = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)]
    ?? row?.[k.charAt(0).toLowerCase() + k.slice(1)] ?? null;

  function jsonArray(row, key) {
    const raw = P(row, key);
    if (!raw) return [];
    if (Array.isArray(raw)) return raw;
    try { const p = JSON.parse(raw); return Array.isArray(p) ? p : []; } catch (_) { return []; }
  }

  async function load(opts) {
    const o = opts || {};
    const params = [];
    if (o.practiceId)                params.push("practiceId=" + encodeURIComponent(o.practiceId));
    if (o.organizationId)            params.push("organizationId=" + encodeURIComponent(o.organizationId));
    if (o.organizationRequirementId) params.push("organizationRequirementId=" + encodeURIComponent(o.organizationRequirementId));
    const r = await fetch(U("/practice/api/workflow/practice-configure/detail?") + params.join("&"),
                          { credentials: "same-origin" });
    if (!r.ok) return { ok: false, status: r.status, practice: null };
    const body = await r.json().catch(() => ({}));
    return { ok: true, status: r.status, practice: body.data || body.Data || null };
  }

  // Framework releases the practice is mapped to, one pm-badge each.
  // MappedFrameworksJson -- sp_practice_detail_get (migration 301), from
  // organization_statement_practice_mapping. '' when nothing is mapped or
  // the column is absent; render() then leaves the row out.
  function frameworkChips(practice) {
    const list = jsonArray(practice, "MappedFrameworksJson")
      .map(f => String(f.FrameworkRelease ?? f.frameworkRelease ?? "").trim())
      .filter(Boolean);
    if (!list.length) return "";
    return list.map(name => '<span class="pm-badge">' + esc(name) + "</span>").join("");
  }

  // Control Statement(s) the practice is mapped to -- MappedSourceStatementsJson
  // (migration 316), the same mapping rows as frameworkChips(). Migration
  // 396: a statement retired in the repository is still listed, marked.
  function sourceStatementChips(practice) {
    const list = jsonArray(practice, "MappedSourceStatementsJson")
      .map(s => {
        const name = String(s.SourceStatement ?? s.sourceStatement ?? "").trim();
        const retired = String(s.RepositoryLifecycleStatus ?? s.repositoryLifecycleStatus ?? "").toLowerCase() === "retired";
        return name ? name + (retired ? " (Retired in repository)" : "") : "";
      })
      .filter(Boolean);
    if (!list.length) return "";
    return list.map(name => '<span class="pm-badge">' + esc(name) + "</span>").join("");
  }

  function render(practice, opts) {
    // Host-supplied [label, value] rows; drawn as plain escaped text.
    const extraRows = (opts && opts.extraRows) || [];
    const panel = document.getElementById("pmPracticeDetailsPanel");
    if (!panel || !practice) return;

    // Same fields and order Practice View has always shown. Implementation
    // Status is the practice's roll-up over its instances
    // (sp_practice_detail_get, migration 303) -- the same rule and labels
    // as the Organization Practices list.
    const rows = [
      ["Implementation Status", P(practice, "practiceImplementationStatus"), "badge"],
      ["Practice Code",         P(practice, "practiceCode")],
      ["Origin",                P(practice, "originType")],
      ["Practice Owner",        P(practice, "practiceOwner")],
      ["Applicability",         P(practice, "applicabilityStatus")],
      ["Status",                P(practice, "status")],
      ["Active Instances",      P(practice, "activeInstanceCount")],
      ...extraRows,
      // The two fields whose height grows with the data go last, as wide
      // cells, so they land in the second row's free space.
      ["Frameworks",            frameworkChips(practice), "html"],
      ["Control Statement",     sourceStatementChips(practice), "html"]
    ];
    // Third element: 'html' = chip markup built from esc()'d text,
    // 'badge' = escaped text in a pm-badge, absent = escaped text.
    document.getElementById("pmPracticeDetailsGrid").innerHTML = rows
      .filter(([, v]) => v !== null && v !== undefined && v !== "")
      .map(([k, v, kind]) => (kind === "html" ? '<div class="pm-detail-wide">' : "<div>")
        + "<dt>" + esc(k) + "</dt>"
        + (kind === "html"
            ? '<dd class="pm-chip-list">' + v + "</dd>"
            : kind === "badge"
              ? '<dd><span class="pm-badge">' + esc(v) + "</span></dd>"
              : "<dd>" + esc(v) + "</dd>")
        + "</div>")
      .join("");

    const desc = P(practice, "description");
    document.getElementById("pmPracticeDetailsDesc").textContent = desc || "";
    document.getElementById("pmPracticeDetailsDescWrap").hidden = !desc;
    panel.hidden = false;
  }

  window.gracPracticeDetails = { load, render };
})();
