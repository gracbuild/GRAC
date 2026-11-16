# Audit Assurance dashboard v2 (migration 506)

Source: Dashboard UI / Functional Specification v2, section 9. Fourth module
on the v2 layout (Governance 503, Issues & Actions 504, Risk 505).
Presentation only: no table, column, status or workflow change.

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/506_audit_assurance_dashboard_insights.sql` | `sp_dashboard_audit_assurance` re-issued from the 414 body; same parameter, result sets and columns, every 414 row kept. Adds the rows below; `audits_overdue` 15 rows (was 5); new list `findings_overdue`. Rollback restores the 414 body verbatim. |
| API | none | Same 414 contract (`GET /api/practice/management-dashboard/audit-assurance`). |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | `loadAuditAssurance` / `renderAuditAssurance`; `watchTable` extracted as the shared watchlist (Issues & Actions now uses it too); `distItems` carries a master's own colour (observation severity `color_hex`); `listRowHref` + `findings_overdue` (opens Observations on the overdue drill -- that page has no single-record URL). |
| Web | `wwwroot/css/practice-management.css` 11c | `.pm-dx-row-even` (two equal, balanced columns; stacks below 1280px). |

## Page

1. KPIs: Audits in progress (planned, starting in 30 days) / Fieldwork progress % (entities completed / in scope of in-progress audits) / Overdue audits (completed) / Open findings (critical or high, linked to an issue) / Overdue findings (% of open, meter) / Resolved, awaiting closure (closed).
2. Needs attention (left): overdue audits, overdue findings, critical/high open findings, findings without owner (High); resolved awaiting closure, findings without due date, event-driven audits open (Medium); audits starting in 30 days (Info).
   Right: Open findings ageing (days since observed, bars drill) -> Open findings by severity (master colours) and Audits by status.
3. Distributions: Findings by status, Open findings by type, Audits by origin (plan / manual / event-driven), Audit plans by status.
4. Watchlists (balanced two columns): Overdue audits + Audits starting in the next 30 days | Overdue findings (severity, due, days overdue).

## KPI dictionary (new in 506; the rest are 414's)

| Key | Label | Definition | Drill |
|---|---|---|---|
| audits.entitiesdone / entitiestotal | Fieldwork progress | Sum of `completed_entity_count` / `total_entity_count` over audits in stage InProgress | none |
| audits.triggeredopen | Event-driven audits open | `origin_type = 'TRIGGER'`, stage Planned or InProgress | none |
| findings.highsev | Critical or high, pending | Stage Pending, `severity_code` Critical or High (severity master, 101) | severity bars |
| findings.noduedate | Pending, no due date | Stage Pending, `due_date` NULL | none |
| findings.linkedgap | Pending, linked to an issue | Stage Pending, `gap_id` set (raised to the Gap Register) | none |
| audits_origin | Audits by origin | `origin_type` | none |
| findings_type | Open findings by type | Stage Pending by `observation_type` | none |
| findings_overdue (list) | Overdue findings | View's `is_overdue`, oldest due first, 15 rows; StatusText = severity | Observations, overdue drill |

## Out-of-scope register (spec 9 items not shown)

| Item | Why |
|---|---|
| Assurance coverage % of applicable practices (9.3) | Audit scope resolves to entities (scope resolution), not reliably to practices; the spec forbids the audits-completed / planned proxy. |
| Audit type (risk-based, compliance, concurrent ...) | No audit-type field on definitions or executions; plan_type is a period (annual, quarterly ...). Origin is shown instead. |
| Schedule variance (planned vs actual) | Actual dates exist but no agreed variance rule; not added. |
| Repeat / reopened findings, failed validation | No repeat link or reopen history on observations. |
| Remediation status from linked tasks | Only the gap link is recorded; the gap's own status lives in Issues & Actions. |

## Deploy

`506_audit_assurance_dashboard_insights.sql` (after 414), then Web. No API rebuild. Without 506 the page still renders; the new figures are simply absent.
