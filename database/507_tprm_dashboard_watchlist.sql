-- =====================================================================
-- 507_tprm_dashboard_watchlist.sql
--
-- WHY
-- ---
-- GRAC Dashboard UI / Functional Specification v2 (1 Nov 2026), section 10
-- (TPRM). The Third-Party Risk dashboard moves to the v2 layout. 490 already
-- returns every figure the page shows except the spec's high-risk
-- watchlist (10.4), which this adds. Presentation only -- nothing is
-- written; no table, column, status or workflow change.
--
-- WHAT
--   sp_dashboard_tprm re-issued from the 490 body; same parameter, result
--   sets and columns, every 490 row kept. Added list:
--     tprmengagements_highrisk  the engagements KPI tprmengagements.highrisk
--                               counts (ACTIVE / SUSPENDED, band rank >= 3);
--                               StatusText = band, DateValue = next review
--
-- Not added (no reliable source -- docs/tprm-dashboard-v2.md): vendors
-- missing a due-diligence questionnaire by service category, incomplete
-- third-party profiles, contract value / spend.
--
-- SAFE TO RE-RUN (CREATE OR ALTER). Requires 490 (and 486-489, the TPRM
-- module). ASCII-only. Rollback: 507_tprm_dashboard_watchlist_rollback.sql
-- Refuses to re-run once 525 is applied (525 carries this body).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_dashboard_tprm','P') IS NULL
   OR COL_LENGTH('grac_practice.tprm_engagement','next_review_dt') IS NULL
BEGIN
    PRINT 'ABORT (507): run the TPRM migrations 486-490 first.';
    SET NOEXEC ON;
END
GO
-- 525 re-issues sp_dashboard_tprm from this body plus the CR 2 views;
-- running 507 again would remove them.
IF OBJECT_ID('grac_practice.tprm_register_profile_review','U') IS NOT NULL
BEGIN
    PRINT 'ABORT (507): superseded by 525_tpm_dashboard_tasks_profile_review.sql, which is already applied. Do not re-run 507.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_tprm
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57900, 'sp_dashboard_tprm: organization_id is required.', 1;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Engagements with the band / criticality the engagement list shows.
    SELECT e.engagement_id, e.engagement_code, e.engagement_title, e.stage_code, e.stage_dt, t.legal_name AS third_party_name,
           COALESCE(e.residual_band_code, e.inherent_band_code) AS band_code, b.band_name, b.color_hex, b.rank_no AS band_rank,
           e.service_criticality_code, e.reassessment_required, e.next_review_dt, e.acceptance_until,
           COALESCE(e.actual_end_dt, e.proposed_end_dt) AS end_dt,
           ow.employee_name AS owner_name
      INTO #eng
      FROM grac_practice.tprm_engagement e
      JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
      LEFT JOIN grac_practice.tprm_rm_band b ON b.version_id = e.risk_model_version_id
                                            AND b.band_code = COALESCE(e.residual_band_code, e.inherent_band_code)
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = COALESCE(e.relationship_owner_employee_id, e.business_owner_employee_id)
     WHERE e.organization_id = @organization_id;

    SELECT f.finding_id, f.finding_number, f.finding_kind, f.title, f.severity_code, f.status, f.due_dt, f.entered_dt,
           f.engagement_id, ow.employee_name AS owner_name, sv.rank_no AS severity_rank, sv.label AS severity_label, sv.color_hex
      INTO #fnd
      FROM grac_practice.tprm_finding f
      JOIN #eng x ON x.engagement_id = f.engagement_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = f.owner_employee_id
      LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) sv ON sv.list_code = N'FINDING_SEVERITY' AND sv.value_code = f.severity_code
     WHERE f.status IN (N'OPEN', N'IN_PROGRESS')
       AND x.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED');   -- findings of closed engagements are history

    SELECT r.review_id, r.review_number, r.review_type, r.trigger_code, r.due_dt, r.raised_dt, r.engagement_id,
           ow.employee_name AS owner_name
      INTO #rev
      FROM grac_practice.tprm_review r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
     WHERE r.organization_id = @organization_id AND r.status = N'OPEN';

    SELECT d.dd_id, d.engagement_id, d.due_dt, d.started_dt
      INTO #dd
      FROM grac_practice.tprm_dd_assessment d
     WHERE d.organization_id = @organization_id AND d.status = N'IN_PROGRESS';

    SELECT d.decision_id, d.engagement_id, d.submitted_dt
      INTO #dec
      FROM grac_practice.tprm_decision d
     WHERE d.organization_id = @organization_id AND d.status = N'PENDING';

    DECLARE @open_stages TABLE (stage_code NVARCHAR(30));
    INSERT @open_stages VALUES (N'SCOPING'), (N'RISK_ASSESSED'), (N'DUE_DILIGENCE'), (N'PENDING_DECISION'), (N'APPROVED'),
                               (N'ONBOARDING'), (N'ACTIVE'), (N'SUSPENDED'), (N'EXITING');

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'tprmthirdparties' AS SectionKey, N'Third parties' AS SectionTitle, N'total' AS KpiKey, N'Registered (active records)' AS Label,
               (SELECT COUNT(*) FROM grac_practice.tprm_third_party WHERE organization_id = @organization_id AND status = N'Active') AS Value,
               CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
        UNION ALL SELECT N'tprmthirdparties', N'Third parties', N'withactive', N'With an active engagement',
                         (SELECT COUNT(DISTINCT e.third_party_id) FROM grac_practice.tprm_engagement e
                           WHERE e.organization_id = @organization_id AND e.stage_code = N'ACTIVE'), 0, 2
        UNION ALL SELECT N'tprmthirdparties', N'Third parties', N'samples', N'Sample records',
                         (SELECT COUNT(*) FROM grac_practice.tprm_third_party WHERE organization_id = @organization_id AND is_sample = 1 AND status = N'Active'), 0, 3

        UNION ALL SELECT N'tprmengagements', N'Engagements', N'open', N'Open engagements',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)), 0, 1
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'inassessment', N'In assessment',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE')), 0, 2
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'pendingdecision', N'Pending decision',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code = N'PENDING_DECISION'), 1, 3
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'active', N'Active',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code = N'ACTIVE'), 0, 4
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'highrisk', N'Active, high or critical band',
                         (SELECT COUNT(*) FROM #eng x WHERE x.stage_code IN (N'ACTIVE', N'SUSPENDED') AND x.band_rank >= 3), 1, 5
        UNION ALL SELECT N'tprmengagements', N'Engagements', N'reassess', N'Reassessment required',
                         (SELECT COUNT(*) FROM #eng x WHERE x.reassessment_required = 1 AND x.stage_code IN (SELECT stage_code FROM @open_stages)), 1, 6

        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'inprogress', N'Rounds in progress', (SELECT COUNT(*) FROM #dd), 0, 1
        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'overdue', N'Overdue rounds',
                         (SELECT COUNT(*) FROM #dd WHERE due_dt < @today), 1, 2
        UNION ALL SELECT N'tprmdiligence', N'Due diligence', N'evidencepending', N'Evidence awaiting review',
                         (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l JOIN #eng x ON x.engagement_id = l.engagement_id
                           WHERE l.status = N'Active' AND l.review_status = N'PENDING'), 1, 3

        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'open', N'Open findings', (SELECT COUNT(*) FROM #fnd), 0, 1
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'high', N'Open high or critical',
                         (SELECT COUNT(*) FROM #fnd WHERE severity_rank >= 3), 1, 2
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'overdue', N'Overdue remediation',
                         (SELECT COUNT(*) FROM #fnd WHERE due_dt < @today), 1, 3
        UNION ALL SELECT N'tprmfindings', N'Findings and remediation', N'conditions', N'Open approval conditions',
                         (SELECT COUNT(*) FROM #fnd WHERE finding_kind = N'CONDITION'), 0, 4

        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'open', N'Open reviews', (SELECT COUNT(*) FROM #rev), 0, 1
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'overdue', N'Overdue reviews',
                         (SELECT COUNT(*) FROM #rev WHERE due_dt < @today), 1, 2
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'due30', N'Due in 30 days',
                         (SELECT COUNT(*) FROM #rev WHERE due_dt BETWEEN @today AND DATEADD(DAY, 30, @today)), 0, 3
        UNION ALL SELECT N'tprmreviews', N'Reviews and monitoring', N'triggered', N'Open triggered reviews',
                         (SELECT COUNT(*) FROM #rev WHERE review_type = N'TRIGGERED'), 0, 4

        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'accepted', N'Live engagements with accepted risk',
                         (SELECT COUNT(*) FROM #eng x WHERE x.acceptance_until IS NOT NULL AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')), 0, 1
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'acceptexpiring', N'Acceptance ending in 60 days',
                         (SELECT COUNT(*) FROM #eng x WHERE x.acceptance_until BETWEEN @today AND DATEADD(DAY, 60, @today)
                             AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')), 1, 2
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'contractexpiring', N'Engagements ending in 90 days',
                         (SELECT COUNT(*) FROM #eng x WHERE x.end_dt BETWEEN @today AND DATEADD(DAY, 90, @today) AND x.stage_code IN (N'ACTIVE', N'SUSPENDED')), 1, 3
        UNION ALL SELECT N'tprmacceptance', N'Acceptance and expiry', N'certexpiring', N'Accepted evidence expiring in 60 days',
                         (SELECT COUNT(*) FROM grac_practice.tprm_evidence_link l JOIN #eng x ON x.engagement_id = l.engagement_id
                           WHERE l.status = N'Active' AND l.review_status = N'ACCEPTED' AND x.stage_code IN (N'ACTIVE', N'SUSPENDED')
                             AND l.valid_to BETWEEN @today AND DATEADD(DAY, 60, @today)), 1, 4
      ) k
     ORDER BY CASE k.SectionKey WHEN N'tprmthirdparties' THEN 1 WHEN N'tprmengagements' THEN 2 WHEN N'tprmdiligence' THEN 3
                                WHEN N'tprmfindings' THEN 4 WHEN N'tprmreviews' THEN 5 ELSE 6 END, k.SortOrder;

    -- ---- 1. Ageing: open findings (days since recorded), pending
    --         decisions (days since requested) -----------------------------
    SELECT N'tprmfindings' AS GroupKey, N'Open findings' AS GroupTitle,
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #fnd x WHERE DATEDIFF(DAY, x.entered_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays) AS ItemCount
      FROM grac_practice.fn_pm_ageing_band() b
    UNION ALL
    SELECT N'tprmengagements', N'Pending decisions',
           b.BandCode, b.BandName, b.SortOrder, b.MinDays, b.MaxDays,
           (SELECT COUNT(*) FROM #dec x WHERE DATEDIFF(DAY, x.submitted_dt, SYSUTCDATETIME()) BETWEEN b.MinDays AND b.MaxDays)
      FROM grac_practice.fn_pm_ageing_band() b
     ORDER BY 1, 5;

    -- ---- 2. Distributions ----------------------------------------------
    -- ItemKey is the value the Engagements / Reviews filter takes.
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'tprmengagements_stage' AS GroupKey, N'Engagements by stage' AS GroupTitle,
               x.stage_code AS ItemKey,
               CAST(CASE x.stage_code WHEN N'SCOPING' THEN N'Scoping' WHEN N'RISK_ASSESSED' THEN N'Risk assessed'
                    WHEN N'DUE_DILIGENCE' THEN N'Due diligence' WHEN N'PENDING_DECISION' THEN N'Pending decision'
                    WHEN N'APPROVED' THEN N'Approved' WHEN N'ONBOARDING' THEN N'Onboarding' WHEN N'ACTIVE' THEN N'Active'
                    WHEN N'SUSPENDED' THEN N'Suspended' WHEN N'EXITING' THEN N'Exiting' ELSE x.stage_code END AS NVARCHAR(200)) AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
               MIN(CASE x.stage_code WHEN N'SCOPING' THEN 1 WHEN N'RISK_ASSESSED' THEN 2 WHEN N'DUE_DILIGENCE' THEN 3
                    WHEN N'PENDING_DECISION' THEN 4 WHEN N'APPROVED' THEN 5 WHEN N'ONBOARDING' THEN 6 WHEN N'ACTIVE' THEN 7
                    WHEN N'SUSPENDED' THEN 8 ELSE 9 END) AS SortOrder
          FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.stage_code
        UNION ALL
        SELECT N'tprmengagements_band', N'Open engagements by risk band (residual, else inherent)',
               x.band_code, CAST(ISNULL(MAX(x.band_name), N'Not assessed') AS NVARCHAR(200)), COUNT(*), MAX(x.color_hex), ISNULL(MAX(x.band_rank), 0)
          FROM #eng x WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.band_code
        UNION ALL
        SELECT N'tprmengagements_criticality', N'Open engagements by service criticality',
               x.service_criticality_code, CAST(ISNULL(MAX(c.label), N'Not set') AS NVARCHAR(200)), COUNT(*), MAX(c.color_hex), ISNULL(MAX(c.rank_no), 0)
          FROM #eng x
          LEFT JOIN grac_practice.fn_tprm_reference_effective(@organization_id) c ON c.list_code = N'CRITICALITY' AND c.value_code = x.service_criticality_code
         WHERE x.stage_code IN (SELECT stage_code FROM @open_stages)
         GROUP BY x.service_criticality_code
        UNION ALL
        SELECT N'tprmfindings_severity', N'Open findings by severity',
               CAST(NULL AS NVARCHAR(60)), CAST(ISNULL(MAX(f.severity_label), f.severity_code) AS NVARCHAR(200)), COUNT(*), MAX(f.color_hex), ISNULL(MAX(f.severity_rank), 0) * -1
          FROM #fnd f GROUP BY f.severity_code
        UNION ALL
        SELECT N'tprmreviews_type', N'Open reviews by type',
               x.review_type,
               CAST(CASE x.review_type WHEN N'PERIODIC' THEN N'Periodic' WHEN N'TRIGGERED' THEN N'Triggered'
                    WHEN N'CONTRACT_EXPIRY' THEN N'Contract expiry' WHEN N'CERTIFICATION_EXPIRY' THEN N'Certification expiry'
                    ELSE N'Acceptance expiry' END AS NVARCHAR(200)),
               COUNT(*), CAST(NULL AS NVARCHAR(20)),
               MIN(CASE x.review_type WHEN N'PERIODIC' THEN 1 WHEN N'TRIGGERED' THEN 2 WHEN N'CONTRACT_EXPIRY' THEN 3
                    WHEN N'CERTIFICATION_EXPIRY' THEN 4 ELSE 5 END)
          FROM #rev x GROUP BY x.review_type
      ) d
     ORDER BY d.GroupKey, d.SortOrder, d.ItemLabel;

    -- ---- 3. Lists ---------------------------------------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmreviews_overdue' AS ListKey, N'Overdue reviews' AS ListTitle,
               r.engagement_id AS RecordId, CAST(r.review_number AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               r.owner_name AS OwnerName, CAST(r.trigger_code AS NVARCHAR(400)) AS StatusText, r.due_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY r.due_dt, r.review_id) AS SortOrder
          FROM #rev r JOIN #eng x ON x.engagement_id = r.engagement_id
         WHERE r.due_dt < @today
         ORDER BY r.due_dt, r.review_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmfindings_overdue' AS ListKey, N'Overdue remediation' AS ListTitle,
               f.engagement_id AS RecordId, CAST(f.finding_number AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.engagement_code, N' - ', f.title) AS NVARCHAR(400)) AS Title,
               f.owner_name AS OwnerName, CAST(ISNULL(f.severity_label, f.severity_code) AS NVARCHAR(400)) AS StatusText, f.due_dt AS DateValue,
               ROW_NUMBER() OVER (ORDER BY f.due_dt, f.finding_id) AS SortOrder
          FROM #fnd f JOIN #eng x ON x.engagement_id = f.engagement_id
         WHERE f.due_dt < @today
         ORDER BY f.due_dt, f.finding_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmengagements_decisions' AS ListKey, N'Pending decisions' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, N'Not assessed') AS NVARCHAR(400)) AS StatusText,
               CAST(d.submitted_dt AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY d.submitted_dt, d.decision_id) AS SortOrder
          FROM #dec d JOIN #eng x ON x.engagement_id = d.engagement_id
         ORDER BY d.submitted_dt, d.decision_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'tprmacceptance_expiring' AS ListKey, N'Risk acceptance ending in 60 days' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, N'') AS NVARCHAR(400)) AS StatusText, x.acceptance_until AS DateValue,
               ROW_NUMBER() OVER (ORDER BY x.acceptance_until, x.engagement_id) AS SortOrder
          FROM #eng x
         WHERE x.acceptance_until BETWEEN @today AND DATEADD(DAY, 60, @today)
           AND x.stage_code IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED')
         ORDER BY x.acceptance_until, x.engagement_id
      ) l
    UNION ALL
    -- 507: high-risk watchlist (spec 10.4) -- exactly the engagements KPI
    -- tprmengagements.highrisk counts (ACTIVE / SUSPENDED, band rank >= 3),
    -- highest band first, then the nearest next review. StatusText = band;
    -- DateValue = next review date.
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (15) N'tprmengagements_highrisk' AS ListKey, N'High-risk engagements' AS ListTitle,
               x.engagement_id AS RecordId, CAST(x.engagement_code AS NVARCHAR(60)) AS RefText,
               CAST(CONCAT(x.third_party_name, N' - ', x.engagement_title) AS NVARCHAR(400)) AS Title,
               x.owner_name AS OwnerName, CAST(ISNULL(x.band_name, x.band_code) AS NVARCHAR(400)) AS StatusText,
               CAST(x.next_review_dt AS DATE) AS DateValue,
               ROW_NUMBER() OVER (ORDER BY x.band_rank DESC, CASE WHEN x.next_review_dt IS NULL THEN 1 ELSE 0 END,
                                           x.next_review_dt, x.engagement_id) AS SortOrder
          FROM #eng x
         WHERE x.stage_code IN (N'ACTIVE', N'SUSPENDED') AND x.band_rank >= 3
         ORDER BY x.band_rank DESC, CASE WHEN x.next_review_dt IS NULL THEN 1 ELSE 0 END, x.next_review_dt, x.engagement_id
      ) l
     ORDER BY 1, 9;
END
GO

PRINT '=== 507 verification ===';
SELECT '507 sp_dashboard_tprm' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_tprm')) LIKE '%tprmengagements_highrisk%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
SET NOEXEC OFF;
GO
