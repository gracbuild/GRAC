-- =====================================================================
-- 275 Move Calendar from Assurance to Oversight -- ROLLBACK
--
-- Puts the 'assurance-calendar' row back exactly where 274's snapshot
-- had it:
--     parent_menu_id -> nav-assurance
--     module_type    -> 'Assurance'
--     display_order  -> 455
--
-- Nothing was created by 275, so nothing is deleted here. menu_id is
-- untouched in both directions, so permissions are unaffected by the
-- rollback just as they were unaffected by the move.
--
-- NOTE: 274_menu_master_seed.sql was updated alongside 275 so the
-- authoritative snapshot agrees with the new placement. If you roll 275
-- back and then re-run 274, 274 will move Calendar to Oversight again.
-- Revert the two 'assurance-calendar' lines in 274 as well if the intent
-- is to keep Calendar under Assurance permanently.
--
-- Re-runnable: yes. A second run reports 0 rows changed.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (275 rollback): grac_practice.menu_master missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN
    PRINT 'ABORT (275 rollback): nav-assurance is missing -- cannot restore the old parent.';
    SET NOEXEC ON;
END
GO

DECLARE @assurance_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

UPDATE grac_practice.menu_master
   SET parent_menu_id = @assurance_id,
       module_type    = N'Assurance',
       display_order  = 455,
       updated_by     = N'rollback-275',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'assurance-calendar'
   AND (ISNULL(parent_menu_id, -1) <> @assurance_id
        OR ISNULL(module_type, N'') <> N'Assurance'
        OR display_order <> 455);

PRINT '275 rollback: Calendar rows returned to Assurance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

SELECT p.menu_key AS Parent, m.menu_key AS ChildMenu, m.menu_name AS ChildName,
       m.module_type AS ModuleType, m.display_order AS DisplayOrder, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key = N'assurance-calendar';

PRINT '275 rollback complete.';
GO
SET NOEXEC OFF;
GO
