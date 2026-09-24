-- =====================================================================
-- 283 Backfill organization_control_id -- ROLLBACK
--
-- Undoes only what 283 wrote, identified by 'seed-283':
--   1. organization_control_requirement rows 283 inserted are deleted.
--   2. organization_requirement.organization_control_id is set back to
--      NULL on the rows 283 stamped (updated_by = 'seed-283').
--
-- Order matters: the mapping rows are deleted FIRST, because after step
-- 2 the requirement no longer names the control that would identify
-- them.
--
-- NOTE: a row that someone has legitimately edited since 283 ran will
-- carry a different updated_by and is therefore left alone -- this
-- reverts the backfill, not later human work.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
BEGIN
    PRINT 'ABORT (283 rollback): organization_requirement missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- 1. Mapping rows 283 created.
IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_control_requirement
     WHERE entered_by = N'seed-283';
    PRINT '283 rollback: mapping rows deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 2. The column, back to NULL.
UPDATE grac_practice.organization_requirement
   SET organization_control_id = NULL,
       updated_by = N'rollback-283',
       updated_dt = SYSUTCDATETIME()
 WHERE updated_by = N'seed-283'
   AND organization_control_id IS NOT NULL;

PRINT '283 rollback: control ids cleared = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

COMMIT TRAN;
GO

SELECT 'rows still stamped seed-283' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.organization_requirement
              WHERE updated_by = N'seed-283') AS NVARCHAR(20)) AS Result;

PRINT '283 rollback complete.';
GO
