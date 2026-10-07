-- =====================================================================
-- 432 rollback -- Asset Verification Exceptions
--
--   * restores the 431 bodies of sp_asset_attestation_respond and
--     sp_asset_custody_get (copied verbatim below);
--   * occurrences in status Exception go back to Disputed (431 status);
--   * drops the exception procedures and functions;
--   * drops asset_verification_exception (every investigation is lost),
--     asset_verification_settings and asset_verification_sla_rule;
--   * removes the exception transition rules. The exception statuses stay
--     because the immutable transition log references them.
-- practice_audit_trace rows stay as history. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

-- 431 body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_respond
    @organization_id         BIGINT,
    @attestation_id          BIGINT,
    @response                NVARCHAR(10),
    @asset_exists            BIT            = NULL,
    @custody_confirmed       BIT            = NULL,
    @location_verified       BIT            = NULL,
    @tag_verified            BIT            = NULL,
    @serial_verified         BIT            = NULL,
    @assigned_user_verified  BIT            = NULL,
    @information_correct     BIT            = NULL,
    @business_use_confirmed  BIT            = NULL,
    @condition_code          NVARCHAR(30)   = NULL,
    @disagreement_category   NVARCHAR(40)   = NULL,
    @comments                NVARCHAR(2000) = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @channel                 NVARCHAR(30)   = N'Web',
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @response = UPPER(LTRIM(RTRIM(ISNULL(@response, N''))));
    SET @condition_code = UPPER(NULLIF(LTRIM(RTRIM(@condition_code)), N''));
    SET @disagreement_category = UPPER(NULLIF(LTRIM(RTRIM(@disagreement_category)), N''));
    SET @comments = NULLIF(LTRIM(RTRIM(@comments)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');
    SET @channel = ISNULL(NULLIF(LTRIM(RTRIM(@channel)), N''), N'Web');

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @emp BIGINT, @team BIGINT, @evidence_req NVARCHAR(20), @mgr BIT, @asset_id BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @emp = assignee_employee_id, @team = assignee_team_id,
           @evidence_req = evidence_requirement, @mgr = manager_approval_required, @asset_id = asset_id
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54357, 'Attestation not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54358, 'This attestation was changed by someone else. Reload and try again.', 1;
    IF @status NOT IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE')
        THROW 54359, 'This attestation is not open for a response.', 1;
    -- 5.3.2: no response on behalf of another custodian (no delegated authority is configured).
    IF @actor_employee_id IS NULL
       OR NOT (@actor_employee_id = @emp
               OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                           WHERE m.team_id = @team AND m.employee_id = @actor_employee_id AND m.status = N'Active'))
        THROW 54360, 'Only the assigned custodian or owner (or a member of the assigned team) can respond to this attestation.', 1;
    IF @response NOT IN (N'CONFIRM', N'DISAGREE')
        THROW 54361, 'The response must be Confirm or Disagree.', 1;
    IF @condition_code IS NULL OR @condition_code NOT IN
        (N'GOOD', N'FAIR', N'POOR', N'DAMAGED', N'LOST', N'NOT_FOUND', N'RETURNED', N'REPLACED', N'RETIRED')
        THROW 54362, 'Select the condition of the asset.', 1;
    IF @response = N'CONFIRM'
    BEGIN
        IF ISNULL(@asset_exists, 0) = 0 OR ISNULL(@custody_confirmed, 0) = 0 OR @condition_code IN (N'LOST', N'NOT_FOUND')
            THROW 54366, 'A confirmation needs the asset to exist and custody confirmed; a lost or missing asset is a disagreement.', 1;
        -- Conditional confirmation: a check left open or a condition other than Good needs a comment.
        IF @comments IS NULL AND (@condition_code <> N'GOOD' OR ISNULL(@location_verified, 0) = 0 OR ISNULL(@tag_verified, 0) = 0
               OR ISNULL(@serial_verified, 0) = 0 OR ISNULL(@assigned_user_verified, 0) = 0 OR ISNULL(@information_correct, 0) = 0
               OR ISNULL(@business_use_confirmed, 0) = 0)
            THROW 54364, 'Add a comment explaining the checks not confirmed or the condition.', 1;
        SET @disagreement_category = NULL;
    END
    ELSE
    BEGIN
        IF @disagreement_category IS NULL OR @disagreement_category NOT IN
            (N'ASSET_NOT_FOUND', N'WRONG_CUSTODIAN', N'ASSET_RETURNED', N'ASSET_REPLACED', N'ASSET_DAMAGED', N'ASSET_LOST',
             N'LOCATION_INCORRECT', N'INFORMATION_INCORRECT', N'DUPLICATE_RECORD', N'ASSET_RETIRED', N'OTHER')
            THROW 54363, 'Select the disagreement category.', 1;
        IF @comments IS NULL
            THROW 54364, 'Explain the disagreement in the comments.', 1;
    END
    IF @evidence_req = N'MANDATORY' AND @evidence_text IS NULL
        THROW 54365, 'Evidence is required for this attestation (photo, scan, document or other reference).', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT status, response, condition_code, disagreement_category, comments
                                       FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @new_status NVARCHAR(20) = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED'
                                            WHEN @mgr = 1 THEN N'CONFIRMED' ELSE N'CLOSED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET response = @response, asset_exists = @asset_exists, custody_confirmed = @custody_confirmed,
           location_verified = @location_verified, tag_verified = @tag_verified, serial_verified = @serial_verified,
           assigned_user_verified = @assigned_user_verified, information_correct = @information_correct,
           business_use_confirmed = @business_use_confirmed, condition_code = @condition_code,
           disagreement_category = @disagreement_category, comments = @comments, evidence_text = @evidence_text,
           attested_by = @actor, attested_by_employee_id = @actor_employee_id, channel = @channel, response_dt = SYSUTCDATETIME(),
           status = CASE WHEN @new_status = N'CLOSED' THEN N'CONFIRMED' ELSE @new_status END,
           verification_status = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED' END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    IF @new_status = N'CLOSED'
        EXEC grac_practice.sp_asset_attestation_close_verified @attestation_id = @attestation_id, @actor = @actor;
    IF @response = N'DISAGREE'
        MERGE grac_practice.asset_attestation_state AS t
        USING (SELECT @asset_id AS asset_id) AS s ON t.asset_id = s.asset_id
        WHEN MATCHED THEN UPDATE SET verification_status = N'DISPUTED', last_attestation_id = @attestation_id,
                                     updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (asset_id, organization_id, verification_status, last_attestation_id, updated_by, updated_dt)
                              VALUES (@asset_id, @organization_id, N'DISPUTED', @attestation_id, @actor, SYSUTCDATETIME());
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation', @attestation_id, @response, @before,
            (SELECT @response AS response, @new_status AS status, @condition_code AS conditionCode,
                    @disagreement_category AS disagreementCategory, @comments AS comments, @evidence_text AS evidence,
                    @asset_exists AS assetExists, @custody_confirmed AS custodyConfirmed, @location_verified AS locationVerified,
                    @tag_verified AS tagVerified, @serial_verified AS serialVerified, @assigned_user_verified AS assignedUserVerified,
                    @information_correct AS informationCorrect, @business_use_confirmed AS businessUseConfirmed, @channel AS channel
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @attestation_id AS AttestationId, @new_status AS Result;
END
GO
PRINT '432 rollback: sp_asset_attestation_respond restored (431).';
GO

-- 431 body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_custody_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54351, 'Asset not found for this organization.', 1;

    SELECT @asset_id AS AssetId, ISNULL(st.verification_status, N'NOT_VERIFIED') AS VerificationStatus,
           st.last_attested_date AS LastAttestedDate, st.next_attestation_date AS NextAttestationDate,
           p.ProfileId, p.AttestationRequired, p.Participant, p.Frequency, p.CustomIntervalDays, p.DueWindowDays,
           p.EvidenceRequirement, p.ManagerApprovalRequired, p.VersionNo AS ProfileVersion
      FROM (SELECT 1 AS x) one
      LEFT JOIN grac_practice.asset_attestation_state st ON st.asset_id = @asset_id
      OUTER APPLY grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset_id) p;

    SELECT h.assignment_id AS AssignmentId, ow.employee_name AS OwnerName,
           COALESCE(ce.employee_name, ct.team_name + N' (team)') AS CustodianName,
           d.department_name AS DepartmentName, l.location_name AS LocationName,
           h.building AS Building, h.floor AS Floor, h.room AS Room,
           h.effective_from AS EffectiveFrom, h.effective_to AS EffectiveTo, h.is_current AS IsCurrent,
           h.change_source AS ChangeSource, h.entered_by AS EnteredBy, h.entered_dt AS EnteredDt
      FROM grac_practice.asset_assignment_history h
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = h.asset_owner_id
      LEFT JOIN grac_practice.organization_employee ce ON h.custodian LIKE N'E:%' AND ce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_team ct ON h.custodian LIKE N'T:%' AND ct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_department d ON d.department_id = h.department_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = h.location_id
     WHERE h.asset_id = @asset_id
     ORDER BY h.effective_from DESC, h.assignment_id DESC;

    SELECT t.attestation_id AS AttestationId, t.attestation_type AS AttestationType, t.assignee_role AS AssigneeRole,
           COALESCE(e.employee_name, tm.team_name + N' (team)') AS AssigneeName, t.due_date AS DueDate,
           CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < CAST(SYSUTCDATETIME() AS DATE)
                THEN N'OVERDUE' ELSE t.status END AS DisplayStatus,
           t.response AS Response, t.condition_code AS ConditionCode, t.disagreement_category AS DisagreementCategory,
           t.comments AS Comments, at.employee_name AS AttestedByName, t.response_dt AS ResponseDt, t.closed_dt AS ClosedDt,
           t.decision_note AS DecisionNote
      FROM grac_practice.asset_attestation t
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assignee_employee_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = t.assignee_team_id
      LEFT JOIN grac_practice.organization_employee at ON at.employee_id = t.attested_by_employee_id
     WHERE t.asset_id = @asset_id
     ORDER BY t.generated_dt DESC, t.attestation_id DESC;
END
GO
PRINT '432 rollback: sp_asset_custody_get restored (431).';
GO

IF OBJECT_ID('grac_practice.asset_attestation','U') IS NOT NULL
    UPDATE grac_practice.asset_attestation
       SET status = N'DISPUTED', updated_by = N'rollback-432', updated_dt = SYSUTCDATETIME()
     WHERE status = N'EXCEPTION';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_rule_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_settings_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_settings_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_exception_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_exception_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_exception_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_verification_exception_create;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_verification_exception_view;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_verification_rule;
PRINT '432 rollback: procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_verification_exception;
DROP TABLE IF EXISTS grac_practice.asset_verification_settings;
DROP TABLE IF EXISTS grac_practice.asset_verification_sla_rule;
DELETE FROM grac_practice.entity_state_transition_rule
 WHERE entity_type = N'AssetVerificationException' AND entered_by = N'seed-432';
PRINT '432 rollback: tables and rules removed.';
GO

SELECT '432 rollback: exception objects gone, 431 procedures restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_verification_exception','U') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_attestation_respond')) NOT LIKE '%sp_asset_verification_exception_create%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_custody_get')) NOT LIKE '%asset_verification_exception%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
