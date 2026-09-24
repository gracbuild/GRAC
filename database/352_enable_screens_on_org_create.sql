-- =====================================================================
-- 352_enable_screens_on_org_create.sql
--
-- GOAL
--   When an organization is created, enable ALL centers/screens for it
--   automatically -- Gap Center, Task Center, Risk Register, etc. -- so a
--   new org never lands on "<Center> is not yet enabled".
--
-- WHY A TRIGGER (not an edit to the org-create proc)
--   The enabling routine (pm_grant_organization_default_access) already
--   turns on every active 'screen.%' flag, but the app's org-create path
--   (pm_manage_practice_repository, entity 'organization-setup') never
--   calls it. Rather than surgically edit that 3,000-line, XACT_ABORT
--   atomic proc (where any added statement that throws would roll back the
--   whole org creation), this wires the behaviour in at the table level:
--   an AFTER INSERT trigger that enables every active screen flag for the
--   new org. It covers EVERY creation path (the app, setup scripts, tools),
--   and a future new screen is picked up automatically (LIKE 'screen.%').
--
--   The insert is a guarded NOT EXISTS insert (no conversions, no divides)
--   so it cannot realistically throw and cannot doom the org insert.
--   It only ADDS missing enable rows; an org that deliberately disabled a
--   screen (its own is_enabled = 0 row) is left untouched.
--
-- Also backfills existing orgs that are missing any screen flag, so the
-- current data matches the new rule too. Supersedes 351 (broader: all
-- screens, all orgs); 351 remains harmless.
--
-- SAFE TO RE-RUN. ASCII-only.
-- Rollback: 352_enable_screens_on_org_create_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    RAISERROR('352: feature_flag / organization tables missing -- run 041 first.', 16, 1);
END
GO

-- ---------------------------------------------------------------------
-- 1. AFTER INSERT trigger: enable every active screen flag for a new org.
-- ---------------------------------------------------------------------
CREATE OR ALTER TRIGGER grac_practice.tr_pm_organization_enable_screens
ON grac_practice.organization
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
       OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
        RETURN;

    INSERT grac_practice.feature_flag
        (organization_id, feature_flag_id, is_enabled, notes, entered_by)
    SELECT i.organization_id, m.feature_flag_id, 1,
           N'Enabled at organization creation', N'org-create'
    FROM   inserted i
    CROSS  JOIN grac_practice.feature_flag_master m
    WHERE  m.feature_code LIKE N'screen.%'
      AND  i.organization_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag ff
                       WHERE ff.organization_id = i.organization_id
                         AND ff.feature_flag_id = m.feature_flag_id);
END
GO
PRINT '352: tr_pm_organization_enable_screens ready (new orgs get every screen flag ON).';
GO

-- ---------------------------------------------------------------------
-- 2. Backfill existing orgs that are missing any screen flag. Only adds
--    missing rows; deliberate per-org disables are preserved.
-- ---------------------------------------------------------------------
INSERT grac_practice.feature_flag
    (organization_id, feature_flag_id, is_enabled, notes, entered_by)
SELECT o.organization_id, m.feature_flag_id, 1,
       N'Backfilled by 352', N'seed-352'
FROM   grac_practice.organization o
CROSS  JOIN grac_practice.feature_flag_master m
WHERE  m.feature_code LIKE N'screen.%'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag ff
                   WHERE ff.organization_id = o.organization_id
                     AND ff.feature_flag_id = m.feature_flag_id);
PRINT CONCAT('352: backfilled screen-flag enable rows for existing orgs = ', @@ROWCOUNT);
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
PRINT '=== 352 verification ===';
SELECT CASE WHEN OBJECT_ID('grac_practice.tr_pm_organization_enable_screens','TR') IS NOT NULL
            THEN 'PASS -- trigger present' ELSE 'FAIL' END AS TriggerCheck;

-- Every org should now be missing zero screen flags.
SELECT CASE WHEN NOT EXISTS (
          SELECT 1
          FROM   grac_practice.organization o
          CROSS  JOIN grac_practice.feature_flag_master m
          WHERE  m.feature_code LIKE N'screen.%'
            AND  NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag ff
                             WHERE ff.organization_id = o.organization_id
                               AND ff.feature_flag_id = m.feature_flag_id))
            THEN 'PASS -- every org has a row for every screen flag'
            ELSE 'INFO -- some orgs still missing rows (deliberately disabled?)' END AS BackfillCheck;
GO
