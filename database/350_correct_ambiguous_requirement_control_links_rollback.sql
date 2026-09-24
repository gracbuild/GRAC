-- =====================================================================
-- 350 Correct ambiguous requirement->control links -- ROLLBACK
--
-- Undoes only what 350 wrote, identified by 'seed-350' and by the audit
-- log 350 writes BEFORE every correction:
--   1. organization_control_requirement (057) rows 350 inserted fresh
--      are deleted.
--   2. organization_control_requirement rows 350 reactivated (they
--      existed but were Inactive) are set back to Inactive.
--   3. organization_control_requirement rows 350 deactivated (the OLD,
--      wrong control's mapping) are set back to Active.
--   4. organization_requirement.organization_control_id is restored to
--      its PRIOR value from grac_practice.requirement_control_correction_log
--      -- which may be NULL, if that is what it was before 350 ran.
--      This is why the log table exists: unlike 283 (which only ever
--      moved NULL -> a value, so "back to NULL" is always safe), 350
--      can change an already-set value, and NULL would not restore the
--      original state.
--
-- The log table itself is left in place as a permanent audit trail; it
-- is not dropped by this rollback.
--
-- NOTE: a row someone has legitimately edited since 350 ran carries a
-- different updated_by and is left alone -- this reverts 350's
-- correction, not later human work.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
BEGIN
    PRINT 'ABORT (350 rollback): organization_requirement missing -- nothing to do.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.requirement_control_correction_log','U') IS NULL
BEGIN
    PRINT 'ABORT (350 rollback): requirement_control_correction_log missing --';
    PRINT '                      350 was never applied (or its log table was';
    PRINT '                      dropped). Nothing to roll back.';
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- 1. 057 rows 350 inserted fresh for the corrected control.
IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.organization_control_requirement
     WHERE entered_by = N'seed-350';
    PRINT '350 rollback: freshly-inserted 057 mappings deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    -- 2. 057 rows 350 reactivated (existed, were Inactive) -- back to
    --    Inactive. Identified as: touched by seed-350, currently
    --    Active, and pointing at the CORRECTED control on a row the log
    --    says 350 changed.
    UPDATE m
    SET    status = N'Inactive',
           updated_by = N'rollback-350',
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.organization_control_requirement m
    JOIN   grac_practice.requirement_control_correction_log log
           ON log.organization_requirement_id = m.organization_requirement_id
          AND log.corrected_control_id        = m.organization_control_id
    WHERE  m.updated_by = N'seed-350'
      AND  m.entered_by <> N'seed-350'
      AND  m.status = N'Active';
    PRINT '350 rollback: reactivated 057 mappings set back to Inactive = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    -- 3. 057 rows 350 deactivated (the OLD, wrong control) -- back to
    --    Active.
    UPDATE m
    SET    status = N'Active',
           updated_by = N'rollback-350',
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.organization_control_requirement m
    JOIN   grac_practice.requirement_control_correction_log log
           ON log.organization_requirement_id = m.organization_requirement_id
          AND log.previous_control_id         = m.organization_control_id
    WHERE  m.updated_by = N'seed-350'
      AND  m.status = N'Inactive';
    PRINT '350 rollback: old-control 057 mappings restored to Active = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END

-- 4. The column itself, back to its prior value (which may be NULL).
UPDATE r
SET    organization_control_id = log.previous_control_id,
       updated_by = N'rollback-350',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.organization_requirement r
JOIN   grac_practice.requirement_control_correction_log log
       ON log.organization_requirement_id = r.organization_requirement_id
WHERE  r.updated_by = N'seed-350'
  AND  r.organization_control_id = log.corrected_control_id;

PRINT '350 rollback: organization_control_id restored on = ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';

COMMIT TRAN;
GO

SELECT 'rows still stamped seed-350' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.organization_requirement
              WHERE updated_by = N'seed-350') AS NVARCHAR(20)) AS Result;

PRINT '350 rollback complete. The correction log table was left in place as an audit trail.';
GO
