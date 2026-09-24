-- =====================================================================
-- 305 Enable Gap Center / Task Center / Exception Centre -- ROLLBACK
--
-- Undoes only what 305 wrote, identified by entered_by / updated_by
-- 'seed-305':
--   1. per-org feature_flag rows 305 INSERTED are deleted; rows it only
--      RAISED from 0 to 1 are set back to 0 (they existed before, so
--      deleting them would lose an operator's earlier decision).
--   2. menu grants 305 INSERTED are deleted; grants it only RAISED are
--      listed for manual review rather than zeroed -- 305 tops up five
--      flags at once and the pre-run combination is not recorded, so
--      resetting them would invent a state the row never had.
--   3. feature_flag_master rows 305 added are deleted, but only if no
--      organisation still references them.
--
-- NOT REVERTED
--   menu_master.status. 305 only ever raises a row to 'Active', which is
--   the value 274_menu_master_seed.sql declares for all four keys. Undoing
--   that would put the snapshot and the database out of step -- switch a
--   menu off deliberately with its own migration instead (the 288 / 289
--   pattern).
--
-- Set @OrganizationId to match the forward run if it was scoped.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all organizations

IF OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (305 rollback): feature_flag missing -- nothing to do.';
    SET NOEXEC ON;
END

-- 1a. Rows 305 raised from 0 -> 1 go back to 0.
UPDATE ff
SET    is_enabled = 0,
       notes      = NULL,
       updated_by = N'rollback-305',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.feature_flag ff
WHERE  ff.updated_by = N'seed-305'
   AND ff.entered_by <> N'seed-305'
   AND (@OrganizationId IS NULL OR ff.organization_id = @OrganizationId);

PRINT '305 rollback: raised flags reset = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 1b. Rows 305 created are removed outright.
DELETE ff
FROM   grac_practice.feature_flag ff
WHERE  ff.entered_by = N'seed-305'
   AND (@OrganizationId IS NULL OR ff.organization_id = @OrganizationId);

PRINT '305 rollback: created flags deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

DECLARE @OrganizationId BIGINT = NULL;   -- keep in step with the value above

-- 2. Menu grants.
--
--    Rows 305 only RAISED are REPORTED, not reset. 305 tops up five
--    flags at once and the pre-run combination is not recorded anywhere,
--    so a blanket can_view = 0 would invent a state the row never had --
--    and would strip an administrator who legitimately held the grant
--    before 305 ran. Review the list and adjust from the Role Menu
--    Permission screen if any of them should come back down.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    SELECT 'Raised by 305 -- review manually' AS Note_,
           r.organization_id AS OrganizationId,
           r.role_name       AS RoleName,
           m.menu_key        AS MenuKey,
           p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve
    FROM   grac_practice.organization_role_menu_permission p
    JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
    JOIN   grac_practice.menu_master m       ON m.menu_id = p.menu_id
    WHERE  p.updated_by = N'seed-305'
       AND p.entered_by <> N'seed-305'
       AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId)
    ORDER BY r.organization_id, r.role_name, m.menu_key;

    DELETE p
    FROM   grac_practice.organization_role_menu_permission p
    JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
    WHERE  p.entered_by = N'seed-305'
       AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

    PRINT '305 rollback: created grants deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- 3. Master rows 305 added, only when nothing points at them any more.
DELETE m
FROM   grac_practice.feature_flag_master m
WHERE  m.entered_by = N'seed-305'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag ff
                    WHERE ff.feature_flag_id = m.feature_flag_id);

PRINT '305 rollback: unused master rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

PRINT '305 rollback complete.';
GO
SET NOEXEC OFF;
GO
