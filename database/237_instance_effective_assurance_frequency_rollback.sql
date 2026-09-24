-- =====================================================================
-- 237 Instance's effective assurance frequency -- ROLLBACK
--
-- Drops the view. The service tier will fall back to pi.assurance_frequency_id
-- through its COALESCE, so the calendar screen returns to today's
-- Configure-seeded value. Nothing else in the schema is touched.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (237 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_instance_effective_assurance_frequency','V') IS NOT NULL
BEGIN
    DROP VIEW grac_practice.vw_pm_instance_effective_assurance_frequency;
    PRINT '237 rollback: vw_pm_instance_effective_assurance_frequency dropped.';
END
ELSE
BEGIN
    PRINT '237 rollback: view was already absent.';
END
GO

PRINT '=== 237 rollback verification ===';
SELECT 'view dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_instance_effective_assurance_frequency','V') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT '237 rollback complete.';
GO

SET NOEXEC OFF;
GO
