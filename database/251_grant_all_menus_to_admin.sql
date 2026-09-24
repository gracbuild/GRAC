-- =====================================================================
-- 251 Top up Admin role permissions across every active menu
--
-- WHY
-- ---
-- Migration 022 seeded the Admin role for every organization with all
-- five flags on every menu that existed at the time. Menus added
-- afterwards (Task Centre v2 tabs, Gap Centre, Assurance modules,
-- Document uploads, ...) rely on their own subsequent migrations to
-- top up the Admin grant. On a database restored from an older backup,
-- or one that missed a follow-up migration, the Admin role can end up
-- without permissions on newer forms -- the operator sees a 403 or an
-- empty screen for something the role name promises access to.
--
-- Sir asked for a single re-grant script covering "all forms". This
-- migration walks every active menu in menu_master and, for every
-- Admin role in every organization, ensures the join row exists and
-- carries VIEW / ADD / EDIT / DELETE / APPROVE = 1. Idempotent -- runs
-- again after a new menu is seeded and simply tops up the new one.
--
-- Scope kept narrow:
--   * Only the org-level role named 'Admin'. Any other role that
--     happens to include "admin" in its name is unaffected.
--   * Only menus with status = 'Active'. A retired menu stays retired.
--   * INSERT-if-missing + UPDATE-to-true; never DELETE. A grant the
--     admin already has stays.
--
-- SAFE TO RE-RUN.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (251): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
BEGIN
    PRINT 'ABORT (251): permission tables missing (run 002 / 022 first).';
    SET NOEXEC ON;
END
GO

-- Cache the Active record_status_id once so the two writes below share it.
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id
    FROM   grac_practice.record_status_master
    WHERE  status_code = 'ACTIVE' OR status_name = 'Active'
    ORDER  BY record_status_id);

IF @active_record_status_id IS NULL
    THROW 55251, '251: record status master data is missing.', 1;

-- 1. Insert the missing rows. Every Admin role x every active menu
--    that has no join row today.
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_record_status_id, 'seed-251'
FROM   grac_practice.organization_role r
CROSS  JOIN grac_practice.menu_master m
WHERE  r.role_name = N'Admin'
  AND  r.status    = N'Active'
  AND  m.status    = N'Active'
  AND  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE  p.role_id = r.role_id
          AND  p.menu_id = m.menu_id);

DECLARE @inserted INT = @@ROWCOUNT;

-- 2. Top up rows that already exist but have a flag turned off. Only
--    touched when a flag was 0; a row already fully granted is left
--    with its own updated_dt intact.
UPDATE p
   SET can_view    = 1,
       can_add     = 1,
       can_edit    = 1,
       can_delete  = 1,
       can_approve = 1,
       status      = N'Active',
       updated_by  = 'seed-251',
       updated_dt  = SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
JOIN   grac_practice.menu_master m       ON m.menu_id = p.menu_id
WHERE  r.role_name = N'Admin'
  AND  r.status    = N'Active'
  AND  m.status    = N'Active'
  AND  (p.can_view = 0 OR p.can_add = 0 OR p.can_edit = 0
        OR p.can_delete = 0 OR p.can_approve = 0
        OR p.status <> N'Active');

DECLARE @updated INT = @@ROWCOUNT;

PRINT CONCAT('251: inserted ', @inserted,
             ' new Admin permission rows; topped up ', @updated,
             ' existing rows to full access.');
GO

-- =====================================================================
-- Verification -- every Admin role should now be at (menu-count x 1)
-- =====================================================================
PRINT '=== 251 verification ===';

SELECT '251-a every Admin role has a row for every active menu' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                FROM   grac_practice.organization_role r
                CROSS  JOIN grac_practice.menu_master m
                WHERE  r.role_name = N'Admin'
                  AND  r.status    = N'Active'
                  AND  m.status    = N'Active'
                  AND  NOT EXISTS (
                        SELECT 1 FROM grac_practice.organization_role_menu_permission p
                        WHERE  p.role_id = r.role_id
                          AND  p.menu_id = m.menu_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '251-b no Admin permission row has a flag turned off',
       CASE WHEN NOT EXISTS (
                SELECT 1
                FROM   grac_practice.organization_role_menu_permission p
                JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
                JOIN   grac_practice.menu_master m       ON m.menu_id = p.menu_id
                WHERE  r.role_name = N'Admin'
                  AND  r.status    = N'Active'
                  AND  m.status    = N'Active'
                  AND  (p.can_view = 0 OR p.can_add = 0 OR p.can_edit = 0
                        OR p.can_delete = 0 OR p.can_approve = 0
                        OR p.status <> N'Active'))
            THEN 'PASS' ELSE 'FAIL' END;

-- Per-organization summary so an operator can eyeball which orgs got
-- which counts.
PRINT '';
PRINT '=== Admin permission coverage per organization ===';
SELECT o.organization_id, o.organization_name,
       COUNT(*) AS AdminMenuRows,
       SUM(CASE WHEN p.can_view = 1 AND p.can_add = 1 AND p.can_edit = 1
                       AND p.can_delete = 1 AND p.can_approve = 1
                 THEN 1 ELSE 0 END) AS FullAccessRows
FROM   grac_practice.organization o
JOIN   grac_practice.organization_role r
       ON r.organization_id = o.organization_id AND r.role_name = N'Admin' AND r.status = N'Active'
JOIN   grac_practice.organization_role_menu_permission p
       ON p.role_id = r.role_id
GROUP  BY o.organization_id, o.organization_name
ORDER  BY o.organization_id;

PRINT '';
PRINT '251 complete. Admin has view/add/edit/delete/approve on every active menu.';
GO

SET NOEXEC OFF;
GO
