-- =====================================================================
-- 5. Risk Intelligence of one subject (CR2 5.3): a read / reference view
--    of existing GRAC records -- nothing is copied, no risk is created.
--    The subject's mapped practice instances / practices are its
--    Suggested and Confirmed mappings (each row says which).
--      1 risks        the subject's RISK mappings (Suggested / Confirmed):
--                     owner, category, inherent and residual ratings,
--                     appetite status and trend (the methodology, 574),
--                     treatment option, open treatment actions
--                     (fn_risk_treatment_roots, 389), acceptance, reviews
--      2 gaps         gaps of the mapped practice instances (source, or
--                     mapped with custom_gap_practice_map -- 388's rule)
--      3 exceptions   exceptions on those gaps or on the mapped practices
--      4 instances    the mapped practice instances with their
--                     implementation status, open gaps, obligations
--      5 findings     audit findings recorded against those practice
--                     instances in executions (execution entity)
--      6 summary      one row of counts
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_risk_intelligence
    @organization_id     BIGINT,
    @universe_subject_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                    WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id)
        THROW 54120, 'The subject was not found in this organization.', 1;

    DECLARE @inst TABLE(practice_instance_id BIGINT PRIMARY KEY, practice_id BIGINT, mapping_status NVARCHAR(20));
    INSERT INTO @inst (practice_instance_id, practice_id, mapping_status)
    SELECT pi.practice_instance_id, pi.practice_id, MAX(m.mapping_status)
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN grac_practice.practice_instance pi
           ON pi.practice_instance_id = TRY_CAST(m.record_key AS BIGINT) AND pi.organization_id = @organization_id
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = N'PRACTICE_INSTANCE'
       AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED')
     GROUP BY pi.practice_instance_id, pi.practice_id;

    DECLARE @prac TABLE(practice_id BIGINT PRIMARY KEY);
    INSERT INTO @prac (practice_id)
    SELECT DISTINCT x.practice_id
      FROM (SELECT TRY_CAST(m.record_key AS BIGINT) AS practice_id
              FROM grac_practice.org_assurance_universe_mapping m
             WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = N'PRACTICE'
               AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED')
            UNION
            SELECT practice_id FROM @inst) x
     WHERE x.practice_id IS NOT NULL;

    DECLARE @gap TABLE(custom_gap_id BIGINT PRIMARY KEY, practice_instance_id BIGINT);
    INSERT INTO @gap (custom_gap_id, practice_instance_id)
    SELECT g.custom_gap_id, MIN(i.practice_instance_id)
      FROM grac_practice.custom_gap g
      JOIN @inst i
           ON (g.source_reference_type = N'PracticeInstance' AND g.source_reference_id = i.practice_instance_id)
           OR EXISTS (SELECT 1
                        FROM grac_practice.custom_gap_practice_map gm
                        JOIN grac_practice.record_status_master rs
                          ON rs.record_status_id = gm.record_status_id AND rs.status_code = N'Active'
                       WHERE gm.custom_gap_id = g.custom_gap_id AND gm.practice_instance_id = i.practice_instance_id)
     WHERE g.organization_id = @organization_id
     GROUP BY g.custom_gap_id;

    DECLARE @risk TABLE(risk_register_id BIGINT PRIMARY KEY, mapping_status NVARCHAR(20), mapping_source NVARCHAR(10), basis NVARCHAR(400));
    INSERT INTO @risk (risk_register_id, mapping_status, mapping_source, basis)
    SELECT rr.risk_register_id, m.mapping_status, m.mapping_source, m.suggestion_basis
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN grac_practice.risk_register rr
           ON rr.risk_register_id = TRY_CAST(m.record_key AS BIGINT) AND rr.organization_id = @organization_id
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = N'RISK'
       AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED');

    -- 1 risks
    SELECT rr.risk_register_id AS RiskRegisterId, rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle,
           rr.risk_statement AS RiskStatement, rr.risk_category_name AS RiskCategoryName,
           ow.employee_name AS RiskOwnerName, rr.status_code AS StatusCode,
           rr.inherent_rating_name AS InherentRatingName, rr.inherent_rating_score AS InherentRatingScore,
           rr.residual_rating_name AS ResidualRatingName, rr.residual_rating_score AS ResidualRatingScore,
           ms.CurrentStage, ms.AppetiteStatus, ms.AppetiteMaxRatingCode, ms.Trend, ms.PreviousRatingCode,
           rr.treatment_option_name AS TreatmentOptionName,
           (SELECT COUNT(*) FROM grac_practice.fn_risk_treatment_roots(rr.risk_register_id) t
              JOIN grac_practice.vw_pm_practice_task v ON v.task_id = t.task_id
             WHERE v.closed_at IS NULL AND v.current_status_is_terminal = 0) AS OpenTreatmentActions,
           rr.accepted_dt AS AcceptedDt, rr.accepted_by_name AS AcceptedByName, rr.acceptance_note AS AcceptanceNote,
           rr.last_reviewed_dt AS LastReviewedDt, rr.next_review_date AS NextReviewDate,
           CAST(CASE WHEN rr.next_review_date IS NOT NULL AND rr.next_review_date < CAST(SYSUTCDATETIME() AS DATE)
                     THEN 1 ELSE 0 END AS BIT) AS ReviewOverdue,
           x.mapping_status AS MappingStatus, x.mapping_source AS MappingSource, x.basis AS SuggestionBasis
      FROM @risk x
      JOIN grac_practice.risk_register rr ON rr.risk_register_id = x.risk_register_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = rr.risk_owner_employee_id
      LEFT JOIN grac_practice.fn_risk_register_methodology_status(@organization_id) ms ON ms.RiskRegisterId = rr.risk_register_id
     ORDER BY CASE x.mapping_status WHEN N'CONFIRMED' THEN 0 ELSE 1 END,
              ISNULL(rr.residual_rating_score, rr.inherent_rating_score) DESC, rr.risk_register_id;

    -- 2 gaps
    SELECT g.custom_gap_id AS CustomGapId, g.gap_number AS GapNumber, g.title AS GapTitle,
           g.severity_name AS SeverityName, g.status AS Status, g.owner_display_name AS OwnerName,
           g.opened_dt AS OpenedDt, g.target_resolution_date AS TargetResolutionDate, g.closed_dt AS ClosedDt,
           CAST(CASE WHEN g.closed_dt IS NULL THEN 1 ELSE 0 END AS BIT) AS IsOpen,
           pi.instance_code AS InstanceCode, pi.instance_name AS InstanceName,
           rr.risk_number AS RiskNumber
      FROM @gap x
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = x.custom_gap_id
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
      LEFT JOIN grac_practice.risk_register rr ON rr.risk_register_id = g.risk_id
     ORDER BY CASE WHEN g.closed_dt IS NULL THEN 0 ELSE 1 END, g.opened_dt DESC, g.custom_gap_id DESC;

    -- 3 exceptions
    SELECT e.exception_request_id AS ExceptionRequestId, e.request_title AS RequestTitle, e.status_code AS StatusCode,
           e.requested_dt AS RequestedDt, e.approved_dt AS ApprovedDt, e.effective_until AS EffectiveUntil,
           g.gap_number AS GapNumber,
           STUFF((SELECT N', ' + ISNULL(ep.practice_code, ep.practice_name)
                    FROM grac_practice.exception_request_practice ep
                   WHERE ep.exception_request_id = e.exception_request_id
                   FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS Practices
      FROM grac_practice.exception_request e
      LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = e.custom_gap_id
     WHERE e.organization_id = @organization_id
       AND (e.custom_gap_id IN (SELECT custom_gap_id FROM @gap)
            OR EXISTS (SELECT 1 FROM grac_practice.exception_request_practice ep
                        WHERE ep.exception_request_id = e.exception_request_id
                          AND ep.practice_id IN (SELECT practice_id FROM @prac)))
     ORDER BY e.requested_dt DESC, e.exception_request_id DESC;

    -- 4 practice instances (assurance status)
    SELECT pi.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, pi.instance_name AS InstanceName,
           p.practice_code AS PracticeCode, p.practice_name AS PracticeName, pi.primary_owner AS PrimaryOwner,
           pi.implementation_status AS ImplementationStatus, x.mapping_status AS MappingStatus,
           (SELECT COUNT(*) FROM @gap gx JOIN grac_practice.custom_gap g ON g.custom_gap_id = gx.custom_gap_id
             WHERE gx.practice_instance_id = pi.practice_instance_id AND g.closed_dt IS NULL) AS OpenGaps,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_obligation o
             WHERE o.practice_instance_id = pi.practice_instance_id AND o.status = N'Active') AS Obligations
      FROM @inst x
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
      LEFT JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
     ORDER BY p.practice_code, pi.instance_code;

    -- 5 previous audit findings
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode,
           o.observation_title AS ObservationTitle, o.severity_name AS SeverityName, os.status_code AS StatusCode,
           o.execution_code AS ExecutionCode, o.execution_name AS ExecutionName, o.observed_dt AS ObservedDt,
           o.closed_dt AS ClosedDt, ee.entity_code AS InstanceCode, ee.entity_name AS InstanceName
      FROM grac_practice.org_assurance_observation o
      JOIN grac_practice.org_assurance_execution_entity ee
           ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
          AND ee.dimension_code = N'PRACTICE_INSTANCE'
      JOIN @inst x ON x.practice_instance_id = ee.entity_id
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
     WHERE o.organization_id = @organization_id AND o.is_active = 1
     ORDER BY o.observed_dt DESC, o.org_assurance_observation_id DESC;

    -- 6 summary
    SELECT (SELECT COUNT(*) FROM @risk WHERE mapping_status = N'CONFIRMED') AS ConfirmedRisks,
           (SELECT COUNT(*) FROM @risk WHERE mapping_status = N'SUGGESTED') AS SuggestedRisks,
           (SELECT COUNT(*) FROM @risk x
              JOIN grac_practice.fn_risk_register_methodology_status(@organization_id) ms ON ms.RiskRegisterId = x.risk_register_id
             WHERE ms.AppetiteStatus = N'Above') AS AboveAppetite,
           (SELECT COUNT(*) FROM @risk x JOIN grac_practice.risk_register rr ON rr.risk_register_id = x.risk_register_id
             WHERE rr.accepted_dt IS NOT NULL) AS AcceptedRisks,
           (SELECT COUNT(*) FROM @gap x JOIN grac_practice.custom_gap g ON g.custom_gap_id = x.custom_gap_id
             WHERE g.closed_dt IS NULL) AS OpenGaps,
           (SELECT COUNT(*) FROM @inst) AS PracticeInstances,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_observation o
              JOIN grac_practice.org_assurance_execution_entity ee
                   ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
                  AND ee.dimension_code = N'PRACTICE_INSTANCE'
              JOIN @inst x ON x.practice_instance_id = ee.entity_id
             WHERE o.organization_id = @organization_id AND o.is_active = 1) AS Findings;
END
GO

-- =====================================================================
-- 6. Menu: Audit Intelligence -> Risk Intelligence (40), the Audit Plans
--    permissions copied; also in 274's snapshot.
-- =====================================================================
DECLARE @intel_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-risk-intelligence', N'Risk Intelligence', N'Practice/org-audit-risk-intelligence', 40, N'shield-halved')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @intel_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-581', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @intel_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-581');
PRINT '581.6: org-audit-risk-intelligence menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-581', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key = N'org-audit-risk-intelligence'
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '581.6: org-audit-risk-intelligence permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_risk_register_methodology_status'), (N'sp_risk_methodology_register_summary'),
               (N'fn_org_assurance_universe_mapping_ref'), (N'sp_org_assurance_universe_mapping_list'),
               (N'sp_org_assurance_universe_mapping_options'), (N'sp_org_assurance_universe_mapping_suggest'),
               (N'sp_org_assurance_universe_mapping_add'), (N'sp_org_assurance_universe_risk_intelligence')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('581 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.menu_master WHERE menu_key = N'org-audit-risk-intelligence' AND status = N'Active') AS menu_rows;
PRINT '581 done: Audit Intelligence -- Enterprise Risk Intelligence (risk mapping, suggestions, intelligence view).';
GO
