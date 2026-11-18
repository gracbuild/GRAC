# Risk methodology -- organisation-configurable, versioned (migration 532, 2026-11-12)

## Request

A risk manager reviewing the risk pages asked for **velocity** beside likelihood and impact. A gap review against ISO 31000, COSO ERM 2017 and ISO 27005 / NIST 800-30 found nine more commonly used elements missing.

Sir decided to make all of them organisation-configurable, so that each organisation builds its own risk methodology:

- **3D scoring** is available as an option.
- **Methodology versioning** is required.
- It is **configured by the org admin**.
- Everything is in scope **except KRIs**.

## What an organisation configures -- Risk Management -> Settings -> Risk Methodology

| Element | Setting |
|---|---|
| Velocity, proximity, persistence, control effectiveness, confidence, and the organisation's own dimensions | Per dimension: on / off, required, which stages ask it (inherent / residual / review), its levels (1-10, name, descriptor) and a priority weight. **Every dimension follows the convention that a higher level means more risk** (control effectiveness: 1 = Effective ... 5 = No controls). |
| Scoring mode | **Matrix**: likelihood x impact through the matrix, as before.<br>**Priority**: the rating is unchanged; the priority score is `L x I + SUM(weight x level)` over the stage's dimensions.<br>**3D**: the score is `L x I x level of the third-axis dimension`, and the rating comes from the version's score bands. |
| Score bands (3D) | Each band is a score range mapped to one of the matrix's **own** rating codes. Publish checks that the bands cover 1 .. maxL x maxI x maxLevel with no gaps or overlaps. |
| Appetite | The highest acceptable rating, either per risk category or as a default. Where a risk has several categories, the strictest applies. |
| Target rating | Asked on the inherent and review pages. The register shows "Target X" until the residual rating reaches it. |
| Impact by area | **Single**: as before.<br>**Max** or **Average**: impact is rated per impact area and the overall impact is derived. The Impact select becomes read-only.<br>The areas belong to the version (`risk_methodology_impact_area`); templates add Financial, Operational, Legal & Regulatory, Reputational, Customer, People, Information Security and Environmental. 309, which would have added an organisation impact-area master, was withdrawn and is not used. |
| Trend | Up / Down / Same against the previous version of the current stage. |
| Quantification | SLE and ARO are captured; ALE = SLE x ARO; one currency per methodology. |
| Templates | A draft can be started from ISO 31000, COSO ERM, ISO 27005 or Blank. Every template writes all five standard dimensions and switches on its own set. |

### Versioning

How it is controlled:

- **Rows.** Every version is one row in `risk_methodology_version` with a status: **Draft**, **Published** or **Superseded**.
- **Database rule.** Two filtered unique indexes allow at most one Draft and one Published row per organisation (`ux_pm_rmv_one_draft`, `ux_pm_rmv_one_published`).
- **Draft.** "New ..." in the Draft combo creates the Draft (`sp_risk_methodology_draft_create`), as a copy of the published version or from Blank / a template. Save draft overwrites the Draft's own rows only. The published version and the risks are never touched.
- **Publish** (`sp_risk_methodology_publish`):
  - It validates everything: a name, at least two levels per enabled dimension, 3D band coverage, appetite ratings, a currency for quantification, impact areas.
  - In one transaction, the current Published version becomes **Superseded**, and the Draft becomes **Published** with `version_no = MAX(version_no) + 1` for the organisation.
- **Stamping.** Every assessment row (`risk_assessment_methodology`) stores the `methodology_version_id` it was made under. Superseded versions are kept, never deleted, so old assessments still read their own version.
- **Stale page.** A risk page sends the version it rendered. If it is no longer the published one, the save is refused (58332, "reload the page").
- **History.** Risk Management -> Settings -> Risk Methodology -> Version history lists every published and superseded version with its name, scoring mode, template, date and who published it.

**Name.** `methodology_name` is required to publish (58341). Templates pre-fill "<template> based risk methodology". The name is shown on the settings page, in the version history, and as the heading of the methodology block on the risk pages.

### Who

- Menu row `risk-methodology` sits under Risk Management -> Settings (`risk-centre-settings`, moved there by 533; under the organisation Settings menu before that), granted to the `ORG_ADMIN` and `GRAC_ADMIN` roles only.
- The Web proxy refuses writes without EDIT on `risk-methodology`.
- The risk pages only **read** the published version.

## How it reaches the rating (3D)

- One procedure produces every rating: `sp_risk_rating_resolve`, called by `sp_risk_analysis_save` (inherent, register assess, review re-assessment) and `sp_risk_residual_analysis_save`. 532 re-issues only this procedure: the 206 body plus a 3D block.
- The Api puts the page's dimension values in `SESSION_CONTEXT('grac.risk.methodology')`. This happens inside **one transaction** with the base save and `sp_risk_methodology_assessment_save`, so the stored rating and the stored methodology values cannot disagree.
- **`rating_score` stays on the matrix scale.** It is the lowest matrix score of the band's rating (`fn_risk_rating_rank`), because `sp_risk_approval_required` compares scores against matrix cells. The raw 3D score is kept in `risk_assessment_methodology.score_3d`.
- Because the stored scores stay comparable, the approval gate, acceptance authority, register, dashboard and heat map all keep working unchanged.
- A save without the context (bulk review, or an older client) resolves through the matrix, as before.

## Database (532)

| Object | Purpose |
|---|---|
| `risk_methodology_version` | One row per draft / published / superseded version (filtered unique: one Draft and one Published per organisation). Holds the switches. |
| `risk_methodology_dimension`, `risk_methodology_dimension_level` | Dimensions and their levels, per version. |
| `risk_methodology_score_band` | 3D bands, per version. |
| `risk_methodology_appetite` | Appetite rows, per version (category or default). |
| `risk_methodology_impact_area` | Impact areas, per version (impact by area). |
| `risk_assessment_methodology` | One row per scored assessment: stage (Inherent / Residual), source (Assess / Review / Residual), analysis or residual id, version, mode, L / I, matrix rating, effective rating, `score_3d`, priority, target, derived impact, SLE / ARO / ALE. |
| `risk_assessment_dimension_value` | The assessment's dimension levels and impact-area levels, with names frozen. |
| `fn_risk_rating_rank(org, code)` | The order of an organisation's ratings: the lowest score of the rating's cells. |
| `sp_risk_rating_resolve` | Re-issued: the 206 body plus the 532 3D block. |
| `sp_risk_methodology_get` | Published + draft. Result sets: versions, dimensions, levels, bands, appetite, ratings, impact areas (per version), categories, history, scale. |
| `sp_risk_methodology_draft_create` / `_draft_save` / `_draft_discard` / `_publish` | The draft lifecycle. `_publish` validates everything. |
| `sp_risk_methodology_template_fill` | Fills a draft from a template. |
| `sp_risk_methodology_assessment_save` | Validates the payload against the published version (version unchanged, required dimensions present, known levels, impact areas agree with the overall impact, target is a matrix rating) and stores it. |
| `sp_risk_methodology_assessment_get` | One risk's applied inherent, newest inherent and current residual methodology rows, with their values. |
| `sp_risk_methodology_register_summary` | Per risk: priority, 3D score, ALE, target / met, appetite status, trend; plus the current dimension values. |

- Errors 58301-58341, surfaced verbatim.
- Rollback: `532_risk_methodology_rollback.sql`. It restores the 206 resolver and drops the 532 objects. **Methodology settings and assessment values are lost**; ratings already stored stay.
- `274_menu_master_seed.sql` now has the row. Run its Section 3 with `@RolesScope = 'ADMIN'` to keep 532's narrower grant.

## API -- `/api/practice/risk-centre` (Web proxy: `/practice/api/risk-centre`)

| Method | Route | Body / query | Answer |
|---|---|---|---|
| GET | `methodology` | `?organizationId=` | `{ success, sets: { versions, dimensions, levels, bands, appetite, ratings, impactAreas, categories, history, scale } }` (rows camelCase) |
| POST | `methodology/draft` | `{ organizationId, templateCode (null = copy published; BLANK, ISO31000, COSO_ERM, ISO27005), replace }` | `{ success, methodologyVersionId }` |
| POST | `methodology/draft/save` | `{ organizationId, draft: { methodologyName, scoringMode, thirdAxisCode, targetRatingEnabled, appetiteEnabled, impactMode, trendEnabled, quantificationEnabled, currencyCode, notes, dimensions[{ dimensionCode, dimensionName, description, isEnabled, isRequired, askInherent, askResidual, askReview, priorityWeight, displayOrder, levels[{ levelValue, levelName, descriptor }] }], bands[{ minScore, maxScore, ratingCode }], appetite[{ riskCategoryCode, maxRatingCode, appetiteStatement }], impactAreas[{ areaCode, areaName, displayOrder }] } }` | `{ success, methodologyVersionId }` |
| POST | `methodology/draft/discard` | `{ organizationId }` | `{ success }` |
| POST | `methodology/publish` | `{ organizationId }` | `{ success, methodologyVersionId, versionNo }` |
| GET | `register/{riskId}/methodology` | | `{ sets: { assessments (slot Inherent / Latest / Residual), values } }` |
| GET | `register/methodology-summary` | `?organizationId=` | `{ sets: { risks, values } }` |
| POST | `register/{riskId}/assess`, `register/{riskId}/residual`, `register/{riskId}/review` | existing body + optional `methodology: { methodologyVersionId, values[{ dimensionCode, levelValue }], impactAreas[{ areaCode, impactCode }], targetRatingCode, singleLossAmount, annualRate }` | unchanged |

- Writes on `methodology/*` need EDIT on `risk-methodology`; otherwise the Web answers 403. The organisation is checked from the body.
- An Api without 532 in the database answers the reads with `success: false` ("not installed"). The risk pages then carry on without methodology.

## UI

- **Risk Management -> Settings -> Risk Methodology** (`Partials/risk-methodology.cshtml`, `js/RiskCentre/risk-methodology.js`)
  - The toolbar has the org picker, the **Draft** combo and the standard icon Reload button (`pm-button icon`, the same one the dashboards use).
  - **Draft** shows **Current draft**, selected, while a draft is open (the form is that draft). Its other options start a new draft as soon as they are chosen; there is no Start button:
    - **New -- blank**: everything off, set it up fresh.
    - **New -- copy of the published version**: only when one exists.
    - **New -- from a template**: opens a **Template** combo (ISO 31000, COSO ERM, ISO 27005); picking a template starts the draft.
  - Replacing an open draft asks first. Cancel changes nothing, and the combo returns to Current draft (or "-- choose --" when there is no draft).
  - The page shows the published version read-only. With a draft open it shows the editable sections: Scoring, Dimensions (with levels), 3D score bands, Impact areas, Risk appetite, then Save draft / Discard draft / Publish.
  - In the Dimensions table, a dimension that is not **Enabled** shows its Required / Inherent / Residual / Review boxes unticked and locked, because the risk pages never ask a disabled dimension. The stored flags (the template's defaults) are kept, so ticking Enabled brings them back.
  - Version history is listed at the bottom.
  - Confirmations go through `gracUi.confirm`.
- **Risk Analysis, Residual, Review pages** (`risk-centre.cshtml` hosts `raMethodology`, `rrMethodology`, `rvMethodology`; `risk-centre.js` `mountMethodology`, `collectMethodology`)
  - The pages show the stage's dimensions, the target (not on residual), the 3D or priority score, impact by area and quantification. Values are pre-filled from the risk's own assessment.
  - The rating preview follows 3D through `resolveRating(..., prefix)`.
  - Required dimensions are checked before saving.
- **Risk Register:** under the Residual cell, tags show "Above appetite", "Target X" (not yet met), a trend arrow, "P <priority>" and "3D <score>" (`decorateRegisterMethodology`).

## Not included

- KRIs, as decided.
- Methodology values on the read-only risk detail page. The data is available from the two reads above.
- Bulk review does not re-score, so it does not touch methodology values.

## Deploy

1. Run `532_risk_methodology.sql` and confirm 4 PASS rows. Requires 204-206, 258, 375, 022 and 052 (not 309, which is withdrawn).
2. Restart the Api.
3. Publish Web.
4. Hard refresh.
5. As org admin: Risk Management -> Settings -> Risk Methodology -> Draft -> New ... -> adjust -> Publish. (Run 533 for the menu location.)
6. Org admins must sign out and back in to see the new menu (permissions are read at sign-in).

## Risk Management dashboard (2026-11-12)

The dashboard is per organisation (its organization filter). It adds only what that organisation's **published** methodology switches on. With no published methodology it is unchanged. All figures are for **open** risks (not Closed / Retired) and come from each risk's current assessment (residual, else inherent), via `register/methodology-summary`.

| Switch on | Added |
|---|---|
| Quantification | KPI **Annual loss expectancy**: the sum of ALE, in the methodology currency, with "N of M open risks quantified". |
| Appetite | Needs attention, High: **Above risk appetite**. |
| Target rating | Needs attention, Medium: **Target rating not met** (the residual rating is still above the target). |
| Trend | Distribution **Rating trend**: went up / unchanged / went down / first assessment. |
| Each enabled dimension | Distribution by level (e.g. **Velocity**: 1 Slow ... 4 Very fast), plus "Not assessed yet". |

- The appetite and target checks are not clickable, because the register has no filter for them. The register rows carry the same tags.
- `sp_risk_methodology_register_summary` returns `StatusCode` so that the dashboard can count open risks.
- The change is in `risk-centre.js`: `refreshDashboard`, plus `fetchMethodologySummary`, which is shared with the register tags.

## 574 -- Likelihood, impact and the risk matrix (2026-11-16)

**Request:** add Likelihood and Impact to Dimensions. Every box is ticked and locked, and only their levels can change. 3x3, 4x4 and 5x5 methodologies must work. When the scale changes, older risks are marked "Re-assessment needed" and shown separately on the heat map. Publishing is allowed only when no assessment is waiting for approval, and the page warns first.

### What the admin sees (Settings -> Risk Methodology)
- **Dimensions** starts with two locked rows, **Likelihood** and **Impact**.
  - On, Required, Inherent, Residual and Review are all ticked and disabled. Weight is not used.
  - Their levels are edited in the same level grid as other dimensions: name and descriptor.
  - Levels can be added or removed **at the top only**, so the values stay 1..n. Each axis has 2 to 10 levels.
- **Risk matrix** (new section):
  - One rating per likelihood x impact cell. Rows are likelihood, highest first; columns are impact, as on the heat maps.
  - The matrix resizes with the levels. A new cell gets a suggested rating; the suggestion is L x I as a share of the maximum, spread over the current ratings.
  - **Default ratings** re-suggests every cell.
  - Ratings come from the organisation's own ratings: the current matrix plus any earlier version's. New rating codes cannot be invented here.
- 3D bands and appetite offer the ratings of the version's own matrix. A saved choice that the matrix no longer has is shown as "(not in the risk matrix)".
- **Publish** compares the draft with the published version.
  - If the size changes, or any cell's rating changes, the page warns first. The warning shows the old and new size and how many open risks were assessed. Those risks keep their ratings, but they are marked "Re-assessment needed" and shown separately on the heat maps.
  - If any assessment is waiting for approval, the page stops and says so. The server enforces the same rule (58349).

**Layout (2026-11-17):** the editable sections come in three groups.
1. **Likelihood & Impact**: its own panel, with the same columns as Dimensions.
2. **Risk matrix**: directly under the levels it follows.
3. **Dimensions**: the other dimensions.

The Likelihood / Impact checkboxes are ticked and **not disabled**. Unticking one puts the tick back and shows "Likelihood and impact are always asked, at every stage. Only their levels can be changed."

### Where it shows
| Place | Behaviour |
|---|---|
| Risk register | Tag **Re-assessment needed** beside the residual cell (`decorateRegisterMethodology`). |
| Risk Analysis / Review page | When the current inherent assessment is older than the scale change, a note is shown and Likelihood / Impact are **not pre-filled**. Impact-area levels are not pre-filled either. |
| Residual page | The same, for the current residual assessment. |
| Dashboard | Flagged risks are **not plotted** on the heat maps. The hint under each map reads "N on the previous scale (re-assessment needed)". Needs attention shows **Re-assessment needed** (only when > 0). |

The flag clears for a stage when that stage is assessed again, because a newer analysis or residual assessment is then applied.

### Database (574)
| Object | Purpose |
|---|---|
| `risk_methodology_matrix_cell` (new) | The version's matrix: `likelihood_value`, `impact_value`, `rating_code`, `rating_name`, `colour_hex`. |
| `risk_methodology_version.scale_changed` (new) | Set on publish when the scale or matrix changed. |
| `risk_methodology_dimension_level` | Likelihood / impact levels are rows with the reserved codes `LIKELIHOOD` / `IMPACT`. They have **no dimension row**, so risk pages, priority / 3D scores and dashboard distributions never treat them as a dimension. A dimension may not use these codes (58342). |
| `sp_risk_methodology_core_fill` (new) | Gives a version the organisation's current levels and matrix, for each part it lacks. Seeds 204's defaults for an organisation with no matrix. Used by templates, by draft create, and by the 574 backfill of every existing version. |
| `fn_risk_scale_reassessment(@org)` (new) | Per risk: `inherent_reassess` and `residual_reassess`. A stage is flagged when its current assessment (`risk_analysis.analysis_dt`, `risk_residual_analysis.assessed_dt`) is older than the latest publish with `scale_changed = 1`. |
| `sp_risk_methodology_draft_save` | Accepts `likelihoodLevels`, `impactLevels` and `matrix`. Each part is replaced only when present. Errors: 58343 (level needs a name), 58344 (2-10 levels numbered 1..n), 58345 (cell out of range or duplicate), 58346 (unknown rating). |
| `sp_risk_methodology_publish` | Validates the scale (58344), that every cell has a rating (58347) and the approval threshold rating (58348). Bands and appetite are checked against the **draft's** matrix, and the 3D maximum uses the draft scale. Then it detects a scale change and refuses while assessments are pending (58349). Finally it syncs the published scale to the organisation, in the same transaction:<br>- `risk_likelihood_master` / `risk_impact_master`: existing levels are renamed; new levels are inserted as `LIKELIHOOD_n` / `IMPACT_n`; levels above the new top become **Inactive**, never deleted.<br>- `risk_matrix_cell` is replaced, with `rating_score = L x I` as in 204's seed.<br>It returns `ScaleChanged`. |
| `sp_risk_methodology_get` | Adds set 11 `matrix`, set 12 `ratingCatalogue` and set 13 `publishCheck` (`PendingApprovals`, `OpenAssessedRisks`). |
| `sp_risk_methodology_assessment_get` | Adds set 3 `scale` (`InherentReassessmentNeeded`, `ResidualReassessmentNeeded`). |
| `sp_risk_methodology_register_summary` | Adds `InherentReassessmentNeeded` and `ResidualReassessmentNeeded`. |
| `sp_risk_dashboard_counts` (505 body) | Sets 12 and 13 leave flagged risks out. Set 14 adds `InherentReassessment`, `ResidualReassessment` and `ReassessmentNeeded`. |

- Stored ratings, names and scores on risks and analyses are **never rewritten**.
- Every existing reader works on the new scale unchanged, because it reads the masters and `risk_matrix_cell`: `sp_risk_rating_resolve`, the scoring options, heat maps and the approval gate.
- Rollback (`574_risk_methodology_matrix_rollback.sql`) restores the 532 and 505 bodies and drops the 574 objects. The organisation's masters and matrix stay as the last publish left them.

### API changes
- `GET methodology`: `sets` gains `matrix`, `ratingCatalogue` and `publishCheck`.
- `POST methodology/draft/save`: `draft` may carry the following. Older clients that omit them keep the draft's scale.
  - `likelihoodLevels: [{ levelValue, levelName, descriptor }]`
  - `impactLevels: [...]`
  - `matrix: [{ likelihoodValue, impactValue, ratingCode }]`
- `POST methodology/publish`: unchanged. It refuses 58342-58349 verbatim.
- `GET register/{riskId}/methodology`: `sets.scale`.
- `GET register/methodology-summary`: `risks[]` gains `inherentReassessmentNeeded` and `residualReassessmentNeeded`.
- Dashboard `heatmapCoverage` gains `inherentReassessment`, `residualReassessment` and `reassessmentNeeded` (0 before 574).

### Deploy
1. Run `574_risk_methodology_matrix.sql`. Expect 3 PASS rows. It requires 532 and 505.
2. Restart the Api.
3. Publish Web.
4. Hard refresh.

