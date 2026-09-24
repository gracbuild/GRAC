(() => {
  "use strict";

  const iconMap = {
    success: "fa-solid fa-check",
    info: "fa-solid fa-info",
    warning: "fa-solid fa-triangle-exclamation",
    error: "fa-solid fa-xmark",
    confirm: "fa-solid fa-question"
  };
  const titleMap = { success: "Success", info: "Information", warning: "Warning", error: "Unable to continue", confirm: "Please confirm" };
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" })[char]);

  function closeOverlay(overlay, resolve, value) {
    overlay.classList.add("closing");
    window.setTimeout(() => { overlay.remove(); resolve(value); }, 140);
  }

  function show(options = {}) {
    const type = options.type || (options.confirm ? "confirm" : "info");
    const needsCancel = options.confirm || options.prompt;
    const overlay = document.createElement("div");
    overlay.className = "grac-dialog-overlay";
    overlay.innerHTML = `
      <section class="grac-dialog" role="dialog" aria-modal="true" aria-labelledby="gracDialogTitle">
        <div class="grac-dialog-body">
          <div class="grac-dialog-icon ${escapeHtml(type)}"><i class="${escapeHtml(iconMap[type] || iconMap.info)}" aria-hidden="true"></i></div>
          <div>
            <h2 class="grac-dialog-title" id="gracDialogTitle">${escapeHtml(options.title || titleMap[type] || titleMap.info)}</h2>
            <p class="grac-dialog-message">${escapeHtml(options.message || "")}</p>
            ${options.prompt ? `<input class="grac-dialog-input" type="text" value="${escapeHtml(options.defaultValue || "")}" aria-label="${escapeHtml(options.inputLabel || "Comments")}">` : ""}
          </div>
        </div>
        <div class="grac-dialog-actions">
          ${needsCancel ? `<button type="button" class="grac-dialog-button secondary" data-grac-dialog-cancel>${escapeHtml(options.cancelText || "Cancel")}</button>` : ""}
          <button type="button" class="grac-dialog-button primary" data-grac-dialog-ok>${escapeHtml(options.confirmText || "OK")}</button>
        </div>
      </section>`;
    document.body.appendChild(overlay);
    return new Promise(resolve => {
      const ok = overlay.querySelector("[data-grac-dialog-ok]");
      const cancel = overlay.querySelector("[data-grac-dialog-cancel]");
      const input = overlay.querySelector(".grac-dialog-input");
      const finish = value => closeOverlay(overlay, resolve, value);
      ok.focus();
      if (input) { input.focus(); input.select(); }
      ok.addEventListener("click", () => finish(options.prompt ? input.value : true));
      cancel?.addEventListener("click", () => finish(options.prompt ? null : false));
      overlay.addEventListener("keydown", event => {
        if (event.key === "Escape") { event.preventDefault(); finish(options.prompt ? null : false); }
        if (event.key === "Enter" && options.prompt && document.activeElement === input) { event.preventDefault(); finish(input.value); }
      });
    });
  }

  const api = {
    show,
    alert: options => show({ ...(typeof options === "string" ? { message: options } : options), confirm: false }),
    confirm: options => show({ ...(typeof options === "string" ? { message: options } : options), type: (options && options.type) || "confirm", confirm: true }),
    prompt: options => show({ ...(typeof options === "string" ? { message: options } : options), type: (options && options.type) || "info", prompt: true, confirmText: (options && options.confirmText) || "Continue" })
  };

  window.GracDialog = api;
  window.gracAlert = api.alert;
  window.gracConfirm = api.confirm;
  window.gracPrompt = api.prompt;
  window.alert = message => { api.alert({ message, type: "info" }); };

  // -------------------------------------------------------------------
  // window.gracUi -- message-first convenience wrapper.
  //
  // WHY IT EXISTS
  // -------------
  // window.alert is replaced above, so every alert() in the product
  // already gets this styling for free. confirm() and prompt() CANNOT be
  // replaced the same way: they are synchronous and return a value, while
  // this dialog is a Promise. Overriding them would make every
  // `if (confirm(...))` pass unconditionally, because a Promise is always
  // truthy -- a silent, dangerous change. So each call site has to be
  // converted by hand, and this is what it converts TO:
  //
  //     if (!await gracUi.confirm("Retire this release?")) return;
  //     const reason = await gracUi.prompt("Why not applicable?");
  //     if (reason === null) return;      // cancelled
  //
  // prompt() resolves to the typed string or null when cancelled -- the
  // same contract window.prompt has, so a converted call site reads the
  // same as it did before.
  //
  // Lifted from RiskCentre/risk-centre.js's local `dlg`, which had the
  // right shape but was reachable only from that one file. Every native
  // fallback below is kept for the same reason it had them: a page that
  // somehow loads without this file still asks the question rather than
  // silently doing nothing.
  // -------------------------------------------------------------------
  window.gracUi = {
    alert: (message, opts = {}) =>
      api.alert({ type: opts.type || "info", title: opts.title, message,
                  confirmText: opts.confirmText }),

    confirm: (message, opts = {}) =>
      api.confirm({ type: opts.type || "confirm", title: opts.title, message,
                    confirmText: opts.confirmText, cancelText: opts.cancelText }),

    prompt: (message, opts = {}) =>
      api.prompt({ type: opts.type || "info", title: opts.title, message,
                   defaultValue: opts.defaultValue || "",
                   inputLabel: opts.inputLabel, confirmText: opts.confirmText }),

    // promptRequired -- like prompt(), but a blank answer re-asks instead
    // of resolving. Cancel still resolves to null, same contract as
    // prompt() itself, so `if (reason === null) return;` keeps working
    // unchanged at the call site.
    //
    // Added for 355 (Retire/Restore instance): both acts need a reason
    // that cannot be skipped by clicking through with nothing typed, and
    // this belongs here rather than duplicated in each call site's own
    // loop -- any future "reason required" prompt reuses it too.
    promptRequired: async (message, opts = {}) => {
      let prefixedMessage = message;
      for (;;) {
        const value = await api.prompt({
          type: opts.type || "info", title: opts.title, message: prefixedMessage,
          defaultValue: opts.defaultValue || "",
          inputLabel: opts.inputLabel, confirmText: opts.confirmText
        });
        if (value === null) return null;                 // cancelled
        const trimmed = value.trim();
        if (trimmed) return trimmed;
        prefixedMessage = (opts.requiredNote || "A reason is required.") + "\n\n" + message;
      }
    }
  };
})();
