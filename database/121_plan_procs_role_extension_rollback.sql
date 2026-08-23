-- =====================================================================
-- 121 rollback -- reapply 090 to restore prior SP shape.
-- The role columns on org_assurance_plan + org_assurance_plan_item are
-- left in place (they belong to a 115 rollback).
-- =====================================================================
SET NOCOUNT ON;
GO
PRINT '121 rollback: re-run 090_org_assurance_plan_procs.sql to restore prior SP shape.';
GO
