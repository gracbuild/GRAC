// =====================================================================
// Risk Acceptance Approval Authority -- migration 271.
// Loaded by Views/Practice/Partials/risk-acceptance-authority.cshtml.
//
// Organization -> Risk Acceptance Approval Authority.
//
// THE LEVELS COME FROM THE SERVER, NOT FROM HERE.
// There is deliberately no rating vocabulary in this file. The rows are
// whatever sp_org_risk_acceptance_authority_get derives from the
// organisation's own risk_matrix_cell -- four on a default matrix, five
// on a five-band one. A list here would be a second place for the
// vocabulary to live and the first place for it to drift.
//
// THE FALLBACK IS SHOWN, NOT HIDDEN.
// A level with no configured role is not unapproved: 212's
// approver_role_id still applies. Rows in that state say so, because a
// blank dropdown that silently means "someone else decides" is worse
// than no page at all.
//
// Auth: /practice/api/risk-centre/* enforces session + org isolation.
// Hiding or disabling anything here removes a control, never a check.
// =====================================================================
(() => {
  "use strict";

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const API      = "/practice/api/risk-centre/acceptance-authority";
  const ORGS_API = "/practice/api/organizations/allowed";

  const state = {
    orgId    : null,
    levels   : [],     // as loaded, for Discard changes
    roles    : [],
    fallback : null
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("raaRoot")) return;
    bindEvents();
    await populateOrgs();

    const sel = document.getElementById("raaPickOrg");
    if (sel && sel.options.length > 1) {
      sel.selectedIndex = 1;
      state.orgId = Number(sel.value) || null;
      await load();
    }
  }

  function bindEvents() {
    document.getElementById("raaPickOrg").addEventListener("change", async ev => {
      state.orgId = Number(ev.target.value) || null;
      await load();
    });
    document.getElementById("raaReloadBtn").addEventListener("click", load);
    document.getElementById("raaResetBtn").addEventListener("click", () => {
      render();                       // re-render from the loaded state
      msg("Changes discarded.", "info");
    });
    document.getElementById("raaSaveBtn").addEventListener("click", save);

    // Delegated: the grid is re-rendered on every load, so per-control
    // listeners would need rebinding each time.
    document.getElementById("raaTableBody").addEventListener("change", ev => {
      const tr = ev.target.closest("tr");
      if (tr) tr.classList.add("raa-dirty");

      // "Same as inherent" owns the residual dropdown. Disabled rather
      // than hidden, so the row keeps its shape and the reader can see
      // what it would fall back to being.
      if (ev.target.matches(".raa-same")) {
        const sel = tr?.querySelector(".raa-residual");
        if (sel) {
          sel.disabled = ev.target.checked;
          if (ev.target.checked) sel.value = "";
        }
      }
    });
  }

  // The endpoint answers { data: [...] }, NOT a bare array, and the
  // casing varies with the serializer -- hence the four-way read below.
  // This is copied from org-sla-config.js's populateOrgs rather than
  // re-derived: it is the same feed, and the first version of this
  // function guessed a bare array, got nothing, and reported
  // "Organizations could not be loaded" for a response that was fine.
  async function populateOrgs() {
    const sel = document.getElementById("raaPickOrg");
    sel.innerHTML = `<option value="">Select organization</option>`;

    let rows = [];
    let failed = false;
    try {
      const r = await fetch(U(ORGS_API), { credentials: "same-origin" });
      if (r.ok) {
        const b = await r.json();
        rows = (b && (b.data || b.Data)) || [];
      } else {
        failed = true;
        // 401 is its own thing: the session has gone, and telling the
        // user "organizations could not be loaded" would send them
        // looking for a data problem instead of signing back in.
        if (r.status === 401) {
          sel.innerHTML = `<option value="">Session expired — sign in again</option>`;
          msg("Your session has expired. Sign in again to load organizations.", "error");
          return;
        }
      }
    } catch (_) {
      failed = true;
    }

    if (failed) {
      sel.innerHTML = `<option value="">Organizations could not be loaded</option>`;
      msg("Organizations could not be loaded. Check that the API is reachable.", "error");
      return;
    }

    rows.forEach(row => {
      const value = String(row.organizationId ?? row.OrganizationId ?? "");
      const label = String(row.organizationName ?? row.OrganizationName ?? "");
      if (!value) return;
      const opt = document.createElement("option");
      opt.value = value;
      opt.textContent = label;
      sel.appendChild(opt);
    });

    // An empty list is not a failure -- it means this user is mapped to
    // no organization. Said plainly rather than left as an empty picker.
    if (!rows.length)
      msg("You are not mapped to any organization, so there is nothing to configure.", "info");
  }

  async function load() {
    const body = document.getElementById("raaTableBody");
    if (!state.orgId) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">Select an organization.</td></tr>`;
      document.getElementById("raaFallback").style.display = "none";
      return;
    }
    body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">Loading...</td></tr>`;
    msg("");

    try {
      const r = await fetch(U(`${API}?organizationId=${encodeURIComponent(state.orgId)}`),
                            { credentials: "same-origin" });
      const d = await r.json().catch(() => ({}));
      if (!r.ok || d.success === false) {
        body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">`
          + `Could not load the configuration: ${esc(d.error || ("HTTP " + r.status))}</td></tr>`;
        return;
      }
      state.levels   = d.levels   || [];
      state.roles    = d.roles    || [];
      state.fallback = d.fallback || null;
      render();
    } catch (err) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">Network error: ${esc(err.message)}</td></tr>`;
    }
  }

  function render() {
    const body = document.getElementById("raaTableBody");
    const fb   = document.getElementById("raaFallback");

    // What applies where nothing is configured. Stated before the grid,
    // because it is the answer for every blank row in it.
    if (state.fallback) {
      const f = state.fallback;
      fb.style.display = "block";

      // ONE MESSAGE, IN PRECEDENCE ORDER.
      //
      // These were previously two sentences shown together, and they
      // contradicted each other: the first explained what an unset level
      // falls back to, the second said none of it applied because
      // approval was switched off. Explaining a rule and then retracting
      // it in the same breath is worse than saying nothing.
      //
      // So the most decisive fact wins, and it is the only one shown:
      //
      //   1. approval off       nothing here is enforced yet -- that is
      //                         the only thing worth acting on, so the
      //                         fallback detail is not raised at all
      //   2. no general role    unset levels are open to any authorised
      //                         user (212: "NULL = any user the API lets
      //                         through", and the settings dropdown
      //                         calls it "Any authorised user")
      //   3. a general role     unset levels fall back to it
      if (f.approvalRequired === false) {
        fb.className = "raa-note is-blocked";
        fb.innerHTML =
            `<strong>Risk approval is switched off for this organisation.</strong> `
          + `Authorities set here are saved, but nothing enforces them until approval `
          + `is enabled in Risk Centre settings.`;
      } else if (!f.fallbackRoleId) {
        fb.className = "raa-note";
        fb.innerHTML =
            `No general risk approver is set, so a level left unset below is open to `
          + `<strong>any authorised user</strong>. Set a role per level to restrict it.`;
      } else {
        fb.className = "raa-note";
        fb.innerHTML =
            `Levels left unset fall back to the organisation's general risk approver: `
          + `<strong>${esc(f.fallbackRoleName)}</strong>.`;
      }
    } else {
      fb.style.display = "none";
    }

    if (!state.levels.length) {
      body.innerHTML = `<tr><td colspan="4" class="pm-empty-row">`
        + `This organisation's risk matrix has not been set up, so there are no rating `
        + `levels to configure yet. Seed the risk scoring matrix first.</td></tr>`;
      return;
    }

    const opts = (sel) =>
      `<option value="">-- not set --</option>`
      + state.roles.map(r =>
          `<option value="${r.roleId}"${String(r.roleId) === String(sel || "") ? " selected" : ""}>`
          + `${esc(r.roleName)}</option>`).join("");

    body.innerHTML = state.levels.map(l => {
      const same = !!l.residualSameAsInherent;
      return `<tr data-rating="${esc(l.ratingCode)}">
        <td>
          <span class="raa-level">${esc(l.ratingName || l.ratingCode)}</span>
        </td>
        <td>
          <select class="raa-inherent">${opts(l.inherentRoleId)}</select>
          ${l.inherentUsesFallback && l.effectiveInherentRoleName
              ? `<span class="raa-fallback">Currently ${esc(l.effectiveInherentRoleName)} (organisation default)</span>`
              : ""}
        </td>
        <td class="raa-same-cell">
          <input type="checkbox" class="raa-same"${same ? " checked" : ""}
                 aria-label="Residual same as inherent for ${esc(l.ratingCode)}" />
        </td>
        <td>
          <select class="raa-residual"${same ? " disabled" : ""}>${opts(l.residualRoleId)}</select>
          ${!same && l.residualUsesFallback && l.effectiveResidualRoleName
              ? `<span class="raa-fallback">Currently ${esc(l.effectiveResidualRoleName)} (organisation default)</span>`
              : ""}
        </td>
      </tr>`;
    }).join("");
  }

  async function save() {
    if (!state.orgId) { msg("Select an organization first.", "error"); return; }

    const rows = Array.from(document.querySelectorAll("#raaTableBody tr[data-rating]")).map(tr => {
      const same = tr.querySelector(".raa-same")?.checked || false;
      const inh  = tr.querySelector(".raa-inherent")?.value || "";
      const res  = tr.querySelector(".raa-residual")?.value || "";
      return {
        ratingCode: tr.getAttribute("data-rating"),
        inherentRoleId: inh ? Number(inh) : null,
        // Deliberately null when "same as inherent": the flag is the
        // instruction, and sending a role alongside it would be two
        // answers to one question.
        residualRoleId: same ? null : (res ? Number(res) : null),
        residualSameAsInherent: same
      };
    });

    if (!rows.length) { msg("There is nothing to save.", "error"); return; }

    // Checked here as well as in SQL (56747) so the message names the
    // levels before a round trip. The rule is the server's.
    const orphan = rows.filter(r => r.residualSameAsInherent && !r.inherentRoleId)
                       .map(r => r.ratingCode);
    if (orphan.length) {
      msg(`"Same as inherent" needs an inherent approver for: ${orphan.join(", ")}. `
        + `Set the inherent authority for those levels first.`, "error");
      return;
    }

    const btn = document.getElementById("raaSaveBtn");
    btn.disabled = true;
    msg("Saving...", "info");

    try {
      const r = await fetch(U(API), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({ organizationId: state.orgId, rows })
      });
      const d = await r.json().catch(() => ({}));
      btn.disabled = false;

      if (!r.ok || d.success === false) {
        msg(d.error || `Save failed (HTTP ${r.status}).`, "error");
        return;
      }

      // The response is the configuration AS STORED -- the procedure
      // re-reads it -- so re-rendering from it shows what was actually
      // saved rather than what was sent.
      state.levels   = d.levels   || [];
      state.roles    = d.roles    || [];
      state.fallback = d.fallback || null;
      render();
      msg("Approval authority saved.", "ok");
    } catch (err) {
      btn.disabled = false;
      msg(`Network error: ${err.message}`, "error");
    }
  }

  function msg(text, kind) {
    const el = document.getElementById("raaMessage");
    if (!el) return;
    if (!text) { el.hidden = true; el.textContent = ""; return; }
    el.hidden = false;
    el.textContent = text;
    el.style.background = kind === "error" ? "#fef2f2" : kind === "ok" ? "#ecfdf5" : "#eff6ff";
    el.style.color      = kind === "error" ? "#b91c1c" : kind === "ok" ? "#065f46" : "#1e40af";
    el.style.border     = "1px solid " + (kind === "error" ? "#fecaca" : kind === "ok" ? "#a7f3d0" : "#bfdbfe");
  }

  function esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
