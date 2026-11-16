
-- =====================================================================
-- Verification
-- =====================================================================
SELECT '554 narrow procedure' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '554 branch list',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_scope_dimension_values')) LIKE '%organization_location%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '554 start execution narrows',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%narrow_location%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '554 view scope narrows',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview')) LIKE '%narrow_location%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '554 complete. Restart the Api and publish Web; pick a Branch on an engagement to audit that branch.';
GO
SET NOEXEC OFF;
GO
