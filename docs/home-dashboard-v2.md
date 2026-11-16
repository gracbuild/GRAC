# Home dashboard v2 (Dashboard UI specification v2, section 5)

Follows `docs/governance-dashboard-v2.md` (503). UI and Web tier only:
**no migration, no API change.** Every Home figure is read from the module
dashboard's own endpoint, so it is the same number that dashboard shows
(spec 12.1).

## Layout

| Order | Block | Source | Shown when |
|---|---|---|---|
| 1 | Welcome + context strip (organisation, refreshed time) and the organisation picker | session display name; `lookups` | always |
| 2 | **My work** (left) beside **Needs your attention** (right), one row, equal height, each scrolls inside | `home-my-work.js` -- unchanged session-scoped APIs | the caller has at least one My work area (as before) |
| 3 | **Module overview** -- one snapshot card per module dashboard the caller may open; three figures each; the card opens that dashboard for the selected organisation | module dashboard endpoints | per module: `CanViewScreen(<module>-dashboard)` |
| 4 | **Upcoming** -- audits starting in 30 days, risk acceptances ending in 60 days, contracts ending in 90 days, date order (12 max) | the dashboards' own lists `audits_upcoming`, `tprmacceptance_expiring`, `contracts_expiring` | the caller may see at least one of those sections |

The 2026-09-29 **Overview** panel (dashboard-summary cards: Control
Statements, Practices, Practice Instances, Dependencies, Evidence, Resolve
Status) and its collapse control are removed. Its counts were
organisation-wide for every user, and two of its evidence figures read
alignment codes the master does not contain (see the governance doc). The
Governance card replaces it with permission-scoped figures.

## Module cards (figures and sources)

A figure is shown only when its section is one the caller may see on that
dashboard (`ManagementDashboards.AllowedSections`) and the server returned it.

| Card | Figure (qualifier) | KPI keys |
|---|---|---|
| Governance | Implemented instances (% of instances, meter) / Critical instances not implemented (critical in total) / One-time evidence missing (of one-time rows); scope chip All / Your instances | `instances.implemented/total/criticalopen/critical`, `evidence.onetimemissing/onetime` |
| Issues & Actions | Open issues (overdue, no owner) / Open tasks (overdue, pending review) / Exceptions awaiting approval (lapsed waivers) | `gaps.open/overdue/noowner`, `tasks.open/overdue/pending`, `exceptions.pending/lapsed` |
| Risk Management | Open risks (under treatment, no owner) / Residual assessment pending (of open risks) / Reviews overdue (accepted risks) | Risk Centre dashboard: `heatmapCoverage.openRisks/residualPending`, `register.underTreatmentCount/unownedCount/acceptedCount`, `reviewAgeing` (BandGroup Overdue) |
| Audit Assurance | Audits in progress (planned, overdue) / Open findings (overdue) / Resolved, awaiting closure | `audits.inprogress/planned/overdue`, `findings.pending/overdue/awaiting` |
| Third-Party Risk | Active engagements (high or critical band) / Overdue due-diligence rounds (in progress) / Overdue reviews (due in 30 days) | `tprmengagements.active/highrisk`, `tprmdiligence.overdue/inprogress`, `tprmreviews.overdue/due30` |
| Asset & Contract | Assets in use (without an owner) / Contracts ending in 30 days (expired, open renewals) / Overdue attestations (disputed) | `assets.inuse/noowner`, `contracts.expiring30/expired/renewals`, `attestation.overdue/disputed` |

Policies & Documents has no module dashboard yet, so it has no card.
Numbers are neutral; colour is not applied because a count is non-zero
(spec 3.3).

## Files

| File | Change |
|---|---|
| `Models/ManagementDashboards.cs` | `HomeSnapshots`: module, dashboard screen key, title, in display order. |
| `Controllers/PracticeController.cs` (`Dashboard`) | `ViewBag.HomeModules`: the snapshots the caller may open (`CanViewScreen`) with their allowed sections. |
| `Views/Practice/Dashboard.cshtml` | New row anatomy (above); `#homeModules data-modules` (JSON); loads `ManagementDashboard/dashboard-components.js`. Overview markup and its toggle script removed. |
| `wwwroot/js/practice-dashboard.js` | Organisation picker kept (still publishes `pm:home-organization`); dashboard-summary read replaced by the module cards and Upcoming. Cards load in parallel and fail independently (error + Retry). |
| `wwwroot/js/ManagementDashboard/dashboard-components.js` | `gracDash.snapshot(o)` -- the module card. |
| `wwwroot/css/practice-management.css` | Home row rules rewritten (My work + attention); `.pm-home-modules`, `.pm-home-snaps` (three cards a row, then two, then one); `.pm-dx-snap*` in 11c. Removed the now-unused Overview rules (`.pm-home-org*`, `.pm-dashboard-kpi-grid`, `.pm-dashboard-card*`, `.pm-dashboard-primary`, `.pm-mini-metrics`). |

`home-my-work.js` is unchanged. The `dashboard-summary` query is unchanged;
the Governance dashboard still reads it for practice applicability.

## Notes for the product owner

- The Web proxy for the Risk Centre dashboard data checks the organisation only; Home shows the Risk card only to callers who may open the Risk dashboard page.
- Spec 5.2's separate "Enterprise snapshot" strip is folded into the module cards (one place per figure, no duplicated KPIs on Home).
- Role label in the welcome strip is not shown: the session holds role codes, not a display label.

## Deploy

Web only (cshtml, js, css, the two C# files). Hard refresh. Needs 503 for
the Governance card's criticality and evidence figures; without it the
card shows only implemented instances.

## Module not set up in this database (2026-11-02)

When a module's dashboard procedure is missing (SQL error 2812 -- e.g. TPRM
on a database where 486-490 were never applied while its menu rows exist),
the Api `ManagementDashboardController` returns **501** with
`{ error, notConfigured: true }` instead of a 500. Home shows the card as
"Not set up in this environment yet." (no error, no zeros, no Retry) and
the module's own dashboard page shows the message without "Could not load".
Fix for the environment: apply that module's migrations (TPRM: 486-490).
