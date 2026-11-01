// =====================================================================
// window.gracEvidenceUpload -- THE "Upload evidence" dialog
// (migration 499).
//
// Pairs with Views/Practice/Partials/_evidence-upload-dialog.cshtml.
// Include that partial once on a page, load this script, and any screen
// on that page can open the one Evidence Center item form:
//   * Evidence Center  (upload / edit / new version)
//   * Operationalize   -- one-time evidence, Direct Upload
//   * Complete Task    -- evidence, Direct Upload
//
// WHY IT EXISTS
//   Direct Upload used to be a bare file picker on the other two
//   screens. The file DID reach the Evidence Center (both attachment
//   procedures call sp_evidence_item_store), but with no title, type,
//   validity, classification, tags or chosen owner -- so the operator had
//   to describe the item a second time on the Evidence Center screen.
//   One dialog, used from all three, is what fixes that; 499 carries the
//   captured fields through the existing per-screen endpoints.
//
// USAGE
//   const r = await window.gracEvidenceUpload.open({
//     mode:    "NEW",               // NEW (default) | EDIT | VERSION
//     context: "Evidence: Access review report",   // optional, shown on top
//     item:    {...},               // EDIT / VERSION prefill (either key case)
//     typeId:  12,                  // NEW: preselect the row's evidence type
//     lookups: { types: [...], employees: [...] },  // the host already has these
//     submit:  async ({ mode, file, metadata, versionNote, allowDuplicate }) =>
//                ({ ok, message, error, itemId,
//                   duplicate, duplicateItemId, duplicateText }),
//     onOpenDuplicate: itemId => { ... }   // optional "Open existing"
//   });
//   // r = { saved: true, message, itemId } | { saved: false }
//
// The HOST passes submit, so the dialog knows nothing about endpoints or
// permissions -- the same arrangement Shared/evidence-picker.js uses for
// "Select from Evidence Center". The Evidence Center posts to its own
// /upload (which needs evidence-center ADD); Operationalize and Complete
// Task post to their own attachments endpoints, so a user who may
// operationalize but holds no Evidence Center grant can still upload.
//
// VALIDATION lives here and nowhere else: a file is required for NEW and
// VERSION, everything else is optional. That is the Evidence Center's own
// rule, and making a field mandatory here makes it mandatory on all three
// screens at once.
// =====================================================================
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const val = id => ($(id)?.value || "").trim();
  const setVal = (id, v) => { const el = $(id); if (el) el.value = v ?? ""; };
  const F = (row, key) =>
    row ? (row[key] ?? row[key.charAt(0).toUpperCase() + key.slice(1)] ?? "") : "";

  // yyyy-mm-dd for <input type="date">; anything unparseable becomes "".
  const dateOnly = v => {
    if (!v) return "";
    const s = String(v);
    return s.length >= 10 && s[4] === "-" ? s.slice(0, 10) : "";
  };

  function message(text, kind) {
    const el = $("ecEditMessage");
    if (!el) return;
    if (!text) { el.hidden = true; el.textContent = ""; return; }
    el.hidden = false;
    el.textContent = text;
    el.className = "pm-message full" + (kind ? " " + kind : "");
  }

  function hideDuplicate() {
    const el = $("ecEdDuplicate");
    if (el) el.hidden = true;
  }

  // Deliberately tolerant of the host's lookup shape. The three screens
  // get these lists from three different feeds: the Evidence Center's own
  // /lookups ({evidenceTypeId, evidenceType} / {employeeId, employeeName}),
  // the gateway lookups Operationalize already loads ({value, label}), and
  // the task page's organisation employees endpoint. Normalising here
  // keeps that mapping out of all three hosts.
  function fillSelect(id, rows, valueKey, labelKey, placeholder) {
    const sel = $(id);
    if (!sel) return;
    sel.innerHTML = `<option value="">${placeholder}</option>`;
    (rows || []).forEach(row => {
      const v = F(row, valueKey) || F(row, "value") || F(row, "id");
      const l = F(row, labelKey) || F(row, "label") || F(row, "name");
      if (v === null || v === undefined || v === "") return;
      const o = document.createElement("option");
      o.value = String(v);
      o.textContent = String(l || v);
      sel.appendChild(o);
    });
  }

  // The fields as the dialog holds them. Shape matches the Api's
  // EvidenceUploadMetadata record and the Evidence Center's own
  // /upload form field names, so a host can post it straight through.
  function metadata() {
    return {
      evidenceTitle:       val("ecEdTitle") || null,
      evidenceTypeId:      val("ecEdType") ? Number(val("ecEdType")) : null,
      evidenceDescription: val("ecEdDescription") || null,
      ownerEmployeeId:     val("ecEdOwner") ? Number(val("ecEdOwner")) : null,
      validFrom:           val("ecEdValidFrom") || null,
      validTo:             val("ecEdValidTo") || null,
      classification:      val("ecEdClass") || "Internal",
      tags:                val("ecEdTags") || null
    };
  }

  // One open dialog at a time. The handlers are bound on open and
  // removed on close, so two screens on one page cannot both own the
  // form (the Evidence Center keeps its own grid handlers either way).
  let session = null;

  function close(result) {
    const modal = $("ecEditModal");
    if (modal) modal.hidden = true;
    if (!session) return;
    const { form, dupOpen, dupUpload, closers, resolve } = session;
    form?.removeEventListener("submit", session.onSubmit);
    dupOpen?.removeEventListener("click", session.onDupOpen);
    dupUpload?.removeEventListener("click", session.onDupUpload);
    closers.forEach(b => b.removeEventListener("click", session.onClose));
    const r = result || { saved: false };
    session = null;
    resolve(r);
  }

  function open(options) {
    const o = options || {};
    const mode = o.mode || "NEW";
    const item = o.item || null;

    // A second open() while one is up closes the first rather than
    // stacking two sets of handlers on the one form.
    if (session) close({ saved: false });

    const modal = $("ecEditModal");
    if (!modal) {
      console.error("[grac-evidence-upload] _evidence-upload-dialog partial is not on this page.");
      return Promise.resolve({ saved: false });
    }

    message(null);
    hideDuplicate();

    fillSelect("ecEdType", (o.lookups || {}).types, "evidenceTypeId", "evidenceType", "--");
    fillSelect("ecEdOwner", (o.lookups || {}).employees, "employeeId", "employeeName",
               mode === "NEW" ? "Me" : "--");

    setVal("ecEdFile", "");
    setVal("ecEdVersionNote", "");
    $("ecEdFileRow").hidden        = mode === "EDIT";
    $("ecEdVersionNoteRow").hidden = mode !== "VERSION";
    document.querySelectorAll("[data-ec-meta]").forEach(x => { x.hidden = mode === "VERSION"; });

    $("ecEditTitle").textContent =
      mode === "NEW" ? "Upload evidence"
      : mode === "VERSION" ? `New version - ${F(item, "evidenceTitle")}`
      : `Edit - ${F(item, "evidenceTitle")}`;

    // The context line tells the operator what this upload answers, which
    // the Evidence Center screen does not need (it has no row in hand).
    $("ecEdNote").textContent =
      o.context ? o.context
      : mode === "NEW" ? "The file is stored once. Link it from Operationalize wherever it is needed."
      : mode === "VERSION" ? "Places already using this evidence keep the version they linked and are offered the new one."
      : "";

    setVal("ecEdTitle",       item ? F(item, "evidenceTitle") : "");
    setVal("ecEdType",        item ? F(item, "evidenceTypeId") : (o.typeId || ""));
    setVal("ecEdOwner",       item ? F(item, "ownerEmployeeId") : "");
    setVal("ecEdValidFrom",   item ? dateOnly(F(item, "validFrom")) : "");
    setVal("ecEdValidTo",     item ? dateOnly(F(item, "validTo")) : "");
    setVal("ecEdClass",       item ? (F(item, "classification") || "Internal") : "Internal");
    setVal("ecEdTags",        item ? F(item, "tags") : "");
    setVal("ecEdDescription", item ? F(item, "evidenceDescription") : "");

    const form      = $("ecEditForm");
    const dupOpen   = $("ecEdDupOpen");
    const dupUpload = $("ecEdDupUpload");
    const closers   = Array.from(document.querySelectorAll('[data-close-ec="ecEditModal"]'));

    return new Promise(resolve => {
      let duplicateItemId = null;

      async function send(allowDuplicate) {
        const input = $("ecEdFile");
        const file  = input && input.files && input.files.length ? input.files[0] : null;
        // The one validation rule, for every screen that opens this.
        if (mode !== "EDIT" && !file) { message("Choose a file."); return; }

        hideDuplicate();
        message(mode === "EDIT" ? "Saving..." : "Uploading...", "info");

        let res;
        try {
          res = await o.submit({
            mode, file,
            metadata: metadata(),
            versionNote: val("ecEdVersionNote") || null,
            allowDuplicate: !!allowDuplicate
          });
        } catch (err) {
          console.error("[grac-evidence-upload] submit failed", err);
          message("Could not upload the file.");
          return;
        }
        res = res || {};

        // The identical file is already in the Evidence Center and this
        // caller can see it: offer it instead of storing a second copy.
        if (res.duplicate) {
          message(null);
          duplicateItemId = res.duplicateItemId || null;
          $("ecEdDuplicateText").textContent =
            (res.duplicateText || res.error || "That file is already in the Evidence Center.")
            + " Open it instead of uploading again?";
          $("ecEdDuplicate").hidden = false;
          return;
        }
        if (!res.ok) { message(res.error || "Upload failed."); return; }

        close({ saved: true, message: res.message || null, itemId: res.itemId || null });
      }

      session = {
        form, dupOpen, dupUpload, closers, resolve,
        onSubmit: ev => { ev.preventDefault(); send(false); },
        onDupOpen: () => {
          const id = duplicateItemId;
          close({ saved: false, openedDuplicateId: id });
          if (id && typeof o.onOpenDuplicate === "function") o.onOpenDuplicate(id);
        },
        onDupUpload: () => send(true),
        onClose: () => close({ saved: false })
      };

      form?.addEventListener("submit", session.onSubmit);
      dupOpen?.addEventListener("click", session.onDupOpen);
      dupUpload?.addEventListener("click", session.onDupUpload);
      closers.forEach(b => b.addEventListener("click", session.onClose));

      modal.hidden = false;
      $("ecEdFile")?.focus();
    });
  }

  window.gracEvidenceUpload = { open, close: () => close({ saved: false }) };
})();
