-- =====================================================================
-- 336 ROLLBACK  Schedule rule per-obligation change
--
-- Reverses 336: drops the two indexes and the FK, drops the two added
-- columns, and restores the original one-rule-per-instance UNIQUE.
--
-- CAUTION
-- -------
-- Restoring UNIQUE(practice_instance_id) will FAIL if, by the time this
-- runs, any instance already owns more than one active rule (which is
-- the whole point of 336). That is intended: the rollback refuses rather
-- than silently deleting the extra streams. Remove the extra rules first
-- if you truly mean to go back to one-per-instance.
--
-- SAFE TO RE-RUN: every drop is guarded; the column drops remove the
-- objects that depend on them (index, FK) first.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
BEGIN
    PRINT 'ABORT (336 rollback): assurance_schedule_rule missing -- nothing to undo.';
    SET NOEXEC ON;
END
GO

-- 1. Drop the helper + filtered-unique indexes.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_pm_schedule_rule_pio' AND object_id=OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN DROP INDEX ix_pm_schedule_rule_pio ON grac_practice.assurance_schedule_rule; PRINT '336 rollback: dropped ix_pm_schedule_rule_pio'; END
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='uq_pm_schedule_rule_obligation_active' AND object_id=OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN DROP INDEX uq_pm_schedule_rule_obligation_active ON grac_practice.assurance_schedule_rule; PRINT '336 rollback: dropped uq_pm_schedule_rule_obligation_active'; END
GO

-- 2. Drop the FK, then the columns.
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_schedule_rule_pio')
BEGIN ALTER TABLE grac_practice.assurance_schedule_rule DROP CONSTRAINT fk_pm_schedule_rule_pio; PRINT '336 rollback: dropped fk_pm_schedule_rule_pio'; END
GO
IF COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NOT NULL
BEGIN ALTER TABLE grac_practice.assurance_schedule_rule DROP COLUMN practice_instance_obligation_id; PRINT '336 rollback: dropped practice_instance_obligation_id'; END
GO
IF COL_LENGTH('grac_practice.assurance_schedule_rule','schedule_kind') IS NOT NULL
BEGIN ALTER TABLE grac_practice.assurance_schedule_rule DROP COLUMN schedule_kind; PRINT '336 rollback: dropped schedule_kind'; END
GO

-- 3. Restore the original one-rule-per-instance UNIQUE (see CAUTION).
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
                WHERE name='uq_pm_schedule_rule_instance'
                  AND parent_object_id=OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN
    ALTER TABLE grac_practice.assurance_schedule_rule
        ADD CONSTRAINT uq_pm_schedule_rule_instance UNIQUE(practice_instance_id);
    PRINT '336 rollback: restored UNIQUE uq_pm_schedule_rule_instance';
END
ELSE PRINT '336 rollback: uq_pm_schedule_rule_instance already present -- skipped';
GO

PRINT '336 rollback complete.';
GO
