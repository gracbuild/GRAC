-- =====================================================================
-- 332 ROLLBACK -- Event Profiles menu, permissions and feature flag
--
-- Removes the navigation only. No profile, criterion or applicability
-- row is touched: the screen disappearing is a navigation decision, and
-- the organisation's configuration is not.
--
-- The feature_flag_master row is marked inactive rather than deleted,
-- following 138's reasoning: deleting it would silently discard whichever
-- organisations had deliberately switched the screen OFF, and that record
-- is worth more than a tidy table. The per-organisation feature_flag rows
-- ARE deleted -- they were created by this migration and mean nothing
-- once the menu is gone.
--
-- Also remove the matching row from 274_menu_master_seed.sql, or its
-- next run re-creates the menu entry this script just deleted.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

BEGIN TRAN;

-- Permissions first -- they reference menu_id.
DELETE p
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE  m.menu_key = N'event-profiles';
GO

DELETE FROM grac_practice.menu_master
 WHERE menu_key = N'event-profiles';
GO

DELETE f
FROM   grac_practice.feature_flag f
JOIN   grac_practice.feature_flag_master fm ON fm.feature_flag_id = f.feature_flag_id
WHERE  fm.feature_code = N'screen.event-profiles';
GO

UPDATE grac_practice.feature_flag_master
   SET is_active   = 0,
       description = N'RETIRED by the 332 rollback.',
       updated_by  = 'seed-332-rollback',
       updated_dt  = SYSUTCDATETIME()
 WHERE feature_code = N'screen.event-profiles';
GO

COMMIT TRAN;
GO

SELECT 'event-profiles menu removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'event-profiles')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'profile data untouched',
       CASE WHEN OBJECT_ID('grac_practice.event_profile','U') IS NOT NULL THEN 'PASS' ELSE 'N/A' END;

PRINT '332 rollback complete. Profile data was not touched.';
PRINT 'Remove the event-profiles row and parent link from 274_menu_master_seed.sql as well.';
GO

SET NOEXEC OFF;
GO
