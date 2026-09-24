-- =====================================================================
-- 281 UAT: enable Audit Management -- ROLLBACK
--
-- Undoes only what 281 wrote, identified by entered_by / updated_by
-- 'seed-281':
--   1. per-org feature_flag rows 281 INSERTED are deleted; rows it only
--      RAISED from 0 to 1 are set back to 0 (they existed before, so
--      deleting them would lose an operator's earlier decision).
--   2. menu view grants 281 INSERTED are deleted; grants it RAISED are
--      set back to can_view = 0.
--   3. feature_flag_master rows 281 added are deleted, but only if no
--      organization still references them.
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

DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all active organizations

IF OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    PRINT 'ABORT (281 rollback): feature_flag missing -- nothing to do.';
    SET NOEXEC ON;
END

-- 1a. Rows 281 raised from 0 -> 1 go back to 0.
UPDATE ff
SET    is_enabled = 0,
       notes      = NULL,
       updated_by = N'rollback-281',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.feature_flag ff
WHERE  ff.updated_by = N'seed-281'
   AND ff.entered_by <> N'seed-281'
   AND (@OrganizationId IS NULL OR ff.organization_id = @OrganizationId);

PRINT '281 rollback: raised flags reset = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 1b. Rows 281 created are removed outright.
DELETE ff
FROM   grac_practice.feature_flag ff
WHERE  ff.entered_by = N'seed-281'
   AND (@OrganizationId IS NULL OR ff.organization_id = @OrganizationId);

PRINT '281 rollback: created flags deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

DECLARE @OrganizationId BIGINT = NULL;   -- keep in step with the value above

-- 2. Menu grants.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    UPDATE p
    SET    can_view   = 0,
           updated_by = N'rollback-281',
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.organization_role_menu_permission p
    JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
    WHERE  p.updated_by = N'seed-281'
       AND p.entered_by <> N'seed-281'
       AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

    PRINT '281 rollback: raised grants reset = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    DELETE p
    FROM   grac_practice.organization_role_menu_permission p
    JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
    WHERE  p.entered_by = N'seed-281'
       AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

    PRINT '281 rollback: created grants deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- 3. Master rows 281 added, only when nothing points at them any more.
DELETE m
FROM   grac_practice.feature_flag_master m
WHERE  m.entered_by = N'seed-281'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.feature_flag ff
                    WHERE ff.feature_flag_id = m.feature_flag_id);

PRINT '281 rollback: unused master rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

PRINT '281 rollback complete.';
GO
SET NOEXEC OFF;
GO
