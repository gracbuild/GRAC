-- =====================================================================
-- 276 Assurance -> Audit Management menu restructure -- ROLLBACK
--
-- Restores the menu exactly as 274's snapshot had it:
--   * nav-assurance back to menu_name / module_type 'Assurance'
--   * the eight screens back under nav-assurance at orders 460..468
--   * org-assurance-plans / executions / observations back to
--     module_type 'Assurance'
--   * the permission rows 276 created for the containers are deleted,
--     then the two container menus are deleted (permissions first, or
--     the FK on organization_role_menu_permission.menu_id blocks it)
--
-- NOTHING ELSE IS TOUCHED. 276 created no assurance data, so there is
-- none to unwind. Permission rows on the eight screens were never
-- modified by 276 and are not modified here.
--
-- NOTE: 274_menu_master_seed.sql was amended alongside 276. Roll this
-- back and then re-run 274 and the restructure returns. Revert 274's
-- Audit Management lines too if the intent is to keep 'Assurance'.
--
-- Re-runnable: yes. A second run finds nothing to change or delete.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (276 rollback): menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN
    PRINT 'ABORT (276 rollback): nav-assurance is missing -- cannot restore the old parent.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Put the eight screens back under nav-assurance at their 274 orders.
-- ---------------------------------------------------------------------
DECLARE @assurance_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

UPDATE m
SET    parent_menu_id = @assurance_id,
       display_order  = x.old_order,
       module_type    = N'Assurance',
       updated_by     = N'rollback-276',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    (N'org-assurance-definitions'     , 460),
    (N'org-assurance-scope-builder'   , 461),
    (N'org-assurance-question-sets'   , 462),
    (N'org-assurance-evidence-config' , 463),
    (N'org-assurance-workflow-config' , 464),
    (N'org-assurance-scoring-config'  , 465),
    (N'org-assurance-triggers'        , 467),
    (N'org-assurance-scope-resolution', 468)
) AS x(menu_key, old_order) ON x.menu_key = m.menu_key
WHERE  ISNULL(m.parent_menu_id, -1) <> @assurance_id
    OR m.display_order <> x.old_order
    OR ISNULL(m.module_type, N'') <> N'Assurance';

PRINT '276 rollback: screens returned to nav-assurance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. Direct children back to module_type 'Assurance'.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET module_type = N'Assurance',
       updated_by  = N'rollback-276',
       updated_dt  = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-assurance-plans', N'org-assurance-executions', N'org-assurance-observations')
   AND ISNULL(module_type, N'') <> N'Assurance';

PRINT '276 rollback: direct children retyped = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 3. Delete the container permissions, then the containers themselves.
--    Permissions first: organization_role_menu_permission.menu_id has an
--    FK to menu_master, so deleting the menu first would fail.
-- ---------------------------------------------------------------------
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key IN (N'org-audit-definition', N'org-audit-configuration');

PRINT '276 rollback: container permissions deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- Defensive: if anything still points at a container as its parent,
-- detach it rather than let the self-FK block the delete. After step 1
-- this should affect nothing.
UPDATE m
   SET parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance'),
       updated_by     = N'rollback-276',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
WHERE  p.menu_key IN (N'org-audit-definition', N'org-audit-configuration');

DELETE FROM grac_practice.menu_master
 WHERE menu_key IN (N'org-audit-definition', N'org-audit-configuration');

PRINT '276 rollback: container menus deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 4. Rename the group back.
-- ---------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET menu_name   = N'Assurance',
       module_type = N'Assurance',
       icon_class  = N'shield-halved',
       updated_by  = N'rollback-276',
       updated_dt  = SYSUTCDATETIME()
 WHERE menu_key = N'nav-assurance'
   AND (menu_name <> N'Assurance' OR ISNULL(module_type, N'') <> N'Assurance');

PRINT '276 rollback: nav-assurance renamed back = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 5. Sanity report
-- ---------------------------------------------------------------------
SELECT 'Containers removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key IN (N'org-audit-definition', N'org-audit-configuration'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'nav-assurance reads Assurance' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'nav-assurance' AND menu_name = N'Assurance')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName, m.display_order AS Ord,
       m.module_type AS ModuleType, m.status AS Status
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE p.menu_key = N'nav-assurance'
 ORDER BY m.display_order;

PRINT '276 rollback complete.';
GO
SET NOEXEC OFF;
GO
