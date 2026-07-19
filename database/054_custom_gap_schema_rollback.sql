-- =====================================================================
-- 054 Custom Gap schema -- ROLLBACK
-- Drops the custom_gap table (and its indexes automatically).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
    DROP TABLE grac_practice.custom_gap;
GO

PRINT '054 custom_gap schema rollback complete.';
GO
