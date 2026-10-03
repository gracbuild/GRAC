-- =====================================================================
-- 388_gap_exception_practice_instance_mapping.sql
--
-- CHANGE REQUEST 2026-09-27 (follow-up to 387): "map practice INSTANCE,
-- not practice -- everywhere the Practice Picker is used". 387 made the
-- picker end at the instance level and made Risk store it. This
-- migration does the same for the other two callers of the picker:
--
--   Gap Register     -> Add Custom Gap -> Map practice   (382 table)
--   Exceptions       -> Add Custom Exception -> practice (328 table)
--
-- WHAT THIS ADDS
--   1. custom_gap_practice_map and exception_request_practice gain
--      practice_instance_id (FK practice_instance), frozen
--      practice_instance_name / _code, and a computed
--      practice_instance_key. The old one-row-per-practice uniques
--      become one row per (entity, practice, instance).
--      practice_id stays populated (from the instance), so every
--      existing reader keeps working unchanged.
--   2. sp_custom_gap_practice_instance_set /
--      sp_exception_request_practice_instance_set -- given a JSON array
--      of practice_instance_ids, record them against the gap/exception.
--      A practice-level row (instance NULL) written by the create proc
--      for the same practice is CLAIMED (updated in place) rather than
--      duplicated; further instances of that practice get their own row.
--      Called by the API straight after the create procs, which are NOT
--      re-issued (their practice-level insert is unchanged).
--   3. sp_custom_gap_practice_map_list / sp_exception_request_practice_list
--      re-issued with the instance columns.
--   4. sp_risk_treatment_state re-issued (387 body): a mapped instance's
--      gap tasks now also include Custom Gaps MAPPED to that instance
--      (custom_gap_practice_map), not only gaps whose source reference
--      is the instance.
--   5. Backfill (user decision: "migrate old maps to instance"): each
--      practice-level row claims the practice's first active instance;
--      every other active instance of that practice gets its own row --
--      the same rule 387 applied to risk_practice_map. A practice with
--      no active instance stays practice-level.
--
-- Idempotent / SAFE TO RE-RUN. ASCII-only.
-- Requires 328, 382, 387.
-- Rollback: 388_gap_exception_practice_instance_mapping_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.custom_gap_practice_map','U') IS NULL
BEGIN PRINT 'ABORT (388): custom_gap_practice_map missing (run 382).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.exception_request_practice','U') IS NULL
BEGIN PRINT 'ABORT (388): exception_request_practice missing (run 328).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN PRINT 'ABORT (388): practice_instance missing.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NULL
BEGIN PRINT 'ABORT (388): risk_practice_map.practice_instance_id missing (run 387).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NULL
BEGIN PRINT 'ABORT (388): risk_treatment_task_link missing (run 387).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('388_gap_exception_practice_instance_mapping: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1a. custom_gap_practice_map: instance columns
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NULL
    ALTER TABLE grac_practice.custom_gap_practice_map
        ADD practice_instance_id BIGINT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id);
GO
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_name') IS NULL
    ALTER TABLE grac_practice.custom_gap_practice_map ADD practice_instance_name NVARCHAR(300) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_code') IS NULL
    ALTER TABLE grac_practice.custom_gap_practice_map ADD practice_instance_code NVARCHAR(100) NULL;
GO
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_key') IS NULL
    ALTER TABLE grac_practice.custom_gap_practice_map
        ADD practice_instance_key AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED;
GO
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_custom_gap_practice'
              AND parent_object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    ALTER TABLE grac_practice.custom_gap_practice_map DROP CONSTRAINT uq_pm_custom_gap_practice;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_custom_gap_practice_instance'
                  AND object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    CREATE UNIQUE INDEX ux_pm_custom_gap_practice_instance
        ON grac_practice.custom_gap_practice_map(custom_gap_id, practice_id, practice_instance_key);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_custom_gap_practice_map_instance'
                  AND object_id = OBJECT_ID('grac_practice.custom_gap_practice_map'))
    CREATE INDEX ix_pm_custom_gap_practice_map_instance
        ON grac_practice.custom_gap_practice_map(practice_instance_id)
        INCLUDE (custom_gap_id, record_status_id);
GO
PRINT '388: custom_gap_practice_map is instance-aware.';
GO

-- =====================================================================
-- 1b. exception_request_practice: instance columns
-- =====================================================================
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_id') IS NULL
    ALTER TABLE grac_practice.exception_request_practice
        ADD practice_instance_id BIGINT NULL
            CONSTRAINT fk_pm_exception_request_practice_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id);
GO
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_name') IS NULL
    ALTER TABLE grac_practice.exception_request_practice ADD practice_instance_name NVARCHAR(300) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_code') IS NULL
    ALTER TABLE grac_practice.exception_request_practice ADD practice_instance_code NVARCHAR(100) NULL;
GO
IF COL_LENGTH('grac_practice.exception_request_practice','practice_instance_key') IS NULL
    ALTER TABLE grac_practice.exception_request_practice
        ADD practice_instance_key AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED;
GO
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_exception_request_practice'
              AND parent_object_id = OBJECT_ID('grac_practice.exception_request_practice'))
    ALTER TABLE grac_practice.exception_request_practice DROP CONSTRAINT uq_pm_exception_request_practice;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_practice_instance'
                  AND object_id = OBJECT_ID('grac_practice.exception_request_practice'))
    CREATE UNIQUE INDEX ux_pm_exception_request_practice_instance
        ON grac_practice.exception_request_practice(exception_request_id, practice_id, practice_instance_key);
GO
PRINT '388: exception_request_practice is instance-aware.';
GO

-- =====================================================================
-- 2a. sp_custom_gap_practice_instance_set
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_practice_instance_set
    @custom_gap_id               BIGINT,
    @practice_instance_ids_json  NVARCHAR(MAX),
    @actor_employee_id           BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 56780, 'sp_custom_gap_practice_instance_set: custom_gap_id is required.', 1;

    DECLARE @org_id BIGINT =
        (SELECT organization_id FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id);
    IF @org_id IS NULL
        THROW 56781, 'sp_custom_gap_practice_instance_set: custom gap not found.', 1;

    IF @practice_instance_ids_json IS NULL OR ISJSON(@practice_instance_ids_json) <> 1
        RETURN;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- Only instances of this organization; anything else is dropped
    -- quietly, the same choice 382/328 make for practice ids.
    DECLARE @inst TABLE(practice_instance_id BIGINT PRIMARY KEY, practice_id BIGINT,
                        instance_name NVARCHAR(300), instance_code NVARCHAR(100));
    INSERT @inst
    SELECT DISTINCT pi.practice_instance_id, pi.practice_id, pi.instance_name, pi.instance_code
      FROM OPENJSON(@practice_instance_ids_json) WITH (practice_instance_id BIGINT N'$') j
      JOIN grac_practice.practice_instance pi
        ON pi.practice_instance_id = j.practice_instance_id
       AND pi.organization_id      = @org_id;

    DECLARE @iid BIGINT, @pid BIGINT, @iname NVARCHAR(300), @icode NVARCHAR(100), @claim BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT practice_instance_id, practice_id, instance_name, instance_code FROM @inst;
    OPEN c;
    FETCH NEXT FROM c INTO @iid, @pid, @iname, @icode;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap_practice_map
                        WHERE custom_gap_id = @custom_gap_id AND practice_instance_id = @iid)
        BEGIN
            SET @claim = NULL;
            SELECT TOP 1 @claim = custom_gap_practice_map_id
              FROM grac_practice.custom_gap_practice_map
             WHERE custom_gap_id = @custom_gap_id AND practice_id = @pid
               AND practice_instance_id IS NULL
             ORDER BY custom_gap_practice_map_id;

            IF @claim IS NOT NULL
                UPDATE grac_practice.custom_gap_practice_map
                   SET practice_instance_id   = @iid,
                       practice_instance_name = @iname,
                       practice_instance_code = @icode
                 WHERE custom_gap_practice_map_id = @claim;
            ELSE
                INSERT INTO grac_practice.custom_gap_practice_map
                    (organization_id, custom_gap_id, practice_id, practice_name, practice_code,
                     practice_instance_id, practice_instance_name, practice_instance_code,
                     mapped_by_employee_id, record_status_id, mapped_dt)
                SELECT @org_id, @custom_gap_id, p.practice_id, p.practice_name, p.practice_code,
                       @iid, @iname, @icode,
                       @actor_employee_id, @active_rs, SYSUTCDATETIME()
                  FROM grac_practice.practice p
                 WHERE p.practice_id = @pid;
        END
        FETCH NEXT FROM c INTO @iid, @pid, @iname, @icode;
    END
    CLOSE c; DEALLOCATE c;
END
GO
PRINT '388: sp_custom_gap_practice_instance_set created.';
GO

-- =====================================================================
-- 2b. sp_exception_request_practice_instance_set
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_practice_instance_set
    @exception_request_id        BIGINT,
    @practice_instance_ids_json  NVARCHAR(MAX),
    @actor_employee_id           BIGINT        = NULL,
    @caller_display_name         NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 56782, 'sp_exception_request_practice_instance_set: exception_request_id is required.', 1;

    DECLARE @org_id BIGINT =
        (SELECT organization_id FROM grac_practice.exception_request
          WHERE exception_request_id = @exception_request_id);
    IF @org_id IS NULL
        THROW 56783, 'sp_exception_request_practice_instance_set: exception request not found.', 1;

    IF @practice_instance_ids_json IS NULL OR ISJSON(@practice_instance_ids_json) <> 1
        RETURN;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @inst TABLE(practice_instance_id BIGINT PRIMARY KEY, practice_id BIGINT,
                        instance_name NVARCHAR(300), instance_code NVARCHAR(100));
    INSERT @inst
    SELECT DISTINCT pi.practice_instance_id, pi.practice_id, pi.instance_name, pi.instance_code
      FROM OPENJSON(@practice_instance_ids_json) WITH (practice_instance_id BIGINT N'$') j
      JOIN grac_practice.practice_instance pi
        ON pi.practice_instance_id = j.practice_instance_id
       AND pi.organization_id      = @org_id;

    DECLARE @iid BIGINT, @pid BIGINT, @iname NVARCHAR(300), @icode NVARCHAR(100), @claim BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT practice_instance_id, practice_id, instance_name, instance_code FROM @inst;
    OPEN c;
    FETCH NEXT FROM c INTO @iid, @pid, @iname, @icode;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.exception_request_practice
                        WHERE exception_request_id = @exception_request_id AND practice_instance_id = @iid)
        BEGIN
            SET @claim = NULL;
            SELECT TOP 1 @claim = exception_request_practice_id
              FROM grac_practice.exception_request_practice
             WHERE exception_request_id = @exception_request_id AND practice_id = @pid
               AND practice_instance_id IS NULL
             ORDER BY exception_request_practice_id;

            IF @claim IS NOT NULL
                UPDATE grac_practice.exception_request_practice
                   SET practice_instance_id   = @iid,
                       practice_instance_name = @iname,
                       practice_instance_code = @icode
                 WHERE exception_request_practice_id = @claim;
            ELSE
                INSERT INTO grac_practice.exception_request_practice
                    (organization_id, exception_request_id, practice_id, practice_name, practice_code,
                     practice_instance_id, practice_instance_name, practice_instance_code,
                     linked_by_employee_id, record_status_id, entered_by)
                SELECT @org_id, @exception_request_id, p.practice_id, p.practice_name, p.practice_code,
                       @iid, @iname, @icode,
                       @actor_employee_id, @active_rs,
                       ISNULL(NULLIF(@caller_display_name, N''), N'system')
                  FROM grac_practice.practice p
                 WHERE p.practice_id = @pid;
        END
        FETCH NEXT FROM c INTO @iid, @pid, @iname, @icode;
    END
    CLOSE c; DEALLOCATE c;
END
GO
PRINT '388: sp_exception_request_practice_instance_set created.';
GO

-- =====================================================================
-- 3a. sp_custom_gap_practice_map_list (382 body + instance columns)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_practice_map_list
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.custom_gap_practice_map_id CustomGapPracticeMapId,
           m.custom_gap_id              CustomGapId,
           m.practice_id                PracticeId,
           COALESCE(p.practice_name, m.practice_name) PracticeName,
           COALESCE(p.practice_code, m.practice_code) PracticeCode,
           m.mapped_dt                  MappedDt,
           m.practice_instance_id       PracticeInstanceId,
           COALESCE(pi.instance_name, m.practice_instance_name) PracticeInstanceName,
           COALESCE(pi.instance_code, m.practice_instance_code) PracticeInstanceCode
      FROM grac_practice.custom_gap_practice_map m
      LEFT JOIN grac_practice.practice p ON p.practice_id = m.practice_id
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = m.practice_instance_id
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = m.record_status_id
     WHERE m.custom_gap_id = @custom_gap_id
       AND rs.status_code = N'Active'
     ORDER BY COALESCE(p.practice_name, m.practice_name),
              COALESCE(pi.instance_name, m.practice_instance_name);
END
GO
PRINT '388: sp_custom_gap_practice_map_list returns instance columns.';
GO

-- =====================================================================
-- 3b. sp_exception_request_practice_list (328 body + instance columns)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_practice_list
    @exception_request_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55230, 'sp_exception_request_practice_list: exception_request_id is required.', 1;

    SELECT
        x.exception_request_practice_id AS ExceptionRequestPracticeId,
        x.practice_id                   AS PracticeId,
        x.practice_name                 AS PracticeName,
        x.practice_code                 AS PracticeCode,
        x.linked_dt                     AS LinkedOn,
        x.practice_instance_id          AS PracticeInstanceId,
        COALESCE(pi.instance_name, x.practice_instance_name) AS PracticeInstanceName,
        COALESCE(pi.instance_code, x.practice_instance_code) AS PracticeInstanceCode
      FROM grac_practice.exception_request_practice x
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
     WHERE x.exception_request_id = @exception_request_id
     ORDER BY x.exception_request_practice_id;
END
GO
PRINT '388: sp_exception_request_practice_list returns instance columns.';
GO

-- =====================================================================
-- 4. sp_risk_treatment_state (387 body; gap roots also via
--    custom_gap_practice_map instance rows)
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

    -- 387: the top-level tasks that make up this risk's treatment work,
    -- each with where it came from. A task reachable two ways is listed
    -- once, under the first source in this order.
    CREATE TABLE #roots(TaskId BIGINT PRIMARY KEY, LinkSourceCode NVARCHAR(20));

    INSERT #roots(TaskId, LinkSourceCode)
    SELECT v.task_id, N'Treatment'
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @org_id
       AND v.parent_task_id IS NULL
       AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = @risk_register_id)
         OR (@candidate_id IS NOT NULL
             AND v.source_type_code = N'Risk' AND v.source_record_id = @candidate_id));

    -- Tasks raised from gaps on a mapped practice INSTANCE: gaps whose
    -- source is the instance, and (388) Custom Gaps mapped to it.
    INSERT #roots(TaskId, LinkSourceCode)
    SELECT DISTINCT v.task_id, N'Gap'
      FROM grac_practice.risk_practice_map pm
      JOIN grac_practice.custom_gap g
        ON (g.source_reference_type = N'PracticeInstance'
            AND g.source_reference_id = pm.practice_instance_id)
        OR EXISTS (SELECT 1
                     FROM grac_practice.custom_gap_practice_map gm
                     JOIN grac_practice.record_status_master rs
                       ON rs.record_status_id = gm.record_status_id
                      AND rs.status_code = N'Active'
                    WHERE gm.custom_gap_id        = g.custom_gap_id
                      AND gm.practice_instance_id = pm.practice_instance_id)
      JOIN grac_practice.vw_pm_practice_task v
        ON v.source_type_code = N'Gap'
       AND v.source_record_id = g.custom_gap_id
       AND v.organization_id  = @org_id
       AND v.parent_task_id IS NULL
     WHERE pm.risk_register_id = @risk_register_id
       AND pm.practice_instance_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM #roots r WHERE r.TaskId = v.task_id);

    -- Open tasks mapped with "Map open task".
    IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NOT NULL
        INSERT #roots(TaskId, LinkSourceCode)
        SELECT l.task_id, N'Linked'
          FROM grac_practice.risk_treatment_task_link l
         WHERE l.risk_register_id = @risk_register_id
           AND NOT EXISTS (SELECT 1 FROM #roots r WHERE r.TaskId = l.task_id);

    CREATE TABLE #tt(
        TaskId BIGINT, TaskNumber NVARCHAR(60), Title NVARCHAR(250),
        StatusCode NVARCHAR(30), StatusName NVARCHAR(120), IsTerminal BIT,
        OwnerEmployeeId BIGINT, OwnerName NVARCHAR(240), Priority NVARCHAR(30),
        DueAt DATETIME2, ClosedAt DATETIME2, IsChild BIT, ParentTaskId BIGINT,
        ChildCount INT, MandatoryChildOpenCount INT, RaisedDt DATETIME2,
        LinkSourceCode NVARCHAR(20)
    );

    -- Each root task plus its sub tasks (children inherit the root's
    -- LinkSourceCode). Same columns and order as 263.
    INSERT INTO #tt
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.assigned_to_employee_id, v.assigned_to_employee_name, v.priority,
           v.sla_due_at, v.closed_at,
           CASE WHEN v.parent_task_id IS NOT NULL THEN 1 ELSE 0 END,
           v.parent_task_id, v.child_count, v.mandatory_child_open_count, v.entered_dt,
           r.LinkSourceCode
      FROM grac_practice.vw_pm_practice_task v
      JOIN #roots r ON r.TaskId = COALESCE(v.parent_task_id, v.task_id)
     WHERE v.organization_id = @org_id;

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
    DROP TABLE #roots;
END;
GO
PRINT '388: sp_risk_treatment_state includes Custom Gaps mapped to a risk''s instances.';
GO

-- =====================================================================
-- 5. Backfill: practice-level rows -> instance rows
--    (same rule as 387's sp_risk_practice_map_expand_instances: the
--    existing row claims the practice's first active instance, every
--    other active instance gets its own row; no active instance -> the
--    row stays practice-level). Re-runnable: only instance-NULL rows
--    are touched, and inserts skip instances already present.
-- =====================================================================
-- 5a. Custom Gap
IF OBJECT_ID('tempdb..#gl') IS NOT NULL DROP TABLE #gl;
SELECT m.custom_gap_practice_map_id AS map_id, m.custom_gap_id, m.practice_id,
       (SELECT MIN(pi.practice_instance_id)
          FROM grac_practice.practice_instance pi
         WHERE pi.practice_id = m.practice_id
           AND pi.organization_id = m.organization_id
           AND pi.status = N'Active'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap_practice_map x
                            WHERE x.custom_gap_id = m.custom_gap_id
                              AND x.practice_instance_id = pi.practice_instance_id)) AS first_inst
  INTO #gl
  FROM grac_practice.custom_gap_practice_map m
 WHERE m.practice_instance_id IS NULL;

UPDATE m
   SET practice_instance_id   = g.first_inst,
       practice_instance_name = pi.instance_name,
       practice_instance_code = pi.instance_code
  FROM grac_practice.custom_gap_practice_map m
  JOIN #gl g ON g.map_id = m.custom_gap_practice_map_id
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = g.first_inst
 WHERE g.first_inst IS NOT NULL;

INSERT INTO grac_practice.custom_gap_practice_map
    (organization_id, custom_gap_id, practice_id, practice_name, practice_code,
     practice_instance_id, practice_instance_name, practice_instance_code,
     mapped_dt, mapped_by_employee_id, remarks, record_status_id)
SELECT m.organization_id, m.custom_gap_id, m.practice_id, m.practice_name, m.practice_code,
       pi.practice_instance_id, pi.instance_name, pi.instance_code,
       m.mapped_dt, m.mapped_by_employee_id, m.remarks, m.record_status_id
  FROM #gl g
  JOIN grac_practice.custom_gap_practice_map m ON m.custom_gap_practice_map_id = g.map_id
  JOIN grac_practice.practice_instance pi
    ON pi.practice_id = m.practice_id
   AND pi.organization_id = m.organization_id
   AND pi.status = N'Active'
 WHERE g.first_inst IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap_practice_map x
                    WHERE x.custom_gap_id = m.custom_gap_id
                      AND x.practice_instance_id = pi.practice_instance_id);
DROP TABLE #gl;
PRINT '388: custom_gap_practice_map backfilled to instance level.';
GO

-- 5b. Exception
IF OBJECT_ID('tempdb..#el') IS NOT NULL DROP TABLE #el;
SELECT x.exception_request_practice_id AS map_id, x.exception_request_id, x.practice_id,
       (SELECT MIN(pi.practice_instance_id)
          FROM grac_practice.practice_instance pi
         WHERE pi.practice_id = x.practice_id
           AND pi.organization_id = x.organization_id
           AND pi.status = N'Active'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.exception_request_practice y
                            WHERE y.exception_request_id = x.exception_request_id
                              AND y.practice_instance_id = pi.practice_instance_id)) AS first_inst
  INTO #el
  FROM grac_practice.exception_request_practice x
 WHERE x.practice_instance_id IS NULL;

UPDATE x
   SET practice_instance_id   = e.first_inst,
       practice_instance_name = pi.instance_name,
       practice_instance_code = pi.instance_code
  FROM grac_practice.exception_request_practice x
  JOIN #el e ON e.map_id = x.exception_request_practice_id
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = e.first_inst
 WHERE e.first_inst IS NOT NULL;

INSERT INTO grac_practice.exception_request_practice
    (organization_id, exception_request_id, practice_id, practice_name, practice_code,
     practice_instance_id, practice_instance_name, practice_instance_code,
     linked_dt, linked_by_employee_id, record_status_id, entered_by)
SELECT x.organization_id, x.exception_request_id, x.practice_id, x.practice_name, x.practice_code,
       pi.practice_instance_id, pi.instance_name, pi.instance_code,
       x.linked_dt, x.linked_by_employee_id, x.record_status_id, N'388-backfill'
  FROM #el e
  JOIN grac_practice.exception_request_practice x ON x.exception_request_practice_id = e.map_id
  JOIN grac_practice.practice_instance pi
    ON pi.practice_id = x.practice_id
   AND pi.organization_id = x.organization_id
   AND pi.status = N'Active'
 WHERE e.first_inst IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM grac_practice.exception_request_practice y
                    WHERE y.exception_request_id = x.exception_request_id
                      AND y.practice_instance_id = pi.practice_instance_id);
DROP TABLE #el;
PRINT '388: exception_request_practice backfilled to instance level.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '388-a custom_gap_practice_map' AS [check],
       SUM(CASE WHEN practice_instance_id IS NOT NULL THEN 1 ELSE 0 END) AS instance_rows,
       SUM(CASE WHEN practice_instance_id IS NULL THEN 1 ELSE 0 END)     AS practice_level_rows
  FROM grac_practice.custom_gap_practice_map;
SELECT '388-b exception_request_practice' AS [check],
       SUM(CASE WHEN practice_instance_id IS NOT NULL THEN 1 ELSE 0 END) AS instance_rows,
       SUM(CASE WHEN practice_instance_id IS NULL THEN 1 ELSE 0 END)     AS practice_level_rows
  FROM grac_practice.exception_request_practice;
SELECT '388-c objects' AS [check], name, type_desc
  FROM sys.objects
 WHERE schema_id = SCHEMA_ID('grac_practice')
   AND name IN ('sp_custom_gap_practice_instance_set','sp_exception_request_practice_instance_set',
                'sp_custom_gap_practice_map_list','sp_exception_request_practice_list',
                'sp_risk_treatment_state')
 ORDER BY name;
GO
SET NOEXEC OFF;
GO
