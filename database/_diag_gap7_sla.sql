-- =====================================================================
-- Diagnostic: why the SLA card does not open for Gap #7 (org 4)
--
-- 5 sections. Copy every result set back so we can pinpoint the miss.
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Is migration 185 deployed? (header proc must return SLA cols) =====';
SELECT
    CASE WHEN COL_LENGTH('grac_practice.custom_gap','sla_master_id')      IS NOT NULL THEN 'YES' ELSE 'NO' END AS Col_sla_master_id,
    CASE WHEN COL_LENGTH('grac_practice.custom_gap','sla_master_name')    IS NOT NULL THEN 'YES' ELSE 'NO' END AS Col_sla_master_name_185,
    CASE WHEN COL_LENGTH('grac_practice.custom_gap','sla_days_effective') IS NOT NULL THEN 'YES' ELSE 'NO' END AS Col_sla_days_effective,
    CASE WHEN COL_LENGTH('grac_practice.custom_gap','sla_source_code')    IS NOT NULL THEN 'YES' ELSE 'NO' END AS Col_sla_source_code;

PRINT '';
PRINT '===== 2. Does gap #7 have SLA fields populated? =====';
SELECT custom_gap_id, organization_id, title, severity_code,
       sla_master_id, sla_master_name, sla_days_effective, sla_source_code,
       due_date, updated_dt
FROM grac_practice.custom_gap
WHERE custom_gap_id = 7;

PRINT '';
PRINT '===== 3. Are there SLA masters with classification = ''High'' active? =====';
IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    SELECT 'grac_new.sla_master MISSING' AS Diagnosis;
ELSE
    SELECT sla_id, sla_code, classification, duration_value, duration_unit,
           warning_pct, escalation_pct, status
    FROM grac_new.sla_master
    WHERE ISNULL(status, N'Active') = N'Active'
      AND UPPER(LTRIM(RTRIM(classification))) = 'HIGH';

PRINT '';
PRINT '===== 4. Has ORG 4 configured (Active) any of those masters? =====';
IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
    SELECT 'org_sla_config MISSING (run 178)' AS Diagnosis;
ELSE
    SELECT c.org_sla_config_id, c.sla_master_id, c.sla_master_name,
           c.warning_pct, c.escalation_pct, c.time_basis, c.total_sla_days,
           c.is_active,
           CASE WHEN c.is_active = 1 THEN 'Active' ELSE 'Inactive' END AS ConfigStatus
    FROM grac_practice.org_sla_config c
    WHERE c.organization_id = 4;

PRINT '';
PRINT '===== 5. What does sp_org_sla_match_for_severity return for (org=4, ''High'')? =====';
IF OBJECT_ID('grac_practice.sp_org_sla_match_for_severity','P') IS NULL
    SELECT 'sp_org_sla_match_for_severity MISSING (run 184)' AS Diagnosis;
ELSE
    EXEC grac_practice.sp_org_sla_match_for_severity
        @organization_id = 4,
        @severity_code   = N'High';

PRINT '';
PRINT '===== Diagnostic complete =====';
