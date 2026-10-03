/* ---------------------------------------------------------------------------
   Role Menu Permission editor  (window.__roleMenuPermissionEditor)

   The menu-permission matrix that used to be its own "Role Menu Permission"
   screen, now rendered as a section INSIDE the Role add/edit editor so a role
   and its permissions are managed in one place. It replaces the "Event
   Checklists for this Role" section, which moved to Profile.

   Contract (mirrors scope-checklist-editor.js so practice.js wires it the
   same way):
     __roleMenuPermissionEditor.render(host, { roleId, organizationId, readonly })
     __roleMenuPermissionEditor.flushPending(roleId) -> { saved, failed }

   TICKING STAGES, THE HOST's SAVE WRITES. Every checkbox only updates the
   in-memory state; nothing is written until the Role dialog's Save calls
   flushPending(roleId). That lets a brand-new role (no id yet) collect
   permissions and persist them the moment it is created.

   SOURCES (unchanged, reused):
     - Menus:  POST {api}/menu-master/query  -> already status='Active' only,
               carries ParentMenuId so the matrix follows the Menu Master
               Parent -> Child hierarchy rather than a flat list.
     - Saved:  POST {api}/role-menu-permissions/query  (by organization)
     - Write:  POST {api}/role-menu-permissions  (upsert, UNIQUE(role,menu))
     - Advanced Settings (migration 415): the role's View Data Scope,
               GET/POST {appBase}/practice/api/roles/{roleId}/view-data-scope
               -- staged like the matrix and written by the same Save.
   The saved rows are what sign-in reads (organization_role_menu_permission),
   so no new permission framework is introduced -- enforcement is the existing
   one.
--------------------------------------------------------------------------- */
(function () {
  if (window.__roleMenuPermissionEditor) return;

  const appBasePath = () => (window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const apiBase = () => (window.pmApi || (appBasePath() + "/practice-management-gateway")).replace(/\/+$/, "");
  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";
  const esc = value => String(value ?? "").replace(/[&<>"']/g, ch =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);

  // Permission columns, in display order. can_view/add/edit/delete/approve are
  // every type the schema and sign-in already support -- all preserved.
  const PERMS = [
    { field: "canView",    col: "CanView",    label: "View" },
    { field: "canAdd",     col: "CanAdd",     label: "Add" },
    { field: "canEdit",    col: "CanEdit",    label: "Edit" },
    { field: "canDelete",  col: "CanDelete",  label: "Delete" },
    { field: "canApprove", col: "CanApprove", label: "Approve" }
  ];

  // Menus that are structural/never permissionable in this matrix.
  const EXCLUDED_KEYS = new Set(["menu-master", "role-menu-permissions"]);

  const unwrap = v => (v && typeof v === "object" && !Array.isArray(v) && ("value" in v || "Value" in v))
    ? (v.value ?? v.Value) : v;
  function rowsOf(result) {
    let d = unwrap(result && (result.data ?? result.Data));
    if (!Array.isArray(d)) return [];
    if (d.length && !Array.isArray(d[0]) && d[0] && typeof d[0] === "object") return d;
    const t = unwrap(d[0] ?? []);
    return Array.isArray(t) ? t : (t && typeof t === "object" ? [t] : []);
  }
  const val = (row, name) => row?.[name] ?? row?.[name[0]?.toUpperCase() + name.slice(1)] ?? "";
  const boolv = (row, name) => {
    const v = val(row, name);
    if (typeof v === "boolean") return v;
    if (typeof v === "number") return v !== 0;
    const s = String(v).trim().toLowerCase();
    return s === "1" || s === "true" || s === "yes";
  };

  // state: the one live matrix. perm[menuId] = {canView,...} (UI state);
  // original[menuId] = same shape from the server (or all-false); rowId[menuId]
  // = existing role_menu_permission id (0 when none).
  const state = {
    opts: null, host: null, orgEl: null, menus: [], byId: new Map(),
    perm: new Map(), original: new Map(), rowId: new Map(),
    // 415: Advanced Settings -> View Data Scope. viewScope is the UI value,
    // viewScopeOriginal what the server holds (ALL for a new role -- the
    // column default, i.e. the unrestricted behaviour every role had).
    viewScope: "ALL", viewScopeOriginal: "ALL", viewScopeAvailable: true
  };

  // The View Data Scope options (organization_role.view_data_scope, 415).
  // "All records" is the explicit default every existing role carries.
  const VIEW_SCOPES = [
    { value: "ALL",      label: "All records",    hint: "No restriction -- every record of the module (the default)." },
    { value: "LOCATION", label: "Location",       hint: "Records of the user's own location." },
    { value: "TEAM",     label: "Team",           hint: "Records assigned to the user's teams." },
    { value: "OWNER",    label: "Assigned Owner", hint: "Only records the user owns." }
  ];
  const roleScopeUrl = roleId => `${appBasePath()}/practice/api/roles/${encodeURIComponent(roleId)}/view-data-scope`;

  // The organization can come from the caller, from an Organization <select>
  // inside the role dialog (Role Master Add picks it there), or from the
  // screen-level organization filter. Resolved live so a save always uses the
  // org currently chosen, not whatever was set when the section first drew.
  function resolveOrg() {
    return Number(
      (state.opts && state.opts.organizationId)
      || state.orgEl?.value
      || document.querySelector("#organizationFilter")?.value
      || 0
    );
  }

  const blank = () => PERMS.reduce((o, p) => (o[p.field] = false, o), {});
  const same = (a, b) => PERMS.every(p => !!a[p.field] === !!b[p.field]);
  const allOn = m => PERMS.every(p => !!m[p.field]);
  const anyOn = m => PERMS.some(p => !!m[p.field]);

  async function postJson(path, body) {
    const r = await fetch(`${apiBase()}/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
      credentials: "same-origin",
      body: JSON.stringify(body)
    });
    if (!r.ok) {
      let msg = "HTTP " + r.status;
      try { const b = await r.json(); msg = b.error || b.Error || b.message || msg; } catch (_) { }
      throw new Error(msg);
    }
    return r.json().catch(() => ({}));
  }

  // Build Parent -> Child sections from Menu Master's own hierarchy. A parent
  // that is a real screen (has a url) also gets its own permission row; pure
  // containers (# / empty url) are headers only.
  //
  // Only menus the sidebar can actually reach are listed. The menu-master
  // query returns ACTIVE rows only, and the sidebar (PracticeMenuService.
  // BuildMenuItems) builds its tree from the roots down, so a menu whose
  // parent is inactive -- and everything beneath it -- never appears there.
  // It used to be promoted to top level here instead, which put sections
  // such as Practices (parent Governance inactive) in the matrix with no
  // matching menu. A menu with no parent is a root, as in the sidebar.
  function reachableMenus() {
    const byId = state.byId;
    const reachable = new Map();   // id -> true / false, memoised
    const isReachable = (m, depth) => {
      const id = String(val(m, "Id"));
      if (reachable.has(id)) return reachable.get(id);
      const pid = Number(val(m, "ParentMenuId") || 0);
      let ok;
      if (!pid) ok = true;                               // root
      else if (!byId.has(String(pid)) || depth > 50) ok = false; // parent inactive (or a cycle)
      else ok = isReachable(byId.get(String(pid)), depth + 1);
      reachable.set(id, ok);
      return ok;
    };
    return state.menus.filter(m => isReachable(m, 0));
  }

  function buildSections() {
    const menus = reachableMenus();
    const byId = state.byId;
    const isContainer = m => {
      const u = String(val(m, "MenuUrl") || "").trim();
      return u === "" || u === "#";
    };
    const childrenOf = new Map();
    const tops = [];
    menus.forEach(m => {
      const pid = Number(val(m, "ParentMenuId") || 0);
      if (pid && byId.has(String(pid))) {
        if (!childrenOf.has(String(pid))) childrenOf.set(String(pid), []);
        childrenOf.get(String(pid)).push(m);
      } else {
        tops.push(m);
      }
    });
    const ord = (a, b) => Number(val(a, "DisplayOrder") || 0) - Number(val(b, "DisplayOrder") || 0);
    tops.sort(ord);
    return tops.map(top => {
      const kids = (childrenOf.get(String(val(top, "Id"))) || []).slice().sort(ord);
      let rows;
      if (kids.length) {
        // Parent that is also a screen keeps its own row so its permission is
        // not lost; a container contributes only its children.
        rows = (isContainer(top) ? [] : [top]).concat(kids);
      } else {
        rows = [top]; // top-level leaf: the section is the menu itself
      }
      return { parent: top, rows, isCategory: kids.length > 0 };
    });
  }

  function currentOf(menuId) {
    const key = String(menuId);
    if (!state.perm.has(key)) state.perm.set(key, blank());
    return state.perm.get(key);
  }

  // ---- rendering ---------------------------------------------------------
  function render(host, opts) {
    host.querySelector("[data-role-menu-perms]")?.remove();
    const section = document.createElement("div");
    section.className = "pm-panel pm-role-perms";
    section.setAttribute("data-role-menu-perms", "1");
    section.innerHTML = `
      <div class="pm-section-heading">
        <h2>Menu Permissions</h2>
        <p>What this role can see and do, by menu. Saved with the role.</p>
      </div>
      <div class="pm-role-perms-body"><div class="pm-empty compact">Loading menus and permissions...</div></div>
      <div class="pm-role-adv" data-role-adv>
        <div class="pm-section-heading">
          <h2>Advanced Settings</h2>
          <p>Which records this role's users see where they have View access. Menu access is still decided by the matrix above.</p>
        </div>
        <div class="pm-role-adv-body"></div>
      </div>`;
    host.appendChild(section);
    state.host = host;
    // The role dialog's own Organization <select>, if present. Reload the
    // matrix when it changes so picking an org fills the section in place.
    const orgEl = host.querySelector("[name='organizationId']");
    state.orgEl = orgEl || null;
    if (orgEl && !orgEl.__rmpBound) {
      orgEl.__rmpBound = true;
      orgEl.addEventListener("change", () => {
        const s = host.querySelector("[data-role-menu-perms]");
        if (s) load(s, { ...state.opts, organizationId: orgEl.value });
      });
    }
    load(section, opts);
    return section;
  }

  async function load(section, opts) {
    state.opts = opts;
    state.menus = []; state.byId = new Map();
    state.perm = new Map(); state.original = new Map(); state.rowId = new Map();
    const body = section.querySelector(".pm-role-perms-body");
    // Menus are global (menu-master is not org-scoped), so the matrix renders
    // right away. The organization is only needed to preload an existing
    // role's saved permissions and to save -- resolved live from the dialog.
    const orgId = resolveOrg();
    loadViewScope(section, opts, orgId);
    try {
      const [menuRes, permRes] = await Promise.all([
        postJson("menu-master/query", { data: { pageNumber: 1, pageSize: 500 } }),
        (opts.roleId && orgId)
          ? postJson("role-menu-permissions/query", { data: { organizationId: orgId, pageNumber: 1, pageSize: 1000 } })
          : Promise.resolve({})
      ]);
      state.menus = rowsOf(menuRes)
        .filter(m => !EXCLUDED_KEYS.has(String(val(m, "MenuKey"))))
        .sort((a, b) => Number(val(a, "DisplayOrder") || 0) - Number(val(b, "DisplayOrder") || 0));
      state.menus.forEach(m => state.byId.set(String(val(m, "Id")), m));

      const existing = opts.roleId
        ? rowsOf(permRes).filter(p => String(val(p, "RoleId")) === String(opts.roleId))
        : [];
      const existingByMenu = new Map(existing.map(p => [String(val(p, "MenuId")), p]));
      state.menus.forEach(m => {
        const key = String(val(m, "Id"));
        const ex = existingByMenu.get(key);
        const cur = ex ? PERMS.reduce((o, p) => (o[p.field] = boolv(ex, p.col), o), {}) : blank();
        state.perm.set(key, cur);
        state.original.set(key, { ...cur });
        state.rowId.set(key, ex ? Number(val(ex, "Id") || 0) : 0);
      });
      draw(section);
    } catch (err) {
      body.innerHTML = `<div class="pm-empty compact">${esc(err.message || "Unable to load menu permissions.")}</div>`;
    }
  }

  // ---- Advanced Settings: View Data Scope (415) -----------------------
  async function loadViewScope(section, opts, orgId) {
    state.viewScope = state.viewScopeOriginal = "ALL";
    state.viewScopeAvailable = true;
    if (opts.roleId && orgId) {
      try {
        const r = await fetch(`${roleScopeUrl(opts.roleId)}?organizationId=${encodeURIComponent(orgId)}`,
                              { credentials: "same-origin" });
        if (!r.ok) throw new Error("HTTP " + r.status);
        const b = await r.json();
        state.viewScope = state.viewScopeOriginal = String(val(b, "viewDataScope") || "ALL").toUpperCase();
      } catch (_) {
        state.viewScopeAvailable = false;
      }
    }
    drawViewScope(section);
  }

  function drawViewScope(section) {
    const body = section.querySelector(".pm-role-adv-body");
    if (!body) return;
    if (!state.viewScopeAvailable) {
      body.innerHTML = `<div class="pm-empty compact">The View Data Scope could not be loaded for this role.</div>`;
      return;
    }
    const dis = state.opts?.readonly ? " disabled" : "";
    body.innerHTML = `
      <fieldset class="pm-view-scope">
        <legend>View Data Scope</legend>
        ${VIEW_SCOPES.map(o => `
          <label class="pm-view-scope-opt">
            <input type="radio" name="rmpViewDataScope" value="${o.value}"${o.value === state.viewScope ? " checked" : ""}${dis} />
            <span><strong>${esc(o.label)}</strong><small>${esc(o.hint)}</small></span>
          </label>`).join("")}
      </fieldset>`;
    body.querySelectorAll("input[name='rmpViewDataScope']").forEach(rb =>
      rb.addEventListener("change", () => { if (rb.checked) state.viewScope = rb.value; }));
  }

  function draw(section) {
    const readonly = !!state.opts.readonly;
    const dis = readonly ? " disabled" : "";
    const sections = buildSections();
    const body = section.querySelector(".pm-role-perms-body");
    if (!sections.length) {
      body.innerHTML = `<div class="pm-empty compact">No active menus are available for permission assignment.</div>`;
      return;
    }
    const headCols = ["Menu", "All", ...PERMS.map(p => p.label)];
    const rowsHtml = sections.map((sec, si) => {
      const parentId = String(val(sec.parent, "Id"));
      const parentName = esc(val(sec.parent, "MenuName"));
      // A header row only for a real category (a parent with children). A
      // top-level leaf menu is drawn as a plain row, no header. The category
      // "All" checkbox shows only when the category has more than one row --
      // with a single row its own row-All is the same thing, so a category
      // All there would be redundant. When shown, it is a bare checkbox
      // centred in the All column so it lines up with the row All checkboxes.
      const showParentAll = sec.isCategory && sec.rows.length > 1;
      // Beside the category All, one checkbox per permission column sets
      // that single permission (View / Add / Edit / Delete / Approve) on
      // every menu of the category. Both are .pm-perms-bulk, drawn heavier
      // than the per-menu boxes so they read as "all of the rows below".
      const bulkPerms = PERMS.map(p => `
          <td class="pm-perms-check">${showParentAll
            ? `<input type="checkbox" class="pm-perms-bulk" data-parent-perm="${p.field}" data-bulk-section="${si}" title="${esc(p.label)} for all menus in ${parentName}" aria-label="${esc(p.label)} for all menus in ${parentName}"${dis}>`
            : ""}</td>`).join("");
      const header = sec.isCategory ? `
        <tr class="pm-perms-parent" data-parent-section="${si}">
          <td>${parentName}</td>
          <td class="pm-perms-check">${showParentAll
            ? `<input type="checkbox" class="pm-perms-bulk" data-parent-all="${si}" title="All permissions for all menus in ${parentName}" aria-label="Select all permissions for ${parentName}"${dis}>`
            : ""}</td>${bulkPerms}
        </tr>` : "";
      const rows = sec.rows.map(menu => {
        const menuId = String(val(menu, "Id"));
        const isParentRow = sec.isCategory && menuId === parentId;
        const label = esc(val(menu, "MenuName"))
          + ` <small class="pm-perms-key">${esc(val(menu, "MenuKey"))}</small>`;
        const cells = PERMS.map(p =>
          `<td class="pm-perms-check"><input type="checkbox" data-perm="${p.field}" data-menu="${esc(menuId)}"${dis}></td>`
        ).join("");
        return `
          <tr class="pm-perms-row${isParentRow ? " pm-perms-row-parent-self" : ""}" data-menu-row="${esc(menuId)}" data-section="${si}">
            <td class="pm-perms-menu">${label}</td>
            <td class="pm-perms-check"><input type="checkbox" data-row-all="${esc(menuId)}"${dis}></td>
            ${cells}
          </tr>`;
      }).join("");
      return header + rows;
    }).join("");

    body.innerHTML = `
      <div class="pm-table-wrap pm-role-perms-table">
        <table class="pm-table">
          <thead><tr>${headCols.map((c, i) =>
            `<th${i >= 1 ? ' class="pm-perms-check"' : ""}>${esc(c)}</th>`).join("")}</tr></thead>
          <tbody>${rowsHtml}</tbody>
        </table>
      </div>`;

    // paint every checkbox from state
    section.querySelectorAll("[data-menu-row]").forEach(tr => syncRow(section, tr.getAttribute("data-menu-row")));
    section.querySelectorAll("[data-parent-all]").forEach(cb => syncParent(section, Number(cb.getAttribute("data-parent-all"))));

    if (!readonly) wire(section);
  }

  function wire(section) {
    section.addEventListener("change", e => {
      const t = e.target;
      if (t.matches("[data-perm]")) {
        const menuId = t.getAttribute("data-menu");
        currentOf(menuId)[t.getAttribute("data-perm")] = t.checked;
        syncRow(section, menuId);
        syncParent(section, sectionIndexOfMenu(section, menuId));
      } else if (t.matches("[data-row-all]")) {
        const menuId = t.getAttribute("data-row-all");
        const cur = currentOf(menuId);
        PERMS.forEach(p => cur[p.field] = t.checked);
        syncRow(section, menuId);
        syncParent(section, sectionIndexOfMenu(section, menuId));
      } else if (t.matches("[data-parent-perm]")) {
        // One permission column for every menu in the category.
        const si = Number(t.getAttribute("data-bulk-section"));
        const field = t.getAttribute("data-parent-perm");
        section.querySelectorAll(`[data-menu-row][data-section="${si}"]`).forEach(tr => {
          const menuId = tr.getAttribute("data-menu-row");
          currentOf(menuId)[field] = t.checked;
          syncRow(section, menuId);
        });
        syncParent(section, si);
      } else if (t.matches("[data-parent-all]")) {
        const si = Number(t.getAttribute("data-parent-all"));
        section.querySelectorAll(`[data-menu-row][data-section="${si}"]`).forEach(tr => {
          const menuId = tr.getAttribute("data-menu-row");
          const cur = currentOf(menuId);
          PERMS.forEach(p => cur[p.field] = t.checked);
          syncRow(section, menuId);
        });
        syncParent(section, si);
      }
    });
  }

  function sectionIndexOfMenu(section, menuId) {
    const tr = section.querySelector(`[data-menu-row="${cssEsc(menuId)}"]`);
    return tr ? Number(tr.getAttribute("data-section")) : -1;
  }
  const cssEsc = v => String(v).replace(/["\\]/g, "\\$&");

  // Row: paint each perm + the row-All (checked/indeterminate/unchecked).
  function syncRow(section, menuId) {
    const cur = currentOf(menuId);
    const tr = section.querySelector(`[data-menu-row="${cssEsc(menuId)}"]`);
    if (!tr) return;
    PERMS.forEach(p => {
      const cb = tr.querySelector(`[data-perm="${p.field}"][data-menu="${cssEsc(menuId)}"]`);
      if (cb) cb.checked = !!cur[p.field];
    });
    const rowAll = tr.querySelector(`[data-row-all]`);
    if (rowAll) {
      rowAll.checked = allOn(cur);
      rowAll.indeterminate = !allOn(cur) && anyOn(cur);
    }
  }

  // Parent-All: checked when every row in the section is fully on; unchecked
  // when nothing is on; indeterminate for anything between. Each category
  // permission column follows the same rule for its one permission.
  function syncParent(section, si) {
    if (si < 0) return;
    const rows = [...section.querySelectorAll(`[data-menu-row][data-section="${si}"]`)]
      .map(tr => currentOf(tr.getAttribute("data-menu-row")));
    const cb = section.querySelector(`[data-parent-all="${si}"]`);
    if (cb) {
      const full = rows.length && rows.every(allOn);
      const none = rows.every(m => !anyOn(m));
      cb.checked = full;
      cb.indeterminate = !full && !none;
    }
    section.querySelectorAll(`[data-parent-perm][data-bulk-section="${si}"]`).forEach(pcb => {
      const field = pcb.getAttribute("data-parent-perm");
      const on = rows.filter(m => !!m[field]).length;
      pcb.checked = rows.length > 0 && on === rows.length;
      pcb.indeterminate = on > 0 && on < rows.length;
    });
  }

  // ---- persistence -------------------------------------------------------
  // Write every row whose UI state differs from what was loaded. A brand-new
  // role passes its fresh id in as roleId. Existing rows update in place
  // (their id is carried); new ticks insert. Rows unchanged are skipped, so no
  // duplicate writes.
  async function flushPending(roleId) {
    const rid = Number(roleId || state.opts?.roleId || 0);
    const orgId = resolveOrg();
    if (!rid || !orgId) return { saved: 0, failed: 0 };
    let saved = 0, failed = 0;
    // 415: the role's View Data Scope, when it changed.
    if (state.viewScopeAvailable && state.viewScope !== state.viewScopeOriginal) {
      try {
        const r = await fetch(roleScopeUrl(rid), {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
          credentials: "same-origin",
          body: JSON.stringify({ organizationId: orgId, viewDataScope: state.viewScope })
        });
        if (!r.ok) throw new Error("HTTP " + r.status);
        state.viewScopeOriginal = state.viewScope;
        saved++;
      } catch (_) { failed++; }
    }
    for (const [menuId, cur] of state.perm.entries()) {
      const orig = state.original.get(menuId) || blank();
      if (same(cur, orig)) continue;
      const id = state.rowId.get(menuId) || 0;
      if (!id && !anyOn(cur)) continue; // nothing to insert
      try {
        const res = await postJson("role-menu-permissions", {
          id: id || 0,
          data: {
            organizationId: orgId, roleId: rid, menuId: Number(menuId),
            canView: cur.canView, canAdd: cur.canAdd, canEdit: cur.canEdit,
            canDelete: cur.canDelete, canApprove: cur.canApprove
          }
        });
        // adopt server id + new baseline so a second Save is a no-op
        const savedRow = rowsOf(res)[0];
        if (savedRow) state.rowId.set(menuId, Number(val(savedRow, "Id") || id || 0));
        state.original.set(menuId, { ...cur });
        saved++;
      } catch (_) { failed++; }
    }
    return { saved, failed };
  }

  function hasPending() {
    if (state.viewScopeAvailable && state.viewScope !== state.viewScopeOriginal) return true;
    for (const [menuId, cur] of state.perm.entries()) {
      if (!same(cur, state.original.get(menuId) || blank())) return true;
    }
    return false;
  }

  window.__roleMenuPermissionEditor = { render, flushPending, hasPending };
})();
