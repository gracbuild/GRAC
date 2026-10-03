// =====================================================================
// window.gracPageActions -- the "Actions" button + menu of a full-page
// record view (2026-10-03).
//
// The same button and menu Gap / Task / Exception View use: a .pm-button
// "Actions" in the page heading opening a .pm-action-menu appended to the
// document body (so no table or panel clips it), positioned under the
// button, closed on an outside click, Escape, resize and scroll, and
// reading "No actions available" when nothing applies. Those three pages
// each carry their own copy of this behaviour; Practice View and the
// Operationalize workspace share this one instead of adding two more.
//
//   window.gracPageActions.attach(buttonId, getItems)
//
// getItems() is called every time the menu opens, so each item reflects
// the record's state at that moment. It returns
//   [{ icon: "fa-...", label: "...", run: () => {...} }, ...]
// and the page decides which items apply (permission, status) -- this
// module only draws and dismisses the menu.
// =====================================================================
(function () {
  "use strict";

  const escapeHtml = v => String(v ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c]);

  function attach(buttonId, getItems) {
    const btn = document.getElementById(buttonId);
    if (!btn) return null;
    let menu = null;

    function close() {
      if (menu) { menu.remove(); menu = null; }
      btn.setAttribute("aria-expanded", "false");
    }

    function open() {
      menu = document.createElement("div");
      menu.className = "pm-action-menu";
      menu.setAttribute("role", "menu");
      const items = (getItems() || []).filter(Boolean);
      if (!items.length) {
        const p = document.createElement("div");
        p.style.cssText = "padding:8px 12px; font-size:12px; color:var(--fg-subtle); white-space:nowrap;";
        p.textContent = "No actions available";
        menu.appendChild(p);
      }
      items.forEach(it => {
        const b = document.createElement("button");
        b.type = "button";
        b.setAttribute("role", "menuitem");
        b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
        b.addEventListener("click", e => {
          e.preventDefault();
          e.stopPropagation();
          close();
          try { it.run(); } catch (err) { console.error("[page-actions] action failed", err); }
        });
        menu.appendChild(b);
      });
      document.body.appendChild(menu);
      btn.setAttribute("aria-expanded", "true");

      const r = btn.getBoundingClientRect(), mr = menu.getBoundingClientRect(), gap = 6;
      let top = r.bottom + gap, left = r.left;
      if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - gap);
      if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
      if (left < 8) left = 8;
      menu.style.top = `${top}px`;
      menu.style.left = `${left}px`;
    }

    btn.addEventListener("click", () => { if (menu) close(); else open(); });
    document.addEventListener("click", e => {
      if (!menu || menu.contains(e.target) || btn.contains(e.target)) return;
      close();
    });
    document.addEventListener("keydown", e => { if (e.key === "Escape") close(); });
    window.addEventListener("resize", close);
    window.addEventListener("scroll", close, true);
    return { close };
  }

  window.gracPageActions = { attach };
})();
