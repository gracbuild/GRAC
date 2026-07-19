-- =====================================================================
-- 048 Rollback — reverses the additive task-model extension.
-- Keeps data intact where possible. Drops the new columns / index and
-- the related_entity_type_master ONLY if no rows are referencing them.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (048-rollback): schema missing.';
    RAISERROR('schema missing', 16, 1);
    SET NOEXEC ON;
END
GO

-- Indexes
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_related_entity'    AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_related_entity ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_workflow'          AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_workflow ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_task_number'       AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_task_number ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_assurance_activity' AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_assurance_activity ON grac_practice.practice_task;
GO

-- FK before column
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_task_related_entity_type')
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT fk_pm_practice_task_related_entity_type;
GO

-- Columns
IF COL_LENGTH('grac_practice.practice_task','task_number')             IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN task_number;
IF COL_LENGTH('grac_practice.practice_task','assurance_activity_id')   IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN assurance_activity_id;
IF COL_LENGTH('grac_practice.practice_task','current_workflow_stage_id') IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN current_workflow_stage_id;
IF COL_LENGTH('grac_practice.practice_task','workflow_id')             IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN workflow_id;
IF COL_LENGTH('grac_practice.practice_task','start_date')              IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN start_date;
IF COL_LENGTH('grac_practice.practice_task','related_record_id')       IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN related_record_id;
IF COL_LENGTH('grac_practice.practice_task','related_entity_type_id')  IS NOT NULL ALTER TABLE grac_practice.practice_task DROP COLUMN related_entity_type_id;
GO

-- Master table — drop only if no rows now reference it. Since we already
-- dropped the FK column, this is safe once other schema doesn't hold FKs.
IF OBJECT_ID('grac_practice.related_entity_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.related_entity_type_master;
GO

-- Note: the new task_type_master rows 'Assurance' / 'Custom' are intentionally
-- KEPT (they may already be referenced by task rows created after 048 ran).
-- Delete manually if you truly want them gone.

PRINT '048 rollback complete. Task-type rows preserved by design.';
GO
SET NOEXEC OFF;
GO
