// =====================================================================
// window.gracGapPracticeInstances -- the Practice Instance(s) a gap
// concerns, for the Gap Details page (gap-detail.js) and Gap View
// (gap-view.js). Change request 2026-10-27, migration 496.
//
// One list, from the two places a gap names an instance:
//   * the instance an Implementation gap was materialized from -- the gap
//     header's PracticeInstanceId / Name / Code / Description;
//   * the instances mapped to a Custom gap on the Add / Edit page --
//     GET /practice/api/gaps/custom/{id}/practices (382/388).
// The same instance is listed once.
//
// Each entry: the instance name (and code) as a link to the instance's
// own read-only view page -- resolve-workspace?mode=view, the destination
// Gap Register's row menu and the "View Practice Instance" link already
// use, opened in a new tab like that link -- and its description on the
// line beneath. A practice instance has no description of its own; it
// carries its practice's (practice.description, projected by 496 as
// PracticeInstanceDescription). Before 496 the description is simply
// absent.
//
// Presentation only: both reads already existed (the description column
// is 496's only addition).
// =====================================================================
(function () {
  "use strict";

  var U = function (p) { return String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p; };
  var esc = function (v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  };
  var pick = function (o, k) {
    return o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);
  };

  // header: the gap header already loaded by the page (may be null).
  async function load(gapId, orgId, header) {
    var list = [];
    var seen = {};
    var add = function (id, name, code, description) {
      id = Number(id || 0);
      if (!id || seen[id]) return;
      seen[id] = true;
      list.push({ id: id, name: name || ("Practice Instance #" + id), code: code || "", description: description || "" });
    };
    if (header) {
      add(pick(header, "practiceInstanceId"), pick(header, "practiceInstanceName"),
          pick(header, "practiceInstanceCode"), pick(header, "practiceInstanceDescription"));
    }
    try {
      var r = await fetch(U("/practice/api/gaps/custom/") + encodeURIComponent(gapId)
                          + "/practices?organizationId=" + encodeURIComponent(orgId || 0),
                          { credentials: "same-origin" });
      if (r.ok) {
        var b = await r.json();
        ((b && (b.data || b.Data)) || []).forEach(function (x) {
          add(pick(x, "practiceInstanceId"), pick(x, "practiceInstanceName"),
              pick(x, "practiceInstanceCode"), pick(x, "practiceInstanceDescription"));
        });
      }
    } catch (err) {
      console.warn("[gap] practice instances load failed", err);
    }
    return list;
  }

  function viewUrl(instanceId, orgId) {
    return U("/Practice/Index/resolve-workspace")
      + "?instanceId=" + encodeURIComponent(instanceId)
      + "&organizationId=" + encodeURIComponent(orgId || 0)
      + "&mode=view";
  }

  // The list as HTML for a <dd>: one block per instance, the name as the
  // link, the description beneath it. "None" when the gap names none.
  function renderHtml(list, orgId) {
    if (!list || !list.length) return "None";
    return list.map(function (it) {
      return '<div style="margin:0 0 6px;">'
        + '<a href="' + esc(viewUrl(it.id, orgId)) + '" target="_blank" rel="noopener"'
        + ' title="Open this Practice Instance\'s view page in a new tab">'
        + esc(it.name) + (it.code ? " (" + esc(it.code) + ")" : "")
        + ' <i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true" style="font-size:10px;"></i></a>'
        + (it.description
            ? '<div class="pm-hint" style="margin:2px 0 0; white-space:pre-wrap;">' + esc(it.description) + "</div>"
            : "")
        + "</div>";
    }).join("");
  }

  window.gracGapPracticeInstances = { load: load, renderHtml: renderHtml, viewUrl: viewUrl };
})();
