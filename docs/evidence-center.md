# Evidence Center (migrations 476 / 477, Phases 1 and 2)

Plan: Claude Doc "Evidence Center - Architecture Plan" (agreed 2026-10-18).
Follows `evidence-cadence-operationalize.md` (473) and
`evidence-attach-on-save-and-cadence-fix-475.md` (475).

An evidence file is uploaded **once** into an organisation-level Evidence
Center. Every place that uses it holds only a **link**, pinned to the version
that was linked. Phase 1 covers Operationalize one-time evidence and the
Evidence Center screen. Task completion (recurring evidence) is Phase 2.

## Decisions (agreed 2026-10-18)

| Topic | Rule | Where it is enforced |
|---|---|---|
| Visibility | An item is visible to its uploader and owner, to users who can see an instance it is linked to (View Data Scope, 415/460), and to organisation admins. **Restricted** items: owner and admins only. | `fn_pm_evidence_item_visible` |
| Edit rights | Admin, owner, or the uploader of a non-Restricted item may edit details, upload a new version, retire / restore / delete. Users who see an item only through a linked instance may view and link it. | `fn_pm_evidence_item_editable` |
| Recurring tasks | Older evidence may be referenced only when its validity covers the occurrence period. **Phase 2** -- `evidence_link.period_from / period_to` are already there. | -- |
| Version pin | A link keeps the version it was made with. A newer version is offered as an update ("Use vN"). | `evidence_link.evidence_file_id`, `sp_evidence_link_refresh` |
| Phase 1 scope | Operationalize only, plus the Evidence Center screen and the migration of the 473 attachments. | -- |

"Admin" is the existing caller flag: session data scope GLOBAL or
ORGANIZATION (`X-PM-Caller-Is-Admin`, stamped by the Web tier).

"Can see a linked instance" reads `grac_practice.practice_instance` under the
View Data Scope row-level security policy. GETs carry the reader through the
request middleware. The two POSTs that test visibility (upload with the
identical-file check, link) set the reader themselves
(`CallerViewScope.BeginRead`).

## 1. Database (`476_evidence_center.sql`)

### Tables

| Table | What it holds |
|---|---|
| `evidence_item` | Organisation-level entry: title, evidence type (`grac_practice.evidence_type_master`), description, owner, valid from / to, classification (Internal / Confidential / Restricted), tags, status (Active / Retired / Deleted), creator. |
| `evidence_item_file` | The item's versions: `version_no`, `is_current` (one per item, filtered unique index), file name / type / size, `file_sha256`, the bytes, version note, uploader. |
| `evidence_link` | Item + **pinned** `evidence_file_id` + target. Phase 1 target: `target_type = 'InstanceEvidence'`, `target_id = practice_instance_evidence.evidence_id`, `practice_instance_id`. Also `link_note`, `period_from / period_to` (Phase 2), status (Active / Removed), who / when, `legacy_attachment_id` (the 473 row it came from). One active link of an item per target. |

### Migration of the 473 attachments

Every **active** `practice_instance_evidence_attachment` row becomes a link.
Identical files (SHA-256) in one organisation become **one** item. The item
takes the first upload's file name as its title, the evidence row's type, and
the uploader as owner (Internal). The 473 description becomes the link note.
The same file attached twice to one evidence row gives one active link (the
second is recorded as Removed by `migration-476`). The 473 table is **not**
changed or dropped. Re-running skips rows that are already migrated.

### Procedures

| Procedure | Purpose |
|---|---|
| `sp_evidence_center_list` | Grid: search (title, file name, tags), type, owner, validity (Valid incl. no expiry / Expiring within 30 days / Expired), used / not used, status (Active / Retired / All), paging, `TotalRows`, `UsedInCount`, `CanEdit`. |
| `sp_evidence_center_get` | Item (+ `UsedInCount`, `HiddenUsageCount`, `CanEdit`), versions (+ `PinnedLinkCount`), Used in (links on instances the caller can see). No row = not found or not visible. |
| `sp_evidence_center_file_get` | One version's bytes, only for a visible item. |
| `sp_evidence_center_upload` | New item, or the next version (`@evidence_item_id`). New item: when the identical file is the current version of an Active item the caller can see, it returns `Duplicate = 1` and that item, and stores nothing (unless `@allow_duplicate = 1`). New version: edit rights, Active item, not identical to the current version. |
| `sp_evidence_center_save` | Metadata (edit rights). |
| `sp_evidence_center_status` | Retire / Restore / Delete. Delete only when no active link exists (soft: status Deleted, bytes kept). |
| `sp_evidence_center_lookups` | Active evidence types, active employees of the organisation. |
| `sp_evidence_item_store` | Internal: stores a file as a new item or the next version. |
| `sp_evidence_link_candidates` | The picker list for one evidence row. Visible Active items with `Linkable` / `NotLinkableReason` (expired, already attached). |
| `sp_evidence_link_add` | Links an item to a one-time evidence row, pinned to the current version. Checks: the row is one-time and on this instance / organisation; the item is visible, Active, not expired, not already linked. |
| `sp_evidence_link_refresh` | Moves a link to the item's latest version. |

Re-issued over links, with the same names, parameters and columns (plus new
ones):

| Procedure | Change |
|---|---|
| `sp_resolve_evidence_attachment_add` | The file becomes an Evidence Center item (title = file name, the row's type, owner = uploader, Internal) linked here. When the uploader can already see an Active, unexpired item whose current version is the identical file, that item is linked instead (`Reused = 1`). New optional `@caller_is_admin`. Returns `EvidenceAttachmentId` (= link id), `EvidenceItemId`, `Reused`, `Message`. |
| `sp_resolve_evidence_attachment_list` | Reads links. File columns = the pinned version. New: `EvidenceItemId`, `EvidenceTitle`, `EvidenceItemStatus`, `VersionNo`, `CurrentVersionNo`, `NewerVersionAvailable`, `ValidTo`, `ValidityState`, `LinkedByName`, `LinkedDt`. |
| `sp_resolve_evidence_attachment_get` | The pinned version of a link. |
| `sp_resolve_evidence_attachment_remove` | **Unlink**. The item and its files stay in the Evidence Center. |
| `sp_resolve_evidence_list` | `AttachmentCount` counts active links (473 body otherwise unchanged). |

Every change writes `practice_audit_trace` (`evidence-item`, `evidence-item-file`,
`evidence-link`; actions CREATE, UPDATE, RETIRE, RESTORE, DELETE, REFRESH,
REMOVE, MIGRATE).

Error numbers 52780-52796 and 52850-52858 are user-facing sentences. 52760-52767
(473) keep their texts.

### Menu

`evidence-center` ("Evidence Center", `Practice/Index/evidence-center`,
display order 15, icon `box-archive`) under `nav-documents` (Policies &
Documents). Full permissions for every active role of every active
organisation, the 458 way. The procedures still decide which items a user sees
and may change. Narrow the menu in Role Menu Permissions if wanted.
`274_menu_master_seed.sql` carries the row (Section 1) and its parent link
(Section 2).

## 2. API

### Evidence Center -- `/api/practice/evidence-center` (browser: `/practice/api/evidence-center`)

Caller = `X-PM-Caller-Employee-Id` / `X-PM-Caller-Is-Admin`, stamped by the Web
tier from the session. Rows are column-name objects (the procedure columns).

| Method | Route | Web permission | Body / result |
|---|---|---|---|
| GET | `?organizationId&search&evidenceTypeId&ownerEmployeeId&validity&usage&status&pageNumber&pageSize` | VIEW | `{ data: [row], totalRows, page, pageSize, isAdmin }` |
| GET | `lookups?organizationId` | VIEW | `{ evidenceTypes: [{EvidenceTypeId, EvidenceType}], employees: [{EmployeeId, EmployeeName, EmployeeCode}] }` |
| GET | `{id}?organizationId` | VIEW | `{ item, versions: [...], usedIn: [...] }`; 404 when not found or not visible |
| GET | `files/{fileId}?organizationId` | VIEW | the file; 404 when not visible |
| POST | `upload?organizationId` | ADD (new item) / EDIT (`evidenceItemId` = new version) | multipart: `file`, optional `evidenceItemId`, `versionNote`, `evidenceTitle`, `evidenceTypeId`, `evidenceDescription`, `ownerEmployeeId`, `validFrom`, `validTo`, `classification`, `tags`, `allowDuplicate`. 50 MB. 201 `{ evidenceItemId, evidenceFileId, versionNo, message }`; **409** `{ duplicate: true, duplicateItemId, duplicateTitle, duplicateVersionNo, error }` |
| POST | `{id}/save` | EDIT | `{ organizationId, evidenceTitle, evidenceTypeId, evidenceDescription, ownerEmployeeId, validFrom, validTo, classification, tags }` |
| POST | `{id}/status` | EDIT (Retire / Restore), DELETE (Delete) | `{ organizationId, action }` |

Web: `Controllers/EvidenceCenterController.cs` (session guard, organisation
check, permission on the `evidence-center` screen, caller stamping;
`ApiFileProxy` for upload and download). Api:
`Controllers/EvidenceCenterController.cs`, `Services/EvidenceCenterService.cs`,
`Models/EvidenceCenterModels.cs`, registered by
`AddPracticeEvidenceCenterService()`.

### Operationalize -- `/api/practice/workflow/resolve` (browser: `/practice/api/workflow/resolve`)

| Method | Route | Body / result |
|---|---|---|
| GET | `instances/{id}/evidence/{evidenceId}/evidence-center?organizationId&search&evidenceTypeId&pageNumber&pageSize` | `{ data: [candidate], totalRows }` |
| POST | `evidence-links` | `{ practiceInstanceId, organizationId, evidenceId, evidenceItemId, linkNote? }` -> `{ evidenceAttachmentId, message }` |
| POST | `evidence-links/refresh` | `{ practiceInstanceId, organizationId, evidenceAttachmentId }` -> `{ message }` |
| GET | `instances/{id}/evidence-attachments?organizationId` | rows gain the 476 columns above |
| POST | `instances/{id}/evidence/{evidenceId}/attachments` | unchanged contract; `message` now says whether the file was stored or the identical one linked |
| POST | `evidence-attachments/remove` | unchanged contract; now unlinks |

These ride the existing `WorkflowController` catch-alls (organisation check on
the query / body); upload and download keep their own routes.

The API stays deployable before the database: `@caller_is_admin` is bound only
when the procedure declares it, and the new attachment columns are read only
when present.

## 3. UI

### Evidence Center screen (`Partials/evidence-center.cshtml`, `js/EvidenceCenter/evidence-center.js`)
Policies & Documents -> Evidence Center. Same layout as the Asset & Contract
screens: organisation picker, filters (search, type, owner, validity, used in,
status), grid with the `pm-grid` pager.

- **Upload evidence** (ADD): file + title, type, owner (default: me), valid
  from / to, classification, tags, description. If the identical file is
  already there, the dialog offers **Open existing** or **Upload as a separate
  item**.
- Row -> detail: summary, **Used in** (practice, instance with a link to
  Operationalize, evidence row, pinned version, "older" when a newer version
  exists, who / when; a note counts usages outside the caller's view) and
  **Versions** (download any version, how many links pin it).
- **Edit details**, **New version**, **Retire / Restore**, **Delete** (only
  when unused) -- shown when the screen permission and the item's own edit
  right allow it.

### Shared picker (`Partials/_evidence-picker-dialog.cshtml`, `js/Shared/evidence-picker.js`)
`window.gracEvidencePicker.open({ context, typeId, typeName, load, link })`.
The evidence row's type is the default filter ("Only <type>"). Rows show
validity, latest version and how many places use the item. An item that cannot
be linked says why. The host supplies the list and link calls, so Phase 2 (Task
completion) reuses the same dialog.

### Operationalize (`resolve-workspace.cshtml`)
On a one-time evidence row:
- **Select from Evidence Center** opens the picker and links the chosen item.
- Choosing a file and saving the obligation stores it in the Evidence Center
  (or links the identical file already there); the message under the picker
  says which.
- Each file shows its version. **Use vN** appears when a newer version exists.
  An expired item shows a badge.
- **Remove** unlinks. The file stays in the Evidence Center.
- **481:** the row first asks how the evidence is provided (Direct Upload /
  Evidence Center Reference / External Evidence Reference) and shows only
  that option's control -- see `evidence-source-options-481.md`.

## 4. Deploy / rollback

1. `476_evidence_center.sql` (after 473 and 475). The end lists items / files /
   active links per organisation and PASS / FAIL checks.
2. API + Web.

Rollback: `476_evidence_center_rollback.sql`:
- copies files linked after 476 back into the 473 table and marks 473 rows
  unlinked after 476 as Removed;
- restores the 473 procedure bodies;
- drops the new procedures and functions;
- removes the menu row and its permissions.

The three tables are dropped only when every item came from the migration.
Also remove the `evidence-center` rows from `274_menu_master_seed.sql`.

`_diag_one_time_evidence_attachments.sql` still reads the 473 table. After 476,
attachments are in `evidence_link` / `evidence_item_file`.

## Phase 2 -- tasks, validity rule, expiry notices (`477_evidence_center_tasks.sql`)

### Rules
- **Evidence on a task is an Evidence Center link.** A file attached to a task
  (Add Evidence, or Attach in Complete Task) is stored as an item (title = file
  name, owner = uploader, Internal) and linked to the task. When the uploader
  can already see an Active item whose current version is the identical file
  and whose validity covers the task's period, that item is linked instead.
- **Select from Evidence Center** on both task dialogs links an existing item,
  pinned to its current version.
- **Validity versus period (agreed):** the task's period date is the
  occurrence date of a scheduled occurrence task (449), otherwise today. An
  item may be linked only when `valid_from <= period <= valid_to` (an open end
  counts as covering). The picker lists the others with the reason and no Link
  button; the link procedure refuses them as well.
- **A task keeps the version it was linked with.** Task links are never moved
  to a newer version (a task completed for a period keeps that file). The
  Evidence Center shows them as "older" for information only.
- Task evidence stays append-only: there is no remove (as before).
- The recurring-evidence completion gate (473) counts the task's links.
  *Removed by 482* (`task-recurring-evidence-482.md`): recurring evidence is
  listed per row on Complete Task and is optional.

### Database
- `evidence_link.target_type` takes `Task` (target_id = task_id,
  practice_instance_id = the task's linked instance, period_from / period_to =
  the period date); new column `legacy_task_attachment_id`.
- `fn_pm_task_evidence_period(@task_id)` -- the period date.
- `fn_pm_evidence_item_visible` re-issued: an item is also visible through a
  task the caller can see (`practice_task` is under View Data Scope).
- Every `task_attachment` row is migrated: one item per distinct file per
  organisation (reusing a 476 item with the identical current file), one link
  per attachment. `task_attachment` is not changed or dropped.
- New: `sp_task_evidence_candidates`, `sp_task_evidence_link_add`.
- Re-issued, same contracts: `sp_task_attachment_add` (new optional
  `@caller_is_admin`; returns `TaskAttachmentId` = link id, `EvidenceItemId`,
  `Reused`, `Message`), `sp_task_attachment_get` (the pinned version),
  `sp_task_get` (result 3 reads links; adds `EvidenceItemId`, `EvidenceTitle`,
  `VersionNo`, `PeriodDate`, `FileUploadedDt`), `sp_task_completion_eligibility`
  (counts links), `sp_evidence_center_get` (Used in lists tasks: `TaskId`,
  `TaskNumber`, `TaskTitle`, `PeriodDate`).
- Expiry notices: table `evidence_expiry_notice` (item, recipient, Expiring /
  Expired, valid-to date, raised, read; unique per item + recipient + notice +
  valid-to). `sp_evidence_expiry_sweep(@organization_id, @days = 30)` raises
  them for Active items -- Expiring when valid-to is within 30 days, Expired
  when it ended within the last 30 days -- to the owner and the uploader.
  `sp_evidence_expiry_notice_list` / `_mark` serve My Notifications.
- Errors 52860-52866.

### API
Task Centre -- `/api/practice/tasks` (browser: `/practice/api/tasks`):

| Method | Route | Body / result |
|---|---|---|
| GET | `{id}/evidence-center?organizationId&search&evidenceTypeId&pageNumber&pageSize` | `{ data: [candidate (+ PeriodDate, Linkable, NotLinkableReason)], totalRows }` |
| POST | `{id}/evidence-links` | `{ organizationId, evidenceItemId, linkNote? }` -> `{ taskAttachmentId, message }` |
| POST | `{id}/attachments` | unchanged multipart contract; now also returns `message` |
| GET | `{id}` | `attachments[]` gain `evidenceItemId`, `evidenceTitle`, `versionNo`, `periodDate` |

The Web proxy requires `organizationId` on both new routes and checks it
against the session; the procedures check the task belongs to it. The upload
and both new routes stamp the admin flag (`CallerIdentityHandler.StampAdminFlag`,
the one shared rule, also used by the Evidence Center proxy).

Evidence Center -- `/api/practice/evidence-center`:

| Method | Route | Body / result |
|---|---|---|
| GET | `notices/me?organizationId&status&pageNumber&pageSize` | `{ data: [notice], totalRows, unreadCount }` (status Unread / Read / All) |
| POST | `notices/me/mark` | `{ organizationId?, evidenceNoticeId? }` (no id = all) -> `{ markedCount }` |

Session only (no screen permission): the recipient is the stamped caller.

Worker: `TaskNotificationWorker` runs `sp_evidence_expiry_sweep` every
`TaskNotification:EvidenceExpiryIntervalMinutes` (60) with
`EvidenceExpiryDays` (30). `EvidenceExpiryEnabled=false` leaves it to SQL Agent:
`EXEC grac_practice.sp_evidence_expiry_sweep;`

### UI
- **Complete Task** and **Add Evidence** dialogs (`_task-action-dialogs.cshtml`,
  `Shared/task-actions.js`): **Select from Evidence Center** opens the shared
  picker for the task. The upload message says whether the file was stored or
  the identical one linked. Evidence rows show the version and the period.
  Task View shows the same.
- **Evidence Center -> Used in** lists tasks (link to Task View, period).
- **My Notifications** has a third section, **Evidence Center notices**
  (`js/EvidenceCenter/evidence-my-notifications.js`): Expiring / Expired,
  why you (owner / uploader), valid to, mark read / mark all read; the title
  opens the item in the Evidence Center (in its organisation).

### Deploy / rollback
1. `477_evidence_center_tasks.sql` after 476. It ends with PASS / FAIL checks,
   links per organisation and target, and a first expiry sweep.
2. API + Web.

Rollback `477_evidence_center_tasks_rollback.sql`: copies task evidence linked
after 477 back into `task_attachment`, restores the 193 / 195 / 473 / 476
bodies, drops the new procedures, function and notice table, removes task
links and the items the 477 migration created, drops
`legacy_task_attachment_id` and restores the 476 target check.

## Not yet (Phase 3)

- Exception, Risk and Asset contract attachments; referencing Document Upload
  policies; moving file storage out of the database.

## Update 530 -- Evidence Automation feeds the Evidence Center

Migration 530 (`evidence-automation.md`) lets an organization's own systems send
evidence for an obligation (webhook or file drop). Each file received is stored
through the unchanged `sp_evidence_item_store` as an ordinary item (tag
`automated`, owner = the source owner, validity = the evidence period) and waits
for review on Policies & Documents -> Evidence Automation. Accepting it links it
through the unchanged `sp_evidence_link_add` / `sp_task_evidence_link_add`, so
Used in, version pinning, the completion gate and the expiry sweep treat it like
any other item. No Evidence Center table, procedure or screen was changed.
