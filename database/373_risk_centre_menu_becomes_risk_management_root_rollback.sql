-- =====================================================================
-- 373 ROLLBACK -- "Risk Management" back to "Risk Centre" under
-- Oversight
--
-- Restores menu_master.risk-centre to exactly the state 171/274 left it
-- in: menu_name 'Risk Centre', parent nav-oversight, module_type
-- 'Oversight', display_order 280 (unchanged either way).
--
-- menu_key, menu_url, menu_id and every organization_role_menu_permission
-- row are untouched either way -- nothing to roll back there.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('373 rollback: grac_practice.menu_master missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight')
BEGIN
    RAISERROR('373 rollback: nav-oversight parent row is missing -- cannot restore prior parent.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name      = N'Risk Centre',
       parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight'),
       module_type    = N'Oversight',
       display_order  = 280,
       status         = N'Active',
       updated_by     = 'seed-373-rollback',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre';

PRINT '373 rollback: risk-centre restored to Risk Centre under Oversight = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '373 rollback: menu_name restored' AS Check_,
       CASE WHEN (SELECT menu_name FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') = N'Risk Centre'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '373 rollback: parent restored to nav-oversight',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                WHERE m.menu_key = N'risk-centre' AND p.menu_key = N'nav-oversight')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '373 rollback: module_type restored to Oversight',
       CASE WHEN (SELECT module_type FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') = N'Oversight'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '373 rollback complete. risk-centre is back under Oversight,';
PRINT '     labelled Risk Centre -- back to pre-373 behaviour.';
GO
SET NOEXEC OFF;
GO
