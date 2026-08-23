-- =====================================================================
-- 119 rollback -- reapply 070 to restore prior SP shape.
-- The role columns on org_assurance_definition are left in place
-- (dropping them belongs to a 115 rollback, not here).
-- =====================================================================
SET NOCOUNT ON;
GO
PRINT '119 rollback: re-run 070_org_assurance_definition_procs.sql to restore prior SP shape.';
GO
