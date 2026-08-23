-- =====================================================================
-- 212 Risk Centre — organisation configuration + approval gate
--     (Risk Candidate Analysis and Risk Register BRD §18, §19, §24)
--     Phase B.
--
-- WHAT §19 ACTUALLY ASKS FOR
-- --------------------------
-- §19: "The organisation shall be able to configure whether formal
-- approval is required before registration ... The approval mechanism
-- shall not alter the fundamental requirement that initial analysis
-- precedes registration."
--
-- Two things follow, and the second is the one that is easy to get
-- wrong:
--
--  1. Whether approval is required is DATA, per organisation.
--  2. Approval sits BETWEEN analysis and registration — it is a second
--     gate, never a substitute for the first. §24 rule 1 still holds
--     unconditionally. So the approval check is added INSIDE
--     sp_risk_candidate_register, AFTER the analysis lookup that already
--     throws 56133, never before it.
--
-- WHY A RATING THRESHOLD AND NOT JUST AN ON/OFF SWITCH
-- ----------------------------------------------------
-- A flat switch forces an organisation to choose between "approve
-- nothing" and "approve every Low risk anyone ever logs". Neither is how
-- risk committees work: approval is reserved for exposure that matters.
-- So `approval_min_rating_code` names the lowest rating that needs it,
-- resolved through the organisation's OWN matrix — `risk_matrix_cell`
-- (204) gives every rating a numeric band, and the gate compares scores,
-- not strings. An organisation using colour bands or 1-4 instead of
-- Low/Medium/High/Critical works unchanged, which is what §7's
-- "configurable methodology" requires.
--
-- LEGACY `Accepted` — DEPRECATED HERE
-- -----------------------------------
-- 169/199's Accept triage is superseded by Register (see
-- docs/risk-centre.md, conflict 1). Rather than delete a proc that
-- organisations may still be mid-flight on, this migration adds
-- `allow_legacy_accept` (default 0) and teaches
-- sp_risk_candidate_accept to refuse when it is off. Existing 'Accepted'
-- rows are untouched and stay readable — deleting history to tidy a
-- vocabulary would be the worse trade.
--
-- WHAT THIS MIGRATION ADDS
--   1. org_risk_config              per-org switches
--   2. org_risk_config_notify_role  §18/§21 who hears about what
--   3. sp_risk_config_get / _save
--   4. sp_risk_approval_required    the gate's decision, in one place
--   5. sp_risk_analysis_submit_approval   §19 request
--   6. sp_risk_analysis_approve           §19 approve / return
--   7. sp_risk_approval_queue_list        the approver's worklist
--   8. sp_risk_candidate_register  REWRITE — enforces the gate
--   9. sp_risk_candidate_accept    REWRITE — honours the deprecation
--
-- 8 and 9 are STRICT SUPERSETS: same names, same parameters in the same
-- order, every original result-set column still present.
--
-- ERROR CODE RANGE: 56220-56299
-- Rollback: database/212_risk_org_config_and_approval_rollback.sql
-- Depends:  204, 205, 206, 207
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
BEGIN PRINT 'ABORT (212): risk_analysis missing — run 205 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_candidate_register','P') IS NULL
BEGIN PRINT 'ABORT (212): sp_risk_candidate_register missing — run 206 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN PRINT 'ABORT (212): organization_role missing — run 052 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('212_risk_org_config_and_approval: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. org_risk_config   (BRD §19, §22, and conflict 1)
--
-- One row per organisation. Follows the org_sla_config shape (178) so
-- the two configuration screens read alike.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_risk_config','U') IS NULL
CREATE TABLE grac_practice.org_risk_config(
    org_risk_config_id      BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_risk_config PRIMARY KEY,
    organization_id         BIGINT NOT NULL
        CONSTRAINT fk_pm_org_risk_config_org
            REFERENCES grac_practice.organization(organization_id)
        CONSTRAINT uq_pm_org_risk_config_org UNIQUE,

    -- ---- §19 approval gate -------------------------------------------
    approval_required       BIT NOT NULL
        CONSTRAINT df_pm_org_risk_approval_required DEFAULT 0,

    -- Lowest rating that needs approval. NULL with approval_required = 1
    -- means "every risk". Compared by SCORE, resolved through the
    -- organisation's own matrix — see the header note.
    approval_min_rating_code NVARCHAR(30) NULL,

    -- Which role may approve. NULL = any user the API lets through;
    -- the Risk Manager / Approver of §18 when set.
    approver_role_id        BIGINT NULL,
    approver_role_name      NVARCHAR(200) NULL,

    -- ---- §22 treatment tasks -----------------------------------------
    -- §22: "Risk registration itself shall not automatically imply that
    -- a treatment task exists." So the DEFAULT is 0 and the caller opts
    -- in per registration. This column is only the pre-tick on the form,
    -- never an automatic raise. See 215.
    default_raise_treatment_task BIT NOT NULL
        CONSTRAINT df_pm_org_risk_default_treatment DEFAULT 0,

    -- ---- Deprecation of the legacy triage (conflict 1) ---------------
    allow_legacy_accept     BIT NOT NULL
        CONSTRAINT df_pm_org_risk_allow_accept DEFAULT 0,

    -- ---- §21 notifications -------------------------------------------
    notifications_enabled   BIT NOT NULL
        CONSTRAINT df_pm_org_risk_notify DEFAULT 1,

    notes                   NVARCHAR(1000) NULL,

    record_status_id        INT NOT NULL
        CONSTRAINT fk_pm_org_risk_config_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_risk_config_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_org_risk_config_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT fk_pm_org_risk_config_approver_role
        FOREIGN KEY (approver_role_id)
        REFERENCES grac_practice.organization_role(role_id)
);
GO

-- =====================================================================
-- 2. org_risk_config_notify_role   (BRD §18, §21)
--
-- Same shape and reasoning as org_sla_config_notify_role (178): the
-- config stores WHICH ROLES hear about an event; sp_org_role_holders_list
-- (117) resolves WHO holds them at the moment it fires.
--
-- The event vocabulary is §21's list verbatim. It is deliberately NOT
-- the SLA vocabulary (WARNING / BREACH / ESCALATION) — these are
-- workflow events, not time thresholds, and pretending otherwise would
-- force one of the two lists to lie.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_risk_config_notify_role','U') IS NULL
CREATE TABLE grac_practice.org_risk_config_notify_role(
    org_risk_config_notify_role_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_risk_notify_role PRIMARY KEY,
    org_risk_config_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_org_risk_nr_config
            REFERENCES grac_practice.org_risk_config(org_risk_config_id),
    organization_id         BIGINT NOT NULL
        CONSTRAINT fk_pm_org_risk_nr_org
            REFERENCES grac_practice.organization(organization_id),

    notify_event_code       NVARCHAR(40) NOT NULL,
    role_id                 BIGINT NOT NULL
        CONSTRAINT fk_pm_org_risk_nr_role
            REFERENCES grac_practice.organization_role(role_id),
    role_name               NVARCHAR(200) NULL,

    is_active               BIT NOT NULL
        CONSTRAINT df_pm_org_risk_nr_active DEFAULT 1,
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_org_risk_nr_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_org_risk_nr_entered_dt DEFAULT SYSUTCDATETIME(),

    -- BRD §21, in the order the BRD lists them.
    CONSTRAINT ck_pm_org_risk_nr_event
        CHECK (notify_event_code IN (
            N'CANDIDATE_ASSIGNED',      -- "New Risk Candidate assigned for analysis"
            N'CLARIFICATION_REQUESTED', -- "Clarification requested"
            N'ANALYSIS_COMPLETED',      -- "Analysis completed"
            N'APPROVAL_REQUIRED',       -- "Approval required"
            N'RISK_APPROVED',           -- "Risk approved for registration"
            N'CANDIDATE_REJECTED',      -- "Candidate rejected"
            N'RISK_OWNER_ASSIGNED',     -- "Risk Owner assignment"
            N'RISK_REGISTERED'          -- registration itself
        ))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_org_risk_notify_role_uniq'
                  AND object_id = OBJECT_ID('grac_practice.org_risk_config_notify_role'))
    CREATE UNIQUE INDEX ux_pm_org_risk_notify_role_uniq
        ON grac_practice.org_risk_config_notify_role
           (organization_id, notify_event_code, role_id);
GO

-- =====================================================================
-- 3. Seed a config row for every active organisation
--
-- Defaults are the conservative ones: approval OFF (so 206's behaviour
-- is unchanged until somebody turns it on), treatment tasks OFF (§22),
-- legacy Accept OFF (conflict 1), notifications ON.
-- =====================================================================
DECLARE @active_rs INT =
    (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

INSERT INTO grac_practice.org_risk_config
    (organization_id, approval_required, approval_min_rating_code,
     default_raise_treatment_task, allow_legacy_accept, notifications_enabled,
     record_status_id, entered_by)
SELECT o.organization_id, 0, NULL, 0, 0, 1, @active_rs, N'seed-212'
  FROM grac_practice.organization o
 WHERE o.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config c
                    WHERE c.organization_id = o.organization_id);
GO

-- =====================================================================
-- 4. sp_risk_config_get / sp_risk_config_save
--
-- _get creates the row on demand rather than returning nothing, so an
-- organisation added after 212 ran still has working defaults. The same
-- on-demand pattern sp_risk_scoring_options_get uses for the matrix.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56220, 'sp_risk_config_get: organization_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config
                    WHERE organization_id = @organization_id)
    BEGIN
        DECLARE @rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
        INSERT INTO grac_practice.org_risk_config
            (organization_id, record_status_id, entered_by)
        VALUES (@organization_id, @rs, N'auto-212');
    END

    SELECT
        c.org_risk_config_id           AS OrgRiskConfigId,
        c.organization_id              AS OrganizationId,
        c.approval_required            AS ApprovalRequired,
        c.approval_min_rating_code     AS ApprovalMinRatingCode,
        c.approver_role_id             AS ApproverRoleId,
        c.approver_role_name           AS ApproverRoleName,
        c.default_raise_treatment_task AS DefaultRaiseTreatmentTask,
        c.allow_legacy_accept          AS AllowLegacyAccept,
        c.notifications_enabled        AS NotificationsEnabled,
        c.notes                        AS Notes
      FROM grac_practice.org_risk_config c
     WHERE c.organization_id = @organization_id;

    -- Second result set: the §21 notify-role matrix.
    SELECT
        n.notify_event_code AS NotifyEventCode,
        n.role_id           AS RoleId,
        n.role_name         AS RoleName,
        n.is_active         AS IsActive
      FROM grac_practice.org_risk_config_notify_role n
     WHERE n.organization_id = @organization_id
       AND n.is_active = 1
     ORDER BY n.notify_event_code, n.role_name;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_config_save
    @organization_id              BIGINT,
    @approval_required            BIT           = NULL,
    @approval_min_rating_code     NVARCHAR(30)  = NULL,
    @approver_role_id             BIGINT        = NULL,
    @default_raise_treatment_task BIT           = NULL,
    @allow_legacy_accept          BIT           = NULL,
    @notifications_enabled        BIT           = NULL,
    @notes                        NVARCHAR(1000) = NULL,
    -- NULL means "leave this field alone" for every parameter above.
    -- Two fields also have NULL as a legitimate VALUE — no approver role,
    -- and "every rating needs approval" — so each gets an explicit clear
    -- switch. Without them a caller could set those fields but never
    -- un-set them.
    @clear_approver_role          BIT           = 0,
    @clear_min_rating             BIT           = 0,
    @caller_display_name          NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56221, 'sp_risk_config_save: organization_id is required.', 1;

    -- A rating the organisation's matrix does not produce would make the
    -- gate silently unreachable, which is the worst possible failure for
    -- a control: it looks configured and does nothing.
    IF @approval_min_rating_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell
                        WHERE organization_id = @organization_id
                          AND rating_code     = @approval_min_rating_code)
        THROW 56222, 'sp_risk_config_save: approval_min_rating_code is not a rating this organisation''s risk matrix produces.', 1;

    IF @approver_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @approver_role_id)
        THROW 56223, 'sp_risk_config_save: approver_role_id not found.', 1;

    -- Create the row on demand. Deliberately NOT a call to
    -- sp_risk_config_get: that proc emits two result sets, and calling it
    -- here would put four on the wire ahead of the caller's read.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config
                    WHERE organization_id = @organization_id)
    BEGIN
        DECLARE @rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
        INSERT INTO grac_practice.org_risk_config
            (organization_id, record_status_id, entered_by)
        VALUES (@organization_id, @rs, @caller_display_name);
    END

    DECLARE @role_name NVARCHAR(200) =
        (SELECT role_name FROM grac_practice.organization_role WHERE role_id = @approver_role_id);

    UPDATE grac_practice.org_risk_config
       SET approval_required            = COALESCE(@approval_required, approval_required),
           approval_min_rating_code     = CASE WHEN @clear_min_rating = 1 THEN NULL
                                               ELSE COALESCE(@approval_min_rating_code, approval_min_rating_code) END,
           approver_role_id             = CASE WHEN @clear_approver_role = 1 THEN NULL
                                               ELSE COALESCE(@approver_role_id, approver_role_id) END,
           approver_role_name           = CASE WHEN @clear_approver_role = 1 THEN NULL
                                               ELSE COALESCE(@role_name, approver_role_name) END,
           default_raise_treatment_task = COALESCE(@default_raise_treatment_task, default_raise_treatment_task),
           allow_legacy_accept          = COALESCE(@allow_legacy_accept, allow_legacy_accept),
           notifications_enabled        = COALESCE(@notifications_enabled, notifications_enabled),
           notes                        = COALESCE(@notes, notes),
           updated_by                   = @caller_display_name,
           updated_dt                   = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;

    EXEC grac_practice.sp_risk_config_get @organization_id = @organization_id;
END;
GO

-- =====================================================================
-- 5. sp_risk_approval_required   (BRD §19)
--
-- The gate's decision, in ONE place, so the register proc, the UI hint
-- and the approval queue can never disagree about whether a given
-- analysis needs signing off.
--
-- Comparison is by SCORE, not by string. `approval_min_rating_code` is
-- looked up in the organisation's own matrix to find the lowest score
-- carrying that rating; anything at or above it needs approval. That is
-- what makes a colour-band or 1-4 framework work without special cases.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_approval_required
    @risk_analysis_id BIGINT,
    @required         BIT           OUTPUT,
    @reason           NVARCHAR(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @required = 0;
    SET @reason   = N'Approval is not configured for this organisation.';

    IF @risk_analysis_id IS NULL
        THROW 56230, 'sp_risk_approval_required: risk_analysis_id is required.', 1;

    DECLARE @org_id BIGINT, @rating NVARCHAR(30), @score INT;
    SELECT @org_id = organization_id,
           @rating = inherent_rating_code,
           @score  = inherent_rating_score
      FROM grac_practice.risk_analysis
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @org_id IS NULL
        THROW 56231, 'sp_risk_approval_required: analysis not found.', 1;

    DECLARE @approval_required BIT, @min_rating NVARCHAR(30);
    SELECT @approval_required = approval_required,
           @min_rating        = approval_min_rating_code
      FROM grac_practice.org_risk_config
     WHERE organization_id = @org_id;

    -- No config row yet = the 212 defaults = approval off.
    IF ISNULL(@approval_required, 0) = 0 RETURN;

    IF @min_rating IS NULL
    BEGIN
        SET @required = 1;
        SET @reason   = N'This organisation requires approval for every risk before registration.';
        RETURN;
    END

    -- Lowest score that carries the threshold rating in THIS org's matrix.
    DECLARE @threshold_score INT =
        (SELECT MIN(rating_score) FROM grac_practice.risk_matrix_cell
          WHERE organization_id = @org_id AND rating_code = @min_rating);

    -- A threshold naming a rating the matrix no longer produces (someone
    -- re-graded the grid after configuring the gate) must FAIL SAFE —
    -- require approval — rather than quietly waving everything through.
    IF @threshold_score IS NULL
    BEGIN
        SET @required = 1;
        SET @reason   = CONCAT(N'Approval threshold "', @min_rating,
                               N'" is no longer produced by this organisation''s risk matrix; approval is required until the configuration is corrected.');
        RETURN;
    END

    IF @score IS NULL
    BEGIN
        SET @required = 1;
        SET @reason   = N'This analysis has no inherent rating score, so it cannot be shown to fall below the approval threshold.';
        RETURN;
    END

    IF @score >= @threshold_score
    BEGIN
        SET @required = 1;
        SET @reason   = CONCAT(N'Inherent rating "', ISNULL(@rating, N'?'),
                               N'" is at or above the configured approval threshold "', @min_rating, N'".');
    END
    ELSE
        SET @reason = CONCAT(N'Inherent rating "', ISNULL(@rating, N'?'),
                             N'" is below the configured approval threshold "', @min_rating, N'".');
END;
GO

-- =====================================================================
-- 6. sp_risk_analysis_submit_approval   (BRD §19)
--
-- Moves the CURRENT analysis to Pending approval and the candidate to
-- AnalysisCompleted — §16's "Analysis Completed" is exactly the state
-- "the analyst is done, somebody else must act now".
--
-- Submitting when approval is NOT required is not an error: an
-- organisation may want a second pair of eyes on a Medium risk even
-- though its policy does not demand one. The gate governs what is
-- MANDATORY, not what is permitted.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_submit_approval
    @risk_candidate_id   BIGINT,
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56240, 'sp_risk_analysis_submit_approval: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30);
    SELECT @current = status_code FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 56241, 'sp_risk_analysis_submit_approval: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56242, 'sp_risk_analysis_submit_approval: this candidate is closed.', 1;

    DECLARE @analysis_id BIGINT =
        (SELECT risk_analysis_id FROM grac_practice.risk_analysis
          WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1);
    IF @analysis_id IS NULL
        THROW 56243, 'sp_risk_analysis_submit_approval: no risk analysis exists for this candidate (BRD 24.1).', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_analysis
           SET approval_status_code = N'Pending',
               approval_note        = @remark,
               approved_by_employee_id = NULL,
               approved_dt          = NULL,
               updated_by           = @caller_display_name,
               updated_dt           = SYSUTCDATETIME()
         WHERE risk_analysis_id = @analysis_id;

        UPDATE grac_practice.risk_candidate
           SET status_code = N'AnalysisCompleted',
               updated_by  = @caller_display_name,
               updated_dt  = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'SubmitApproval', @current, N'AnalysisCompleted',
             @remark, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'AnalysisCompleted' AS StatusCode,
           @analysis_id       AS RiskAnalysisId,
           N'Pending'         AS ApprovalStatusCode;
END;
GO

-- =====================================================================
-- 7. sp_risk_analysis_approve   (BRD §19)
--
-- "Review the analysis. Validate risk classification and rating. Approve
-- registration or return the risk for further analysis."
--
-- @decision = 'Approve' | 'Return'. A return goes back to
-- ClarificationRequired and reuses the §8C column, because "the approver
-- wants more work done" and "the analyst wants more information" are the
-- same state to everyone downstream — one status, one place to look.
--
-- Approving does NOT register. §19's diagram is
-- Analysis -> Approval -> Risk Register: three steps, not two. Keeping
-- them separate is also what lets an approver approve in bulk while
-- registration stays a deliberate act.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_analysis_approve
    @risk_candidate_id   BIGINT,
    @decision            NVARCHAR(20),          -- Approve | Return
    @remark              NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 56250, 'sp_risk_analysis_approve: risk_candidate_id is required.', 1;
    IF @decision IS NULL OR @decision NOT IN (N'Approve', N'Return')
        THROW 56251, 'sp_risk_analysis_approve: decision must be Approve or Return.', 1;
    IF @decision = N'Return' AND (@remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0)
        THROW 56252, 'sp_risk_analysis_approve: a reason is required when returning a risk for further analysis.', 1;

    DECLARE @current NVARCHAR(30), @org_id BIGINT;
    SELECT @current = status_code, @org_id = organization_id
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 56253, 'sp_risk_analysis_approve: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56254, 'sp_risk_analysis_approve: this candidate is closed.', 1;

    DECLARE @analysis_id BIGINT, @approval NVARCHAR(30);
    SELECT @analysis_id = risk_analysis_id, @approval = approval_status_code
      FROM grac_practice.risk_analysis
     WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1;
    IF @analysis_id IS NULL
        THROW 56255, 'sp_risk_analysis_approve: no current analysis to approve.', 1;
    IF ISNULL(@approval, N'') <> N'Pending'
        THROW 56256, 'sp_risk_analysis_approve: this analysis has not been submitted for approval.', 1;

    -- §18 Risk Manager / Approver. Enforced only when the organisation
    -- has named a role — an unnamed role means "the screen's permissions
    -- are the control", which is how every other Centre behaves.
    DECLARE @approver_role_id BIGINT =
        (SELECT approver_role_id FROM grac_practice.org_risk_config
          WHERE organization_id = @org_id);

    --
    -- "Holds the role" is checked BOTH ways on purpose. GRAC stores role
    -- membership in two places: organization_employee.role_id (the
    -- primary role, which sp_org_role_holders_list (117) reads) and the
    -- organization_employee_role map (027, for secondary roles). 213
    -- notifies approvers through 117, so if this check used only the map,
    -- a person could be TOLD to approve and then refused permission to —
    -- the most confusing failure a workflow can produce. Accepting either
    -- keeps the notification and the permission in agreement.
    IF @approver_role_id IS NOT NULL AND @actor_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        WHERE e.employee_id = @actor_employee_id
                          AND e.role_id     = @approver_role_id)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee_role r
                        WHERE r.employee_id = @actor_employee_id
                          AND r.role_id     = @approver_role_id
                          AND r.status      = N'Active')
        THROW 56257, 'sp_risk_analysis_approve: caller does not hold the configured risk approver role (BRD 18).', 1;

    DECLARE @to_status NVARCHAR(30) =
        CASE WHEN @decision = N'Approve' THEN N'AnalysisCompleted' ELSE N'ClarificationRequired' END;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_analysis
           SET approval_status_code    = CASE WHEN @decision = N'Approve' THEN N'Approved' ELSE N'Returned' END,
               approved_by_employee_id = @actor_employee_id,
               approved_dt             = SYSUTCDATETIME(),
               approval_note           = @remark,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_analysis_id = @analysis_id;

        UPDATE grac_practice.risk_candidate
           SET status_code                = @to_status,
               clarification_note         = CASE WHEN @decision = N'Return' THEN @remark ELSE clarification_note END,
               clarification_requested_dt = CASE WHEN @decision = N'Return' THEN SYSUTCDATETIME() ELSE clarification_requested_dt END,
               updated_by                 = @caller_display_name,
               updated_dt                 = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id,
             CASE WHEN @decision = N'Approve' THEN N'Approve' ELSE N'ReturnFromApproval' END,
             @current, @to_status,
             @remark, @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId,
           @to_status         AS StatusCode,
           @analysis_id       AS RiskAnalysisId,
           CASE WHEN @decision = N'Approve' THEN N'Approved' ELSE N'Returned' END AS ApprovalStatusCode;
END;
GO

-- =====================================================================
-- 8. sp_risk_approval_queue_list   (BRD §19, §23 "Candidates awaiting
--    approval")
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_approval_queue_list
    @organization_id BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56260, 'sp_risk_approval_queue_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        c.risk_candidate_id      AS RiskCandidateId,
        c.candidate_number       AS CandidateNumber,
        c.candidate_title        AS CandidateTitle,
        c.source_type_code       AS SourceTypeCode,
        c.source_reference       AS SourceReference,
        c.status_code            AS StatusCode,
        a.risk_analysis_id       AS RiskAnalysisId,
        a.analysis_version       AS AnalysisVersion,
        a.risk_statement         AS RiskStatement,
        a.risk_category_name     AS RiskCategoryName,
        a.likelihood_name        AS LikelihoodName,
        a.impact_name            AS ImpactName,
        a.inherent_rating_code   AS InherentRatingCode,
        a.inherent_rating_score  AS InherentRatingScore,
        a.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name         AS RiskOwnerName,
        a.analysis_dt            AS AnalysisOn,
        an.employee_name         AS AnalysedByName,
        a.approval_note          AS ApprovalNote,
        DATEDIFF(DAY, a.updated_dt, SYSUTCDATETIME()) AS DaysWaiting,
        COUNT(*) OVER ()         AS TotalRows
      FROM grac_practice.risk_analysis a
      JOIN grac_practice.risk_candidate c ON c.risk_candidate_id = a.risk_candidate_id
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
     WHERE a.organization_id      = @organization_id
       AND a.is_current           = 1
       AND a.approval_status_code = N'Pending'
       AND c.status_code NOT IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
     ORDER BY a.inherent_rating_score DESC, a.updated_dt
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- =====================================================================
-- 9. sp_risk_candidate_register   (REWRITE — strict superset of 206)
--
-- ONE new behaviour: the §19 gate, inserted AFTER the §24 rule 1 check
-- so approval can never become a way around analysis.
--
-- Every parameter, every result-set column and every other line is
-- 206's. @force_without_approval exists for an administrative override
-- and is NOT exposed by the API — it is there so a future data-fix
-- script has a documented door rather than an UPDATE against the table.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_register
    @risk_candidate_id    BIGINT,
    @risk_title           NVARCHAR(300) = NULL,
    @registration_note    NVARCHAR(MAX) = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system',
    @force_without_approval BIT         = 0     -- NEW, administrative only
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_candidate_id IS NULL
        THROW 56130, 'sp_risk_candidate_register: risk_candidate_id is required.', 1;

    DECLARE @current NVARCHAR(30), @cand_title NVARCHAR(300),
            @src_type NVARCHAR(40), @src_id BIGINT, @src_ref NVARCHAR(200),
            @src_desc NVARCHAR(MAX), @src_centre NVARCHAR(60);

    SELECT @current    = status_code,
           @cand_title = candidate_title,
           @src_type   = source_type_code,
           @src_id     = source_record_id,
           @src_ref    = source_reference,
           @src_desc   = source_description,
           @src_centre = source_centre_code
      FROM grac_practice.risk_candidate
     WHERE risk_candidate_id = @risk_candidate_id;

    IF @current IS NULL
        THROW 56131, 'sp_risk_candidate_register: candidate not found.', 1;
    IF @current IN (N'Registered', N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
        THROW 56132, 'sp_risk_candidate_register: this candidate is already closed.', 1;

    -- §24 rule 1. FIRST, always.
    DECLARE @analysis_id BIGINT =
        (SELECT risk_analysis_id FROM grac_practice.risk_analysis
          WHERE risk_candidate_id = @risk_candidate_id AND is_current = 1);
    IF @analysis_id IS NULL
        THROW 56133, 'sp_risk_candidate_register: no risk analysis exists for this candidate. Every risk entering the register must pass through an initial analysis (BRD 24.1).', 1;

    IF @src_type IS NULL
        THROW 56134, 'sp_risk_candidate_register: this candidate has no source type. Run 207_risk_centre_source_wiring.sql to backfill legacy candidates.', 1;

    -- ---- NEW in 212: the §19 approval gate ---------------------------
    -- Second gate, never a substitute for the first.
    IF ISNULL(@force_without_approval, 0) = 0
    BEGIN
        DECLARE @needs_approval BIT, @gate_reason NVARCHAR(400);
        EXEC grac_practice.sp_risk_approval_required
             @risk_analysis_id = @analysis_id,
             @required         = @needs_approval OUTPUT,
             @reason           = @gate_reason    OUTPUT;

        IF @needs_approval = 1
        BEGIN
            DECLARE @approval NVARCHAR(30) =
                (SELECT approval_status_code FROM grac_practice.risk_analysis
                  WHERE risk_analysis_id = @analysis_id);

            IF ISNULL(@approval, N'') <> N'Approved'
            BEGIN
                DECLARE @gate_msg NVARCHAR(2048) =
                    CONCAT(N'sp_risk_candidate_register: approval is required before registration. ',
                           @gate_reason,
                           N' Current approval status: ', ISNULL(@approval, N'(not submitted)'), N'.');
                THROW 56270, @gate_msg, 1;
            END
        END
    END

    DECLARE @new_risk_id BIGINT;
    DECLARE @title NVARCHAR(300) = COALESCE(NULLIF(LTRIM(RTRIM(@risk_title)), N''), @cand_title);

    BEGIN TRY
        BEGIN TRAN;

        EXEC grac_practice.sp_risk_register_insert
             @risk_analysis_id     = @analysis_id,
             @risk_title           = @title,
             @source_type_code     = @src_type,
             @source_record_id     = @src_id,
             @source_reference     = @src_ref,
             @source_description   = @src_desc,
             @source_centre_code   = @src_centre,
             @risk_candidate_id    = @risk_candidate_id,
             @linked_asset_id      = @linked_asset_id,
             @linked_vendor_id     = @linked_vendor_id,
             @linked_practice_id   = @linked_practice_id,
             @linked_obligation_id = @linked_obligation_id,
             @linked_control_id    = @linked_control_id,
             @registered_by_employee_id = @registered_by_employee_id,
             @caller_display_name  = @caller_display_name,
             @risk_register_id     = @new_risk_id OUTPUT;

        UPDATE grac_practice.risk_candidate
           SET status_code        = N'Registered',
               registered_risk_id = @new_risk_id,
               formal_risk_ref    = (SELECT risk_number FROM grac_practice.risk_register
                                      WHERE risk_register_id = @new_risk_id),
               acceptance_note    = COALESCE(@registration_note, acceptance_note),
               accepted_by_employee_id = COALESCE(@registered_by_employee_id, accepted_by_employee_id),
               accepted_dt        = COALESCE(accepted_dt, SYSUTCDATETIME()),
               updated_by         = @caller_display_name,
               updated_dt         = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        UPDATE grac_practice.risk_analysis
           SET decision_note = COALESCE(@registration_note, decision_note)
         WHERE risk_analysis_id = @analysis_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Register', @current, N'Registered',
             CONCAT(N'Registered as risk_register_id ', CAST(@new_risk_id AS NVARCHAR(20)),
                    CASE WHEN @registration_note IS NULL THEN N''
                         ELSE CONCAT(N'. ', @registration_note) END),
             @registered_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Registered'      AS StatusCode,
           @new_risk_id       AS RiskRegisterId,
           (SELECT risk_number FROM grac_practice.risk_register
             WHERE risk_register_id = @new_risk_id) AS RiskNumber;
END;
GO

-- =====================================================================
-- 10. sp_risk_candidate_accept   (REWRITE — deprecation, conflict 1)
--
-- 199's body is preserved verbatim, including the Task Centre raise.
-- The ONLY change is a guard at the top: when the organisation has not
-- set allow_legacy_accept, the proc refuses and names its replacement.
--
-- Refusing rather than silently redirecting to sp_risk_candidate_register
-- is deliberate. Accept and Register are not the same act — Register
-- creates a register entry and may need approval — so quietly doing the
-- other one would be the worst kind of helpfulness.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_candidate_accept
    @risk_candidate_id       BIGINT,
    @acceptance_note         NVARCHAR(MAX),
    @accepted_by_employee_id BIGINT,
    @formal_risk_ref         NVARCHAR(200) = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    @raise_task_candidate    BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_candidate_id IS NULL
        THROW 55430, 'sp_risk_candidate_accept: risk_candidate_id is required.', 1;
    IF @acceptance_note IS NULL OR LEN(LTRIM(RTRIM(@acceptance_note))) = 0
        THROW 55431, 'sp_risk_candidate_accept: acceptance_note is required.', 1;
    IF @accepted_by_employee_id IS NULL
        THROW 55432, 'sp_risk_candidate_accept: accepted_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30), @org_id BIGINT;
    SELECT @current = status_code, @org_id = organization_id
      FROM grac_practice.risk_candidate WHERE risk_candidate_id = @risk_candidate_id;
    IF @current IS NULL
        THROW 55433, 'sp_risk_candidate_accept: candidate not found.', 1;
    IF @current <> N'Pending'
        THROW 55434, 'sp_risk_candidate_accept: only Pending candidates can be accepted.', 1;

    -- ---- NEW in 212: deprecation guard -------------------------------
    IF ISNULL((SELECT allow_legacy_accept FROM grac_practice.org_risk_config
                WHERE organization_id = @org_id), 0) = 0
        THROW 56280, 'sp_risk_candidate_accept: the legacy Accept triage is disabled for this organisation. Use sp_risk_candidate_register, which creates the Risk Register entry the BRD requires. Set org_risk_config.allow_legacy_accept = 1 to re-enable it during migration.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.risk_candidate
           SET status_code             = N'Accepted',
               accepted_by_employee_id = @accepted_by_employee_id,
               accepted_dt             = SYSUTCDATETIME(),
               acceptance_note         = @acceptance_note,
               formal_risk_ref         = @formal_risk_ref,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE risk_candidate_id = @risk_candidate_id;

        INSERT INTO grac_practice.risk_candidate_history
            (risk_candidate_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_candidate_id, N'Accept', N'Pending', N'Accepted',
             CONCAT(N'Note: ', @acceptance_note,
                    CASE WHEN @formal_risk_ref IS NOT NULL
                         THEN CONCAT(N'  Formal risk ref: ', @formal_risk_ref)
                         ELSE N'' END),
             @accepted_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- ---- 199's treatment Task Candidate raise (unchanged) ------------
    DECLARE @candidate_id BIGINT = NULL, @created BIT = 0;

    IF ISNULL(@raise_task_candidate, 1) = 1
    BEGIN
        BEGIN TRY
            DECLARE @risk_title NVARCHAR(300), @risk_summary NVARCHAR(MAX), @severity NVARCHAR(30);

            SELECT @risk_title   = candidate_title,
                   @risk_summary = candidate_summary,
                   @severity     = severity_code
              FROM grac_practice.risk_candidate
             WHERE risk_candidate_id = @risk_candidate_id;

            DECLARE @priority NVARCHAR(30) =
                CASE WHEN @severity IN (N'Low', N'Medium', N'High', N'Critical')
                     THEN @severity ELSE N'Medium' END;

            DECLARE @cand_title NVARCHAR(250) =
                LEFT(CONCAT(N'Risk treatment: ', @risk_title), 250);
            DECLARE @cand_desc NVARCHAR(MAX) =
                CONCAT(ISNULL(@risk_summary, N''),
                       N'  Accepted as a formal risk: ', @acceptance_note);
            DECLARE @source_ref NVARCHAR(200) =
                CONCAT(N'RISK-', CAST(@risk_candidate_id AS NVARCHAR(20)));

            EXEC grac_practice.sp_task_candidate_create
                 @organization_id       = @org_id,
                 @source_type_code      = N'Risk',
                 @source_record_id      = @risk_candidate_id,
                 @candidate_title       = @cand_title,
                 @candidate_description = @cand_desc,
                 @source_reference      = @source_ref,
                 @source_dedupe_key     = N'RISK_TREATMENT',
                 @task_type_code        = N'RiskDriven',
                 @proposed_priority     = @priority,
                 @actor_employee_id     = @accepted_by_employee_id,
                 @caller_display_name   = @caller_display_name,
                 @task_candidate_id     = @candidate_id OUTPUT,
                 @created               = @created      OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @tc_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_risk_candidate_accept: task candidate warning: ', @tc_warn);
        END CATCH
    END

    SELECT @risk_candidate_id AS RiskCandidateId,
           N'Accepted'        AS StatusCode,
           @candidate_id      AS TaskCandidateId;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '212 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_risk_config','U')                 IS NOT NULL
             AND OBJECT_ID('grac_practice.org_risk_config_notify_role','U')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_config_get','P')               IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_config_save','P')              IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_approval_required','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_submit_approval','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_analysis_approve','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_approval_queue_list','P')      IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'every active org has a risk config row' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization o
                              WHERE o.status = N'Active'
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config c
                                                 WHERE c.organization_id = o.organization_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'register proc keeps its 206 parameters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_register')
                            AND name = '@linked_obligation_id')
             AND EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_register')
                            AND name = '@registration_note')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'accept proc keeps its 199 parameters' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_accept')
                            AND name = '@raise_task_candidate')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '212 Risk Centre org config + approval gate installed. Next: 213_risk_notification_outbox.sql';
PRINT 'DEFAULTS: approval OFF, treatment tasks OFF, legacy Accept OFF, notifications ON.';
PRINT '          206 behaviour is therefore unchanged until an organisation turns approval on.';
GO

SET NOEXEC OFF;
GO
