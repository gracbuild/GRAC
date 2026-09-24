-- =====================================================================
-- 288 Retire the Practice Instances screen
--     (Practice Instance form slimming -- the end of it)
--
-- WHY IT CAN GO NOW
-- -----------------
-- Every job that screen still held has a home elsewhere, and each one
-- was moved deliberately rather than assumed:
--
--   create an instance      Configure, per team          (139)
--   name / code / owner     derived by Configure         (139)
--   profile: practice type,
--   criticality, business
--   function, owner         Operationalize, Save profile (222)
--   obligations, evidence,
--   dependencies            Operationalize               (140/141/222)
--   retire                  Operationalize -- workspace  (222)
--                           and now the row menu         (287)
--   restore                 Operationalize -- both       (287)
--   see retired instances   Operationalize, Show retired (287)
--   list every instance     Operationalize, for anyone
--                           with organisation-wide scope (141)
--   drill down from a
--   Practice / Requirement  Operationalize, filtered     (287)
--
-- The last two entries are what 287 added; without them this migration
-- would have broken the "Practice Instances" row action on Practices and
-- on Organization Requirements, and left retired instances unreachable.
-- 288 must not run before 287.
--
-- ---------------------------------------------------------------------
-- ONE BEHAVIOUR CHANGE, STATED PLAINLY
-- ---------------------------------------------------------------------
-- 002's 'practice-instances' branch has NO owner predicate: it is
-- organisation-scoped only, so any user with VIEW on that menu sees
-- every instance in the organisation. sp_resolve_instance_list does have
-- one:
--
--     AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
--
-- and @is_admin is stamped from the session's DATA SCOPE -- GLOBAL or
-- ORGANIZATION = 1, EMPLOYEE = 0.
--
-- So after this migration an EMPLOYEE-SCOPED user no longer sees
-- instances they do not own. Everyone with organisation-wide scope is
-- unaffected; they already saw everything through Operationalize.
--
-- That is the intended outcome -- the grid being retired was handing
-- employee-scoped users a view their data scope does not grant -- but it
-- IS a change, and if some employee-scoped role genuinely needs the
-- organisation-wide list, the answer is a permission, not this screen.
--
-- ---------------------------------------------------------------------
-- HIDDEN, NOT DELETED -- the 279 pattern
-- ---------------------------------------------------------------------
-- The row is set to 'Inactive'. Deleting it would cascade into
-- organization_role_menu_permission (menu_id FK) and throw away every
-- per-screen grant, which would have to be rebuilt if this is reversed.
-- Only 'Active' passes the sidebar and permission filters, so Inactive
-- is exactly "not shown" -- the row, its id and its grants all survive.
--
-- The ROUTE stays alive: PracticeController resolves a screen from
-- PracticeScreen.All, not from menu_master, so an existing deep link to
-- /Practice/Index/practice-instances still opens. That is deliberate for
-- one release -- bookmarks and any hard-coded link keep working while
-- the sidebar stops offering it.
--
-- NO INSTANCE DATA IS TOUCHED. This script reads and writes menu_master
-- only. practice_instance rows, and the 27 foreign keys that depend on
-- them, are untouched and must stay that way -- the TABLE is not being
-- retired, the SCREEN is.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/288_retire_practice_instances_screen_rollback.sql
-- DEPENDS ON: 287 (the drill-down filters and restore that replace it).
-- ALSO EDIT: 274_menu_master_seed.sql -- it is a MERGE-with-UPDATE
--            snapshot and will set this row back to Active on its next
--            run unless the same change is written there. Done in this
--            commit; see the note beside practice-instances in 274.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (288): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

-- 287 is what makes this safe. Without the restore procedure a retired
-- instance would be unreachable the moment this screen is hidden.
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.sp_resolve_instance_restore','P') IS NULL
BEGIN PRINT 'ABORT (288): sp_resolve_instance_restore missing. Run 287 first.'; SET @prereqs_ok = 0; END

-- And without the drill-down parameters, the two "Practice Instances"
-- row actions would have nowhere to go.
IF @prereqs_ok = 1 AND NOT EXISTS (
        SELECT 1 FROM sys.parameters
         WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_list')
           AND name = '@practice_id')
BEGIN PRINT 'ABORT (288): sp_resolve_instance_list has no @practice_id. Run 287 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'resolve' AND status = N'Active')
BEGIN PRINT 'ABORT (288): the Operationalize menu row is not active -- retiring Practice Instances would leave no way in.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('288_retire_practice_instances_screen: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Take the row out of the sidebar.
--    parent_menu_id is left as it is so the relationship stays readable
--    and the rollback finds the row where it expects.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = N'seed-288',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'practice-instances'
   AND status <> N'Inactive';

PRINT '288: Practice Instances menu hidden = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. Sanity report
-- =====================================================================
SELECT '288 Practice Instances is hidden' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'practice-instances' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The replacement must be reachable, or this migration has removed the
-- only door without opening another.
SELECT '288 Operationalize is visible' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master
                          WHERE menu_key = N'resolve' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The row, its id and its grants survive -- that is the whole point of
-- hiding rather than deleting.
SELECT '288 menu row and grants retained' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'practice-instances')
            THEN 'PASS -- '
                 + CAST((SELECT COUNT(*)
                           FROM grac_practice.organization_role_menu_permission p
                           JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                          WHERE m.menu_key = N'practice-instances') AS NVARCHAR(20))
                 + ' permission grant(s) kept'
            ELSE 'FAIL -- the row was deleted, not hidden' END AS Result;

-- Instance DATA must be untouched. The table is not being retired.
SELECT '288 practice instances untouched' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.practice_instance) AS NVARCHAR(20))
       + ' instance row(s) still present' AS Result;

PRINT '288 Practice Instances screen retired.';
PRINT '     Hidden, not deleted -- menu_id and every permission grant survive.';
PRINT '     Deep links to /Practice/Index/practice-instances still resolve.';
PRINT '     REMEMBER: 274_menu_master_seed.sql carries the same change, or';
PRINT '               its next run sets this row back to Active.';
PRINT '     Employee-scoped users no longer see instances they do not own.';
GO
SET NOEXEC OFF;
GO
