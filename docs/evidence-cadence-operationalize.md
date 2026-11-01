# Evidence cadence on Operationalize (migration 473)

**Request (2026-10-18):** Control Management `077_evidence_cadence.sql` lets an
obligation's evidence be marked **Recurring** or **One-time**. Practice
Management now:

1. shows the cadence on every evidence row of the Operationalize card;
2. lets **one-time** evidence be attached (a file) on Operationalize, at implementation;
3. makes an attachment **mandatory on the scheduled task only for recurring** evidence;
4. lets the organisation edit the **obligation description** and the
   **evidence description** on Operationalize -- for that practice instance only.

**Migration:** `database/473_evidence_cadence_operationalize.sql`
(rollback `473_evidence_cadence_operationalize_rollback.sql`). Requires CM 077.
**API:** `Api/Models/ResolveWorkspaceModels.cs`, `Api/Services/ResolveWorkspaceService.cs`,
`Api/Controllers/ResolveWorkspaceController.cs`
**Web:** `Web/Controllers/WorkflowController.cs`, `Web/Services/ApiFileProxy.cs` (new),
`Web/Views/Practice/Partials/resolve-workspace.cshtml`

---

## 1. How the cadence reaches Practice Management

The organisation reads the obligation catalogue from its **copy** (391-395), not
live from `GRAC_New`. 473 re-runs 391's builders for the evidence step:

* `vw_repo_src_obligation_evidence` is rebuilt from the live table, so it now
  carries `evidence_cadence`;
* `sp_repo_clone_ensure_table` adds `evidence_cadence` to
  `organization_obligation_evidence`.

A new column changes every row's content hash, which would otherwise make the
change detector (395) raise a **Changed** approval for every evidence spec of
every organisation. So rows that were **in step** before the rebuild get the
cadence and the new hash in place. Rows that were already behind keep their old
hash and arrive through Repository Updates as before, cadence included. Until
then their cadence reads as **Recurring** (077's default).

`vw_pm_instance_evidence_cadence` gives the cadence of every
`practice_instance_evidence` row:

| Case | Cadence | `CadenceSource` |
|---|---|---|
| Published specs of this obligation + evidence type | **Recurring if any spec is recurring**, else One-time | `Published` |
| No type match, but the exact source spec is known | that spec's cadence | `Published` |
| Organisation-defined obligation (nothing published) | Recurring | `Default` |

The "any recurring wins" rule is needed because adoption creates one evidence
row per (obligation, evidence type) (304/400); it follows 077's reasoning that
the error should fall on the side of asking for proof.

## 2. Operationalize

| Where | What changed |
|---|---|
| Evidence row head (before and after adoption) | badge **Recurring** / **One-time** with a tooltip saying where it is attached |
| One-time evidence row (adopted) | **Attached at implementation**: file list (download, Remove) + file picker. The chosen file is uploaded by the card's **Save obligation** (since 2026-10-18; the separate **Attach file** button was removed -- see `evidence-attach-on-save-and-cadence-fix-475.md`). |
| One-time evidence, not adopted yet | note: the file is attached once the obligation is saved (the row is created by the save) |
| Recurring evidence row | note: attach it to each scheduled task when completing it |
| Obligation description (published obligations) | now a **Description** textarea. Shows the instance's text; "As published: ..." appears under it once they differ. Saved by the card's **Save obligation**. Saving the published text again, or emptying the box, returns to as published. |
| Evidence Description | opens on the **published** evidence description when the organisation has not written its own. "As published: ..." shows once they differ; saving the published text, or emptying the box, clears the organisation's text. |
| Evidence-type obligations, "As published" block | shows **Evidence cadence** (label); the raw code is hidden |

Organisation-defined obligations keep their read-only description (edited with
**Edit obligation**). View mode (`?mode=view`) keeps the download links and
hides attach / remove.

**Not changed:** an evidence row is still *resolved* only when Location **and**
Locator are filled (353) -- an attached file does not resolve it.
*Superseded by 481* (`evidence-source-options-481.md`): Operationalize lists
one-time evidence only, each row picks Direct Upload / Evidence Center
Reference / External Evidence Reference, and resolved follows the option.

## 3. Scheduled tasks

*Superseded by 482* (`task-recurring-evidence-482.md`): the gate below is
removed; Complete Task lists every recurring evidence row with the three
evidence options, and none is mandatory.

`sp_task_completion_eligibility` (194, re-issued) gains one rule after the
mandatory sub-task rule:

> A task with source **Schedule** (449) whose obligation has at least one
> **recurring** evidence row cannot be completed until **at least one file is
> attached to the task**.

The Complete Task dialog already shows the eligibility reason and already has
the attach control, so the user sees, for example:

    Attach the evidence for this occurrence before completing it
    (recurring evidence: Access review report, Policy).

`sp_task_complete` enforces it (it calls the eligibility procedure), so the rule
holds whatever screen completes the task. The result set is unchanged (seven
columns), so 200's `INSERT ... EXEC` is untouched.

By design: files are not matched to evidence types (Task Centre attachments
have no type), one-time evidence is never asked for on the task, **Close Task**
(close without completing) is not gated, and an occurrence of an instance-level
rule (no obligation) is not gated.

The obligation-description edit also reaches **new** scheduled tasks with no
change: 459 already describes a task with
`COALESCE(practice_instance_obligation.obligation_description, published text)`,
and 473 stores the edit in that column (an adopted row never used it before).
Tasks raised earlier keep their description.

## 4. Database objects

| Object | Kind | Notes |
|---|---|---|
| `organization_obligation_evidence.evidence_cadence` | column (copy) | added by the 391 builder |
| `practice_instance_evidence_attachment` | table | `task_attachment` shape + organisation / instance / evidence keys, soft remove (`status`, `removed_by`, `removed_dt`) |
| `vw_pm_instance_evidence_cadence` | view | see section 1 |
| `sp_resolve_obligation_list` | re-issued (457) | `ObligationDescription` = edit or published; **new** `PublishedObligationDescription`, `IsDescriptionOverridden`; `PublishedEvidenceJson` elements gain `EvidenceCadence`, `EvidenceCadenceLabel` |
| `sp_resolve_evidence_list` | re-issued (394) | **new** `EvidenceCadence`, `EvidenceCadenceLabel`, `EvidenceCadenceSource`, `AttachmentCount` |
| `sp_resolve_evidence_save` | re-issued (254) | **new** `@clear_evidence_description BIT = 0` |
| `sp_task_completion_eligibility` | re-issued (194) | recurring-evidence gate |
| `sp_resolve_obligation_description_save` | new | `@practice_instance_id`, `@payload_json` `[{obligationId, description}]`, `@actor`, `@saved OUTPUT` |
| `sp_resolve_evidence_attachment_add` / `_list` / `_get` / `_remove` | new | instance-scoped; add refuses recurring evidence (52764) |

Every description change and every attach / remove is written to
`practice_audit_trace` (`practice-instance-obligation` / `UPDATE_DESCRIPTION`,
`practice-instance-evidence-attachment` / `CREATE`, `REMOVE`).

Error numbers 52760-52772.

## 5. API

All under `/api/practice/workflow/resolve` (browser: `/practice/api/workflow/resolve`).

| Method | Route | Body / result |
|---|---|---|
| GET | `instances/{id}/obligations` | rows gain `publishedObligationDescription`, `isDescriptionOverridden` |
| POST | `obligations` | each `obligations[]` item accepts `obligationDescription` (null = untouched, `""` = back to published, text = stored) |
| GET | `instances/{id}/evidence` | rows gain `evidenceCadence`, `evidenceCadenceLabel`, `evidenceCadenceSource`, `attachmentCount` |
| POST | `evidence` | accepts `clearEvidenceDescription` (bound only when the database has 473) |
| GET | `instances/{id}/evidence-attachments?organizationId=` | `{ data: [{ evidenceAttachmentId, evidenceId, fileName, contentType, fileSizeBytes, attachmentDescription, uploadedByEmployeeId, uploadedByName, uploadedDt }] }` |
| POST | `instances/{id}/evidence/{evidenceId}/attachments?organizationId=` | multipart: `file`, optional `attachmentDescription`; 50 MB; 201 `{ evidenceAttachmentId }`. Uploader = session caller. |
| GET | `instances/{id}/evidence-attachments/{attachmentId}?organizationId=` | the file |
| POST | `evidence-attachments/remove` | `{ practiceInstanceId, organizationId, evidenceAttachmentId }` |

**Since 476** the attachments are Evidence Center links: the same routes and
contract, `evidenceAttachmentId` is the link id, the list gains the item /
version columns, remove unlinks (the file stays in the Evidence Center), and
three routes are added for "Select from Evidence Center". See
`evidence-center.md`.

The Web tier forwards the JSON routes through `WorkflowController`'s
catch-alls; the upload and the download have their own routes there (a file
cannot ride the string proxy) and use `Services/ApiFileProxy.cs`.

**Organisation check.** The catch-alls verify an `organizationId` when one is
sent; the screen always sends it on these four calls. The upload and download
routes **require** it, check it against the caller, and pass it on, and the
procedures then serve or change an attachment only when the instance belongs
to that organisation (`@organization_id`, NULL = no check for calls from SQL).

**Save with a description.** The obligation description is saved after the
adopt in the same request. If that save fails, the gap and schedule syncs
still run (the adopt is committed) and the request reports the description
error, so pressing Save again is enough. Text is compared with CRLF and LF
treated alike, so re-saving the published text is recognised as published.

Every new column is read defensively, so the API runs against a database
without 473 (no cadence shown, descriptions read-only, no attachments).

## 6. Deploy / rollback

1. Control Management `077_evidence_cadence.sql` (schema owner login).
2. `473_evidence_cadence_operationalize.sql` -- the end of the script lists, per
   organisation, how many copied specs are Recurring / One-time / not yet copied.
3. API + Web.

Rollback: `473_..._rollback.sql` restores the four procedure bodies, drops the
new procedures and the view, drops the attachment table only if empty, and (by
default) clears description edits on adopted obligations. The copy column stays
(it mirrors 077).

## Follow-ups (not in this change)

* Cadence for organisation-defined obligations' evidence (the shared obligation
  form has no cadence field; they are Recurring).
* Matching task attachments to individual recurring evidence types.
* The older inline multipart proxies (Task, Exception, Risk, Document Upload
  controllers) can move onto `ApiFileProxy`.

## 492 -- cadence for custom obligation evidence (2026-10-26)

Closes the first follow-up above. The shared obligation form
(`Shared/obligation-form.js`, used by Practice View for practice-level custom
obligations and by Operationalize for instance-level ones) now asks for each
evidence's **Cadence** -- Recurring (default) or One-time, the codes and
wording of Control Management's evidence-cadence options (077).

- **DB** `database/492_custom_obligation_evidence_cadence.sql`:
  `practice_instance_evidence.evidence_cadence` (CHECK Recurring / OneTime,
  NULL = not chosen); `sp_resolve_local_obligation_evidence_sync` (463 body)
  stores `evidenceCadence` from each evidence item (either key case; absent =
  keep); `vw_pm_instance_evidence_cadence` (475 body) reads it for evidence
  with nothing published -- `CadenceSource = 'Organization'`. Rollback restores
  both bodies and drops the column.
- **API**: `ResolveLocalEvidenceItem` (POST `.../workflow/resolve/local-obligation`)
  and `PracticeObligationEvidenceItem` (POST `/api/practice/practice-obligations`)
  gain optional `evidenceCadence`. `practice_obligation.evidence_json` stores it
  as sent; the fan-out carries it to every instance.
- **UI**: Cadence select on each evidence line (`_obligation-form-dialog.cshtml`
  CSS `.gof-evidence-cadence`); Practice View and Operationalize re-seed it when
  the form is reopened.

Effect: One-time custom evidence appears on Operationalize with the three
evidence options (481); Recurring custom evidence is listed on the scheduled
task's Complete page (482). Existing custom evidence stays Recurring until the
obligation is saved with another cadence.

## 494 -- cadence on Practice View (2026-10-27)

Practice View (Organization Practices -> View) shows the same **One-time** /
**Recurring** badge on every evidence of every obligation card.
`dbo.sp_pm_view_obligations_typed` adds `EvidenceCadence` /
`EvidenceCadenceLabel` to each published `EvidenceJson` element (the 473
enrichment of `sp_resolve_obligation_list`); practice-level custom obligations
use the cadence stored by 492. Details: `docs/practice-view-page.md`, section
"Evidence cadence".

## Descriptions read-only on Operationalize (2026-10-27)

Change request: the **obligation description** and the **evidence description**
on the Operationalize card are read-only again. This reverses point 4 of 473
on the screen only.

| Where | Now |
| --- | --- |
| Obligation description (published obligations) | plain text, no textarea. Shows `ObligationDescription`, the text the instance works to: an edit stored before this change, else the published text. When the two differ, "As published: ..." follows it. |
| Evidence description, adopted row | plain text under the evidence name, no Description box. Shows the stored description (473's box, or Edit obligation for an organisation-defined obligation), else the published one. "As published: ..." follows when they differ. |
| Evidence description, not adopted yet | the published description as a note; no box, so a draft carries no description. |
| Organisation-defined obligations | unchanged: their description and their evidence descriptions are still written with **Edit obligation**. |

**Saving.** The card's Save sends `obligationDescription: null` (untouched),
and every evidence save sends `evidenceDescription: null`,
`clearEvidenceDescription: false` (unchanged). So nothing stored is changed or
cleared by this: an earlier edit stays, and stays visible. The client helper
`evidenceDescriptionPayload` was removed (nothing calls it).

**No database or API change.** `sp_resolve_obligation_description_save`, the
`obligationDescription` item of `POST obligations` and
`evidenceDescription` / `clearEvidenceDescription` on `POST evidence` stay as
473 documented them (absent / null = unchanged); the screen simply no longer
sends a change. Tasks still describe themselves with
`COALESCE(practice_instance_obligation.obligation_description, published)`.

File: `Views/Practice/Partials/resolve-workspace.cshtml` (`description`, the
published-evidence and adopted-evidence row markup, `saveEvidence`, the
draft flush in `saveOneObligation`, `buildObligationPayloadRow`).
