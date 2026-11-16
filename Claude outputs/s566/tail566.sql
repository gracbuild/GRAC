-- =====================================================================
-- 9. Menu: Audit Assurance -> Audit Engagements (also in 274's snapshot)
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-engagements', N'Audit Engagements', N'Practice/org-audit-engagements', 467, N'briefcase')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-566', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-566');
PRINT '566.9: org-audit-engagements menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- The roles that hold Audit Plans get Audit Engagements with the same rights.
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-566', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key = N'org-audit-engagements'
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '566.9: org-audit-engagements permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 10. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_responsibility_holder'), (N'fn_org_assurance_engagement_status'),
               (N'fn_org_assurance_engagement_progress'), (N'fn_org_assurance_engagement_rows'),
               (N'sp_org_assurance_engagement_initiation_list'), (N'sp_org_assurance_engagement_list'),
               (N'sp_org_assurance_engagement_get'), (N'sp_org_assurance_engagement_team_list'),
               (N'sp_org_assurance_engagement_team_apply'), (N'sp_org_assurance_engagement_team_save'),
               (N'sp_org_assurance_engagement_approve'), (N'sp_org_assurance_engagement_cancel'),
               (N'sp_org_assurance_engagement_delete'), (N'sp_org_assurance_plan_item_save'),
               (N'sp_org_assurance_plan_item_list'), (N'sp_org_assurance_plan_item_start_execution'),
               (N'sp_org_assurance_my_audits_prepare'), (N'sp_org_assurance_my_audit_list'),
               (N'sp_org_responsibility_holder_list')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('566 verification: missing objects: %s', 16, 1, @missing);

IF NOT EXISTS (SELECT 1 FROM sys.parameters
                WHERE object_id = OBJECT_ID(N'grac_practice.sp_org_assurance_plan_item_save') AND name = N'@team_json')
    RAISERROR('566 verification: sp_org_assurance_plan_item_save has no @team_json.', 16, 1);

IF COLUMNPROPERTY(OBJECT_ID(N'grac_practice.org_assurance_plan_item'), N'org_assurance_plan_id', 'AllowsNull') <> 1
    RAISERROR('566 verification: org_assurance_plan_item.org_assurance_plan_id is still NOT NULL.', 16, 1);

SELECT (SELECT COUNT(*) FROM grac_practice.org_assurance_engagement_initiation_master) AS initiation_sources,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_engagement_team WHERE is_active = 1) AS team_rows,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_item WHERE is_active = 1) AS engagements,
       (SELECT COUNT(*) FROM grac_practice.menu_master WHERE menu_key = N'org-audit-engagements' AND status = N'Active') AS menu_rows;
PRINT '566 done: Audit Engagements are a record of their own (planned or independent), with an audit team and its trail.';
GO
