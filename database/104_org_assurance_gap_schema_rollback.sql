-- =====================================================================
-- 104 rollback -- Organization Assurance Gap schema
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_history;
GO
IF OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_action;
GO
IF OBJECT_ID('grac_practice.org_assurance_gap','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap;
GO
IF OBJECT_ID('grac_practice.org_assurance_gap_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_status_master;
GO
PRINT '104 Organization Assurance Gap schema rolled back.';
GO
