-- =====================================================================
-- 280 "Assurance" -> "Audit" in Audit Management menu labels -- ROLLBACK
--
-- Restores the two display names 280 changed. Nothing else was touched
-- going forward, so nothing else is touched coming back.
--
-- NOTE: 274_menu_master_seed.sql carries the 280 labels too. Roll this
-- back and then re-run 274 and the rename returns -- revert 274's two
-- menu_name values as well if the intent is to keep "Assurance".
--
-- Re-runnable: yes. A second run reports 0 changes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (280 rollback): menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

UPDATE m
SET    menu_name  = x.old_name,
       updated_by = N'rollback-280',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    (N'org-assurance-definitions', N'Assurance Definitions'),
    (N'org-assurance-plans'      , N'Assurance Plans')
) AS x(menu_key, old_name) ON x.menu_key = m.menu_key
WHERE  m.menu_name <> x.old_name;

PRINT '280 rollback: menu labels restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName, m.status AS Status
  FROM grac_practice.menu_master m
 WHERE m.menu_key IN (N'org-assurance-definitions', N'org-assurance-plans');

PRINT '280 rollback complete.';
GO
SET NOEXEC OFF;
GO
