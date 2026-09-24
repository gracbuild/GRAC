-- =====================================================================
-- 346_instance_impl_status_derived_rollback.sql
-- Removes the derived-status trigger and recompute proc added by 346.
-- Existing practice_instance.implementation_status values are left as
-- they are (the last derived value stays); they are no longer kept in
-- sync with obligations after this runs. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.tr_pm_pio_impl_status_rollup','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_pio_impl_status_rollup;
GO
IF OBJECT_ID('grac_practice.sp_pm_recalc_instance_impl_status','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_recalc_instance_impl_status;
GO
PRINT '346 rollback: derived implementation-status trigger and proc removed.';
GO
