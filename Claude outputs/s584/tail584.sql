
-- =====================================================================
-- 3. Gap detail: the audit source of a gap raised from audit findings
--    (CR2 8.2 -- read through the reference, nothing copied)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_audit_source
    @organization_id BIGINT,
    @custom_gap_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode,
           o.observation_title AS ObservationTitle, o.severity_name AS SeverityName, os.status_name AS ObservationStatus,
           i.engagement_code AS EngagementCode, ISNULL(i.engagement_name, i.definition_name) AS EngagementName,
           o.execution_code AS ExecutionCode, o.execution_name AS ExecutionName,
           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s.universe_ref + N' - ' + s.subject_name), N'; ')
              FROM grac_practice.fn_org_assurance_observation_subjects(@organization_id) x
              JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = x.universe_subject_id
             WHERE x.org_assurance_observation_id = o.org_assurance_observation_id) AS UniverseSubjects,
           o.entity_dimension_name AS EntityDimensionName, o.entity_code AS EntityCode, o.entity_name AS EntityName,
           o.audit_criteria AS AuditCriteria, o.condition_text AS ConditionText, o.root_cause AS RootCause,
           o.risk_impact AS RiskImpact, o.recommendation AS Recommendation, o.management_response AS ManagementResponse,
           o.supporting_evidence AS SupportingEvidence, o.observed_dt AS ObservedDt
      FROM grac_practice.custom_gap_observation j
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = j.custom_gap_id AND g.organization_id = @organization_id
      JOIN grac_practice.org_assurance_observation o ON o.org_assurance_observation_id = j.org_assurance_observation_id
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
      LEFT JOIN grac_practice.org_assurance_execution e ON e.org_assurance_execution_id = o.org_assurance_execution_id
      LEFT JOIN grac_practice.org_assurance_plan_item i ON i.org_assurance_plan_item_id = e.org_assurance_plan_item_id
     WHERE j.custom_gap_id = @custom_gap_id AND j.is_active = 1
     ORDER BY j.linked_dt, j.custom_gap_observation_id;
END
GO

-- =====================================================================
-- 4. Raise a Risk Candidate from an audit finding (CR2 9.2): Accepted,
--    not Informational; sp_risk_candidate_create (378) does the rest --
--    one open candidate per finding, numbering, history. The candidate
--    carries the finding's references and audit facts as its source
--    description (the finding stays in Audit Assurance).
--    Result: { RiskCandidateId, CandidateNumber, StatusCode, Created }.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_finding_raise_risk
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @employee_id     BIGINT        = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(60), @sev NVARCHAR(30), @sev_name NVARCHAR(120), @code NVARCHAR(120), @title NVARCHAR(300),
            @descr NVARCHAR(MAX), @impact NVARCHAR(MAX), @observed DATETIME2, @source NVARCHAR(MAX);
    SELECT @status = os.status_code, @sev = o.severity_code, @sev_name = o.severity_name,
           @code = ISNULL(o.observation_code, N'OBS-' + CAST(o.org_assurance_observation_id AS NVARCHAR(20))),
           @title = o.observation_title, @descr = o.observation_description, @impact = o.risk_impact, @observed = o.observed_dt,
           @source = CONCAT_WS(NCHAR(13) + NCHAR(10),
               N'Audit finding ' + ISNULL(o.observation_code, N'') + N': ' + ISNULL(o.observation_title, N''),
               N'Engagement: ' + NULLIF(ISNULL(i.engagement_code, N'') + N' ' + ISNULL(ISNULL(i.engagement_name, i.definition_name), N''), N' '),
               N'Execution: ' + NULLIF(ISNULL(o.execution_code, N'') + N' ' + ISNULL(o.execution_name, N''), N' '),
               N'Audit Universe subject(s): ' + (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s.universe_ref + N' - ' + s.subject_name), N'; ')
                                                   FROM grac_practice.fn_org_assurance_observation_subjects(@organization_id) x
                                                   JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = x.universe_subject_id
                                                  WHERE x.org_assurance_observation_id = o.org_assurance_observation_id),
               N'Practice / entity: ' + NULLIF(ISNULL(o.entity_dimension_name + N': ', N'') + ISNULL(o.entity_code + N' ', N'') + ISNULL(o.entity_name, N''), N''),
               N'Severity: ' + o.severity_name,
               N'Audit criteria: ' + o.audit_criteria,
               N'Observed condition: ' + o.condition_text,
               N'Root cause: ' + o.root_cause,
               N'Risk / impact: ' + o.risk_impact,
               N'Recommendation: ' + o.recommendation,
               N'Management response: ' + o.management_response,
               N'Evidence: ' + o.supporting_evidence)
      FROM grac_practice.org_assurance_observation o
      JOIN grac_practice.org_assurance_observation_status_master os
           ON os.org_assurance_observation_status_id = o.observation_status_id
      LEFT JOIN grac_practice.org_assurance_execution e ON e.org_assurance_execution_id = o.org_assurance_execution_id
      LEFT JOIN grac_practice.org_assurance_plan_item i ON i.org_assurance_plan_item_id = e.org_assurance_plan_item_id
     WHERE o.org_assurance_observation_id = @observation_id AND o.organization_id = @organization_id AND o.is_active = 1;
    IF @status IS NULL THROW 54170, 'The audit finding was not found in this organization.', 1;
    IF @status <> N'Accepted' THROW 54171, 'Only an Accepted audit finding can raise a Risk Candidate.', 1;
    IF @sev = N'Informational' THROW 54172, 'An Informational finding does not become a Risk Candidate.', 1;

    DECLARE @me NVARCHAR(100) = LEFT(ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                               WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor), 100);
    DECLARE @before BIGINT = (SELECT MAX(risk_candidate_id) FROM grac_practice.risk_candidate
                               WHERE organization_id = @organization_id AND source_type_code = N'Assurance'
                                 AND source_record_id = @observation_id);
    DECLARE @cand_title NVARCHAR(300) = LEFT(N'Audit finding: ' + ISNULL(@title, @code), 300);
    DECLARE @src_type NVARCHAR(40) = N'Assurance';
    EXEC grac_practice.sp_risk_candidate_create
         @candidate_title          = @cand_title,
         @candidate_summary        = @descr,
         @severity_code            = @sev,
         @severity_name            = @sev_name,
         @impact_summary           = @impact,
         @requested_by_employee_id = @employee_id,
         @caller_display_name      = @me,
         @organization_id          = @organization_id,
         @source_type_code         = @src_type,
         @source_record_id         = @observation_id,
         @source_reference         = @code,
         @source_description       = @source,
         @identified_dt            = @observed;

    SELECT TOP (1) c.risk_candidate_id AS RiskCandidateId, c.candidate_number AS CandidateNumber, c.status_code AS StatusCode,
           CAST(CASE WHEN c.risk_candidate_id > ISNULL(@before, 0) THEN 1 ELSE 0 END AS BIT) AS Created
      FROM grac_practice.risk_candidate c
     WHERE c.organization_id = @organization_id AND c.source_type_code = N'Assurance' AND c.source_record_id = @observation_id
     ORDER BY CASE WHEN c.status_code IN (N'Pending', N'UnderAnalysis', N'ClarificationRequired', N'AnalysisCompleted',
                                          N'Accepted', N'Registered') THEN 0 ELSE 1 END,
              c.risk_candidate_id DESC;
END
GO

-- =====================================================================
-- 5. Traceability (CR2 9.3): when Risk Management registers a candidate
--    raised from an audit finding, or closes it as a duplicate of an
--    existing risk, that risk is mapped (RISK) to the finding's Universe
--    subject(s) as CONFIRMED -- a Suggested mapping is confirmed, a
--    missing one added; a mapping the auditor Rejected or made Inactive is
--    left as the auditor set it. Risk Management's procedures are not
--    changed (CR2 9.7).
-- =====================================================================
CREATE OR ALTER TRIGGER grac_practice.trg_pm_risk_candidate_audit_subject_map
ON grac_practice.risk_candidate
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(registered_risk_id) OR UPDATE(duplicate_of_risk_id)) RETURN;

    DECLARE @m TABLE(org BIGINT, sid BIGINT, risk_id BIGINT, label NVARCHAR(600),
                     PRIMARY KEY (sid, risk_id));
    INSERT INTO @m (org, sid, risk_id, label)
    SELECT MIN(i.organization_id), s.universe_subject_id, COALESCE(i.registered_risk_id, i.duplicate_of_risk_id),
           MIN(LEFT(ISNULL(rr.risk_number, N'') + N' ' + ISNULL(rr.risk_title, N'') + N' -- risk candidate '
               + ISNULL(i.candidate_number, N'') + N' from audit finding ' + ISNULL(i.source_reference, N'')
               + CASE WHEN i.registered_risk_id IS NOT NULL THEN N' (registered)' ELSE N' (linked to the existing risk)' END, 600))
      FROM inserted i
      JOIN deleted d ON d.risk_candidate_id = i.risk_candidate_id
     CROSS APPLY grac_practice.fn_org_assurance_observation_subjects(i.organization_id) s
      LEFT JOIN grac_practice.risk_register rr ON rr.risk_register_id = COALESCE(i.registered_risk_id, i.duplicate_of_risk_id)
     WHERE i.source_type_code = N'Assurance'
       AND s.org_assurance_observation_id = i.source_record_id
       AND (   (i.registered_risk_id IS NOT NULL AND ISNULL(d.registered_risk_id, -1) <> i.registered_risk_id)
            OR (i.registered_risk_id IS NULL AND i.duplicate_of_risk_id IS NOT NULL
                AND ISNULL(d.duplicate_of_risk_id, -1) <> i.duplicate_of_risk_id))
     GROUP BY s.universe_subject_id, COALESCE(i.registered_risk_id, i.duplicate_of_risk_id);
    IF NOT EXISTS (SELECT 1 FROM @m) RETURN;

    DECLARE @done TABLE(org BIGINT, sid BIGINT, label NVARCHAR(600));
    UPDATE mp
       SET mapping_status = N'CONFIRMED', confirmed_by = N'Risk Management', confirmed_dt = SYSUTCDATETIME(),
           remarks = LEFT(m.label, 1000), updated_by = N'trg-584', updated_dt = SYSUTCDATETIME()
    OUTPUT m.org, m.sid, m.label INTO @done (org, sid, label)
      FROM grac_practice.org_assurance_universe_mapping mp
      JOIN @m m ON mp.universe_subject_id = m.sid AND mp.mapping_level = N'RISK' AND mp.record_key = CAST(m.risk_id AS NVARCHAR(80))
     WHERE mp.mapping_status = N'SUGGESTED';

    INSERT INTO grac_practice.org_assurance_universe_mapping
        (organization_id, universe_subject_id, mapping_level, record_key, mapping_source, mapping_status,
         suggestion_basis, confirmed_by, confirmed_dt, remarks, entered_by)
    OUTPUT inserted.organization_id, inserted.universe_subject_id, inserted.remarks INTO @done (org, sid, label)
    SELECT m.org, m.sid, N'RISK', CAST(m.risk_id AS NVARCHAR(80)), N'AUTO', N'CONFIRMED',
           N'Risk Management decision on a risk candidate from an audit finding', N'Risk Management', SYSUTCDATETIME(),
           LEFT(m.label, 1000), N'trg-584'
      FROM @m m
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping mp
                        WHERE mp.universe_subject_id = m.sid AND mp.mapping_level = N'RISK'
                          AND mp.record_key = CAST(m.risk_id AS NVARCHAR(80)));

    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, comment, actor_name)
    SELECT org, sid, N'MAP_ADD', LEFT(N'Mapped (RISK): ' + label, 4000), N'Risk Management'
      FROM @done;
END
GO

-- =====================================================================
-- 6. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_observation_subjects'), (N'sp_custom_gap_generate_from_assurance_observation'),
               (N'sp_custom_gap_audit_source'), (N'sp_org_assurance_finding_raise_risk'),
               (N'trg_pm_risk_candidate_audit_subject_map')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('584 verification: missing objects: %s', 16, 1, @missing);
PRINT '584 done: Audit Intelligence -- audit findings to Gap and Risk candidates (traceability to the Audit Universe).';
GO
