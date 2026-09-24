-- =====================================================================
-- 263 Risk Centre — Treatment Option, treatment tasks and the gate into
--     Residual Risk Analysis
--
-- WHAT THE FLOW ASKS FOR
-- ----------------------
--   Risk Analysis
--        |
--        +-- Terminate / Avoid  --> Risk Treatment Task --+
--        +-- Treat / Reduce     --> Risk Treatment Task --+--> all closed
--        +-- Transfer / Share   --> Risk Treatment Task --+       |
--        |                                                       v
--        |                                        Residual Risk Analysis
--        |                                                       |
--        +-- Tolerate / Accept  ------------------------> Risk Acceptance
--
-- Three of the four options raise work. The fourth raises none and goes
-- straight to acceptance. That asymmetry is the whole of this file.
--
-- ---------------------------------------------------------------------
-- DECISION 1 — A REAL TASK, NOT A TASK CANDIDATE
-- ---------------------------------------------------------------------
-- 215 raises a task CANDIDATE (197) so a human can confirm owner, SLA
-- and priority before work lands in a queue, and docs/risk-centre.md
-- records that as BRD §22's separation of registration from treatment.
--
-- This migration opens a TASK directly instead, for these options, and
-- the reason is not that §22 was wrong -- it is that the precondition
-- §22 was protecting no longer holds here:
--
--   * §22 worried about work with no owner. A treatment task raised from
--     a chosen treatment option HAS an owner by construction: the Risk
--     Owner, who is already on the register and already accountable.
--   * §22's candidate stage needed a screen to be approved from. 253
--     records that the Task Candidates tab was retired, so candidates
--     raised here would sit in task_candidate reachable by nothing --
--     the exact failure 253 was written to fix for gaps.
--
-- 253 made the same call for gap remediation, in the same words ("revert
-- the gap seam to direct task creation"), and explicitly left the
-- candidate model standing for the sources that still use it. This is
-- the second such seam, not a reversal of the model.
--
-- 215's sp_risk_treatment_task_raise IS NOT REMOVED OR MODIFIED. An
-- organisation that wants the candidate gate still has it, still on the
-- register row menu. This file adds an automatic path; it does not close
-- the manual one.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — IDEMPOTENCY IS A COLUMN, NOT A QUERY
-- ---------------------------------------------------------------------
-- "Treatment task creation is idempotent -- reopening/reloading the page
--  must not create duplicate tasks."
--
-- risk_register.treatment_task_id (261) holds the parent task. Before
-- creating anything, this file looks there. That is one indexed read of
-- a row it has already loaded, and it cannot be defeated by a concurrent
-- save the way a COUNT(*) over practice_task can.
--
-- The column is only trusted when the task it names still EXISTS and is
-- still OPEN. A completed treatment task must not block the next round
-- of treatment after a review re-opens the risk -- that would make the
-- second cycle silently impossible.
--
-- ---------------------------------------------------------------------
-- DECISION 3 — THE RESIDUAL GATE, AND WHY 258'S SAVE IS REWRITTEN
-- ---------------------------------------------------------------------
-- "If multiple treatment tasks exist, Residual Risk Analysis should
--  become available only when all required treatment tasks are closed."
--
-- 258's gate is status-based: residual is allowed once the risk is
-- UnderTreatment, Monitoring or Accepted. Raising a treatment task sets
-- UnderTreatment -- so under 258 alone, residual would be assessable the
-- moment treatment STARTS, which is precisely what the requirement
-- forbids.
--
-- A gate enforced only in the API or the UI is not a gate; it is a
-- convention that the next caller does not know about. So
-- sp_risk_residual_analysis_save is re-emitted here as a STRICT SUPERSET
-- of its 258 definition: same name, same parameters in the same order,
-- same result set, every 258 gate still present, plus one more.
--
-- Re-emitting a procedure body is a real cost -- 215's header argues
-- against doing it casually and it is right. It is paid here because the
-- alternative is a rule that holds only for callers who remember it.
-- The 258 body below is unmodified apart from the new gate and the new
-- treatment_option_code column; diffing the two files should show
-- exactly that and nothing else.
--
-- 263-rollback re-runs 258 to restore the original. That is the same
-- instruction 258's own rollback gives for 216.
--
-- ---------------------------------------------------------------------
-- DECISION 4 — 'RiskRegister' EVERYWHERE, NEVER 'Risk'
-- ---------------------------------------------------------------------
-- 215 established the distinction and it still holds:
--   Risk          source_record_id is a risk_candidate_id
--   RiskRegister  source_record_id is a risk_register_id
-- Both CHECKs already admit 'RiskRegister' (215), so nothing here has to
-- widen anything. Reads still union both, because a stream-originated
-- risk can carry work from both eras.
--
-- CONTENTS
--   1. sp_risk_treatment_task_ensure    idempotent direct task
--   2. sp_risk_treatment_option_set     the decision, and its dispatch
--   3. sp_risk_treatment_state          open/closed counts + gate answer
--   4. sp_risk_treatment_sync           all tasks closed -> Monitoring
--   5. sp_risk_residual_analysis_save   REWRITE, superset of 258
--
-- ERROR CODE RANGE: 56560-56599
-- Rollback: database/263_risk_treatment_option_rollback.sql
-- Depends:  037, 192-196 (Task Centre v2), 205, 215, 216, 258, 261, 262
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF COL_LENGTH('grac_practice.risk_register','treatment_option_code') IS NULL
BEGIN PRINT 'ABORT (263): risk_register.treatment_option_code missing -- run 261 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_register','treatment_task_id') IS NULL
BEGIN PRINT 'ABORT (263): risk_register.treatment_task_id missing -- run 261 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
BEGIN PRINT 'ABORT (263): sp_task_open missing -- run 196 first.'; SET @ok = 0; END

-- Existence is not enough. 196 added @source_type_code / @source_record_id /
-- @source_reference / @resolve_owner (v3), and 196's ROLLBACK restores the
-- pre-v3 signature without them. Against that older body this migration
-- would install cleanly and then fail at the first treatment decision with
-- "too many arguments specified" -- a run-time failure for a condition that
-- is knowable now.
IF OBJECT_ID('grac_practice.sp_task_open','P') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.parameters
                    WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                      AND name = '@source_type_code')
BEGIN
    PRINT 'ABORT (263): sp_task_open is missing @source_type_code -- it is on a pre-196';
    PRINT '             definition. Re-run 196_task_centre_v2_open.sql.';
    SET @ok = 0;
END

IF OBJECT_ID('grac_practice.sp_task_open','P') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.parameters
                    WHERE object_id = OBJECT_ID('grac_practice.sp_task_open')
                      AND name = '@resolve_owner')
BEGIN
    PRINT 'ABORT (263): sp_task_open is missing @resolve_owner -- it is on a pre-196';
    PRINT '             definition. Re-run 196_task_centre_v2_open.sql.';
    SET @ok = 0;
END
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (263): vw_pm_practice_task missing -- run 195 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_rating_resolve','P') IS NULL
BEGIN PRINT 'ABORT (263): sp_risk_rating_resolve missing -- run 206 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NULL
BEGIN PRINT 'ABORT (263): risk_residual_analysis missing -- run 258 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_residual_analysis','treatment_option_code') IS NULL
BEGIN PRINT 'ABORT (263): risk_residual_analysis.treatment_option_code missing -- run 261 first.'; SET @ok = 0; END

-- 'RiskDriven' is seeded by 037. Without it sp_task_open throws 53721 at
-- the first treatment decision rather than here, which is a much worse
-- place to discover a missing seed row.
IF NOT EXISTS (SELECT 1 FROM grac_practice.task_type_master
                WHERE type_code = N'RiskDriven' AND is_active = 1)
BEGIN PRINT 'ABORT (263): task type RiskDriven missing or inactive -- run 037 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('263_risk_treatment_option: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_treatment_task_ensure
--
-- Opens the risk's treatment task, or returns the one that is already
-- open. Never opens a second.
--
-- OWNER (requirement: "The Risk Owner should automatically become the
-- owner of the Risk Treatment Task"): risk_owner_employee_id is passed
-- as @assigned_to_employee_id, and @resolve_owner = 0 so Task Centre's
-- owner ladder does not second-guess it. The ladder exists for work that
-- arrives without an owner; this work never does.
--
-- Where the risk somehow has no owner, @resolve_owner is left at 1 and
-- the ladder runs -- a task with a resolved owner beats a task with
-- none, and beats refusing to create the task at all.
--
-- PRIORITY comes from the risk's own rating, unchanged from 215's logic:
-- the four-level rating vocabulary and the four-level priority
-- vocabulary coincide, and urgency is upstream's call.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_task_ensure
    @risk_register_id    BIGINT,
    @task_title          NVARCHAR(250) = NULL,
    @task_description    NVARCHAR(MAX) = NULL,
    @target_date         DATETIME2     = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system',
    @task_id             BIGINT        OUTPUT,
    @created             BIT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @task_id = NULL;
    SET @created = 0;

    IF @risk_register_id IS NULL
        THROW 56560, 'sp_risk_treatment_task_ensure: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @risk_number NVARCHAR(60), @risk_title NVARCHAR(300),
            @statement NVARCHAR(1000), @rating NVARCHAR(30), @status NVARCHAR(30),
            @owner BIGINT, @consequence NVARCHAR(MAX),
            @option_code NVARCHAR(30), @option_name NVARCHAR(120),
            @existing BIGINT, @linked_practice_id BIGINT, @linked_control_id BIGINT;

    SELECT @org_id      = r.organization_id,
           @risk_number = r.risk_number,
           @risk_title  = r.risk_title,
           @statement   = r.risk_statement,
           @rating      = r.inherent_rating_code,
           @status      = r.status_code,
           @owner       = r.risk_owner_employee_id,
           @consequence = r.potential_consequence,
           @option_code = r.treatment_option_code,
           @option_name = r.treatment_option_name,
           @existing    = r.treatment_task_id,
           @linked_practice_id = r.linked_practice_id,
           @linked_control_id  = r.linked_control_id
      FROM grac_practice.risk_register r
     WHERE r.risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56561, 'sp_risk_treatment_task_ensure: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56562, 'sp_risk_treatment_task_ensure: this risk is closed or retired -- reopen it before raising treatment work.', 1;

    -- ---- Idempotency, decision 2 -------------------------------------
    -- The stamped task counts only while it exists AND is still open.
    IF @existing IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.vw_pm_practice_task v
                    WHERE v.task_id = @existing
                      AND v.closed_at IS NULL
                      AND v.current_status_is_terminal = 0)
        BEGIN
            SET @task_id = @existing;
            SET @created = 0;
            RETURN;
        END
    END

    -- Second guard, for the case the stamp was lost: a risk whose task
    -- was raised through 215's candidate route, or by an older build,
    -- still has an open RiskDriven task against it. Re-stamping is
    -- better than duplicating.
    IF @task_id IS NULL
    BEGIN
        SELECT TOP 1 @task_id = v.task_id
          FROM grac_practice.vw_pm_practice_task v
         WHERE v.organization_id  = @org_id
           AND v.source_type_code = N'RiskRegister'
           AND v.source_record_id = @risk_register_id
           AND v.parent_task_id IS NULL
           AND v.closed_at IS NULL
           AND v.current_status_is_terminal = 0
         ORDER BY v.task_id DESC;

        IF @task_id IS NOT NULL
        BEGIN
            UPDATE grac_practice.risk_register
               SET treatment_task_id = @task_id,
                   updated_by = @caller_display_name,
                   updated_dt = SYSUTCDATETIME()
             WHERE risk_register_id = @risk_register_id;

            SET @created = 0;
            RETURN;
        END
    END

    -- ---- Nothing open. Create one. -----------------------------------
    DECLARE @priority NVARCHAR(30) =
        CASE WHEN @rating IN (N'Low', N'Medium', N'High', N'Critical')
             THEN @rating ELSE N'Medium' END;

    -- T-SQL will not take an expression as an EXEC parameter value, so
    -- every argument below is precomputed into a variable. 253 hit the
    -- same wall and left the same note.
    DECLARE @title NVARCHAR(250) =
        COALESCE(NULLIF(LTRIM(RTRIM(@task_title)), N''),
                 LEFT(CONCAT(N'Risk treatment (',
                             ISNULL(@option_name, N'Treat'), N'): ', @risk_title), 250));

    DECLARE @description NVARCHAR(MAX) =
        COALESCE(@task_description,
                 CONCAT(N'Treatment action for ', @risk_number, N'.', CHAR(13), CHAR(10),
                        N'Treatment option: ', ISNULL(@option_name, N'(not recorded)'),
                        CHAR(13), CHAR(10),
                        N'Risk statement: ', ISNULL(@statement, N''),
                        CASE WHEN @consequence IS NULL THEN N''
                             ELSE CONCAT(CHAR(13), CHAR(10),
                                         N'Potential consequence: ', @consequence) END,
                        CHAR(13), CHAR(10),
                        N'Add sub tasks to break this down -- the parent closes only when',
                        N' every mandatory sub task is complete.'));

    DECLARE @source_ref NVARCHAR(200) = @risk_number;

    -- The risk owner owns the task. See the header.
    DECLARE @resolve_owner BIT = CASE WHEN @owner IS NULL THEN 1 ELSE 0 END;
    DECLARE @new_task_id BIGINT;

    BEGIN TRY
        EXEC grac_practice.sp_task_open
             @organization_id         = @org_id,
             @task_type_code          = N'RiskDriven',
             @subject_entity_type     = N'RiskRegister',
             @subject_entity_id       = @risk_register_id,
             @subject_title           = @title,
             @subject_description     = @description,
             @linked_practice_id      = @linked_practice_id,
             @linked_control_id       = @linked_control_id,
             @priority                = @priority,
             @origin_code             = N'GRAC',
             @assigned_to_employee_id = @owner,
             @actor_employee_id       = @actor_employee_id,
             @target_date             = @target_date,
             @source_type_code        = N'RiskRegister',
             @source_record_id        = @risk_register_id,
             @source_reference        = @source_ref,
             @resolve_owner           = @resolve_owner,
             @task_id                 = @new_task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(2000) = ERROR_MESSAGE();
        THROW 56563, @msg, 1;
    END CATCH

    UPDATE grac_practice.risk_register
       SET treatment_task_id = @new_task_id,
           updated_by = @caller_display_name,
           updated_dt = SYSUTCDATETIME()
     WHERE risk_register_id = @risk_register_id;

    SET @task_id = @new_task_id;
    SET @created = 1;
END;
GO

-- =====================================================================
-- 2. sp_risk_treatment_option_set   (requirements 3 and 4)
--
-- The one writer of a treatment decision. It does four things, in one
-- transaction, because a decision recorded without its consequence is
-- the state this whole flow exists to avoid:
--
--   a. stamp the option on the register (authoritative)
--   b. stamp it on the current analysis version (retained history, §20)
--   c. Terminate/Treat/Transfer -> ensure a task, status UnderTreatment
--      Tolerate                 -> no task, status left for acceptance
--   d. write the §20 history line
--
-- WHY TOLERATE DOES NOT SET 'Accepted' HERE
-- -----------------------------------------
-- It is tempting: the option is called Tolerate/Accept, so set Accepted
-- and be done. But acceptance is not the same act as choosing to accept.
-- Requirement 5 says acceptance captures Accepted By, Accepted Date and
-- Next Review Date, and requirement 10 makes the review date MANDATORY
-- at that point. Setting status = 'Accepted' here would produce risks
-- that are accepted by nobody, on no date, with no review date -- and
-- the Review Risk list would never show them again.
--
-- So Tolerate records the intent and routes the user to the acceptance
-- screen. sp_risk_acceptance_save (264) is the only thing that sets
-- Accepted, and it refuses without a review date.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_option_set
    @risk_register_id    BIGINT,
    @treatment_option_code NVARCHAR(30),
    @task_title          NVARCHAR(250) = NULL,
    @task_description    NVARCHAR(MAX) = NULL,
    @target_date         DATETIME2     = NULL,
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system',
    -- Same device, and the same reason, as sp_risk_analysis_save's
    -- @suppress_result (206): this procedure is called BOTH directly by
    -- the API -- which needs the result set -- and from inside
    -- sp_risk_residual_analysis_save and sp_risk_review_perform, which
    -- emit result sets of their own afterwards.
    --
    -- Without this, an inner call's SELECT becomes result set 1 of the
    -- OUTER procedure, and the caller reading "the first result set"
    -- gets the treatment dispatch instead of the residual score. That is
    -- not a hypothetical: it is why this parameter was added.
    @suppress_result     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56564, 'sp_risk_treatment_option_set: risk_register_id is required.', 1;
    IF @treatment_option_code IS NULL OR LEN(LTRIM(RTRIM(@treatment_option_code))) = 0
        THROW 56565, 'sp_risk_treatment_option_set: a treatment option is required.', 1;

    SET @treatment_option_code = LTRIM(RTRIM(@treatment_option_code));

    IF @treatment_option_code NOT IN (N'Terminate', N'Treat', N'Transfer', N'Tolerate')
        THROW 56566, 'sp_risk_treatment_option_set: treatment option must be Terminate, Treat, Transfer or Tolerate.', 1;

    -- The label the user saw, frozen beside the code. One mapping, here,
    -- so the API and the UI never invent their own wording.
    DECLARE @option_name NVARCHAR(120) =
        CASE @treatment_option_code
             WHEN N'Terminate' THEN N'Terminate / Avoid'
             WHEN N'Treat'     THEN N'Treat / Reduce'
             WHEN N'Transfer'  THEN N'Transfer / Share'
             WHEN N'Tolerate'  THEN N'Tolerate / Accept'
        END;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @analysis_id BIGINT, @prev_option NVARCHAR(30), @owner BIGINT;

    SELECT @org_id           = organization_id,
           @status           = status_code,
           @analysis_pending = analysis_pending,
           @analysis_id      = risk_analysis_id,
           @prev_option      = treatment_option_code,
           @owner            = risk_owner_employee_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56567, 'sp_risk_treatment_option_set: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56568, 'sp_risk_treatment_option_set: this risk is closed or retired -- reopen it before choosing a treatment option.', 1;

    -- A treatment decision is a response to a rating. Without one there
    -- is nothing to respond to, and the task's priority would be a
    -- guess dressed up as a derivation.
    IF ISNULL(@analysis_pending, 1) = 1
        THROW 56569, 'sp_risk_treatment_option_set: complete the risk analysis before choosing a treatment option.', 1;

    DECLARE @task_id BIGINT = NULL, @created BIT = 0,
            @new_status NVARCHAR(30) = @status;

    BEGIN TRY
        BEGIN TRAN;

        -- ---- 2a / 2b. Record the decision ----------------------------
        UPDATE grac_practice.risk_register
           SET treatment_option_code            = @treatment_option_code,
               treatment_option_name            = @option_name,
               treatment_decided_dt             = SYSUTCDATETIME(),
               treatment_decided_by_employee_id = @actor_employee_id,
               updated_by                       = @caller_display_name,
               updated_dt                       = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        -- The current analysis version carries the option it concluded
        -- with. Guarded on the id because a custom risk registered before
        -- 216 can have a NULL analysis link.
        IF @analysis_id IS NOT NULL
            UPDATE grac_practice.risk_analysis
               SET treatment_option_code = @treatment_option_code,
                   treatment_option_name = @option_name,
                   updated_by            = @caller_display_name,
                   updated_dt            = SYSUTCDATETIME()
             WHERE risk_analysis_id = @analysis_id;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ---- 2c. Dispatch ------------------------------------------------
    -- Outside the transaction above on purpose. sp_task_open runs its
    -- own transaction and calls the owner ladder; nesting it under a
    -- Risk Centre transaction would hold Task Centre locks for the
    -- duration of a Risk Centre write. The decision is already durable
    -- if the task raise fails, and the failure is reported -- which is
    -- the right split: the decision was made, the work was not raised,
    -- and the operator can see exactly that.
    IF @treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
    BEGIN
        EXEC grac_practice.sp_risk_treatment_task_ensure
             @risk_register_id    = @risk_register_id,
             @task_title          = @task_title,
             @task_description    = @task_description,
             @target_date         = @target_date,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name,
             @task_id             = @task_id OUTPUT,
             @created             = @created OUTPUT;

        -- Only Active moves. A risk already Monitoring or Accepted that
        -- gains new treatment work goes back to UnderTreatment; one that
        -- is already UnderTreatment stays put.
        IF @status <> N'UnderTreatment'
            SET @new_status = N'UnderTreatment';
    END

    BEGIN TRY
        BEGIN TRAN;

        IF @new_status <> @status
            UPDATE grac_practice.risk_register
               SET status_code = @new_status,
                   updated_by  = @caller_display_name,
                   updated_dt  = SYSUTCDATETIME()
             WHERE risk_register_id = @risk_register_id;

        -- ---- 2d. §20 ------------------------------------------------
        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'TreatmentDecided', @status, @new_status,
             CONCAT(N'Treatment option ', @option_name,
                    CASE WHEN @prev_option IS NULL THEN N' chosen.'
                         WHEN @prev_option = @treatment_option_code THEN N' re-confirmed.'
                         ELSE CONCAT(N' chosen (was ', @prev_option, N').') END,
                    CASE WHEN @treatment_option_code = N'Tolerate'
                         THEN N' No treatment task raised -- proceed to Risk Acceptance.'
                         WHEN @created = 1
                         THEN CONCAT(N' Treatment task ', CAST(@task_id AS NVARCHAR(20)),
                                     N' raised, owned by the risk owner.')
                         ELSE CONCAT(N' Treatment task ', ISNULL(CAST(@task_id AS NVARCHAR(20)), N'?'),
                                     N' already open -- not duplicated.') END,
                    CASE WHEN @remark IS NULL THEN N''
                         ELSE CONCAT(N' ', @remark) END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 0
        SELECT @risk_register_id      AS RiskRegisterId,
               @treatment_option_code AS TreatmentOptionCode,
               @option_name           AS TreatmentOptionName,
               @task_id               AS TreatmentTaskId,
               @created               AS TaskCreated,
               @new_status            AS StatusCode,
               -- What the client should do next. Computed here so the
               -- flow has one definition rather than one per screen.
               CASE WHEN @treatment_option_code = N'Tolerate'
                    THEN N'Acceptance' ELSE N'Treatment' END AS NextStep;
END;
GO

-- =====================================================================
-- 3. sp_risk_treatment_state
--
-- The read behind every "can I do this yet?" affordance on the risk.
-- One round trip, two result sets: the counts, then the tasks.
--
-- WHAT COUNTS AS A TREATMENT TASK
-- -------------------------------
-- Both source eras, as 215 established:
--   ('RiskRegister', risk_register_id)  raised here or by 215
--   ('Risk',         risk_candidate_id) raised by 199's legacy Accept
-- Hiding either would tell the risk owner that work does not exist when
-- it does.
--
-- CHILD TASKS ARE COUNTED SEPARATELY, NOT AS PEERS
-- ------------------------------------------------
-- BRD §11: the parent owns the commitment. A parent with two open
-- children is ONE open treatment task, not three, and Task Centre
-- already refuses to close the parent while a mandatory child is open
-- (§12). So the gate counts parents; the children are surfaced for
-- display and to explain WHY a parent is still open.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_state
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56570, 'sp_risk_treatment_state: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @candidate_id BIGINT, @option_code NVARCHAR(30),
            @status NVARCHAR(30), @residual_pending BIT, @analysis_pending BIT;

    SELECT @org_id           = organization_id,
           @candidate_id     = risk_candidate_id,
           @option_code      = treatment_option_code,
           @status           = status_code,
           @residual_pending = residual_pending,
           @analysis_pending = analysis_pending
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56571, 'sp_risk_treatment_state: risk not found.', 1;

    -- Materialised once: the counts and the list both need it, and the
    -- view is not cheap enough to scan twice.
    CREATE TABLE #tt(
        TaskId BIGINT, TaskNumber NVARCHAR(60), Title NVARCHAR(250),
        StatusCode NVARCHAR(30), StatusName NVARCHAR(120), IsTerminal BIT,
        OwnerEmployeeId BIGINT, OwnerName NVARCHAR(240), Priority NVARCHAR(30),
        DueAt DATETIME2, ClosedAt DATETIME2, IsChild BIT, ParentTaskId BIGINT,
        ChildCount INT, MandatoryChildOpenCount INT, RaisedDt DATETIME2
    );

    INSERT INTO #tt
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.assigned_to_employee_id, v.assigned_to_employee_name, v.priority,
           v.sla_due_at, v.closed_at,
           CASE WHEN v.parent_task_id IS NOT NULL THEN 1 ELSE 0 END,
           v.parent_task_id, v.child_count, v.mandatory_child_open_count, v.entered_dt
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @org_id
       AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = @risk_register_id)
         OR (@candidate_id IS NOT NULL
             AND v.source_type_code = N'Risk' AND v.source_record_id = @candidate_id));

    DECLARE @total INT, @open INT, @closed INT, @open_children INT;

    SELECT @total  = COUNT(*),
           @open   = SUM(CASE WHEN ClosedAt IS NULL AND IsTerminal = 0 THEN 1 ELSE 0 END),
           @closed = SUM(CASE WHEN ClosedAt IS NOT NULL OR IsTerminal = 1 THEN 1 ELSE 0 END)
      FROM #tt WHERE IsChild = 0;

    SELECT @open_children = COUNT(*)
      FROM #tt WHERE IsChild = 1 AND ClosedAt IS NULL AND IsTerminal = 0;

    SET @total  = ISNULL(@total, 0);
    SET @open   = ISNULL(@open, 0);
    SET @closed = ISNULL(@closed, 0);

    -- ---- The gate answer, in one place --------------------------------
    -- Residual analysis is available when treatment is genuinely done:
    -- an option that raises work was chosen, at least one task exists,
    -- and none of them is still open. Tolerate never gets here -- it has
    -- no treatment to be residual to and goes straight to acceptance.
    DECLARE @residual_available BIT =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1 THEN 0
             WHEN @status IN (N'Closed', N'Retired')  THEN 0
             WHEN @option_code IS NULL                THEN 0
             WHEN @option_code = N'Tolerate'          THEN 0
             WHEN @total = 0                          THEN 0
             WHEN @open > 0                           THEN 0
             ELSE 1 END;

    DECLARE @reason NVARCHAR(400) =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1
                  THEN N'Complete the risk analysis first.'
             WHEN @status IN (N'Closed', N'Retired')
                  THEN N'This risk is closed or retired.'
             WHEN @option_code IS NULL
                  THEN N'Choose a treatment option first.'
             WHEN @option_code = N'Tolerate'
                  THEN N'Tolerate / Accept does not require residual analysis -- go to Risk Acceptance.'
             WHEN @total = 0
                  THEN N'No treatment task has been raised yet.'
             WHEN @open > 0
                  THEN CONCAT(CAST(@open AS NVARCHAR(10)),
                              N' treatment task(s) still open.',
                              CASE WHEN @open_children > 0
                                   THEN CONCAT(N' ', CAST(@open_children AS NVARCHAR(10)),
                                               N' sub task(s) open.')
                                   ELSE N'' END)
             ELSE N'All treatment tasks are closed -- residual risk analysis is available.'
        END;

    SELECT @risk_register_id   AS RiskRegisterId,
           @option_code        AS TreatmentOptionCode,
           @status             AS StatusCode,
           @total              AS TreatmentTaskCount,
           @open               AS OpenTreatmentTaskCount,
           @closed             AS ClosedTreatmentTaskCount,
           @open_children      AS OpenSubTaskCount,
           @residual_available AS ResidualAvailable,
           ISNULL(@residual_pending, 1) AS ResidualPending,
           @reason             AS Reason;

    SELECT * FROM #tt ORDER BY IsChild, ParentTaskId, TaskId;
    DROP TABLE #tt;
END;
GO

-- =====================================================================
-- 4. sp_risk_treatment_sync   (requirement 6)
--
-- "Once all Risk Treatment Tasks associated with that risk are
--  completed/closed, the risk should move to Residual Risk Analysis."
--
-- Task Centre does not know Risk Centre exists and must not be made to.
-- So this is a SWEEP, not a callback: idempotent, safe to run for one
-- risk or for a whole organisation, and it writes a history row only
-- when it actually moves something.
--
-- Call it from the API after a task completes, and from the Risk Centre
-- read path. Calling it twice does nothing the second time, which is the
-- property that lets it be called liberally.
--
-- UnderTreatment -> Monitoring is the move. §17's own vocabulary already
-- has the right word for "treated, now being watched", and using it
-- means the Risk Register grid, its filters and its status chips all
-- keep working with no new value to teach them.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_sync
    @risk_register_id    BIGINT        = NULL,   -- NULL = sweep the org
    @organization_id     BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL AND @organization_id IS NULL
        THROW 56572, 'sp_risk_treatment_sync: pass risk_register_id or organization_id.', 1;

    -- Candidates for the move, resolved as a set. The two NOT EXISTS
    -- clauses are the "all tasks closed" test, expressed as "no open
    -- task of either source era", which is the same thing and indexes
    -- better than a COUNT comparison.
    CREATE TABLE #moved(RiskRegisterId BIGINT PRIMARY KEY, FromStatus NVARCHAR(30));

    INSERT INTO #moved(RiskRegisterId, FromStatus)
    SELECT r.risk_register_id, r.status_code
      FROM grac_practice.risk_register r
     WHERE r.status_code = N'UnderTreatment'
       AND r.treatment_option_code IN (N'Terminate', N'Treat', N'Transfer')
       AND (@risk_register_id IS NULL OR r.risk_register_id = @risk_register_id)
       AND (@organization_id  IS NULL OR r.organization_id  = @organization_id)
       -- at least one treatment task exists ...
       AND EXISTS (
             SELECT 1 FROM grac_practice.vw_pm_practice_task v
              WHERE v.organization_id = r.organization_id
                AND v.parent_task_id IS NULL
                AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = r.risk_register_id)
                  OR (r.risk_candidate_id IS NOT NULL
                      AND v.source_type_code = N'Risk'
                      AND v.source_record_id = r.risk_candidate_id)))
       -- ... and none of them, parent or child, is still open
       AND NOT EXISTS (
             SELECT 1 FROM grac_practice.vw_pm_practice_task v
              WHERE v.organization_id = r.organization_id
                AND v.closed_at IS NULL
                AND v.current_status_is_terminal = 0
                AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = r.risk_register_id)
                  OR (r.risk_candidate_id IS NOT NULL
                      AND v.source_type_code = N'Risk'
                      AND v.source_record_id = r.risk_candidate_id)));

    IF EXISTS (SELECT 1 FROM #moved)
    BEGIN
        BEGIN TRY
            BEGIN TRAN;

            UPDATE r
               SET status_code = N'Monitoring',
                   updated_by  = @caller_display_name,
                   updated_dt  = SYSUTCDATETIME()
              FROM grac_practice.risk_register r
              JOIN #moved m ON m.RiskRegisterId = r.risk_register_id;

            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            SELECT m.RiskRegisterId, N'TreatmentCompleted', m.FromStatus, N'Monitoring',
                   N'All treatment tasks closed. Residual risk analysis is now available.',
                   NULL, @caller_display_name, @caller_display_name, SYSUTCDATETIME()
              FROM #moved m;

            COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            THROW;
        END CATCH
    END

    SELECT COUNT(*) AS RisksMovedToMonitoring FROM #moved;
    DROP TABLE #moved;
END;
GO

-- =====================================================================
-- 5. sp_risk_residual_analysis_save   REWRITE -- superset of 258
--
-- 258's body, unchanged, plus:
--   * GATE 3 -- every treatment task must be closed (validation case 8)
--   * the treatment option this residual assessment concludes with
--
-- Everything else is byte-for-byte 258: the same parameters in the same
-- order with two appended and defaulted, the same gates 1 and 2, the
-- same resolver, the same versioning, the same register stamp, the same
-- history line, the same result set with two columns added at the end.
-- Existing callers are unaffected -- which is what "superset" has to
-- mean or the word is doing no work.
--
-- See decision 3 in the header for why the gate lives here and not in
-- the API.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_residual_analysis_save
    @risk_register_id        BIGINT,
    @residual_likelihood_code NVARCHAR(60),
    @residual_impact_code    NVARCHAR(60),
    @treatment_summary       NVARCHAR(MAX) = NULL,
    @residual_controls       NVARCHAR(MAX) = NULL,
    @analyst_remarks         NVARCHAR(MAX) = NULL,
    @assessed_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    -- New in 263. Defaulted, so every 258 caller still compiles.
    @treatment_option_code   NVARCHAR(30)  = NULL,
    @skip_treatment_gate     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56450, 'sp_risk_residual_analysis_save: risk_register_id is required.', 1;
    IF @residual_likelihood_code IS NULL OR LEN(LTRIM(RTRIM(@residual_likelihood_code))) = 0
        THROW 56451, 'sp_risk_residual_analysis_save: residual likelihood is required.', 1;
    IF @residual_impact_code IS NULL OR LEN(LTRIM(RTRIM(@residual_impact_code))) = 0
        THROW 56452, 'sp_risk_residual_analysis_save: residual impact is required.', 1;

    IF @treatment_option_code IS NOT NULL
       AND @treatment_option_code NOT IN (N'Terminate', N'Treat', N'Transfer', N'Tolerate')
        THROW 56573, 'sp_risk_residual_analysis_save: treatment option must be Terminate, Treat, Transfer or Tolerate.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @inherent_analysis_id BIGINT, @candidate_id BIGINT,
            @register_option NVARCHAR(30),
            @inh_code NVARCHAR(30), @inh_name NVARCHAR(120), @inh_score INT;

    SELECT @org_id               = organization_id,
           @status               = status_code,
           @analysis_pending     = analysis_pending,
           @inherent_analysis_id = risk_analysis_id,
           @candidate_id         = risk_candidate_id,
           @register_option      = treatment_option_code,
           @inh_code             = inherent_rating_code,
           @inh_name             = inherent_rating_name,
           @inh_score            = inherent_rating_score
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56453, 'sp_risk_residual_analysis_save: risk not found.', 1;

    -- ---- Gate 1 (258): there must be something to be residual TO -----
    IF ISNULL(@analysis_pending, 1) = 1 OR @inh_code IS NULL
        THROW 56454, 'sp_risk_residual_analysis_save: this risk has no inherent rating yet. Complete the risk analysis before assessing residual risk.', 1;

    -- ---- Gate 2 (258): treatment must have been decided (§17) --------
    IF @status IN (N'Closed', N'Retired')
        THROW 56455, 'sp_risk_residual_analysis_save: this risk is closed or retired -- reopen it before assessing residual risk.', 1;

    IF @status = N'Active'
        THROW 56456, 'sp_risk_residual_analysis_save: residual risk is what remains after treatment. Move this risk to Under treatment, Monitoring or Accepted first.', 1;

    IF @status NOT IN (N'UnderTreatment', N'Monitoring', N'Accepted')
        THROW 56457, 'sp_risk_residual_analysis_save: residual risk can only be assessed on a risk under treatment, monitoring or accepted.', 1;

    -- ---- Gate 3 (263, NEW): the treatment must actually be FINISHED --
    -- Only meaningful where treatment work was raised. A Tolerate risk,
    -- and a risk from before this migration with no option recorded, are
    -- both governed by gate 2 alone -- tightening the rule must not make
    -- existing data unassessable (validation case 13).
    --
    -- @skip_treatment_gate exists for one caller: the review flow (264),
    -- which re-opens a risk and re-scores it before the NEXT round of
    -- treatment. It is not a general escape hatch and no screen sends it.
    IF ISNULL(@skip_treatment_gate, 0) = 0
       AND @register_option IN (N'Terminate', N'Treat', N'Transfer')
    BEGIN
        DECLARE @open_tasks INT;

        SELECT @open_tasks = COUNT(*)
          FROM grac_practice.vw_pm_practice_task v
         WHERE v.organization_id = @org_id
           AND v.closed_at IS NULL
           AND v.current_status_is_terminal = 0
           AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = @risk_register_id)
             OR (@candidate_id IS NOT NULL
                 AND v.source_type_code = N'Risk' AND v.source_record_id = @candidate_id));

        IF ISNULL(@open_tasks, 0) > 0
        BEGIN
            DECLARE @gate_msg NVARCHAR(400) = CONCAT(
                N'sp_risk_residual_analysis_save: ', CAST(@open_tasks AS NVARCHAR(10)),
                N' treatment task(s) are still open. Residual risk can only be assessed once all treatment work is complete.');
            THROW 56574, @gate_msg, 1;
        END
    END

    -- ---- Resolve the scale -- the SAME masters as the inherent path --
    DECLARE @lk_name NVARCHAR(200), @lk_value INT,
            @im_name NVARCHAR(200), @im_value INT;

    SELECT @lk_name = likelihood_name, @lk_value = level_value
      FROM grac_practice.risk_likelihood_master
     WHERE organization_id = @org_id
       AND likelihood_code = @residual_likelihood_code
       AND status = N'Active';
    IF @lk_value IS NULL
        THROW 56458, 'sp_risk_residual_analysis_save: unknown residual likelihood_code for this organisation.', 1;

    SELECT @im_name = impact_name, @im_value = level_value
      FROM grac_practice.risk_impact_master
     WHERE organization_id = @org_id
       AND impact_code = @residual_impact_code
       AND status = N'Active';
    IF @im_value IS NULL
        THROW 56459, 'sp_risk_residual_analysis_save: unknown residual impact_code for this organisation.', 1;

    DECLARE @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT;
    EXEC grac_practice.sp_risk_rating_resolve
         @organization_id  = @org_id,
         @likelihood_value = @lk_value,
         @impact_value     = @im_value,
         @rating_code      = @rt_code  OUTPUT,
         @rating_name      = @rt_name  OUTPUT,
         @rating_score     = @rt_score OUTPUT;

    IF @rt_code IS NULL
        THROW 56460, 'sp_risk_residual_analysis_save: the residual likelihood/impact pair resolved to no rating. Check the organisation''s risk matrix configuration.', 1;

    DECLARE @option_name NVARCHAR(120) =
        CASE @treatment_option_code
             WHEN N'Terminate' THEN N'Terminate / Avoid'
             WHEN N'Treat'     THEN N'Treat / Reduce'
             WHEN N'Transfer'  THEN N'Transfer / Share'
             WHEN N'Tolerate'  THEN N'Tolerate / Accept'
             ELSE NULL
        END;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @next_version INT = 1, @residual_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @next_version = ISNULL(MAX(residual_version), 0) + 1
          FROM grac_practice.risk_residual_analysis
         WHERE risk_register_id = @risk_register_id;

        UPDATE grac_practice.risk_residual_analysis
           SET is_current = 0,
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND is_current = 1;

        INSERT INTO grac_practice.risk_residual_analysis
            (organization_id, risk_register_id, inherent_analysis_id,
             residual_version, is_current,
             residual_likelihood_code, residual_likelihood_name, residual_likelihood_value,
             residual_impact_code, residual_impact_name, residual_impact_value,
             residual_rating_code, residual_rating_name, residual_rating_score,
             inherent_rating_code, inherent_rating_name, inherent_rating_score,
             treatment_summary, residual_controls, analyst_remarks,
             treatment_option_code, treatment_option_name,
             assessed_dt, assessed_by_employee_id,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @risk_register_id, @inherent_analysis_id,
             @next_version, 1,
             @residual_likelihood_code, @lk_name, @lk_value,
             @residual_impact_code, @im_name, @im_value,
             @rt_code, @rt_name, @rt_score,
             @inh_code, @inh_name, @inh_score,
             @treatment_summary, @residual_controls, @analyst_remarks,
             @treatment_option_code, @option_name,
             SYSUTCDATETIME(), @assessed_by_employee_id,
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @residual_id = SCOPE_IDENTITY();

        UPDATE grac_practice.risk_register
           SET residual_analysis_id      = @residual_id,
               residual_likelihood_code  = @residual_likelihood_code,
               residual_likelihood_name  = @lk_name,
               residual_likelihood_value = @lk_value,
               residual_impact_code      = @residual_impact_code,
               residual_impact_name      = @im_name,
               residual_impact_value     = @im_value,
               residual_rating_code      = @rt_code,
               residual_rating_name      = @rt_name,
               residual_rating_score     = @rt_score,
               residual_assessed_dt      = SYSUTCDATETIME(),
               residual_pending          = 0,
               updated_by                = @caller_display_name,
               updated_dt                = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'ResidualAssessed', @status, @status,
             CONCAT(N'Residual assessment v', CAST(@next_version AS NVARCHAR(10)),
                    N'. Inherent ', ISNULL(@inh_code, N'(none)'),
                    N' -> residual ', @rt_code,
                    N' (', @lk_name, N' x ', @im_name, N').',
                    CASE WHEN @option_name IS NULL THEN N''
                         ELSE CONCAT(N' Concluded: ', @option_name, N'.') END),
             @assessed_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- The residual assessment can itself conclude with a NEW treatment
    -- decision -- a risk still too high after one round gets another.
    -- Delegated to the one writer of that decision, outside the
    -- transaction, for the reason section 2 gives.
    --
    -- @suppress_result = 1 is NOT optional here. Without it the inner
    -- SELECT becomes this procedure's FIRST result set and the caller,
    -- reading result set 1 for the residual score, gets the treatment
    -- dispatch instead.
    IF @treatment_option_code IS NOT NULL
        EXEC grac_practice.sp_risk_treatment_option_set
             @risk_register_id      = @risk_register_id,
             @treatment_option_code = @treatment_option_code,
             @remark                = N'Set from residual risk analysis.',
             @actor_employee_id     = @assessed_by_employee_id,
             @caller_display_name   = @caller_display_name,
             @suppress_result       = 1;

    SELECT @risk_register_id AS RiskRegisterId,
           @residual_id      AS RiskResidualAnalysisId,
           @next_version     AS ResidualVersion,
           @rt_code          AS ResidualRatingCode,
           @rt_name          AS ResidualRatingName,
           @rt_score         AS ResidualRatingScore,
           @inh_code         AS InherentRatingCode,
           @inh_score        AS InherentRatingScore,
           -- New in 263, appended so 258's column order is preserved.
           @treatment_option_code AS TreatmentOptionCode,
           @option_name           AS TreatmentOptionName;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '263 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_treatment_task_ensure','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_option_set','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_state','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_sync','P')        IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- 215's manual, candidate-based raise must still be there. This
-- migration adds a path; it does not replace one.
SELECT '263 215 candidate raise still present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_treatment_task_raise','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '263 residual save carries the treatment gate' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_residual_analysis_save')
                            AND definition LIKE '%skip_treatment_gate%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '263 Risk treatment option installed.';
PRINT '     Terminate/Treat/Transfer open a RiskDriven task owned by the risk owner.';
PRINT '     Tolerate raises nothing and routes to Risk Acceptance.';
PRINT '     Residual analysis is refused while any treatment task is open.';
GO

SET NOEXEC OFF;
GO
