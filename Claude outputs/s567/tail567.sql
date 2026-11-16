-- =====================================================================
-- 11. Menu: Audit Assurance -> Workpapers (470), Observations to 471
--     (spec 5: ... My Audits, Executions, Workpapers, Observations ...);
--     also in 274's snapshot.
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-workpapers', N'Workpapers', N'Practice/org-workpapers', 470, N'file-pen')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-567', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-567');
PRINT '567.11: org-workpapers menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE grac_practice.menu_master
   SET display_order = 471, updated_by = 'seed-567', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-observations' AND display_order <> 471;
GO

-- Every active role (the page lists the caller's own engagements), as 555.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0,
       N'Active', @active_rs, N'seed-567', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'org-workpapers'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '567.11: org-workpapers permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 12. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_wp_roles'), (N'fn_org_assurance_wp_question_state'),
               (N'sp_org_assurance_testing_method_list'), (N'sp_org_assurance_observation_origin_list'),
               (N'sp_org_assurance_wp_log'), (N'sp_org_assurance_wp_question_sync'),
               (N'sp_org_assurance_execution_score_refresh'), (N'sp_org_assurance_wp_execution_list'),
               (N'sp_org_assurance_wp_overview'), (N'sp_org_assurance_wp_activity_list'),
               (N'sp_org_assurance_wp_question_assign'), (N'sp_org_assurance_working_paper_save'),
               (N'sp_org_assurance_working_paper_action'), (N'sp_org_assurance_wp_question_conclude'),
               (N'sp_org_assurance_execution_conclusion_save'), (N'sp_org_assurance_wp_raise_finding'),
               (N'sp_org_assurance_observation_finding_get'), (N'sp_org_assurance_observation_finding_save'),
               (N'sp_org_assurance_execution_transition')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('567 verification: missing objects: %s', 16, 1, @missing);

SELECT (SELECT COUNT(*) FROM grac_practice.org_assurance_testing_method_master)    AS testing_methods,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_observation_origin_master) AS observation_origins,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_question)        AS execution_questions,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_working_paper WHERE is_active = 1) AS working_papers,
       (SELECT COUNT(*) FROM grac_practice.menu_master WHERE menu_key = N'org-workpapers' AND status = N'Active') AS menu_rows;
PRINT '567 done: Test Working Papers, question conclusions, execution score and findings with the spec 4.7 fields.';
GO
