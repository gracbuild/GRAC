// =====================================================================
// window.gracObligationForm — THE organisation-defined obligation form.
//
// Pairs with Views/Practice/Partials/_obligation-form-dialog.cshtml.
// Include that partial once on a page, load this script, and any screen
// on that page can open the same add/edit form.
//
// WHY THIS EXISTS
// ---------------
// The form lived inline in resolve-workspace.cshtml: the type dropdown,
// the typed rule panel mirrored from Control Management, the
// Assurance -> Automated -> Connection cascade, the evidence list, the
// validation and the save. Practice View needs the same form for a
// practice-level obligation (docs/practice-level-obligations.md), and
// copying ~600 lines would mean two validations, two field lists and two
// places to change every time Control Management adds a field.
//
// The shared task form (Shared/task-form.js) established the pattern for
// exactly this problem. This is that pattern applied a second time.
//
// ONE FORM, TWO SCOPES
// --------------------
//   scope: "instance"   POST /practice/api/workflow/resolve/local-obligation
//                       the obligation belongs to ONE practice instance
//                       (migration 227). Unchanged behaviour.
//   scope: "practice"   POST /practice/api/practice-obligations
//                       the obligation belongs to the PRACTICE and fans
//                       out to every instance of it.
//
// The two endpoints take the same field set because the practice-level
// table mirrors the instance-level columns on purpose. Only the ids and
// the URL differ, so only they are branched.
//
// USAGE
//   window.gracObligationForm.open({
//     scope:        "instance" | "practice",
//
//     // where it saves -- one of these two sets
//     practiceInstanceId: 123,              // scope "instance"
//     organizationId: 4, practiceId: 77,    // scope "practice"
//
//     row:        <the row being edited, or null to add>,
//     recordId:   0,                        // 0 adds; the row id edits
//     detailJson: <the row's typed detail, JSON string or array>,
//     evidence:   [ { evidenceTypeId, evidenceType, isMandatory,
//                     retentionPeriod, locked } ],
//
//     lookups: { frequencies, roles, assuranceTypes,
//                implementationStatuses, evidenceTypes, connectionTypes },
//     ensureConnectionTypes: () => Promise<[{value,label}]>,   // optional
//     showImplementationStatus: true,       // default true
//     showConnection:           true,       // default true
//
//     onSaved: result => reloadTheHostList()   // { recordId, scope }
//   });
//
// The caller passes DATA, not helpers: this module carries its own esc /
// F / options, the same way every other screen partial in this codebase
// carries its own. What it does not carry is anything the host owns --
// the lookups and the reload are handed in.
//
// WHAT THE MODULE OWNS, AND WHY IT IS EXPORTED
// --------------------------------------------
// TYPE_SCHEMA is a PRESENTATION contract mirrored from
//   ControlManagement.Web/wwwroot/js/obligation-master-form.js
// It lives here, once, and is exported so a host can read it rather than
// restate it.
//
// The map of which JSON array carries which type's detail stays with the
// HOST: a read side has to render the two types Control Management
// retired (Evidence, Retention) and this form never offers them, so a
// copy here would be a smaller version of the same map. The host passes
// the detail it found as opts.detailJson instead.
// =====================================================================
(() => {
  "use strict";

  // Resolved lazily, not captured at parse time: this script can load
  // before the layout's inline script sets window.pmPathBase, and a
  // published build under a PathBase would then post to the origin root.
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;

  const $ = id => document.getElementById(id);

  const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // Rows arrive camelCase from the Web tier and PascalCase from some
  // gateway paths. Same accessor the screen partials use.
  const F = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)] ?? null;

  const normKey = k => String(k).replace(/_/g, "").toLowerCase();

  function unwrap(v) {
    if (typeof v === "string") {
      const t = v.trim();
      if ((t.startsWith("{") && t.endsWith("}")) || (t.startsWith("[") && t.endsWith("]"))) {
        try { return unwrap(JSON.parse(t)); } catch (_) { return v; }
      }
    }
    if (v && typeof v === "object" && Array.isArray(v.$values)) return v.$values.map(unwrap);
    if (Array.isArray(v)) return v.map(unwrap);
    return v;
  }

  function rowsOf(body) {
    const d = unwrap(body?.data ?? body?.Data ?? body ?? []);
    if (!Array.isArray(d)) return [];
    return (d.length && Array.isArray(d[0])) ? d.flat() : d;
  }

  function options(list, selected, blank) {
    return '<option value="">' + esc(blank || "As published") + "</option>"
      + (list || []).map(o => '<option value="' + esc(o.value) + '"'
        + (String(o.value) === String(selected ?? "") ? " selected" : "") + ">"
        + esc(o.label) + "</option>").join("");
  }

  function labelOf(list, value) {
    if (value === null || value === undefined || value === "") return null;
    const hit = (list || []).find(o => String(o.value) === String(value));
    return hit ? hit.label : null;
  }

  function parseJsonArray(raw) {
    if (!raw) return [];
    if (Array.isArray(raw)) return raw;
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch (_) { return []; }
  }

  // Not offered when adding. The type dropdown is already filtered by
  // what Control Management still publishes; this is belt and braces for
  // a database whose type master has not caught up. An obligation ALREADY
  // saved under one of them is still editable -- see typeOptionsFor.
  const retiredTypes = new Set(["Evidence", "Retention"]);

  // ===================================================================
  // The typed-detail panel, mirrored from Control Management
  //
  // TYPE_SCHEMA is a deliberate copy of the one in
  //   ControlManagement.Web/wwwroot/js/obligation-master-form.js
  // -- labels, order, control types, hints, required flags, which fields
  // are retired, and the Assurance cascade.
  //
  // WHY COPY RATHER THAN DERIVE
  // ---------------------------
  // Migration 225 established that this module must not name Control
  // Management's COLUMNS, and 228 that it must not name its TABLES --
  // both are schema, and schema can be read from sys.columns.
  //
  // None of this is schema. "Verification Method", the field order,
  // "Scheduled runs on a frequency", the fact that `scope` is retired
  // from the panel but still carried in the payload -- sys.columns knows
  // none of it. It is a PRESENTATION contract, and Control Management
  // keeps it in exactly one file. So this is that file's other half.
  // Re-sync it when CM's changes.
  //
  // AND WHY IT IS STILL CHECKED AGAINST THE SCHEMA
  // ----------------------------------------------
  // Every field here is matched to a real column via the /fields endpoint
  // before it is rendered or saved. A field CM has since dropped from the
  // table therefore disappears from this form by itself, rather than
  // being posted into a column that is not there. Copied presentation,
  // verified existence.
  // ===================================================================
  const TYPE_SCHEMA = {
    State: {
      heading: "State Rule",
      subheading: "Positive parametric assertion (e.g. password.length >= 12).",
      fields: [
        { name: "attribute", label: "Attribute", type: "text", required: true, hint: "e.g. password.length" },
        { name: "operator",  label: "Operator",  type: "text", required: true, hint: "e.g. >=, =, in, contains" },
        { name: "value",     label: "Value",     type: "text", required: true, hint: "e.g. 12, true, AES-256" },
        { name: "unit",      label: "Unit",      type: "text", hint: "e.g. characters, days" },
        { name: "tolerance", label: "Tolerance", type: "text" }
      ]
    },
    Execution: {
      heading: "Execution Spec",
      subheading: "What must be done and when.",
      fields: [
        { name: "action",               label: "Action",              type: "textarea", required: true, full: true },
        { name: "executionFrequencyId", label: "Execution Frequency", type: "reference" },
        { name: "dueWithin",            label: "Due Within",          type: "text", hint: "e.g. 30 days, quarter-end" },
        { name: "triggerCondition",     label: "Trigger Condition",   type: "text", hidden: true },
        { name: "responsibleParty",     label: "Responsible Party",   type: "text", hidden: true }
      ]
    },
    // The cascade the other types do not have:
    //   Trigger Mode -> (Scheduled ? Frequency : Domain -> Event, Due Within)
    // CM's CHECK constraint ck_cm_assurance_spec_trigger enforces the same
    // shape at the database, so the two halves are genuinely exclusive --
    // not a styling choice.
    Assurance: {
      heading: "Assurance Spec",
      subheading: "What must be verified, and what triggers it.",
      fields: [
        { name: "verificationMethod",   label: "Verification Method", type: "textarea", required: true, full: true },
        { name: "triggerMode",          label: "Trigger Mode",        type: "trigger-mode", required: true, controls: true,
          hint: "Scheduled runs on a frequency; event driven runs each time the event occurs." },
        { name: "assuranceFrequencyId", label: "Assurance Frequency", type: "reference", required: true,
          showWhen: () => triggerModeCode() === "Scheduled" },
        // UI-only: the server stores the leaf event, which already knows
        // its parent.
        { name: "eventDomainId",        label: "Event Domain",        type: "event-domain", required: true, controls: true, transient: true,
          showWhen: () => triggerModeCode() === "EventDriven" },
        { name: "eventTypeId",          label: "Event",               type: "event-leaf", required: true,
          showWhen: () => triggerModeCode() === "EventDriven",
          hint: "This assurance is raised every time the selected event occurs." },
        { name: "slaDays",              label: "Due Within (days)",   type: "number",
          showWhen: () => triggerModeCode() === "EventDriven",
          hint: "Days after the event to complete this. Leave blank for no deadline." },
        { name: "scope",                label: "Scope",               type: "text", hidden: true },
        { name: "assuranceParty",       label: "Assurance Party",     type: "text", hidden: true }
      ]
    },
    EventResponse: {
      heading: "Event Response",
      subheading: "If X occurs, do Y within SLA.",
      fields: [
        { name: "triggerEvent",   label: "Trigger Event",   type: "textarea", required: true, full: true },
        { name: "responseAction", label: "Response Action", type: "textarea", required: true, full: true },
        { name: "slaValue",       label: "SLA Value",       type: "number" },
        { name: "slaUnit",        label: "SLA Unit",        type: "select", options: ["", "Hours", "Days", "Weeks", "Months", "Years"] },
        { name: "escalationPath", label: "Escalation Path", type: "text", hidden: true }
      ]
    },
    Constraint: {
      heading: "Constraint Rule",
      subheading: "A prohibition -- what must never be true.",
      fields: [
        { name: "prohibitedCondition", label: "Prohibited Condition", type: "textarea", required: true, full: true },
        { name: "scope",               label: "Scope",                type: "text", hidden: true },
        { name: "exceptionPolicy",     label: "Exception Policy",     type: "text", hidden: true }
      ]
    }
    // Evidence and Retention are absent: Control Management retired both
    // from its own form, so neither is offered here either.
  };

  // ---- module state -------------------------------------------------
  let opts = null;              // options of the currently open dialog
  let wired = false;

  let typedValues = {};         // panel values, keyed by SCHEMA field name
  let localEvidence = [];       // the evidence list being edited
  let localFields = [];         // the chosen type's real columns
  const fieldCache = {};        // typeCode -> column list

  let obligationTypes = null;   // null = not fetched yet
  let typesFetch = null;
  let triggerModes = [], eventTypes = [];
  let vocabularyFetch = null;

  const triggerModeCode = () => String(typedValues.triggerMode ?? "");
  const eventDomains    = () => eventTypes.filter(e => F(e, "isDomain") === true);
  const eventLeaves     = domainId => eventTypes.filter(e =>
    F(e, "isDomain") !== true && String(F(e, "parentEventTypeId") || "") === String(domainId));

  const lookup = name => (opts && opts.lookups && opts.lookups[name]) || [];

  function msg(text) {
    const el = $("gofMsg");
    if (el) el.textContent = text || "";
  }

  // ===================================================================
  // Vocabularies
  // ===================================================================

  // The obligation types the form can offer. Exported because the host
  // needs the same list to decide whether its Add button can appear at
  // all -- no type list means no way to say what an obligation IS, and
  // the save procedure refuses one without a type.
  function loadTypes() {
    if (obligationTypes) return Promise.resolve(obligationTypes);
    if (typesFetch) return typesFetch;
    typesFetch = fetch(U("/practice/api/workflow/resolve/obligation-types"),
                       { credentials: "same-origin" })
      .then(r => (r.ok ? r.json() : null))
      .then(body => {
        obligationTypes = body
          ? rowsOf(body)
              .map(x => ({ value: String(F(x, "typeCode") || ""),
                           label: String(F(x, "typeName") || F(x, "typeCode") || "") }))
              .filter(x => x.value && !retiredTypes.has(x.value))
          : [];                      // 227 not applied
        return obligationTypes;
      })
      .catch(() => { obligationTypes = []; return obligationTypes; });
    return typesFetch;
  }

  // Migration 230. The two vocabularies Control Management's Assurance
  // panel is built from, which this form mirrors. Empty when CM 033 is
  // not applied here -- the trigger mode then degrades to free text
  // rather than an unusable one-item dropdown.
  function loadVocabulary() {
    if (vocabularyFetch) return vocabularyFetch;
    vocabularyFetch = fetch(U("/practice/api/workflow/resolve/obligation-vocabulary"),
                            { credentials: "same-origin" })
      .then(r => (r.ok ? r.json() : null))
      .then(body => {
        if (!body) return;
        triggerModes = (unwrap(body.triggerModes ?? body.TriggerModes ?? []) || [])
          .map(m => ({ value: String(F(m, "triggerMode") || ""),
                       label: String(F(m, "triggerModeLabel") || F(m, "triggerMode") || "") }))
          .filter(m => m.value);
        eventTypes = unwrap(body.eventTypes ?? body.EventTypes ?? []) || [];
      })
      .catch(() => { /* the panel falls back to free text */ });
    return vocabularyFetch;
  }

  // Mirrors CM's reinstateRetiredType: an obligation already saved under
  // a type CM has since retired gets its code back on the dropdown,
  // labelled as retired, so editing it does not quietly change what it
  // is.
  // Any code the row already carries but the list does not offer is put
  // back, not just a retired one: if the types feed failed or the type
  // master has moved on, dropping the option would leave the dropdown
  // blank and the save would then refuse the row for having no type --
  // silently changing what the obligation is on the way through.
  function typeOptionsFor(code) {
    const list = (obligationTypes || []).slice();
    if (code && !list.some(t => t.value === code)) {
      list.push({ value: code, label: code + (retiredTypes.has(code) ? " (retired)" : "") });
    }
    return list;
  }

  // ===================================================================
  // The typed rule panel
  // ===================================================================

  // Schema field name -> the real column it is stored in. Built from the
  // /fields endpoint, matched on the normalised name, so
  // verificationMethod finds verification_method and slaDays finds
  // sla_days.
  function columnFor(fieldName) {
    const want = normKey(fieldName);
    const hit = localFields.find(c => normKey(F(c, "columnName") || "") === want);
    return hit ? String(F(hit, "columnName") || "") : null;
  }

  async function loadTypeFields(typeCode) {
    const box  = $("gofRuleBox");
    const host = $("gofRuleFields");
    localFields = [];
    if (!typeCode) { box.hidden = true; host.innerHTML = ""; return; }

    // The column list is still fetched -- it is what verifies each
    // mirrored field actually exists before the form offers it.
    if (!fieldCache[typeCode]) {
      try {
        const r = await fetch(U("/practice/api/workflow/resolve/obligation-types/"
                                + encodeURIComponent(typeCode) + "/fields"),
                              { credentials: "same-origin" });
        fieldCache[typeCode] = r.ok ? rowsOf(await r.json()) : [];
      } catch (_) { fieldCache[typeCode] = []; }
    }
    localFields = fieldCache[typeCode];

    renderTypedPanel(typeCode);
  }

  function renderTypedPanel(typeCode) {
    const box    = $("gofRuleBox");
    const host   = $("gofRuleFields");
    const note   = $("gofRuleNote");
    const schema = TYPE_SCHEMA[typeCode];

    if (!schema) {
      // A type with no mirrored panel -- Evidence, or one Control
      // Management adds later. Say so rather than showing an empty box
      // that looks broken.
      box.hidden = false;
      note.textContent = "This type has no rule detail of its own.";
      host.innerHTML = "";
      return;
    }

    box.hidden = false;
    note.textContent = schema.heading + " -- " + schema.subheading;

    // Two independent reasons a field is not drawn, exactly as CM has it:
    // `hidden` is retired from the UI for good, `showWhen` is the live
    // half of the cascade. A third reason is ours: the column is not in
    // the table any more.
    const visible = schema.fields.filter(f =>
      !f.hidden
      && (typeof f.showWhen !== "function" || f.showWhen())
      && (f.transient === true || columnFor(f.name)));

    host.innerHTML = visible.map(renderTypedField).join("");

    host.querySelectorAll("[data-typed-field]").forEach(el => {
      const name   = el.getAttribute("data-typed-field");
      const field  = schema.fields.find(f => f.name === name);
      const commit = () => { typedValues[name] = el.value; };

      if (field && field.controls) {
        // A controlling field changes which other fields exist, so it
        // re-renders. Clear what it invalidates first: a stale event
        // surviving a switch back to Scheduled would trip CM's CHECK
        // constraint on save.
        el.addEventListener("change", () => {
          commit();
          if (name === "triggerMode") {
            const code = triggerModeCode();
            if (code !== "EventDriven") { typedValues.eventDomainId = ""; typedValues.eventTypeId = ""; }
            if (code !== "Scheduled")   { typedValues.assuranceFrequencyId = ""; }
          }
          if (name === "eventDomainId") typedValues.eventTypeId = "";
          renderTypedPanel(typeCode);
        });
        return;
      }
      el.addEventListener("input", commit);
      el.addEventListener("change", commit);
    });
  }

  function renderTypedField(field) {
    const value = typedValues[field.name] ?? "";
    const req   = field.required ? ' <span class="required">*</span>' : "";
    const hint  = field.hint ? '<span class="gof-note">' + esc(field.hint) + "</span>" : "";
    // Long-form inputs take the full row; everything else sits beside its
    // neighbours. Same rule CM applies with its 12-column grid.
    const wide  = (field.full || field.type === "textarea") ? ' class="full"' : "";
    const attr  = 'data-typed-field="' + esc(field.name) + '"';

    let control;
    if (field.type === "textarea") {
      control = "<textarea " + attr + ' rows="2">' + esc(value) + "</textarea>";
    } else if (field.type === "number") {
      control = '<input type="number" ' + attr + ' value="' + esc(value) + '">';
    } else if (field.type === "select") {
      control = "<select " + attr + ">"
        + (field.options || []).map(o =>
            '<option value="' + esc(o) + '"' + (String(o) === String(value) ? " selected" : "") + ">"
            + esc(o || "-- Select --") + "</option>").join("")
        + "</select>";
    } else if (field.type === "reference") {
      control = "<select " + attr + ">" + options(lookup("frequencies"), value, "-- Select --") + "</select>";
    } else if (field.type === "trigger-mode") {
      // Falls back to free text when migration 230 has not run or Control
      // Management 033 is not applied here -- a one-item or empty
      // dropdown would be a dead end.
      control = triggerModes.length
        ? "<select " + attr + ">" + options(triggerModes, value, "-- Select Mode --") + "</select>"
        : '<input type="text" ' + attr + ' value="' + esc(value) + '" placeholder="Scheduled or EventDriven">';
    } else if (field.type === "event-domain") {
      control = "<select " + attr + ">"
        + options(eventDomains().map(d => ({ value: String(F(d, "eventTypeId")),
                                             label: String(F(d, "eventName") || "") })),
                  value, "-- Select Domain --") + "</select>";
    } else if (field.type === "event-leaf") {
      const domainId = String(typedValues.eventDomainId ?? "");
      const leaves = eventLeaves(domainId)
        .map(l => ({ value: String(F(l, "eventTypeId")), label: String(F(l, "eventName") || "") }));
      control = "<select " + attr + (domainId ? "" : " disabled") + ">"
        + options(leaves, value, domainId ? "-- Select Event --" : "-- Select a domain first --")
        + "</select>";
    } else {
      control = '<input type="text" ' + attr + ' value="' + esc(value) + '">';
    }

    return "<div" + wide + "><label>" + esc(field.label) + req + control + hint + "</label></div>";
  }

  // ===================================================================
  // Assurance / Connection visibility (migration 244)
  //
  // Keep the Assurance type row hidden unless the obligation's type is
  // Assurance -- outside Assurance it is a meaningless choice (the store
  // still accepts it, but the operator has no reason to answer). If
  // Assurance type is hidden the Connection row must be hidden too,
  // because "Automated" is a value it cannot hold when the outer row is
  // not visible.
  //
  // The wrap divs carry `hidden`; the inputs themselves stay in the DOM
  // so the save-time reads never trip on a missing element.
  // ===================================================================
  function syncAssuranceVisibility() {
    const isAssurance = String($("gofType").value || "") === "Assurance";
    $("gofAssuranceTypeWrap").hidden = !isAssurance;
    if (!isAssurance) {
      // Wipe the values so a stale selection does not survive when the
      // operator toggles Assurance -> Execution -> Assurance.
      $("gofAssuranceType").value  = "";
      $("gofConnectionType").value = "";
      $("gofConnectionUrl").value  = "";
    }
    syncConnectionVisibility();
  }

  function syncConnectionVisibility() {
    // A scope that does not store the connection never shows the two
    // controls -- an input whose value is dropped on save is worse than
    // no input. A practice-level obligation is one such scope: the
    // endpoint an automated check calls is each instance's own.
    const allowed    = !(opts && opts.showConnection === false);
    const isAssurance = String($("gofType").value || "") === "Assurance";
    const isAutomated = allowed && isAssurance
      && String($("gofAssuranceType").value || "") === "Automated";
    $("gofConnectionTypeWrap").hidden = !isAutomated;
    $("gofConnectionUrlWrap").hidden  = !isAutomated;
  }

  // ===================================================================
  // The evidence list (migration 232)
  // ===================================================================
  function renderEvidence() {
    const host = $("gofEvidenceRows");
    // The per-evidence Description box. Both scopes round-trip it, each via
    // its own store, and it travels as the evidence item's `remarks`:
    //  * practice: kept verbatim in practice_obligation.evidence_json and read
    //    straight back onto the practice card.
    //  * instance: migration 340 makes sp_resolve_local_obligation_evidence_sync
    //    write it to practice_instance_evidence.evidence_description, which the
    //    Operationalize card shows (inline) and openLocalForm re-seeds here.
    const showEvDesc = true;
    host.innerHTML = localEvidence.length
      ? localEvidence.map((e, i) =>
          '<div class="gof-evidence-line">'
          + '<span class="gof-evidence-name">' + esc(e.evidenceType) + "</span>"
          + "<label>"
            + '<input type="checkbox" data-ev-mandatory="' + i + '"'
            + (e.isMandatory ? " checked" : "") + "> Mandatory</label>"
          + '<label class="gof-evidence-retention">Retention'
            + '<input type="text" data-ev-retention="' + i + '" value="'
            + esc(e.retentionPeriod || "") + '"></label>'
          + (e.locked
              // A row somebody has already worked on cannot be removed
              // here -- the procedure keeps it anyway, and a control that
              // appears to delete it would be a lie.
              ? '<span class="gof-note">already in use -- cannot be removed here</span>'
              : '<button class="pm-button ghost small" type="button" data-ev-drop="' + i + '">'
                + '<i class="fa-solid fa-xmark"></i></button>')
          // Full-width note under the row: what this evidence should show.
          + (showEvDesc
              ? '<label class="gof-evidence-desc">Description'
                + '<textarea rows="2" data-ev-desc="' + i + '"'
                + ' placeholder="What this evidence should show (optional)">'
                + esc(e.remarks || "") + '</textarea></label>'
              : "")
          + "</div>").join("")
      : '<p class="gof-note">No evidence declared yet.</p>';

    // The picker offers only what is not already on the list.
    const taken = new Set(localEvidence.map(e => String(e.evidenceTypeId)));
    $("gofEvidencePick").innerHTML =
      options(lookup("evidenceTypes").filter(t => !taken.has(String(t.value))), "", "Select a type...");

    host.querySelectorAll("[data-ev-mandatory]").forEach(cb => {
      cb.addEventListener("change", function () {
        localEvidence[Number(this.getAttribute("data-ev-mandatory"))].isMandatory = this.checked;
      });
    });
    host.querySelectorAll("[data-ev-retention]").forEach(el => {
      el.addEventListener("input", function () {
        localEvidence[Number(this.getAttribute("data-ev-retention"))].retentionPeriod = this.value;
      });
    });
    host.querySelectorAll("[data-ev-desc]").forEach(el => {
      el.addEventListener("input", function () {
        localEvidence[Number(this.getAttribute("data-ev-desc"))].remarks = this.value;
      });
    });
    host.querySelectorAll("[data-ev-drop]").forEach(b => {
      b.addEventListener("click", function () {
        localEvidence.splice(Number(this.getAttribute("data-ev-drop")), 1);
        renderEvidence();
      });
    });
  }

  function addEvidence() {
    const sel = $("gofEvidencePick");
    const id  = sel.value;
    if (!id) return;
    const type = lookup("evidenceTypes").find(t => String(t.value) === String(id));
    localEvidence.push({
      evidenceTypeId:  Number(id),
      evidenceType:    type ? type.label : "",
      isMandatory:     true,
      retentionPeriod: "",
      remarks:         "",
      locked:          false
    });
    renderEvidence();
  }

  // ===================================================================
  // Open / close
  // ===================================================================

  // Which field on the row holds what, per scope. Both shapes are known
  // here because this module owns both endpoints; a host hands over its
  // raw row and does not have to translate it.
  //
  // The typed DETAIL is the exception and arrives as opts.detailJson. An
  // instance row carries it in one of SEVEN arrays named by the row's own
  // type, and that map belongs to the host: its read side needs the two
  // retired types (Evidence, Retention) that this form never offers, so
  // a copy here would be a second, smaller version of the same map -- the
  // kind of near-duplicate that drifts. A practice row carries it in one
  // column and the host passes that.
  function seedOf(row, scope) {
    if (!row) return {};
    return scope === "practice"
      ? {
          name:        F(row, "obligationName"),
          description: F(row, "obligationDescription"),
          typeCode:    F(row, "obligationTypeCode"),
          responsibility:         F(row, "responsibility"),
          approvalAuthority:      F(row, "approvalAuthority"),
          assuranceType:          F(row, "assuranceType"),
          implementationStatusId: F(row, "implementationStatusId"),
          connectionTypeId:       F(row, "connectionTypeId"),
          connectionUrl:          F(row, "connectionUrl"),
          remarks:                F(row, "remarks")
        }
      : {
          name:        F(row, "obligationName"),
          description: F(row, "obligationDescription"),
          typeCode:    F(row, "typeCode"),
          responsibility:         F(row, "responsibility"),
          approvalAuthority:      F(row, "approvalAuthority"),
          assuranceType:          F(row, "adoptedAssuranceType"),
          implementationStatusId: F(row, "implementationStatusId"),
          connectionTypeId:       F(row, "connectionTypeId"),
          connectionUrl:          F(row, "connectionUrl"),
          remarks:                F(row, "remarks")
        };
  }

  async function open(options_) {
    opts = Object.assign(
      { scope: "instance", showImplementationStatus: true, showConnection: true },
      options_ || {});
    wire();

    const dlg  = $("gofDialog");
    const row  = opts.row || null;
    const seed = seedOf(row, opts.scope);

    // The type list and the Assurance vocabulary are both needed before
    // the panel can draw. Both are cached, and a host that called prime()
    // at start-up has them already -- so this resolves instantly and the
    // dialog opens as promptly as the inline version did, which loaded
    // the same two feeds during its own init.
    await Promise.all([loadTypes(), loadVocabulary()]);

    $("gofHeading").textContent = row ? "Edit obligation" : "Add obligation";
    msg("");

    $("gofId").value          = String(opts.recordId || 0);
    $("gofName").value        = seed.name || "";
    $("gofDescription").value = seed.description || "";

    const rowType = String(seed.typeCode || "");
    $("gofType").innerHTML = options(typeOptionsFor(rowType), rowType, "Select a type...");

    $("gofResponsibility").innerHTML = options(lookup("roles"), seed.responsibility, "Not set");
    $("gofApproval").innerHTML       = options(lookup("roles"), seed.approvalAuthority, "Not set");
    $("gofAssuranceType").innerHTML  = options(lookup("assuranceTypes"), seed.assuranceType, "Not set");
    $("gofImplStatus").innerHTML     = options(lookup("implementationStatuses"), seed.implementationStatusId, "Not set");
    $("gofRemarks").value            = seed.remarks || "";
    $("gofConnectionUrl").value      = seed.connectionUrl || "";

    // A practice-level obligation has no implementation status of its
    // own: status is a fact about doing the work, and the work happens on
    // an instance. Hidden rather than removed, so the field set stays one
    // field set.
    $("gofImplStatusWrap").hidden = opts.showImplementationStatus === false;

    // Migration 244: the connection dropdown is populated asynchronously
    // by the host's cache; visibility is computed from the current Type +
    // Assurance type once it lands.
    const connect = typeof opts.ensureConnectionTypes === "function"
      ? opts.ensureConnectionTypes()
      : Promise.resolve(lookup("connectionTypes"));
    Promise.resolve(connect).then(list => {
      $("gofConnectionType").innerHTML =
        options(list && list.length ? list : lookup("connectionTypes"), seed.connectionTypeId, "Not set");
      syncAssuranceVisibility();
      syncConnectionVisibility();
    });

    // The panel reads typedValues, so the stored JSON is loaded into it
    // BEFORE the panel renders -- otherwise the Assurance cascade would
    // draw its Scheduled half on an event-driven obligation and then
    // clear the event when the mode was applied.
    typedValues = {};
    if (row) {
      const item = parseJsonArray(opts.detailJson)[0] || {};
      // Stored under column names; the panel is keyed by schema field
      // name. Mapped back through the same normalisation.
      (TYPE_SCHEMA[rowType] ? TYPE_SCHEMA[rowType].fields : []).forEach(f => {
        const key = Object.keys(item).find(k => normKey(k) === normKey(f.name));
        if (key !== undefined && item[key] !== null) typedValues[f.name] = String(item[key]);
      });
      // eventDomainId is transient -- never stored -- so it is derived
      // from the leaf's parent, or the cascade would open on step two
      // with step one blank.
      if (typedValues.eventTypeId) {
        const leaf = eventTypes.find(e => String(F(e, "eventTypeId")) === String(typedValues.eventTypeId));
        if (leaf) typedValues.eventDomainId = String(F(leaf, "parentEventTypeId") || "");
      }
    }
    // Not awaited, matching the inline version: the panel fills itself in
    // when the /fields call lands rather than holding the dialog shut on
    // a network round trip. The column list is cached per type, so this
    // is only ever a wait on the first use of a type.
    loadTypeFields(rowType);

    localEvidence = Array.isArray(opts.evidence)
      ? opts.evidence.map(e => Object.assign({}, e))
      : [];
    renderEvidence();

    if (!dlg.open) dlg.showModal();
  }

  function close() {
    const dlg = $("gofDialog");
    if (dlg && dlg.open) dlg.close();
    $("gofRuleFields").innerHTML = "";
    $("gofRuleBox").hidden = true;
    typedValues = {};
    localEvidence = [];
  }

  // ===================================================================
  // Save
  // ===================================================================
  async function save() {
    const name = $("gofName").value.trim();
    const type = $("gofType").value;
    if (!name) { msg("A name is required."); return; }
    if (!type) { msg("A type is required."); return; }

    // One object, keyed by the real COLUMN names, in the same array shape
    // vw_pm_obligation_typed_detail emits -- so the card renders an
    // organisation-defined obligation through exactly the same path as a
    // published one.
    //
    // Only the live half of a cascade is sent: CM's own form does the
    // same, and its CHECK constraint refuses an event alongside a
    // Scheduled trigger. `transient` fields (Event Domain) are a UI step
    // and are never stored -- the leaf event knows its parent.
    const schema = TYPE_SCHEMA[type];
    const detail = {};
    if (schema) {
      schema.fields.forEach(f => {
        if (f.transient === true) return;
        if (typeof f.showWhen === "function" && !f.showWhen()) return;
        const col = columnFor(f.name);
        if (!col) return;                      // column no longer exists
        const v = String(typedValues[f.name] ?? "").trim();
        if (v !== "") detail[col] = v;
      });
    }

    // The one rule worth refusing on this side: CM's constraint would
    // reject it anyway, but as SQL error text rather than a sentence.
    if (type === "Assurance") {
      const mode = triggerModeCode();
      if (mode === "EventDriven" && !String(typedValues.eventTypeId ?? "").trim()) {
        msg("An event driven assurance needs an event."); return;
      }
      if (mode === "Scheduled" && !String(typedValues.assuranceFrequencyId ?? "").trim()) {
        msg("A scheduled assurance needs an assurance frequency."); return;
      }
    }

    // For Execution obligations the frequency lives on the typed panel
    // above, and it flows into the top-level executionFrequencyId key
    // here -- which is what the save procedure writes to
    // execution_frequency_id, keeping the instance-default frequency view
    // (migration 145) fed.
    //
    // For a non-Execution obligation there IS no execution frequency, so
    // nothing is sent -- the procedure reads an absent key as "no
    // opinion" and leaves any prior value alone.
    const execId = type === "Execution" ? String(typedValues.executionFrequencyId ?? "") : "";

    const num = el => { const v = $(el).value; return v ? Number(v) : null; };

    const payload = {
      obligationName:        name,
      obligationDescription: $("gofDescription").value || null,
      obligationTypeCode:    type,
      typedDetailJson:       Object.keys(detail).length ? JSON.stringify([detail]) : "[]",
      executionFrequencyId:  execId ? Number(execId) : null,
      executionFrequency:    labelOf(lookup("frequencies"), execId),
      responsibility:        $("gofResponsibility").value || null,
      approvalAuthority:     $("gofApproval").value || null,
      assuranceType:         $("gofAssuranceType").value || null,
      // Migration 242: per-obligation implementation status.
      implementationStatusId: opts.showImplementationStatus === false ? null : num("gofImplStatus"),
      // Migration 244: connection payload -- populated only when
      // Assurance + Automated is the current selection. The procedure
      // COALESCEs a null onto the stored value so a switch to Manual
      // leaves the previous URL alone.
      connectionTypeId:      opts.showConnection === false ? null : num("gofConnectionType"),
      connectionUrl:         opts.showConnection === false ? null : ($("gofConnectionUrl").value || null),
      remarks:               $("gofRemarks").value || null,
      retire:                false,
      // The complete set. Sent even when empty -- an empty array means
      // "none", where omitting it would mean "no opinion" and leave the
      // stored evidence alone.
      evidence: localEvidence.map(e => ({
        evidenceTypeId:  e.evidenceTypeId,
        isMandatory:     e.isMandatory !== false,
        retentionPeriod: e.retentionPeriod || null,
        // The per-evidence Description, captured in the practice scope
        // (see renderEvidence). Trimmed to null so a blank box stores
        // nothing rather than an empty string.
        remarks:         (e.remarks && String(e.remarks).trim()) ? e.remarks : null
      }))
    };

    const recordId = Number($("gofId").value || 0);
    let url, idKey;
    if (opts.scope === "practice") {
      url   = U("/practice/api/practice-obligations");
      idKey = "practiceObligationId";
      payload.organizationId      = opts.organizationId ? Number(opts.organizationId) : null;
      payload.practiceId          = Number(opts.practiceId);
      payload.practiceObligationId = recordId;
    } else {
      url   = U("/practice/api/workflow/resolve/local-obligation");
      idKey = "practiceInstanceObligationId";
      payload.practiceInstanceId           = Number(opts.practiceInstanceId);
      payload.practiceInstanceObligationId = recordId;
    }

    // Hold the button down for the whole round trip. A save that is slow,
    // or one that fails after the row is already written, must not be
    // clickable a second time -- the second click would carry the same id
    // 0 and insert a duplicate rather than update.
    const btn = $("gofSave");
    if (btn.disabled) return;
    btn.disabled = true;
    msg("Saving...");

    try {
      const r = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        body: JSON.stringify(payload)
      });
      const body = await r.json().catch(() => ({}));

      // If the server named the row, remember it even on failure. A retry
      // then updates that obligation instead of inserting a second one --
      // which is what turned one bad save into a pile of duplicates
      // before.
      const savedId = Number(body[idKey] || body[idKey.charAt(0).toUpperCase() + idKey.slice(1)] || 0);
      if (savedId > 0) $("gofId").value = String(savedId);

      if (!r.ok) { msg(body.error || ("Could not save (HTTP " + r.status + ").")); return; }

      const done = opts.onSaved;
      const result = { recordId: savedId || recordId, scope: opts.scope };
      close();
      if (typeof done === "function") { try { await done(result); } catch (e) { console.error(e); } }
    } catch (err) {
      console.error("[grac-obligation-form] save failed", err);
      msg("Could not save the obligation.");
    } finally {
      // finally, not the success path: a failed save has to stay
      // retryable, and an exception must not leave a dead button.
      btn.disabled = false;
    }
  }

  // Retire, exposed so a host's row menu does not have to know the
  // endpoint or the payload shape either. Confirmation is the host's --
  // it knows what it is removing from.
  async function retire(o) {
    const scope = (o && o.scope) || "instance";
    const payload = { retire: true };
    let url;
    if (scope === "practice") {
      url = U("/practice/api/practice-obligations");
      payload.organizationId       = o.organizationId ? Number(o.organizationId) : null;
      payload.practiceId           = Number(o.practiceId);
      payload.practiceObligationId = Number(o.recordId);
    } else {
      url = U("/practice/api/workflow/resolve/local-obligation");
      payload.practiceInstanceId           = Number(o.practiceInstanceId);
      payload.practiceInstanceObligationId = Number(o.recordId);
    }

    const r = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
      body: JSON.stringify(payload)
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || ("Could not remove (HTTP " + r.status + ")."));
    return body;
  }

  // Read at call time, not at parse time: the meta tag is in the layout
  // and this script may be evaluated before it on some pages.
  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";

  // Bound once, on first open. The dialog markup is static, so there is
  // nothing to re-bind and no listener to leak.
  //
  // No backdrop dismissal: half-filled work should not vanish on a stray
  // click, so Cancel is the only way out. `cancel` (the Esc key) is
  // allowed through to close() so the dialog does not become a trap.
  function wire() {
    if (wired) return;
    wired = true;
    $("gofClose")?.addEventListener("click", close);
    $("gofCancel")?.addEventListener("click", close);
    $("gofSave")?.addEventListener("click", save);
    $("gofEvidenceAdd")?.addEventListener("click", addEvidence);
    $("gofType")?.addEventListener("change", function () {
      // typedValues is deliberately NOT cleared here: a field the two
      // types share keeps what was typed, which is how the inline version
      // behaved. renderTypedPanel only draws fields the new type has, and
      // save() only sends columns that type actually owns, so nothing
      // stale can reach the database.
      loadTypeFields(this.value);
      // Migration 244: Assurance type is only meaningful for an Assurance
      // obligation, and the Connection type / URL row hangs off
      // assurance_type = Automated -- so both are hidden when the type
      // changes away from Assurance.
      syncAssuranceVisibility();
    });
    $("gofAssuranceType")?.addEventListener("change", syncConnectionVisibility);
    $("gofDialog")?.addEventListener("cancel", e => { e.preventDefault(); close(); });
  }

  // Warm both feeds at page start-up, the way the inline version fetched
  // them during its own init. Optional -- open() awaits them anyway --
  // but calling it means the first Add is instant instead of waiting on
  // two round trips.
  function prime() { return Promise.all([loadTypes(), loadVocabulary()]); }

  // The Assurance vocabulary, for a host that needs it on its READ side
  // too -- the obligation card names a published event from it. Exported
  // so the endpoint is fetched once, here, rather than by every screen
  // that has to spell an event out.
  //
  // Call prime() (or open the form once) before relying on it; until then
  // both arrays are empty, which is also what a database without
  // migration 230 leaves them.
  function vocabulary() { return { triggerModes, eventTypes }; }

  window.gracObligationForm = {
    open, close, retire, loadTypes, prime, vocabulary,
    // Exported so a host can read the presentation contract rather than
    // restate it. `typedArrays` is deliberately NOT here -- see seedOf.
    TYPE_SCHEMA, retiredTypes
  };
})();
