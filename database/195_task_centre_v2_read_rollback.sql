-- =====================================================================
-- 195 Task Centre v2 — read layer ROLLBACK
--
-- Drops the two NEW read procs and RESTORES the three objects 195
-- rewrote to their pre-192 definitions, so the Task Center keeps
-- rendering after a rollback:
--
--   vw_pm_practice_task     -> the 048 shape
--   sp_task_list            -> the 037 shape
--   sp_task_center_counts   -> the 049 shape
--
-- Run this FIRST when unwinding the phase (195 -> 194 -> 193 -> 192):
-- the restored view and list proc reference only pre-192 columns, so the
-- later column drops in 192's rollback cannot fail on a dependency.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '195-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Drop the procs 195 introduced
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_source_tasks','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_source_tasks;
IF OBJECT_ID('grac_practice.sp_task_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_get;
GO

-- ---------------------------------------------------------------------
-- 2. Restore vw_pm_practice_task to the 048 definition
--     (sp_executesql for the same deferred-parse reason as 048/195)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NOT NULL
    DROP VIEW grac_practice.vw_pm_practice_task;
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.task_type_master','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE VIEW grac_practice.vw_pm_practice_task AS
SELECT t.task_id,
       t.task_number,
       t.organization_id,
       t.task_type_id,
       tt.type_code                            AS task_type_code,
       tt.type_name                            AS task_type_name,
       t.subject_entity_type,
       t.subject_entity_id,
       t.linked_release_id,
       t.linked_control_id,
       t.linked_practice_id,
       t.linked_instance_id,
       t.related_entity_type_id,
       ret.entity_code                         AS related_entity_type_code,
       ret.entity_name                         AS related_entity_type_name,
       t.related_record_id,
       t.assurance_activity_id,
       t.workflow_id,
       t.current_workflow_stage_id,
       t.subject_title,
       t.subject_description,
       t.assigned_to_employee_id,
       t.current_status_id,
       s.status_code                           AS current_status_code,
       s.status_name                           AS current_status_name,
       s.is_terminal                           AS current_status_is_terminal,
       t.priority,
       t.criticality,
       t.origin_code,
       t.start_date,
       t.sla_due_at,
       CASE
         WHEN t.sla_due_at IS NULL THEN NULL
         WHEN s.is_terminal = 1 THEN NULL
         WHEN SYSUTCDATETIME() > t.sla_due_at THEN 1
         ELSE 0
       END                                     AS is_overdue,
       t.escalated_at,
       t.reason_code,
       t.reason_text,
       t.correlation_id,
       t.closed_at,
       t.entered_by, t.entered_dt, t.updated_by, t.updated_dt
FROM grac_practice.practice_task t
JOIN grac_practice.task_type_master tt      ON tt.task_type_id      = t.task_type_id
JOIN grac_practice.entity_status_master s   ON s.entity_status_id   = t.current_status_id
LEFT JOIN grac_practice.related_entity_type_master ret ON ret.related_entity_type_id = t.related_entity_type_id;';
END
GO

-- ---------------------------------------------------------------------
-- 3. Restore sp_task_list to the 037 definition
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id      BIGINT       = NULL,
    @assigned_to_employee_id BIGINT   = NULL,
    @task_type_code       NVARCHAR(60) = NULL,
    @status_code          NVARCHAR(60) = NULL,      -- 'OpenSet' for non-terminal, else specific
    @overdue_only         BIT          = 0,
    @search               NVARCHAR(200) = NULL,
    @page                 INT          = 1,
    @page_size            INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT v.*
        FROM grac_practice.vw_pm_practice_task v
        WHERE (@organization_id IS NULL OR v.organization_id = @organization_id)
          AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
          AND (@task_type_code IS NULL OR v.task_type_code = @task_type_code)
          AND (
                @status_code IS NULL
             OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
             OR v.current_status_code = @status_code
              )
          AND (@overdue_only = 0 OR v.is_overdue = 1)
          AND (@search IS NULL
               OR v.subject_title LIKE N'%' + @search + N'%'
               OR v.subject_description LIKE N'%' + @search + N'%')
    )
    SELECT
        (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
        @page      AS PageNumber,
        @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT v.*
        FROM grac_practice.vw_pm_practice_task v
        WHERE (@organization_id IS NULL OR v.organization_id = @organization_id)
          AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
          AND (@task_type_code IS NULL OR v.task_type_code = @task_type_code)
          AND (
                @status_code IS NULL
             OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
             OR v.current_status_code = @status_code
              )
          AND (@overdue_only = 0 OR v.is_overdue = 1)
          AND (@search IS NULL
               OR v.subject_title LIKE N'%' + @search + N'%'
               OR v.subject_description LIKE N'%' + @search + N'%')
    )
    SELECT *
    FROM filtered
    ORDER BY CASE WHEN sla_due_at IS NULL THEN 1 ELSE 0 END,
             sla_due_at ASC,
             task_id DESC
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END;
GO

-- ---------------------------------------------------------------------
-- 4. Restore sp_task_center_counts to the 049 definition
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_instance pi
           LEFT JOIN grac_practice.implementation_status_master ims
                  ON ims.implementation_status_id = pi.implementation_status_id
          WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
            AND COALESCE(ims.status_code, pi.implementation_status)
                IN (N'Not Implemented', N'Partially Implemented')) AS GapsCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Implementation') AS ImplementationCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Assurance') AS AssuranceCount,

        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Custom') AS CustomCount;
END;
GO

PRINT '195 Task Centre v2 read layer rolled back; 037/048/049 shapes restored.';
GO

SET NOEXEC OFF;
GO
