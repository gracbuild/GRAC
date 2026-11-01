-- =====================================================================
-- 16  UAT diagnostics -- Asset & Contract Management (migrations 420-453)
--
-- Phase 9 (regression, permission, workflow and reconciliation testing).
-- Run after every deployment of the asset module, and whenever a screen,
-- the dashboard and a report disagree about a number.
--
--   1. Migrations present (one object each, 420-453) and the run order.
--   2. Menu rows and grants of the asset screens (who can open what).
--   3. Configuration health (report catalogue, schedules, deliveries,
--      scheduler, governance snapshots).
--   4. Reconciliation checks that are computed here -- PASS / FAIL
--      (shared register source, Asset Value distribution, governance
--      score = its record rows, delivery counts = recipient results,
--      downloads = export log).
--   5. Expected totals for the organization -- the numbers the Asset
--      Register, Asset Privacy, Asset Attestation, Asset Contracts, Asset
--      Discovery screens, the Asset & Contract dashboard and the Asset
--      Reports must all show (compare by hand; the UAT workbook says where).
--
-- Set @organization_id below (NULL = the first organization with assets).
-- READ-ONLY. Nothing here writes. Safe on any environment. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#diag_org') IS NOT NULL DROP TABLE #diag_org;
CREATE TABLE #diag_org (organization_id BIGINT NULL);
DECLARE @organization_id BIGINT = NULL;   -- <<< set the organization to check
INSERT #diag_org (organization_id)
SELECT ISNULL(@organization_id, (SELECT TOP (1) organization_id FROM grac_practice.organization_dependency_asset ORDER BY organization_id));
SELECT d.organization_id AS OrganizationId, o.organization_name AS OrganizationName
  FROM #diag_org d LEFT JOIN grac_practice.organization o ON o.organization_id = d.organization_id;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 1. MIGRATIONS PRESENT (run 420 to 453 in order; a MISSING row names';
PRINT '    the first script to run)';
PRINT '=====================================================================';
SELECT v.migration AS Migration, v.object_name AS ProbeObject,
       CASE WHEN OBJECT_ID(N'grac_practice.' + v.object_name) IS NULL THEN 'MISSING' ELSE 'present' END AS State
  FROM (VALUES ('420', N'asset_field_group_master'), ('421', N'asset_form_template_rule'), ('422', N'asset_valuation_config'),
               ('423', N'asset_option_list_master'), ('424', N'asset_type_org_default'), ('425', N'asset_make'),
               ('426', N'asset_firmware_product'), ('427', N'asset_os_product'), ('428', N'asset_lifecycle_status_phase'),
               ('429', N'asset_lifecycle_transition_gate'), ('430', N'asset_firmware_installation'), ('431', N'asset_assignment_history'),
               ('432', N'asset_verification_sla_rule'), ('433', N'asset_workflow_definition'), ('434', N'asset_contract'),
               ('435', N'asset_contract_entitlement'), ('436', N'asset_contract_renewal'), ('437', N'asset_notification_activity'),
               ('438', N'asset_activity_template'), ('439', N'asset_activity_result'), ('440', N'asset_relationship_type'),
               ('441', N'business_service'), ('442', N'asset_discovery_source'), ('443', N'asset_stale_setting'),
               ('444', N'asset_merge_split_event'), ('445', N'asset_split_allocation'), ('446', N'asset_valuation_recalc_run'),
               ('447', N'asset_consistency_rule'), ('448', N'asset_privacy_requirement'), ('450', N'asset_governance_kpi'),
               ('451', N'sp_dashboard_asset_contract'), ('452', N'asset_report_definition'), ('453', N'asset_report_schedule')
       ) v(migration, object_name)
 ORDER BY v.migration;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 2. MENU ROWS AND GRANTS (Active, under Asset & Contract; roles with';
PRINT '    VIEW / EDIT / APPROVE per screen; a screen nobody may open is a';
PRINT '    configuration gap -- grant it in Role Master and re-login)';
PRINT '=====================================================================';
SELECT m.menu_key AS MenuKey, m.menu_name AS MenuName, m.display_order AS DisplayOrder, m.status AS Status,
       CASE WHEN p.menu_key = N'nav-asset-contract' THEN 'yes' ELSE 'NO' END AS UnderAssetContract,
       (SELECT COUNT(DISTINCT g.role_id) FROM grac_practice.organization_role_menu_permission g
         WHERE g.menu_id = m.menu_id AND g.status = N'Active' AND g.can_view = 1) AS RolesView,
       (SELECT COUNT(DISTINCT g.role_id) FROM grac_practice.organization_role_menu_permission g
         WHERE g.menu_id = m.menu_id AND g.status = N'Active' AND g.can_edit = 1) AS RolesEdit,
       (SELECT COUNT(DISTINCT g.role_id) FROM grac_practice.organization_role_menu_permission g
         WHERE g.menu_id = m.menu_id AND g.status = N'Active' AND g.can_approve = 1) AS RolesApprove
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key IN (N'asset-contract-dashboard', N'asset-register', N'asset-field-dictionary', N'asset-form-templates',
                      N'asset-valuation-config', N'asset-option-lists', N'asset-taxonomy', N'asset-tech-catalog',
                      N'asset-attestation', N'asset-contracts', N'asset-notifications', N'asset-activities',
                      N'asset-relationships', N'business-services', N'asset-discovery', N'asset-privacy',
                      N'asset-governance', N'asset-reports')
 ORDER BY m.display_order;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 3. CONFIGURATION HEALTH (PASS / WARN / FAIL with the rows to fix)';
PRINT '=====================================================================';
IF OBJECT_ID('grac_practice.asset_report_schedule','U') IS NULL
BEGIN
    PRINT '452 / 453 not run: report checks skipped.';
END
ELSE
BEGIN
    DECLARE @org BIGINT = (SELECT organization_id FROM #diag_org);
    SELECT c.Check_, c.Result, c.Detail
      FROM (
        SELECT 'H1 every report screen has an Active menu row' AS Check_,
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_definition d
                                  WHERE d.is_active = 1 AND d.is_available = 1
                                    AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master m
                                                     WHERE m.menu_key = d.view_area AND m.status = N'Active'))
                    THEN 'FAIL' ELSE 'PASS' END AS Result,
               (SELECT STRING_AGG(d.report_code, N', ') FROM grac_practice.asset_report_definition d
                 WHERE d.is_active = 1 AND d.is_available = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master m WHERE m.menu_key = d.view_area AND m.status = N'Active')) AS Detail
        UNION ALL
        SELECT 'H2 active schedules are due on time (next run not in the past; worker running)',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_schedule s
                                  WHERE s.is_active = 1 AND (s.next_run_date IS NULL OR s.next_run_date < CAST(SYSUTCDATETIME() AS DATE)))
                    THEN 'WARN' ELSE 'PASS' END,
               (SELECT STRING_AGG(CONCAT(s.schedule_name, N' (next ', ISNULL(CONVERT(NVARCHAR(10), s.next_run_date, 23), N'none'), N')'), N'; ')
                  FROM grac_practice.asset_report_schedule s
                 WHERE s.is_active = 1 AND (s.next_run_date IS NULL OR s.next_run_date < CAST(SYSUTCDATETIME() AS DATE)))
        UNION ALL
        SELECT 'H3 no delivery left running for more than 6 hours',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery d
                                  WHERE d.status = N'RUNNING' AND d.started_dt < DATEADD(HOUR, -6, SYSUTCDATETIME()))
                    THEN 'WARN' ELSE 'PASS' END,
               (SELECT STRING_AGG(CAST(d.delivery_id AS NVARCHAR(20)), N', ') FROM grac_practice.asset_report_delivery d
                 WHERE d.status = N'RUNNING' AND d.started_dt < DATEADD(HOUR, -6, SYSUTCDATETIME()))
        UNION ALL
        SELECT 'H4 schedule recipients are active employees / roles',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_schedule_recipient r
                                   JOIN grac_practice.asset_report_schedule s ON s.schedule_id = r.schedule_id AND s.is_active = 1
                                   LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                                   LEFT JOIN grac_practice.organization_role rl ON rl.role_id = r.role_id
                                  WHERE (r.recipient_kind = N'EMPLOYEE' AND ISNULL(e.status, N'') <> N'Active')
                                     OR (r.recipient_kind = N'ROLE' AND ISNULL(rl.status, N'') <> N'Active'))
                    THEN 'WARN' ELSE 'PASS' END,
               N'A recipient who left is skipped at delivery; remove them from the schedule.'
        UNION ALL
        SELECT 'H5 the asset scheduler ran in the last 2 hours',
               CASE WHEN OBJECT_ID('grac_practice.asset_scheduler_run','U') IS NULL THEN 'WARN'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_scheduler_run WHERE started_dt >= DATEADD(HOUR, -2, SYSUTCDATETIME()))
                    THEN 'PASS' ELSE 'WARN' END,
               (SELECT TOP (1) CONCAT(N'last run ', CONVERT(NVARCHAR(19), started_dt, 120), N' UTC: ', result)
                  FROM grac_practice.asset_scheduler_run ORDER BY started_dt DESC)
        UNION ALL
        SELECT 'H6 the organization has a governance snapshot of today or yesterday',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot
                                  WHERE organization_id = @org AND as_of_date >= DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS DATE)))
                    THEN 'PASS' ELSE 'WARN' END,
               N'Taken daily by the scheduler (450) and by Take snapshot.'
        UNION ALL
        SELECT 'H7 every asset of the organization has a register status (current, or the legacy map)',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                                   LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
                                   LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
                                  WHERE a.organization_id = @org AND COALESCE(cs.status_code, ls.status_code) IS NULL)
                    THEN 'FAIL' ELSE 'PASS' END,
               N'An asset with no status is missing from every status filter, bar and report total.'
      ) c;
END
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 4. RECONCILIATION (computed here; any FAIL is a defect to report)';
PRINT '=====================================================================';
IF OBJECT_ID('grac_practice.fn_asset_report_assets') IS NULL
BEGIN
    PRINT '452 not run: reconciliation checks skipped.';
END
ELSE
BEGIN
    DECLARE @org BIGINT = (SELECT organization_id FROM #diag_org);
    DECLARE @snap BIGINT = (SELECT TOP (1) snapshot_id FROM grac_practice.asset_governance_snapshot
                             WHERE organization_id = @org AND is_current = 1 ORDER BY as_of_date DESC);
    SELECT c.Check_, c.Result, c.Detail
      FROM (
        SELECT 'R1 the shared report source returns every register record' AS Check_,
               CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL))
                       = (SELECT COUNT(*) FROM grac_practice.organization_dependency_asset WHERE organization_id = @org)
                    THEN 'PASS' ELSE 'FAIL' END AS Result,
               CONCAT((SELECT COUNT(*) FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL)), N' report rows / ',
                      (SELECT COUNT(*) FROM grac_practice.organization_dependency_asset WHERE organization_id = @org), N' register rows') AS Detail
        UNION ALL
        SELECT 'R2 in use: the report source and the governance population agree',
               CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL) WHERE InUse = 1)
                       = (SELECT COUNT(*) FROM grac_practice.fn_asset_governance_assets(@org) WHERE ExclusionReason IS NULL)
                    THEN 'PASS' ELSE 'FAIL' END,
               CONCAT((SELECT COUNT(*) FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL) WHERE InUse = 1), N' in use')
        UNION ALL
        SELECT 'R3 governance: every KPI numerator / denominator / failing / excluded = its record rows (latest snapshot)',
               CASE WHEN @snap IS NULL THEN 'SKIPPED'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot WHERE snapshot_id = @snap AND items_purged = 1) THEN 'SKIPPED'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_governance_snapshot_kpi k
                                 OUTER APPLY (SELECT ISNULL(SUM(CASE WHEN i.outcome <> N'EXCLUDED' THEN i.numerator ELSE 0 END), 0) AS num,
                                                     ISNULL(SUM(CASE WHEN i.outcome <> N'EXCLUDED' THEN i.denominator ELSE 0 END), 0) AS den,
                                                     ISNULL(SUM(CASE WHEN i.outcome = N'FAIL' THEN 1 ELSE 0 END), 0) AS fail,
                                                     ISNULL(SUM(CASE WHEN i.outcome = N'EXCLUDED' THEN 1 ELSE 0 END), 0) AS exc
                                                FROM grac_practice.asset_governance_snapshot_item i
                                               WHERE i.snapshot_id = k.snapshot_id AND i.kpi_code = k.kpi_code) x
                                  WHERE k.snapshot_id = @snap
                                    AND (k.numerator <> x.num OR k.denominator <> x.den OR k.failing_count <> x.fail OR k.excluded_count <> x.exc))
                    THEN 'FAIL' ELSE 'PASS' END,
               CONCAT(N'snapshot ', ISNULL(CAST(@snap AS NVARCHAR(20)), N'none'))
        UNION ALL
        SELECT 'R4 delivery counts = recipient results',
               CASE WHEN OBJECT_ID('grac_practice.asset_report_delivery','U') IS NULL THEN 'SKIPPED'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery d
                                 OUTER APPLY (SELECT COUNT(*) AS total,
                                                     ISNULL(SUM(CASE WHEN r.status = N'DELIVERED' THEN 1 ELSE 0 END), 0) AS dl,
                                                     ISNULL(SUM(CASE WHEN r.status = N'SKIPPED' THEN 1 ELSE 0 END), 0) AS sk,
                                                     ISNULL(SUM(CASE WHEN r.status = N'FAILED' THEN 1 ELSE 0 END), 0) AS fl
                                                FROM grac_practice.asset_report_delivery_recipient r WHERE r.delivery_id = d.delivery_id) x
                                  WHERE d.organization_id = @org AND d.status <> N'RUNNING'
                                    AND (d.recipient_count <> x.total OR d.delivered_count <> x.dl OR d.skipped_count <> x.sk OR d.failed_count <> x.fl))
                    THEN 'FAIL' ELSE 'PASS' END,
               N'sp_asset_report_delivery_finish'
        UNION ALL
        SELECT 'R5 every download of a delivered file is in the export log',
               CASE WHEN OBJECT_ID('grac_practice.asset_report_delivery_recipient','U') IS NULL THEN 'SKIPPED'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery_recipient r
                                   JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id AND d.organization_id = @org
                                  WHERE r.download_count <> (SELECT COUNT(*) FROM grac_practice.asset_report_export x
                                                              WHERE x.delivery_recipient_id = r.delivery_recipient_id))
                    THEN 'FAIL' ELSE 'PASS' END,
               N'13.4.1: exports record report, version, filters, columns, user, tenant, time, classification'
        UNION ALL
        SELECT 'R6 no delivered file outlives its retention',
               CASE WHEN OBJECT_ID('grac_practice.asset_report_delivery_recipient','U') IS NULL THEN 'SKIPPED'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery_recipient r
                                   JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id AND d.organization_id = @org
                                  WHERE r.rows_json IS NOT NULL
                                    AND DATEADD(DAY, d.retention_days + 1, ISNULL(r.delivered_dt, d.started_dt)) < SYSUTCDATETIME())
                    THEN 'WARN' ELSE 'PASS' END,
               N'Removed by the next delivery pass (worker); WARN = the pass has not run for a day.'
      ) c;
END
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 5. EXPECTED TOTALS (the screens, the dashboard and the reports must';
PRINT '    show these numbers for this organization)';
PRINT '=====================================================================';
DECLARE @org BIGINT = (SELECT organization_id FROM #diag_org);
DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
IF OBJECT_ID('grac_practice.fn_asset_report_assets') IS NOT NULL
BEGIN
    -- Asset Register status filter = dashboard bar "Assets by lifecycle status" = Complete Asset Register report.
    SELECT N'Register status' AS Area, ISNULL(x.StatusName, N'(none)') AS Item, COUNT(*) AS Expected,
           N'Asset Register filter / dashboard bar / Complete Asset Register report' AS ComparedOn
      FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL) x
     GROUP BY x.StatusName
    UNION ALL
    -- Assets in use by Asset Value = dashboard bars = Asset Value Distribution report.
    SELECT N'Asset Value (in use)', ISNULL(vr.asset_value_category, N'Not rated'), COUNT(*),
           N'Dashboard bar / Asset Value Distribution report'
      FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL) x
      LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = x.AssetId AND vr.validation_status = N'VALID'
     WHERE x.InUse = 1
     GROUP BY vr.asset_value_category
    UNION ALL
    -- Attestation display status = Asset Attestation filter = dashboard bar = Attestation Compliance report.
    SELECT N'Attestation display status',
           CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < @today THEN N'OVERDUE' ELSE t.status END,
           COUNT(*), N'Asset Attestation filter / dashboard / Attestation Compliance report'
      FROM grac_practice.asset_attestation t
     WHERE t.organization_id = @org
     GROUP BY CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < @today THEN N'OVERDUE' ELSE t.status END
    UNION ALL
    SELECT N'Coverage gaps', g.GapKind, COUNT(*), N'Asset Contracts -> Coverage gaps / dashboard tile / Coverage Gaps report'
      FROM grac_practice.fn_asset_coverage_gaps(@org) g
     GROUP BY g.GapKind
    UNION ALL
    SELECT N'Reconciliation queue (open)', e.exception_kind, COUNT(*), N'Asset Discovery queue / dashboard / Reconciliation Queue report'
      FROM grac_practice.asset_reconciliation_exception e
     WHERE e.organization_id = @org AND e.status = N'OPEN'
     GROUP BY e.exception_kind
    UNION ALL
    SELECT N'Contracts', c.contract_status, COUNT(*), N'Asset Contracts filter / dashboard bar'
      FROM grac_practice.asset_contract c
     WHERE c.organization_id = @org
     GROUP BY c.contract_status
    ORDER BY 1, 2;

    -- Heavier evaluations (per-asset functions): privacy status and technology classification of assets in use.
    SELECT N'Privacy status' AS Area, ps.PrivacyStatus AS Item, COUNT(*) AS Expected,
           N'Asset Privacy filter / dashboard bar / Personal-Data Assets report (APPLICABLE only)' AS ComparedOn
      FROM grac_practice.fn_asset_privacy_status(@org, NULL) ps
     GROUP BY ps.PrivacyStatus
    UNION ALL
    SELECT N'Technology (assets in use)', CONCAT(ts.Kind, N' ', ts.Classification), COUNT(DISTINCT ts.AssetId),
           N'Dashboard technology tiles / Firmware and OS Compliance reports'
      FROM grac_practice.fn_asset_report_assets(@org, NULL, NULL) x
     CROSS APPLY grac_practice.fn_asset_technology_status(@org, x.AssetId) ts
     WHERE x.InUse = 1 AND ts.Classification <> N'NOT_APPLICABLE'
     GROUP BY ts.Kind, ts.Classification
    ORDER BY 1, 2;
END
GO
DROP TABLE IF EXISTS #diag_org;
GO
