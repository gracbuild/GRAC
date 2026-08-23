-- =====================================================================
-- 158 Gap Centre v1 seed -- ROLLBACK
--
-- Wipes the backfill (sets lifecycle_state_id to NULL on rows this seed
-- populated) and removes the transitions + states inserted by 158.
-- The state and transition MASTER tables themselves survive so 156's
-- schema stays intact.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Undo backfill (only null out rows updated by seed-158)
UPDATE grac_practice.custom_gap
   SET lifecycle_state_id = NULL,
       updated_by = 'rollback-158',
       updated_dt = SYSUTCDATETIME()
 WHERE updated_by = N'seed-158';
GO

DELETE FROM grac_practice.gap_lifecycle_transition_master
 WHERE entered_by = N'seed-158';
GO

DELETE FROM grac_practice.gap_lifecycle_state_master
 WHERE entered_by = N'seed-158';
GO

PRINT '158 rollback complete.';
GO
