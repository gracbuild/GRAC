-- =====================================================================
-- 158 Gap Centre v1 -- seed (states + transitions) + backfill
--
-- Seeds the 9 canonical lifecycle states (AES sec 4) and the allowed
-- transitions between them (feeds the Decision Gateway + 3-dot menu).
-- Also backfills lifecycle_state_id on every existing custom_gap row
-- from the legacy status value so 157's transition proc has a valid
-- starting point.
--
-- Everything is idempotent (NOT EXISTS guards on natural keys).
--
-- DEPENDS ON: 156, 157. Rollback: 158_gap_centre_v1_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @active_rs INT =
    (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
IF @active_rs IS NULL
BEGIN
    RAISERROR('158: record_status_master.Active is missing.', 16, 1);
    RETURN;
END

-- =====================================================================
-- 1. States (AES section 4)
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'New', N'New', N'Gap has just been raised; needs validation.',
         10, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Validation')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Validation', N'Validation', N'Reviewer confirms the gap is real and in-scope.',
         20, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Analysis')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Analysis', N'Analysis', N'Gap Analysis Engine captures severity, impact, RCA and recommended actions.',
         30, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'ResolutionPlanning')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'ResolutionPlanning', N'Resolution Planning',
         N'Decision Gateway: plan tasks / exceptions / risk candidates.',
         40, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Execution')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Execution', N'Execution',
         N'Remediation is being carried out; linked tasks are in flight.',
         50, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Verification')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Verification', N'Verification',
         N'Remediation complete; verifier confirms closure criteria are met.',
         60, 0, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Closed')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Closed', N'Closed', N'Gap resolved and verified.',
         70, 1, 1, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Invalid')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Invalid', N'Invalid', N'Gap was not real / not in scope; withdrawn.',
         80, 1, 0, N'Active', @active_rs, N'seed-158');

IF NOT EXISTS(SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Duplicate')
    INSERT INTO grac_practice.gap_lifecycle_state_master
        (state_code, state_name, description, sort_order, is_terminal, is_valid_terminal, status, record_status_id, entered_by)
    VALUES
        (N'Duplicate', N'Duplicate', N'Gap merged into another existing gap.',
         90, 1, 0, N'Active', @active_rs, N'seed-158');
GO

-- =====================================================================
-- 2. Transitions
-- Layered idempotently: only insert (from_state, action) pairs that are
-- not already present. Naming follows a short verb: Validate, Analyse,
-- PlanResolution, StartExecution, SubmitForVerification, Approve,
-- SendBack, MarkInvalid, MarkDuplicate, Reopen.
-- =====================================================================
DECLARE @s_new  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
DECLARE @s_val  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Validation');
DECLARE @s_ana  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Analysis');
DECLARE @s_plan INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'ResolutionPlanning');
DECLARE @s_exec INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Execution');
DECLARE @s_ver  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Verification');
DECLARE @s_cls  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Closed');
DECLARE @s_inv  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Invalid');
DECLARE @s_dup  INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Duplicate');
DECLARE @rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

;WITH desired(from_state_id, to_state_id, action_code, action_name, description, remark_required) AS (
    SELECT * FROM (VALUES
        (@s_new,  @s_val,  N'Validate',              N'Validate',                N'Confirm the gap is real and in-scope.',                    0),
        (@s_new,  @s_inv,  N'MarkInvalid',           N'Mark Invalid',            N'Reject the gap with a reason.',                            1),
        (@s_new,  @s_dup,  N'MarkDuplicate',         N'Mark Duplicate',          N'Point at an existing gap this row duplicates.',            1),

        (@s_val,  @s_ana,  N'Analyse',               N'Start Analysis',          N'Move into the Gap Analysis Engine.',                       0),
        (@s_val,  @s_inv,  N'MarkInvalid',           N'Mark Invalid',            N'Reject after validation.',                                 1),
        (@s_val,  @s_dup,  N'MarkDuplicate',         N'Mark Duplicate',          N'Point at an existing gap this row duplicates.',            1),

        (@s_ana,  @s_plan, N'PlanResolution',        N'Plan Resolution',         N'Analysis complete; move to Decision Gateway.',             0),
        (@s_ana,  @s_val,  N'SendBackToValidation',  N'Send Back to Validation', N'Analysis found the gap is not in scope; re-validate.',     1),
        (@s_ana,  @s_inv,  N'MarkInvalid',           N'Mark Invalid',            N'Reject during analysis.',                                  1),

        (@s_plan, @s_exec, N'StartExecution',        N'Start Execution',         N'Downstream artefacts created; remediation begins.',        0),
        (@s_plan, @s_ana,  N'SendBackToAnalysis',    N'Send Back to Analysis',   N'Planning found analysis is incomplete.',                   1),

        (@s_exec, @s_ver,  N'SubmitForVerification', N'Submit for Verification', N'Remediation complete; ready for verifier sign-off.',       0),
        (@s_exec, @s_plan, N'SendBackToPlanning',    N'Send Back to Planning',   N'Execution cannot proceed with the current plan.',          1),

        (@s_ver,  @s_cls,  N'Approve',               N'Close Gap',               N'Verifier approves closure.',                               0),
        (@s_ver,  @s_exec, N'SendBackToExecution',   N'Send Back to Execution',  N'Verifier rejects; additional remediation needed.',         1),

        (@s_cls,  @s_exec, N'Reopen',                N'Reopen',                  N'Reopen a closed gap for further remediation.',             1)
    ) v(from_state_id, to_state_id, action_code, action_name, description, remark_required)
)
INSERT INTO grac_practice.gap_lifecycle_transition_master
    (from_state_id, to_state_id, action_code, action_name, description, remark_required,
     record_status_id, entered_by, entered_dt)
SELECT d.from_state_id, d.to_state_id, d.action_code, d.action_name, d.description, d.remark_required,
       @rs, N'seed-158', SYSUTCDATETIME()
  FROM desired d
 WHERE NOT EXISTS (
    SELECT 1 FROM grac_practice.gap_lifecycle_transition_master t
     WHERE t.from_state_id = d.from_state_id
       AND t.action_code   = d.action_code );
GO

-- =====================================================================
-- 3. Backfill lifecycle_state_id from legacy status on existing rows.
--    Mapping:
--       Open       -> New
--       InProgress -> Execution
--       Closed     -> Closed
--       Cancelled  -> Invalid
--    Only touch rows that don't already have a lifecycle_state_id
--    (idempotent).
-- =====================================================================
DECLARE @new_id    INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
DECLARE @exec_id   INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Execution');
DECLARE @closed_id INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Closed');
DECLARE @inv_id    INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Invalid');

UPDATE grac_practice.custom_gap
   SET lifecycle_state_id = CASE status
                              WHEN N'Open'       THEN @new_id
                              WHEN N'InProgress' THEN @exec_id
                              WHEN N'Closed'     THEN @closed_id
                              WHEN N'Cancelled'  THEN @inv_id
                              ELSE @new_id
                            END,
       updated_by = COALESCE(updated_by, N'seed-158'),
       updated_dt = COALESCE(updated_dt, SYSUTCDATETIME())
 WHERE lifecycle_state_id IS NULL;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'gap_lifecycle_state_master row count' AS Check_, COUNT(*) AS RowCount_
  FROM grac_practice.gap_lifecycle_state_master;
SELECT 'gap_lifecycle_transition_master row count' AS Check_, COUNT(*) AS RowCount_
  FROM grac_practice.gap_lifecycle_transition_master;
SELECT 'custom_gap rows with lifecycle_state_id populated' AS Check_,
       SUM(CASE WHEN lifecycle_state_id IS NOT NULL THEN 1 ELSE 0 END) AS WithState,
       COUNT(*) AS TotalRows
  FROM grac_practice.custom_gap;

PRINT '158 Gap Centre v1 seed complete.';
GO
