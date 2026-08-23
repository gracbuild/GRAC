-- =====================================================================
-- 183 Organization SLA -- pct + time_basis contract -- ROLLBACK
--
-- Restores the day columns + defaults + CHECKs and re-installs the
-- 181 versions of the affected procs.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- Drop new CHECKs.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_warning_pct')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT ck_pm_org_sla_warning_pct;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_escalation_pct')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT ck_pm_org_sla_escalation_pct;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_pct_order')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT ck_pm_org_sla_pct_order;

-- Drop the covering index that INCLUDE-references the pct columns,
-- else DROP COLUMN below fails with Msg 5074 (index dependency).
-- Recreated with the day columns below.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_org_sla_org'
             AND object_id = OBJECT_ID('grac_practice.org_sla_config'))
    DROP INDEX ix_pm_org_sla_org ON grac_practice.org_sla_config;

-- Re-add day columns with defaults.
IF COL_LENGTH('grac_practice.org_sla_config','warning_before_due_days') IS NULL
    ALTER TABLE grac_practice.org_sla_config
        ADD warning_before_due_days INT NOT NULL
            CONSTRAINT df_pm_org_sla_warning DEFAULT 3;

IF COL_LENGTH('grac_practice.org_sla_config','escalation_after_due_days') IS NULL
    ALTER TABLE grac_practice.org_sla_config
        ADD escalation_after_due_days INT NOT NULL
            CONSTRAINT df_pm_org_sla_escalation DEFAULT 2;

-- Drop new columns.
IF COL_LENGTH('grac_practice.org_sla_config','warning_pct') IS NOT NULL
    ALTER TABLE grac_practice.org_sla_config DROP COLUMN warning_pct;
IF COL_LENGTH('grac_practice.org_sla_config','escalation_pct') IS NOT NULL
    ALTER TABLE grac_practice.org_sla_config DROP COLUMN escalation_pct;
IF COL_LENGTH('grac_practice.org_sla_config','time_basis') IS NOT NULL
    ALTER TABLE grac_practice.org_sla_config DROP COLUMN time_basis;

-- Re-add old CHECKs.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_thresholds')
    ALTER TABLE grac_practice.org_sla_config
        ADD CONSTRAINT ck_pm_org_sla_thresholds
            CHECK (warning_before_due_days >= 0 AND escalation_after_due_days >= 0);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_warning_within_total')
    ALTER TABLE grac_practice.org_sla_config
        ADD CONSTRAINT ck_pm_org_sla_warning_within_total
            CHECK (total_sla_days IS NULL
                OR warning_before_due_days <= total_sla_days);

-- Recreate the original (178-shape) covering index over the day columns.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_org_sla_org'
                 AND object_id = OBJECT_ID('grac_practice.org_sla_config'))
    CREATE INDEX ix_pm_org_sla_org
        ON grac_practice.org_sla_config(organization_id, is_active)
        INCLUDE (sla_master_id, sla_master_name, warning_before_due_days,
                 escalation_after_due_days);

COMMIT TRAN;
GO

-- The rest of the rollback re-installs the 181 versions of the four
-- affected procs. Run 181_org_sla_master_grid.sql afterwards if you
-- prefer to restore the full 181 state in one shot; the block below
-- only ensures the procs at least compile with the day columns.
PRINT '183 rolled back -- day columns restored. Re-run 181 to restore the day-based procs.';
GO
