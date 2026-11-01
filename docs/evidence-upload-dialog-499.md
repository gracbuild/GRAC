# Direct Upload opens the Evidence Center form (migration 499)

**Screens:** Operationalize (`resolve-workspace.cshtml`, one-time evidence) and
Complete Task (`_task-action-dialogs.cshtml` + `Shared/task-actions.js`,
recurring and general evidence). Follows `evidence-source-options-481.md`,
`task-recurring-evidence-482.md`, `evidence-center.md`.

## Request (sir, 2026-10-27)

The three evidence options (Direct Upload / Evidence Center Reference /
External Evidence Reference) stay as they are. But **Direct Upload was only a
file picker**. The file does reach the Evidence Center — and arrives there
with nothing filled in, so the same evidence has to be described a second time
on the Evidence Center screen.

Asked for: a button on Direct Upload that opens **the same Add evidence popup
the Evidence Center uses**, so all the details are captured in one place, on
both screens.

## Decisions (asked 2026-10-27)

- The plain file picker is **replaced** by the button, not kept beside it. One
  path, so metadata can never be skipped — which was the whole complaint.
- **Mandatory fields stay whatever the Evidence Center makes mandatory.**
  Today that is the file alone. Because all three screens now open one dialog,
  this holds by construction: make a field required in the dialog and it is
  required everywhere at once.
- The file is saved through **each screen's existing attachments endpoint**,
  not the Evidence Center's `/upload`. `/upload` requires the `ADD` grant on
  the Evidence Center menu, and routing Operationalize and Complete Task
  through it would have locked out every role that can operationalize or
  complete tasks without an Evidence Center grant. This cost a migration
  instead; the permission model is untouched.

## Why nothing needed inventing

`sp_evidence_item_store` (476) has always accepted the whole set:
`@evidence_title`, `@evidence_type_id`, `@evidence_description`,
`@owner_employee_id`, `@valid_from`, `@valid_to`, `@classification`, `@tags`.

Its two callers simply never passed them:

| Caller | What it passed before 499 |
| --- | --- |
| `sp_resolve_evidence_attachment_add` (476 body) | the evidence ROW's type, the uploader as owner, `'Internal'` hard-coded |
| `sp_task_attachment_add` (482 body) | no type at all, no title |

So the metadata was never collected and never handed over. Nothing was missing
from the store.

## Database — `499_evidence_upload_metadata.sql`

Re-issues both procedures with the same eight optional parameters, passed
through to `sp_evidence_item_store`. **`sp_evidence_item_store` is not
touched.**

Backward compatible both ways: an older Api that does not send them behaves
exactly as before (NULL → the pre-499 default), and the new Api binds them
only when the procedure declares them (`ProcParameterProbe`), so it works
against a database where 499 has not run.

**Not applied** on the "identical file is already in the Evidence Center"
branch of either procedure. That branch links an item somebody else created
and described; writing this upload's metadata over theirs would be editing
their record. The link is made, their description stands.

Normalisation, identical in both so one upload behaves the same from either
screen: an unknown type → NULL; an owner who is not an employee of this
organisation → the uploader; blank classification → `'Internal'`; blank
title/description/tags → NULL, never `''`. On the resolve side the dialog's
type **wins** over the evidence row's own; leaving it blank keeps the pre-499
inheritance.

On the task side the item's description parameter is `@evidence_detail`, not
`@evidence_description` — that name was already taken on that procedure by the
attachment's own note. The Api keeps them apart as `evidenceItemDescription`
and `evidenceDescription`.

## Api

- `EvidenceUploadMetadata` (new, `EvidenceCenterModels.cs`) — one record
  instead of eight more positional parameters on two already long signatures.
  `HasAny` lets the controllers send `null` when nothing was filled in.
- `ResolveWorkspaceController.UploadEvidenceAttachment` and
  `TaskController.UploadAttachment` take the fields `[FromForm]`.
- `AddEvidenceAttachmentAsync` / `AddAttachmentAsync` take
  `EvidenceUploadMetadata? metadata = null`, optional and last.
- **No Web-tier change.** The resolve proxy forwards the form through
  `ApiFileProxy.BuildMultipartAsync`; the task proxy copies every field.

## UI

| Object | Role |
| --- | --- |
| `Partials/_evidence-upload-dialog.cshtml` | the markup, moved verbatim out of `evidence-center.cshtml` (ids unchanged) |
| `Shared/evidence-upload.js` | `window.gracEvidenceUpload.open({...})` — fills the selects, applies the mode, validates, handles the duplicate banner |

Same arrangement as `_evidence-picker-dialog.cshtml` + `Shared/evidence-picker.js`:
**the host passes the submit call**, so the dialog knows nothing about
endpoints or permissions. The Evidence Center posts to its own `/upload`;
Operationalize and Complete Task post to their own attachments endpoints.

`fillSelect` is deliberately shape-tolerant — the three screens get their
lookups from three different feeds (`{evidenceTypeId, evidenceType}` from the
Evidence Center's `/lookups`, `{value, label}` from the gateway lookups
Operationalize already loads, and the organisation employees endpoint on the
task page). Normalising inside the dialog keeps that mapping out of all three
hosts.

`evidence-center.js` now **delegates** to the module and only decides what to
do with the outcome, so there is exactly one Upload evidence form in the
product — the same rule the Approve/Reject dialogs follow.

### What changed on the two screens

- The file input is gone; an **Upload evidence** button takes its place.
- The file is stored **when the dialog is submitted**, not when the obligation
  is saved or the task completed. Both save-time sweeps that used to attach a
  chosen-but-unattached file are therefore removed (`saveOneObligation`'s
  `pendingFiles` loop and the Complete Task `st.file` / `taskCompleteFile`
  handling).
- Evidence types are not loaded on the task screen, so that dropdown is
  offered empty there rather than wrong; every other field still reaches the
  Evidence Center.

## Deploy

499 → Api → Web, then a hard refresh. Order is not critical: the Api probes
for the parameters, and the procedures default them.

Rollback: `499_evidence_upload_metadata_rollback.sql` restores the 476/482
bodies. Items already created with metadata keep it.
