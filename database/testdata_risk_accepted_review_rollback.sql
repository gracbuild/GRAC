-- =====================================================================
-- ROLLBACK — testdata_risk_accepted_review.sql
--
-- Two different jobs, because the forward script did two different
-- things and they cannot be undone the same way:
--
--   PHASE 2 rows (entered_by = 'seed-risk-accepted') are risks this
--   script invented. They are DELETED, along with the analysis rows
--   cloned for them and their history.
--
--   PHASE 1 rows are risks that already existed and were merely
--   re-statused. They are NOT deleted -- deleting real data to undo a
--   status change would be far worse than the change. Their previous
--   status is not recoverable from the register itself, so it is read
--   back from the risk_register_history row the forward script wrote
--   (from_status_code), which is exactly what that row is for.
--
-- SAFETY
--   * Nothing outside organization 1 is touched.
--   * A risk that acquired real work after seeding -- treatment tasks,
--     a later history entry, a real acceptance -- is REPORTED AND
--     SKIPPED rather than deleted.
--   * Idempotent: a second run finds nothing and says so.
--
-- Set @WhatIf = 1 to see what would happen without changing anything.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @OrgId   BIGINT        = 1;
DECLARE @SeedTag NVARCHAR(100) = N'seed-risk-accepted';
DECLARE @WhatIf  BIT           = 0;      -- 1 = report only

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT 'SKIP: risk_register does not exist -- nothing to undo.';
    RETURN;
END

PRINT '--- rollback: risk test data ---';
IF @WhatIf = 1 PRINT '    WHAT-IF MODE: nothing will be changed.';

-- ---------------------------------------------------------------------
-- Phase 2 rows: created by the seed, safe to remove -- unless something
-- real has since attached itself to them.
-- ---------------------------------------------------------------------
DECLARE @Created TABLE (risk_register_id BIGINT PRIMARY KEY, risk_analysis_id BIGINT);

INSERT INTO @Created (risk_register_id, risk_analysis_id)
SELECT r.risk_register_id, r.risk_analysis_id
FROM grac_practice.risk_register r
WHERE r.organization_id = @OrgId
  AND r.entered_by = @SeedTag
  -- Left alone if a treatment task was raised against it: that task is
  -- real work, and the FK from practice_task would refuse anyway.
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.practice_task t
         WHERE t.source_type_code = N'RiskRegister'
           AND t.source_record_id = r.risk_register_id);

DECLARE @Skipped INT =
    (SELECT COUNT(*) FROM grac_practice.risk_register r
      WHERE r.organization_id = @OrgId AND r.entered_by = @SeedTag)
  - (SELECT COUNT(*) FROM @Created);

PRINT CONCAT('    Seeded risks removable : ', (SELECT COUNT(*) FROM @Created));
IF @Skipped > 0
    PRINT CONCAT('    Seeded risks SKIPPED   : ', @Skipped,
                 ' (treatment work exists against them -- left in place)');

-- ---------------------------------------------------------------------
-- Phase 1 rows: restore the status recorded in history, keep the risk.
-- ---------------------------------------------------------------------
DECLARE @Restore TABLE (risk_register_id BIGINT PRIMARY KEY, from_status NVARCHAR(30));

INSERT INTO @Restore (risk_register_id, from_status)
SELECT h.risk_register_id, MAX(h.from_status_code)
FROM grac_practice.risk_register_history h
JOIN grac_practice.risk_register r ON r.risk_register_id = h.risk_register_id
WHERE h.entered_by = @SeedTag
  AND h.action_code = N'RiskAccepted'
  AND r.organization_id = @OrgId
  AND r.entered_by <> @SeedTag          -- phase 2 rows are deleted, not restored
  AND h.from_status_code IS NOT NULL
GROUP BY h.risk_register_id;

PRINT CONCAT('    Pre-existing risks to restore: ', (SELECT COUNT(*) FROM @Restore));

IF @WhatIf = 1
BEGIN
    SELECT 'WOULD DELETE' AS Action_, r.risk_number, r.risk_title
    FROM grac_practice.risk_register r JOIN @Created c ON c.risk_register_id = r.risk_register_id;

    SELECT 'WOULD RESTORE' AS Action_, r.risk_number, r.status_code AS Now_, x.from_status AS BackTo_
    FROM grac_practice.risk_register r JOIN @Restore x ON x.risk_register_id = r.risk_register_id;

    RETURN;
END

BEGIN TRAN;

-- Children before parents: history, then the risks, then the analysis
-- rows they were the only user of.
DELETE h
  FROM grac_practice.risk_register_history h
  JOIN @Created c ON c.risk_register_id = h.risk_register_id;

DELETE r
  FROM grac_practice.risk_register r
  JOIN @Created c ON c.risk_register_id = r.risk_register_id;

-- Only analysis rows this script cloned, and only where no risk still
-- points at them -- a shared analysis is never removed.
DELETE a
  FROM grac_practice.risk_analysis a
  JOIN @Created c ON c.risk_analysis_id = a.risk_analysis_id
 WHERE a.entered_by = @SeedTag
   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_register r
                    WHERE r.risk_analysis_id = a.risk_analysis_id);

-- Restore the adopted risks. next_review_date is cleared only where the
-- seed set it: a risk that had its own review date keeps it.
UPDATE r
   SET r.status_code      = x.from_status,
       r.next_review_date = CASE WHEN r.next_review_date = '2026-09-01'
                                 THEN NULL ELSE r.next_review_date END,
       r.updated_by       = @SeedTag + N'-rollback',
       r.updated_dt       = SYSUTCDATETIME()
FROM grac_practice.risk_register r
JOIN @Restore x ON x.risk_register_id = r.risk_register_id;

-- The seed's own history entries go; everything else stays.
DELETE FROM grac_practice.risk_register_history
 WHERE entered_by = @SeedTag;

COMMIT;

PRINT '    Rollback complete.';
GO

PRINT '';
PRINT '--- rollback verification ---';

SELECT 'Seeded risks remaining' AS Check_, COUNT(*) AS Result
FROM grac_practice.risk_register
WHERE organization_id = 1 AND entered_by = N'seed-risk-accepted';

SELECT 'Seeded history remaining' AS Check_, COUNT(*) AS Result
FROM grac_practice.risk_register_history
WHERE entered_by = N'seed-risk-accepted';

SELECT 'Risks still on the seeded review date' AS Check_, COUNT(*) AS Result
FROM grac_practice.risk_register
WHERE organization_id = 1 AND next_review_date = '2026-09-01';
GO
