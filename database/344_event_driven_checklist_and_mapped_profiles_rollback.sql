-- =====================================================================
-- 344 The Checklists tab's two read procedures -- ROLLBACK
--
-- Both are pure read procedures -- neither writes a row anywhere -- so
-- this rollback has no data-loss question to guard against. It just drops
-- them.
--
-- IF THE CHECKLISTS TAB UI (item 6 of the plan) HAS ALREADY BEEN BUILT,
-- IT WILL START FAILING THE MOMENT THIS RUNS -- both of these procedures
-- are what its two screens call. Confirm the UI change is being rolled
-- back too (or was never deployed) before running this.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (344 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_event_driven_checklist_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_event_driven_checklist_list;
    PRINT '344 rollback: sp_event_driven_checklist_list dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_event_checklist_mapped_profiles_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_event_checklist_mapped_profiles_list;
    PRINT '344 rollback: sp_event_checklist_mapped_profiles_list dropped.';
END
GO

PRINT '=== 344 rollback verification ===';

SELECT 'sp_event_driven_checklist_list gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_driven_checklist_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_event_checklist_mapped_profiles_list gone',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_checklist_mapped_profiles_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '344 rollback complete.';
GO

SET NOEXEC OFF;
GO
