# Risk Management dashboard v2 (migration 505)

Source: Dashboard UI / Functional Specification v2, section 8. Third module
on the v2 layout (after Governance 503 and Issues & Actions 504). The
dashboard stays inside Risk Centre (`risk-centre-dashboard`, Dashboard tab);
every drill still opens the Candidates / Register / Review tab in the page
with its filter banner. Presentation only: no table, column, status or
workflow change.

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/505_risk_dashboard_insights.sql` | `sp_risk_dashboard_counts` re-issued from the 413 body. Set 16 Top risks: TOP 10 (was 5) + `WorkflowStageCode`, `NextReviewDate`. Appended sets 17 (open risks by workflow stage), 18 (by treatment option), 19 (by assessed residual rating). Rollback restores the 413 body. |
| API | `Models/RiskCentreModels.cs` | `RiskDashboard` + `StageCounts`, `TreatmentOptions`, `ResidualRatings` (optional, last); `RiskTopRisk` + `WorkflowStageCode`, `NextReviewDate` (optional, last). |
| API | `Services/RiskCentreService.cs` | Reads sets 17-19 (shared `ReadGroupsAsync`) and the new set-16 columns only when present -- deployable before or after 505. |
| Web | `Views/Practice/Partials/risk-centre.cshtml` | Dashboard tab: context strip `#dashContext`, one host `#riskDashBody`; loads `ManagementDashboard/dashboard-components.js`. The 2026-10-01 `.risk-dash-row` / `.risk-tiles-4` markup and CSS removed; heatmaps sit in a v2 card. |
| Web | `wwwroot/js/RiskCentre/risk-centre.js` | `refreshDashboard` renders with `window.gracDash`; drills keep the `data-dash-drill` / `applyDashDrill` mechanism (now also `workflowStageCode` -> the register's Workflow stage filter). Enter / Space activate a drill button. Removed the now-unused `dashTile`, `dashBars`, `setHint`; `heatmap()` unchanged. |
| Web | `wwwroot/js/ManagementDashboard/dashboard-components.js` | A link target may be `{ attr }` (an in-page drill button) besides an href; chart items may carry a configured `colour` (the organisation's matrix rating colour). |
| Web | `wwwroot/css/practice-management.css` 11c | `a.pm-dx-*` hover rules now `.pm-dx-*.is-link` (anchors and drill buttons alike); `.pm-dx-grid-3`. |

## Page

1. KPIs: Open risks (registered, closed or retired) / Under treatment (in treatment stage) / Residual assessed (awaiting residual; meter = assessed / open) / Accepted risks ("still part of residual exposure") / Reviews overdue (due in 30 days) / Open risk candidates (awaiting approval, converted).
2. Needs attention (left): reviews overdue, treatment actions overdue, residual assessment pending, risks without owner (High); treatment option not decided, analysis due, acceptance due, candidates awaiting approval, treatment actions due soon (Medium).
   Right: inherent and residual heatmaps side by side (organisation matrix, cell drill unchanged), then **Treatment lifecycle** -- open risks per workflow stage, each bar opens the register on that stage.
3. Distributions (three a row): Inherent rating (matrix colours), Residual rating (assessed only + a separate "Residual assessment pending" segment), Treatment option, Open risks by category, Candidate ageing (drill), Review ageing (drill).
4. Watchlist: Top 10 open risks -- risk, title, owner, inherent, residual (or "Residual assessment pending"), stage, next review (past dates flagged). Row opens the risk.

## Rules kept (spec 8.7)

- Ratings and colours come from the organisation's risk matrix; nothing hard-coded.
- Residual is never inferred: a risk without residual assessment is shown as pending, never as a rating.
- Accepted risks stay in every open count and on the heatmaps.
- Heatmap cell counts and the register list they open use the same rule (413).

## Out-of-scope register

| Item | Why |
|---|---|
| Risks exceeding appetite / tolerance, appetite status column | GRAC has no appetite or tolerance configuration. |
| Critical / High *residual* as a KPI | Rating names are the organisation's own; the residual distribution shows every rating instead of guessing which are "high". |
| Risk movement (inherent -> residual) view | Both heatmaps shown side by side; a per-risk movement chart needs a charting component GRAC does not use. |
| Acceptance expiry separate from next review | Acceptance carries a next review date only (shown). |
| KRIs, trend | No KRI data; the monthly trend set (9) exists but is P3 in the spec. |

Treatment actions overdue / due soon are counted from set 10 (risk tasks by SLA status); the separate overdue-actions table removed on 2026-10-01 is not brought back.

## Deploy

`505_risk_dashboard_insights.sql` (after 413, 484) -> Api -> Web. Without 505 the page renders without the lifecycle, treatment and residual-rating charts.

## Row balance (2026-11-02)

With live data most attention checks can be zero, leaving a short attention
card beside the tall heatmaps + lifecycle column (blank block on the left).
`gracDash.balance(row)` now runs after render on every v2 two-column row
(Governance, Issues & Actions, Risk): it measures the columns' natural
heights and moves the last card of the taller column (here the Treatment
lifecycle) to the shorter one while that narrows the gap. The row then
stretches so both columns end level (`.pm-dx-row-2` align-items: stretch,
last card grows); the heatmaps take spare height (likelihood rows are
`minmax(40px, 1fr)`, set by `heatmap()`).
