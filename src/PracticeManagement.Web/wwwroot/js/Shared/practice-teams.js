// =====================================================================
// window.gracPracticeTeams -- pick the teams that carry out a practice and
// create one Practice Instance per team (2026-11-16).
//
// Moved out of Views/Practice/Partials/practice-view.cshtml (its Assign
// Team dialog: loadTeams / renderTeams / updateCount / saveConfigure's
// POST / outcomeSummary) so the applicability dialogs can offer the same
// team list -- sir: marking a practice Applicable picks its teams too, and
// one Save records the applicability AND creates the instances. Used by:
//   * Practice View -- Assign Team dialog and the Mark / Update
//     Applicability dialog (practice-view.cshtml)
//   * Organization Practices list -- Mark / Update Applicability
//     (practice.js openForm / saveForm)
//
//   const pk = gracPracticeTeams.picker({ list, search, selectAll, clear,
//                                         count, save });   // element ids
//   await pk.load(organizationId, practiceId);  // practiceId optional
//   pk.selectedIds(); pk.reset(); pk.loaded
//
//   gracPracticeTeams.blockHtml(prefix)  the "Assign Team" block for a form
//                                        (ids = gracPracticeTeams.ids(prefix))
//   await gracPracticeTeams.createInstances(organizationId, practiceId, teamIds)
//        -> { ok: true, body } | { ok: false, error }
//   gracPracticeTeams.summary(body)      -> { text, kind, note }
//   gracPracticeTeams.summaryText(body)  -> text + note
//
// Data: GET  /practice/api/workflow/practice-configure/teams
//       POST /practice/api/workflow/practice-configure/instances
//       (PracticeConfigureController -> sp_practice_instance_configure)
// =====================================================================
(function () {
  "use strict";
  if (window.gracPracticeTeams) return;

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const CSRF = () => document.querySelector('meta[name="csrf-token"]')?.content
                  || document.querySelector("input[name='__RequestVerificationToken']")?.value || "";
  const esc = v => (window.__wfCommon ? window.__wfCommon.escape(v)
    : String(v ?? "").replace(/[&<>"']/g, c =>
        ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c]));

  // ---------------------------------------------------------------
  // One picker = one team list with its own teams and selection.
  // ---------------------------------------------------------------
  function picker(ids) {
    const el = id => (id ? document.getElementById(id) : null);
    const st = { teams: [], selected: new Set(), loaded: false };

    async function load(organizationId, practiceId) {
      const host = el(ids.list);
      st.loaded = true;
      if (!host) return;
      host.innerHTML = '<div class="pm-empty compact">Loading teams...</div>';
      try {
        // practiceId is optional: a practice being marked Applicable for
        // the first time has no practice row yet (migration 218), so no
        // team can already be configured for it.
        const r = await fetch(U("/practice/api/workflow/practice-configure/teams?organizationId=")
                    + encodeURIComponent(organizationId)
                    + (Number(practiceId) > 0 ? "&practiceId=" + encodeURIComponent(practiceId) : ""),
                    { credentials: "same-origin" });
        if (!r.ok) {
          host.innerHTML = '<div class="pm-empty compact">Could not load teams (HTTP ' + r.status + ').</div>';
          return;
        }
        const body = await r.json();
        st.teams = (body.data || body.Data || []).map(t => ({
          teamId:            Number(t.teamId ?? t.TeamId),
          teamName:          t.teamName ?? t.TeamName ?? "",
          managerName:       t.teamManagerName ?? t.TeamManagerName ?? "",
          hasManager:        !!(t.hasManager ?? t.HasManager),
          departmentName:    t.departmentName ?? t.DepartmentName ?? "",
          alreadyConfigured: !!(t.alreadyConfigured ?? t.AlreadyConfigured),
          existingCode:      t.existingInstanceCode ?? t.ExistingInstanceCode ?? ""
        }));
        st.selected.clear();
        render();
      } catch (err) {
        console.error("practice-teams: team load failed", err);
        host.innerHTML = '<div class="pm-empty compact">Could not load teams.</div>';
      }
    }

    function visible() {
      const q = (el(ids.search)?.value || "").trim().toLowerCase();
      if (!q) return st.teams;
      return st.teams.filter(t => (t.teamName + " " + t.managerName + " " + t.departmentName)
                                  .toLowerCase().includes(q));
    }

    function render() {
      const host = el(ids.list);
      if (!host) return;
      const list = visible();

      if (!st.teams.length) {
        host.innerHTML = '<div class="pm-empty compact">'
          + "No active teams in this organization. Add teams under Organization / Team Management first."
          + "</div>";
        updateCount();
        return;
      }
      if (!list.length) {
        host.innerHTML = '<div class="pm-empty compact">No team matches that filter.</div>';
        updateCount();
        return;
      }

      host.innerHTML = '<table class="pm-table"><thead><tr>'
        + '<th style="width:3rem"></th><th>Team</th><th>Manager (becomes owner)</th>'
        + "<th>Department</th><th>State</th></tr></thead><tbody>"
        + list.map(t => {
            const done = t.alreadyConfigured;
            const checked = done || st.selected.has(t.teamId);
            const owner = t.hasManager
              ? esc(t.managerName)
              : '<span class="pm-text-warning" title="The instance will be created without an owner">'
                + "No manager set</span>";
            const state = done
              ? '<span class="pm-badge">Configured' + (t.existingCode ? " - " + esc(t.existingCode) : "") + "</span>"
              : "";
            // No name attribute: practice.js collectForm() reads every
            // [name] input of its form, and these are not form fields.
            return "<tr>"
              + '<td><input type="checkbox" data-team="' + t.teamId + '"'
                + (checked ? " checked" : "")
                + (done ? ' disabled title="This team already has an instance for this practice"' : "")
                + "></td>"
              + "<td>" + esc(t.teamName) + "</td>"
              + "<td>" + owner + "</td>"
              + "<td>" + esc(t.departmentName) + "</td>"
              + "<td>" + state + "</td>"
              + "</tr>";
          }).join("")
        + "</tbody></table>";

      host.querySelectorAll("input[data-team]").forEach(cb => {
        cb.addEventListener("change", function () {
          const id = Number(this.getAttribute("data-team"));
          if (this.checked) st.selected.add(id); else st.selected.delete(id);
          updateCount();
        });
      });
      updateCount();
    }

    function updateCount() {
      const n = st.selected.size;
      const count = el(ids.count);
      if (count) count.textContent =
        n + " selected" + (n ? " -- " + n + " instance" + (n === 1 ? "" : "s") + " will be created" : "");
      const save = el(ids.save);
      if (save) save.disabled = n === 0;
    }

    function reset() {
      st.teams = []; st.selected.clear(); st.loaded = false;
      if (el(ids.search)) el(ids.search).value = "";
      if (el(ids.list)) el(ids.list).innerHTML = "";
      updateCount();
    }

    el(ids.search)?.addEventListener("input", render);
    el(ids.selectAll)?.addEventListener("click", function () {
      visible().forEach(t => { if (!t.alreadyConfigured) st.selected.add(t.teamId); });
      render();
    });
    el(ids.clear)?.addEventListener("click", function () { st.selected.clear(); render(); });

    return {
      load, render, reset,
      selectedIds: () => Array.from(st.selected),
      get loaded() { return st.loaded; }
    };
  }

  // ---------------------------------------------------------------
  // The "Assign Team" block for an applicability form.
  // ---------------------------------------------------------------
  function ids(prefix) {
    return { block: prefix + "TeamsBlock", list: prefix + "TeamList", search: prefix + "TeamSearch",
             selectAll: prefix + "TeamSelectAll", clear: prefix + "TeamClear", count: prefix + "TeamCount" };
  }

  function blockHtml(prefix) {
    const i = ids(prefix);
    return '<div class="pm-field full" id="' + i.block + '" hidden>'
      + "<span>Assign Team</span>"
      + '<p class="pm-hint" style="margin:2px 0 6px;">One Practice Instance is created per ticked team when you Save, '
      + "owned by that team's manager. Teams that already have one are ticked and left alone. "
      + "More teams can be added later with Assign Team.</p>"
      + '<div class="pm-toolbar" style="padding:0;">'
      + '<input type="search" id="' + i.search + '" placeholder="Filter teams..." />'
      + '<button class="pm-button ghost small" id="' + i.selectAll + '" type="button">Select all available</button>'
      + '<button class="pm-button ghost small" id="' + i.clear + '" type="button">Clear</button>'
      + '<span class="pm-badge" id="' + i.count + '">0 selected</span>'
      + "</div>"
      + '<div id="' + i.list + '" style="max-height:260px; overflow-y:auto; margin-top:6px;"></div>'
      + "</div>";
  }

  // ---------------------------------------------------------------
  // Create the instances, and say what happened.
  // ---------------------------------------------------------------
  async function createInstances(organizationId, practiceId, teamIds) {
    try {
      const r = await fetch(U("/practice/api/workflow/practice-configure/instances"), {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF() },
        body: JSON.stringify({ organizationId: organizationId, practiceId: practiceId, teamIds: teamIds })
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) return { ok: false, error: body.error || ("Could not create the instances (HTTP " + r.status + ").") };
      return { ok: true, body: body };
    } catch (err) {
      console.error("practice-teams: configure failed", err);
      return { ok: false, error: "Could not create the instances." };
    }
  }

  // Say what actually happened rather than a blanket "Saved". A batch
  // that skipped every team looks identical to a successful one unless
  // the counts are spelled out.
  function summary(body) {
    const created = Number(body.createdCount ?? 0);
    const already = Number(body.alreadyConfiguredCount ?? 0);
    const noOwner = Number(body.withoutOwnerCount ?? 0);

    const parts = [];
    parts.push(created + " instance" + (created === 1 ? "" : "s") + " created");
    if (already) parts.push(already + " team" + (already === 1 ? "" : "s") + " already had one");
    if (noOwner) parts.push(noOwner + " created without an owner");

    return {
      text: parts.join(". ") + ".",
      kind: created ? "ok" : "info",
      // An instance with no owner is not assurance-eligible, so the
      // page keeps saying so after the dialog has gone.
      note: noOwner
        ? "An instance with no owner is not assurance-eligible. Set a team manager, "
          + "or set the owner directly on the instance under Governance / Practice Instances."
        : null
    };
  }

  function summaryText(body) {
    const s = summary(body);
    return s.text + (s.note ? " " + s.note : "");
  }

  window.gracPracticeTeams = { picker, ids, blockHtml, createInstances, summary, summaryText };
})();
