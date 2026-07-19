ISO Controls Import to GRAC v1.0 -- Generated Scripts
=====================================================

Source: uploads/ISO Controls Import to GRAC v1.0.xlsx
Rows:   93 controls (structure_node_ids 3, 4, 5, 6) + 1115 practices

Fill in these parameters at the top of each script before running:
    @release_id       = grac_new.release row id for the ISO release
    @organization_id  = grac_practice.organization row id (Phase 4 + 5 only)

Run order (repository side, one-time):
    01_cleanup_repository_iso.sql           -- Phase 1
    02_insert_repository_controls.sql       -- Phase 2
    03_insert_repository_practices.sql      -- Phase 3

Run order (per organization, repeat for each subscribed org):
    04_cleanup_organization_iso.sql         -- Phase 4
    05_import_organization_controls.sql     -- Phase 5

All scripts are idempotent (WHERE NOT EXISTS guards + status filters) and
wrap DML in BEGIN TRAN / COMMIT with SET XACT_ABORT ON.

Practice code convention: {control_code}.{seq}, e.g. 5.1.1, 5.1.2, ...
generated in Excel row order within each control. This becomes
grac_new.requirement.requirement_code.

Notes:
- Phase 5 sets applicability_status = 'Not Updated' (matching what
  grac_practice.sp_sync_organization_controls_from_subscriptions does).
- Phase 5 does NOT create organization_requirement rows (Practices).
  Those get created when the user runs Mark Applicability on a Control,
  which triggers the existing SP that seeds Practices from the mapped
  requirements.
- Excel columns Assurance Frequency, Obligation Frequency, Assurance
  Subject / Type / Location, Evidence, Control Statement are per
  Practice-Instance attributes at the organization tier, not repo-tier
  requirement columns. They are not persisted by these scripts.
