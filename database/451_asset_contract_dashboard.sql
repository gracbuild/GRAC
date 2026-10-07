-- =====================================================================
-- 451  Asset & Contract dashboard -- the module dashboard of the
--      Asset & Contract menu on the management-dashboard framework
--      (Asset & Contract Management, Phase 8 increment 4b)
--
-- REQUEST
-- -------
--   BRD v1.7 13.1 (Executive: asset landscape, compliance posture,
--   critical exposure, contracts, workload, privacy and trends; Asset
--   Owner; Contract: expiry windows, renewal funnel, coverage gaps;
--   Biomedical: maintenance / calibration; Privacy: personal-data
--   assets, assessment, retention; Asset Attestation: required,
--   verified, pending, overdue, disputed, exceptions), 13.2.2
--   (technology KPI cards: unsupported, support ending, unknown
--   versions, exceptions), 13.3 (Notification Operations: upcoming,
--   escalation levels, delivery health), 13.5 (CMDB Quality, Business
--   Service, Discovery Operations, Governance), 19.10 (service
--   dependency / coverage / conflict widgets), "KPI / chart drill-down
--   returns the exact filtered record set" (13.2.7) and "dashboard totals
--   reconcile with detailed records" (9.1.11, 13.3).
--   Plan: docs/asset-contract-management.md (Phase 8.4b, D184-D193).
--
-- WHAT THIS DOES
-- --------------
--   1. sp_dashboard_asset_contract: the 414 contract -- one call, four
--      result sets (KPIs, ageing, distributions, lists) -- with eleven
--      sections: governance, assets, technology, contracts, attestation,
--      activities, privacy, discovery, services, relationships,
--      notifications. Every count uses the definition the section page
--      lists with, so a tile and the list it opens agree.
--   2. Menu: Asset & Contract -> Dashboard (asset-contract-dashboard,
--      348, the first child, 416 rule); VIEW for every role that can VIEW
--      one of the screens it summarises (416 rule) -- nobody gains or
--      loses data access.
--
-- NOT DONE HERE: charts beyond the shared tiles / bars / lists (no
--   charting library -- 414 layout); technology campaign progress and
--   refresh pipeline (no campaign workflow for technology exists);
--   criticality-based "critical exposure" (asset criticality levels are
--   organization data with no fixed "critical" level); exports (8.5).
--
-- ERROR NUMBERS: 53090 (organization required).
-- ALSO EDITED: API ManagementDashboardService (module map), Web
--   ManagementDashboards (sections), PracticeScreen (screen),
--   management-dashboard.js (targets, drills, ageing links only where the
--   page filters by age), dashboard-drill.js (tab / kind / pending and
--   the preselect / banner helpers for the asset screens), nine asset
--   screens (read the drill: asset-register, asset-contracts,
--   asset-attestation, asset-activities, asset-privacy, asset-discovery,
--   business-services, asset-relationships, asset-notifications),
--   appsettings (PM_ORG_ADMIN), 274 (menu), docs.
-- DEPENDS ON: 414, 416, 428-450.
-- Rollback: 451_asset_contract_dashboard_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.fn_pm_ageing_band') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_governance_assets') IS NULL
   OR OBJECT_ID('grac_practice.asset_governance_snapshot','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_privacy_status') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_technology_status') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_stale_state') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_discovery_confidence') IS NULL
   OR OBJECT_ID('grac_practice.fn_business_service_conflicts') IS NULL
   OR OBJECT_ID('grac_practice.asset_contract_renewal','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_restrictive_review','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_notification_outbox','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract')
BEGIN
    RAISERROR('ABORT (451): run 414, 416 and 428-450 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_dashboard_asset_contract (414 contract, D185-D191)
--    0 KPIs  1 ageing  2 distributions  3 lists
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_asset_contract
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53090, 'sp_dashboard_asset_contract: organization_id is required.', 1;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Assets: the register status rule (sp_asset_register_list) and "in use" (450).
    SELECT a.asset_id, a.asset_name, a.owner_id, COALESCE(cs.status_code, ls.status_code) AS status_code,
           CASE WHEN g.ExclusionReason IS NULL THEN 1 ELSE 0 END AS in_use,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change pc
                              WHERE pc.asset_id = a.asset_id AND pc.change_status = N'PENDING_APPROVAL') THEN 1 ELSE 0 END AS pending,
           vr.asset_value_category AS value_category
      INTO #ast
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.fn_asset_governance_assets(@organization_id) g ON g.AssetId = a.asset_id
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
      LEFT JOIN grac_practice.asset_valuation_result vr ON vr.asset_id = a.asset_id AND vr.validation_status = N'VALID'
     WHERE a.organization_id = @organization_id;

    -- Technology of the assets in use (430 classification).
    SELECT ts.AssetId AS asset_id, ts.Kind AS kind, ts.Classification AS classification, ts.CurrentLabel AS current_label,
           ts.SupportEndDate AS support_end
      INTO #tech
      FROM grac_practice.fn_asset_technology_status(@organization_id, NULL) ts
      JOIN #ast x ON x.asset_id = ts.AssetId AND x.in_use = 1
     WHERE ts.Classification <> N'NOT_APPLICABLE';

    -- Contracts and their version in force.
    SELECT c.contract_id, c.contract_number, c.contract_name, c.contract_status, cv.effective_end, ow.employee_name AS owner_name
      INTO #con
      FROM grac_practice.asset_contract c
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = cv.contract_owner_id
     WHERE c.organization_id = @organization_id;

    -- Attestation occurrences with the display status the list filters on (431).
    SELECT t.attestation_id, a.asset_name, t.attestation_type, t.due_date, t.generated_dt,
           CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < @today THEN N'OVERDUE' ELSE t.status END AS display_status,
           COALESCE(e.employee_name, tm.team_name + N' (team)') AS assignee_name
      INTO #att
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assignee_employee_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = t.assignee_team_id
     WHERE t.organization_id = @organization_id;

    -- Activity occurrences (438).
    SELECT o.occurrence_id, a.asset_name, o.template_code, tp.template_name, o.due_date, o.status, ow.employee_name AS owner_name
      INTO #occ
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = o.template_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.owner_id
     WHERE o.organization_id = @organization_id;

    -- Privacy status per asset (448).
    SELECT ps.AssetId AS asset_id, ps.PrivacyStatus AS privacy_status, ps.Applicability AS applicability
      INTO #prv
      FROM grac_practice.fn_asset_privacy_status(@organization_id, NULL) ps;

    -- Open reconciliation exceptions (442).
    SELECT e.exception_id, e.exception_kind, e.entered_dt
      INTO #rec
      FROM grac_practice.asset_reconciliation_exception e
     WHERE e.organization_id = @organization_id AND e.status = N'OPEN';

    -- Business services (441).
    SELECT b.service_id, b.status, b.business_owner_employee_id, b.review_date
      INTO #svc
      FROM grac_practice.business_service b
     WHERE b.organization_id = @organization_id;

    -- Relationships (440).
    SELECT r.relationship_id, r.status, r.is_critical
      INTO #rel
      FROM grac_practice.asset_relationship r
     WHERE r.organization_id = @organization_id;

    -- Notification occurrences (437).
    SELECT o.occurrence_id, o.status, o.escalation_level, o.activity_code, act.activity_name, act.display_order
      INTO #ntf
      FROM grac_practice.asset_notification_occurrence o
      JOIN grac_practice.asset_notification_activity act ON act.activity_code = o.activity_code
     WHERE o.organization_id = @organization_id;

    -- Latest current governance snapshot (450).
    DECLARE @snap BIGINT = (SELECT TOP (1) snapshot_id FROM grac_practice.asset_governance_snapshot
                             WHERE organization_id = @organization_id AND is_current = 1 ORDER BY as_of_date DESC);

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'governance' AS SectionKey, N'Governance (latest snapshot)' AS SectionTitle, N'overall' AS KpiKey,
               N'Overall score %' AS Label,
               CAST(ROUND((SELECT overall_score FROM grac_practice.asset_governance_snapshot WHERE snapshot_id = @snap), 0) AS INT) AS Value,
               CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder WHERE @snap IS NOT NULL
        UNION ALL SELECT N'governance', N'Governance (latest snapshot)', N'red', N'KPIs below threshold',
                         (SELECT COUNT(*) FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @snap AND rag = N'RED'), 1, 2 WHERE @snap IS NOT NULL
        UNION ALL SELECT N'governance', N'Governance (latest snapshot)', N'amber', N'KPIs at warning',
                         (SELECT COUNT(*) FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @snap AND rag = N'AMBER'), 0, 3 WHERE @snap IS NOT NULL
        UNION ALL SELECT N'governance', N'Governance (latest snapshot)', N'green', N'KPIs on target',
                         (SELECT COUNT(*) FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @snap AND rag = N'GREEN'), 0, 4 WHERE @snap IS NOT NULL
        UNION ALL SELECT N'governance', N'Governance (latest snapshot)', N'failing', N'Failing records',
                         (SELECT ISNULL(SUM(failing_count), 0) FROM grac_practice.asset_governance_snapshot_kpi WHERE snapshot_id = @snap), 1, 5 WHERE @snap IS NOT NULL

        UNION ALL SELECT N'assets', N'Asset register', N'total', N'Registered records', COUNT(*), 0, 1 FROM #ast
        UNION ALL SELECT N'assets', N'Asset register', N'inuse', N'In use', SUM(in_use), 0, 2 FROM #ast
        UNION ALL SELECT N'assets', N'Asset register', N'draft', N'Draft', SUM(CASE WHEN status_code = N'DRAFT' THEN 1 ELSE 0 END), 0, 3 FROM #ast
        UNION ALL SELECT N'assets', N'Asset register', N'pending', N'Awaiting lifecycle approval', SUM(pending), 1, 4 FROM #ast
        UNION ALL SELECT N'assets', N'Asset register', N'retiring', N'On the way out',
                         SUM(CASE WHEN status_code IN (N'PENDING_DECOMMISSION', N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL') THEN 1 ELSE 0 END), 0, 5 FROM #ast
        UNION ALL SELECT N'assets', N'Asset register', N'noowner', N'In use, no owner',
                         SUM(CASE WHEN in_use = 1 AND owner_id IS NULL THEN 1 ELSE 0 END), 1, 6 FROM #ast

        UNION ALL SELECT N'technology', N'Technology lifecycle (assets in use)', N'unsupported', N'Unsupported',
                         COUNT(DISTINCT CASE WHEN classification = N'UNSUPPORTED' THEN asset_id END), 1, 1 FROM #tech
        UNION ALL SELECT N'technology', N'Technology lifecycle (assets in use)', N'duesoon', N'Support ending soon',
                         COUNT(DISTINCT CASE WHEN classification = N'DUE_SOON' THEN asset_id END), 0, 2 FROM #tech
        UNION ALL SELECT N'technology', N'Technology lifecycle (assets in use)', N'unknown', N'Unknown versions',
                         COUNT(DISTINCT CASE WHEN classification = N'UNKNOWN' THEN asset_id END), 1, 3 FROM #tech
        UNION ALL SELECT N'technology', N'Technology lifecycle (assets in use)', N'exception', N'On an exception',
                         COUNT(DISTINCT CASE WHEN classification = N'EXCEPTION' THEN asset_id END), 0, 4 FROM #tech
        UNION ALL SELECT N'technology', N'Technology lifecycle (assets in use)', N'expiring', N'Exceptions expiring in 30 days',
                         COUNT(*), 0, 5
                    FROM grac_practice.asset_technology_exception e
                   WHERE e.organization_id = @organization_id AND e.status = N'APPROVED'
                     AND e.expiry_date BETWEEN @today AND DATEADD(DAY, 30, @today)

        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'active', N'Active contracts',
                         SUM(CASE WHEN contract_status = N'ACTIVE' THEN 1 ELSE 0 END), 0, 1 FROM #con
        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'expiring30', N'Ending in 30 days',
                         SUM(CASE WHEN contract_status = N'ACTIVE' AND effective_end BETWEEN @today AND DATEADD(DAY, 30, @today) THEN 1 ELSE 0 END), 1, 2 FROM #con
        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'expiring90', N'Ending in 90 days',
                         SUM(CASE WHEN contract_status = N'ACTIVE' AND effective_end BETWEEN @today AND DATEADD(DAY, 90, @today) THEN 1 ELSE 0 END), 0, 3 FROM #con
        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'expired', N'Expired',
                         SUM(CASE WHEN contract_status = N'EXPIRED' THEN 1 ELSE 0 END), 0, 4 FROM #con
        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'renewals', N'Open renewals',
                         COUNT(*), 0, 5
                    FROM grac_practice.asset_contract_renewal r
                    JOIN grac_practice.asset_contract c ON c.contract_id = r.contract_id AND c.organization_id = @organization_id
                   WHERE r.is_open = 1
        UNION ALL SELECT N'contracts', N'Contracts and coverage', N'gaps', N'Coverage gaps',
                         COUNT(*), 1, 6 FROM grac_practice.fn_asset_coverage_gaps(@organization_id)

        UNION ALL SELECT N'attestation', N'Asset attestation', N'pending', N'Pending',
                         SUM(CASE WHEN display_status = N'PENDING' THEN 1 ELSE 0 END), 0, 1 FROM #att
        UNION ALL SELECT N'attestation', N'Asset attestation', N'inprogress', N'In progress',
                         SUM(CASE WHEN display_status = N'IN_PROGRESS' THEN 1 ELSE 0 END), 0, 2 FROM #att
        UNION ALL SELECT N'attestation', N'Asset attestation', N'overdue', N'Overdue',
                         SUM(CASE WHEN display_status = N'OVERDUE' THEN 1 ELSE 0 END), 1, 3 FROM #att
        UNION ALL SELECT N'attestation', N'Asset attestation', N'confirmed', N'Awaiting approval',
                         SUM(CASE WHEN display_status = N'CONFIRMED' THEN 1 ELSE 0 END), 0, 4 FROM #att
        UNION ALL SELECT N'attestation', N'Asset attestation', N'disputed', N'Disputed',
                         SUM(CASE WHEN display_status = N'DISPUTED' THEN 1 ELSE 0 END), 1, 5 FROM #att
        UNION ALL SELECT N'attestation', N'Asset attestation', N'exceptions', N'Exceptions not closed',
                         COUNT(*), 1, 6
                    FROM grac_practice.asset_verification_exception x
                    JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
                   WHERE x.organization_id = @organization_id AND s.status_code NOT IN (N'CLOSED', N'CANCELLED')

        UNION ALL SELECT N'activities', N'Maintenance, calibration and inspections', N'open', N'Open activities',
                         SUM(CASE WHEN status = N'OPEN' THEN 1 ELSE 0 END), 0, 1 FROM #occ
        UNION ALL SELECT N'activities', N'Maintenance, calibration and inspections', N'overdue', N'Overdue',
                         SUM(CASE WHEN status = N'OPEN' AND due_date < @today THEN 1 ELSE 0 END), 1, 2 FROM #occ
        UNION ALL SELECT N'activities', N'Maintenance, calibration and inspections', N'due30', N'Due in 30 days',
                         SUM(CASE WHEN status = N'OPEN' AND due_date BETWEEN @today AND DATEADD(DAY, 30, @today) THEN 1 ELSE 0 END), 0, 3 FROM #occ
        UNION ALL SELECT N'activities', N'Maintenance, calibration and inspections', N'reviews', N'Restrictive-use reviews open',
                         COUNT(*), 1, 4
                    FROM grac_practice.asset_restrictive_review rr
                    JOIN grac_practice.organization_dependency_asset a ON a.asset_id = rr.asset_id AND a.organization_id = @organization_id
                   WHERE rr.status = N'OPEN'

        UNION ALL SELECT N'privacy', N'Privacy', N'personal', N'Personal data (yes or unknown)',
                         SUM(CASE WHEN applicability = N'APPLICABLE' THEN 1 ELSE 0 END), 0, 1 FROM #prv
        UNION ALL SELECT N'privacy', N'Privacy', N'noncompliant', N'Non-compliant',
                         SUM(CASE WHEN privacy_status = N'NON_COMPLIANT' THEN 1 ELSE 0 END), 1, 2 FROM #prv
        UNION ALL SELECT N'privacy', N'Privacy', N'incomplete', N'Incomplete',
                         SUM(CASE WHEN privacy_status = N'INCOMPLETE' THEN 1 ELSE 0 END), 1, 3 FROM #prv
        UNION ALL SELECT N'privacy', N'Privacy', N'undetermined', N'Undetermined',
                         SUM(CASE WHEN privacy_status = N'UNDETERMINED' THEN 1 ELSE 0 END), 0, 4 FROM #prv
        UNION ALL SELECT N'privacy', N'Privacy', N'reviews', N'Reviews overdue',
                         COUNT(*), 1, 5
                    FROM grac_practice.asset_privacy_review pr
                   WHERE pr.organization_id = @organization_id AND pr.status = N'OPEN' AND pr.due_date < @today
        UNION ALL SELECT N'privacy', N'Privacy', N'exceptions', N'Exceptions awaiting approval',
                         COUNT(*), 0, 6
                    FROM grac_practice.asset_privacy_exception px
                   WHERE px.organization_id = @organization_id AND px.status = N'PENDING_APPROVAL'

        UNION ALL SELECT N'discovery', N'CMDB quality and discovery', N'open', N'Open reconciliation exceptions', COUNT(*), 0, 1 FROM #rec
        UNION ALL SELECT N'discovery', N'CMDB quality and discovery', N'conflicts', N'Open conflicts',
                         SUM(CASE WHEN exception_kind = N'CONFLICT' THEN 1 ELSE 0 END), 1, 2 FROM #rec
        UNION ALL SELECT N'discovery', N'CMDB quality and discovery', N'duplicates', N'Potential duplicates',
                         SUM(CASE WHEN exception_kind = N'DUPLICATE' THEN 1 ELSE 0 END), 0, 3 FROM #rec
        UNION ALL SELECT N'discovery', N'CMDB quality and discovery', N'stale', N'Stale assets',
                         SUM(CAST(ss.IsListed AS INT)), 1, 4 FROM grac_practice.fn_asset_stale_state(@organization_id) ss
        UNION ALL SELECT N'discovery', N'CMDB quality and discovery', N'sources', N'Sources needing attention',
                         SUM(CASE WHEN s.last_run_dt IS NULL OR s.last_run_status IN (N'FAILED', N'PARTIAL')
                                       OR DATEADD(HOUR, s.expected_interval_hours, s.last_run_dt) < SYSUTCDATETIME() THEN 1 ELSE 0 END), 1, 5
                    FROM grac_practice.asset_discovery_source s
                   WHERE s.organization_id = @organization_id AND s.is_active = 1

        UNION ALL SELECT N'services', N'Business services', N'operating', N'In operation',
                         SUM(CASE WHEN status IN (N'ACTIVE', N'DEGRADED') THEN 1 ELSE 0 END), 0, 1 FROM #svc
        UNION ALL SELECT N'services', N'Business services', N'degraded', N'Degraded',
                         SUM(CASE WHEN status = N'DEGRADED' THEN 1 ELSE 0 END), 1, 2 FROM #svc
        UNION ALL SELECT N'services', N'Business services', N'conflicts', N'Validation conflicts',
                         COUNT(*), 1, 3 FROM grac_practice.fn_business_service_conflicts(@organization_id)
        UNION ALL SELECT N'services', N'Business services', N'noowner', N'No business owner',
                         SUM(CASE WHEN status <> N'RETIRED' AND business_owner_employee_id IS NULL THEN 1 ELSE 0 END), 1, 4 FROM #svc
        UNION ALL SELECT N'services', N'Business services', N'review', N'Review date passed',
                         SUM(CASE WHEN status <> N'RETIRED' AND review_date < @today THEN 1 ELSE 0 END), 0, 5 FROM #svc

        UNION ALL SELECT N'relationships', N'CMDB relationships', N'active', N'Active',
                         SUM(CASE WHEN status = N'ACTIVE' THEN 1 ELSE 0 END), 0, 1 FROM #rel
        UNION ALL SELECT N'relationships', N'CMDB relationships', N'proposed', N'Awaiting approval',
                         SUM(CASE WHEN status = N'PROPOSED' THEN 1 ELSE 0 END), 0, 2 FROM #rel
        UNION ALL SELECT N'relationships', N'CMDB relationships', N'disputed', N'Disputed',
                         SUM(CASE WHEN status = N'DISPUTED' THEN 1 ELSE 0 END), 1, 3 FROM #rel
        UNION ALL SELECT N'relationships', N'CMDB relationships', N'critical', N'Active critical dependencies',
                         SUM(CASE WHEN status = N'ACTIVE' AND is_critical = 1 THEN 1 ELSE 0 END), 0, 4 FROM #rel

        UNION ALL SELECT N'notifications', N'Notification operations', N'open', N'Open occurrences',
                         SUM(CASE WHEN status = N'OPEN' THEN 1 ELSE 0 END), 0, 1 FROM #ntf
        UNION ALL SELECT N'notifications', N'Notification operations', N'escalated', N'Escalated',
                         SUM(CASE WHEN status = N'OPEN' AND escalation_level > 0 THEN 1 ELSE 0 END), 1, 2 FROM #ntf
        UNION ALL SELECT N'notifications', N'Notification operations', N'failed', N'Failed deliveries',
                         COUNT(*), 1, 3
                    FROM grac_practice.asset_notification_outbox ob
                   WHERE ob.organization_id = @organization_id AND ob.status_code = N'Failed'
      ) k
     ORDER BY CASE k.SectionKey WHEN N'governance' THEN 1 WHEN N'assets' THEN 2 WHEN N'technology' THEN 3 WHEN N'contracts' THEN 4
                                WHEN N'attestation' THEN 5 WHEN N'activities' THEN 6 WHEN N'privacy' THEN 7 WHEN N'discovery' THEN 8
                                WHEN N'services' THEN 9 WHEN N'relationships' THEN 10 ELSE 11 END, k.SortOrder;

    -- ---- 1. Ageing: open attestations (days since generated) and open
    --         reconciliation exceptions (days since raised) ------------------
    SELECT N'attestation' AS GroupKey, N'Open attestations' AS GroupTitle,
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #att x
             WHERE x.display_status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE', N'ESCALATED')
               AND DATEDIFF(DAY, x.generated_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM grac_practice.fn_pm_ageing_band() b
    UNION ALL
    SELECT N'discovery', N'Open reconciliation exceptions',
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #rec x WHERE DATEDIFF(DAY, x.entered_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays)
      FROM grac_practice.fn_pm_ageing_band() b
     ORDER BY 1, 5;

    -- ---- 2. Distributions ----------------------------------------------
    -- ItemKey is the value the section page filter takes; NULL where the
    -- page has no such filter (the bar is then not a link).
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'assets_status' AS GroupKey, N'Assets by lifecycle status' AS GroupTitle,
               x.status_code AS ItemKey, ISNULL(MAX(sm.status_name), ISNULL(x.status_code, N'(none)')) AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex, ISNULL(MIN(sm.display_order), 999) AS SortOrder
          FROM #ast x
          LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = x.status_code
         GROUP BY x.status_code
        UNION ALL
        SELECT N'assets_value', N'Assets in use by Asset Value', CAST(NULL AS NVARCHAR(100)), ISNULL(x.value_category, N'Not rated'),
               COUNT(*), NULL, CASE WHEN x.value_category IS NULL THEN 999 ELSE 1 END
          FROM #ast x WHERE x.in_use = 1
         GROUP BY x.value_category
        UNION ALL
        SELECT N'technology_firmware', N'Firmware (assets in use)', NULL,
               CASE t.classification WHEN N'CURRENT' THEN N'Current' WHEN N'DUE_SOON' THEN N'Support ending' WHEN N'UNSUPPORTED' THEN N'Unsupported'
                                     WHEN N'UNKNOWN' THEN N'Unknown' WHEN N'EXCEPTION' THEN N'Exception' ELSE t.classification END,
               COUNT(*), NULL,
               CASE t.classification WHEN N'CURRENT' THEN 1 WHEN N'DUE_SOON' THEN 2 WHEN N'UNSUPPORTED' THEN 3 WHEN N'UNKNOWN' THEN 4 ELSE 5 END
          FROM #tech t WHERE t.kind = N'FIRMWARE'
         GROUP BY t.classification
        UNION ALL
        SELECT N'technology_os', N'Operating systems (assets in use)', NULL,
               CASE t.classification WHEN N'CURRENT' THEN N'Current' WHEN N'DUE_SOON' THEN N'Support ending' WHEN N'UNSUPPORTED' THEN N'Unsupported'
                                     WHEN N'UNKNOWN' THEN N'Unknown' WHEN N'EXCEPTION' THEN N'Exception' ELSE t.classification END,
               COUNT(*), NULL,
               CASE t.classification WHEN N'CURRENT' THEN 1 WHEN N'DUE_SOON' THEN 2 WHEN N'UNSUPPORTED' THEN 3 WHEN N'UNKNOWN' THEN 4 ELSE 5 END
          FROM #tech t WHERE t.kind = N'OS'
         GROUP BY t.classification
        UNION ALL
        SELECT N'contracts_status', N'Contracts by status', c.contract_status,
               CASE c.contract_status WHEN N'DRAFT' THEN N'Draft' WHEN N'APPROVED' THEN N'Approved (not yet effective)' WHEN N'ACTIVE' THEN N'Active'
                                      WHEN N'EXPIRED' THEN N'Expired' ELSE N'Terminated' END,
               COUNT(*), NULL,
               CASE c.contract_status WHEN N'DRAFT' THEN 1 WHEN N'APPROVED' THEN 2 WHEN N'ACTIVE' THEN 3 WHEN N'EXPIRED' THEN 4 ELSE 5 END
          FROM #con c GROUP BY c.contract_status
        UNION ALL
        SELECT N'attestation_status', N'Attestations by status',
               CASE WHEN x.display_status IN (N'GENERATED', N'ESCALATED') THEN NULL ELSE x.display_status END,
               CASE x.display_status WHEN N'GENERATED' THEN N'Generated' WHEN N'PENDING' THEN N'Pending' WHEN N'IN_PROGRESS' THEN N'In progress'
                                     WHEN N'OVERDUE' THEN N'Overdue' WHEN N'ESCALATED' THEN N'Escalated' WHEN N'CONFIRMED' THEN N'Awaiting approval'
                                     WHEN N'DISPUTED' THEN N'Disputed' WHEN N'EXCEPTION' THEN N'Exception' WHEN N'RESOLVED' THEN N'Resolved'
                                     WHEN N'CLOSED' THEN N'Closed' ELSE N'Cancelled' END,
               COUNT(*), NULL,
               CASE x.display_status WHEN N'OVERDUE' THEN 1 WHEN N'ESCALATED' THEN 2 WHEN N'GENERATED' THEN 3 WHEN N'PENDING' THEN 4
                                     WHEN N'IN_PROGRESS' THEN 5 WHEN N'CONFIRMED' THEN 6 WHEN N'DISPUTED' THEN 7 WHEN N'EXCEPTION' THEN 8
                                     WHEN N'RESOLVED' THEN 9 WHEN N'CLOSED' THEN 10 ELSE 11 END
          FROM #att x GROUP BY x.display_status
        UNION ALL
        SELECT N'activities_template', N'Open activities by type', NULL, MAX(o.template_name), COUNT(*), NULL, 1
          FROM #occ o WHERE o.status = N'OPEN' GROUP BY o.template_code
        UNION ALL
        SELECT N'privacy_status', N'Assets by privacy status', p.privacy_status,
               CASE p.privacy_status WHEN N'NON_COMPLIANT' THEN N'Non-compliant' WHEN N'INCOMPLETE' THEN N'Incomplete'
                                     WHEN N'UNDETERMINED' THEN N'Undetermined' WHEN N'CONDITIONAL' THEN N'Conditional'
                                     WHEN N'COMPLIANT' THEN N'Compliant' ELSE N'Not applicable' END,
               COUNT(*), NULL,
               CASE p.privacy_status WHEN N'NON_COMPLIANT' THEN 1 WHEN N'INCOMPLETE' THEN 2 WHEN N'UNDETERMINED' THEN 3
                                     WHEN N'CONDITIONAL' THEN 4 WHEN N'COMPLIANT' THEN 5 ELSE 6 END
          FROM #prv p GROUP BY p.privacy_status
        UNION ALL
        SELECT N'discovery_kind', N'Open reconciliation by kind', r.exception_kind,
               CASE r.exception_kind WHEN N'SUGGESTED_MATCH' THEN N'Suggested match' WHEN N'MANUAL_REVIEW' THEN N'Manual review'
                                     WHEN N'NEW_CANDIDATE' THEN N'New candidate' WHEN N'DUPLICATE' THEN N'Potential duplicate' ELSE N'Conflict' END,
               COUNT(*), NULL,
               CASE r.exception_kind WHEN N'CONFLICT' THEN 1 WHEN N'DUPLICATE' THEN 2 WHEN N'MANUAL_REVIEW' THEN 3
                                     WHEN N'SUGGESTED_MATCH' THEN 4 ELSE 5 END
          FROM #rec r GROUP BY r.exception_kind
        UNION ALL
        SELECT N'discovery_confidence', N'Data confidence (assets)', c.OverallStatus,
               CASE c.OverallStatus WHEN N'CONFLICTING' THEN N'Conflicting' WHEN N'STALE' THEN N'Stale' WHEN N'VERIFIED' THEN N'Verified'
                                    WHEN N'PROBABLE' THEN N'Probable' ELSE N'Unverified' END,
               COUNT(*), NULL,
               CASE c.OverallStatus WHEN N'CONFLICTING' THEN 1 WHEN N'STALE' THEN 2 WHEN N'UNVERIFIED' THEN 3 WHEN N'PROBABLE' THEN 4 ELSE 5 END
          FROM grac_practice.fn_asset_discovery_confidence(@organization_id) c GROUP BY c.OverallStatus
        UNION ALL
        SELECT N'services_status', N'Business services by status', s.status,
               CASE s.status WHEN N'DRAFT' THEN N'Draft' WHEN N'DESIGN' THEN N'Design' WHEN N'ACTIVE' THEN N'Active' WHEN N'DEGRADED' THEN N'Degraded'
                             WHEN N'SUSPENDED' THEN N'Suspended' WHEN N'RETIRING' THEN N'Retiring' ELSE N'Retired' END,
               COUNT(*), NULL,
               CASE s.status WHEN N'DRAFT' THEN 1 WHEN N'DESIGN' THEN 2 WHEN N'ACTIVE' THEN 3 WHEN N'DEGRADED' THEN 4
                             WHEN N'SUSPENDED' THEN 5 WHEN N'RETIRING' THEN 6 ELSE 7 END
          FROM #svc s GROUP BY s.status
        UNION ALL
        SELECT N'relationships_status', N'Relationships by status', r.status,
               CASE r.status WHEN N'PROPOSED' THEN N'Proposed' WHEN N'ACTIVE' THEN N'Active' WHEN N'DISPUTED' THEN N'Disputed'
                             WHEN N'INACTIVE' THEN N'Inactive' ELSE N'Retired' END,
               COUNT(*), NULL,
               CASE r.status WHEN N'PROPOSED' THEN 1 WHEN N'ACTIVE' THEN 2 WHEN N'DISPUTED' THEN 3 WHEN N'INACTIVE' THEN 4 ELSE 5 END
          FROM #rel r GROUP BY r.status
        UNION ALL
        SELECT N'notifications_activity', N'Open notification occurrences by activity', NULL, MAX(n.activity_name), COUNT(*), NULL,
               MIN(n.display_order)
          FROM #ntf n WHERE n.status = N'OPEN' GROUP BY n.activity_code
      ) d
     ORDER BY d.GroupKey, d.SortOrder, d.ItemLabel;

    -- ---- 3. Lists ---------------------------------------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'technology_unsupported' AS ListKey, N'Unsupported or unknown technology' AS ListTitle,
               x.asset_id AS RecordId, CAST(CONCAT(N'#', x.asset_id) AS NVARCHAR(60)) AS RefText, CAST(x.asset_name AS NVARCHAR(400)) AS Title,
               ow.employee_name AS OwnerName,
               CAST(CONCAT(CASE t.kind WHEN N'FIRMWARE' THEN N'Firmware ' ELSE N'Operating system ' END,
                           LOWER(t.classification), ISNULL(N': ' + t.current_label, N'')) AS NVARCHAR(400)) AS StatusText,
               CAST(t.support_end AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY CASE t.classification WHEN N'UNSUPPORTED' THEN 0 ELSE 1 END, t.support_end, x.asset_id) AS SortOrder
          FROM #tech t
          JOIN #ast x ON x.asset_id = t.asset_id
          LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = x.owner_id
         WHERE t.classification IN (N'UNSUPPORTED', N'UNKNOWN')
         ORDER BY CASE t.classification WHEN N'UNSUPPORTED' THEN 0 ELSE 1 END, t.support_end, x.asset_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'contracts_expiring' AS ListKey, N'Active contracts ending in 90 days' AS ListTitle,
               c.contract_id AS RecordId, CAST(c.contract_number AS NVARCHAR(60)) AS RefText, CAST(c.contract_name AS NVARCHAR(400)) AS Title,
               c.owner_name AS OwnerName, CAST(N'Active' AS NVARCHAR(400)) AS StatusText, c.effective_end AS DateValue,
               ROW_NUMBER() OVER (ORDER BY c.effective_end, c.contract_id) AS SortOrder
          FROM #con c
         WHERE c.contract_status = N'ACTIVE' AND c.effective_end BETWEEN @today AND DATEADD(DAY, 90, @today)
         ORDER BY c.effective_end, c.contract_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'attestation_overdue' AS ListKey, N'Overdue attestations' AS ListTitle,
               x.attestation_id AS RecordId, CAST(CONCAT(N'#', x.attestation_id) AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.asset_name, N' - ', LOWER(x.attestation_type)) AS NVARCHAR(400)) AS Title,
               x.assignee_name AS OwnerName, CAST(N'Overdue' AS NVARCHAR(400)) AS StatusText, x.due_date AS DateValue,
               ROW_NUMBER() OVER (ORDER BY x.due_date, x.attestation_id) AS SortOrder
          FROM #att x
         WHERE x.display_status = N'OVERDUE'
         ORDER BY x.due_date, x.attestation_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'activities_overdue' AS ListKey, N'Overdue activities' AS ListTitle,
               o.occurrence_id AS RecordId, CAST(CONCAT(N'#', o.occurrence_id) AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(o.asset_name, N' - ', o.template_name) AS NVARCHAR(400)) AS Title,
               o.owner_name AS OwnerName, CAST(N'Open' AS NVARCHAR(400)) AS StatusText, o.due_date AS DateValue,
               ROW_NUMBER() OVER (ORDER BY o.due_date, o.occurrence_id) AS SortOrder
          FROM #occ o
         WHERE o.status = N'OPEN' AND o.due_date < @today
         ORDER BY o.due_date, o.occurrence_id
      ) l
     ORDER BY 1, 9;
END
GO
PRINT '451: sp_dashboard_asset_contract created.';
GO
-- =====================================================================
-- 2. Menu: Asset & Contract -> Dashboard (first child, 416 rule; also
--    carried in 274) and VIEW for every role that can VIEW one of the
--    screens it summarises (the ManagementDashboards sections).
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (
    SELECT x.menu_key, x.menu_url, x.display_order, x.module_type, p.menu_id AS parent_menu_id
      FROM (VALUES (N'asset-contract-dashboard', N'Practice/Index/asset-contract-dashboard', 348, N'Asset & Contract', N'nav-asset-contract'))
           x(menu_key, menu_url, display_order, module_type, parent_key)
      JOIN grac_practice.menu_master p ON p.menu_key = x.parent_key
) AS s
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_url, N'') <> s.menu_url OR ISNULL(t.parent_menu_id, -1) <> s.parent_menu_id
               OR t.display_order <> s.display_order OR t.menu_name <> N'Dashboard' OR t.status <> N'Active') THEN UPDATE SET
    menu_name = N'Dashboard', menu_url = s.menu_url, parent_menu_id = s.parent_menu_id, display_order = s.display_order,
    icon_class = N'chart-pie', module_type = s.module_type, status = N'Active', updated_by = N'seed-451', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES (s.menu_key, N'Dashboard', s.menu_url, s.parent_menu_id, s.display_order, N'chart-pie', s.module_type, N'Active', N'seed-451');
PRINT CONCAT('451: dashboard menu row upserted: ', @@ROWCOUNT);
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, d.menu_id, 1, 0, 0, 0, 0, N'Active', @active_rs, N'seed-451', SYSUTCDATETIME()
  FROM (VALUES (N'asset-register'), (N'asset-contracts'), (N'asset-attestation'), (N'asset-activities'), (N'asset-privacy'),
               (N'asset-discovery'), (N'business-services'), (N'asset-relationships'), (N'asset-notifications'),
               (N'asset-governance')) x(child_key)
  JOIN grac_practice.menu_master d ON d.menu_key = N'asset-contract-dashboard'
  JOIN grac_practice.menu_master c ON c.menu_key = x.child_key AND c.status = N'Active'
  JOIN grac_practice.organization_role_menu_permission p ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = p.role_id AND e.menu_id = d.menu_id);
PRINT CONCAT('451: dashboard VIEW grants inserted: ', @@ROWCOUNT);
GO
-- =====================================================================
-- 3. Verification
-- =====================================================================
SELECT '451-a procedure' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_dashboard_asset_contract','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '451-b menu: Dashboard is the first Active child of Asset & Contract' AS Check_,
       CASE WHEN (SELECT TOP (1) c.menu_key FROM grac_practice.menu_master c
                    JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                   WHERE c.status = N'Active' ORDER BY c.display_order, c.menu_id) = N'asset-contract-dashboard'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- The dashboard runs for one organization that has assets (four result
-- sets; run it by hand for any other organization).
DECLARE @org BIGINT = (SELECT TOP (1) organization_id FROM grac_practice.organization_dependency_asset ORDER BY organization_id);
IF @org IS NOT NULL EXEC grac_practice.sp_dashboard_asset_contract @organization_id = @org;
GO

/* =====================================================================
   UAT (a role with VIEW on some Asset & Contract screens)
   ---------------------------------------------------------------------
   1. Asset & Contract -> Dashboard opens; only the sections whose screen
      the role may VIEW are shown (remove asset-privacy VIEW -> no Privacy
      section). Re-login after granting.
   2. Asset register: Draft opens the Asset Register filtered to Draft
      with the banner; Clear filter shows every asset; the bar "Assets by
      lifecycle status: Active" opens the register filtered to Active and
      the count matches its total.
   3. Attestation: Overdue opens Asset Attestation -> All occurrences
      filtered to Overdue; same count.
   4. Contracts: Coverage gaps opens the Coverage gaps tab; the count is
      its total. Open renewals opens Renewals (Open).
   5. Privacy: the bar Non-compliant opens Asset Privacy filtered to
      Non-compliant.
   6. CMDB quality: Open conflicts opens the Reconciliation queue with
      Exception = Conflict; Stale assets opens Stale assets.
   7. Lists: a row of Unsupported or unknown technology opens the asset on
      the Asset Register.
   8. Governance: shown once a snapshot exists (Asset Governance);
      the tiles open Asset Governance.
   ===================================================================== */
