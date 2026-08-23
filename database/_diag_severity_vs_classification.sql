-- =====================================================================
-- Diagnostic: severity vocabulary vs SLA master classification
--
-- 3 sections. Section 3 shows the MISSING classifications -- those are
-- the ones the operator needs to add in grac_new.sla_master (Option A)
-- OR alias in grac_practice (Option B).
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Distinct severity_code in use across gaps =====';
SELECT DISTINCT severity_code, COUNT(*) AS GapCount
FROM grac_practice.custom_gap
WHERE severity_code IS NOT NULL
GROUP BY severity_code
ORDER BY severity_code;

PRINT '';
PRINT '===== 2. Distinct criticality in use across practice instances =====';
IF COL_LENGTH('grac_practice.practice_instance','criticality') IS NULL
    SELECT 'practice_instance.criticality column MISSING' AS Diagnosis;
ELSE
    SELECT DISTINCT criticality, COUNT(*) AS InstanceCount
    FROM grac_practice.practice_instance
    WHERE criticality IS NOT NULL
    GROUP BY criticality
    ORDER BY criticality;

PRINT '';
PRINT '===== 3. Classifications AVAILABLE in grac_new.sla_master =====';
IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    SELECT 'grac_new.sla_master MISSING' AS Diagnosis;
ELSE
    SELECT DISTINCT classification, COUNT(*) AS MasterRowCount
    FROM grac_new.sla_master
    WHERE ISNULL(status, N'Active') = N'Active'
      AND classification IS NOT NULL
    GROUP BY classification
    ORDER BY classification;

PRINT '';
PRINT '===== 4. GAP severities with NO matching SLA classification (the fix targets) =====';
IF OBJECT_ID('grac_new.sla_master','U') IS NOT NULL
BEGIN
    ;WITH gap_sev AS (
        SELECT DISTINCT UPPER(LTRIM(RTRIM(severity_code))) AS Sev
        FROM grac_practice.custom_gap
        WHERE severity_code IS NOT NULL
          AND LEN(LTRIM(RTRIM(severity_code))) > 0
    ),
    master_cls AS (
        SELECT DISTINCT UPPER(LTRIM(RTRIM(classification))) AS Cls
        FROM grac_new.sla_master
        WHERE ISNULL(status, N'Active') = N'Active'
          AND classification IS NOT NULL
    )
    SELECT g.Sev AS UnmatchedGapSeverity
    FROM gap_sev g
    LEFT JOIN master_cls m ON m.Cls = g.Sev
    WHERE m.Cls IS NULL
    ORDER BY g.Sev;
END

PRINT '';
PRINT '===== Diagnostic complete =====';
