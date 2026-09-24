-- =====================================================================
-- 347_custom_statement_mapping_bridge.sql
--
-- WHY
-- ---
-- A Practice (organization_requirement) can be mapped to subscribed
-- repository statements, but NOT to an organization's own custom-release
-- statements. Repository statements carry an org overlay row in
-- grac_practice.organization_framework_statements (org_statement_id), and
-- the practice<->statement mapping (organization_statement_practice_mapping)
-- and the Add/Edit Practice picker are all keyed on that org_statement_id.
-- Custom statements live in grac_practice.custom_release_statement with no
-- org_statement_id and no framework_statement_id, so they can neither be
-- offered by the picker nor persisted by the save.
--
-- This migration is the "Option B" bridge: give every custom statement an
-- org_statement_id overlay row, source-tagged, so the ONE existing mapping
-- path works for both sources unchanged. The Add/Edit Practice save
-- (dbo.pm_manage_practice_repository, mappedOrgStatementIds branch) already
-- copies framework_statement_id / release_id straight from the overlay row
-- it is handed -- it does not re-derive them from grac_new -- so a custom
-- overlay row with framework_statement_id = NULL simply produces a mapping
-- row with framework_statement_id = NULL. Nothing else in that path changes.
--
-- WHAT
-- ----
--   1. organization_framework_statements: allow a custom-sourced row --
--      framework_statement_id / release_id nullable, add source_type,
--      subscription_id, custom_statement_id, and replace the single unique
--      constraint with two filtered unique indexes (one per source).
--   2. organization_statement_practice_mapping.framework_statement_id ->
--      nullable, so a custom mapping row (no framework_statement_id) is
--      valid. release_id was already nullable.
--   3. sp_pm_ensure_org_statement_for_custom -- idempotently create/return
--      the overlay org_statement_id for a custom statement.
--   4. Backfill overlay rows for existing active custom statements.
--
-- OUT OF SCOPE (deferred, per plan decision #2): rolling custom-statement
-- mappings into the applicability / obligation / Repository-Subscriptions
-- count pipeline. This migration only makes custom statements mappable and
-- their mappings persist + reload.
--
-- SAFE TO RE-RUN. Additive / constraint-relaxing only; existing repository
-- rows and mappings are untouched. ASCII-only.
-- Rollback: database/347_custom_statement_mapping_bridge_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_release_statement','U') IS NULL
BEGIN
    PRINT 'ABORT (347): a prerequisite table is missing (run 001 / 031 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. organization_framework_statements: allow a custom-sourced row
-- =====================================================================

-- 1a. source_type -- 'Repository' (default, existing rows) or 'Custom'.
IF COL_LENGTH('grac_practice.organization_framework_statements','source_type') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ADD source_type NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_ofs_source_type DEFAULT 'Repository';
    PRINT '347: organization_framework_statements.source_type added.';
END
GO

-- 1b. subscription_id + custom_statement_id -- identify a custom overlay row.
IF COL_LENGTH('grac_practice.organization_framework_statements','subscription_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ADD subscription_id BIGINT NULL
            CONSTRAINT fk_pm_ofs_subscription
                REFERENCES grac_practice.repository_subscription(subscription_id);
    PRINT '347: organization_framework_statements.subscription_id added.';
END
GO
IF COL_LENGTH('grac_practice.organization_framework_statements','custom_statement_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ADD custom_statement_id BIGINT NULL
            CONSTRAINT fk_pm_ofs_custom_statement
                REFERENCES grac_practice.custom_release_statement(custom_statement_id);
    PRINT '347: organization_framework_statements.custom_statement_id added.';
END
GO

-- 1c. Drop the old all-rows unique constraint; a custom row has
-- framework_statement_id / release_id NULL, and SQL Server allows only one
-- NULL per UNIQUE constraint, so it must become two filtered indexes.
IF EXISTS (SELECT 1 FROM sys.key_constraints
           WHERE name='uq_pm_org_framework_statement'
             AND parent_object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        DROP CONSTRAINT uq_pm_org_framework_statement;
    PRINT '347: dropped uq_pm_org_framework_statement (replaced by filtered indexes).';
END
GO

-- 1d. framework_statement_id / release_id -> NULL (custom rows have neither).
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id=OBJECT_ID('grac_practice.organization_framework_statements')
             AND name='framework_statement_id' AND is_nullable=0)
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ALTER COLUMN framework_statement_id BIGINT NULL;
    PRINT '347: organization_framework_statements.framework_statement_id -> NULL.';
END
GO
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id=OBJECT_ID('grac_practice.organization_framework_statements')
             AND name='release_id' AND is_nullable=0)
BEGIN
    ALTER TABLE grac_practice.organization_framework_statements
        ALTER COLUMN release_id BIGINT NULL;
    PRINT '347: organization_framework_statements.release_id -> NULL.';
END
GO

-- 1e. Filtered unique indexes -- one per source. Repository keeps the old
-- (org, release, framework_statement) shape; Custom is unique per
-- (org, custom_statement).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='uq_pm_ofs_repository'
                 AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    CREATE UNIQUE INDEX uq_pm_ofs_repository
        ON grac_practice.organization_framework_statements(organization_id, release_id, framework_statement_id)
        WHERE source_type = 'Repository';
    PRINT '347: uq_pm_ofs_repository filtered unique index created.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='uq_pm_ofs_custom'
                 AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    CREATE UNIQUE INDEX uq_pm_ofs_custom
        ON grac_practice.organization_framework_statements(organization_id, custom_statement_id)
        WHERE source_type = 'Custom';
    PRINT '347: uq_pm_ofs_custom filtered unique index created.';
END
GO

-- =====================================================================
-- 2. organization_statement_practice_mapping.framework_statement_id -> NULL
--    (release_id is already nullable). A custom mapping row carries
--    org_statement_id + org_practice_id and NULL framework_statement_id.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id=OBJECT_ID('grac_practice.organization_statement_practice_mapping')
             AND name='framework_statement_id' AND is_nullable=0)
BEGIN
    ALTER TABLE grac_practice.organization_statement_practice_mapping
        ALTER COLUMN framework_statement_id BIGINT NULL;
    PRINT '347: organization_statement_practice_mapping.framework_statement_id -> NULL.';
END
GO

-- =====================================================================
-- 3. Ensure-overlay procedure for a custom statement
--    Idempotent: returns the existing org_statement_id, or creates one.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_ensure_org_statement_for_custom
    @p_custom_statement_id BIGINT,
    @p_actor              NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @org_statement_id BIGINT =
        (SELECT org_statement_id
         FROM grac_practice.organization_framework_statements
         WHERE source_type = 'Custom' AND custom_statement_id = @p_custom_statement_id);

    IF @org_statement_id IS NOT NULL
    BEGIN
        SELECT @org_statement_id AS org_statement_id;
        RETURN;
    END

    DECLARE @organization_id BIGINT, @subscription_id BIGINT, @applicability_status_id INT;
    SELECT @organization_id       = cs.organization_id,
           @subscription_id       = cs.subscription_id,
           @applicability_status_id = cs.applicability_status_id
    FROM   grac_practice.custom_release_statement cs
    WHERE  cs.custom_statement_id = @p_custom_statement_id;

    IF @organization_id IS NULL
    BEGIN
        -- No such custom statement; nothing to create.
        SELECT CAST(NULL AS BIGINT) AS org_statement_id;
        RETURN;
    END

    INSERT grac_practice.organization_framework_statements(
        organization_id, release_id, framework_statement_id,
        source_type, subscription_id, custom_statement_id,
        applicability_status_id, status, entered_by, entered_dt)
    VALUES(
        @organization_id, NULL, NULL,
        'Custom', @subscription_id, @p_custom_statement_id,
        @applicability_status_id, 'Active', @p_actor, SYSUTCDATETIME());

    SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS org_statement_id;
END
GO
PRINT '347: sp_pm_ensure_org_statement_for_custom ready.';
GO

-- =====================================================================
-- 4. Backfill overlay rows for existing active custom statements
--    so already-authored custom statements are immediately mappable.
-- =====================================================================
INSERT grac_practice.organization_framework_statements(
    organization_id, release_id, framework_statement_id,
    source_type, subscription_id, custom_statement_id,
    applicability_status_id, status, entered_by, entered_dt)
SELECT cs.organization_id, NULL, NULL,
       'Custom', cs.subscription_id, cs.custom_statement_id,
       cs.applicability_status_id, 'Active', 'backfill-347', SYSUTCDATETIME()
FROM   grac_practice.custom_release_statement cs
WHERE  cs.status = 'Active'
  AND  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_framework_statements ofs
        WHERE ofs.source_type = 'Custom'
          AND ofs.custom_statement_id = cs.custom_statement_id);
PRINT CONCAT('347: custom overlay rows backfilled: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 347 verification ===';
SELECT '347 columns present' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_framework_statements','source_type') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_framework_statements','custom_statement_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_framework_statements','subscription_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'framework_statement_id nullable (both tables)',
       CASE WHEN (SELECT is_nullable FROM sys.columns WHERE object_id=OBJECT_ID('grac_practice.organization_framework_statements') AND name='framework_statement_id')=1
             AND (SELECT is_nullable FROM sys.columns WHERE object_id=OBJECT_ID('grac_practice.organization_statement_practice_mapping') AND name='framework_statement_id')=1
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'ensure proc present',
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_ensure_org_statement_for_custom','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'every active custom statement has an overlay',
       CASE WHEN NOT EXISTS (
              SELECT 1 FROM grac_practice.custom_release_statement cs
              WHERE cs.status='Active'
                AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_framework_statements ofs
                                WHERE ofs.source_type='Custom' AND ofs.custom_statement_id=cs.custom_statement_id))
            THEN 'PASS' ELSE 'FAIL' END;
GO
