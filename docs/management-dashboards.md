# Management dashboards (migrations 413 / 414 / 416)

Each major parent menu has a **Dashboard** submenu as its first child.
It opens that module's management dashboard. The other child menus, their
pages and their routes are unchanged. The dashboard drills into those same
pages, with their own filters.

| Parent menu (`menu_key`) | Dashboard submenu (`menu_key`, order) | Page | Built by |
| --- | --- | --- | --- |
| Governance (`nav-governance`) | `governance-dashboard`, 99 | `Practice/Index/governance-dashboard` | 414; submenu 416 |
| Issues & Actions (`nav-oversight`) | `issues-actions-dashboard`, 223 | `Practice/Index/issues-actions-dashboard` | 414; submenu 416 |
| Risk Management (`risk-centre`) | `risk-centre-dashboard`, 280 (was 286) | `Practice/Index/risk-centre-dashboard` (existing screen, restructured) | 413, see `docs/risk-centre.md`; submenu 383, made first by 416 |
| Audit Assurance (`nav-assurance`) | `audit-assurance-dashboard`, 439 | `Practice/Index/audit-assurance-dashboard` | 414; submenu 416 |

**Parent menus only expand or collapse (416).** From 413/414 to 416, the
parent row itself carried the dashboard url. The sidebar navigates a
parent that has a url (`data-nav-href`, since 276), so one click both
expanded the menu and loaded the dashboard. 416 clears those urls:

- `nav-*` parents go back to NULL;
- `risk-centre` goes back to `#`.

A parent click now only toggles its children. No sidebar code changed.
`274_menu_master_seed.sql` carries the same values.

## Layout

The same structure on every dashboard, showing only the blocks that
module has real data for:

heading and organization -> KPI tiles per section -> ageing ->
distributions -> lists

It is built from the existing design pieces: `pm-page-heading`,
`pm-panel`, `pm-toolbar`, the Risk dashboard's tiles and proportional
bars (moved to `practice-management.css` section 11b and shared as
`.pm-dash-*` / `.risk-*`), `pm-table-wrap` tables, and the Gap Register's
filter banner (now `.pm-filter-banner`). No charting library, no new
visual language.

**Arrangement (2026-10-01).** This is in `management-dashboard.js` and
`practice-management.css` section 11b. It applies to all three dashboards.

| Part | Arrangement | Rules |
|---|---|---|
| KPI cards and ageing | One row (`.pm-dash-split`). The KPI sections take the left half and the ageing groups the right half. | Each KPI section is a fixed six-column row, so all six cards stay on one row whatever the Windows display scaling. Each ageing group is one column (`--pm-dash-cols`). A dashboard with no ageing keeps its KPIs full width. Below 1400px the two halves stack. |
| Distributions | `.pm-dash-grid-dist`, `auto-fit` with a 180px floor. | All six Issues & Actions groups share one row, including "Exception requests by type". |
| Lists (Overdue tasks, Overdue issues, the audit lists) | When there is ageing, the lists sit in the right half under it (`.pm-dash-side`, 2026-10-02). Otherwise each list is a full row (`.pm-dash-lists`). | In the right half, the column is held to the KPI cards' height (`contain: size`). The list tables share what is left and scroll inside it, with a sticky header, so the row still ends where Distribution starts. The title column wraps, so the table does not scroll sideways. Below 1400px the lists flow at their own height. |

**Bar fill fix.** The proportional bars never showed their fill. `.fil`
is a `<span>`, so its inline width was ignored. It is now
`display: block`. This also fixes the Risk dashboard's ageing bars.

## Access and organization

* **Who may open a dashboard (416).** A module dashboard opens only if
  the caller has both:
  - VIEW on its own Dashboard submenu (`governance-dashboard:VIEW` and so
    on, granted in Role Master like any menu);
  - VIEW on at least one of the child screens it summarises.

  It shows only the sections whose child screen the caller may VIEW
  (`ManagementDashboards.CanOpen`, used by both
  `PracticeController.CanViewScreen` and the Web proxy for the data read).
* **416's grants.** 416 gave `can_view` on each new Dashboard row to
  exactly the roles that could VIEW one of that dashboard's child screens.
  So nobody gained or lost a dashboard. Users must re-login to pick up the
  new permission.
* **Risk dashboard.** Like every `risk-centre-*` page, it still rides on
  the `risk-centre` grant (383).
* Organization: the dashboard's organization picker is the allowed list
  (`/practice/api/organizations/allowed`); the proxy refuses an
  organization outside the session's allowed set
  (`IsOrganizationAllowed`).
* Governance's practice instances follow Operationalize's own rule: an
  admin (data scope GLOBAL / ORGANIZATION) sees the organization, anyone
  else the instances they own. The caller comes from the session
  (`X-PM-Caller-*` headers), never the browser.

## API

| Tier | Route |
| --- | --- |
| Web proxy | `GET /practice/api/management-dashboard/{module}?organizationId=` |
| API | `GET /api/practice/management-dashboard/{module}?organizationId=` |

`module` = `governance` | `issues-actions` | `audit-assurance` (404 for
anything else). One call, one response:

```json
{
  "module": "issues-actions",
  "kpis":          [{ "sectionKey", "sectionTitle", "kpiKey", "label", "value", "isAlert", "sortOrder" }],
  "ageing":        [{ "groupKey", "groupTitle", "bandCode", "bandName", "sortOrder", "minDays", "maxDays", "itemCount" }],
  "distributions": [{ "groupKey", "groupTitle", "itemKey", "itemLabel", "itemCount", "colourHex", "sortOrder" }],
  "lists":         [{ "listKey", "listTitle", "recordId", "refText", "title", "ownerName", "statusText", "dateValue", "sortOrder" }]
}
```

`itemKey` is the exact value the target list's own filter takes.

Governance also reads two EXISTING gateway queries that already return
its figures, rather than recounting them: `subscribed-frameworks`
(Standards & Frameworks' per-release statement counts) and
`dashboard-summary` (the Home overview's practices and attention items).
Three fixed calls in parallel, no per-row calls.

### Drill-down parameters on the existing lists (414)

Every parameter is optional; absent = the list exactly as before. The
API sends each to the procedure only when the procedure declares it
(`Infrastructure/ListDrillParameters.cs`, `ProcParameterProbe`).

| List (API) | New query parameters | Procedure parameters |
| --- | --- | --- |
| Gap Register `GET /api/practice/gaps/custom/centre` | `drillCode` (open, pending, overdue, completed, noowner), `statusText`, `severityText`, `minAgeDays`, `maxAgeDays` | `sp_gap_centre_list` `@drill_code`, `@status_text`, `@severity_text`, `@min_age_days`, `@max_age_days` |
| Task Board `GET /api/practice/tasks` | `noOwner=1`, `minAgeDays`, `maxAgeDays` (status, overdue and priority were already there) | `sp_task_list` `@no_owner`, `@min_age_days`, `@max_age_days` |
| Exceptions `GET /api/practice/exception-centre` | `drillCode` (open, lapsed, noowner), `minAgeDays`, `maxAgeDays` | `sp_exception_request_list` `@drill_code`, age band |
| Audit executions `GET /api/practice/org-assurance/executions` | `drillCode` (planned, inprogress, completed, cancelled, overdue, upcoming) | `sp_org_assurance_execution_list` `@drill_code` |
| Audit observations `GET /api/practice/org-assurance/observations` | `drillCode` (pending, awaiting, closed, overdue, noowner), `minAgeDays`, `maxAgeDays` | `sp_org_assurance_observation_list` `@drill_code`, age band |

The pages read the dashboard's link with `wwwroot/js/Shared/dashboard-drill.js`
(`organizationId`, `drill`, `statusText`, `severity`, `minAge`, `maxAge`,
`noOwner`, `status`, `overdue`, `priority`, `requestType`, `drillLabel`,
`from`), set their own controls where a value is theirs (status,
severity, priority, request type), send the rest to the API, and show
the banner. **Clear filter** reloads the page without those parameters;
**Dashboard** goes back. Operationalize reads `?status=`; Control
Statements, Standards & Frameworks and Organization Practices read
`?organizationId=`, and Control Statements `?status=` (applicability).

## One definition per bucket

A tile and the list it opens must never disagree, so each bucket is
defined once in SQL and read by both the dashboard procedure and the
list's drill-down:

| Entity | Definition | Buckets |
| --- | --- | --- |
| Issues (Gap Register) | `fn_pm_gap_centre_rows` -- the rows `sp_gap_centre_list` built inline in 379, now one function the list reads too | **open**: not Closed / Cancelled and not Invalid / Duplicate (lifecycle `is_terminal = 1` and `is_valid_terminal = 0`); **pending analysis**: open and lifecycle not terminal (or an unmaterialized "New" row); **completed**: Closed; **overdue**: open, due date before today; **no owner**: open, owner ID NULL; age from `opened_dt` |
| Tasks (Task Board) | `vw_pm_practice_task` (existing) | top-level tasks, as the Task Board lists them; **open** = `current_status_is_terminal = 0`; **pending review** = PendingReview; **overdue** = `is_overdue`; **completed** = Closed; **no owner** = open, `assigned_to_employee_id` NULL; age from `COALESCE(start_date, entered_dt)` (the SLA baseline) |
| Exceptions & Waivers | `vw_pm_exception_request_state` | **open** = Pending / SubmittedForApproval; **awaiting approval** = SubmittedForApproval; **lapsed** = Approved with `effective_until` before today (not yet swept to Expired -- the test `sp_exception_request_expire_due` uses); **no owner** = open, `owner_employee_id` NULL; age from `requested_dt` |
| Audits (Executions) | `vw_pm_org_assurance_execution_state` | Planned; **in progress** = any other non-terminal status (InProgress, Submitted, Reviewed, Approved); **completed** = Closed; Cancelled; **overdue** = not terminal, `planned_end_dt` before today; **starting in 30 days** = Planned, `planned_start_dt` within 30 days |
| Findings (Observations) | `vw_pm_org_assurance_observation_state` | **pending** = Open / InReview / Accepted; **awaiting closure** = Resolved; **closed** = Closed / Rejected; **overdue** = pending, `due_date` before today; **no owner** = pending, owner ID NULL; age from `observed_dt` |
| Audit plans | `org_assurance_plan` + status master | status as stored |
| Practice instances | Operationalize's `sp_resolve_instance_list` rule | Active instances; status = `COALESCE(implementation_status_master.status_name, implementation_status)`; **no owner** = `primary_owner_id` NULL (admins only) |

Ageing bands are `fn_pm_ageing_band()` -- the Risk dashboard's bands
(0-7, 8-30, 31-90, 91-180, over 180 days), in one place.

## What each dashboard shows

**Governance** -- Standards & Frameworks (frameworks, statements, not
updated, applicable, implemented, pending repository updates, and a
per-release table whose counts open Control Statements), Practices
(total, applicable, not updated, not applicable, and the Home overview's
"Needs attention" items with their links), Practice instances (total,
implemented, partially implemented, not implemented, no owner; status
distribution). Governance entities carry no due, review or target
dates, so **no ageing or overdue figure is produced** for them.

**Issues & Actions** -- per section (Issues, Tasks, Exceptions): total,
open, pending, overdue / lapsed, completed / approved, no owner; ageing of
open items; status distribution for each, severity (issues), priority
(tasks) and request type (exceptions); the oldest overdue tasks and
issues.

**Audit & Assurance** -- Audits: total, planned, in progress, completed,
overdue, starting in 30 days; Findings: total, pending, awaiting closure,
overdue, closed, no owner; Audit plans: total, active. Ageing of pending
findings; audits by status, pending findings by severity (the severity
master's colours), findings by status, plans by status; upcoming and
overdue audits.

## Not linked, on purpose

* Governance "No owner" (instances): Operationalize has no no-owner
  filter, and an unfiltered list under that tile would mislead.
* Governance practice tiles open Organization Practices without a status:
  the counts are the Home overview's (practice rows), and that page lists
  organization requirements.

## Files

* Database: `413_risk_management_dashboard.sql`,
  `414_management_dashboards.sql` (+ rollbacks), `274_menu_master_seed.sql`.
* API: `ManagementDashboardController`, `ManagementDashboardService`,
  `ManagementDashboardModels`, `ListDrillParameters`,
  `ManagementDashboardServiceRegistration`; list endpoints above take
  `ListDrillQuery`.
* Web: `ManagementDashboardController` (proxy), `Models/ManagementDashboards.cs`,
  `PracticeScreen` (three screens), `PracticeController.CanViewScreen`,
  `Manage.cshtml`, `Partials/management-dashboard.cshtml`,
  `js/ManagementDashboard/management-dashboard.js`,
  `js/Shared/dashboard-drill.js`, and the receiving pages (gaps, tasks,
  exception-centre, org-assurance-executions / -observations / -plans,
  resolve, practice.js).
