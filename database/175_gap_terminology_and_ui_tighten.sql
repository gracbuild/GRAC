-- =====================================================================
-- 175 Gap terminology + UI-strip tightening
--
-- SIR'S UX FEEDBACK (from gap-detail screenshot):
--   1. Stepper showed the current state twice (once as a standalone chip,
--      once as the first pill). Fixed in view/JS -- no schema change.
--   2. "Validate" button in the actions strip is redundant -- filling +
--      saving Analysis is the implicit validation. Filtered in JS AND
--      deactivated the New->Validation transition here so the actions
--      endpoint stops returning it too.
--   3. "Delegated" state name was jargon. Rename display to "Analysed"
--      (state_code stays Delegated to avoid churn in procs / APIs / data).
--
-- SCOPE:
--   * Rename gap_lifecycle_state_master.state_name for Delegated.
--   * Deactivate the New->Validation transition (Validate action) --
--      analyst goes straight from New to Analysed via analysis save.
--   * Validation state stays in the master (dormant, for historical
--      gaps that landed there before).
--
-- Rollback: 175_gap_terminology_and_ui_tighten_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Rename Delegated -> Analysed (display name only).
UPDATE grac_practice.gap_lifecycle_state_master
   SET state_name  = N'Analysed',
       description = N'Analysis complete; downstream Task / Exception / Risk artefacts own the remediation. Terminal from Gap Centre.',
       updated_by  = N'seed-175',
       updated_dt  = SYSUTCDATETIME()
 WHERE state_code = N'Delegated';
GO

-- 2. Deactivate the "Validate" action (New -> Validation). Analyst saves
--    Analysis instead, which auto-transitions New -> Analysed via the
--    Delegate action fired in sp_custom_gap_analysis_save.
DECLARE @inactive_rs INT =
    (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

UPDATE grac_practice.gap_lifecycle_transition_master
   SET record_status_id = @inactive_rs
 WHERE action_code = N'Validate';
GO

PRINT '175 gap terminology + UI tighten ready.';
GO
