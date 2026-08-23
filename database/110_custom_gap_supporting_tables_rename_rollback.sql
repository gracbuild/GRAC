-- =====================================================================
-- 110 rollback -- drop the new custom_gap_* supporting tables.
-- (org_assurance_gap_* tables are untouched -- 113 handles those.)
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_history;
GO
IF OBJECT_ID('grac_practice.custom_gap_action','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_action;
GO
IF OBJECT_ID('grac_practice.custom_gap_observation','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap_observation;
GO
PRINT '110 rollback complete.';
GO
