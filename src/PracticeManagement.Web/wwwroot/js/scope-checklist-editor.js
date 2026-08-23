/* =====================================================================
   Scope checklist editor (migrations 123-137)

   One editor, two hosts:
     * Role Master's Add/Edit form, via practice.js   -> ORG_ROLE
     * the Asset Category Assurance screen            -> ASSET_CATEGORY

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
         scopeValueId may be falsy -- see buffering below.
     __scopeChecklistEditor.flushPending(scopeValueId) -> {saved, failed}
         Writes what was held while the record had no id.
     __scopeChecklistEditor.isBuffering()

   BUFFERING
   ---------
   Which obligations reach an organization depends on the organization, the
   event and the subscribed releases -- not on the role or category. So the
   list renders before the record exists (migration 137 allows the query
   without a scope value) and every row comes back Unmapped. What the user
   ticks is held in memory until the host has an id and calls flushPending.
   Writing optimistically would leave orphaned mappings behind whenever an
   Add is cancelled.
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
    ]
  };

  const pending = { buffering: false, obligations: [], questions: [], opts: null };

  // ------------------------------------------------------------------
  function scopeQuery(opts) {
    const parts = ["organizationId=" + encodeURIComponent(opts.organizationId || ""),
                   "scopeDimension=" + encodeURIComponent(opts.scopeDimension)];
    // Omit the scope value entirely when there is none. Sending
    // "scopeRoleId=undefined" fails model binding on a long? and the request
    // comes back 400.
    if (opts.scopeValueId) {
      parts.push((opts.scopeDimension === "ORG_ROLE" ? "scopeRoleId=" : "scopeAssetCategoryId=")
                 + encodeURIComponent(opts.scopeValueId));
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
  async function render(host, opts) {
    if (!host) return;
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
          <p>${esc(opts.subtitle || "Tick the obligations that apply, and add your own checklists.")}</p>
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
         </div>`).join("")}`;
    host.appendChild(container);

    pending.buffering = !opts.scopeValueId;
    if (pending.buffering) {
      pending.obligations = [];
      pending.questions = [];
      pending.opts = opts;
      const note = document.createElement("p");
      note.style.cssText = "margin:6px 0 0 0; font-size:12px; color:#78350f;";
      note.textContent = "Not saved yet — these are written when you press Save.";
      container.querySelector(".pm-tabs").insertAdjacentElement("afterend", note);
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
      cb.checked = m.mappingState === "Mapped"
                || pending.obligations.some(function (t) { return t.obligationId === m.obligationId && t.isApplicable; });
      cb.disabled = !m.isSubscribed;
      cb.style.marginTop = "3px";
      cb.addEventListener("change", function () { saveObligation(container, opts, eventCode, m, cb); });
      row.appendChild(cb);
      row.insertAdjacentHTML("beforeend",
        `<span>${esc(m.obligationLabel || ("Obligation #" + m.obligationId))}
           ${m.isSubscribed ? "" : `<span style="color:#b91c1c; font-size:11px;">not subscribed</span>`}
           ${m.practiceCode ? `<br><span style="font-size:11px; color:#94a3b8;">${esc(m.practiceCode)}</span>` : ""}
           ${m.rationale ? `<br><span style="font-size:11px; color:#78350f;">N/A: ${esc(m.rationale)}</span>` : ""}
         </span>`);
      host.appendChild(row);
    });
  }

  async function saveObligation(container, opts, eventCode, m, checkbox) {
    if (pending.buffering) {
      const at = pending.obligations.findIndex(function (t) { return t.obligationId === m.obligationId; });
      const entry = { obligationId: m.obligationId, eventTypeId: m.eventTypeId,
                      isApplicable: checkbox.checked, rationale: null, eventCode: eventCode };
      if (at >= 0) pending.obligations[at] = entry; else pending.obligations.push(entry);
      msg(container, "Held — saved with the record.", "info");
      setTimeout(function () { msg(container, null); }, 1500);
      return;
    }

    // Unticking records an explicit "not applicable" decision with a reason.
    // An auditor asks why a check is missing; that answer has to be stored.
    let rationale = null;
    if (!checkbox.checked && m.mappingState === "Mapped") {
      rationale = window.prompt("Why is this obligation not applicable for this scope?\nAn auditor will read this.", "");
      if (rationale === null || !rationale.trim()) {
        checkbox.checked = true;
        msg(container, "Not applicable needs a reason; nothing was saved.", "error");
        return;
      }
      rationale = rationale.trim();
    }

    const ok = await postObligation(opts, m.obligationId, m.eventTypeId, checkbox.checked, rationale);
    if (!ok) { msg(container, "Save failed", "error"); checkbox.checked = !checkbox.checked; return; }
    m.mappingState = checkbox.checked ? "Mapped" : "NotApplicable";
    m.rationale = rationale;
    msg(container, "Saved.", "ok");
    setTimeout(function () { msg(container, null); }, 1500);
  }

  // ------------------------------------------------------------------
  async function loadQuestions(container, opts, eventCode, host) {
    if (!host) return;
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
    if (!confirm("Remove this checklist from future events?\nAnswers already recorded against it are kept.")) return;
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
  async function postObligation(opts, obligationId, eventTypeId, isApplicable, rationale) {
    try {
      const r = await fetch(url("practice/api/workflow/scope/obligation-mappings"), {
        method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({
          organizationId: Number(opts.organizationId),
          obligationId: Number(obligationId),
          eventTypeId: Number(eventTypeId),
          scopeDimension: opts.scopeDimension,
          scopeRoleId: opts.scopeDimension === "ORG_ROLE" ? Number(opts.scopeValueId) : null,
          scopeAssetCategoryId: opts.scopeDimension === "ASSET_CATEGORY" ? Number(opts.scopeValueId) : null,
          isApplicable: !!isApplicable, rationale: rationale,
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
      (await postObligation(opts, t.obligationId, t.eventTypeId, t.isApplicable, t.rationale)) ? saved++ : failed++;
    }
    for (const q of pending.questions) {
      (await postQuestion(opts, q.eventCode, q.text, q.isMandatory)) ? saved++ : failed++;
    }
    pending.buffering = false;
    pending.obligations = [];
    pending.questions = [];
    return { saved, failed };
  }

  window.__scopeChecklistEditor = {
    render: render,
    flushPending: flushPending,
    isBuffering: function () { return pending.buffering; },
    events: SCOPE_EVENTS
  };
})();
