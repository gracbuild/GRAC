# Risk Treatment: Existing Controls as a grid (migration 410)

The Risk Treatment page listed each mapped practice instance as a full card. The card showed facts, dependencies and tasks, so with several controls mapped the page became very long. The section is now a grid, and a row click opens that instance's card in a popup.

## Grid

| Column | Source |
| --- | --- |
| Practice / Practice Instance | `PracticeName`, with the instance (`code - name`) under it. A practice-level row reads "Practice-level (no active instance)". |
| Tasks | The number of tasks of **this practice instance** (411). It is the same list the card's Tasks table shows (`/register/{id}/practice-context`). |
| Status | The instance's **implementation status**, new `PracticeInstanceStatus` from `sp_risk_mapping_get` (410). It uses the same expression as the Operationalize grid (315): `COALESCE(implementation_status_master.status_name, practice_instance.implementation_status)`. |
| Actions (3 dots) | **View instance** (was *View practice*) opens Operationalize's read-only view of the instance (`resolve-workspace?instanceId=&organizationId=&mode=view`) in a new tab. It is the same URL Gap Detail uses, and it is disabled on a practice-level row. **Unmap** is disabled on the Primary row. |

A row click opens `#riskMapPracticeDetailModal`; this is the only way to open it, and the row menu has no View details item. The popup shows the **same** card (`practiceItem()`), with framework, statement, practice ref, dependencies, tasks and the unmap control, unchanged. Unmapping from the popup or from the menu goes through one function, `unmapPractice()`, and the popup closes after an unmap.

The Treatment mount passes `practiceGrid: true`, and since 2026-10-08 so do **View Risk** (`rdMapping`, read-only) and **Residual analysis** (`rrMapping`). The other mounts keep the cards: Analysis, Review and Acceptance.

## Changes

- **DB:** `database/410_risk_mapping_instance_status.sql` (+ `_rollback`, which restores the 387 body). It re-issues `sp_risk_mapping_get` from the 387 body. The only additions are one LEFT JOIN on `implementation_status_master` and one trailing column, `PracticeInstanceStatus`.
- **API:** `RiskMappedPracticeRow` gains `PracticeInstanceStatus`, so `GET /register/{riskId}/mapping` practice rows carry `practiceInstanceStatus`. `RiskCentreService` reads the column only when it is present, so an API deployed before 410 still works and shows a blank Status.
- **UI:**
  - `wwwroot/js/RiskCentre/risk-centre.js`:
    - `riskMapping` gets the `practiceGrid` option, plus `practiceGrid()`, `openPracticeDetail()`, `practiceViewUrl()` and `unmapPractice()`.
    - The grid's row menu uses the page's existing `openRowMenu()`, which portals it to body.
  - `Views/Practice/Partials/risk-centre.cshtml`: new popup `#riskMapPracticeDetailModal`, built on the existing `.pm-modal` pattern.

## Tasks per practice instance (migration 411)

Before 411, `sp_risk_scope_practice_context` returned tasks by **practice** (`linked_practice_id`). Two instances of one practice therefore showed the same tasks. Result set 2 now returns one row per (task, mapped instance) and adds a `PracticeInstanceId` column.

A task belongs to a mapped instance when either of these holds:

- `practice_task.linked_instance_id` is that instance.
- The task was raised from a gap on that instance. The gap counts when its source is the instance, or when it is a Custom Gap mapped to the instance. This is the same rule `sp_risk_treatment_state` uses (387/388).

A mapping row that is still practice-level keeps the old practice-wide rule.

The risk's **own** treatment tasks (263, Treat / Reduce etc.) carry the practice but no instance. They no longer repeat on every control row, and they stay listed under *Treatment tasks*.

**Changes for 411:**
- **DB:** `database/411_risk_scope_context_instance_tasks.sql` (+ `_rollback`, which restores the 393 body).
- **API:** `RiskScopePracticeTask.PracticeInstanceId`. It is read only when present.
- **JS:** tasks are grouped by `I<instanceId>` or `P<practiceId>` (`practiceTasksOf`). Both the grid count and the popup card use this grouping.

## Dependency chips per instance (migration 413)

The popup groups a practice instance's inherited dependencies into PERSON / TEAM / ... chips under its `DEPENDENCIES` badge. The badge is `DependencyCount` from `sp_risk_mapping_get` result set 1, counted for **this** instance (`s.practice_instance_id = pm.practice_instance_id`). The chips, however, were derived in the browser by matching each dependency's `SourcePractices` **name** against the mapped practices.

When one practice is mapped as several instances (e.g. PR_017-HR, PR_001-ISM, PR_006-Network of the same practice) they all share the practice name, so every instance card claimed the practice's whole dependency set, and the name match fired once per same-named instance. A single person then showed three times and each team three times, while the badge still read 1.

**Fix:** attribution is now by id, per instance.

- **DB:** `database/413_risk_mapping_instance_dependency_provenance.sql` (+ `_rollback`, which restores the 410 body). It re-issues `sp_risk_mapping_get` from the 410 body and adds two trailing columns to result set 3: `SourcePracticeIds` and `SourcePracticeInstanceIds` -- the DISTINCT `practice_id` / `practice_instance_id` of the `risk_dependency_map_source` rows (`source_kind_code = 'PracticeDependency'`) that inherited each dependency.
- **API:** `RiskMappedDependencyRow` gains `SourcePracticeIds` and `SourcePracticeInstanceIds`, so `GET /register/{riskId}/mapping` dependency rows carry `sourcePracticeIds` / `sourcePracticeInstanceIds`. `RiskCentreService` reads them only when present (an API deployed before 413 omits them, and the browser then falls back).
- **JS:** `wwwroot/js/RiskCentre/risk-centre.js` builds `depsByPractice` keyed by `riskPracticeMapId` (unique per card, was `practiceId`). It attributes a dependency to an instance card by `practiceInstanceId` (mirroring the `DependencyCount` predicate, so chips and badge agree) and to a practice-level card by `practiceId`, and dedupes per card by (category, object). Without the ids it falls back to the old `SourcePractices` name match, still deduped per card. The two lookups (`openPracticeDetail` and the inline card list) key by `riskPracticeMapId`.

## Run

Run 410, 411 and 413 after 387, 388 and 393, restart the API, then hard-refresh the browser.

## View Risk and Residual analysis use the list too (2026-10-08)

The Existing Controls section on **View Risk** (`rdMapping`) and **Residual analysis** (`rrMapping`) now uses the same list as Risk Treatment:
- **Row click** opens the instance card in the popup.
- **3 dots → View instance** opens Operationalize's read-only view in a new tab.

**View Risk** is mounted read-only, so its menu shows no **Unmap** (`applicable: !st.readOnly`), and the popup card has no unmap control either. **Residual** keeps Unmap, with the same Primary-row rule as Treatment.

The 3-dots label changed from *View practice* to **View instance** on all three pages, because it opens the instance.

UI only, in `risk-centre.js` and comments in `risk-centre.cshtml`: two mount options were added and one label renamed. No API or database change.

## Row click opens the instance; popup and 3-dot menu removed (2026-10-08)

This applies to all three list pages: Risk Treatment, View Risk and Residual analysis.

**Row click**
- It opens the practice instance's Operationalize view in a new tab: `resolve-workspace?instanceId=&organizationId=&mode=view`, via `practiceViewUrl()`, the same URL as before.
- A practice-level row has no active instance to open, so it is not clickable. Its tooltip says why.

**Removed**
- The row popup `#riskMapPracticeDetailModal`: its markup and CSS in `risk-centre.cshtml`, plus `openPracticeDetail` / `closePracticeDetail` and `st.depsByPractice` in `risk-centre.js`.
- The 3-dot menu (View instance / Unmap) and its click handler.

**Unmap is kept.** On the editable pages (Treatment, Residual), the last column is the card's unmap **X**. It uses the same `rmp-remove` button and the same `[data-map-practice-remove]` handler that calls `unmapPractice()`, and it is disabled on the Primary row. View Risk is read-only, so it has no such column.

The cards (`practiceItem`) are still used by the Analysis, Review and Acceptance mounts.

UI only. No API or database change.

## Review Risk uses the list too (2026-10-23)

The Existing Controls section on **Review Risk** (`rvMapping`) now mounts with
`practiceGrid: true`, like Treatment, Residual analysis and View Risk: the same
columns, a row click opens the instance's Operationalize view in a new tab, and
the unmap **X** column is shown (Review is editable; disabled on the Primary
row). The cards (`practiceItem`) remain only on the Analysis and Acceptance
mounts.

UI only (`risk-centre.js` mount option, comment in `risk-centre.cshtml`). No API
or database change.
