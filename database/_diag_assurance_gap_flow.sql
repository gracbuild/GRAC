-- =====================================================================
-- Diagnostic script -- run this in SSMS or your query tool to see
-- exactly where the Observation -> Assurance Gap flow is breaking.
--
-- This script is READ-ONLY. It does not modify anything.
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== CHECK 1: migrations 109-113 deployed? =====';

SELECT 'custom_gap.gap_source_module_code exists' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','gap_source_module_code') IS NOT NULL
            THEN 'YES (109 deployed)' ELSE 'NO (109 NOT deployed)' END AS Result;

SELECT 'custom_gap_observation table exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.custom_gap_observation','U') IS NOT NULL
            THEN 'YES (110 deployed)' ELSE 'NO (110 NOT deployed)' END AS Result;

SELECT 'sp_custom_gap_generate_from_assurance_observation exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_custom_gap_generate_from_assurance_observation','P') IS NOT NULL
            THEN 'YES (112 deployed)' ELSE 'NO (112 NOT deployed)' END AS Result;

SELECT 'org_assurance_gap table dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL
            THEN 'YES (113 deployed)' ELSE 'NO (still present -- 113 not deployed OR safe to re-run)' END AS Result;

PRINT '===== CHECK 2: how many Assurance-source gaps exist? =====';

SELECT gap_source_module_code AS Source,
       status                  AS Status,
       COUNT(*)                AS RowCount_
FROM grac_practice.custom_gap
GROUP BY gap_source_module_code, status
ORDER BY gap_source_module_code, status;

PRINT '===== CHECK 3: which orgs have Assurance gaps? =====';

SELECT organization_id AS OrgId,
       COUNT(*)         AS AssuranceGapCount,
       SUM(CASE WHEN status <> N'Cancelled' THEN 1 ELSE 0 END) AS ActiveCount
FROM grac_practice.custom_gap
WHERE gap_source_module_code = N'Assurance'
GROUP BY organization_id
ORDER BY organization_id;

PRINT '===== CHECK 4: any Accepted observations without gaps? (candidates for 114 backfill) =====';

IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
    PRINT 'org_assurance_observation table missing -- Observations module not deployed.';
ELSE
    SELECT o.org_assurance_observation_id AS ObservationId,
           o.organization_id               AS OrgId,
           o.observation_code              AS ObsCode,
           o.observation_title             AS ObsTitle,
           o.gap_id                        AS LegacyGapPointer,
           CASE WHEN EXISTS (
                    SELECT 1 FROM grac_practice.custom_gap_observation j
                    WHERE j.org_assurance_observation_id = o.org_assurance_observation_id
                      AND j.is_active = 1)
                THEN 'has active junction'
                ELSE 'NO junction (needs backfill)'
           END AS JunctionStatus,
           o.updated_dt                    AS ObsUpdatedDt
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master s
         ON s.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.is_active = 1 AND s.status_code = N'Accepted'
    ORDER BY o.organization_id, o.org_assurance_observation_id;

PRINT '===== CHECK 5: verify one org''s Assurance tab data =====';
PRINT 'Replace 1 with your organization_id below and re-run to see what the tab SHOULD show:';

DECLARE @check_org BIGINT = 1;

SELECT g.custom_gap_id, g.title, g.gap_source_module_code, g.status,
       g.severity_code, g.execution_name, g.entity_name,
       g.observation_code, g.observation_title, g.entered_dt
FROM grac_practice.custom_gap g
WHERE g.organization_id = @check_org
  AND g.gap_source_module_code = N'Assurance'
ORDER BY g.custom_gap_id DESC;
GO
