// =====================================================================
// window.gracGapActions -- THE Gap Centre row-menu actions (Analysis,
// View, Edit, View Existing Tasks, Close Gap) plus the menu-item list
// they come from. (Edit: migration 495, 2026-10-27.)
//
// Extracted from Views/Practice/Partials/gaps.cshtml (change request:
// Gap View's own "Actions" menu must reuse these verbatim -- same
// navigation targets, same API calls, same permission / applicability
// rules, same confirm / success / error handling -- rather than a
// second copy for Gap View. Gap Centre itself was rewired to call this
// module too, so there is exactly one implementation of each action,
// used from both screens. Mirrors the Task Centre / Task View precedent
// (Shared/task-actions.js, change request 2026-09-22) for exactly the
// same reason.
//
// Pairs with nothing extra on the markup side -- unlike Task's Edit /
// Complete / Close / Add Evidence, none of these actions open a form
// dialog: "Analysis" and "View" are plain navigations to gap-detail.cshtml
// / gap-view.cshtml (both already-existing full pages), "View Existing
// Tasks" is a plain navigation to Task Centre with a search term, and
// "Close Gap" is a confirm() + one POST, exactly as it always was. So
// there is no _gap-action-dialogs.cshtml partial to include -- only this
// script.
//
// PERMISSION / APPLICABILITY
// ---------------------------
// buildMenu() reproduces exactly the applicable/disabled rules
// gaps.cshtml's own buildRowMenu() used to hardcode, so a host page that
// calls it gets identical status-based gating for free -- there is no
// separate "can this user act on this gap" role check in Gap Centre
// beyond these; the item list itself IS the permission surface, same as
// Task Centre's.
//
// WHAT IS DELIBERATELY *NOT* HERE
// --------------------------------
// The materialize-then-navigate "Analysis" branch for an UN-MATERIALIZED
// practice-instance row (POST /gap-lifecycle/materialize-from-instance,
// then navigate) is not reproduced here. Gap View only ever exists for
// an already-materialized gap -- it is reached BY gapId -- so that
// branch can never occur there, and Gap Centre's own copy of it stays
// local to gaps.cshtml: moving a branch that only one caller can ever
// reach would not remove any duplication, only relocate it.
//
// NOTE ON AUTHORITY: this is presentation only, exactly like Task's
// module. Every rule mirrored here is also enforced by the API and by
// SQL (sp_custom_gap_analysis_save's terminal-state / 55143 / 55144 /
// 55145 guards, sp_custom_gap_close's own checks). Hiding or disabling
// an item removes a button, never a check.
// =====================================================================
(function () {
  "use strict";

  var U = function (p) { return String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p; };

  // fields: { gapId, isMaterialized, isAnalysed, sourceModuleCode,
  //           statusCode, practiceInstanceId, existingTaskCount,
  //           lifecycleStateCode, isLifecycleTerminal }
  //   - lifecycleStateCode / isLifecycleTerminal (495) decide whether Edit
  //     is enabled; isLifecycleTerminal (Gap View's header flag) wins when
  //     given, else the code is checked against TERMINAL_LIFECYCLE.
  //   - statusCode is the gap's own raw Open/InProgress/Closed/Cancelled
  //     code (custom_gap.status -- GapHeader.StatusCode on Gap View,
  //     row.rawStatusCode on Gap Centre's grid row), NOT the lifecycle
  //     stage (New/Analysed/...).
  //   - isAnalysed mirrors gaps.cshtml's own isAnalysed check: the
  //     lifecycle stage code is 'Delegated' once a gap has been analysed;
  //     re-analysis is rejected server-side (55143), so "Analysis" is not
  //     offered again past that point -- "View" is, instead.
  //
  // handlers: { onAnalysis, onReanalysis, onView, onEdit,
  //             onViewExistingTasks, onCloseGap }
  // A handler that is omitted means that item is not offered at all --
  // e.g. Gap View has no use for "View" (the page already IS the view),
  // so it simply does not pass onView. Callers are encouraged to pass
  // every handler they have and let the fields decide applicability,
  // same as Task Centre's own buildRowMenu() does against
  // window.gracTaskActions.buildMenu() -- but an omitted handler is
  // honoured too, for a host page (like Gap View) that has no use for a
  // given item at all.
  // Migration 495: the terminal stages of gap_lifecycle_state_master
  // (is_terminal = 1) -- Analysed shows as Delegated. Used only when the
  // host has the code but not the flag (Gap Centre's grid row).
  var TERMINAL_LIFECYCLE = ["Delegated", "Closed", "Invalid", "Duplicate"];

  // Migration 495: why a Custom gap cannot be edited, or "" when it can.
  // The same rules sp_custom_gap_edit enforces (55006, 55061).
  function editBlockedReason(fields) {
    var st = String(fields.statusCode || "");
    if (st && ["Open", "InProgress", "Reopened"].indexOf(st) < 0)
      return "Gap is " + st.toLowerCase() + ".";
    var terminal = typeof fields.isLifecycleTerminal === "boolean"
      ? fields.isLifecycleTerminal
      : TERMINAL_LIFECYCLE.indexOf(String(fields.lifecycleStateCode || "")) >= 0;
    if (terminal) return "Gap has already been analysed, closed or marked invalid / duplicate.";
    return "";
  }

  function buildMenu(fields, handlers) {
    fields = fields || {};
    handlers = handlers || {};
    var items = [];
    var isMat = !!fields.isMaterialized;
    var gapId = fields.gapId;

    // ---- Analysis / View -------------------------------------------
    // Mirrors gaps.cshtml's own comment on this exactly: a materialized,
    // not-yet-analysed gap offers "Analysis"; once analysed (Delegated),
    // that item is gone and "View" is offered instead, for every
    // materialized gap regardless of analysis stage.
    if (isMat && gapId) {
      if (!fields.isAnalysed && handlers.onAnalysis) {
        items.push({ icon: "fa-magnifying-glass", label: "Analysis", action: handlers.onAnalysis });
      }
      // Migration 501: once analysed, Analysis above is replaced by
      // Re-analysis -- the same destination, opened in re-analysis mode.
      // An omitted handler drops the item, like every other one here, so
      // a caller that does not offer re-analysis is unaffected.
      if (fields.isAnalysed && handlers.onReanalysis) {
        items.push({ icon: "fa-rotate", label: "Re-analysis", action: handlers.onReanalysis });
      }
      if (handlers.onView) {
        items.push({ icon: "fa-eye", label: "View", action: handlers.onView });
      }
    } else if (fields.practiceInstanceId) {
      // An un-materialized practice-instance gap has no custom_gap row
      // yet, so BOTH actions first materialize it (the handlers do that)
      // and then land -- Analysis on the analysis page, View on the
      // read-only Gap View. An omitted handler drops its item, exactly
      // like the materialized branch above.
      if (handlers.onAnalysis) {
        items.push({ icon: "fa-magnifying-glass", label: "Analysis", action: handlers.onAnalysis });
      }
      if (handlers.onView) {
        items.push({ icon: "fa-eye", label: "View", action: handlers.onView });
      }
    }

    // ---- Edit (migration 495) -----------------------------------------
    // A Custom gap only, the same scope as Close Gap below: gaps of the
    // other sources are owned by their module. Shown for every Custom
    // gap, disabled with the reason once it can no longer be edited --
    // the "disabled, not hidden" choice Close Gap makes.
    if (fields.sourceModuleCode === "Custom" && gapId && handlers.onEdit) {
      var blocked = editBlockedReason(fields);
      items.push({
        icon: "fa-pen", label: "Edit",
        disabled: !!blocked,
        disabledReason: blocked,
        action: handlers.onEdit
      });
    }

    // ---- View Existing Tasks ----------------------------------------
    if (fields.practiceInstanceId && handlers.onViewExistingTasks) {
      var n = Number(fields.existingTaskCount || 0);
      if (n > 0) {
        items.push({ icon: "fa-list", label: "View Existing Tasks (" + n + ")", action: handlers.onViewExistingTasks });
      }
    }

    // ---- Close Gap ----------------------------------------------------
    // Stays scoped to Custom-source gaps: closing an assurance or
    // implementation gap from here would bypass the lifecycle those
    // sources own. Always shown for a Custom gap (never hidden), greyed
    // out with a reason once already closed/cancelled -- same
    // "disabled, not hidden" choice gaps.cshtml always made here.
    if (fields.sourceModuleCode === "Custom" && gapId && handlers.onCloseGap) {
      var isClosed = (fields.statusCode === "Closed" || fields.statusCode === "Cancelled");
      items.push({
        icon: "fa-lock", label: "Close Gap",
        disabled: isClosed,
        disabledReason: "Gap is already " + String(fields.statusCode || "").toLowerCase() + ".",
        action: handlers.onCloseGap
      });
    }

    return items;
  }

  // Same confirm + POST /practice/api/gaps/custom/{id}/close both
  // callers used inline before this change. `remark` lets each caller
  // say where the action was taken from, matching the audit-trail intent
  // of the original hardcoded string ("Closed from Gap Center 3-dot
  // menu.") without hardcoding Gap Centre's own name into a module Gap
  // View calls too. `onSuccess` is the caller's own refresh -- Gap
  // Centre's reloadCurrentTab(), Gap View's load().
  async function closeGap(gapId, remark, onSuccess) {
    if (!await window.gracUi.confirm("Close Custom Gap #" + gapId + "?",
          { type: "warning", title: "Close gap", confirmText: "Close gap" })) return false;
    try {
      var r = await fetch(U("/practice/api/gaps/custom/") + encodeURIComponent(gapId) + "/close", {
        method: "POST", headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({ remarks: remark || "Closed from Gap Center 3-dot menu." })
      });
      if (r.ok) { if (onSuccess) onSuccess(); return true; }
      var b = await r.json().catch(function () { return {}; });
      alert(b.error || "Close failed");
      return false;
    } catch (err) {
      alert("Network error: " + err.message);
      return false;
    }
  }

  // Migration 495: the Edit Custom Gap page for a gap. `from` = "view"
  // sends the page back to Gap View after Save / Cancel; anything else
  // back to the Gap Register.
  function editUrl(gapId, orgId, orgName, from) {
    return U("/Practice/Index/gap-edit") + "?gapId=" + encodeURIComponent(gapId)
      + "&orgId=" + encodeURIComponent(orgId || "")
      + (orgName ? "&orgName=" + encodeURIComponent(orgName) : "")
      + (from ? "&from=" + encodeURIComponent(from) : "");
  }

  window.gracGapActions = {
    buildMenu: buildMenu,
    closeGap: closeGap,
    editUrl: editUrl,
    editBlockedReason: editBlockedReason
  };
})();
