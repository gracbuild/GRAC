# Issues & Actions dashboard v2 (migration 504)

Source: Dashboard UI / Functional Specification v2, section 7. Second module
on the v2 layout after Governance (`docs/governance-dashboard-v2.md`, 503).
Presentation only: no table, column, status or workflow change.

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/504_issues_actions_dashboard_insights.sql` | `sp_dashboard_issues_actions` re-issued from the 414 body; same parameter, result sets and columns. Adds the rows below; overdue lists 15 rows (was 5). Rollback restores the 414 body verbatim. |
| API | none | Same 414 contract (`GET /api/practice/management-dashboard/issues-actions`). |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | `loadIssuesActions` / `renderIssuesActions`. Shared v2 helpers extracted and used by Governance too: `kpiValues`, `distItems`, `kpiHref`, `setContext`, `errorBlock`. `load()` dispatches v2 modules from one map. `DIST_DRILL.gaps_source` added. Every link reuses the 414 drill maps (`KPI_DRILL`, `DIST_DRILL`, `AGEING_DRILL`, `listRowHref`). |
| Web | `wwwroot/js/ManagementDashboard/dashboard-components.js` | `gracDash.ageing(o)`: bands x series on one scale. |
| Web | `wwwroot/js/Shared/dashboard-drill.js` | `source` added to the keys "Clear filter" removes (Gap Register Source preset). |
| Web | `wwwroot/css/practice-management.css` 11c | `.pm-dx-age*`, `.pm-dx-grid-watch`; analytics grid floor 300px -> 260px (five cards a row at ~1500px). |

## Page

1. KPIs: Open issues (pending analysis, closed) / Overdue issues (% of open, meter) / Open tasks (due soon, pending review) / Overdue tasks (% of open) / Exceptions awaiting approval (open requests) / Approved waivers (ending in 30 days, lapsed). Each opens its list with the 414 drill.
2. Needs attention (left): overdue issues, overdue tasks, critical/high open issues, lapsed waivers (High); issues / tasks / exception requests without owner, tasks pending review, exceptions awaiting approval, waivers ending in 30 days, tasks due soon (Medium). Linked where the list filters to exactly that set.
   Right: **Ageing of open items** -- issues, tasks and exception requests as separate series per band (414 bands, `fn_pm_ageing_band`), each bar opens that list aged that band; under it Open issues by severity and Open tasks by priority.
3. Distributions: Issues by status, Open issues by source (new), Tasks by status, Exception requests by status, Exception requests by type.
4. Watchlists: Overdue issues, Overdue tasks -- reference, title, owner, status, due date, days overdue; oldest 15; row opens Gap View / Task View; "View all" opens the overdue list.

## KPI dictionary (new in 504; the rest are 414's, unchanged)

| Key | Label | Definition | Drill |
|---|---|---|---|
| gaps.highsev | Critical or high severity | Open Gap Register rows (414 open rule) whose Severity column is Critical or High | none (distribution bars drill each severity) |
| tasks.duesoon | Due soon | Open top-level tasks with `vw_pm_practice_task.sla_timing_code` DueToday or DueSoon (org SLA warning %) | none (Task Board has no SLA-timing URL filter) |
| exceptions.expiring | Waivers ending in 30 days | Approved requests with `effective_until` between today and today + 30 | none |
| gaps_source | Open issues by source | Open rows by `SourceModuleCode` | Gap Register `?drill=open&source=` |

## Out-of-scope register (spec 7 items not shown)

| Item | Why |
|---|---|
| Issues "under treatment / in progress" | Gap lifecycle has no such state; status distribution shows the real states. |
| Tasks "assigned" as a KPI | Shown in Tasks by status; no separate definition. |
| Exceptions "due for renewal" | No renewal concept on exception requests; "ending in 30 days" is shown instead. |
| Remediation "awaiting verification" | Only Task status Pending review exists (shown). |
| Reopened / recurring issues | No reopen history or recurrence link captured. |

## Deploy

`504_issues_actions_dashboard_insights.sql` (after 414), then Web. No API rebuild. Without 504 the page still renders; the four new figures are simply absent.
