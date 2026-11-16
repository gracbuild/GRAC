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
