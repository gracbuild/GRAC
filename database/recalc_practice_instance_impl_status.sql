-- =====================================================================
-- recalc_practice_instance_impl_status.sql
--
-- One-time recalculation of every existing Practice Instance's
-- implementation status from its obligations.
--
-- 2026-10-08 (456): the rule now lives in ONE place,
-- grac_practice.sp_pm_recalc_instance_impl_status (re-issued by 456),
-- and this tool just runs it. It used to carry its own copy of the old
-- binary rule (Implemented / Not Implemented), which would undo 456's
-- Not Updated default if run after it.
--
-- Rule (456):
--   Not Updated      -> no applicable obligation has been updated
--                       (all Not Set / Not Started), or no applicable
--                       obligation and only a default value stored
--   Implemented      -> every applicable obligation is Implemented
--   Not Implemented  -> otherwise
--
-- Safe to run any number of times (the proc only writes rows whose value
-- actually changes). Run it in the target database (the one holding the
-- grac_practice schema). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;

IF ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_pm_recalc_instance_impl_status')), N'') NOT LIKE N'%updated_n%'
BEGIN
    RAISERROR('Run migration 456 first (sp_pm_recalc_instance_impl_status with the Not Updated rule).', 16, 1);
END
ELSE
BEGIN
    EXEC grac_practice.sp_pm_recalc_instance_impl_status NULL;

    SELECT COALESCE(pi.implementation_status, N'(null)') AS ImplementationStatus,
           COUNT(*) AS Instances
    FROM   grac_practice.practice_instance pi
    GROUP  BY pi.implementation_status
    ORDER  BY ImplementationStatus;
END
GO
