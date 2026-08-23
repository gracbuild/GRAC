-- =====================================================================
-- 132 Obligation instance execution -- ROLLBACK
--
-- Drops the new procedure. The two ALTERED procedures are CREATE OR ALTER,
-- so restoring them means re-running their owning migrations, in order:
--     067  -> sp_event_instance_complete
--     124  -> sp_event_instance_detail_get
--
-- WHAT YOU LOSE -- read this before rolling back:
--   * The checklist drawer goes blank again for obligation instances.
--   * sp_event_instance_complete goes back to gating on event_instance_item
--     only. For an obligation instance that check finds nothing, so the
--     instance closes as Completed with every obligation still Pending --
--     an onboarding pack can be signed off with no work recorded. That is a
--     control failure, not a cosmetic regression.
--
-- If the reason for rolling back is a problem with the detail query, prefer
-- fixing it forward. Restoring the old complete gate on a live system leaves
-- a hole that produces false compliance evidence.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_event_instance_obligation_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_instance_obligation_save;
GO

PRINT '132 ROLLBACK: sp_event_instance_obligation_save dropped.';
PRINT '132 ROLLBACK: now re-run, in order:';
PRINT '    database\067_workflow_engine_procs.sql        (restores sp_event_instance_complete)';
PRINT '    database\124_event_scope_mapping_procs.sql    (restores sp_event_instance_detail_get)';
PRINT '';
PRINT 'WARNING: the restored sp_event_instance_complete cannot see obligation items.';
PRINT '         Obligation instances will close as Completed with work outstanding.';
GO

-- Anything currently open with unresolved obligations -- these are the rows
-- the restored gate would close incorrectly.
IF OBJECT_ID('grac_practice.event_instance_obligation','U') IS NOT NULL
    SELECT ei.event_instance_id, ei.organization_id,
           ei.entity_display_name AS SubjectLabel, ei.status,
           COUNT(*) AS UnresolvedMandatoryObligations
    FROM   grac_practice.event_instance ei
    JOIN   grac_practice.event_instance_obligation io ON io.event_instance_id = ei.event_instance_id
    WHERE  ei.status NOT IN (N'Completed', N'Cancelled')
      AND  io.is_mandatory = 1
      AND  io.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable')
    GROUP BY ei.event_instance_id, ei.organization_id, ei.entity_display_name, ei.status
    ORDER BY UnresolvedMandatoryObligations DESC;
GO
