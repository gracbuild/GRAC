-- =====================================================================
-- 337 ROLLBACK  Drop the schedulable-obligations view
--
-- Removes vw_pm_instance_schedulable_obligations. The calendar read query
-- and the save hook that consume it ship in later steps; roll those back
-- first if they are already deployed, or this view's absence will surface
-- as "Invalid object name" the next time they run.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.vw_pm_instance_schedulable_obligations','V') IS NOT NULL
BEGIN
    DROP VIEW grac_practice.vw_pm_instance_schedulable_obligations;
    PRINT '337 rollback: dropped vw_pm_instance_schedulable_obligations';
END
ELSE PRINT '337 rollback: view already absent -- skipped';
GO
