-- =====================================================================
-- Diagnostic + backfill for gap #12 (test custom gap for auto severity)
--
-- SECTION 1 -- show current state of gap 12
-- SECTION 2 -- show what sp_org_sla_match_for_severity returns for
--              (org=1, priority='Critical')  <-- what apply_sla would try
-- SECTION 3 -- run sp_custom_gap_apply_sla for gap 12
-- SECTION 4 -- show state of gap 12 AFTER the backfill so you can see
--              which fields lit up
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Current state of gap #12 =====';
SELECT custom_gap_id, organization_id, title, priority, severity_code,
       sla_master_id, sla_master_name, sla_days_effective, sla_source_code,
       due_date, updated_dt
FROM grac_practice.custom_gap
WHERE custom_gap_id = 12;

PRINT '';
PRINT '===== 2. Match preview: what will apply_sla try for (org=1, Critical)? =====';
EXEC grac_practice.sp_org_sla_match_for_severity
    @organization_id = 1,
    @severity_code   = N'Critical';

PRINT '';
PRINT '===== 3. Run the backfill =====';
EXEC grac_practice.sp_custom_gap_apply_sla
    @custom_gap_id       = 12,
    @caller_display_name = 'ops-backfill';

PRINT '';
PRINT '===== 4. Gap #12 AFTER backfill =====';
SELECT custom_gap_id, organization_id, title, priority, severity_code,
       sla_master_id, sla_master_name, sla_days_effective, sla_source_code,
       due_date, updated_dt
FROM grac_practice.custom_gap
WHERE custom_gap_id = 12;
