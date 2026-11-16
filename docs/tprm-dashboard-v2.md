# Third-Party Risk dashboard v2 (migration 507)

Source: Dashboard UI / Functional Specification v2, section 10. Fifth module
on the v2 layout (Governance 503, Issues & Actions 504, Risk 505, Audit
Assurance 506). Presentation only: no table, column, status or workflow
change. Requires the TPRM module (486-490) in the database; without it the
page and the Home card say "not set up in this database" (Api 501,
`notConfigured`).

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/507_tprm_dashboard_watchlist.sql` | `sp_dashboard_tprm` re-issued from the 490 body; same parameter, result sets and columns. Adds list `tprmengagements_highrisk` (the engagements KPI `tprmengagements.highrisk` counts: ACTIVE / SUSPENDED, band rank >= 3; StatusText = band, DateValue = next review). Rollback restores the 490 body verbatim. |
| API | none | Same 414 contract (`GET /api/practice/management-dashboard/tprm`). |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | `loadTprm` / `renderTprm`; `watchTable` gains `statusFormat` (review trigger codes shown as words). |

## Page

1. KPIs: Third parties (with an active engagement) / Open engagements (in assessment, active) / High or critical active (residual band, else inherent) / Due diligence overdue (rounds in progress) / Decisions pending / Reviews overdue (due in 30 days).
2. Needs attention (left): due diligence overdue, reviews overdue, overdue remediation, high/critical findings, reassessment required (High); decisions pending, evidence awaiting review, acceptance ending in 60 days, engagements ending in 90 days, accepted evidence expiring, open approval conditions (Medium).
   Right: **Engagement lifecycle** -- open engagements per stage (each bar opens Engagements on that stage) with the five spec stages summed underneath (Scope & risk -> Due diligence -> Decision -> Onboarding -> Operation); then risk band and service criticality (risk-model / reference colours).
3. Open findings by severity, Open reviews by type (drill), Ageing (open findings since recorded, pending decisions since submitted).
4. Watchlists (balanced two columns): High-risk engagements + Pending decisions | Overdue reviews + Overdue remediation + Risk acceptance ending in 60 days. Rows open the engagement.

Stage groups (spec 10.2) used for the lifecycle line: SCOPING, RISK_ASSESSED = Scope & risk; DUE_DILIGENCE; PENDING_DECISION = Decision; APPROVED, ONBOARDING = Onboarding; ACTIVE, SUSPENDED, EXITING = Operation. Registration (stage 1 of the spec) is the Third parties KPI.

## Out-of-scope register

| Item | Why |
|---|---|
| Pending classification / incomplete third-party profiles | No completeness rule recorded on third parties. |
| Questionnaire completion % | Rounds are counted (in progress / overdue); per-question completion is not aggregated anywhere. |
| Approved but not onboarded beyond stage counts | Shown as the Approved / Onboarding stages. |
| Vendor tool dependencies / licence expiry | Belongs to the asset / tool view, not TPRM (spec 10.5). |

## Deploy

TPRM 486-490 first (if not already), then `507_tprm_dashboard_watchlist.sql`, then Web. No API rebuild.
