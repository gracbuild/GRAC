# Operationalize one-time evidence: attach on Save, cadence fix (475, 2026-10-18)

Follows `evidence-cadence-operationalize.md` (473). Superseded in part by
`evidence-center.md` (476): the file chosen on a one-time evidence row is now
stored in the Evidence Center and linked, and the row also offers "Select
from Evidence Center".

## One-time evidence is NOT mandatory
A rule was drafted and withdrawn the same day. It required one-time evidence
to be attached before an obligation could be saved as Implemented. One-time
evidence can be attached on Operationalize, but an obligation can be marked
Implemented without it.

What the draft added has been removed:
- the API check in `AdoptObligationsAsync`;
- the card-side check `oneTimeEvidenceBlock`;
- the procedure `sp_resolve_obligation_implementation_evidence_check`.

475 drops the procedure if a database already ran the draft.

## Attaching a file: the card's Save does it (UI, `resolve-workspace.cshtml`)
**Finding (DEMO):** a user chose a file and pressed **Save obligation**. The
file never reached the server. `_diag_one_time_evidence_attachments.sql`
showed evidence 10022 with 0 files, no attachment row and no audit row. Only
the separate **Attach file** button uploaded a file, and Save ignored the chosen
file without any message.

Now:
- `saveOneObligation` first uploads every file chosen in that card's one-time
  evidence pickers, then saves the obligation.
- A failed upload stops the save. The reason is shown under the picker.
- `uploadEvidenceFile` returns true / false.
- The **Attach file** button is removed. Under the picker the card says "The
  chosen file is attached when you save the obligation."
- Download and **Remove** of attached files are unchanged.

## Cadence view fix (`475_evidence_cadence_type_mapping_fix.sql`)
`vw_pm_instance_evidence_cadence` (473) re-issued:
- **Bug:** its by-type branch compared a GRAC_New evidence type id
  (`organization_obligation_evidence`) with a Practice Management one
  (`practice_instance_evidence`). They are two masters, so it matched nothing,
  or the wrong type when the ids coincided.
- **Fix:** it now maps by name (`GRAC_New.evidence_type_master` ->
  `evidence_type_master`), as `sp_resolve_evidence_list` does. Nothing else in
  the view changed.
- **Run order:** requires 473. Safe to re-run.
- **Rollback:** restores the 473 view.

## Diagnostics
`database/_diag_one_time_evidence_attachments.sql` (read-only, set
`@practice_instance_id`) shows:
- each evidence row with its cadence and Active file count;
- every attached file with a verdict;
- the attach / remove audit trail.

After deploying: run 475, restart the API, Ctrl+F5.
