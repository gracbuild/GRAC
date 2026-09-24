-- =====================================================================
-- 342_functional_owners_lookup_rollback.sql
-- Removes the owners lookup shim added by 342. Owner dropdowns fall back
-- to their pre-342 behaviour (the UI treats a missing owners lookup as
-- "no functional filter available"). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
IF OBJECT_ID('grac_practice.sp_get_owners_lookup','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_get_owners_lookup;
GO
PRINT '342 rollback: sp_get_owners_lookup dropped.';
GO
