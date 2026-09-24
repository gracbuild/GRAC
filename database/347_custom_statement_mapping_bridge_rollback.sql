-- =====================================================================
-- 347_custom_statement_mapping_bridge_rollback.sql
--
-- Reverses 347. Removes the custom-statement overlay rows and the
-- schema additions. Any practice<->custom-statement mappings created
-- while 347 was live are removed too (they reference the custom overlay
-- rows being deleted); repository mappings are untouched.
--
-- NOTE: framework_statement_id is left NULLABLE on both tables. Widening
-- back to NOT NULL is unsafe if any custom mapping/overlay rows existed,
-- and nullable is harmless for repository rows (they always carry a
-- value). If you truly need NOT NULL back, do it manually after
-- confirming no NULLs remain. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Remove mappings that point at custom overlay rows.
IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id=OBJECT_ID('grac_practice.organization_framework_statements')
                 AND name='source_type')
BEGIN
    DELETE m
    FROM grac_practice.organization_statement_practice_mapping m
    JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = m.org_statement_id
    WHERE ofs.source_type = 'Custom';
    PRINT CONCAT('347 rollback: custom mappings removed: ', @@ROWCOUNT);
END
GO

-- 2. Remove custom overlay rows.
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id=OBJECT_ID('grac_practice.organization_framework_statements')
             AND name='source_type')
BEGIN
    DELETE FROM grac_practice.organization_framework_statements WHERE source_type = 'Custom';
    PRINT CONCAT('347 rollback: custom overlay rows removed: ', @@ROWCOUNT);
END
GO

-- 3. Drop the ensure procedure.
IF OBJECT_ID('grac_practice.sp_pm_ensure_org_statement_for_custom','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_ensure_org_statement_for_custom;
GO

-- 4. Drop filtered indexes.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='uq_pm_ofs_custom' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
    DROP INDEX uq_pm_ofs_custom ON grac_practice.organization_framework_statements;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='uq_pm_ofs_repository' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
    DROP INDEX uq_pm_ofs_repository ON grac_practice.organization_framework_statements;
GO

-- 5. Restore the original all-rows unique constraint (repository shape).
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name='uq_pm_org_framework_statement'
                 AND parent_object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ADD CONSTRAINT uq_pm_org_framework_statement
            UNIQUE(organization_id, release_id, framework_statement_id);
    PRINT '347 rollback: uq_pm_org_framework_statement restored.';
END
GO

-- 6. Drop the added columns (FKs first, via column drop).
IF COL_LENGTH('grac_practice.organization_framework_statements','custom_statement_id') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_ofs_custom_statement')
        ALTER TABLE grac_practice.organization_framework_statements DROP CONSTRAINT fk_pm_ofs_custom_statement;
    ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN custom_statement_id;
END
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','subscription_id') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_ofs_subscription')
        ALTER TABLE grac_practice.organization_framework_statements DROP CONSTRAINT fk_pm_ofs_subscription;
    ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN subscription_id;
END
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','source_type') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name='df_pm_ofs_source_type')
        ALTER TABLE grac_practice.organization_framework_statements DROP CONSTRAINT df_pm_ofs_source_type;
    ALTER TABLE grac_practice.organization_framework_statements DROP COLUMN source_type;
END
GO
PRINT '347 rollback complete.';
GO
