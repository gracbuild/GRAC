-- =====================================================================
-- 483 Complete Task: the three evidence options for "Other evidence" too
--
-- Change request 2026-10-23 (sir), after 482: the dialog's general
-- evidence section ("Other evidence") also asks how the evidence is
-- provided -- Direct Upload / Evidence Center Reference / External
-- Evidence Reference -- and shows only that option's control. Direct
-- Upload and Evidence Center keep working exactly as before (general task
-- links, evidence_link.instance_evidence_id NULL). External needs a place
-- to live, so:
--
--   1. practice_task_evidence_response.evidence_id becomes NULLable.
--      NULL = the task's general evidence. uq_pm_task_evidence_response
--      (task_id, evidence_id) is re-created over the nullable column, so a
--      task still has at most ONE general row.
--   2. sp_task_evidence_response_save (482 body): an item with no
--      evidenceId is the general row; it is not checked against the
--      recurring evidence list.
--   3. sp_task_recurring_evidence_list (482 body): + result 2, the
--      general row (EvidenceSource, EvidenceLocation, EvidenceLocator) --
--      at most one row, none when nothing is recorded.
--
-- DEPENDS ON: 482.  Rollback: 483_task_general_evidence_options_rollback.sql
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_task_evidence_response','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_recurring_evidence_list','P') IS NULL
BEGIN
    RAISERROR('483 ABORT: practice_task_evidence_response / sp_task_recurring_evidence_list missing -- run 482 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. evidence_id NULLable (constraint dropped and re-created around it)
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.practice_task_evidence_response')
              AND name = 'evidence_id' AND is_nullable = 0)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.key_constraints
                WHERE name = 'uq_pm_task_evidence_response'
                  AND parent_object_id = OBJECT_ID('grac_practice.practice_task_evidence_response'))
        ALTER TABLE grac_practice.practice_task_evidence_response DROP CONSTRAINT uq_pm_task_evidence_response;
    ALTER TABLE grac_practice.practice_task_evidence_response ALTER COLUMN evidence_id BIGINT NULL;
    PRINT '483: practice_task_evidence_response.evidence_id is NULLable (NULL = general task evidence).';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
                WHERE name = 'uq_pm_task_evidence_response'
                  AND parent_object_id = OBJECT_ID('grac_practice.practice_task_evidence_response'))
    ALTER TABLE grac_practice.practice_task_evidence_response
        ADD CONSTRAINT uq_pm_task_evidence_response UNIQUE (task_id, evidence_id);
GO

-- =====================================================================
-- 2. sp_task_evidence_response_save (482 body; general row)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_evidence_response_save
    @task_id             BIGINT,
    @organization_id     BIGINT,
    @payload_json        NVARCHAR(MAX),
    @caller_employee_id  BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL OR @organization_id IS NULL
        THROW 52921, 'Organization and task are both required.', 1;

    DECLARE @closed_at DATETIME2, @found BIT = 0;
    SELECT @found = 1, @closed_at = t.closed_at
    FROM   grac_practice.practice_task t
    WHERE  t.task_id = @task_id AND t.organization_id = @organization_id;
    IF @found = 0
        THROW 52922, 'That task was not found in this organization.', 1;
    IF @closed_at IS NOT NULL
        THROW 52923, 'This task is already completed. Its evidence can no longer be changed.', 1;
    IF ISJSON(ISNULL(@payload_json, N'')) = 0
        THROW 52926, 'The evidence details could not be read.', 1;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @caller_display_name = ISNULL(NULLIF(LTRIM(RTRIM(@caller_display_name)), N''), N'system');

    -- 483: evidence_id NULL = the general row; item_key = ISNULL(evidence_id, 0).
    DECLARE @items TABLE (item_key BIGINT NOT NULL PRIMARY KEY, evidence_id BIGINT NULL, evidence_source NVARCHAR(30) NULL,
                          evidence_location NVARCHAR(500) NULL, evidence_locator NVARCHAR(500) NULL);
    INSERT @items (item_key, evidence_id, evidence_source, evidence_location, evidence_locator)
    SELECT ISNULL(j.evidenceId, 0), NULLIF(j.evidenceId, 0),
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceSource)), N'')),
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceLocation)), N'')),
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceLocator)), N''))
    FROM   OPENJSON(@payload_json)
           WITH (evidenceId       BIGINT        '$.evidenceId',
                 evidenceSource   NVARCHAR(30)  '$.evidenceSource',
                 evidenceLocation NVARCHAR(500) '$.evidenceLocation',
                 evidenceLocator  NVARCHAR(500) '$.evidenceLocator') j
    GROUP  BY ISNULL(j.evidenceId, 0), NULLIF(j.evidenceId, 0);

    -- No option chosen = nothing to record for that row.
    DELETE @items WHERE evidence_source IS NULL;

    IF EXISTS (SELECT 1 FROM @items
                WHERE evidence_source NOT IN (N'DirectUpload', N'EvidenceCenter', N'External'))
        THROW 52924, 'Choose how the evidence is provided: Direct Upload, Evidence Center Reference or External Evidence Reference.', 1;
    IF EXISTS (SELECT 1 FROM @items i
                WHERE i.evidence_id IS NOT NULL   -- 483: the general row is not on that list
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(@task_id) r
                                   WHERE r.evidence_id = i.evidence_id))
        THROW 52925, 'That evidence is not asked for on this task.', 1;

    DECLARE @saved TABLE (task_evidence_response_id BIGINT, evidence_id BIGINT, action_type NVARCHAR(10));

    BEGIN TRAN;

    MERGE grac_practice.practice_task_evidence_response AS target
    USING @items AS src
       ON target.task_id = @task_id AND ISNULL(target.evidence_id, 0) = src.item_key   -- 483
    WHEN MATCHED THEN UPDATE SET
         evidence_source   = src.evidence_source,
         evidence_location = CASE WHEN src.evidence_source = N'External' THEN src.evidence_location ELSE target.evidence_location END,
         evidence_locator  = CASE WHEN src.evidence_source = N'External' THEN src.evidence_locator  ELSE target.evidence_locator  END,
         updated_by        = @caller_display_name,
         updated_dt        = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
         (organization_id, task_id, evidence_id, evidence_source, evidence_location, evidence_locator,
          entered_by_employee_id, entered_by)
    VALUES
         (@organization_id, @task_id, src.evidence_id, src.evidence_source,
          CASE WHEN src.evidence_source = N'External' THEN src.evidence_location END,
          CASE WHEN src.evidence_source = N'External' THEN src.evidence_locator END,
          @caller_employee_id, @caller_display_name)
    OUTPUT inserted.task_evidence_response_id, inserted.evidence_id,
           CASE WHEN $action = N'INSERT' THEN N'CREATE' ELSE N'UPDATE' END
      INTO @saved (task_evidence_response_id, evidence_id, action_type);

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'task-evidence-response', s.task_evidence_response_id, s.action_type, NULL,
           (SELECT @task_id AS taskId, r.evidence_id AS evidenceId, r.evidence_source AS evidenceSource,
                   r.evidence_location AS evidenceLocation, r.evidence_locator AS evidenceLocator
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @caller_display_name
    FROM   @saved s
    JOIN   grac_practice.practice_task_evidence_response r
           ON r.task_evidence_response_id = s.task_evidence_response_id;

    COMMIT;

    SELECT (SELECT COUNT(*) FROM @saved) AS SavedCount,
           N'Evidence details saved.' AS Message;
END
GO


-- =====================================================================
-- 3. sp_task_recurring_evidence_list (482 body; + result 2, the general row)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_recurring_evidence_list
    @task_id         BIGINT,
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL OR @organization_id IS NULL
        THROW 52921, 'Organization and task are both required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task t
                    WHERE t.task_id = @task_id AND t.organization_id = @organization_id)
        THROW 52922, 'That task was not found in this organization.', 1;

    SELECT r.evidence_id                AS EvidenceId,
           COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''), et.evidence_type_name, N'Evidence') AS EvidenceName,
           pie.evidence_type_id         AS EvidenceTypeId,
           et.evidence_type_name        AS EvidenceType,
           pie.evidence_description     AS EvidenceDescription,
           r.obligation_name            AS ObligationName,
           resp.evidence_source         AS EvidenceSource,
           resp.evidence_location       AS EvidenceLocation,
           resp.evidence_locator        AS EvidenceLocator,
           lk.FileCount                 AS FileCount,
           -- Provided for this occurrence, under the 481 rule: External =
           -- location and locator; the other two = a file linked to it.
           CAST(CASE WHEN resp.evidence_source = N'External'
                      AND NULLIF(LTRIM(RTRIM(ISNULL(resp.evidence_location, N''))), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(ISNULL(resp.evidence_locator,  N''))), N'') IS NOT NULL THEN 1
                     WHEN ISNULL(resp.evidence_source, N'') <> N'External' AND lk.FileCount > 0 THEN 1
                     ELSE 0 END AS BIT) AS IsProvided
    FROM   grac_practice.fn_pm_task_recurring_evidence(@task_id) r
    JOIN   grac_practice.practice_instance_evidence pie ON pie.evidence_id = r.evidence_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = pie.evidence_type_id
    LEFT   JOIN grac_practice.practice_task_evidence_response resp
           ON resp.task_id = @task_id AND resp.evidence_id = r.evidence_id
    OUTER  APPLY (SELECT COUNT(*) AS FileCount
                  FROM   grac_practice.evidence_link l
                  WHERE  l.target_type = N'Task' AND l.target_id = @task_id
                    AND  l.instance_evidence_id = r.evidence_id AND l.status = N'Active') lk
    WHERE  r.organization_id = @organization_id
    ORDER  BY r.obligation_name,
              COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''), et.evidence_type_name);

    -- 483: result 2 -- the task's general evidence ("Other evidence"),
    -- the row with no evidence_id. At most one; none when nothing chosen.
    SELECT resp.evidence_source   AS EvidenceSource,
           resp.evidence_location AS EvidenceLocation,
           resp.evidence_locator  AS EvidenceLocator
    FROM   grac_practice.practice_task_evidence_response resp
    WHERE  resp.task_id = @task_id
      AND  resp.evidence_id IS NULL;
END
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
SELECT '483 evidence_id nullable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.practice_task_evidence_response')
                            AND name = 'evidence_id' AND is_nullable = 1)
             AND EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_task_evidence_response'
                            AND parent_object_id = OBJECT_ID('grac_practice.practice_task_evidence_response'))
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '483 procedures handle the general row',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_evidence_response_save')) LIKE '%general%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_recurring_evidence_list')) LIKE '%evidence_id IS NULL%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '483 complete. Deploy API + Web next.';
GO

SET NOEXEC OFF;
GO
