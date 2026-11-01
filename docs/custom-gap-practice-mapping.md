# Custom Gap -> Practice mapping (migration 382)

Adds the ability to map relevant Practice(s) to a Custom Gap on the
**Add Custom Gap** form, reusing the same cascading Practice Picker that
Risk Analysis already uses. No new selector was created.

## Reused control
`wwwroot/js/practice-picker.js` (`window.__practicePicker`, migration 282)
-- the same component Risk Centre and Exception Centre mount. On the Add
Custom Gap dialog it is opened in a small dialog (`#gapMapPracticeModal`),
the chosen practice is added to a mapped-practices chip list, and the
selected practice ids ride along in the create payload.

Data source is unchanged: `/practice/api/practice-picker/*`
(PracticePickerService).

## Rule
At least one Practice must be mapped to create a Custom Gap. Enforced in
the UI (submit is blocked) and in the API (`OpenAsync` returns
`PRACTICE_REQUIRED` when the list is empty). The stored procedure stays
tolerant (inserts whatever ids are passed) so no non-UI caller breaks.

## Database (migration 382)
- New table `grac_practice.custom_gap_practice_map` -- one row per mapped
  practice, mirroring `risk_practice_map` (261): `custom_gap_id`,
  `practice_id`, frozen `practice_name`/`practice_code`, `organization_id`,
  `mapped_by_employee_id`, `record_status_id`; `UNIQUE(custom_gap_id, practice_id)`.
- `sp_custom_gap_open` re-issued from its live (368) body with one new
  OPTIONAL trailing parameter `@practice_ids_json` (JSON array of practice
  ids). After the gap row is inserted, one map row per id is created for
  practices in the same organization, with name/code frozen from
  `grac_practice.practice`. NULL/empty -> no rows (older callers unaffected).
- New `sp_custom_gap_practice_map_list @custom_gap_id` -- returns the
  active mapped practices for read-only display.
- Rollback: `382_custom_gap_practice_map_rollback.sql`.

## API
- `POST /api/practice/gaps/custom` (`CustomGapController.Open`,
  `CustomGapService.OpenAsync`) -- request model `CustomGapOpenRequest`
  gains `PracticeIds` (`IReadOnlyList<long>?`, optional/last). Serialized
  to JSON and passed as `@practice_ids_json`.
- `GET /api/practice/gaps/custom/{id}/practices` -- new read endpoint
  (`CustomGapController.Practices` -> `GetPracticesAsync` ->
  `sp_custom_gap_practice_map_list`). Returns `{ data: [ { customGapPracticeMapId,
  customGapId, practiceId, practiceName, practiceCode, mappedDt } ] }`.
  The Web tier reaches it through the existing `custom/{**path}` GET proxy
  (`GapsController.CustomProxyGet`), which requires `organizationId` on the
  query string.

## UI
- `Views/Practice/Partials/gaps.cshtml` -- Add Custom Gap dialog gains a
  "Mapped Practices" chip list + "Map practice" button and a native
  `<dialog>` (`#gapMapPracticeModal`) hosting the shared picker; loads
  `practice-picker.js`. Selected ids are sent as `practiceIds`.
- `wwwroot/js/GapLifecycle/gap-detail.js` and `gap-view.js` -- render the
  mapped practices read-only (they fetch the GET endpoint above). Custom
  gaps have no edit form, so post-creation the mapping is display-only.

## Add Gap: Priority removed, Severity required (2026-10-25)

The SLA of a Custom gap is matched on **severity** (`sp_custom_gap_apply_sla`
-> `sp_org_sla_match_for_severity`, classification = severity); priority was
only the fallback when severity was empty. So the Add Gap dialog
(`gaps.cshtml`) no longer has a Priority field:

- **Severity** takes Priority's place in the form, is required and defaults to
  Medium (the old "-- default from priority --" option is gone).
- The payload still sends `priority` = the chosen severity, so
  `custom_gap.priority` stays in step for every reader that falls back to it
  (gap list / dashboards use `COALESCE(severity, priority)`).
- Gap Detail (`gap-detail.js`) and Gap View (`gap-view.js`) no longer show a
  Priority line; Severity is shown as before.

UI only. No API or database change (the API/procedure still accept priority).

## 491 -- Current State, Finding, Comments; Add Gap is a full page (2026-10-25)

**Fields (Add Custom Gap):**
- NEW **Current State / As-Is** -- `custom_gap.current_state` NVARCHAR(MAX).
- NEW **Gap Identified / Finding** -- `custom_gap.gap_finding` NVARCHAR(MAX).
- **Remarks** relabelled **Comments / Management Response** (same
  `custom_gap.remarks` column, same API name `remarks`).

**Full page:** the popup `#newCustomGapDialog` and its Map-a-practice dialog
moved out of `gaps.cshtml` into `Views/Practice/Partials/gap-new.cshtml`
(route `/Practice/Index/gap-new?orgId=&orgName=`), with their handlers --
nothing is left behind in `gaps.cshtml`. Add Gap navigates there for the
selected organization; Create and Cancel return to
`gaps?source=Custom&organizationId=`. Wiring: `PracticeScreen.cs` route
`gap-new`, `ScreenPermissionArea` -> `gaps`, `Manage.cshtml` workflowScreens.

**DB:** `database/491_custom_gap_current_state_finding.sql` -- the two columns;
`sp_custom_gap_open` (382 body) + `@current_state`, `@gap_finding`;
`sp_custom_gap_header` (367 body) + `CurrentState`, `GapFinding`, `Remarks`.
Rollback restores both bodies and drops the columns (their text is lost).

**API:**
- `POST /api/practice/gaps/custom` (browser `/practice/api/gaps/custom`) body
  gains optional `currentState`, `gapFinding` (`CustomGapOpenRequest`); bound
  only when `sp_custom_gap_open` declares them.
- Gap header (`GapHeader`, read by Gap View / Gap Detail) gains
  `currentState`, `gapFinding`, `remarks`.

**UI:** Gap View and Gap Detail show the three narrative fields under
Description (hidden when empty).

Deploy: 491, then API + Web.

## 495 -- Edit a Custom gap (2026-10-27)

A Custom gap can be edited on the Add Custom Gap page, in edit mode.

**Where:** **Edit** on the Gap Register row menu and on Gap View's Actions menu
(`Shared/gap-actions.js`, `buildMenu` + `onEdit`). It is offered for a Custom
gap only, the same scope as Close Gap. It is shown greyed out, with the reason,
when the gap can no longer be edited.

**When it can be edited** (`gracGapActions.editBlockedReason`; enforced by the
procedure):

| Rule | Error |
| --- | --- |
| status is Open, In Progress or Reopened | 55006 `NOT_EDITABLE_IN_STATUS` |
| lifecycle stage not terminal: not Analysed (Delegated), Closed, Invalid or Duplicate. No stage yet counts as New. | 55061 `NOT_EDITABLE_IN_LIFECYCLE` |
| a Custom gap | 55060 `NOT_CUSTOM_GAP` |
| at least one practice instance of the organisation | 55062 `PRACTICE_INSTANCE_REQUIRED` |
| title; the gap is in the caller's organisation | 55002 / 55004 / 55005 (as 112/324) |

Once analysed, the analysis owns severity and the downstream tasks, exceptions
and risks own the gap, so it is no longer edited here.

**Page:** `/Practice/Index/gap-edit?gapId=&orgId=[&orgName=][&from=view]`.
`gap-edit.cshtml` renders `gap-new.cshtml` with `Model.Key = gap-edit`.
- The heading reads "Edit Custom Gap" and the button "Save Changes".
- **Status** is not on the form: it moves through the lifecycle actions.
- The form is filled from `GET /practice/api/gap-lifecycle/gaps/{id}/header`
  and `GET /practice/api/gaps/custom/{id}/practices`. Owner is kept even when
  that employee is no longer in the active list.
- Save or Cancel returns to Gap View (`from=view`) or to the Gap Register.

Wiring:
- `PracticeScreen.cs`: route `gap-edit`.
- `ScreenPermissionArea`: `gap-edit` -> `gaps`.
- `Manage.cshtml`: `gap-edit` in workflowScreens.

**Database:** `495_custom_gap_edit.sql`, new `grac_practice.sp_custom_gap_edit`.
- It writes exactly the page's fields:
  - Title, Description, Current State, Finding, Comments (remarks).
  - Severity. `priority` is kept equal to it, as on Add.
  - Owner. A changed owner clears the owner role.
  - Due Date, Detection Method.
- The chosen practice instances replace the mapped set:
  - Mappings no longer chosen are set **Inactive**. Every reader filters on
    Active.
  - Mappings chosen again are set Active.
  - New ones are added by `sp_custom_gap_practice_instance_set` (388).
  - A pre-388 practice-level row with no instance is retired.
- One `custom_gap_history` row is written: `EDIT`, "Gap edited.".
- `sp_custom_gap_save`'s edit branch is not used: it overwrites reviewer,
  target date, remediation plan and owner role from its parameters, and has no
  narrative fields or instance mapping.
- Rollback: `495_custom_gap_edit_rollback.sql` drops the procedure.

**API:** `POST /api/practice/gaps/custom/{id}/edit` (browser:
`/practice/api/gaps/custom/{id}/edit`, through the Web tier's POST catch-all,
which checks `organizationId`).
- Body `CustomGapEditRequest`:
  `{ organizationId, title, description, currentState, gapFinding, remarks,
  severityCode, ownerEmployeeId, dueDate, detectionMethodCode,
  detectionMethodName, practiceInstanceIds[] }`
- Result: `200 { customGapId }` or `400 { error, reasonCode }`.
- The editor is the session caller (`X-PM-Caller-Employee-Id`), never a value
  in the body.
- After the save the SLA is re-matched (`ApplyAutoSlaAsync`), as after Add,
  because severity may have changed.

## Gap View shows every captured field (2026-10-27)

Gap View (`gap-view.cshtml` / `GapLifecycle/gap-view.js`) now shows every value
the Add / Edit Custom Gap page and the Analysis tab capture. UI only: no
database or API change.

- **Gap Details**: unchanged facts. Source, Detection Method, Practice
  Instance, Status, Severity, Owner, Due Date, Identified Date, SLA,
  Duplicate Of / Invalid Reason, Mapped Practices.
- **Gap Narrative** (new panel): Description, Current State / As-Is, Gap
  Identified / Finding, Comments / Management Response.
  - For a Custom gap all four are always listed; an empty one reads "Not
    recorded".
  - Other sources show only what they have.
  - These moved out of Gap Details.
- **Gap Analysis** (new panel): the saved analysis, read with the same
  `GET /practice/api/gap-lifecycle/gaps/{id}/analysis` call `gap-detail.js`
  makes.
  - Fields: Detection Method, Severity, Business Impact, Business Impact
    Summary, Regulatory Impact, Regulatory Impact Summary, RCA Required.
  - RCA Summary, Corrective Action and Preventive Action are always listed
    when RCA was required, otherwise only if they hold a value.
  - Decisions (Generate Task / Request Exception / Create Risk), Analysed On.
  - "This gap has not been analysed yet." when there is no analysis.
- The narrative needs migration 491 and its API: without them, the header
  carries no Current State / Finding / Comments and they read "Not
  recorded".
- Every text-area field takes a full row of its panel (`.gv-full`, `grid-column:
  1 / -1`): Description, Current State, Finding, Comments, the two impact
  summaries, RCA Summary, Corrective Action and Preventive Action. The short
  fields (codes, Yes/No, dates) keep the columns.
- Current State / As-Is and Gap Identified / Finding are captured only on the
  Add / Edit Custom Gap page, so only Custom gaps have them. Gaps raised from
  Implementation, Assurance, Exception, Risk or TPRM have no input for them,
  and Gap View does not list them for those gaps.

## 496 -- Practice Instance name + description on Gap Details and Gap View (2026-10-27)

The Gap Details page (`gap-detail`, Details tab) and Gap View (Gap Details
panel) list each **Practice Instance** the gap concerns:
- the instance name and code, as a link to the instance's read-only view page
  (`resolve-workspace?instanceId=&organizationId=&mode=view`, a new tab: the
  same destination as the existing "View Practice Instance" link);
- its **description** on the line beneath.

**Which instances.** The instance an Implementation gap was materialized
from (the gap header), plus the instances mapped to a Custom gap on the Add /
Edit page. The same instance is listed once. Shown as "None" when the gap names
none. This entry replaces "Mapped practices" (Gap Details) and "Mapped
Practices" / "Practice / Practice Instance" (Gap View).

**Description.** A practice instance has no description column of its own.
It shows its practice's description, `practice.description` (the Description
on the Practice form).

**Database:** `496_gap_practice_instance_description.sql` re-issues
`sp_custom_gap_header` (491 body) and `sp_custom_gap_practice_map_list` (388
body). Each gains a `PracticeInstanceDescription` column. Rollback
`496_..._rollback.sql` restores both bodies.

**API:** `GapHeader.practiceInstanceDescription` (`GET
/api/practice/gap-lifecycle/gaps/{id}/header`) and
`CustomGapPracticeRow.practiceInstanceDescription` (`GET
/api/practice/gaps/custom/{id}/practices`). Both are read only when the column
exists.

**UI:** new shared module `wwwroot/js/Shared/gap-practice-instances.js`
(`window.gracGapPracticeInstances.load / renderHtml / viewUrl`), used by
`gap-detail.js` and `gap-view.js`, so the list and its rules exist once. On
Gap View it takes a full row.
