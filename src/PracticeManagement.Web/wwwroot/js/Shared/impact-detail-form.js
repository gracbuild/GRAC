// =====================================================================
// DEAD CODE. NOT LOADED BY ANY PAGE. DO NOT BUILD ON THIS FILE.
//
// The narrative Impact Details feature was withdrawn -- see the banner
// on Api/Models/RiskImpactDetailModels.cs. The Web proxy routes this
// module fetches (impact-areas, impact-details, dependency-obligations)
// no longer exist. Delete it with _impact-detail-dialog.cshtml.
//
// window.gracImpactDetailForm — THE Impact Details form.
//
// Pairs with Views/Practice/Partials/_impact-detail-dialog.cshtml.
// Include that partial once on a page, load this script, and any screen
// on that page can add or edit one impact.
//
// Migration 309 / docs/risk-obligation-structure.md.
//
// WHY SHARED BEFORE IT HAS TWO CALLERS
// ------------------------------------
// Impact Details appear on five risk pages and TWO of them can add:
// Risk Analysis and Review, where the requirement is explicit that
// Review reuse "the same Impact Details fields, validation, popup/modal
// and API/database structure already used in Risk Analysis". Copying the
// form into the second page is exactly what _task-form-dialog and
// _obligation-form-dialog had to be extracted to undo, so this starts
// where those two ended up.
//
// USAGE
//   window.gracImpactDetailForm.open({
//     riskId:      123,
//     stage:       "Analysis" | "Residual" | "Review",
//     obligation:  { id, name, originCode } | null,   // null = against the risk
//     row:         <an existing impact row> | null,   // null = add
//     severities:  [ { code, name } ],                // the page's own
//                                                     // state.options.impact
//     onSaved:     result => reloadTheList()
//   });
//
//   window.gracImpactDetailForm.retire(riskId, impactDetailId)  -> Promise
//
// The caller passes DATA, not helpers: this module carries its own esc
// and option builders, the way every other screen script in this
// codebase does.
//
// WHAT IT DELIBERATELY DOES NOT SEND
// ----------------------------------
// actorEmployeeId and callerDisplayName. The Web tier's
// ForwardJsonWithCallerStampAsync strips both from whatever the client
// sent and writes the SESSION's identity instead, so sending them would
// be at best ignored and at worst an attempt to attribute an impact to
// somebody else.
//
// AND WHAT IT DOES NOT ASK
// ------------------------
// Which obligation. That is decided by the button that opened the dialog
// and is shown read-only in the header: a picker here would be the same
// question asked twice, and is how an impact ends up filed under the
// wrong obligation.
// =====================================================================
(() => {
  "use strict";

  // Resolved lazily, not captured at parse time: this script can load
  // before the layout's inline script sets window.pmPathBase, and a
  // published build under a PathBase would then post to the origin root.
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;

  // The same base risk-centre.js uses, so both tiers' routes are one
  // string in one place.
  const BASE = "/practice/api/risk-centre";

  const $ = id => document.getElementById(id);

  const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // Rows arrive camelCase from the Web tier. Same accessor the screen
  // scripts use.
  const F = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)] ?? null;

  let opts  = null;      // options of the currently open dialog
  let wired = false;
  const areaCache = new Map();   // riskId -> [{value,label}]

  function msg(text, kind) {
    const el = $("gidMsg");
    if (!el) return;
    if (!text) { el.style.display = "none"; el.textContent = ""; return; }
    el.style.display = "block";
    el.textContent = text;
    el.style.background = kind === "error" ? "#fee2e2" : kind === "ok" ? "#dcfce7" : "#dbeafe";
    el.style.color      = kind === "error" ? "#7f1d1d" : kind === "ok" ? "#166534" : "#1e40af";
  }

  function options(list, selected, blank) {
    return '<option value="">' + esc(blank) + "</option>"
      + (list || []).map(o => '<option value="' + esc(o.value) + '"'
          + (String(o.value) === String(selected ?? "") ? " selected" : "") + ">"
          + esc(o.label) + "</option>").join("");
  }

  // The page's impact options are {code,name} (they fill the score
  // dropdowns). Accepting {value,label} too costs one line and means a
  // future caller cannot get it subtly wrong.
  const normalise = list => (list || []).map(o => ({
    value: String(o.value ?? o.code ?? o.impactCode ?? ""),
    label: String(o.label ?? o.name ?? o.impactName ?? "")
  })).filter(o => o.value);

  // ===================================================================
  // Impact areas -- fetched once per risk and cached.
  //
  // An empty list is NOT an error: the dropdown shows its placeholder,
  // and the save still refuses an area that does not exist (56807). The
  // same call answers for every obligation on that risk, so opening the
  // dialog a second time costs nothing.
  // ===================================================================
  async function loadAreas(riskId) {
    if (areaCache.has(riskId)) return areaCache.get(riskId);
    let list = [];
    try {
      const r = await fetch(U(`${BASE}/register/${encodeURIComponent(riskId)}/impact-areas`),
                            { credentials: "same-origin" });
      if (r.ok) {
        const body = await r.json();
        list = (body.data || body.Data || []).map(a => ({
          value: String(F(a, "riskImpactAreaId") ?? ""),
          label: String(F(a, "areaName") || F(a, "areaCode") || "")
        })).filter(a => a.value);
      }
    } catch (err) {
      console.warn("[grac-impact-form] impact areas could not be loaded", err);
    }
    areaCache.set(riskId, list);
    return list;
  }

  // ===================================================================
  // Open / close
  // ===================================================================
  async function open(options_) {
    opts = Object.assign({ stage: "Analysis" }, options_ || {});
    wire();

    const dlg = $("gidDialog");
    const row = opts.row || null;

    $("gidHeading").textContent = row ? "Edit impact detail" : "Add impact detail";
    msg("");

    // Which obligation, said once and not asked.
    const oblName = opts.obligation ? String(opts.obligation.name || "").trim() : "";
    $("gidContext").textContent = opts.obligation
      ? "Against obligation: " + (oblName || ("#" + opts.obligation.id))
      : "Against the risk as a whole -- no obligation.";

    // Which stage is recording it. Shown because the same dialog is
    // opened from Analysis and from Review, and the row keeps whichever
    // raised it.
    $("gidStage").textContent = row
      ? "First recorded at " + (F(row, "addedStageCode") || "Analysis") + "."
      : "Will be recorded at " + opts.stage + ".";

    $("gidId").value          = String(row ? (F(row, "riskImpactDetailId") || 0) : 0);
    $("gidDescription").value = row ? (F(row, "impactDescription") || "") : "";
    $("gidAffected").value    = row ? (F(row, "affectedParty") || "") : "";
    $("gidEstimated").value   = row ? (F(row, "estimatedValue") || "") : "";
    $("gidRemarks").value     = row ? (F(row, "remarks") || "") : "";
    $("gidHorizon").value     = row ? (F(row, "timeHorizonCode") || "") : "";

    $("gidSeverity").innerHTML = options(
      normalise(opts.severities), row ? F(row, "impactCode") : "", "-- not sized yet --");

    // Areas last: it is the one asynchronous field, and the dialog opens
    // without waiting on it rather than holding shut on a round trip.
    // Cached per risk, so only the first open ever waits.
    $("gidArea").innerHTML = options([], "", "Loading...");
    loadAreas(opts.riskId).then(list => {
      $("gidArea").innerHTML = options(
        list, row ? F(row, "riskImpactAreaId") : "", "-- select --");
    });

    if (!dlg.open) dlg.showModal();
  }

  function close() {
    const dlg = $("gidDialog");
    if (dlg && dlg.open) dlg.close();
    msg("");
    opts = null;
  }

  // ===================================================================
  // Save
  // ===================================================================
  async function save() {
    if (!opts) return;

    const areaId      = $("gidArea").value;
    const description = $("gidDescription").value.trim();

    // One validation, so both calling pages refuse the same things for
    // the same reasons. The procedure refuses them too (56805 / 56806) --
    // this turns a SQL error into a sentence next to the field.
    if (!areaId)      { msg("An impact area is required.", "error"); return; }
    if (!description) { msg("A description is required.", "error"); return; }

    const btn = $("gidSave");
    if (btn.disabled) return;
    btn.disabled = true;
    msg("Saving...");

    const recordId = Number($("gidId").value || 0);
    const payload = {
      riskImpactDetailId:   recordId,
      obligationId:         opts.obligation ? Number(opts.obligation.id) : null,
      obligationName:       opts.obligation ? (opts.obligation.name || null) : null,
      obligationOriginCode: opts.obligation ? (opts.obligation.originCode || "Published") : null,
      riskImpactAreaId:     Number(areaId),
      impactDescription:    description,
      impactCode:           $("gidSeverity").value || null,
      affectedParty:        $("gidAffected").value.trim() || null,
      estimatedValue:       $("gidEstimated").value.trim() || null,
      timeHorizonCode:      $("gidHorizon").value || null,
      remarks:              $("gidRemarks").value.trim() || null,
      // Only meaningful on an add: the procedure does not rewrite it on
      // an edit, so an Analysis impact corrected during Review still
      // reads as Analysis.
      addedStageCode:       opts.stage || "Analysis"
      // No actorEmployeeId / callerDisplayName -- see the header.
    };

    try {
      const r = await fetch(U(`${BASE}/register/${encodeURIComponent(opts.riskId)}/impact-details`), {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      });
      const body = await r.json().catch(() => ({}));

      // Remember the id the server wrote even on failure, so a retry
      // edits that row instead of adding a second one.
      const savedId = Number(F(body, "riskImpactDetailId") || 0);
      if (savedId > 0) $("gidId").value = String(savedId);

      if (!r.ok || body.success === false) {
        msg(body.error || `Could not save (HTTP ${r.status}).`, "error");
        btn.disabled = false;
        return;
      }

      const done   = opts.onSaved;
      const result = { riskImpactDetailId: savedId || recordId,
                       created: !!F(body, "created"),
                       obligationId: payload.obligationId };
      close();
      if (typeof done === "function") { try { await done(result); } catch (e) { console.error(e); } }
    } catch (err) {
      console.error("[grac-impact-form] save failed", err);
      msg("Could not save the impact.", "error");
    } finally {
      // finally, not the success path: a failed save has to stay
      // retryable, and an exception must not leave a dead button.
      btn.disabled = false;
    }
  }

  // ===================================================================
  // Retire, exposed so a host's Remove button does not have to know the
  // endpoint. Confirmation is the host's -- it knows what it is removing
  // from. Throws on failure so the caller can report it.
  // ===================================================================
  async function retire(riskId, impactDetailId) {
    const r = await fetch(
      U(`${BASE}/register/${encodeURIComponent(riskId)}/impact-details/${encodeURIComponent(impactDetailId)}`),
      { method: "DELETE", credentials: "same-origin" });
    const body = await r.json().catch(() => ({}));
    if (!r.ok || body.success === false)
      throw new Error(body.error || `Could not remove (HTTP ${r.status}).`);
    return body;
  }

  // Bound once, on first open. The dialog markup is static, so there is
  // nothing to re-bind and no listener to leak.
  //
  // No backdrop dismissal: half-filled work should not vanish on a stray
  // click. Esc is routed through close() so the dialog is not a trap.
  function wire() {
    if (wired) return;
    wired = true;
    $("gidClose")?.addEventListener("click", close);
    $("gidCancel")?.addEventListener("click", close);
    $("gidSave")?.addEventListener("click", save);
    $("gidDialog")?.addEventListener("cancel", e => { e.preventDefault(); close(); });
  }

  window.gracImpactDetailForm = { open, close, retire };
})();
