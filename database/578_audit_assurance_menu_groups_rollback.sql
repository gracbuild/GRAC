-- 578 rollback  Audit Assurance menu groups
-- Puts the screens back directly under Audit Assurance with their earlier
-- order and names; sets the five new groups Inactive (Audit Intelligence,
-- from 577, stays). Grants are untouched.
SET NOCOUNT ON;
GO
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');
UPDATE m
   SET parent_menu_id = @assurance_id, display_order = s.display_order,
       menu_name = ISNULL(s.menu_name, m.menu_name),
       updated_by = 'rollback-578', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'org-audit-definition',        440, N'Audit Definition'),
        (N'org-assurance-plans',         466, N'Audit Plans'),
        (N'org-audit-engagements',       467, CAST(NULL AS NVARCHAR(200))),
        (N'org-my-audits',               468, NULL),
        (N'org-assurance-executions',    469, NULL),
        (N'org-workpapers',              470, NULL),
        (N'org-assurance-observations',  471, NULL),
        (N'org-audit-reports',           472, NULL),
        (N'org-assurance-question-sets', 475, NULL)
       ) AS s(menu_key, display_order, menu_name)
       ON s.menu_key = m.menu_key;
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-578', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-audit-definition', N'nav-audit-planning', N'nav-audit-execution',
                    N'nav-audit-findings', N'nav-audit-reporting');
GO
PRINT '578 rolled back: Audit Assurance screens back under Audit Assurance; the five groups Inactive.';
GO
