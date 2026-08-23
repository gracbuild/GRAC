-- =====================================================================
-- 118 rollback -- drop the 4 owner columns and restore 082 procs.
-- =====================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_display_name') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN owner_display_name;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN owner_employee_id;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_role_name') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN owner_role_name;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_role_id') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN owner_role_id;
GO
PRINT '118 rollback: re-run 082_org_assurance_evidence_extend.sql to restore prior SP shape.';
GO
