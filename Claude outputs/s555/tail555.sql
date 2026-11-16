
-- =====================================================================
-- Verification
-- =====================================================================
SELECT '555 schema' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_execution_scope_exclusion','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '555 menu',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-my-audits' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '555 live materialize / start',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_materialize')) LIKE '%@live%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%@suppress_result%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_start')) LIKE '%54030%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '555 new procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_my_audits_prepare','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_my_audit_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_freeze_scope','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_scope_exclusion_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '555 complete. Restart the Api and publish Web; users sign out and back in to see My Audits.';
GO
SET NOEXEC OFF;
GO
