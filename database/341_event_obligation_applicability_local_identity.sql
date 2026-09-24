-- =====================================================================
-- 341 Local-obligation identity on event_obligation_applicability
--
-- WHAT AND WHY
-- ------------
-- event_obligation_applicability (127) decides, per organisation/event/
-- scope, whether ONE obligation applies -- keyed by obligation_id, a soft
-- reference into GRAC_New.requirement_obligation because catalog
-- obligations live in a different database. An organisation-authored
-- obligation (227, extended practice-level by 307, and as of 340 able to
-- declare an event_type_id) has no GRAC_New id at all, so it has never
-- had anywhere to record an applicability decision. This migration gives
-- it one.
--
-- WHY TWO NEW COLUMNS, NOT A POLYMORPHIC ONE
-- --------------------------------------------
-- Confirmed with sir (AskUserQuestion, 2026-09-14): SQL Server cannot FK a
-- single column to "either of two tables", so a real, same-database FK for
-- each kind means two nullable columns, not one. The natural identity for
-- an organisation-authored obligation is:
--
--   authored at practice level (307)   -> practice_obligation_id
--     One applicability decision then covers every instance of that
--     practice, mirroring how a catalog obligation's decision covers
--     every instance today -- the practice fans the obligation out;
--     applicability should not have to be re-decided per instance.
--   instance-only (227, no practice-level parent)
--                                       -> practice_instance_obligation_id
--     There is no broader identity available for this case -- the
--     obligation only exists on the one instance it was added to.
--
-- So the row now carries exactly one of three obligation-identity
-- columns:
--
--   obligation_id                 catalog, soft ref GRAC_New (unchanged)
--   local_practice_obligation_id  practice-level custom, real FK (new)
--   local_instance_obligation_id  instance-only custom, real FK (new)
--
-- obligation_id CHANGES FROM NOT NULL TO NULL
-- ----------------------------------------------
-- It has to: a row deciding a custom obligation's applicability has no
-- GRAC_New id to put there. Every existing row is catalog-sourced and
-- already has obligation_id populated, so relaxing the constraint changes
-- nothing about data already in the table -- only what a NEW row is
-- allowed to look like.
--
-- THE NATURAL-KEY INDEX HAS TO BE REPLACED, NOT JUST WIDENED
-- --------------------------------------------------------------
-- uq_pm_event_obl_app_natural (widened to 6 columns by 329, adding
-- profile_id) is a single unqualified unique index. SQL Server treats
-- NULLs as equal within one, so once obligation_id can be NULL, two
-- different custom-obligation rows for the same event/scope would collide
-- on it -- exactly the problem 329's own header describes for profile_id,
-- solved the same way it solved that one: filtered indexes, one per
-- population, so a NULL in the OTHER two identity columns never counts as
-- a match. Three filtered unique indexes replace the one general-purpose
-- index; each fires only for the population whose identity column it
-- names.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- -------------------------------------
-- Reading which decisions apply (ix_pm_event_obl_app_resolve,
-- ix_pm_event_obl_app_by_role, ix_pm_event_obl_app_by_asset_cat,
-- ix_pm_event_obl_app_by_profile) is untouched -- none of them key on
-- obligation_id, only carry it as an INCLUDE column, so they already work
-- regardless of which identity column a row carries. vw_pm_event_driven_obligation
-- (127), sp_event_obligation_mapping_list / sp_event_obligation_applicability_save
-- / sp_event_obligation_raise (128/331) and the two new Checklists-tab
-- procedures are 342/343/344's work, in that order -- this migration is
-- schema only, so that each later step can be verified against a stable
-- foundation rather than a moving one.
--
-- obligation_label stays a single free-text display snapshot column,
-- reused for whichever kind of obligation the row names -- it was already
-- "display snapshot", not "catalog display snapshot", so no new column is
-- needed for that.
--
-- SAFE TO RE-RUN. Requires 127, 307, 329, 340.
-- ASCII-only.
--
-- DEPENDS ON: 127 (event_obligation_applicability), 307 (practice_obligation),
--             329 (profile_id / the 3-branch scope CHECK this migration
--             does not touch), 340 (event_type_id on the two obligation
--             kinds this migration gives an identity to).
-- Rollback:   database/341_event_obligation_applicability_local_identity_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (341): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL
BEGIN
    PRINT 'ABORT (341): event_obligation_applicability missing (run 127 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (341): practice_obligation missing (run 307 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (341): practice_instance_obligation missing.';
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. obligation_id becomes nullable
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
             AND name = 'obligation_id'
             AND is_nullable = 0)
BEGIN
    ALTER TABLE grac_practice.event_obligation_applicability
        ALTER COLUMN obligation_id BIGINT NULL;
    PRINT '341: obligation_id relaxed to NULL-able.';
END
GO

-- =====================================================================
-- 2. Two new identity columns, each a real FK -- same database, unlike
--    obligation_id's soft reference into GRAC_New.
-- =====================================================================
IF COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD local_practice_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_practice_obl')
   AND COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD CONSTRAINT fk_pm_event_obl_app_local_practice_obl
            FOREIGN KEY (local_practice_obligation_id)
            REFERENCES grac_practice.practice_obligation(practice_obligation_id);
GO

IF COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD local_instance_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_instance_obl')
   AND COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD CONSTRAINT fk_pm_event_obl_app_local_instance_obl
            FOREIGN KEY (local_instance_obligation_id)
            REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id);
GO

PRINT '341: local_practice_obligation_id and local_instance_obligation_id added.';
GO

-- =====================================================================
-- 3. Exactly one of the three obligation-identity columns must be set.
--    Same reasoning 307 gives for its own three-kind split: a row that
--    names two, or none, is not a real decision about anything.
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_obligation_kind')
   AND COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
   AND COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_obligation_applicability
        ADD CONSTRAINT ck_pm_event_obl_app_obligation_kind CHECK (
            (CASE WHEN obligation_id                  IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_practice_obligation_id    IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_instance_obligation_id    IS NOT NULL THEN 1 ELSE 0 END) = 1);
GO

PRINT '341: ck_pm_event_obl_app_obligation_kind added.';
GO

-- =====================================================================
-- 4. Natural key: one filtered unique index per identity kind, replacing
--    329's single 6-column index. Same technique 329 used to add
--    profile_id as a third mutually-exclusive scope -- this is a third
--    mutually-exclusive OBLIGATION identity, same problem, same fix.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_event_obl_app_natural'
             AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    DROP INDEX uq_pm_event_obl_app_natural
        ON grac_practice.event_obligation_applicability;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_catalog'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE UNIQUE INDEX uq_pm_event_obl_app_natural_catalog
        ON grac_practice.event_obligation_applicability(
            organization_id, obligation_id, event_type_id,
            scope_role_id, scope_asset_category_id, profile_id)
        WHERE obligation_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_practice'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE UNIQUE INDEX uq_pm_event_obl_app_natural_practice
        ON grac_practice.event_obligation_applicability(
            organization_id, local_practice_obligation_id, event_type_id,
            scope_role_id, scope_asset_category_id, profile_id)
        WHERE local_practice_obligation_id IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_obl_app_natural_instance'
                 AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
    CREATE UNIQUE INDEX uq_pm_event_obl_app_natural_instance
        ON grac_practice.event_obligation_applicability(
            organization_id, local_instance_obligation_id, event_type_id,
            scope_role_id, scope_asset_category_id, profile_id)
        WHERE local_instance_obligation_id IS NOT NULL;
GO

PRINT '341: three filtered unique indexes replace uq_pm_event_obl_app_natural.';
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 341 verification ===';

SELECT '341-a obligation_id is NULL-able' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
                            AND name = 'obligation_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '341-b local_practice_obligation_id column + FK',
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_practice_obl')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '341-c local_instance_obligation_id column + FK',
       CASE WHEN COL_LENGTH('grac_practice.event_obligation_applicability','local_instance_obligation_id') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_obl_app_local_instance_obl')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '341-d exactly-one-identity CHECK present',
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_obl_app_obligation_kind')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '341-e old 6-column natural-key index gone',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.indexes
                              WHERE name = 'uq_pm_event_obl_app_natural'
                                AND object_id = OBJECT_ID('grac_practice.event_obligation_applicability'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '341-f three filtered natural-key indexes present',
       CASE WHEN (SELECT COUNT(*) FROM sys.indexes
                   WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
                     AND name IN ('uq_pm_event_obl_app_natural_catalog',
                                  'uq_pm_event_obl_app_natural_practice',
                                  'uq_pm_event_obl_app_natural_instance')) = 3
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: every existing row is catalog-sourced (there was no
-- other kind before this migration), so the CHECK must not be violated by
-- data already there.
SELECT '341-g existing rows satisfy the new CHECK',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.event_obligation_applicability
                 WHERE (CASE WHEN obligation_id                IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_practice_obligation_id  IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_instance_obligation_id  IS NOT NULL THEN 1 ELSE 0 END) <> 1)
            THEN 'PASS' ELSE 'FAIL -- a row names zero or multiple obligation identities' END;

PRINT '';
PRINT '341 complete. event_obligation_applicability can now decide';
PRINT 'applicability for a practice-level or instance-only custom';
PRINT 'obligation, not only a catalog one. Next: 342 teaches the';
PRINT 'Configure-Checklists source view to offer those obligations.';
GO

SET NOEXEC OFF;
GO
