-- =====================================================================
-- 282 Practice Picker -- ROLLBACK
--
-- Drops the five lookup procedures. 282 created no table, altered no
-- column and wrote no row, so there is no data to unwind -- dropping
-- these removes every trace of it.
--
-- Any UI still calling the picker endpoints will start reporting an
-- error from the API tier, so roll the Web/API tier back alongside this.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_practice_picker_frameworks','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_picker_frameworks;
GO
IF OBJECT_ID('grac_practice.sp_practice_picker_structures','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_picker_structures;
GO
IF OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_picker_controls;
GO
IF OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_picker_practices;
GO
IF OBJECT_ID('grac_practice.sp_practice_picker_resolve','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_picker_resolve;
GO

SELECT 'all picker procedures removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_frameworks','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_picker_structures','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_picker_controls','P')   IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_picker_practices','P')  IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_picker_resolve','P')    IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '282 rollback complete.';
GO
