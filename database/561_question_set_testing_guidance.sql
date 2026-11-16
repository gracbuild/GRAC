-- =====================================================================
-- 561  Question Sets -- Testing Guidance and question Status
--      (Audit Change spec 4.2.3, P0 phase B)
--
-- REQUEST (2026-11-15, sir): phase B of docs/audit-change-p0-plan.md.
--   Each question carries: Question Code, Question, Response Type,
--   Mandatory, Weight, Testing Guidance, Expected Evidence, Status
--   (Active / Inactive). Testing Guidance is THE field for test
--   procedures -- simple instructions or detailed step-by-step procedures;
--   no separate Test Procedure master.
--
-- WHAT IS ALREADY IN PLACE (no change here)
--   * Testing Guidance = org_assurance_question.help_text (NVARCHAR(MAX),
--     077); Api field HelpText. The page only relabels it.
--   * Status = org_assurance_question.status, Active / Inactive (520),
--     saved by sp_org_assurance_question_set_questions_save (551).
--   * An Inactive question is already left out when an execution takes
--     its questions snapshot (sp_org_assurance_execution_materialize, 555:
--     ISNULL(q.status, N'Active') = N'Active').
--
-- WHAT THIS DOES
--   sp_org_assurance_question_set_list (551 body) -- Questions, Mandatory
--   and Total Weight count only Active questions (the ones an audit uses);
--   an Inactive question was counted before.
--
-- DEPENDS ON: 551, 520 (status column).
-- Rollback: 561_question_set_testing_guidance_rollback.sql (551 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_question','status') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question_set','root_question_set_id') IS NULL
BEGIN
    PRINT 'ABORT (561): run 520 and 551 first. Nothing was changed.';
    RAISERROR('561_question_set_testing_guidance: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53801, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND ISNULL(q.status, N'Active') = N'Active' /* 561: questions in use */) AS question_count
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          -- 551: one row per set -- its latest version.
          AND qs.version_number = (SELECT MAX(x.version_number)
                                     FROM grac_practice.org_assurance_question_set x
                                    WHERE x.root_question_set_id = qs.root_question_set_id
                                      AND x.is_active = 1)
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               qs.root_question_set_id,
               qs.version_number,
               qs.version_status,
               (SELECT MAX(a.version_number) FROM grac_practice.org_assurance_question_set a
                 WHERE a.root_question_set_id = qs.root_question_set_id AND a.is_active = 1
                   AND a.version_status = N'Active') AS active_version_number,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND ISNULL(q.status, N'Active') = N'Active' /* 561: questions in use */) AS question_count,
               -- 535: same rows as question_count (is_active = 1).
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND ISNULL(q.status, N'Active') = N'Active' /* 561: questions in use */
                   AND q.is_mandatory = 1) AS mandatory_count,
               (SELECT ISNULL(SUM(q.weight), 0)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND ISNULL(q.status, N'Active') = N'Active' /* 561: questions in use */) AS total_weight
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          -- 551: one row per set -- its latest version.
          AND qs.version_number = (SELECT MAX(x.version_number)
                                     FROM grac_practice.org_assurance_question_set x
                                    WHERE x.root_question_set_id = qs.root_question_set_id
                                      AND x.is_active = 1)
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_question_set_id AS QuestionSetId,
           organization_id               AS OrganizationId,
           set_code                      AS SetCode,
           set_name                      AS SetName,
           description                   AS Description,
           owner_employee_id             AS OwnerEmployeeId,
           owner_display_name            AS OwnerDisplayName,
           status                        AS Status,
           question_count                AS QuestionCount,
           mandatory_count               AS MandatoryCount,   -- 535
           total_weight                  AS TotalWeight,      -- 535
           root_question_set_id          AS RootQuestionSetId,    -- 551
           version_number                AS VersionNumber,        -- 551
           version_status                AS VersionStatus,        -- 551
           active_version_number         AS ActiveVersionNumber,  -- 551
           entered_dt                    AS EnteredDt,
           updated_dt                    AS UpdatedDt
    FROM base
    ORDER BY set_name, org_assurance_question_set_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '561 sp_org_assurance_question_set_list: counts Active questions only.';
GO
SET NOEXEC OFF;
GO
