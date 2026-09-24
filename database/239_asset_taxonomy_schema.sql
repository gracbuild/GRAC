-- =====================================================================
-- 239 Asset taxonomy: subcategory + asset type masters
--
-- WHY
-- ---
-- The Add Asset form under Practice/Index/organization-dependencies picks
-- an Asset Category and stops there. Real assets need at least two more
-- levels of classification -- "Firewall" is a network device, which is
-- infrastructure, which is technology -- and the Enterprise Asset
-- Taxonomy Template calls for that whole chain:
--
--     Main Category -> Subcategory -> Asset Type -> Instance
--
-- This migration adds the two missing master tables and the FK columns
-- on organization_dependency_asset. Migration 240 seeds the baseline
-- taxonomy from the template; the save proc and the Add Asset form
-- follow in the same batch.
--
-- SCHEMA
-- ------
-- dependency_asset_subcategory_master:
--   subcategory_id       INT IDENTITY PK
--   asset_category_id    INT NOT NULL FK -> dependency_asset_category_master
--   subcategory_code     NVARCHAR(80) UNIQUE
--   subcategory_name     NVARCHAR(200)
--   display_order        INT DEFAULT 0
--   is_active            BIT DEFAULT 1
--   entered_by / entered_dt / updated_by / updated_dt
--
-- dependency_asset_type_master:
--   asset_type_id        INT IDENTITY PK
--   subcategory_id       INT NOT NULL FK -> dependency_asset_subcategory_master
--   asset_type_code      NVARCHAR(80) UNIQUE
--   asset_type_name      NVARCHAR(200)
--   display_order        INT DEFAULT 0
--   is_active            BIT DEFAULT 1
--   entered_by / entered_dt / updated_by / updated_dt
--
-- organization_dependency_asset gains:
--   asset_subcategory_id INT NULL FK -> dependency_asset_subcategory_master
--   asset_type_id        INT NULL FK -> dependency_asset_type_master
--
-- NULL is deliberate: assets created before this migration have no
-- subcategory or type, and forcing a value would either invent one or
-- break every existing row. New saves through the Add Asset form will
-- populate both.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (239): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.dependency_asset_category_master','U') IS NULL
BEGIN
    PRINT 'ABORT (239): dependency_asset_category_master missing (run 002 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.organization_dependency_asset','U') IS NULL
BEGIN
    PRINT 'ABORT (239): organization_dependency_asset missing (run 002 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. dependency_asset_subcategory_master
-- =====================================================================
IF OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.dependency_asset_subcategory_master(
        subcategory_id     INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_asset_subcategory PRIMARY KEY,
        asset_category_id  INT NOT NULL
            CONSTRAINT fk_pm_asset_subcategory_category
                REFERENCES grac_practice.dependency_asset_category_master(asset_category_id),
        subcategory_code   NVARCHAR(80) NOT NULL
            CONSTRAINT uq_pm_asset_subcategory_code UNIQUE,
        subcategory_name   NVARCHAR(200) NOT NULL,
        display_order      INT NOT NULL
            CONSTRAINT df_pm_asset_subcategory_display DEFAULT 100,
        is_active          BIT NOT NULL
            CONSTRAINT df_pm_asset_subcategory_active DEFAULT 1,
        entered_by         NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_asset_subcategory_entered_by DEFAULT 'system',
        entered_dt         DATETIME2 NOT NULL
            CONSTRAINT df_pm_asset_subcategory_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2 NULL
    );
    CREATE INDEX ix_pm_asset_subcategory_by_category
        ON grac_practice.dependency_asset_subcategory_master(asset_category_id, display_order);
    PRINT '239: dependency_asset_subcategory_master created.';
END
ELSE
BEGIN
    PRINT '239: dependency_asset_subcategory_master already present.';
END
GO

-- =====================================================================
-- 2. dependency_asset_type_master
-- =====================================================================
IF OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.dependency_asset_type_master(
        asset_type_id      INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_asset_type PRIMARY KEY,
        subcategory_id     INT NOT NULL
            CONSTRAINT fk_pm_asset_type_subcategory
                REFERENCES grac_practice.dependency_asset_subcategory_master(subcategory_id),
        asset_type_code    NVARCHAR(80) NOT NULL
            CONSTRAINT uq_pm_asset_type_code UNIQUE,
        asset_type_name    NVARCHAR(200) NOT NULL,
        display_order      INT NOT NULL
            CONSTRAINT df_pm_asset_type_display DEFAULT 100,
        is_active          BIT NOT NULL
            CONSTRAINT df_pm_asset_type_active DEFAULT 1,
        entered_by         NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_asset_type_entered_by DEFAULT 'system',
        entered_dt         DATETIME2 NOT NULL
            CONSTRAINT df_pm_asset_type_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2 NULL
    );
    CREATE INDEX ix_pm_asset_type_by_subcategory
        ON grac_practice.dependency_asset_type_master(subcategory_id, display_order);
    PRINT '239: dependency_asset_type_master created.';
END
ELSE
BEGIN
    PRINT '239: dependency_asset_type_master already present.';
END
GO

-- =====================================================================
-- 3. FK columns on organization_dependency_asset
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD asset_subcategory_id INT NULL
            CONSTRAINT fk_pm_org_asset_subcategory
                REFERENCES grac_practice.dependency_asset_subcategory_master(subcategory_id);
    PRINT '239: organization_dependency_asset.asset_subcategory_id added.';
END
GO

IF COL_LENGTH('grac_practice.organization_dependency_asset','asset_type_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD asset_type_id INT NULL
            CONSTRAINT fk_pm_org_asset_type
                REFERENCES grac_practice.dependency_asset_type_master(asset_type_id);
    PRINT '239: organization_dependency_asset.asset_type_id added.';
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 239 verification ===';

SELECT 'subcategory master present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.dependency_asset_subcategory_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'asset type master present',
       CASE WHEN OBJECT_ID('grac_practice.dependency_asset_type_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'FK column asset_subcategory_id present',
       CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','asset_subcategory_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'FK column asset_type_id present',
       CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','asset_type_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '239 complete. Now run 240 to seed the baseline taxonomy from the template.';
GO

SET NOEXEC OFF;
GO
