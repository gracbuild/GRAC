-- =====================================================================
-- 558  Phase 5 -- Question responses and findings (audit flow redesign)
--
-- REQUEST (2026-11-14, sir) -- docs/audit-flow-redesign.md Phase 5,
-- decision 3: compliance is marked ONCE per question per execution.
--   The auditor answers each question of the execution (its questions
--   snapshot): Compliant / Not compliant / Not applicable. Not compliant
--   needs a description and an owner, and raises an Audit Finding
--   (org_assurance_observation) automatically, with the question as its
--   source; later edits keep the finding in step; changing the answer back
--   withdraws the finding while it is still Open.
--
-- RULES
--   * Answers only while the execution is In Progress (scope frozen), and
--     only by its assigned auditor (the execution's owner_employee_id).
--   * The question must be in the execution's questions snapshot.
--   * The finding is made / edited / withdrawn through the existing
--     observation procedures (116a save, 108 soft delete), so its history,
--     gap detach and every Observations screen rule apply as they do for a
--     finding entered by hand. Type Finding, severity Medium (changed on the
--     Observations screen), reported by the auditor, owner = the answer's
--     owner, code <execution code>-<question code> (-2, -3 ... if that code
--     was used before -- withdrawn findings keep theirs).
--   * A finding past Open / In Review is no longer edited from here; once
--     past Open it cannot be withdrawn -- changing the answer is refused
--     (54045) so the answer never contradicts a finding being worked.
--
-- WHAT THIS DOES
--   1. NEW org_assurance_execution_response (one row per execution x
--      question; result, description, owner, current finding, who / when).
--   2. NEW sp_org_assurance_execution_response_list -- the execution's
--      questions (snapshot, in set / question order) with their answers and
--      findings, plus a summary row count per result.
--   3. NEW sp_org_assurance_execution_response_save -- answer one question;
--      raises / edits / withdraws the finding in the same transaction.
--
-- ERRORS: 54040 not In Progress; 54041 not the assigned auditor; 54042
--   question not in this execution; 54043 result invalid; 54044 Not
--   compliant needs a description and an owner; 54045 the finding is past
--   Open -- cannot be withdrawn; 54046 employee required.
-- DEPENDS ON: 555 (frozen scope / auditor), 116a observation save, 108
--   observation delete.
-- Rollback: 558_audit_question_responses_rollback.sql (drops the procedures;
--   the table is kept). Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_observation_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_observation_delete','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_observation','assigned_owner_role_id') IS NULL
BEGIN
    PRINT 'ABORT (558): run 555 (and 116a / 108) first. Nothing was changed.';
    RAISERROR('558_audit_question_responses: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Table
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_execution_response','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_execution_response(
        org_assurance_execution_response_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_oa_exec_response PRIMARY KEY,
        organization_id              BIGINT        NOT NULL,
        org_assurance_execution_id   BIGINT        NOT NULL,
        -- the question as the execution's snapshot has it
        question_id                  BIGINT        NOT NULL,
        question_code                NVARCHAR(120) NULL,
        question_text                NVARCHAR(MAX) NULL,
        question_set_code            NVARCHAR(120) NULL,
        result_code                  NVARCHAR(20)  NOT NULL,
        description                  NVARCHAR(MAX) NULL,
        owner_employee_id            BIGINT        NULL,
        owner_display_name           NVARCHAR(240) NULL,
        -- the finding this answer raised (null when none / withdrawn)
        org_assurance_observation_id BIGINT        NULL,
        answered_by                  NVARCHAR(100) NOT NULL,
        answered_dt                  DATETIME2     NOT NULL
            CONSTRAINT df_pm_oa_exec_resp_dt DEFAULT SYSUTCDATETIME(),
        updated_by                   NVARCHAR(100) NULL,
        updated_dt                   DATETIME2     NULL,
        CONSTRAINT fk_pm_oa_exec_resp_exec
            FOREIGN KEY(org_assurance_execution_id)
            REFERENCES grac_practice.org_assurance_execution(org_assurance_execution_id),
        CONSTRAINT fk_pm_oa_exec_resp_org
            FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_exec_resp_obs
            FOREIGN KEY(org_assurance_observation_id)
            REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
        CONSTRAINT ck_pm_oa_exec_resp_result
            CHECK (result_code IN (N'Compliant', N'NotCompliant', N'NotApplicable')),
        CONSTRAINT uq_pm_oa_exec_resp UNIQUE(org_assurance_execution_id, question_id)
    );
    PRINT '558.1: org_assurance_execution_response created.';
END
GO

-- =====================================================================
-- 2. sp_org_assurance_execution_response_list
--    Result 1: the questions (snapshot order) with answer and finding.
--    Result 2: count per result (NotAnswered included).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_response_list
    @organization_id BIGINT,
    @execution_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @qjson NVARCHAR(MAX);
    SELECT @qjson = e.questions_snapshot_json
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @@ROWCOUNT = 0
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF ISJSON(@qjson) <> 1 SET @qjson = N'[]';

    DECLARE @q TABLE (set_order INT NULL, question_set_code NVARCHAR(120) NULL, question_set_name NVARCHAR(300) NULL,
                      question_id BIGINT NULL, question_code NVARCHAR(120) NULL, question_text NVARCHAR(MAX) NULL,
                      help_text NVARCHAR(MAX) NULL, is_mandatory BIT NULL, display_order INT NULL,
                      evidence_type_name NVARCHAR(160) NULL, expected_evidence NVARCHAR(MAX) NULL);
    INSERT INTO @q
    SELECT j.SetOrder, j.QuestionSetCode, j.QuestionSetName, j.QuestionId, j.QuestionCode, j.QuestionText,
           j.HelpText, j.IsMandatory, j.DisplayOrder, j.EvidenceTypeName, j.ExpectedEvidence
      FROM OPENJSON(@qjson) WITH (
            SetOrder         INT            '$.SetOrder',
            QuestionSetCode  NVARCHAR(120)  '$.QuestionSetCode',
            QuestionSetName  NVARCHAR(300)  '$.QuestionSetName',
            QuestionId       BIGINT         '$.QuestionId',
            QuestionCode     NVARCHAR(120)  '$.QuestionCode',
            QuestionText     NVARCHAR(MAX)  '$.QuestionText',
            HelpText         NVARCHAR(MAX)  '$.HelpText',
            IsMandatory      BIT            '$.IsMandatory',
            DisplayOrder     INT            '$.DisplayOrder',
            EvidenceTypeName NVARCHAR(160)  '$.EvidenceTypeName',
            ExpectedEvidence NVARCHAR(MAX)  '$.ExpectedEvidence') j
     WHERE j.QuestionId IS NOT NULL;

    SELECT q.set_order AS SetOrder, q.question_set_code AS QuestionSetCode, q.question_set_name AS QuestionSetName,
           q.question_id AS QuestionId, q.question_code AS QuestionCode, q.question_text AS QuestionText,
           q.help_text AS HelpText, q.is_mandatory AS IsMandatory, q.display_order AS DisplayOrder,
           q.evidence_type_name AS EvidenceTypeName, q.expected_evidence AS ExpectedEvidence,
           r.result_code AS ResultCode, r.description AS Description,
           r.owner_employee_id AS OwnerEmployeeId, r.owner_display_name AS OwnerDisplayName,
           r.answered_by AS AnsweredBy, ISNULL(r.updated_dt, r.answered_dt) AS AnsweredDt,
           o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode,
           os.status_code AS ObservationStatusCode, os.status_name AS ObservationStatusName
      FROM @q q
      LEFT JOIN grac_practice.org_assurance_execution_response r
             ON r.org_assurance_execution_id = @execution_id
            AND r.question_id = q.question_id
      LEFT JOIN grac_practice.org_assurance_observation o
             ON o.org_assurance_observation_id = r.org_assurance_observation_id
            AND o.is_active = 1
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
     ORDER BY q.set_order, q.question_set_name, q.display_order, q.question_id;

    SELECT ISNULL(r.result_code, N'NotAnswered') AS ResultCode, COUNT(*) AS QuestionCount
      FROM @q q
      LEFT JOIN grac_practice.org_assurance_execution_response r
             ON r.org_assurance_execution_id = @execution_id
            AND r.question_id = q.question_id
     GROUP BY ISNULL(r.result_code, N'NotAnswered');
END
GO

-- =====================================================================
-- 3. sp_org_assurance_execution_response_save -- one question
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_response_save
    @organization_id   BIGINT,
    @execution_id      BIGINT,
    @question_id       BIGINT,
    @result_code       NVARCHAR(20),
    @description       NVARCHAR(MAX) = NULL,
    @owner_employee_id BIGINT        = NULL,
    @employee_id       BIGINT,                 -- the caller (session)
    @actor             NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @execution_id IS NULL OR @question_id IS NULL
        THROW 54009, 'organization_id, execution_id and question_id are required.', 1;
    IF @employee_id IS NULL
        THROW 54046, 'Sign in as the assigned auditor to answer.', 1;
    IF @result_code NOT IN (N'Compliant', N'NotCompliant', N'NotApplicable')
        THROW 54043, 'The answer must be Compliant, Not compliant or Not applicable.', 1;
    SET @description = NULLIF(LTRIM(RTRIM(@description)), N'');
    IF @result_code = N'NotCompliant' AND (@description IS NULL OR @owner_employee_id IS NULL)
        THROW 54044, 'A Not compliant answer needs a description and an owner.', 1;

    DECLARE @owner BIGINT, @status NVARCHAR(60), @qjson NVARCHAR(MAX),
            @exec_code NVARCHAR(120), @auditor_name NVARCHAR(240);
    SELECT @owner        = e.owner_employee_id,
           @status       = s.status_code,
           @qjson        = e.questions_snapshot_json,
           @exec_code    = e.execution_code,
           @auditor_name = e.owner_display_name
      FROM grac_practice.org_assurance_execution e
      JOIN grac_practice.org_assurance_execution_status_master s
           ON s.org_assurance_execution_status_id = e.execution_status_id
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @status IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @status <> N'InProgress'
        THROW 54040, 'Questions are answered while the audit is In Progress (after its scope is frozen).', 1;
    IF @owner IS NULL OR @owner <> @employee_id
        THROW 54041, 'Only the assigned auditor can answer the questions.', 1;

    DECLARE @q_code NVARCHAR(120), @q_text NVARCHAR(MAX), @q_set NVARCHAR(120);
    SELECT TOP 1 @q_code = j.QuestionCode, @q_text = j.QuestionText, @q_set = j.QuestionSetCode
      FROM OPENJSON(CASE WHEN ISJSON(@qjson) = 1 THEN @qjson ELSE N'[]' END) WITH (
            QuestionId      BIGINT        '$.QuestionId',
            QuestionCode    NVARCHAR(120) '$.QuestionCode',
            QuestionText    NVARCHAR(MAX) '$.QuestionText',
            QuestionSetCode NVARCHAR(120) '$.QuestionSetCode') j
     WHERE j.QuestionId = @question_id;
    IF @@ROWCOUNT = 0
        THROW 54042, 'The question is not part of this audit execution.', 1;

    DECLARE @owner_name NVARCHAR(240) = (SELECT employee_name FROM grac_practice.organization_employee
                                          WHERE employee_id = @owner_employee_id
                                            AND organization_id = @organization_id);
    IF @owner_employee_id IS NOT NULL AND @owner_name IS NULL
        THROW 54044, 'The owner must be an employee of this organization.', 1;
    DECLARE @resp_id BIGINT, @obs_id BIGINT, @obs_status NVARCHAR(60);
    SELECT @resp_id = r.org_assurance_execution_response_id,
           @obs_id  = o.org_assurance_observation_id,
           @obs_status = os.status_code
      FROM grac_practice.org_assurance_execution_response r
      LEFT JOIN grac_practice.org_assurance_observation o
             ON o.org_assurance_observation_id = r.org_assurance_observation_id
            AND o.is_active = 1
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
     WHERE r.org_assurance_execution_id = @execution_id
       AND r.question_id = @question_id;

    -- Withdrawing a finding that is being worked would leave the answer and
    -- the finding contradicting each other: refuse it.
    IF @result_code <> N'NotCompliant' AND @obs_id IS NOT NULL AND @obs_status NOT IN (N'Open', N'Rejected')
        THROW 54045, 'The finding raised from this question is past Open; the answer can no longer be changed to compliant here.', 1;

    DECLARE @title NVARCHAR(300) = LEFT(CONCAT(ISNULL(@q_code, N'Question'), N' - ', ISNULL(@q_text, N'')), 300);

    BEGIN TRAN;

    -- The finding first, so the answer row can point at it.
    IF @result_code = N'NotCompliant'
    BEGIN
        IF @obs_id IS NULL
        BEGIN
            -- <execution code>-<question code>; -2, -3 ... when used before
            -- (a withdrawn finding keeps its code; codes are unique per
            -- organization over every row).
            DECLARE @base NVARCHAR(110) = LEFT(CONCAT(@exec_code, N'-', ISNULL(@q_code, CONVERT(NVARCHAR(30), @question_id))), 110),
                    @code NVARCHAR(120), @k INT = 1;
            SET @code = @base;
            WHILE EXISTS (SELECT 1 FROM grac_practice.org_assurance_observation
                           WHERE organization_id = @organization_id AND observation_code = @code)
            BEGIN
                SET @k += 1;
                SET @code = CONCAT(@base, N'-', @k);
            END

            EXEC grac_practice.sp_org_assurance_observation_save
                 @organization_id             = @organization_id,
                 @observation_id              = NULL,
                 @execution_id                = @execution_id,
                 @observation_code            = @code,
                 @observation_title           = @title,
                 @observation_description     = @description,
                 @observation_type            = N'Finding',
                 @severity_code               = N'Medium',
                 @source_question_code        = @q_code,
                 @source_question_text        = @q_text,
                 @assigned_owner_employee_id  = @owner_employee_id,
                 @reported_by_employee_id     = @employee_id,
                 @reported_by_display_name    = @auditor_name,
                 @actor                       = @actor,
                 @observation_id_out          = @obs_id OUTPUT;
        END
        ELSE IF @obs_status IN (N'Open', N'InReview')
        BEGIN
            -- keep the finding in step; its own classification (type,
            -- severity, reviewer, due date) is left as it is.
            DECLARE @o_type NVARCHAR(30), @o_sev NVARCHAR(30), @o_rev BIGINT, @o_rev_name NVARCHAR(240),
                    @o_rev_role BIGINT, @o_rev_role_name NVARCHAR(120), @o_due DATE, @o_obs_dt DATETIME2,
                    @o_rep BIGINT, @o_rep_name NVARCHAR(240);
            SELECT @o_type = observation_type, @o_sev = severity_code,
                   @o_rev = assigned_reviewer_employee_id, @o_rev_name = assigned_reviewer_display_name,
                   @o_rev_role = assigned_reviewer_role_id, @o_rev_role_name = assigned_reviewer_role_name,
                   @o_due = due_date, @o_obs_dt = observed_dt,
                   @o_rep = reported_by_employee_id, @o_rep_name = reported_by_display_name
              FROM grac_practice.org_assurance_observation
             WHERE org_assurance_observation_id = @obs_id;

            EXEC grac_practice.sp_org_assurance_observation_save
                 @organization_id                = @organization_id,
                 @observation_id                 = @obs_id,
                 @execution_id                   = @execution_id,
                 @observation_title              = @title,
                 @observation_description        = @description,
                 @observation_type               = @o_type,
                 @severity_code                  = @o_sev,
                 @source_question_code           = @q_code,
                 @source_question_text           = @q_text,
                 @assigned_owner_employee_id     = @owner_employee_id,
                 @assigned_reviewer_employee_id  = @o_rev,
                 @assigned_reviewer_display_name = @o_rev_name,
                 @assigned_reviewer_role_id      = @o_rev_role,
                 @assigned_reviewer_role_name    = @o_rev_role_name,
                 @reported_by_employee_id        = @o_rep,
                 @reported_by_display_name       = @o_rep_name,
                 @observed_dt                    = @o_obs_dt,
                 @due_date                       = @o_due,
                 @actor                          = @actor,
                 @observation_id_out             = @obs_id OUTPUT;
        END
        -- past In Review: the finding is being worked; the answer is saved,
        -- the finding is left as it is.
    END
    ELSE IF @obs_id IS NOT NULL
    BEGIN
        -- Compliant / Not applicable: withdraw the Open (or Rejected) finding.
        EXEC grac_practice.sp_org_assurance_observation_delete
             @organization_id = @organization_id,
             @observation_id  = @obs_id,
             @actor           = @actor;
        SET @obs_id = NULL;
    END

    IF @resp_id IS NULL
        INSERT INTO grac_practice.org_assurance_execution_response
            (organization_id, org_assurance_execution_id, question_id, question_code, question_text,
             question_set_code, result_code, description, owner_employee_id, owner_display_name,
             org_assurance_observation_id, answered_by)
        VALUES
            (@organization_id, @execution_id, @question_id, @q_code, @q_text,
             @q_set, @result_code, @description, @owner_employee_id, @owner_name,
             @obs_id, @actor);
    ELSE
        UPDATE grac_practice.org_assurance_execution_response
           SET result_code                  = @result_code,
               description                  = @description,
               owner_employee_id            = @owner_employee_id,
               owner_display_name           = @owner_name,
               org_assurance_observation_id = @obs_id,
               updated_by                   = @actor,
               updated_dt                   = SYSUTCDATETIME()
         WHERE org_assurance_execution_response_id = @resp_id;

    COMMIT;

    SELECT @question_id AS QuestionId, @result_code AS ResultCode,
           o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode,
           os.status_code AS ObservationStatusCode, os.status_name AS ObservationStatusName
      FROM (SELECT 1 AS x) d
      LEFT JOIN grac_practice.org_assurance_observation o
             ON o.org_assurance_observation_id = @obs_id
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '558 table and procedures' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_execution_response','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_response_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_response_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '558 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
