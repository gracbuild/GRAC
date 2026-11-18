-- =====================================================================
-- 573  Governance dashboard: framework filter
--
-- REQUEST (2026-11-16)
--   "dashboard lu filter lu organization nte koode framework nte filter
--    koodi vakkamo? first load lu All koduthitu avasyam undenkil framework
--    selection cheythal aa framework nte mathram display cheyyanam"
--
-- WHAT THIS DOES
--   1. grac_practice.fn_pm_release_requirements(@organization_id, @release_id)
--      (new, inline TVF): the organisation requirements that belong to a
--      framework release. Same rule as Practice View's Mapped frameworks
--      (301 sp_practice_detail_get MappedFrameworksJson):
--        * an Active statement mapping whose release
--          (mapping.release_id, else the statement's release) is the
--          release; or
--        * no Active statement mapping at all, and the requirement's
--          organisation control belongs to the release.
--   2. grac_practice.sp_dashboard_governance (528 body otherwise
--      unchanged) takes @release_id BIGINT = NULL. NULL (All frameworks)
--      gives exactly the 528 figures. With a release, practice instances
--      (and through them evidence, dependencies, the watchlist) and the
--      practice counts cover only practices whose requirement belongs to
--      that release.
--      New KPIs practices.total / applicable / notapplicable / notupdated
--      (the 404 dashboard-summary definitions, in scope of the filter) so
--      the Practices card and Practice applicability chart can follow the
--      filter.
--   The control-statement figures need no SQL: the page already has one
--   row per subscribed release (subscribed-frameworks) and shows only the
--   chosen one.
--
-- SAFE TO RE-RUN. Requires 528. ASCII-only.
-- Rollback: 573_governance_dashboard_framework_filter_rollback.sql (528 body)
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_governance')), N'') NOT LIKE N'%practices_implemented_n%'
   OR COL_LENGTH('grac_practice.organization_statement_practice_mapping','org_practice_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_statement_practice_mapping','release_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_framework_statements','release_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_requirement','organization_control_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_control','release_id') IS NULL
   OR COL_LENGTH('grac_practice.practice','organization_requirement_id') IS NULL
BEGIN
    PRINT 'ABORT (573): run 528 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- ---- 1. Requirements of a framework release -------------------------
CREATE OR ALTER FUNCTION grac_practice.fn_pm_release_requirements
(
    @organization_id BIGINT,
    @release_id      BIGINT
)
RETURNS TABLE
AS
RETURN
    SELECT q.organization_requirement_id
      FROM grac_practice.organization_requirement q
     WHERE q.organization_id = @organization_id
       AND (
            EXISTS (SELECT 1
                      FROM grac_practice.organization_statement_practice_mapping m
                      LEFT JOIN grac_practice.organization_framework_statements ofs
                             ON ofs.org_statement_id = m.org_statement_id
                     WHERE m.org_practice_id = q.organization_requirement_id
                       AND m.status = N'Active'
                       AND COALESCE(m.release_id, ofs.release_id) = @release_id)
         OR (    NOT EXISTS (SELECT 1
                               FROM grac_practice.organization_statement_practice_mapping m2
                              WHERE m2.org_practice_id = q.organization_requirement_id
                                AND m2.status = N'Active')
             AND EXISTS (SELECT 1
                           FROM grac_practice.organization_control oc
                          WHERE oc.organization_control_id = q.organization_control_id
                            AND oc.release_id = @release_id))
           );
GO

-- ---- 2. Governance dashboard with @release_id ------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_governance
    @organization_id    BIGINT,
    @caller_employee_id BIGINT = NULL,
    @is_admin           BIT    = 0,
    @release_id         BIGINT = NULL   -- 573: framework filter; NULL = all frameworks
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57312, 'sp_dashboard_governance: organization_id is required.', 1;
    SET @is_admin = ISNULL(@is_admin, 0);

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    -- 573: framework filter. The organisation requirements that belong to
    -- the chosen release (fn_pm_release_requirements -- the Practice View
    -- "Mapped frameworks" rule). A practice is in scope through its
    -- organization_requirement_id; with no release chosen every practice
    -- is in scope, exactly as before.
    CREATE TABLE #rel (organization_requirement_id BIGINT NOT NULL PRIMARY KEY);
    IF @release_id IS NOT NULL
        INSERT INTO #rel (organization_requirement_id)
        SELECT DISTINCT organization_requirement_id
          FROM grac_practice.fn_pm_release_requirements(@organization_id, @release_id);
    DECLARE @inst_title NVARCHAR(200) =
        CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END;

    -- A non-admin with no employee record owns nothing (398's rule for
    -- an unmatched caller): every count is zero rather than an error.
    -- 503: + criticality and the watchlist columns.
    SELECT pi.practice_instance_id,
           pi.primary_owner_id,
           COALESCE(ims.status_name, pi.implementation_status) AS implementation_status,
           NULLIF(LTRIM(RTRIM(pi.criticality)), N'')            AS criticality,
           pi.instance_code,
           COALESCE(NULLIF(pi.instance_name, N''), p.practice_name) AS instance_title,
           COALESCE(owner_emp.employee_name, pi.primary_owner)  AS owner_name,
           COALESCE(pi.updated_dt, pi.entered_dt)               AS last_updated_dt
      INTO #ins
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
      LEFT JOIN grac_practice.implementation_status_master ims
             ON ims.implementation_status_id = pi.implementation_status_id
      LEFT JOIN grac_practice.organization_employee owner_emp
             ON owner_emp.employee_id = pi.primary_owner_id
     WHERE pi.organization_id = @organization_id
       AND pi.status = N'Active'
       AND (@is_admin = 1 OR (@caller_employee_id IS NOT NULL AND pi.primary_owner_id = @caller_employee_id))
       AND (@release_id IS NULL OR EXISTS (SELECT 1 FROM #rel x WHERE x.organization_requirement_id = p.organization_requirement_id));   -- 573

    -- 503: evidence rows of those instances, with cadence and the 481
    -- resolved rule (the same function Operationalize uses).
    SELECT e.evidence_id,
           e.practice_instance_id,
           c.EvidenceCadence AS cadence,
           grac_practice.fn_pm_instance_evidence_is_resolved(
               e.evidence_source, e.evidence_location, e.evidence_locator, e.evidence_id) AS is_resolved,
           al.alignment_status_name AS alignment_status
      INTO #ev
      FROM grac_practice.practice_instance_evidence e
      JOIN #ins i ON i.practice_instance_id = e.practice_instance_id
      JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
      LEFT JOIN grac_practice.evidence_alignment_status_master al
             ON al.alignment_status_id = e.alignment_status_id
     WHERE e.status = N'Active';

    -- 503: dependency objects linked on Operationalize.
    SELECT r.practice_instance_id,
           COALESCE(NULLIF(dt.dependency_type_name, N''), NULLIF(r.dependency_category, N''), N'Other') AS category
      INTO #dep
      FROM grac_practice.practice_dependency_resolution r
      JOIN #ins i ON i.practice_instance_id = r.practice_instance_id
      LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = r.dependency_type_id
     WHERE r.is_active = 1;

    -- 503: instances with an expired dependency -- the Home overview's
    -- definition (dashboard-summary, 404), scoped to #ins.
    DECLARE @expired_n INT = (
        SELECT COUNT(*) FROM #ins i
         WHERE EXISTS (
            SELECT 1
              FROM grac_practice.practice_dependency_resolution r
              LEFT JOIN grac_practice.organization_dependency_tool t ON t.tool_id = r.resolved_dependency_id AND r.dependency_category IN (N'Tool', N'Tools')
              LEFT JOIN grac_practice.organization_dependency_application a ON a.application_id = r.resolved_dependency_id AND r.dependency_category IN (N'Application', N'Applications')
              LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = r.resolved_dependency_id AND r.dependency_category IN (N'Vendor', N'Vendors')
             WHERE r.practice_instance_id = i.practice_instance_id
               AND r.organization_id = @organization_id
               AND r.is_active = 1
               AND (   t.license_expiry_dt < @today OR t.support_expiry_dt < @today
                    OR a.support_expiry_dt < @today OR a.end_of_life_dt < @today
                    OR v.contract_end_dt < @today)));

    -- 503: open overdue Schedule tasks whose obligation has recurring
    -- evidence (the 482 rule Complete Task applies).
    DECLARE @recurring_overdue_n INT = (
        SELECT COUNT(*)
          FROM grac_practice.vw_pm_practice_task v
          JOIN #ins i ON i.practice_instance_id = v.linked_instance_id
         WHERE v.organization_id = @organization_id
           AND v.source_type_code = N'Schedule'
           AND v.is_overdue = 1
           AND v.closed_at IS NULL
           AND EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(v.task_id)));

    -- 503: organisation-level -- applicable practices with no Active
    -- instance (the Home overview's attention rule).
    DECLARE @no_instance_n INT = (
        SELECT COUNT(*) FROM grac_practice.practice p
         WHERE p.organization_id = @organization_id AND p.status = N'Active'
           AND p.applicability_status = N'Applicable'
           AND (@release_id IS NULL OR EXISTS (SELECT 1 FROM #rel x WHERE x.organization_requirement_id = p.organization_requirement_id))   -- 573
           AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance pi
                            WHERE pi.practice_id = p.practice_id AND pi.status = N'Active'));

    -- 528: organisation-level -- applicable practices that are
    -- Implemented, by the Practices grid's rule (PracticeImplementationStatus):
    -- at least one Active instance of the practice's requirement, and every
    -- one of them Implemented. Partially Implemented is NOT counted.
    -- Same practice population as the Applicable practices card
    -- (practice.applicability_status = Applicable).
    DECLARE @practices_implemented_n INT = (
        SELECT COUNT(*) FROM grac_practice.practice p
         WHERE p.organization_id = @organization_id AND p.status = N'Active'
           AND p.applicability_status = N'Applicable'
           AND (@release_id IS NULL OR EXISTS (SELECT 1 FROM #rel x WHERE x.organization_requirement_id = p.organization_requirement_id))   -- 573
           AND EXISTS (SELECT 1
                         FROM grac_practice.practice_instance pi
                         JOIN grac_practice.practice pp ON pp.practice_id = pi.practice_id
                        WHERE pi.organization_id = p.organization_id
                          AND pi.status = N'Active'
                          AND (pp.organization_requirement_id = p.organization_requirement_id
                               OR (p.organization_requirement_id IS NULL AND pp.practice_id = p.practice_id)))
           AND NOT EXISTS (SELECT 1
                             FROM grac_practice.practice_instance pi
                             JOIN grac_practice.practice pp ON pp.practice_id = pi.practice_id
                             LEFT JOIN grac_practice.implementation_status_master ism
                                    ON ism.implementation_status_id = pi.implementation_status_id
                            WHERE pi.organization_id = p.organization_id
                              AND pi.status = N'Active'
                              AND (pp.organization_requirement_id = p.organization_requirement_id
                                   OR (p.organization_requirement_id IS NULL AND pp.practice_id = p.practice_id))
                              AND ISNULL(ism.status_code, N'') <> N'Implemented'));

    -- 573: practice applicability of the practices in scope -- the same
    -- definitions as the Home overview's dashboard-summary (404:
    -- TotalPractices / ApplicablePractices / NotApplicablePractices /
    -- NotUpdatedPractices), so with no release chosen the figures match it.
    DECLARE @p_total INT, @p_applicable INT, @p_notapplicable INT, @p_notupdated INT;
    SELECT @p_total         = COUNT(*),
           @p_applicable    = SUM(CASE WHEN p.applicability_status = N'Applicable' THEN 1 ELSE 0 END),
           @p_notapplicable = SUM(CASE WHEN p.applicability_status = N'Not Applicable' THEN 1 ELSE 0 END),
           @p_notupdated    = SUM(CASE WHEN p.applicability_status IN (N'Not Updated', N'Pending', N'') THEN 1 ELSE 0 END)
      FROM grac_practice.practice p
     WHERE p.organization_id = @organization_id AND p.status = N'Active'
       AND (@release_id IS NULL OR EXISTS (SELECT 1 FROM #rel x WHERE x.organization_requirement_id = p.organization_requirement_id));

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'instances' AS SectionKey, @inst_title AS SectionTitle,
               N'total' AS KpiKey, N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
          FROM #ins
        UNION ALL SELECT N'instances', @inst_title, N'implemented', N'Implemented',
                         SUM(CASE WHEN implementation_status = N'Implemented' THEN 1 ELSE 0 END), 0, 2 FROM #ins
        UNION ALL SELECT N'instances', @inst_title, N'partial', N'Partially implemented',
                         SUM(CASE WHEN implementation_status = N'Partially Implemented' THEN 1 ELSE 0 END), 0, 3 FROM #ins
        UNION ALL SELECT N'instances', @inst_title, N'notimplemented', N'Not implemented',
                         SUM(CASE WHEN implementation_status = N'Not Implemented' THEN 1 ELSE 0 END), 1, 4 FROM #ins
        -- 456: the default status.
        UNION ALL SELECT N'instances', @inst_title, N'notupdated', N'Not updated',
                         SUM(CASE WHEN implementation_status = N'Not Updated' THEN 1 ELSE 0 END), 0, 5 FROM #ins
        -- Only an admin sees unowned instances in Operationalize, so only
        -- an admin gets this tile.
        UNION ALL SELECT N'instances', N'Practice instances', N'noowner', N'No owner',
                         SUM(CASE WHEN primary_owner_id IS NULL THEN 1 ELSE 0 END), 1, 6
                    FROM #ins WHERE @is_admin = 1
                  HAVING @is_admin = 1
        -- 503 ------------------------------------------------------------
        UNION ALL SELECT N'instances', @inst_title, N'critical', N'Critical',
                         SUM(CASE WHEN criticality = N'Critical' THEN 1 ELSE 0 END), 0, 7 FROM #ins
        UNION ALL SELECT N'instances', @inst_title, N'criticalopen', N'Critical not implemented',
                         SUM(CASE WHEN criticality = N'Critical' AND ISNULL(implementation_status, N'') <> N'Implemented' THEN 1 ELSE 0 END), 1, 8 FROM #ins
        UNION ALL SELECT N'practices', N'Practices', N'noinstance', N'Applicable without an instance',
                         @no_instance_n, 1, 10
        -- 528
        UNION ALL SELECT N'practices', N'Practices', N'implemented', N'Applicable and implemented',
                         @practices_implemented_n, 0, 11
        -- 573
        UNION ALL SELECT N'practices', N'Practices', N'total', N'Practices', ISNULL(@p_total, 0), 0, 12
        UNION ALL SELECT N'practices', N'Practices', N'applicable', N'Applicable', ISNULL(@p_applicable, 0), 0, 13
        UNION ALL SELECT N'practices', N'Practices', N'notapplicable', N'Not applicable', ISNULL(@p_notapplicable, 0), 0, 14
        UNION ALL SELECT N'practices', N'Practices', N'notupdated', N'Not updated', ISNULL(@p_notupdated, 0), 1, 15
        UNION ALL SELECT N'evidence', N'Evidence', N'onetime', N'One-time evidence',
                         COUNT(*), 0, 20 FROM #ev WHERE cadence <> N'Recurring'
        UNION ALL SELECT N'evidence', N'Evidence', N'onetimeresolved', N'One-time provided',
                         SUM(CASE WHEN is_resolved = 1 THEN 1 ELSE 0 END), 0, 21 FROM #ev WHERE cadence <> N'Recurring'
        UNION ALL SELECT N'evidence', N'Evidence', N'onetimemissing', N'One-time missing',
                         SUM(CASE WHEN is_resolved = 1 THEN 0 ELSE 1 END), 1, 22 FROM #ev WHERE cadence <> N'Recurring'
        UNION ALL SELECT N'evidence', N'Evidence', N'recurring', N'Recurring evidence',
                         COUNT(*), 0, 23 FROM #ev WHERE cadence = N'Recurring'
        UNION ALL SELECT N'evidence', N'Evidence', N'recurringoverdue', N'Recurring evidence tasks overdue',
                         @recurring_overdue_n, 1, 24
        UNION ALL SELECT N'dependencies', N'Dependencies', N'linked', N'Linked dependency objects',
                         COUNT(*), 0, 30 FROM #dep
        UNION ALL SELECT N'dependencies', N'Dependencies', N'instances', N'Instances with dependencies',
                         COUNT(DISTINCT practice_instance_id), 0, 31 FROM #dep
        UNION ALL SELECT N'dependencies', N'Dependencies', N'expired', N'Instances with an expired dependency',
                         @expired_n, 1, 32
      ) k
     ORDER BY k.SortOrder;

    -- ---- 1. Ageing: none. Practice instances carry no due, review or
    --      target date, so no ageing is invented. Empty set, same shape.
    SELECT CAST(NULL AS NVARCHAR(40)) AS GroupKey, CAST(NULL AS NVARCHAR(200)) AS GroupTitle,
           CAST(NULL AS NVARCHAR(20)) AS BandCode, CAST(NULL AS NVARCHAR(60)) AS BandName,
           CAST(NULL AS INT) AS SortOrder, CAST(NULL AS INT) AS MinDays, CAST(NULL AS INT) AS MaxDays,
           CAST(NULL AS INT) AS ItemCount
     WHERE 1 = 0;

    -- ---- 2. Distributions ------------------------------------------------
    -- instances_status: ItemKey is the value Operationalize's Status filter
    -- takes (unchanged from 414/456). The 503 groups have no list filter
    -- to open, so their ItemKey is NULL (not a link).
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'instances_status' AS GroupKey, N'Practice instances by implementation status' AS GroupTitle,
               implementation_status AS ItemKey, ISNULL(implementation_status, N'(not set)') AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, implementation_status) AS SortOrder
          FROM #ins
         GROUP BY implementation_status
        UNION ALL
        SELECT N'instances_criticality', N'Practice instances by criticality',
               CAST(NULL AS NVARCHAR(100)), ISNULL(criticality, N'Not set'), COUNT(*), CAST(NULL AS NVARCHAR(20)),
               CASE ISNULL(criticality, N'') WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                    WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 WHEN N'' THEN 6 ELSE 5 END
          FROM #ins
         GROUP BY criticality
        UNION ALL
        SELECT N'evidence_alignment', N'Evidence rows by alignment status',
               CAST(NULL AS NVARCHAR(100)), ISNULL(alignment_status, N'Not set'), COUNT(*), CAST(NULL AS NVARCHAR(20)),
               CAST(100 + ROW_NUMBER() OVER (ORDER BY CASE WHEN alignment_status IS NULL THEN 1 ELSE 0 END, COUNT(*) DESC, alignment_status) AS INT)
          FROM #ev
         GROUP BY alignment_status
        UNION ALL
        SELECT N'dependencies_category', N'Linked dependency objects by category',
               CAST(NULL AS NVARCHAR(100)), category, COUNT(*), CAST(NULL AS NVARCHAR(20)),
               CAST(200 + ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, category) AS INT)
          FROM #dep
         GROUP BY category
      ) d
     ORDER BY d.SortOrder, d.GroupKey;

    -- ---- 3. Lists --------------------------------------------------------
    -- 503: watchlist -- Critical instances not Implemented. Not Implemented
    -- first, then Partially, then Not Updated; oldest update first.
    SELECT TOP (20)
           N'instances_critical' AS ListKey,
           N'Critical practice instances not implemented' AS ListTitle,
           i.practice_instance_id AS RecordId,
           CAST(i.instance_code AS NVARCHAR(100)) AS RefText,
           CAST(i.instance_title AS NVARCHAR(400)) AS Title,
           CAST(i.owner_name AS NVARCHAR(300)) AS OwnerName,
           CAST(ISNULL(i.implementation_status, N'Not set') AS NVARCHAR(100)) AS StatusText,
           CAST(i.last_updated_dt AS DATE) AS DateValue,
           CAST(ROW_NUMBER() OVER (ORDER BY
                CASE i.implementation_status WHEN N'Not Implemented' THEN 1 WHEN N'Partially Implemented' THEN 2 ELSE 3 END,
                i.last_updated_dt, i.practice_instance_id) AS INT) AS SortOrder
      FROM #ins i
     WHERE i.criticality = N'Critical'
       AND ISNULL(i.implementation_status, N'') <> N'Implemented'
     ORDER BY SortOrder;
END
GO

SELECT '573 fn_pm_release_requirements' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_release_requirements') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '573 sp_dashboard_governance @release_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_dashboard_governance') AND name = '@release_id')
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_dashboard_governance')) LIKE '%practices_implemented_n%'
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '573 complete. Deploy Api and Web, then hard-refresh the browser.';
GO
SET NOEXEC OFF;
GO
