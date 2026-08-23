SET NOCOUNT ON;
GO

UPDATE grac_practice.gap_lifecycle_state_master
   SET state_name  = N'Delegated',
       description = N'Analysis saved; downstream tasks / exceptions / risk candidates own remediation from here. Terminal from Gap Centre.',
       updated_by  = N'rollback-175',
       updated_dt  = SYSUTCDATETIME()
 WHERE state_code = N'Delegated';
GO

DECLARE @active_rs INT =
    (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
UPDATE grac_practice.gap_lifecycle_transition_master
   SET record_status_id = @active_rs
 WHERE action_code = N'Validate';
GO

PRINT '175 rollback complete.';
GO
