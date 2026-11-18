# Governance dashboard v2 (migration 503)

Source: *GRAC Dashboard UI / Functional Specification for Claude Developer v2*
(1 Nov 2026), sections 3 (common design system) and 6 (Governance). Governance
is the first module moved to the v2 layout; Issues & Actions, Risk, Audit
Assurance, TPRM and Policies follow one module at a time on the same
components.

**Scope boundary kept:** presentation and read-only insight only. No table,
column, status, workflow or data capture changed. Every element below has a
verified, persisted source; anything without one is in the out-of-scope
register at the end.

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/503_governance_dashboard_insights.sql` | `sp_dashboard_governance` re-issued from the 456 body: same parameters, same 4 result sets and columns, extra rows (below). Rollback `503_..._rollback.sql` restores the 456 body verbatim. |
| API | none | `GET /api/practice/management-dashboard/governance` returns the extra rows through the existing 414 contract (`kpis`, `ageing`, `distributions`, `lists`). No model or controller change. |
| Web | `Models/ManagementDashboards.cs` | Governance gains sections `evidence` and `dependencies`, both on child screen `resolve` (Operationalize), so they show only to callers who may VIEW Operationalize. |
| Web | `Views/Practice/Partials/management-dashboard.cshtml` | Context strip `#mdContext`; loads `dashboard-components.js` before `management-dashboard.js`. |
| Web | `wwwroot/js/ManagementDashboard/dashboard-components.js` (new) | Shared v2 components, `window.gracDash`: `kpiCard`, `attention`, `distCard` (stacked bar + legend, or ranked bars), `table`, `card`, `skeleton`, `errorCard`. Presentation only. |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | Governance rendered by `loadGovernance` / `renderGovernance`; the three sources load in parallel and fail independently (error card + Retry, never a silent 0). Old `renderFrameworks` / `renderPractices` and the unused `instances` tile/bar drill entries removed. Other modules unchanged. |
| Web | `wwwroot/css/practice-management.css` section 11c | `.pm-dx-*` styles; GRAC tokens only. |

## Page structure (spec 3.2)

1. **Header + context strip** -- module title (unchanged heading), organisation selector, Refresh; strip shows organisation, scope (*All instances* for an admin, *Instances you own* otherwise) and the refresh time.
2. **Executive KPIs** (up to 6, by permitted section) -- Subscribed frameworks, Applicable control statements, Applicable practices, Practice instances, Implemented instances, One-time evidence provided. Each has a qualifier, a meter where a denominator exists, a definition tooltip and a scope chip.
3. **Needs attention** (left) -- every check with a count > 0, High first then by count; checks at zero are listed as *Clear*. Beside it **Framework coverage** (per release, stacked applicability bar, implemented %), with *Implementation status* and *Practice applicability* under it.
4. **Signature analytics** -- Instance criticality, One-time evidence (+ recurring rows / overdue tasks), Evidence alignment status, Dependencies by category (+ instances with dependencies / expired).
5. **Watchlist** -- Critical practice instances not implemented (top 20; row opens Operationalize in view mode).

Loading = skeleton in the final layout; empty group = one-line empty state; source failure = error card with Retry.

## KPI dictionary

Scope: *Inst* = Operationalize ownership rule (admin: all Active instances of the organisation; others: instances whose primary owner is the caller), with View Data Scope (415). *Org* = organisation-level. Section = permission section (child screen VIEW).

| Key | Label | Definition / formula | Source | Scope | Section | Drill-down |
|---|---|---|---|---|---|---|
| frameworks (count) | Subscribed frameworks | Subscribed releases | `subscribed-frameworks` query | Org | frameworks | Standards & Frameworks |
| statements applicable | Applicable control statements | Sum of `ApplicableStatementsCount`; meter = (total - not updated) / total | `subscribed-frameworks` | Org | frameworks | Standards & Frameworks; per release cells -> Control Statements `?releaseId&status` |
| statements not updated | Control statements not updated (attention) | Sum of `NotUpdatedStatementsCount` | `subscribed-frameworks` | Org | frameworks | Control Statements filtered, only when one release |
| pending updates | Repository updates pending | Sum of `PendingUpdatesCount` | `subscribed-frameworks` | Org | frameworks | Repository Updates |
| practices | Applicable practices / applicability | `ApplicablePractices`, `NotApplicablePractices`, `NotUpdatedPractices`, total; *Other decision* = remainder | `dashboard-summary` | Org | practices | Practices (Total only; list has no status URL filter) |
| practices.noinstance | Applicable practices without an instance | Active Applicable practices with no Active instance | 503 | Org | practices | none (no list filter) |
| instances.total / implemented / partial / notimplemented / notupdated | Implementation status | Instance implementation status (456 rule) | 414/456 | Inst | instances | Operationalize `?status=` |
| instances.noowner | Instances without an owner | `primary_owner_id IS NULL` (admin only) | 414 | Inst | instances | none |
| instances.critical | Critical | `criticality = 'Critical'` (Instance Profile) | 503 | Inst | instances | none |
| instances.criticalopen | Critical instances not implemented | Critical and status <> Implemented | 503 | Inst | instances | in-page watchlist |
| instances_criticality | Instance criticality | Count by criticality (Critical/High/Medium/Low/Not set) | 503 | Inst | instances | none |
| evidence.onetime / onetimeresolved / onetimemissing | One-time evidence | Active evidence rows with cadence One-time (`vw_pm_instance_evidence_cadence`); resolved by `fn_pm_instance_evidence_is_resolved` (481) | 503 | Inst | evidence | none |
| evidence.recurring | Recurring evidence rows | Active rows with cadence Recurring | 503 | Inst | evidence | none |
| evidence.recurringoverdue | Recurring evidence tasks overdue | Open `vw_pm_practice_task` rows, `is_overdue = 1`, source `Schedule`, linked to a scoped instance, with a row in `fn_pm_task_recurring_evidence` (482) | 503 | Inst | evidence | none (Task Board has no source URL filter) |
| evidence_alignment | Evidence alignment status | Rows by `evidence_alignment_status_master` name as recorded (Inherited / Organization Defined / ...; Not set) | 503 | Inst | evidence | none |
| dependencies.linked / dependencies_category | Linked dependency objects | Active `practice_dependency_resolution` rows by category | 503 | Inst | dependencies | none |
| dependencies.instances | Instances with dependencies | Distinct instances with >= 1 active resolution | 503 | Inst | dependencies | none |
| dependencies.expired | Instances with an expired dependency | Home overview rule: linked tool licence/support, application support/end-of-life or vendor contract end date before today | 503 | Inst | dependencies | none |
| instances_critical (list) | Critical instances not implemented | Top 20: Not Implemented, then Partially, then Not Updated; oldest update first | 503 | Inst | instances | `resolve-workspace?instanceId&organizationId&mode=view` |

Severity on *Needs attention* is a fixed category per check (High / Medium, matching the Home overview's attention severities), not a threshold on the count.

## Out-of-scope register (not shown -- no reliable operational source)

| Spec item (section 6) | Why not shown |
|---|---|
| Evidence aligned / not aligned with obligations | The alignment master records *Inherited / Enhanced / Partially Aligned / Organization Defined*; nothing records alignment with the obligation. Shown as recorded alignment status instead. The Home overview's "Evidence not aligned" check reads codes `Aligned` / `Not Aligned` that the master does not contain. |
| Unmapped dependencies | Operationalize stores "No" and an unanswered category identically (no resolution rows). |
| Dependencies missing owner / criticality | Not captured per instance dependency. |
| Practice maturity distribution | No persisted maturity scale or score. |
| Instance inactive / retired counts | Dashboard counts Active instances only (existing rule); not requested as separate metric. |
| Ageing for governance items | Practice instances have no due / review / target date. |
| Period filter | Governance figures are point-in-time; no period applies. |
| Drill-downs for criticality, no owner, evidence, dependencies | Operationalize accepts only `status`, `ownerEmployeeId`, `releaseId`, `practiceId`; adding filters would be functional change. Those elements are shown as non-clickable. |

## Observations for the product owner (not changed)

- `dashboard-summary` (`pm_get_practice_repository`): 404 re-issued the 393 body, so 398's per-user scoping of the Home overview counts is no longer live.
- The Home overview's attention routes `practice-instances` (menu row Inactive) and `evidence-configurations` (no menu row) open screens that are not in the menu.
- Section permission is applied when the page opens and to which sections render; the data endpoint returns all governance rows to a caller who may open the dashboard.

## Deploy

1. `503_governance_dashboard_insights.sql` (after 456, 481, 482, 492). Ends with a PASS/FAIL check.
2. Web (cshtml, js, css, `ManagementDashboards.cs`). No API rebuild needed.
3. Hard refresh. Users keep their access; the new sections ride on the existing Operationalize VIEW grant.

## 2026-11-10 -- Implemented / applicable on the same card (528)

Request: show implementation status on the control-statement and practice cards (e.g. 50/93) with a two-colour bar, and merge the two practice-instance cards into one. Same implementation logic as the grids; Partially Implemented is **not** counted as implemented.

| Card | Value | Bar (two colours) | Source |
|---|---|---|---|
| Control statements | `ImplementedStatementsCount` / applicable | green = implemented, blue = applicable not implemented, track = rest of total | `subscribed-frameworks` (statement rule incl. the 2026-11-10 "practice without instance" fix in `PracticeRepositoryService`) |
| Practices | `practices.implemented` / applicable | green = implemented, blue = applicable not implemented, track = rest of total | 528 (new KPI row) + `dashboard-summary` |
| Practice instances (one card, replaces *Practice instances* + *Implemented instances*) | implemented / total | green = implemented, blue = not implemented | 414/456 |

`practices.implemented` (528, `sp_dashboard_governance`): Active practices with `applicability_status = 'Applicable'`, at least one Active instance under the same practice/requirement, and no such instance whose status is not *Implemented*. Organisation scope (like `practices.noinstance`). If 528 is not run, the Practices card falls back to the earlier *Applicable practices* card.

UI: `gracDash.kpiCard` takes optional `segments` + `segTotal` and renders a split meter (`.pm-dx-meter.is-split`); `gracDash.dot` is exported for the qualifier legend. Other dashboards are unchanged (no `segments` = old single meter).

Deploy: run `528_governance_dashboard_practices_implemented.sql` (PASS row), deploy Web (js + css), hard refresh. Rollback: `528_..._rollback.sql` (503 body).

Layout (2026-11-10): **Framework coverage** now sits on its own full-width row under the KPIs; below it *Needs attention* | *Implementation status* + *Practice applicability*, then the remaining analytics and the watchlist. JS only (`renderGovernance`), existing classes.

## 2026-11-16 -- Framework filter (573)

**Request:** a framework filter next to the organization; "All" first, a chosen
framework shows only that framework.

**UI** (`Partials/management-dashboard.cshtml`, `management-dashboard.js`):
`#mdFramework` after the organization select, existing toolbar select style.
Filled from the same `subscribed-frameworks` rows as Framework coverage
(`fillFrameworks`); hidden until those rows load. Organization change resets it to
All frameworks. The context strip shows the chosen framework.

**What follows the filter**

| Area | All frameworks | One framework |
| --- | --- | --- |
| Subscribed frameworks, Control statements, Framework coverage, statements not updated / updates pending | every subscribed release | that release's row only (client-side) |
| Practices card, Practice applicability chart, Practices not updated | `dashboard-summary` (organisation) | governance KPIs `practices.total / applicable / notapplicable / notupdated` (same definitions), scope label "Selected framework" |
| Practices implemented / without an instance | organisation | practices of the release |
| Instances, evidence, dependencies, watchlist | ownership rule | ownership rule + practices of the release |

**Which practices belong to a release:** `grac_practice.fn_pm_release_requirements(@organization_id, @release_id)`,
the Practice View *Mapped frameworks* rule (301): an Active statement mapping whose
release (`mapping.release_id`, else the statement's) is the release; or, for a
requirement with no Active mapping, its organisation control's release. A practice is
in scope through `practice.organization_requirement_id`; a practice can belong to
several releases, so per-framework figures do not add up to the All figure.

**SQL:** `573_governance_dashboard_framework_filter.sql` -- the TVF, and
`sp_dashboard_governance` (528 body) with `@release_id BIGINT = NULL` (NULL = 528
figures exactly) plus the four practice KPIs. Rollback restores the 528 body and
drops the TVF.

**API:** `releaseId` query parameter on both tiers (see `docs/management-dashboards.md`).
