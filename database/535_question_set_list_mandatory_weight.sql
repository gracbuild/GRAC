-- =====================================================================
-- 535  Question Sets list: mandatory question count and total weight
--
-- REQUEST (2026-11-13, sir)
--   Audit -> Question Sets list: show how many of each set's questions are
--   mandatory, and the set's total weightage, beside Questions.
--
-- WHAT THIS DOES
--   Re-issues sp_org_assurance_question_set_list from its 077 body with
--   two more columns on the page rows (result set 2):
--     MandatoryCount  questions with is_mandatory = 1
--     TotalWeight     SUM(weight), 0 when no question has a weight
--   Both count the same questions QuestionCount counts (is_active = 1,
--   i.e. every question still in the set, whatever its Status). Nothing
--   else changes: parameters, paging, ordering and result set 1.
--
-- No table change. Rollback: 535_question_set_list_mandatory_weight_rollback.sql
-- (the 077 body). Requires 076 / 077. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_list','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question','is_mandatory') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question','weight') IS NULL
BEGIN
    PRINT 'ABORT (535): run 076 / 077 first. Nothing was changed.';
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
                   AND q.is_active = 1) AS question_count
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
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
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count,
               -- 535: same rows as question_count (is_active = 1).
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND q.is_mandatory = 1) AS mandatory_count,
               (SELECT ISNULL(SUM(q.weight), 0)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS total_weight
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
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
           entered_dt                    AS EnteredDt,
           updated_dt                    AS UpdatedDt
    FROM base
    ORDER BY set_name, org_assurance_question_set_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

SELECT '535 sp_org_assurance_question_set_list returns MandatoryCount / TotalWeight' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_question_set_list')) LIKE '%MandatoryCount%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_question_set_list')) LIKE '%TotalWeight%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '535 complete. Restart the Api, deploy Web.';
GO
SET NOEXEC OFF;
GO
