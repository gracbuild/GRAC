// =====================================================================
// Task View  (dedicated full page)
// Loaded by Views/Practice/Partials/task-view.cshtml.
//
// URL: /Practice/Index/task-view?taskId=NNN
//
// WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
// --------------------------------------------------------------------
// This replaces the small "View" dialog (#taskDetailDialog /
// openTaskViewDrawer / renderTaskDetail in tasks.cshtml) as the actual
// destination of every Task "View" action, with a proper full page.
// It reads the exact same single API call tasks.cshtml's dialog always
// used -- GET /practice/api/tasks/{id} -- and lays the same payload out
// as page sections instead of dialog content. No new endpoint, no new
// stored procedure, no duplicate business logic; the one additive
// column (organization_name, migration 326) is projected by the same
// view (vw_pm_practice_task) this call has always read from.
//
// Everything else about the Task (Edit, Complete, Close, Add Evidence,
// Add Update/Comment) is UNCHANGED and still lives entirely in
// tasks.cshtml, reached from the Task Center grid's own row menu --
// this page is read-only, the same way Risk Centre's "View risk" full
// page is read-only and all of a risk's actions stay on the Register
// grid's row menu, not on the view page.
//
// "Related Gap / Risk / Exception" reuses the task's own existing
// source-navigation fields (BRD §15: sourceTypeCode / sourceRecordId /
// sourceReference, already stored at task-open time -- see 196's own
// comment for the exact vocabulary): Gap -> gap-view.cshtml, Exception
// -> exception-view.cshtml (new, see below), Risk -> risk-centre's
// candidate modal, RiskRegister -> risk-centre's registered-risk full
// page -- all three are existing deep-links, not new pages.
// =====================================================================
(() => {
  "use strict";

  const U       = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const taskBase = "/practice/api/tasks";

  // Where "Related <X>" links out to, keyed by the task's own
  // source_type_code (BRD §15, vocabulary fixed by migration 196):
  //   Gap          -> Gap View
