-- =====================================================================
-- 341 Local-obligation identity on event_obligation_applicability
-- -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- 341 gave a practice-level or instance-only custom obligation somewhere
-- to carry an applicability decision. Rolling it back removes that store:
-- local_practice_obligation_id, local_instance_obligation_id, their FKs,
-- the exactly-one-identity CHECK, and the three filtered natural-key
-- indexes, and puts obligation_id back to NOT NULL and the single
-- 6-column natural-key index (329's shape) in their place.
--
-- REFUSES WHILE ANY ROW ACTUALLY USES A LOCAL IDENTITY
-- --------------------------------------------------------
-- An applicability decision for a custom obligation has nowhere else to
-- live -- dropping the columns underneath it would delete the decision,
-- not just the schema. This script counts such rows and stops rather than
-- guessing whether that is wanted. To force it, delete or reassign those
-- rows first:
--
--     DELETE FROM grac_practice.event_obligation_applicability
--     WHERE local_practice_obligation_id IS NOT NULL
--        OR local_instance_obligation_id IS NOT NULL;
--
-- IF 342/343/344 HAVE ALREADY BEEN APPLIED, ROLL THOSE BACK FIRST
-- -----------------------------------------------------------------
-- vw_pm_event_driven_obligation (342) and the applicability-save /
-- mapping-list / raise procedures (343) read these columns; the two
-- Checklists-tab procedures (344) do too. This script does not check for
-- those dependencies because 341 has no way to know what a later
-- migration might have named -- roll them back in reverse order (344,
-- then 343, then 342) before this one.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (341 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NULL
   AND COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NULL
BEGIN
    PRINT '341 rollback: neither local-identity column is present -- nothing from 341 to remove.';
    SET NOEXEC ON;
END
GO

DECLARE @in_use INT = 0;

IF COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
    OR COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
BEGIN
    DECLARE @sql NVARCHAR(600) = N'SELECT @c = COUNT(*) FROM grac_practice.event_obligation_applicability
                                    WHERE local_practice_obligation_id IS NOT NULL
                                       OR local_instance_obligation_id IS NOT NULL;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @in_use OUTPUT;
END

IF @in_use > 0
BEGIN
    PRINT '341 rollback: ' + CAST(@in_use AS NVARCHAR(20))
        + ' applicability decision(s) name a practice-level or instance-only';
    PRINT '               custom obligation. The columns stay -- dropping them';
    PRINT '               would discard those decisions. Clear them first if the';
    PRINT '               rollback is really wanted (see header).';
END
ELSE
BEGIN
    BEGIN TRAN;

    -- ---- 1. Filtered indexes -> back to 329's single 6-column index ----
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_catalog'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
        DROP INDEX uq_pm_event_obl_app_natural_catalog
            ON grac_practice.event_obligation_applicability;

    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_practice'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
        DROP INDEX uq_pm_event_obl_app_natural_practice
            ON grac_practice.event_obligation_applicability;

    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_instance'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
        DROP INDEX uq_pm_event_obl_app_natural_instance
            ON grac_practice.event_obligation_applicability;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = 'uq_pm_event_obl_app_natural'
                     AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
        CREATE UNIQUE INDEX uq_pm_event_obl_app_natural
            ON grac_practice.event_obligation_applicability(
                organization_id, obligation_id, event_type_id,
                scope_role_id, scope_asset_category_id, profile_id);

    -- ---- 2. The exactly-one-identity CHECK ----
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_obligation_kind')
        ALTER TABLE grac_practice.event_obligation_applicability
            DROP CONSTRAINT ck_pm_event_obl_app_obligation_kind;

    -- ---- 3. The two FKs and columns ----
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_practice_obl')
        ALTER TABLE grac_practice.event_obligation_applicability
            DROP CONSTRAINT fk_pm_event_obl_app_local_practice_obl;

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_instance_obl')
        ALTER TABLE grac_practice.event_obligation_applicability
            DROP CONSTRAINT fk_pm_event_obl_app_local_instance_obl;

    IF COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_obligation_applicability
            DROP COLUMN local_practice_obligation_id;

    IF COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
        ALTER TABLE grac_practice.event_obligation_applicability
            DROP COLUMN local_instance_obligation_id;

    -- ---- 4. obligation_id back to NOT NULL. Safe: the branch above
    --         already established no row is using a local identity, and
    --         the 341 CHECK (just dropped) guaranteed every row had
    --         exactly one identity set, so every remaining row's
    --         obligation_id is populated.
    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
                 AND name = 'obligation_id'
                 AND is_nullable = 1)
        ALTER TABLE grac_practice.event_obligation_applicability
            ALTER COLUMN obligation_id BIGINT NOT NULL;

    COMMIT TRAN;

    PRINT '341 rollback: local-obligation identity removed, 329''s natural-key shape restored.';
END
GO

PRINT '=== 341 rollback verification ===';

SELECT 'local_practice_obligation_id column' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END AS Result
UNION ALL
SELECT 'local_instance_obligation_id column',
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
            THEN 'kept -- rows are using it' ELSE 'dropped' END
UNION ALL
SELECT 'obligation_id nullability',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
                            AND name = 'obligation_id' AND is_nullable = 1)
            THEN 'still NULL-able -- local identity columns still present' ELSE 'NOT NULL (restored)' END
UNION ALL
SELECT 'natural-key index shape',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'uq_pm_event_obl_app_natural'
                            AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
            THEN '329 single index (restored)'
            WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'uq_pm_event_obl_app_natural_catalog'
                            AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
            THEN '341 three filtered indexes (still applied)'
            ELSE 'NEITHER -- unexpected, investigate' END;

PRINT '';
PRINT '341 rollback complete.';
GO

SET NOEXEC OFF;
GO
