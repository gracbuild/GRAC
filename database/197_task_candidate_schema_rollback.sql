-- =====================================================================
-- 197 Task Candidate — schema ROLLBACK
--
-- Reverses 197_task_candidate_schema.sql.
--
-- ORDER
--   1. Drop the 198/199/200 procedures that bind to task_candidate —
--      their own rollbacks own this, but guarding here lets 197's
--      rollback run standalone.
--   2. Restore the source procs that 199 rewrote, so Gap / Risk /
--      Continuous Assurance keep working after the rollback.
--   3. Break the practice_task -> task_candidate link.
--   4. Drop the tables (history before header).
--
-- DATA LOSS WARNING: task_candidate and task_candidate_history are
-- DROPPED. Any candidate that had not yet been approved is lost —
-- approved ones already became practice_task rows and survive, they just
-- lose their provenance link.
--
-- Run 199's rollback FIRST if you want the source procs restored
-- cleanly; this script only does a best-effort version of that.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT '197-rollback: schema grac_practice missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Drop candidate procedures (198) — dependents first
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_task_candidate_counts','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_counts;
IF OBJECT_ID('grac_practice.sp_task_candidate_discard','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_discard;
IF OBJECT_ID('grac_practice.sp_task_candidate_approve','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_approve;
IF OBJECT_ID('grac_practice.sp_task_candidate_validate_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_validate_save;
IF OBJECT_ID('grac_practice.sp_task_candidate_get','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_get;
IF OBJECT_ID('grac_practice.sp_task_candidate_list','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_list;
IF OBJECT_ID('grac_practice.sp_task_candidate_apply_sla','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_apply_sla;
IF OBJECT_ID('grac_practice.sp_task_candidate_create','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_task_candidate_create;
GO

-- Source-tasks read proc (199) also reads task_candidate.
IF OBJECT_ID('grac_practice.sp_task_source_items','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_source_items;
GO

-- ---------------------------------------------------------------------
-- 2. Restore sp_custom_gap_task_create to its 174 definition
--
--    199 rewrote it to raise a candidate. Without this restore, gap
--    analysis saves would call a proc that references a dropped table.
--    Byte-for-byte the 174 body.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.sp_task_open','P') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_task_create
    @custom_gap_id           BIGINT,
    @assigned_to_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N''system''
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55500, ''sp_custom_gap_task_create: custom_gap_id is required.'', 1;

    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 task_id
           FROM grac_practice.practice_task
          WHERE subject_entity_type = N''CustomGap''
            AND subject_entity_id   = @custom_gap_id
            AND closed_at IS NULL
          ORDER BY task_id DESC);
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS TaskId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    DECLARE @org_id BIGINT, @gap_title NVARCHAR(250), @summary NVARCHAR(MAX);
    SELECT @org_id = organization_id, @gap_title = title
      FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;
    IF @org_id IS NULL
        THROW 55501, ''sp_custom_gap_task_create: custom_gap not found.'', 1;

    SELECT @summary = recommended_action_summary
      FROM grac_practice.custom_gap_analysis WHERE custom_gap_id = @custom_gap_id;

    DECLARE @task_id    BIGINT;
    DECLARE @task_title NVARCHAR(250) = LEFT(CONCAT(N''Gap task: '', @gap_title), 250);
    BEGIN TRY
        EXEC grac_practice.sp_task_open
            @organization_id         = @org_id,
            @task_type_code          = N''Rectification'',
            @subject_entity_type     = N''CustomGap'',
            @subject_entity_id       = @custom_gap_id,
            @subject_title           = @task_title,
            @subject_description     = @summary,
            @priority                = N''Medium'',
            @origin_code             = N''Custom'',
            @assigned_to_employee_id = @assigned_to_employee_id,
            @actor_employee_id       = @assigned_to_employee_id,
            @task_id                 = @task_id OUTPUT;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 55502, @msg, 1;
    END CATCH

    SELECT @task_id AS TaskId, CAST(1 AS BIT) AS Created;
END';
END
GO

PRINT '197-rollback: sp_risk_candidate_accept and sp_org_assurance_observation_accept are NOT restored here.';
PRINT '              Re-run 170_risk_centre_procs.sql and 102_org_assurance_observation_procs.sql,';
PRINT '              or run 199_task_candidate_sources_rollback.sql which restores both properly.';
GO

-- ---------------------------------------------------------------------
-- 3. Break the practice_task -> task_candidate link
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_practice_task_candidate'
              AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_candidate ON grac_practice.practice_task;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_practice_task_candidate'
              AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT fk_pm_practice_task_candidate;
GO

IF COL_LENGTH('grac_practice.practice_task','task_candidate_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN task_candidate_id;
GO

-- ---------------------------------------------------------------------
-- 4. Drop the tables
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.task_candidate_history','U') IS NOT NULL
    DROP TABLE grac_practice.task_candidate_history;
IF OBJECT_ID('grac_practice.task_candidate','U') IS NOT NULL
    DROP TABLE grac_practice.task_candidate;
GO

PRINT '197 Task Candidate schema rolled back.';
GO

SET NOEXEC OFF;
GO
