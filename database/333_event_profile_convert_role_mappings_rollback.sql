-- =====================================================================
-- 333 ROLLBACK -- undo the role-to-profile conversion
--
-- Reverses 333 in the order that keeps the organisation configured at
-- every step:
--   1. re-activate the role-scoped rows 333 deactivated
--   2. delete the applicability rows 333 created on the profiles
--   3. delete the profiles 333 created, and their criteria
--
-- Step 1 runs first deliberately. Between step 2 and step 3 the
-- organisation must not be left with neither copy active, or an event
-- raised in that window would serve nothing and record a resolution
-- saying so -- a permanent, wrong audit fact produced by a rollback.
--
-- ONLY 333'S OWN ROWS
-- -------------------
-- Every row is identified by entered_by / updated_by = 'seed-333'. A
-- profile you created by hand, a decision you edited on a converted
-- profile after the conversion, and any role row that was already
-- Inactive before 333 ran are all left exactly as they are.
--
-- A decision EDITED on a converted profile still carries
-- entered_by = 'seed-333' (edits set updated_by, not entered_by) and is
-- therefore deleted with the rest. The report at the end lists those
-- before they go, so the edit can be re-made on the role row if it
-- mattered.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- What is about to be lost. Read this before the transaction below.
PRINT '--- Decisions edited on converted profiles since the conversion ---';
SELECT a.applicability_id, a.organization_id, p.profile_code, a.obligation_label,
       a.is_applicable, a.due_days, a.updated_by, a.updated_dt
FROM   grac_practice.event_obligation_applicability a
JOIN   grac_practice.event_profile p ON p.profile_id = a.profile_id
WHERE  a.entered_by = 'seed-333'
  AND  a.updated_dt IS NOT NULL
ORDER BY a.organization_id, p.profile_code;
GO

BEGIN TRAN;

-- 1. Re-activate what the conversion switched off.
UPDATE grac_practice.event_obligation_applicability
   SET status     = N'Active',
       updated_by = 'seed-333-rollback',
       updated_dt = SYSUTCDATETIME()
 WHERE updated_by      = 'seed-333'
   AND status          = N'Inactive'
   AND scope_role_id   IS NOT NULL;
GO

-- 2. The copies the conversion made.
DELETE a
FROM   grac_practice.event_obligation_applicability a
JOIN   grac_practice.event_profile p ON p.profile_id = a.profile_id
WHERE  a.entered_by = 'seed-333'
  AND  p.entered_by = 'seed-333';
GO

-- 3. The profiles, children before parents. Any converted profile that
--    has since acquired a decision NOT created by 333 is kept -- somebody
--    configured it deliberately, and deleting it would discard that.
DELETE v
FROM   grac_practice.event_profile_criteria_value v
JOIN   grac_practice.event_profile p ON p.profile_id = v.profile_id
WHERE  p.entered_by = 'seed-333'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability a
                    WHERE a.profile_id = p.profile_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                    WHERE ei.scope_profile_id = p.profile_id);
GO

DELETE c
FROM   grac_practice.event_profile_criteria c
JOIN   grac_practice.event_profile p ON p.profile_id = c.profile_id
WHERE  p.entered_by = 'seed-333'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability a
                    WHERE a.profile_id = p.profile_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                    WHERE ei.scope_profile_id = p.profile_id);
GO

DELETE p
FROM   grac_practice.event_profile p
WHERE  p.entered_by = 'seed-333'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_profile_criteria c
                    WHERE c.profile_id = p.profile_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability a
                    WHERE a.profile_id = p.profile_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                    WHERE ei.scope_profile_id = p.profile_id);
GO

COMMIT TRAN;
GO

SELECT 'converted profiles remaining' AS Check_,
       CAST(COUNT(1) AS NVARCHAR(20)) AS Result
FROM   grac_practice.event_profile WHERE entered_by = 'seed-333'
UNION ALL
SELECT 'copied decisions remaining',
       CAST(COUNT(1) AS NVARCHAR(20))
FROM   grac_practice.event_obligation_applicability WHERE entered_by = 'seed-333'
UNION ALL
SELECT 'role rows re-activated',
       CAST(COUNT(1) AS NVARCHAR(20))
FROM   grac_practice.event_obligation_applicability
 WHERE updated_by = 'seed-333-rollback';

-- A non-zero "converted profiles remaining" is not a failure: those have
-- raised event instances or carry decisions somebody made after the
-- conversion, so they were kept on purpose. Deactivate them from the
-- Profiles screen if they are no longer wanted.
PRINT '333 rollback complete. Profiles kept above have history and were deliberately not deleted.';
GO

SET NOEXEC OFF;
GO
