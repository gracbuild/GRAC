# Asset & Contract dashboard v2 (509, no migration)

The last module dashboard still on the 414 layout, moved to the v2 layout
used by Governance (503), Issues & Actions (504), Risk (505), Audit Assurance
(506), Third-Party Risk (507) and Policies & Documents (508). The Dashboard
UI specification v2 has no Asset & Contract section, so its common rules
apply (3.1-3.6 design, 3.4 zero / not-available states, 13.1A data
eligibility). Presentation only.

## Files

| Layer | File | Change |
|---|---|---|
| DB | none | `sp_dashboard_asset_contract` (451) unchanged: same eleven sections, KPIs, ageing, distributions and four lists (10 rows each). |
| API | none | Same 414 contract (`GET /api/practice/management-dashboard/asset-contract`). |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | `loadAssetContract` / `renderAssetContract`. `watchTable` gains `hideStatus` and `total`. The 414 renderers (`tile`, `bars`, `block`, `renderKpis`, `renderAgeing`, `renderDistributions`, `renderLists`) and the 414 load path are removed -- no dashboard uses them now. |
| Web | `wwwroot/js/ManagementDashboard/dashboard-components.js` | `kpiCard`: `value: null` is drawn as a dash (not available), never 0. |
| Web | `wwwroot/css/practice-management.css` | Removed the 414-only layout rules (`.pm-dash-split`, `-side`, `-lists`, `-grid-dist`, `-grid-ageing`). Rules shared with Risk Centre / Asset Governance (`.pm-dash-tile*`, `.pm-dash-bar*`, `.pm-dash-grid`) are kept. |
| Web | `Views/Practice/Partials/management-dashboard.cshtml` | Header comment only. |

Drill-downs are 451's unchanged (KPI_DRILL / DIST_DRILL, the nine asset screens read
`tab` / `status` / `kind` / `pending` through `Shared/dashboard-drill.js`).

## Page

1. KPIs: Assets in use (of registered, draft) / Governance score (latest snapshot; KPIs below threshold and at warning; a dash and "No governance snapshot yet" when there is none) / Unsupported technology (support ending, unknown version) / Active contracts (ending in 30 and 90 days) / Attestations overdue (pending, disputed) / Activities overdue (due in 30 days, open).
2. Needs attention (16 checks): coverage gaps, unsupported technology, assets without owner, maintenance / calibration overdue, attestations overdue, CMDB conflicts, privacy non-compliant, contracts ending in 30 days, privacy reviews overdue, services degraded, failed notifications (High); unknown versions, privacy incomplete, stale assets, lifecycle approvals, disputed attestations (Medium). 451's remaining figures sit in the chart footers.
   Right: Governance KPIs of the latest snapshot (on target / warning / below threshold, failing records), then Assets by lifecycle status, Contracts by status (open renewals), Firmware and Operating systems of assets in use (technology exceptions).
3. Chart grid: Assets in use by Asset Value, Attestations by status, Ageing (open attestations, reconciliation exceptions), Open activities by type, Assets by privacy status, Data confidence, Open reconciliation by kind, CMDB relationships by status, Business services by status, Open notifications by activity.
4. Watchlists (balanced two columns): Overdue attestations + Overdue activities | Active contracts ending in 90 days + Unsupported or unknown technology (row opens the asset).

## Out-of-scope register

| Item | Why |
|---|---|
| Critical exposure by asset criticality | Criticality levels are organisation data with no fixed "critical" level (451). |
| Technology refresh / campaign progress | No campaign workflow for technology. |
| Trend over time | 451 returns the latest governance snapshot only; no trend series. |
| Contract spend / value | 451 does not aggregate contract value. |
| Lists longer than 10 rows | 451 returns 10; each watchlist shows "First 10 of N" and links to its page where the page can filter. |

## Deploy

Web only. No database script, no API rebuild.
