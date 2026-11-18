-- 581 rollback  Audit Intelligence -- Enterprise Risk Intelligence
-- 1. Sets the Risk Intelligence menu Inactive and drops the intelligence
--    procedure.
-- 2. Puts the 580 mapping objects back: re-run 580_audit_universe_mapping.sql
--    after this script (its procedures are re-issued without RISK). RISK
--    mappings already made stay in the table; 580's procedures ignore
--    them, except the list, which shows them as "no longer available".
-- 3. Puts sp_risk_methodology_register_summary back: re-run
--    574_risk_methodology_matrix.sql (its own body), then drop
--    fn_risk_register_methodology_status (below, once 574 is re-run).
-- The level check keeps RISK (harmless without the procedures).
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-581', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-risk-intelligence';
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_risk_intelligence','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_universe_risk_intelligence;
GO
-- Only when the summary no longer reads it (574 re-run):
IF OBJECT_ID('grac_practice.fn_risk_register_methodology_status') IS NOT NULL
   AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_methodology_register_summary')) NOT LIKE N'%fn_risk_register_methodology_status%'
    DROP FUNCTION grac_practice.fn_risk_register_methodology_status;
GO
PRINT '581 rolled back: Risk Intelligence menu Inactive, procedure dropped. Re-run 580 and 574, then this script again to drop the function.';
GO
