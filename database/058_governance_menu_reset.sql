-- =====================================================================
-- 058 Governance menu reset -- reassert the Governance sidebar to:
--
--     Repository Subscriptions  ->  Practice/Index/organization-controls
--                                   (RS2 release summary; the "Level 1"
--                                    grid the user calls the Organization
--                                    Controls page)
--     Source Statements         ->  Practice/Index/source-statements
--                                   (RS3 statement grid; auto-drilled from
--                                    the Repository Subscriptions view --
--                                    the "Level 2" drill-down of the
--                                    Organization Controls page)
--     (no "Organization Controls" menu row)
--
-- Why:
--   User needs the sidebar to show a single Repository Subscriptions entry
--   under Governance that opens the organization-controls URL, plus a
--   Source Statements entry whose URL drills into the same view. Legacy
--   variants that surface an "Organization Controls" menu label or point
--   Repository Subscriptions at the RS1 admin URL must not appear.
--
--   Migration 056 already lays this out, but 058 makes the end state
--   idempotent and safe to re-run in environments where 056 is partially
--   applied or was rolled back and re-applied.
--
-- Rename order matters -- menu_key has a UNIQUE constraint. Steps:
--   1. Free the target 'source-statements' key: any existing row whose
--      URL / label already claims Source Statements gets renamed there.
--      If a row already sits at 'source-statements' with the correct
--      target we leave it alone.
--   2. Free the 'organization-controls' key so the Repository Subscriptions
--      row can adopt it. Any legacy row still labelled "Organization
--      Controls" is renamed and repurposed to Repository Subscriptions.
--   3. Reserve the historical 'repository-subscriptions' key as an
--      Inactive admin row so /Practice/Index/repository-subscriptions
--      keeps resolving for bookmarked admin flows without appearing in
--      the sidebar.
--
-- ASCII-only. Idempotent. Rollback: 058_governance_menu_reset_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('058: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1. Ensure a row exists at menu_key='source-statements' pointing at
--         /Practice/Index/source-statements. If a legacy row still uses
--         menu_key='organization-controls' with label "Source Statements"
--         (051 state), rename it. If nothing matches yet, insert fresh.
-- ---------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'source-statements')
BEGIN
    IF EXISTS (
        SELECT 1 FROM grac_practice.menu_master
        WHERE menu_key = N'organization-controls'
          AND (menu_name = N'Source Statements' OR menu_url = N'Practice/Index/source-statements')
    )
    BEGIN
        UPDATE grac_practice.menu_master
           SET menu_key      = N'source-statements',
               menu_name     = N'Source Statements',
               menu_url      = N'Practice/Index/source-statements',
               display_order = 105,
               icon_class    = N'file-lines',
               module_type   = N'Governance',
               status        = N'Active',
               updated_by    = 'seed-058',
               updated_dt    = SYSUTCDATETIME()
         WHERE menu_key = N'organization-controls'
           AND (menu_name = N'Source Statements' OR menu_url = N'Practice/Index/source-statements');
    END
    ELSE
    BEGIN
        INSERT INTO grac_practice.menu_master
            (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
        VALUES
            (N'source-statements',
             N'Source Statements',
             N'Practice/Index/source-statements',
             105, N'file-lines', N'Governance', N'Active', 'seed-058');
    END
END
ELSE
BEGIN
    -- Row already exists -- reassert the target values (idempotent).
    UPDATE grac_practice.menu_master
       SET menu_name     = N'Source Statements',
           menu_url      = N'Practice/Index/source-statements',
           display_order = 105,
           icon_class    = N'file-lines',
           module_type   = N'Governance',
           status        = N'Active',
           updated_by    = 'seed-058',
           updated_dt    = SYSUTCDATETIME()
     WHERE menu_key = N'source-statements';
END
GO

-- ---------------------------------------------------------------------------
-- Step 2. Ensure a row exists at menu_key='organization-controls' pointing
--         at /Practice/Index/organization-controls labelled "Repository
--         Subscriptions". Rename the legacy 'repository-subscriptions' row
--         (from 002/022 initial seed) if present, otherwise insert fresh.
--         Any pre-existing 'organization-controls' row still labelled
--         "Organization Controls" (from 002 initial seed) is repurposed to
--         Repository Subscriptions in place.
-- ---------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM grac_practice.menu_master
    WHERE menu_key = N'organization-controls'
      AND menu_name = N'Repository Subscriptions'
)
BEGIN
    IF EXISTS (
        SELECT 1 FROM grac_practice.menu_master
        WHERE menu_key = N'organization-controls'
    )
    BEGIN
        UPDATE grac_practice.menu_master
           SET menu_name     = N'Repository Subscriptions',
               menu_url      = N'Practice/Index/organization-controls',
               display_order = 100,
               icon_class    = N'bookmark',
               module_type   = N'Governance',
               status        = N'Active',
               updated_by    = 'seed-058',
               updated_dt    = SYSUTCDATETIME()
         WHERE menu_key = N'organization-controls';
    END
    ELSE IF EXISTS (
        SELECT 1 FROM grac_practice.menu_master
        WHERE menu_key = N'repository-subscriptions'
          AND menu_name IN (N'Repository Subscriptions', N'Repository Subscriptions (Admin)')
    )
    BEGIN
        UPDATE grac_practice.menu_master
           SET menu_key      = N'organization-controls',
               menu_name     = N'Repository Subscriptions',
               menu_url      = N'Practice/Index/organization-controls',
               display_order = 100,
               icon_class    = N'bookmark',
               module_type   = N'Governance',
               status        = N'Active',
               updated_by    = 'seed-058',
               updated_dt    = SYSUTCDATETIME()
         WHERE menu_key = N'repository-subscriptions';
    END
    ELSE
    BEGIN
        INSERT INTO grac_practice.menu_master
            (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
        VALUES
            (N'organization-controls',
             N'Repository Subscriptions',
             N'Practice/Index/organization-controls',
             100, N'bookmark', N'Governance', N'Active', 'seed-058');
    END
END
ELSE
BEGIN
    -- Row already correct -- reassert URL / group in case something else
    -- moved it (idempotent).
    UPDATE grac_practice.menu_master
       SET menu_url      = N'Practice/Index/organization-controls',
           display_order = 100,
           icon_class    = N'bookmark',
           module_type   = N'Governance',
           status        = N'Active',
           updated_by    = 'seed-058',
           updated_dt    = SYSUTCDATETIME()
     WHERE menu_key = N'organization-controls'
       AND menu_name = N'Repository Subscriptions';
END
GO

-- ---------------------------------------------------------------------------
-- Step 3. Preserve the historical 'repository-subscriptions' key for the
--         RS1 admin URL, but keep it out of the sidebar (Inactive).
--         Only insert if Step 2 already consumed the original row.
-- ---------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'repository-subscriptions')
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES
        (N'repository-subscriptions',
         N'Repository Subscriptions (Admin)',
         N'Practice/Index/repository-subscriptions',
         999, N'bookmark', N'Governance', N'Inactive', 'seed-058');
END
ELSE
BEGIN
    -- Existing row -- force Inactive so it never appears in the sidebar,
    -- but leave the URL intact so admin bookmarks still resolve.
    UPDATE grac_practice.menu_master
       SET menu_name  = N'Repository Subscriptions (Admin)',
           menu_url   = N'Practice/Index/repository-subscriptions',
           status     = N'Inactive',
           updated_by = 'seed-058',
           updated_dt = SYSUTCDATETIME()
     WHERE menu_key = N'repository-subscriptions';
END
GO

-- ---------------------------------------------------------------------------
-- Step 4. Sweep -- any residual sidebar row still labelled "Organization
--         Controls" or "Organization Control" gets deactivated. We only
--         touch rows whose URL is one of the known RS-1/RS-2 targets so we
--         never disable an unrelated custom menu that happens to share the
--         name.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = 'seed-058',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_name IN (N'Organization Controls', N'Organization Control')
   AND status    = N'Active'
   AND menu_key NOT IN (N'organization-controls', N'source-statements', N'repository-subscriptions');
GO

COMMIT TRAN;

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT menu_key, menu_name, menu_url, display_order, module_type, status
FROM grac_practice.menu_master
WHERE menu_key IN (N'organization-controls', N'source-statements', N'repository-subscriptions')
   OR menu_name IN (N'Organization Controls', N'Organization Control',
                    N'Repository Subscriptions', N'Source Statements')
ORDER BY status DESC, display_order;

PRINT '058 governance menu reset complete.';
PRINT '  Governance sidebar now shows: Repository Subscriptions -> /organization-controls,';
PRINT '  Source Statements -> /source-statements. No "Organization Controls" sidebar entry.';
GO

SET NOEXEC OFF;
GO
