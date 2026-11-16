# Audit → Question Sets: set details and questions on one page (migration 520, 2026-11-05)

This change replaces the 516 Question Repository. Questions belong to their set again. The menu entry is now **Audit Assurance → Question Sets**, directly under Audit Assurance at position 445.

## Screen (`org-assurance-question-sets`)

The screen has two views on one page.

### List view
- Shows the organization's question sets with organization and search filters.
- **New Question Set** opens a blank set page.
- Clicking a row, or choosing **Open** from its 3-dot menu, opens that set's page.
- The 3-dot menu also offers **Delete**.

### Set page
- **Question Set Details**: Code (mandatory, and fixed once the set is saved), Name (mandatory), Status, Owner and Description.
- **Questions**: an editable grid. Each row has these columns:

  | Column | Required | Notes |
  |---|---|---|
  | Order | | Type a new position to move the row. |
  | Code | Mandatory | Unique in the set, and fixed once saved. |
  | Question | Mandatory | |
  | Response Type | Mandatory | Admin question types (see 517). |
  | Mandatory | | Yes / No |
  | Evidence | | **Not Applicable** or an Evidence Type (see below). |
  | Weight | | |
  | Status | | Active / Inactive |
  | Ver | System | Version number, read-only. |

- The chevron on a row opens **Description / Guidance** and **Expected Evidence** for that question, directly underneath it.
- **Add Row** inserts a blank row. The trash button on a row takes it out of the grid.
- Rows are marked until you save:
  - a green edge means a new row;
  - an amber edge means an edited row;
  - an "Unsaved changes" note appears beside the buttons.
- If there are unsaved changes, leaving the page (Back, Cancel, or switching organization) asks for confirmation first.
- **Save** does two things in order:
  1. Saves the set details (`POST question-sets`).
  2. Saves the whole grid in one call (`POST question-sets/{id}/questions/grid`). This step is all-or-nothing: any validation failure is reported as "Row n: …" and nothing in the grid is written.
- **Actions** (on the page heading) offers Delete.

The same partial is hosted on the Audit Definition page (Question Set tab), where it works inside the tab.

## Question fields

The fields are those of the 2026-11-05 list, without Category / Subcategory.

| Field | Column | Notes |
|---|---|---|
| Code | `question_code` | |
| Question | `question_text` | |
| Description / Guidance | `help_text` | |
| Response Type | `question_type_id` / `_code` / `_name` | |
| Mandatory | `is_mandatory` | |
| Evidence | `evidence_type_id` / `_code` / `_name` | New in 520. One input: "Not Applicable" (NULL) or the Evidence Type required, from `evidence_type_master` (the list Evidence Config uses). `evidence_required` is derived from it (1 when a type is set). |
| Expected Evidence | `expected_evidence` | New in 520. |
| Weight | `weight` | |
| Status | `status` | New in 520. Active or Inactive. |
| Version | `version_number` | New in 520. Starts at 1 and goes up by 1 whenever the content changes. A change to Status or Order alone does not change it. |
| Created / Updated | existing audit columns | |

## API

The existing question endpoints are unchanged except for the extra fields noted below.

### POST `question-sets/{id}/questions/grid` (new)

Request body:

```
{ organizationId,
  questions: [ { questionId?, questionCode, questionText, helpText, questionTypeId,
                 questionTypeCode, questionTypeName, isMandatory, evidenceTypeId,
                 expectedEvidence, weight, status, displayOrder } ],
  actor }
```

Response: `{ questionSetId, savedCount }`.

How each row is handled:
- A row **with** a `questionId` updates that question. Its code is kept.
- A row **without** a `questionId` is added. If the set once held a removed question with the same code, that question is brought back instead of a new one being created.
- A saved question that is **left out** of the list is removed (soft delete).

### Extra fields on existing endpoints
- `GET question-sets/{id}/questions` and `GET questions/{id}` also return `evidenceRequired`, `evidenceTypeId`, `evidenceTypeCode`, `evidenceTypeName`, `expectedEvidence`, `status` and `versionNumber`.
- `POST questions` accepts `evidenceTypeId` (null = Not Applicable), `expectedEvidence` and `status`, and can create a question again (516 had blocked that).

### Error reasons

| Code | Reason | Meaning |
|---|---|---|
| 53808 | QUESTION_CODE_REQUIRED | |
| 53809 | QUESTION_TEXT_REQUIRED | |
| 53810 | DUPLICATE_QUESTION_CODE | |
| 53812 | SET_MISMATCH | The row's question is no longer in the set. |
| 53813 | RESPONSE_TYPE_REQUIRED | |
| 53814 | INVALID_STATUS | |
| 53815 | DUPLICATE_QUESTION_CODE_IN_GRID | |
| 53816 | INVALID_QUESTIONS | The JSON could not be read. |
| 53817 | EVIDENCE_TYPE_NOT_FOUND | |

## Database (520)

- **New columns** on `org_assurance_question`: `evidence_type_id` (FK `evidence_type_master`), `evidence_type_code`, `evidence_type_name`, `evidence_required`, `expected_evidence`, `status` and `version_number`.
- **New procedure**: `sp_org_assurance_question_set_questions_save`.
- **Re-issued from 077** with the new columns:
  - `sp_org_assurance_question_list`
  - `sp_org_assurance_question_get`
  - `sp_org_assurance_question_save`
- **If 516 had run**, 520 first copies the Repository-only fields onto each set question: Evidence Required, Expected Evidence, Status and Version. It also restores any code that 516 had given a `-S<set>` suffix, where the original code is free in the set.

  It then drops all of 516:
  - the link column;
  - its 11 procedures;
  - the Repository, Category and Subcategory tables;
  - the backup table;
  - the `org-assurance-question-repository` menu row and its permissions.

  Repository questions that were never placed in any set are listed in result set 520-b before they are dropped.
- **Menu**: the `org-assurance-question-sets` row is set to Active, placed under `nav-assurance` at position 445, and every role that lacked rights to it is given full rights. 274 has been updated to match.
- **516** now refuses to run once 520 has been applied.
- **Rollback**: `520_question_sets_inline_questions_rollback.sql`. It restores the 077 procedure bodies, drops the four columns and the new procedure, and puts the menu row back as Inactive under Audit Definition. It does **not** recreate the 516 Repository.

## View first, Edit from Actions (2026-11-05, UI only)

- A row click (or 3-dot **View**) opens the set **read-only**: the details
  (Code, Name, Status, Questions, Description, Created / Updated) and the
  questions table (Order, Code, Question with its Guidance / Expected
  Evidence underneath, Response Type, Mandatory, Evidence Req., Weight,
  Status, Ver).
- **Actions** (view only) offers **Edit**, which switches the same page to the
  edit layout above. Save and Cancel return to the view. The 3-dot menu on the
  list offers **View** and **Edit**.
- **Status** is chosen only when editing a saved set (set Status) or a saved
  question (row Status). A new set and a new question are saved **Active**.
- **Owner** is no longer asked and the list no longer has an Owner column. A
  set that already has an owner keeps it (the Save re-sends the stored owner).
- **Delete** is no longer offered on this screen (the API endpoint is
  unchanged).
- No database or API change.

## Evidence = one input (2026-11-05)

"Evidence Required (Yes / No)" was replaced by one **Evidence** dropdown: the
first option is **Not Applicable** (no evidence needed); any other option is the
Evidence Type that is required (`GET evidence-types`, the same list Evidence
Config uses). So one input says both *whether* evidence is required and *which*
type. The view page shows the type name or "Not Applicable". Migration 520 was
updated (columns, procedures, rollback); if an earlier copy of 520 was already
run, run 520 again -- every step is re-runnable and only adds what is new.

## Questions not shown on row click (2026-11-05)

Reported: opening a set showed no questions. The set page loaded the questions
with `GET question-sets/{id}/questions`, and on a failed call it silently showed
an empty table. The likely failure is a database behind the API (520 not run,
or the earlier copy without the Evidence Type columns): the API read the 520
columns unconditionally and the call failed.

- API (`OrgAssuranceQuestionService.MapQuestionRow`): the 520 columns are read
  only when the procedure returns them, so the questions list no longer fails
  on a database that is behind.
- UI: if the questions cannot be loaded, the set does not open; the list shows
  "Could not open the question set: its questions could not be loaded -- <the
  API's error>". Opening a set with no questions on screen would also have let
  a Save remove all of its questions, so this is refused, not hidden.

### Question Set tab: selection only (2026-11-05)

The Audit Definition page's Question Set tab now shows only the selection
panel (`_audit-question-set-adoption`: Available / Asked by this audit, icon-only
`>` / `<` buttons -- fa-angle-right / fa-angle-left with a title, the dual-list
pattern used elsewhere -- Up / Down, Save question sets). The Question Sets library that sat
under it is no longer hosted there (`_audit-definition-workspace.cshtml`
dropped the `org-assurance-question-sets` partial and its organization sync).

- **Add new question set** (link under the Available list) opens
  Audit > Question Sets in a new browser tab, straight on a new set
  (`?new=1`, read by `org-assurance-question-sets.cshtml`). The organization
  is the one last picked (shared organization preference), not passed in the URL.
- Back on the audit's tab, the Available list re-reads the sets on window focus
  and on **Refresh list**, keeping picks not yet saved (anything already moved
  to "Asked by this audit" stays there).
- UI only; no database or API change.

#### Selection panel layout (2026-11-05)

- "Asked by this audit" now reads **Selected for this audit**; each list label
  carries a count badge; the footer reads "n set(s) selected for this audit".
- Labels, boxes and hints are three rows of one CSS grid (`.oa-adopt-grid`,
  grid-template-areas), so both boxes start on the same line regardless of the
  hint text under each; the `>` / `<` and up / down buttons are centred beside
  the boxes. Narrow screens restack the areas into one column.
- Boxes are taller (260px), with rounded borders, roomier options, a primary
  tint on the selected option and a focus ring (design tokens only).
- Files: `_audit-question-set-adoption.cshtml`, `practice-management.css`
  (the `.oa-adopt-*` block). UI only.

- The panel heading "Question sets used by this audit" and its line "These sets are asked by the current draft version of this audit." were removed (the tab caption and list labels say it). The line under the tab now appears only when it adds something: no audit picked yet, or "Read-only: ... while the current version is Draft."

## Grid look and columns (2026-11-13, UI only)

- **Order, Status and Ver columns removed** from the edit grid and the view
  table. Rows keep the order they are entered in (saved as displayOrder 1..n).
  A new question is saved Active and version 1; a saved question keeps its
  status and version (Save re-sends the stored status; the version still rises
  on a content change).
- **Spreadsheet look**: the cells carry the grid lines and the inputs have no
  border of their own; the focused cell gets a primary outline; a saved code
  shows greyed (fixed).
- **Question** is the widest column and grows with its text (auto height, no
  drag handle; `autoSize()`); inputs use border-box so the height is exact.
- The row's chevron (Description / Guidance, Expected Evidence) is unchanged.
- File: `org-assurance-question-sets.cshtml` only.


## Importing question sets from Excel -- `database/tool_import_audit_question_sets.sql` (2026-11-13)

Loads `GRAC_Audit_Question_Sets_9_Samples.xlsx` (9 sets, 90 questions) into **one organization**. The workbook rows are embedded in the script as `VALUES`; sheet "Question Sets" and sheet "Questions" are linked by **QuestionSetCode** (`set_code`).

- Writes through the screen's own procedures -- `sp_org_assurance_question_set_save` (077) and `sp_org_assurance_question_set_questions_save` (520) -- in one transaction, so the Question Sets page's rules apply and any error rolls back everything.
- Mapping: QuestionCode -> `question_code`; Question -> `question_text`; ResponseType -> Admin response type matched by name (`sp_org_assurance_admin_question_type_list`, 517); Mandatory Yes -> `is_mandatory`; Evidence -> `evidence_type_master` matched by name or code; Weight -> `weight`; DescriptionGuidance -> `help_text`; ExpectedEvidence -> `expected_evidence`; Status Active; version is system managed (the sheet's Version is not loaded); order = row order in the set.
- Settings at the top: `@OrganizationId` (required; left NULL it lists the organizations), `@DryRun` (1 = report only), `@ExistingSet` (`SKIP` default / `REPLACE` -- replace makes the set's questions exactly the sheet's, removing others the way the screen does; the owner is kept), `@MissingEvidenceType` (`DEFAULT` default -- a label not in `evidence_type_master` gets `@DefaultEvidenceType`, "Register", matched by name or code; the script stops if that type is not in the master / `ABORT` / `CREATE` adds the label to `evidence_type_master` / `NONE` imports it as Not Applicable). Labels that match keep their own type.
- The dry run shows three result sets: each set's action (create / skip / replace), response-type matches, and evidence-label matches. It also stops on a set code that belongs to a removed (inactive) set, since `set_code` is unique per organization.

## List: Mandatory and Total Weight columns (migration 535, 2026-11-13)

- **Request (sir):** show each set's mandatory question count and total weightage in the Question Sets list.
- **Database:** `535_question_set_list_mandatory_weight.sql` re-issues `sp_org_assurance_question_set_list` (077 body) with `MandatoryCount` (questions with `is_mandatory = 1`) and `TotalWeight` (`SUM(weight)`, 0 when none) on the page rows. Both count the same questions as `QuestionCount` (`is_active = 1`, whatever the question's Status). Rollback restores the 077 body.
- **API:** `GET /api/practice/org-assurance/question-sets` rows (`OrgAssuranceQuestionSetListRow`) gain `mandatoryCount` (long?) and `totalWeight` (decimal?). They are null when the database predates 535 (read with `HasColumn`).
- **UI:** `org-assurance-question-sets.cshtml` list columns: Code, Name, Questions, **Mandatory**, **Total Weight**, Status. Whole numbers show without ".00"; "-" before 535 is run.
