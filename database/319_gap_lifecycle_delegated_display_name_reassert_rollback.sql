-- =====================================================================
-- 319 rollback -- restore gap_lifecycle_state_master.state_name for
-- state_code = 'Delegated' back to 'Delegated' (174/272's literal),
-- undoing 175's rename as re-asserted by 319. Provided for symmetry
-- with every other migration pair in this project; 319 exists to KEEP
-- the "Analysed" display name in force, so rolling it back is not
-- expected to be wanted in practice.
-- =====================================================================
SET NOCOUNT ON;
GO

UPDATE grac_practice.gap_lifecycle_state_master
   SET state_name  = N'Delegated',
       description = N'Analysis saved; downstream tasks / exceptions / risk candidates own remediation from here. Terminal from Gap Centre.',
       updated_by  = N'rollback-319',
       updated_dt  = SYSUTCDATETIME()
 WHERE state_code = N'Delegated';
GO
PRINT '319 rollback: gap_lifecycle_state_master.state_name for Delegated restored to Delegated.';
GO
