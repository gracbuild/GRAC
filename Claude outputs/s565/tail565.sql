-- =====================================================================
-- Verification
-- =====================================================================
SELECT '565 schema' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_plan','financial_year') IS NOT NULL
             AND COL_LENGTH('grac_practice.org_assurance_plan_item','org_assurance_programme_id') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_plan_programme','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_plan_revision','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.org_assurance_planning_methodology_master) >= 7
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '565 every engagement has a programme',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_item
                              WHERE is_active = 1 AND org_assurance_programme_id IS NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '565 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_plan_programme_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_plan_revise','P') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_save')) LIKE '%@programme_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_save')) LIKE '%@financial_year%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '565 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
