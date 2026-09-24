/* =====================================================================
   Scope checklist editor (migrations 123-137)

   One editor, three hosts:
     * Role Master's Add/Edit form, via practice.js   -> ORG_ROLE
     * the Asset Category Assurance screen            -> ASSET_CATEGORY
     * the Event Profiles screen (329-332)            -> PROFILE

   PROFILE shows the inherited-obligation half only -- see
   SUPPORTS_CUSTOM_QUESTIONS below for why.

   WHY THIS IS ITS OWN FILE
   -----------------------
   Views/Practice/Manage.cshtml renders workflow-layer screens through their
   own partial and RETURNS before the <script src="practice.js"> tag. So a
   screen registered in workflowScreens never loads practice.js, and anything
   defined inside its IIFE is out of reach there. Keeping the editor in
   practice.js would have meant copying ~250 lines into the asset screen --
   two implementations of the same thing, drifting from the first bug fix
   onwards. Manage.cshtml loads this file before that early return, so both
   hosts get the same code.

   Public API:
     __scopeChecklistEditor.render(host, opts)
         opts = { organizationId, scopeDimension, scopeValueId, title, subtitle }
         scopeValueId may be falsy -- see "who saves" below.
     __scopeChecklistEditor.flushPending(scopeValueId) -> {saved, failed}
         Writes what was held while the record had no id.
     __scopeChecklistEditor.isBuffering()
     __scopeChecklistEditor.hasUnsavedChanges() / .unsavedCount()

   TICKING STAGES, IT DOES NOT SAVE
   --------------------------------
   Every tick used to be its own POST. Configuring a scope meant a round
   trip per checkbox, a "Saved." flash per checkbox, and no way to change
   your mind before committing -- untick something by accident and it was
   already an auditable "not applicable" decision on the record.

   Now a tick only stages the change. The panel shows how many are
   unsaved, each touched row is marked, and ONE Save writes them all.

   The "not applicable" reason is still asked at the moment of unticking,
   not at Save: it is per obligation, and asking for five reasons in a row
   after the fact -- with no indication of which row each belongs to --
   would be worse. The reason is held with the staged change and written
   with it.

   WHO SAVES
   ---------
   Which obligations reach an organization depends on the organization,
   the event and the subscribed releases -- not on the role or category.
   So the list renders before the record exists (migration 137 allows the
   query without a scope value) and every row comes back Unmapped.

     scopeValueId present -> this editor shows its own Save bar and writes.
     scopeValueId falsy   -> there is no id to write against yet, so the
                             HOST's Save owns it and calls flushPending
                             once the record has an id. No Save bar is
                             rendered, because two buttons claiming the
                             same job is worse than one.

   Writing optimistically in that second case would leave orphaned
   mappings behind whenever an Add is cancelled.

   Custom questions (the "your own checklists" half) are NOT staged: each
   is an explicit Add or Remove press, already a deliberate single action,
   and buffering a delete of an already-stored row buys nothing.
   ===================================================================== */
(function () {
  "use strict";
  if (window.__scopeChecklistEditor) return;

  const appBasePath = () => (window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const url = path => `${appBasePath()}/${String(path).replace(/^\/+/, "")}`;
  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";
  const esc = value => String(value ?? "").replace(/[&<>"']/g, ch =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);

  const SCOPE_EVENTS = {
    ORG_ROLE: [
      { code: "PEOPLE_ONBOARDING",  label: "Onboarding"  },
      { code: "PEOPLE_OFFBOARDING", label: "Offboarding" }
    ],
    ASSET_CATEGORY: [
      { code: "ASSET_COMMISSIONING",   label: "Commissioning"   },
      { code: "ASSET_DECOMMISSIONING", label: "Decommissioning" }
    ],
    // Migration 329-331. A Profile is a people population, so it gets the
    // same two events as ORG_ROLE -- it replaces the role as the thing
    // scoped, not the events scoped to it.
    PROFILE: [
      { code: "PEOPLE_ONBOARDING",  label: "Onboarding"  },
      { code: "PEOPLE_OFFBOARDING", label: "Offboarding" }
    ]
  };

  // Custom (organization-authored) questions are stored as checklist rows
  // keyed by scope_role_id / scope_asset_category_id and served through
  // the CHECKLIST raise path, which is a different engine from the
  // obligation path profiles extend. Until checklist and
  // event_checklist_mapping carry profile_id, the panel is hidden for
  // PROFILE rather than shown and silently saving nothing.
  const SUPPORTS_CUSTOM_QUESTIONS = { ORG_ROLE: true, ASSET_CATEGORY: true, PROFILE: false };

  // buffering === "the host owns the Save button", i.e. the record has no
  // id yet (a role being added). Obligation ticks are staged in BOTH modes
  // now -- the difference is only who writes them: this editor's own Save
  // button, or the host calling flushPending once the record exists.
  const pending = { buffering: false, obligations: [], questions: [], opts: null };

  // "Is this obligation on?" -- Mapped is the only stored state that means
  // applicable; Unmapped, NotApplicable and Inactive all read as off.
  const isOn = m => m.mappingState === "Mapped";

  // An obligation's identity is one of three columns, never obligationId
  // alone (migration 343): a catalog row has no local identity, a custom
  // one (practice-level or instance-only) has no GRAC_New id. Same
  // letter-prefixed composite key the SQL side uses
  // (COALESCE('C'+.., 'P'+.., 'I'+..) in sp_event_obligation_coverage_list)
  // so a catalog id, a practice-level id and an instance-level id that
  // happen to share a number never collide here either.
  function obligationKey(m) {
    if (m.obligationId != null) return "C" + m.obligationId;
    if (m.localPracticeObligationId != null) return "P" + m.localPracticeObligationId;
    if (m.localInstanceObligationId != null) return "I" + m.localInstanceObligationId;
    return null;
  }

  function obligationDisplayId(m) {
    if (m.obligationId != null) return "#" + m.obligationId;
    if (m.localPracticeObligationId != null) return "Practice #" + m.localPracticeObligationId;
    if (m.localInstanceObligationId != null) return "Instance #" + m.localInstanceObligationId;
    return "?";
  }

  const stagedFor = m => {
    const key = obligationKey(m);
    return pending.obligations.find(t => obligationKey(t) === key) || null;
  };

  function stage(entry) {
    const key = obligationKey(entry);
    const at = pending.obligations.findIndex(t => obligationKey(t) === key);
    if (at >= 0) pending.obligations[at] = entry; else pending.obligations.push(entry);
  }

  function unstage(m) {
    const key = obligationKey(m);
    const at = pending.obligations.findIndex(t => obligationKey(t) === key);
    if (at >= 0) pending.obligations.splice(at, 1);
  }

  const dirtyCount = () => pending.obligations.length;

  // ------------------------------------------------------------------
  function scopeQuery(opts) {
    const parts = ["organizationId=" + encodeURIComponent(opts.organizationId || ""),
                   "scopeDimension=" + encodeURIComponent(opts.scopeDimension)];
    // Omit the scope value entirely when there is none. Sending
    // "scopeRoleId=undefined" fails model binding on a long? and the request
    // comes back 400.
    if (opts.scopeValueId) {
      const key = opts.scopeDimension === "ORG_ROLE"       ? "scopeRoleId="
                : opts.scopeDimension === "ASSET_CATEGORY" ? "scopeAssetCategoryId="
                : "profileId=";
      parts.push(key + encodeURIComponent(opts.scopeValueId));
    }
    return parts.join("&");
  }

  function msg(container, text, kind) {
    const el = container?.querySelector("[data-scope-message]");
    if (!el) return;
    if (!text) { el.style.display = "none"; el.textContent = ""; return; }
    el.style.display = "block"; el.textContent = text;
    if (kind === "error")   { el.style.background = "#fee2e2"; el.style.color = "#7f1d1d"; }
    else if (kind === "ok") { el.style.background = "#dcfce7"; el.style.color = "#166534"; }
    else                    { el.style.background = "#dbeafe"; el.style.color = "#1e40af"; }
  }

  // ------------------------------------------------------------------
  // The Save bar. Shown only when there IS something to save against --
  // a record still being added has no id, so its host's own Save owns the
  // write (see flushPending) and a second Save button here would be two
  // buttons claiming the same job.
  // ------------------------------------------------------------------
  function saveBarMarkup() {
    return `<div data-scope-savebar
                 style="display:flex; align-items:center; justify-content:flex-end; gap:12px;
                        margin-top:14px; padding-top:12px; border-top:1px solid #e2e8f0;">
              <span data-scope-dirty style="font-size:12px; color:#64748b;"></span>
              <button type="button" class="pm-button primary" data-scope-save disabled>Save changes</button>
            </div>`;
  }

  function refreshSaveBar(container, opts) {
    const bar = container?.querySelector("[data-scope-savebar]");
    const n = dirtyCount();

    if (!bar) {
      // Buffering host: no bar of our own, but the running count still
      // belongs on screen so "nothing happened" is never the impression.
      const note = container?.querySelector("[data-scope-holdnote]");
      if (note) {
        note.textContent = n
          ? `${n} change(s) held — written when you press Save on this form.`
          : "Nothing changed yet. Ticks here are written when you press Save on this form.";
      }
      return;
    }

    const btn   = bar.querySelector("[data-scope-save]");
    const label = bar.querySelector("[data-scope-dirty]");
    btn.disabled = n === 0;
    label.textContent = n === 0 ? "No unsaved changes" : `${n} unsaved change(s)`;
    label.style.color = n === 0 ? "#64748b" : "#78350f";
  }

  // Writes every staged change, then reloads so the panel shows what the
  // database actually holds rather than what we hoped it would.
  async function saveAll(container, opts) {
    const btn = container.querySelector("[data-scope-save]");
    if (!dirtyCount()) return;

    if (btn) { btn.disabled = true; btn.textContent = "Saving..."; }
    msg(container, "Saving...", "info");

    let saved = 0;
    const failed = [];
    for (const t of pending.obligations.slice()) {
      if (await postObligation(opts, t)) {
        saved++;
        unstage(t);
      } else {
        failed.push(t);
      }
    }

    if (btn) btn.textContent = "Save changes";

    // A partial failure keeps its rows staged, so Save can be pressed
    // again for just those. Reporting "saved" for a partial write is how
    // somebody leaves believing a checklist was configured when it wasn't.
    if (failed.length) {
      msg(container, `${saved} change(s) saved, ${failed.length} could not be written. `
                   + "The rows still marked unsaved were not applied — try Save again.", "error");
    } else {
      msg(container, `${saved} change(s) saved.`, "ok");
      setTimeout(function () { msg(container, null); }, 2500);
    }

    await reloadObligationPanels(container, opts);
    refreshSaveBar(container, opts);
  }

  // Re-fetch every event panel's obligation list from the server.
  async function reloadObligationPanels(container, opts) {
    const events = SCOPE_EVENTS[opts.scopeDimension] || [];
    for (const ev of events) {
      const panel = container.querySelector(`[data-scope-panel="${ev.code}"]`);
      if (panel) await loadObligations(container, opts, ev.code, panel.querySelector("[data-scope-obligations]"));
    }
  }

  // ------------------------------------------------------------------
  async function render(host, opts) {
    if (!host) return;

    // Re-rendering means the scope changed (another role, category or
    // profile). Anything staged belonged to the PREVIOUS scope and cannot
    // be carried over, so it is dropped -- but said out loud, because
    // silently discarding a screenful of ticks is exactly the kind of
    // thing that gets reported as "it did not save".
    const discarded = dirtyCount();
    pending.obligations = [];
    pending.questions   = [];

    host.querySelector("[data-scope-checklist]")?.remove();

    const events = SCOPE_EVENTS[opts.scopeDimension] || [];
    if (!events.length) return;

    const container = document.createElement("section");
    container.className = "pm-inline-obligations";
    container.setAttribute("data-scope-checklist", "1");
    container.innerHTML = `
      <div class="pm-inline-obligations-header">
        <div>
          <h3>${esc(opts.title || "Event Checklists")}</h3>
          <p>${esc(opts.subtitle || "Tick the obligations that apply, then press Save changes.")}</p>
        </div>
      </div>
      <div class="pm-tabs" role="tablist" data-scope-tabs>
        ${events.map((e, i) => `<button type="button" role="tab" data-scope-tab="${esc(e.code)}"
            class="${i === 0 ? "active" : ""}" aria-selected="${i === 0 ? "true" : "false"}">${esc(e.label)}</button>`).join("")}
      </div>
      <div data-scope-message style="display:none; margin:8px 0; padding:8px 12px; border-radius:4px; font-size:13px;"></div>
      ${events.map((e, i) => `<div data-scope-panel="${esc(e.code)}" ${i === 0 ? "" : "hidden"}>
            <div data-scope-obligations><div class="pm-obligation-empty">Loading obligations...</div></div>
            <div data-scope-questions style="margin-top:14px;"></div>
         </div>`).join("")}
      ${opts.scopeValueId ? saveBarMarkup() : ""}`;
    host.appendChild(container);

    pending.buffering = !opts.scopeValueId;
    pending.opts = opts;

    if (pending.buffering) {
      // No id yet, so nothing can be written against it. The host's own
      // Save does it, via flushPending.
      const note = document.createElement("p");
      note.setAttribute("data-scope-holdnote", "1");
      note.style.cssText = "margin:6px 0 0 0; font-size:12px; color:#78350f;";
      note.textContent = "Nothing changed yet. Ticks here are written when you press Save on this form.";
      container.querySelector(".pm-tabs").insertAdjacentElement("afterend", note);
    } else {
      container.querySelector("[data-scope-save]")
              ?.addEventListener("click", function () { saveAll(container, opts); });
    }

    refreshSaveBar(container, opts);
    if (discarded) {
      msg(container, `${discarded} unsaved change(s) from the previous selection were discarded.`, "error");
    }

    container.querySelectorAll("[data-scope-tab]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        const code = btn.getAttribute("data-scope-tab");
        container.querySelectorAll("[data-scope-tab]").forEach(function (b) {
          const on = b === btn;
          b.classList.toggle("active", on);
          b.setAttribute("aria-selected", on ? "true" : "false");
        });
        container.querySelectorAll("[data-scope-panel]").forEach(function (p) {
          p.hidden = p.getAttribute("data-scope-panel") !== code;
        });
      });
    });

    // The organization can still change on an Add form after this rendered.
    // Without this the list would keep showing whichever organization was
    // selected first -- and its obligations mapped to the wrong record.
    const orgSelect = host.querySelector("[name='organizationId']");
    if (orgSelect && orgSelect.dataset.scopeRewired !== "1") {
      orgSelect.dataset.scopeRewired = "1";
      orgSelect.addEventListener("change", function () {
        render(host, Object.assign({}, opts, { organizationId: orgSelect.value }));
      });
    }

    for (const ev of events) {
      const panel = container.querySelector(`[data-scope-panel="${ev.code}"]`);
      await Promise.all([
        loadObligations(container, opts, ev.code, panel.querySelector("[data-scope-obligations]")),
        loadQuestions(container, opts, ev.code, panel.querySelector("[data-scope-questions]"))
      ]);
    }
  }

  // ------------------------------------------------------------------
  async function loadObligations(container, opts, eventCode, host) {
    if (!host) return;
    if (!opts.organizationId) {
      host.innerHTML = `<div class="pm-obligation-empty">Choose an organization first — the obligations depend on what it subscribes to.</div>`;
      return;
    }
    host.innerHTML = `<div class="pm-obligation-empty">Loading obligations...</div>`;

    let rows = [];
    try {
      const r = await fetch(url("practice/api/workflow/scope/obligation-mappings?" + scopeQuery(opts)
                + "&eventTypeCode=" + encodeURIComponent(eventCode)), { credentials: "same-origin" });
      const b = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        // Carry the status through: a bare failure message gave no way to
        // tell a 400 from a 403 from a 502.
        host.innerHTML = `<div class="pm-obligation-empty">Could not load obligations (HTTP ${r.status})${
          b.error ? ": " + esc(b.error) : ""}</div>`;
        return;
      }
      rows = (b && b.rows) || [];
    } catch (err) {
      host.innerHTML = `<div class="pm-obligation-empty">Failed: ${esc(err.message)}</div>`;
      return;
    }

    if (!rows.length) {
      host.innerHTML = `<div class="pm-obligation-empty">No event-driven obligations reach this organization for this event. Check the obligation's trigger in GRAC-ADMIN, that the practice is Applicable, and that the release is subscribed.</div>`;
      return;
    }

    host.innerHTML = `<h4 style="margin:4px 0 8px 0; font-size:13px; color:#334155;">Inherited obligations</h4>`;
    rows.forEach(function (m) {
      const row = document.createElement("label");
      row.style.cssText = "display:flex; gap:8px; align-items:flex-start; padding:6px 0; border-bottom:1px solid #f1f5f9; font-size:13px;";
      const cb = document.createElement("input");
      cb.type = "checkbox";
      // A staged change wins over the stored state: re-rendering a tab must
      // not quietly revert what the user has ticked but not yet saved.
      const staged = stagedFor(m);
      cb.checked  = staged ? staged.isApplicable : isOn(m);
      cb.disabled = !m.isSubscribed;
      cb.style.marginTop = "3px";
      cb.addEventListener("change", function () { stageObligation(container, opts, eventCode, m, cb, row); });
      row.appendChild(cb);
      // Migration 340-344: an organisation-authored (Custom) obligation
      // reaches this panel exactly like a catalog one now -- the badge only
      // tells the admin which kind they are ticking, it changes nothing
      // about how the tick is staged or saved.
      const kindBadge = m.obligationKind && m.obligationKind !== "Catalog"
        ? `<span style="color:#6d28d9; font-size:10px; border:1px solid #ddd6fe; background:#f5f3ff;
                 border-radius:3px; padding:0 4px; margin-left:4px; vertical-align:1px;">Custom</span>`
        : "";
      row.insertAdjacentHTML("beforeend",
        `<span>${esc(m.obligationLabel || ("Obligation " + obligationDisplayId(m)))}${kindBadge}
           ${m.isSubscribed ? "" : `<span style="color:#b91c1c; font-size:11px;">not subscribed</span>`}
           ${m.practiceCode ? `<br><span style="font-size:11px; color:#94a3b8;">${esc(m.practiceCode)}</span>` : ""}
           ${m.rationale ? `<br><span style="font-size:11px; color:#78350f;">N/A: ${esc(m.rationale)}</span>` : ""}
           <span data-staged-flag style="display:none; font-size:11px; color:#78350f;"><br>Not saved yet</span>
         </span>`);
      host.appendChild(row);
      markRow(row, !!staged);
    });
  }

  // A row the user has touched but not yet saved. Marked rather than
  // silently identical to a stored one -- the whole point of batching is
  // that the screen and the database differ for a while, and that has to
  // be visible.
  function markRow(row, dirty) {
    if (!row) return;
    row.style.background = dirty ? "#fffbeb" : "";
    const flag = row.querySelector("[data-staged-flag]");
    if (flag) flag.style.display = dirty ? "inline" : "none";
  }

  // Ticking STAGES a change; it does not write one. Every tick used to be
  // its own POST, so configuring a scope meant a round trip per checkbox
  // and there was no way to change your mind before committing. Now the
  // whole panel is one decision, written by Save.
  //
  // A tick back to the stored value drops the entry entirely rather than
  // staging a no-op write, so Save only ever sends real changes and the
  // dirty count is the truth.
  async function stageObligation(container, opts, eventCode, m, checkbox, row) {
    const original = isOn(m);

    if (checkbox.checked === original) {
      unstage(m);
      markRow(row, false);
      refreshSaveBar(container, opts);
      return;
    }

    // Unticking records an explicit "not applicable" decision with a
    // reason. An auditor asks why a check is missing, and that answer has
    // to be stored -- so it is collected now, while the user knows which
    // obligation they just turned off, and written with the rest on Save.
    let rationale = null;
    if (!checkbox.checked) {
      rationale = await window.gracUi.prompt(
        "Why is this obligation not applicable for this scope? An auditor will read this.",
        { title: "Not applicable", inputLabel: "Reason", confirmText: "Continue" });
      if (rationale === null || !rationale.trim()) {
        checkbox.checked = original;
        unstage(m);
        markRow(row, false);
        refreshSaveBar(container, opts);
        msg(container, "Not applicable needs a reason; that row was left as it was.", "error");
        return;
      }
      rationale = rationale.trim();
    }

    // Migration 343: the whole identity travels with the staged entry, not
    // just obligationId -- a custom row has that column NULL and one of the
    // other two set instead.
    stage({ obligationId: m.obligationId,
            localPracticeObligationId: m.localPracticeObligationId,
            localInstanceObligationId: m.localInstanceObligationId,
            eventTypeId: m.eventTypeId,
            isApplicable: checkbox.checked, rationale: rationale, eventCode: eventCode });
    markRow(row, true);
    refreshSaveBar(container, opts);
  }

  // ------------------------------------------------------------------
  async function loadQuestions(container, opts, eventCode, host) {
    if (!host) return;

    // See SUPPORTS_CUSTOM_QUESTIONS at the top. The panel is removed, not
    // disabled: a greyed-out Add box invites a bug report, an absent one
    // matches the endpoint that genuinely does not accept this scope.
    if (SUPPORTS_CUSTOM_QUESTIONS[opts.scopeDimension] === false) {
      host.innerHTML = "";
      host.hidden = true;
      return;
    }
    host.hidden = false;

    let rows = [];
    if (pending.buffering) {
      rows = pending.questions
        .filter(function (q) { return q.eventCode === eventCode; })
        .map(function (q, i) { return { checklistItemId: -(i + 1), questionText: q.text, isMandatory: q.isMandatory }; });
    } else if (opts.organizationId && opts.scopeValueId) {
      try {
        const r = await fetch(url("practice/api/workflow/scope/questions?" + scopeQuery(opts)
                  + "&eventTypeCode=" + encodeURIComponent(eventCode)), { credentials: "same-origin" });
        if (r.ok) { const b = await r.json(); rows = (b && b.rows) || []; }
      } catch (_) { /* fall through to an empty list */ }
    }

    host.innerHTML = `<h4 style="margin:4px 0 8px 0; font-size:13px; color:#334155;">Your own checklists</h4>
      <div data-scope-question-list></div>
      <div style="display:flex; gap:6px; margin-top:8px;">
        <input data-scope-new-question type="text" maxlength="500" placeholder="Add a checklist for this event..."
               style="flex:1; padding:6px 8px; border:1px solid #cbd5e1; border-radius:4px; font-size:13px;" />
        <label style="display:flex; align-items:center; gap:4px; font-size:12px; color:#475569;">
          <input data-scope-new-mandatory type="checkbox" checked /> Mandatory
        </label>
        <button type="button" class="pm-button" data-scope-add>Add</button>
      </div>`;

    const list = host.querySelector("[data-scope-question-list]");
    if (!rows.length) {
      list.innerHTML = `<div class="pm-obligation-empty" style="padding:4px 0;">No custom checklists yet.</div>`;
    } else {
      rows.forEach(function (q) {
        const row = document.createElement("div");
        row.style.cssText = "display:flex; gap:8px; align-items:center; padding:6px 0; border-bottom:1px solid #f1f5f9; font-size:13px;";
        row.insertAdjacentHTML("beforeend",
          `<span style="flex:1;">${esc(q.questionText)}${q.isMandatory ? `<span style="color:#b91c1c;"> *</span>` : ""}</span>`);
        const del = document.createElement("button");
        del.type = "button"; del.className = "pm-button"; del.textContent = "Remove";
        del.addEventListener("click", function () { removeQuestion(container, opts, eventCode, q, host); });
        row.appendChild(del);
        list.appendChild(row);
      });
    }

    host.querySelector("[data-scope-add]").addEventListener("click", function () {
      addQuestion(container, opts, eventCode, host);
    });
  }

  async function addQuestion(container, opts, eventCode, host) {
    const input = host.querySelector("[data-scope-new-question]");
    const mandatory = host.querySelector("[data-scope-new-mandatory]");
    const text = (input.value || "").trim();
    if (!text) { msg(container, "Type the checklist first.", "error"); return; }

    if (pending.buffering) {
      pending.questions.push({ eventCode: eventCode, text: text, isMandatory: !!mandatory.checked });
      input.value = "";
      msg(container, "Held — saved with the record.", "info");
      setTimeout(function () { msg(container, null); }, 1500);
      await loadQuestions(container, opts, eventCode, host);
      return;
    }

    const ok = await postQuestion(opts, eventCode, text, !!mandatory.checked);
    if (!ok) { msg(container, "Could not add the checklist", "error"); return; }
    input.value = "";
    msg(container, "Checklist added.", "ok");
    setTimeout(function () { msg(container, null); }, 1500);
    await loadQuestions(container, opts, eventCode, host);
  }

  async function removeQuestion(container, opts, eventCode, q, host) {
    // Held items were never written, so removing one is just dropping it.
    if (pending.buffering) {
      const idx = -q.checklistItemId - 1;
      const forEvent = pending.questions.filter(function (x) { return x.eventCode === eventCode; });
      const target = forEvent[idx];
      if (target) pending.questions.splice(pending.questions.indexOf(target), 1);
      await loadQuestions(container, opts, eventCode, host);
      return;
    }
    if (!await window.gracUi.confirm(
          "Remove this checklist from future events? Answers already recorded against it are kept.",
          { type: "warning", title: "Remove checklist", confirmText: "Remove" })) return;
    try {
      const r = await fetch(url("practice/api/workflow/scope/questions/delete"), {
        method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({ organizationId: Number(opts.organizationId), checklistItemId: q.checklistItemId })
      });
      const b = await r.json().catch(function () { return {}; });
      if (!r.ok) { msg(container, b.error || "Could not remove the checklist", "error"); return; }
      await loadQuestions(container, opts, eventCode, host);
    } catch (err) {
      msg(container, "Network error: " + err.message, "error");
    }
  }

  // ------------------------------------------------------------------
  // entry carries whichever of the three identity fields the row has --
  // exactly one, mirroring the composite identity 341/343 established on
  // the database side. A custom obligation's obligationId is null here on
  // purpose; sending null (not 0) is what lets the API and the procedure
  // tell "no catalog id" apart from "catalog id zero".
  async function postObligation(opts, entry) {
    try {
      const r = await fetch(url("practice/api/workflow/scope/obligation-mappings"), {
        method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({
          organizationId: Number(opts.organizationId),
          obligationId: entry.obligationId != null ? Number(entry.obligationId) : null,
          localPracticeObligationId: entry.localPracticeObligationId != null ? Number(entry.localPracticeObligationId) : null,
          localInstanceObligationId: entry.localInstanceObligationId != null ? Number(entry.localInstanceObligationId) : null,
          eventTypeId: Number(entry.eventTypeId),
          scopeDimension: opts.scopeDimension,
          scopeRoleId: opts.scopeDimension === "ORG_ROLE" ? Number(opts.scopeValueId) : null,
          scopeAssetCategoryId: opts.scopeDimension === "ASSET_CATEGORY" ? Number(opts.scopeValueId) : null,
          profileId: opts.scopeDimension === "PROFILE" ? Number(opts.scopeValueId) : null,
          isApplicable: !!entry.isApplicable, rationale: entry.rationale,
          ownerRoleId: null, dueDays: null, status: "Active"
        })
      });
      return r.ok;
    } catch (_) { return false; }
  }

  async function postQuestion(opts, eventCode, text, isMandatory) {
    try {
      const r = await fetch(url("practice/api/workflow/scope/questions"), {
        method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({
          organizationId: Number(opts.organizationId),
          scopeDimension: opts.scopeDimension,
          scopeRoleId: opts.scopeDimension === "ORG_ROLE" ? Number(opts.scopeValueId) : null,
          scopeAssetCategoryId: opts.scopeDimension === "ASSET_CATEGORY" ? Number(opts.scopeValueId) : null,
          eventTypeCode: eventCode, checklistItemId: null, questionText: text,
          isMandatory: !!isMandatory, evidenceRequired: false, responsibleRole: null, sortOrder: null
        })
      });
      return r.ok;
    } catch (_) { return false; }
  }

  async function flushPending(scopeValueId) {
    if (!pending.opts || !scopeValueId) return { saved: 0, failed: 0 };
    const opts = Object.assign({}, pending.opts, { scopeValueId: scopeValueId });
    let saved = 0, failed = 0;
    for (const t of pending.obligations) {
      (await postObligation(opts, t)) ? saved++ : failed++;
    }
    for (const q of pending.questions) {
      (await postQuestion(opts, q.eventCode, q.text, q.isMandatory)) ? saved++ : failed++;
    }
    pending.buffering = false;
    pending.obligations = [];
    pending.questions = [];
    return { saved, failed };
  }

  // Leaving the page with staged ticks loses them. The browser's own
  // "leave site?" prompt is the only thing that can interrupt a real
  // navigation, so it is used here -- and only while something is
  // actually staged, so it never nags on a clean screen.
  window.addEventListener("beforeunload", function (ev) {
    if (!dirtyCount()) return;
    ev.preventDefault();
    ev.returnValue = "";
    return "";
  });

  window.__scopeChecklistEditor = {
    render: render,
    flushPending: flushPending,
    isBuffering: function () { return pending.buffering; },
    /// <summary>Staged-but-unwritten tick count. A host with its own
    /// "back" or "close" action should check this before navigating.</summary>
    hasUnsavedChanges: function () { return dirtyCount() > 0; },
    unsavedCount: function () { return dirtyCount(); },
    events: SCOPE_EVENTS
  };
})();
