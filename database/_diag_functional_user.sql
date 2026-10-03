-- =====================================================================
-- _diag_functional_user.sql   (READ-ONLY -- changes nothing)
--
-- Functional User flag: ticked on the Users form, but Edit shows it
-- unticked and the user never appears in Owner pickers.
--
-- The flag's database path is:
--   341  organization_employee.is_functional_user + sp_org_user_save
--        (reads $.isFunctionalUser) + sp_org_user_list (returns
--        IsFunctionalUser for the grid / Edit)
--   342  sp_get_owners_lookup (the functional-only Owner list)
--   366  sp_org_user_save re-issued (341 body + Department mandatory)
-- Users save/read goes Web -> API -> sp_org_user_repository_manage/_get
-- (134) -> sp_org_user_save / sp_org_user_list.
--
-- Each row below says PASS or FAIL and, on FAIL, which script to run.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;

SELECT 'A. column organization_employee.is_functional_user' AS [check],
       CASE WHEN COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -> run 341' END AS result
UNION ALL
SELECT 'B. sp_org_user_save persists the flag',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save')) LIKE '%isFunctionalUser%'
            THEN 'PASS' ELSE 'FAIL -> run 341 then 366' END
UNION ALL
SELECT 'C. sp_org_user_save has Department mandatory (366)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save')) LIKE '%isFunctionalUser%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_save')) LIKE '%366%'
            THEN 'PASS' ELSE 'REVIEW -> run 366 (after 341)' END
UNION ALL
SELECT 'D. sp_org_user_list returns IsFunctionalUser (Edit tick)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_user_list')) LIKE '%IsFunctionalUser%'
            THEN 'PASS' ELSE 'FAIL -> run 341 then 366' END
UNION ALL
SELECT 'E. sp_get_owners_lookup exists (Owner pickers)',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_owners_lookup','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -> run 342' END
UNION ALL
SELECT 'F. users gateway shims exist (134)',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_user_repository_manage','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_user_repository_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -> run 134' END;

-- When each proc was last (re)created. A save/list proc much newer than
-- the rest usually means an older migration (133/208) was re-run after
-- 341 and put back a body without the flag.
SELECT 'G. last altered' AS [check], o.name, o.modify_date
  FROM sys.objects o
 WHERE o.schema_id = SCHEMA_ID('grac_practice')
   AND o.name IN ('sp_org_user_save','sp_org_user_list','sp_get_owners_lookup',
                  'sp_org_user_repository_manage','sp_org_user_repository_get')
 ORDER BY o.modify_date DESC;

-- Functional users per organization (0 everywhere after ticking = the
-- save path is not persisting the flag).
IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NOT NULL
    EXEC sp_executesql N'
        SELECT ''H. functional users per organization'' AS [check],
               e.organization_id, COUNT(*) AS users,
               SUM(CASE WHEN e.is_functional_user = 1 THEN 1 ELSE 0 END) AS functional_users
          FROM grac_practice.organization_employee e
         GROUP BY e.organization_id
         ORDER BY e.organization_id;';
