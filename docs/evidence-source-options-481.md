# Operationalize: one-time evidence only, three evidence options (481)

Change request 2026-10-23 (sir). Follows `evidence-cadence-operationalize.md`
(473), `evidence-attach-on-save-and-cadence-fix-475.md` and
`evidence-center.md` (476 / 477).

## What changed for the user

On **Operationalize -> obligation card -> Evidence**:

1. **Only one-time evidence is listed.** Recurring evidence is attached to each
   scheduled task when it is completed (473), so it is no longer shown here.
   An obligation whose evidence is all recurring says so in one line. The card
   head ("1 / 2 evidence") and the "x / y resolved" badge count one-time
   evidence only. Organisation-defined obligations' evidence is treated as
   recurring (473 `Default`), so it is not listed either.
2. **Each one-time evidence row offers three options** (radio buttons, under the
   Evidence name and Description):

   | Option | Control shown below | Resolved when |
   |---|---|---|
   | **Direct Upload** (default) | file picker -- the file is stored on **Save obligation** | an active Evidence Center link exists |
   | **Evidence Center Reference** | **Select from Evidence Center** | an active Evidence Center link exists |
   | **External Evidence Reference** | **Location** and **Locator** | both are filled |

   The list of attached / linked files (version, Use vN, Remove) shows under the
   first two options. Switching option only hides the other controls; nothing
   already entered or linked is deleted, and only the chosen option counts.
3. **Before the obligation is adopted** the same options are shown on the
   pre-adoption rows. External fields are saved with the obligation; a file can
   be attached or selected once the save has created the evidence row.

View mode (`?mode=view`) shows the stored option, disabled, with the download
links.

## Decisions (2026-10-23)

- Recurring evidence: hidden entirely on Operationalize (rows are kept).
- Resolved rule: per option (table above). A row with no option stored yet
  (older data) is resolved by either a link or location + locator.

## Database -- `database/481_evidence_source_options.sql`

| Object | Change |
|---|---|
| `practice_instance_evidence.evidence_source` | new `NVARCHAR(30) NULL`, check `ck_pm_instance_evidence_source`: `DirectUpload` / `EvidenceCenter` / `External`; NULL = not chosen |
| Backfill | active link -> `DirectUpload`; else location or locator present -> `External`; else NULL (only rows still NULL, so re-runs change nothing) |
| `fn_pm_instance_evidence_is_resolved(@source, @location, @locator, @evidence_id)` | new -- the one place the resolved rule lives |
| `sp_resolve_evidence_list` | re-issued (476 body): `IsResolved` via the function; new column `EvidenceSource` |
| `sp_resolve_evidence_save` | re-issued (473 body): new `@evidence_source NVARCHAR(30) = NULL` (NULL = unchanged; anything else -> **52920**); `IsResolved` / `ResolvedOnInstance` via the function; new result column `EvidenceSource`; a row with an active link is no longer reset to "Inherited" when its text boxes are blank |

Not changed: `sp_resolve_obligation_list.ResolvedEvidenceCount` (353 rule; the
screen no longer reads it), Evidence Center procedures, task evidence.

Rollback `481_evidence_source_options_rollback.sql`: restores the 476 / 473
bodies verbatim, drops the function, the check and the column (the chosen
options are lost; location, locator and links stay).

## API -- `/api/practice/workflow/resolve` (browser: `/practice/api/workflow/resolve`)

| Method | Route | Change |
|---|---|---|
| GET | `instances/{id}/evidence` | rows gain `evidenceSource` (`DirectUpload` / `EvidenceCenter` / `External` / null); `isResolved` follows the option |
| POST | `evidence` | body accepts `evidenceSource` (null / absent = unchanged). Bound only when the procedure declares `@evidence_source`, so the API runs against a database without 481. The "not resolved yet" message names what is missing for the chosen option. |

Files: `Api/Models/ResolveWorkspaceModels.cs` (`ResolveEvidenceRow.EvidenceSource`,
`ResolveEvidenceSaveRequest.EvidenceSource`, both optional and last),
`Api/Services/ResolveWorkspaceService.cs` (`ListEvidenceAsync`, `SaveEvidenceAsync`).
The Web tier forwards through `WorkflowController`'s catch-all -- no change.

## UI -- `Web/Views/Practice/Partials/resolve-workspace.cshtml`

- 482 moved the option list, radios and panel toggle to
  `wwwroot/js/Shared/evidence-source.js` (`window.gracEvidenceSource`), shared
  with Complete Task; the names below are now thin aliases.
- Helpers: `isOneTimeCadence`, `EVIDENCE_SOURCES`, `evidenceSourceOf`,
  `evidenceSourceRadios`, `sourcePanel` / `showSourcePanels`, `evidenceRowsOf`
  (the obligation -> rows match, now shared by the card head and the evidence
  block), `oneTimeEvidenceSummary`.
- Radios use the shared `.radio-group` / `.radio-option` styles
  (`cacca-styles.css`); one scoped rule lets them wrap.
- An unsaved choice on a saved row is kept in `evidenceSourceChoice` across
  redraws; `saveEvidence` sends the ticked option. Drafts buffer it with the
  same helper as their text boxes (`bufferEvidenceDraft`).
- **Save obligation** uploads only files chosen in a visible Direct Upload
  picker.

## Deploy

1. `481_evidence_source_options.sql` (after 476 / 477 / 480). It ends with
   PASS / FAIL checks and a per-organisation count of options and resolved rows.
2. API + Web. Hard refresh.
