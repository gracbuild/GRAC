# Complete Task: recurring evidence with the three evidence options (482)

Change request 2026-10-23 (sir). Follows `evidence-source-options-481.md`
(481 took recurring evidence off Operationalize), `evidence-center.md` (477)
and `scheduled-obligation-tasks.md` (449).

## What changed for the user

**Task Centre / Task View -> Complete task** on a task raised for a scheduled
occurrence (source `Schedule`):

- A new section, **Recurring evidence for this occurrence**, lists every
  recurring evidence row of the task's obligation (all of them, one block
  each: name, type, obligation, description).
- Each row asks how the evidence is provided and shows only that control:

  | Option | Control | Saved |
  |---|---|---|
  | **Direct Upload** (default) | file picker | uploaded when **Complete task** is pressed; stored in the Evidence Center and linked to the task **for that evidence row** |
  | **Evidence Center Reference** | **Select from Evidence Center** (the shared picker, filtered to the row's type, validity checked against the task's period) | linked at once, for that row |
  | **External Evidence Reference** | **Location** and **Locator** | recorded when **Complete task** is pressed |

  Files linked to a row are listed under it (version, period, download).
  The dialog's own **Evidence** list becomes **Other evidence** and keeps the
  general task evidence (Attach / Select from Evidence Center, as before).
- **Nothing is mandatory.** The 473 gate ("Attach the evidence for this
  occurrence before completing it") is removed: a scheduled task completes
  with or without recurring evidence.
- A task with no recurring evidence (any non-scheduled task) looks as before.
- If an upload or the save fails, the task is **not** completed and the
  reason is shown.

## Database -- `database/482_task_recurring_evidence.sql`

| Object | Change |
|---|---|
| `evidence_link.instance_evidence_id` | new, FK `practice_instance_evidence`; which recurring evidence row a task link answers. NULL = general task evidence |
| `practice_task_evidence_response` | new: `task_id`, `evidence_id` (unique together), `evidence_source` (DirectUpload / EvidenceCenter / External), `evidence_location`, `evidence_locator`, who / when |
| `fn_pm_task_recurring_evidence(@task_id)` | new inline TVF: occurrence -> instance obligation -> its Recurring evidence rows (the join 473's gate used) |
| `sp_task_recurring_evidence_list(@task_id, @organization_id)` | new: EvidenceId, EvidenceName, EvidenceTypeId, EvidenceType, EvidenceDescription, ObligationName, EvidenceSource, EvidenceLocation, EvidenceLocator, FileCount, IsProvided |
| `sp_task_evidence_response_save(@task_id, @organization_id, @payload_json, @caller_employee_id, @caller_display_name)` | new: MERGE per row; location / locator written only for External; refuses a completed task; audit `task-evidence-response` |
| `sp_task_attachment_add` | re-issued (477 body) + `@instance_evidence_id`; an identical file already on the task is assigned to the row when it answered none |
| `sp_task_evidence_link_add` | re-issued (477 body) + `@instance_evidence_id` |
| `sp_task_get` | re-issued (477 body); result 3 + `InstanceEvidenceId` |
| `sp_task_completion_eligibility` | re-issued (477 body) with the recurring-evidence gate removed; result set unchanged |

Errors 52921-52926. Rollback `482_task_recurring_evidence_rollback.sql`
restores the four 477 bodies (the gate returns), drops the new procedures and
function, drops the response table only when empty, and drops the column.

Note: one Evidence Center item can be linked once per task
(`ux_pm_evidence_link_active`), so the same file cannot answer two rows of
one task -- the second upload reports "already attached".

## API -- `/api/practice/tasks` (browser: `/practice/api/tasks`)

| Method | Route | Body / result |
|---|---|---|
| GET | `{id}/recurring-evidence?organizationId=` | `{ data: [row] }` (column-name rows above; empty for a task with none, or a database without 482) |
| POST | `{id}/recurring-evidence` | `{ organizationId, items: [{ evidenceId, evidenceSource, evidenceLocation?, evidenceLocator? }] }` -> `{ success, message }` |
| POST | `{id}/attachments` | multipart gains optional `instanceEvidenceId` |
| POST | `{id}/evidence-links` | body gains optional `instanceEvidenceId` |
| GET | `{id}` | `attachments[]` gain `instanceEvidenceId` |

`instanceEvidenceId` is bound only when the procedure declares it, so the API
still runs against a database without 482. The Web proxy requires
`organizationId` on both new routes and checks it against the session
(`ForwardOrgScopedGetAsync` / `ForwardOrgScopedPostAsync`, now also used by
the two 477 routes).

Files: Api `Models/TaskModels.cs` (`TaskAttachmentRow.InstanceEvidenceId`,
`TaskEvidenceLinkRequest.InstanceEvidenceId`, `TaskRecurringEvidence*`),
`Services/TaskService.cs`, `Controllers/TaskController.cs`; Web
`Controllers/TaskController.cs`.

## UI

- `wwwroot/js/Shared/evidence-source.js` (new, `window.gracEvidenceSource`):
  the three options, their radios and the show-one-panel rule -- moved out of
  `resolve-workspace.cshtml` (481), which now uses it too.
- `Partials/_task-action-dialogs.cshtml`: the new section, the label id, two
  scoped CSS rules, the script include.
- `Shared/task-actions.js`: `loadCompleteRecurring`, `renderCompleteRecurring`,
  `pickRecurringFromEvidenceCenter`, `saveCompleteRecurring` (called first by
  `submitCompleteTask`); `postEvidence` and `pickFromEvidenceCenter` take the
  evidence row.

## Deploy

1. `482_task_recurring_evidence.sql` (after 481). It ends with PASS / FAIL
   checks and the open scheduled tasks per organisation that now list
   recurring evidence.
2. API + Web. Hard refresh.

## Update 483 -- the three options for "Other evidence" too

Change request 2026-10-23 (sir). The dialog's general evidence section
("Other evidence", or "Evidence" when the task has no recurring evidence)
also asks how the evidence is provided and shows only that control:

| Option | Control | Saved |
|---|---|---|
| Direct Upload (default) | file picker + **Attach** | immediately, as before (general task link) |
| Evidence Center Reference | **Select from Evidence Center** | immediately, as before |
| External Evidence Reference | **Location** + **Locator** | when **Complete task** is pressed |

`database/483_task_general_evidence_options.sql`:
- `practice_task_evidence_response.evidence_id` is NULLable; NULL = the task's
  general evidence. `uq_pm_task_evidence_response (task_id, evidence_id)` is
  re-created, so a task has at most one general row.
- `sp_task_evidence_response_save` (482 body): an item with no `evidenceId`
  is the general row (not checked against the recurring list).
- `sp_task_recurring_evidence_list` (482 body): + result 2, the general row
  (`EvidenceSource`, `EvidenceLocation`, `EvidenceLocator`).
- Rollback restores the 482 bodies, deletes the general rows and makes the
  column NOT NULL again.

API: GET `{id}/recurring-evidence` returns `{ data, general }` (`general` null
when nothing is recorded); POST `{id}/recurring-evidence` accepts an item with
`evidenceId: null`. Models: `TaskRecurringEvidenceItem.EvidenceId` is `long?`,
`TaskRecurringEvidenceResult.General`.

UI: `_task-action-dialogs.cshtml` wraps the existing controls in option
panels (`#taskCompleteGeneral`); `task-actions.js` adds `generalState` /
`renderCompleteGeneral` and sends the general item from `saveCompleteRecurring`.

Deploy: 483 after 482, then API + Web, hard refresh.

## Update 2026-10-23 -- Complete Task is a full page

The Complete dialog, with its recurring evidence list, outgrew a modal.

- Route `/Practice/Index/task-complete?taskId=NNN[&from=view]`
  (`Views/Practice/Partials/task-complete.cshtml`). It is the SAME Complete
  surface rendered inline, the `task-edit.cshtml` pattern:
  `gracTaskActions.openComplete(taskId, null, null, { host: "page", backUrl })`.
- `task-actions.js`: page mode now hosts either the view/edit dialog or the
  Complete dialog (`pageDialogId`); Cancel and a successful completion
  navigate back. On the page the subject is read from the task.
- Task Board row menu and Task View's Complete action navigate to the page
  (from Task View it returns to Task View).
- Wiring: `PracticeScreen.cs` route screen `task-complete`;
  `PracticeController.ScreenPermissionArea` maps it to `tasks`;
  `Manage.cshtml` dispatches `task-complete` -- and now also `task-new` and
  `task-edit`, which were missing from that list (their partials existed but
  the route fell through to the generic grid).
- No database or API change.

## Update 2026-10-23 -- no Attach button on "Other evidence"

For consistency with the recurring rows, the general Direct Upload has no
**Attach** button any more: the chosen file is attached (as general task
evidence) when **Complete task** is pressed, in `saveCompleteRecurring`.
`attachFromCompleteDialog` and the `#taskCompleteAttach` button are removed.
Select from Evidence Center still links at once. The **Add evidence** dialog
(row menu) is unchanged and still attaches immediately.
