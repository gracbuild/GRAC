-- =====================================================================
-- 048 Task model extension  (Phase 1 of the Task Center redesign)
--
-- Additive-only refactor per Q16 (keep practice_task as the "task_master"
-- entity — no rename). Adds the fields your task_master sketch calls out
-- so P2's workflow subsystem and P4's tabbed Task Center can attach.
--
-- Contents:
--   1. related_entity_type_master  — the catalog of "what does this task
--      relate to?" values (Q22 recommended set)
--   2. New task_type_master rows   — 'Assurance' and 'Custom' (Q17)
--   3. Additive columns on practice_task:
--        related_entity_type_id     INT NULL   FK
--        related_record_id          BIGINT NULL
--        start_date                 DATETIME2 NULL
--        workflow_id                BIGINT NULL   (P2 will add FK)
--        current_workflow_stage_id  BIGINT NULL   (P2 will add FK)
--        assurance_activity_id      BIGINT NULL
--        task_number                AS (persisted computed identifier)
--   4. Supporting indexes
--
-- Q18 resolution: workflow is OPTIONAL — workflow_id and
-- current_workflow_stage_id are NULLable. Tasks without a workflow still
-- run through the existing Open→Closed lifecycle from §12.1.1.
--
-- Idempotent. Rollback: 048_task_model_extension_rollback.sql.
-- Procs updated in 048_task_model_procs.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL BEGIN PRINT 'ABORT (048): schema missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL BEGIN PRINT 'ABORT (048): practice_task missing — run 037 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.task_type_master','U') IS NULL BEGIN PRINT 'ABORT (048): task_type_master missing — run 037 first.'; SET @ok = 0; END
IF @ok = 0 BEGIN RAISERROR('048 prereqs missing', 16, 1); SET NOEXEC ON; END
GO

-- =====================================================================
-- 1. related_entity_type_master (Q22)
-- =====================================================================
IF OBJECT_ID('grac_practice.related_entity_type_master','U') IS NULL
CREATE TABLE grac_practice.related_entity_type_master(
    related_entity_type_id INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_related_entity_type_master PRIMARY KEY,
    entity_code            NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_related_entity_type_code UNIQUE,
    entity_name            NVARCHAR(120) NOT NULL,
    description            NVARCHAR(400) NULL,
    display_order          INT           NOT NULL DEFAULT 0,
    is_active              BIT           NOT NULL DEFAULT 1,
    entered_by             NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt             DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by             NVARCHAR(100) NULL,
    updated_dt             DATETIME2     NULL
);
GO

;WITH src AS (
    SELECT * FROM (VALUES
        (N'PracticeInstance', N'Practice Instance', 10),
        (N'Practice',         N'Practice',          20),
        (N'Control',          N'Control',           30),
        (N'Release',          N'Release',           40),
        (N'Risk',             N'Risk',              50),
        (N'Waiver',           N'Waiver',            60),
        (N'AssuranceTicket',  N'Assurance Ticket',  70),
        (N'AssuranceActivity',N'Assurance Activity',75),
        (N'Custom',           N'Custom / Ad-hoc',   99)
    ) v(entity_code, entity_name, display_order)
)
MERGE grac_practice.related_entity_type_master AS t
USING src
   ON t.entity_code = src.entity_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_code, entity_name, display_order, is_active, entered_by)
    VALUES (src.entity_code, src.entity_name, src.display_order, 1, 'seed-048')
WHEN MATCHED AND (t.entity_name <> src.entity_name OR t.display_order <> src.display_order) THEN
    UPDATE SET entity_name = src.entity_name, display_order = src.display_order,
               updated_by = 'seed-048', updated_dt = SYSUTCDATETIME();
GO

-- =====================================================================
-- 2. New task_type_master rows (Q17)
--    'Assurance' — auto-generated tasks tied to Assurance Ticket / Activity
--    'Custom'    — user-created ad-hoc tasks from the + New Task button
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        (N'Assurance', N'Assurance',  N'Auto-generated task tied to an Assurance Ticket / Activity', 72, N'Medium', 1, 90),
        (N'Custom',    N'Custom',     N'User-created ad-hoc task from Task Center',                  120, N'Medium', 0, 100)
    ) v(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
)
MERGE grac_practice.task_type_master AS t
USING src
   ON t.type_code = src.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (src.type_code, src.type_name, src.description, src.default_sla_hours, src.default_priority, src.is_system_only, src.display_order, 'seed-048');
GO

-- =====================================================================
-- 3. Additive columns on practice_task
--    ALL nullable — existing rows are unaffected; new tasks fill them in.
--    workflow_id / current_workflow_stage_id have no FK yet because the
--    target tables land in P2 (048 workflow subsystem migration).
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_task','related_entity_type_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD related_entity_type_id INT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','related_record_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD related_record_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','start_date') IS NULL
    ALTER TABLE grac_practice.practice_task ADD start_date DATETIME2 NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','workflow_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD workflow_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','current_workflow_stage_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD current_workflow_stage_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.practice_task','assurance_activity_id') IS NULL
    ALTER TABLE grac_practice.practice_task ADD assurance_activity_id BIGINT NULL;
GO

-- FK for related_entity_type_id (safe — the master table exists at this point)
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_task_related_entity_type'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_task'))
    ALTER TABLE grac_practice.practice_task
        ADD CONSTRAINT fk_pm_practice_task_related_entity_type
            FOREIGN KEY (related_entity_type_id)
            REFERENCES grac_practice.related_entity_type_master(related_entity_type_id);
GO

-- Computed column task_number — persisted so it can be indexed / displayed.
-- Format: T-{organization_id}-{task_id}, e.g. T-4-1042.
IF COL_LENGTH('grac_practice.practice_task','task_number') IS NULL
    ALTER TABLE grac_practice.practice_task
        ADD task_number AS
            (CONCAT('T-', CAST(organization_id AS NVARCHAR(20)), '-', CAST(task_id AS NVARCHAR(20))))
        PERSISTED;
GO

-- =====================================================================
-- 4. Supporting indexes
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_related_entity' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_related_entity
        ON grac_practice.practice_task(related_entity_type_id, related_record_id)
        INCLUDE (organization_id, task_type_id, current_status_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_workflow' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_workflow
        ON grac_practice.practice_task(workflow_id, current_workflow_stage_id)
        INCLUDE (organization_id, current_status_id)
        WHERE workflow_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_task_number' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_task_number
        ON grac_practice.practice_task(task_number);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_assurance_activity' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    CREATE INDEX ix_pm_practice_task_assurance_activity
        ON grac_practice.practice_task(assurance_activity_id)
        INCLUDE (organization_id, task_type_id)
        WHERE assurance_activity_id IS NOT NULL;
GO

-- Sanity
SELECT 'related_entity_type_master rows' AS Check_, COUNT(*) AS Rows_ FROM grac_practice.related_entity_type_master;
SELECT 'Assurance + Custom task types present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Assurance')
             AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'Custom')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'practice_task extended columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_task','related_entity_type_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','start_date')             IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','workflow_id')             IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','current_workflow_stage_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','assurance_activity_id')   IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_task','task_number')             IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '048 task model extension complete.';
GO
SET NOEXEC OFF;
GO
