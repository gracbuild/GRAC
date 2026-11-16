-- =====================================================================
-- 523_tpm_cr2_screening_admission_rollback.sql
--
-- Reverses 523_tpm_cr2_screening_admission.sql:
--   * The procedure bodies 523 re-issued are restored verbatim
--     (sp_tprm_engagement_discover from 521; sp_tprm_engagement_exposure_save,
--     sp_tprm_engagement_get, sp_tprm_risk_assessment_start,
--     sp_tprm_sample_load from 522;
--     sp_tprm_engagement_list from 488).
--   * The screening, applicability and admission procedures are dropped,
--     and their tables (tprm_admission_approval, tprm_admission,
--     tprm_applicability_decision, tprm_screening_observation,
--     tprm_screening_report) are dropped WITH their data, as are the
--     engagement columns applicability_status, current_screening_report_id
--     and admitted_dt.
--   * The list SCREENING_INDICATOR is removed (baseline values,
--     organization values and overrides).
-- Deploy the previous API / Web build first. Run AFTER the 524 rollback
-- (refuses while 524 is installed) and BEFORE the 522 rollback.
-- Generated from the 521 / 522 / 488 sources. ASCII-only. SAFE TO RE-RUN.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.tprm_third_party','U') IS NULL
BEGIN
    PRINT '523 rollback: TPRM is not installed -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- 524 builds on 523 (it re-issues sp_tprm_admission_act and
-- sp_tprm_engagement_get): roll 524 back first.
IF OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NOT NULL
BEGIN
    PRINT '523 rollback ABORTED: 524 is installed. Run 524_tpm_cr2_risk_register_rollback.sql first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Procedures as they were before 523
-- =====================================================================

-- restored from 521
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_discover
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @persist           BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tp BIGINT, @stage NVARCHAR(30), @contract_id BIGINT;
    SELECT @tp = third_party_id, @stage = stage_code, @contract_id = contract_id FROM grac_practice.tprm_engagement
     WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @tp IS NULL THROW 57630, 'That engagement was not found.', 1;

    DECLARE @app_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Application');

    -- applications in scope (proposed or actual) or linked
    DECLARE @apps TABLE (application_id BIGINT PRIMARY KEY, application_name NVARCHAR(220));
    INSERT @apps
    SELECT a.application_id, a.application_name
    FROM   grac_practice.organization_dependency_application a
    WHERE  a.organization_id = @organization_id AND a.status = N'Active'
      AND  (   EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                        WHERE s.engagement_id = @engagement_id AND s.item_kind = N'APPLICATION'
                          AND s.status = N'Active' AND s.ref_id = a.application_id)
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l
                        WHERE l.engagement_id = @engagement_id AND l.link_kind = N'APPLICATION'
                          AND l.status = N'Active' AND l.target_id = a.application_id));

    -- instances that depend on those applications
    DECLARE @pi TABLE (practice_instance_id BIGINT PRIMARY KEY, via NVARCHAR(20), resolution_id BIGINT);
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT r.practice_instance_id, N'APPLICATION', MIN(r.resolution_id)
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1
    GROUP  BY r.practice_instance_id;

    DECLARE @counts TABLE (k NVARCHAR(40), n INT);

    -- 2 practice instances
    SELECT pi.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, pi.instance_name AS InstanceName,
           p.practice_id AS PracticeId, p.practice_code AS PracticeCode, p.practice_name AS PracticeName,
           pi.criticality AS Criticality, pi.implementation_status AS ImplementationStatus, pi.status AS Status,
           x.via AS Via, x.resolution_id AS ResolutionId,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = pi.practice_instance_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #instances
    FROM   @pi x
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id;
    INSERT @counts SELECT N'PracticeInstances', COUNT(*) FROM #instances;
    INSERT @counts SELECT N'Practices', COUNT(DISTINCT PracticeId) FROM #instances;

    -- 3 obligations (instance obligations + practice-level obligations)
    SELECT N'INSTANCE' AS Level, pio.practice_instance_obligation_id AS ObligationRowId, pio.practice_instance_id AS PracticeInstanceId,
           i.InstanceCode, pio.obligation_name AS ObligationName, pio.obligation_type_code AS ObligationTypeCode,
           pio.execution_frequency AS ExecutionFrequency, pio.responsibility AS Responsibility
    INTO   #obligations
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   #instances i ON i.PracticeInstanceId = pio.practice_instance_id
    WHERE  pio.status = N'Active'
    UNION ALL
    SELECT N'PRACTICE', po.practice_obligation_id, NULL, NULL, po.obligation_name, po.obligation_type_code,
           po.execution_frequency, po.responsibility
    FROM   grac_practice.practice_obligation po
    WHERE  po.organization_id = @organization_id AND po.status = N'Active'
      AND  po.practice_id IN (SELECT DISTINCT PracticeId FROM #instances);
    INSERT @counts SELECT N'Obligations', COUNT(*) FROM #obligations;

    -- 4 dependencies: the application resolutions, and the applications
    SELECT N'APPLICATION_RESOLUTION' AS DependencyKind, r.resolution_id AS DependencyId, r.resolved_dependency_name AS DependencyName,
           r.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, r.resolution_status AS ResolutionStatus
    INTO   #deps
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1
    UNION ALL
    SELECT N'APPLICATION', a.application_id, a.application_name, NULL, NULL, NULL
    FROM   @apps a;
    INSERT @counts SELECT N'Dependencies', COUNT(*) FROM #deps;

    -- 5 assurance findings on the instances
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode, o.observation_title AS ObservationTitle,
           o.observation_type AS ObservationType, o.severity_code AS SeverityCode, o.severity_name AS SeverityName,
           sm.status_name AS StatusName, sm.is_terminal AS IsClosed, o.observed_dt AS ObservedDt,
           ee.dimension_code AS DimensionCode, ee.entity_name AS EntityName, o.execution_code AS ExecutionCode
    INTO   #findings
    FROM   grac_practice.org_assurance_observation o
    JOIN   grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT   JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE  o.organization_id = @organization_id
      AND  ee.dimension_code = N'PRACTICE_INSTANCE'
      AND  ee.entity_id IN (SELECT PracticeInstanceId FROM #instances);
    INSERT @counts SELECT N'AssuranceFindings', COUNT(*) FROM #findings;
    INSERT @counts SELECT N'OpenAssuranceFindings', COUNT(*) FROM #findings WHERE ISNULL(IsClosed, 0) = 0;

    -- 6 gaps of the instances
    SELECT g.practice_gap_id AS PracticeGapId, g.practice_instance_id AS PracticeInstanceId, i.InstanceCode, i.InstanceName,
           g.gap_status AS GapStatus, g.opened_dt AS OpenedDt, g.closed_dt AS ClosedDt
    INTO   #gaps
    FROM   grac_practice.practice_gap g
    JOIN   #instances i ON i.PracticeInstanceId = g.practice_instance_id;
    INSERT @counts SELECT N'OpenGaps', COUNT(*) FROM #gaps WHERE GapStatus = N'Open';

    -- 7 enterprise risks on the practices of those instances
    SELECT rr.risk_register_id AS RiskRegisterId, rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle,
           rr.status_code AS StatusCode, rr.inherent_rating_name AS InherentRating,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = rr.risk_register_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #risks
    FROM   grac_practice.risk_register rr
    WHERE  rr.organization_id = @organization_id
      AND  rr.linked_practice_id IN (SELECT DISTINCT PracticeId FROM #instances);
    INSERT @counts SELECT N'Risks', COUNT(*) FROM #risks;

    -- 8 the engagement's contract (Asset & Contract, when present)
    CREATE TABLE #contracts (ContractId BIGINT, ContractNumber NVARCHAR(60), ContractName NVARCHAR(250), ContractStatus NVARCHAR(20));
    IF @contract_id IS NOT NULL AND OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        INSERT #contracts
        EXEC sp_executesql N'SELECT c.contract_id, c.contract_number, c.contract_name, c.contract_status
                             FROM grac_practice.asset_contract c
                             WHERE c.organization_id = @o AND c.contract_id = @c;',
             N'@o BIGINT, @c BIGINT', @o = @organization_id, @c = @contract_id;
    INSERT @counts SELECT N'Contracts', COUNT(*) FROM #contracts;
    INSERT @counts SELECT N'Applications', COUNT(*) FROM @apps;

    IF ISNULL(@persist, 0) = 1
    BEGIN
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
        BEGIN TRAN;
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'PRACTICE_INSTANCE', i.PracticeInstanceId,
               LEFT(CONCAT(i.InstanceCode, N' - ', i.InstanceName, N' (', i.PracticeName, N')'), 400), N'DISCOVERED', @actor
        FROM #instances i
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = i.PracticeInstanceId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'DEPENDENCY', d.DependencyId,
               LEFT(CONCAT(d.InstanceCode, N' depends on ', d.DependencyName), 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'APPLICATION_RESOLUTION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'DEPENDENCY' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'APPLICATION', d.DependencyId, LEFT(d.DependencyName, 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'APPLICATION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'APPLICATION' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'CONTRACT', c.ContractId, LEFT(CONCAT(c.ContractNumber, N' - ', c.ContractName), 400), N'DISCOVERED', @actor
        FROM #contracts c
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'CONTRACT' AND l.target_id = c.ContractId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'ENTERPRISE_RISK', r.RiskRegisterId, LEFT(CONCAT(r.RiskNumber, N' - ', r.RiskTitle), 400), N'DISCOVERED', @actor
        FROM #risks r
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = r.RiskRegisterId AND l.status = N'Active');

        INSERT grac_practice.tprm_exposure_snapshot (engagement_id, organization_id, snapshot_kind, summary_json, items_json, taken_by)
        VALUES (@engagement_id, @organization_id, N'DISCOVERED',
                (SELECT k AS [key], n AS [count] FROM @counts FOR JSON PATH),
                (SELECT (SELECT PracticeInstanceId AS id, InstanceCode AS code, InstanceName AS name, PracticeName AS practice FROM #instances FOR JSON PATH) AS instances,
                        (SELECT DependencyKind AS kind, DependencyId AS id, DependencyName AS name FROM #deps FOR JSON PATH) AS dependencies,
                        (SELECT ContractId AS id, ContractNumber AS code FROM #contracts FOR JSON PATH) AS contracts,
                        (SELECT RiskRegisterId AS id, RiskNumber AS code FROM #risks FOR JSON PATH) AS risks
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                @actor);
        COMMIT;
        DECLARE @ddetail NVARCHAR(2000) = (SELECT STRING_AGG(CONCAT(k, N' ', n), N', ') FROM @counts);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'DISCOVERY_RECORDED', @stage, @stage, @ddetail, @actor_employee_id, @actor;
    END

    SELECT k AS CountKey, n AS CountValue FROM @counts;
    SELECT * FROM #instances ORDER BY InstanceCode;
    SELECT * FROM #obligations ORDER BY Level, ObligationName;
    SELECT * FROM #deps ORDER BY DependencyKind, DependencyName;
    SELECT * FROM #findings ORDER BY ISNULL(IsClosed, 0), ObservedDt DESC;
    SELECT * FROM #gaps ORDER BY GapStatus DESC, OpenedDt DESC;
    SELECT * FROM #risks ORDER BY RiskNumber;
    SELECT * FROM #contracts ORDER BY ContractNumber;
END
GO

-- restored from 522
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_exposure_save
    @organization_id           BIGINT,
    @engagement_id             BIGINT,
    @app_access_answer         NVARCHAR(10)   = NULL,
    @premises_access_answer    NVARCHAR(10)   = NULL,
    @data_processing_answer    NVARCHAR(10)   = NULL,
    @subcontracting_answer     NVARCHAR(10)   = NULL,
    @important_process_answer  NVARCHAR(10)   = NULL,
    @disruption_impact_answer  NVARCHAR(10)   = NULL,
    @service_commitment_answer NVARCHAR(10)   = NULL,
    @contract_answer           NVARCHAR(10)   = NULL,
    @service_criticality_code  NVARCHAR(60)   = NULL,
    @data_processing_details   NVARCHAR(2000) = NULL,
    @customer_impact_code      NVARCHAR(60)   = NULL,
    @substitutability_code     NVARCHAR(60)   = NULL,
    @exit_dependencies         NVARCHAR(2000) = NULL,
    @sla_summary               NVARCHAR(2000) = NULL,
    @rto_hours                 INT            = NULL,
    @rpo_hours                 INT            = NULL,
    @contract_id               BIGINT         = NULL,
    @contract_reference        NVARCHAR(200)  = NULL,
    @contract_value            DECIMAL(19,2)  = NULL,
    @currency_code             NVARCHAR(10)   = NULL,
    @contract_start_dt         DATE           = NULL,
    @contract_end_dt           DATE           = NULL,
    @renewal_dt                DATE           = NULL,
    @contract_documents        NVARCHAR(1000) = NULL,
    @scope_json                NVARCHAR(MAX)  = NULL,
    @expected_record_version   BIGINT         = NULL,
    @actor_employee_id         BIGINT         = NULL,
    @actor                     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rv BIGINT, @stage NVARCHAR(30), @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_sub NVARCHAR(60), @o_cust NVARCHAR(60);
    SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code,
           @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_sub = substitutability_code, @o_cust = customer_impact_code
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @rv IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 57639, 'Someone else changed this engagement. Reload and try again.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    SELECT @app_access_answer         = UPPER(NULLIF(LTRIM(RTRIM(@app_access_answer)), N'')),
           @premises_access_answer    = UPPER(NULLIF(LTRIM(RTRIM(@premises_access_answer)), N'')),
           @data_processing_answer    = UPPER(NULLIF(LTRIM(RTRIM(@data_processing_answer)), N'')),
           @subcontracting_answer     = UPPER(NULLIF(LTRIM(RTRIM(@subcontracting_answer)), N'')),
           @important_process_answer  = UPPER(NULLIF(LTRIM(RTRIM(@important_process_answer)), N'')),
           @disruption_impact_answer  = UPPER(NULLIF(LTRIM(RTRIM(@disruption_impact_answer)), N'')),
           @service_commitment_answer = UPPER(NULLIF(LTRIM(RTRIM(@service_commitment_answer)), N'')),
           @contract_answer           = UPPER(NULLIF(LTRIM(RTRIM(@contract_answer)), N''));
    IF EXISTS (SELECT 1 FROM (VALUES (@app_access_answer), (@premises_access_answer), (@data_processing_answer),
                                     (@subcontracting_answer), (@important_process_answer), (@disruption_impact_answer),
                                     (@service_commitment_answer), (@contract_answer)) x(answer)
                WHERE x.answer IS NOT NULL AND x.answer NOT IN (N'YES', N'NO', N'UNKNOWN'))
        THROW 58063, 'Answer each question Yes, No or Not sure.', 1;
    SET @service_criticality_code = NULLIF(LTRIM(RTRIM(@service_criticality_code)), N'');
    IF @service_criticality_code IS NULL THROW 58070, 'Choose the service criticality.', 1;

    -- Only the dimensions that apply are kept (CR 2 5.2: "the system must
    -- not force users to populate every exposure dimension").
    SELECT @data_processing_details = NULLIF(LTRIM(RTRIM(@data_processing_details)), N''),
           @customer_impact_code = NULLIF(LTRIM(RTRIM(@customer_impact_code)), N''),
           @substitutability_code = NULLIF(LTRIM(RTRIM(@substitutability_code)), N''),
           @exit_dependencies = NULLIF(LTRIM(RTRIM(@exit_dependencies)), N''),
           @sla_summary = NULLIF(LTRIM(RTRIM(@sla_summary)), N''),
           @contract_reference = NULLIF(LTRIM(RTRIM(@contract_reference)), N''),
           @currency_code = NULLIF(LTRIM(RTRIM(@currency_code)), N''),
           @contract_documents = NULLIF(LTRIM(RTRIM(@contract_documents)), N'');
    IF ISNULL(@data_processing_answer, N'') <> N'YES' SET @data_processing_details = NULL;
    IF ISNULL(@disruption_impact_answer, N'') <> N'YES'
        SELECT @customer_impact_code = NULL, @substitutability_code = NULL, @exit_dependencies = NULL;
    IF ISNULL(@service_commitment_answer, N'') <> N'YES'
        SELECT @sla_summary = NULL, @rto_hours = NULL, @rpo_hours = NULL;
    IF ISNULL(@contract_answer, N'') <> N'YES'
        SELECT @contract_id = NULL, @contract_reference = NULL, @contract_value = NULL, @currency_code = NULL,
               @contract_start_dt = NULL, @contract_end_dt = NULL, @renewal_dt = NULL, @contract_documents = NULL;

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'CRITICALITY',      @service_criticality_code, N'service criticality'),
        (N'CUSTOMER_IMPACT',  @customer_impact_code,     N'customer impact'),
        (N'SUBSTITUTABILITY', @substitutability_code,    N'substitutability')) x(list_code, code, what)
    WHERE x.code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                       WHERE r.list_code = x.list_code AND r.value_code = x.code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @bad_msg NVARCHAR(300) = CONCAT(N'Choose a ', @bad, N' from the list.');
        THROW 57633, @bad_msg, 1;
    END
    IF (@rto_hours IS NOT NULL AND @rto_hours < 0) OR (@rpo_hours IS NOT NULL AND @rpo_hours < 0)
        THROW 57637, 'RTO and RPO cannot be negative.', 1;
    IF @contract_end_dt IS NOT NULL AND @contract_start_dt IS NOT NULL AND @contract_end_dt < @contract_start_dt
        THROW 58069, 'The contract end date is before its start date.', 1;
    IF @contract_id IS NOT NULL
    BEGIN
        IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL THROW 57638, 'Contracts are not available in this installation.', 1;
        DECLARE @contract_ok INT;
        EXEC sp_executesql N'SELECT @n = COUNT(*) FROM grac_practice.asset_contract WHERE contract_id = @c AND organization_id = @o;',
             N'@n INT OUTPUT, @c BIGINT, @o BIGINT', @n = @contract_ok OUTPUT, @c = @contract_id, @o = @organization_id;
        IF ISNULL(@contract_ok, 0) = 0 THROW 57638, 'That contract was not found in this organization.', 1;
    END

    -- ---- the proposed scope items, as one set
    IF @scope_json IS NOT NULL AND ISJSON(@scope_json) <> 1 THROW 58064, 'The scope items are not valid.', 1;
    DECLARE @in TABLE (row_no INT IDENTITY(1,1) PRIMARY KEY, item_kind NVARCHAR(30), ref_id BIGINT, item_code NVARCHAR(60),
                       item_name NVARCHAR(300), country NVARCHAR(120), item_key NVARCHAR(500));
    INSERT @in (item_kind, ref_id, item_code, item_name, country)
    SELECT UPPER(NULLIF(LTRIM(RTRIM(j.kind)), N'')), j.refId, NULLIF(LTRIM(RTRIM(j.itemCode)), N''),
           NULLIF(LTRIM(RTRIM(j.itemName)), N''), NULLIF(LTRIM(RTRIM(j.country)), N'')
    FROM OPENJSON(ISNULL(@scope_json, N'[]'))
         WITH (kind NVARCHAR(30) '$.kind', refId BIGINT '$.refId', itemCode NVARCHAR(60) '$.itemCode',
               itemName NVARCHAR(300) '$.itemName', country NVARCHAR(120) '$.country') j;
    IF EXISTS (SELECT 1 FROM @in WHERE item_kind IS NULL OR item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION',
                                                                              N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY'))
        THROW 58065, 'Unknown scope item type.', 1;
    -- a dimension that does not apply keeps no items
    DELETE FROM @in
    WHERE (item_kind = N'APPLICATION' AND ISNULL(@app_access_answer, N'') <> N'YES')
       OR (item_kind = N'ACCESS' AND ISNULL(@app_access_answer, N'') <> N'YES' AND ISNULL(@premises_access_answer, N'') <> N'YES')
       OR (item_kind = N'DATA_CATEGORY' AND ISNULL(@data_processing_answer, N'') <> N'YES')
       OR (item_kind = N'FOURTH_PARTY' AND ISNULL(@subcontracting_answer, N'') <> N'YES')
       OR (item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS') AND ISNULL(@important_process_answer, N'') <> N'YES');
    UPDATE @in SET ref_id = NULL WHERE item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION');
    -- GRAC records are picked, not typed: the name comes from the record.
    IF EXISTS (SELECT 1 FROM @in i WHERE i.ref_id IS NOT NULL
                 AND NOT ((i.item_kind = N'BUSINESS_FUNCTION' AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function f
                                                                           WHERE f.business_function_id = i.ref_id AND f.organization_id = @organization_id))
                       OR (i.item_kind = N'PROCESS' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process p
                                                                 WHERE p.process_id = i.ref_id AND p.organization_id = @organization_id))
                       OR (i.item_kind = N'APPLICATION' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_application a
                                                                     WHERE a.application_id = i.ref_id AND a.organization_id = @organization_id))))
        THROW 58066, 'A GRAC record in the scope was not found in this organization.', 1;
    UPDATE i SET item_name = f.function_name FROM @in i
    JOIN grac_practice.organization_business_function f ON f.business_function_id = i.ref_id
    WHERE i.item_kind = N'BUSINESS_FUNCTION';
    UPDATE i SET item_name = p.process_name FROM @in i
    JOIN grac_practice.organization_dependency_process p ON p.process_id = i.ref_id
    WHERE i.item_kind = N'PROCESS';
    UPDATE i SET item_name = a.application_name FROM @in i
    JOIN grac_practice.organization_dependency_application a ON a.application_id = i.ref_id
    WHERE i.item_kind = N'APPLICATION';
    -- list values: the code must be in force; the name is its label
    DECLARE @lv TABLE (list_code NVARCHAR(60), value_code NVARCHAR(60), label NVARCHAR(200), rank_no INT, display_order INT);
    INSERT @lv (list_code, value_code, label, rank_no, display_order)
    SELECT r.list_code, r.value_code, r.label, r.rank_no, r.display_order
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
    WHERE r.list_code IN (N'DATA_EXPOSURE', N'ACCESS_CATEGORY', N'FOURTH_PARTY_CATEGORY');
    -- A value no longer in force (retired / hidden) that this engagement
    -- already records stays valid, so a save never drops it silently.
    DECLARE @kept TABLE (item_kind NVARCHAR(30), item_code NVARCHAR(60), item_name NVARCHAR(300));
    INSERT @kept (item_kind, item_code, item_name)
    SELECT s.item_kind, s.item_code, MAX(s.item_name) FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active' AND s.item_code IS NOT NULL
    GROUP BY s.item_kind, s.item_code;
    IF EXISTS (SELECT 1 FROM @in i
                WHERE (i.item_kind IN (N'DATA_CATEGORY', N'ACCESS')
                       AND (i.item_code IS NULL
                            OR (NOT EXISTS (SELECT 1 FROM @lv l
                                             WHERE l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
                                               AND l.value_code = i.item_code)
                                AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = i.item_kind AND k.item_code = i.item_code))))
                   OR (i.item_kind = N'FOURTH_PARTY' AND i.item_code IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM @lv l WHERE l.list_code = N'FOURTH_PARTY_CATEGORY' AND l.value_code = i.item_code)
                       AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = N'FOURTH_PARTY' AND k.item_code = i.item_code)))
        THROW 58067, 'Choose the scope values from the lists.', 1;
    UPDATE i SET item_name = k.item_name FROM @in i
    JOIN @kept k ON k.item_kind = i.item_kind AND k.item_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE i SET item_name = l.label FROM @in i
    JOIN @lv l ON l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
              AND l.value_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE @in SET item_code = NULL WHERE item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'LOCATION');
    UPDATE @in SET country = NULL WHERE item_kind NOT IN (N'LOCATION', N'FOURTH_PARTY');
    IF EXISTS (SELECT 1 FROM @in WHERE item_name IS NULL) THROW 58068, 'Every scope item needs a name.', 1;
    UPDATE @in SET item_key = grac_practice.fn_tprm_scope_item_key(item_kind, ref_id, item_code, item_name, country);
    DELETE i FROM @in i WHERE EXISTS (SELECT 1 FROM @in d WHERE d.item_key = i.item_key AND d.row_no < i.row_no);

    -- the derived data exposure
    DECLARE @data_code NVARCHAR(60) = NULL;
    IF @data_processing_answer = N'YES'
        SELECT TOP (1) @data_code = i.item_code
        FROM @in i LEFT JOIN @lv l ON l.list_code = N'DATA_EXPOSURE' AND l.value_code = i.item_code
        WHERE i.item_kind = N'DATA_CATEGORY'
        ORDER BY ISNULL(l.rank_no, 0) DESC, ISNULL(l.display_order, 9999);
    ELSE IF @data_processing_answer = N'NO'
        SELECT TOP (1) @data_code = l.value_code FROM @lv l
        WHERE l.list_code = N'DATA_EXPOSURE' AND l.rank_no = 0
        ORDER BY l.display_order;

    DECLARE @added INT = 0, @removed INT = 0, @flagged BIT = 0;
    BEGIN TRAN;
    UPDATE grac_practice.tprm_engagement
       SET app_access_answer = @app_access_answer, premises_access_answer = @premises_access_answer,
           data_processing_answer = @data_processing_answer, subcontracting_answer = @subcontracting_answer,
           important_process_answer = @important_process_answer, disruption_impact_answer = @disruption_impact_answer,
           service_commitment_answer = @service_commitment_answer, contract_answer = @contract_answer,
           service_criticality_code = @service_criticality_code, data_exposure_code = @data_code,
           data_processing_details = @data_processing_details,
           customer_impact_code = @customer_impact_code, substitutability_code = @substitutability_code,
           exit_dependencies = @exit_dependencies,
           sla_summary = @sla_summary, rto_hours = @rto_hours, rpo_hours = @rpo_hours,
           contract_id = @contract_id, contract_reference = @contract_reference, contract_value = @contract_value,
           currency_code = @currency_code, contract_start_dt = @contract_start_dt, contract_end_dt = @contract_end_dt,
           renewal_dt = @renewal_dt, contract_documents = @contract_documents,
           exposure_saved_dt = SYSUTCDATETIME(), exposure_saved_by = @actor,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE engagement_id = @engagement_id;

    -- items no longer listed
    UPDATE s SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND NOT EXISTS (SELECT 1 FROM @in i
                       WHERE i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country));
    SET @removed = @@ROWCOUNT;
    -- items kept: the name and the fourth-party category follow the page
    UPDATE s SET item_name = i.item_name,
                 item_code = CASE WHEN s.item_kind = N'FOURTH_PARTY' THEN i.item_code ELSE s.item_code END,
                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    JOIN @in i ON i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country)
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND (s.item_name <> i.item_name
           OR (s.item_kind = N'FOURTH_PARTY' AND ISNULL(s.item_code, N'') <> ISNULL(i.item_code, N'')));
    -- new items
    INSERT grac_practice.tprm_engagement_scope
        (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, country, entered_by)
    SELECT @engagement_id, @organization_id, i.item_kind, N'PROPOSED', i.ref_id, i.item_code, i.item_name, i.country, @actor
    FROM @in i
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                       WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
                         AND grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country) = i.item_key);
    SET @added = @@ROWCOUNT;

    DECLARE @material NVARCHAR(1000) = NULLIF(CONCAT_WS(N'; ',
        CASE WHEN ISNULL(@o_crit, N'') <> ISNULL(@service_criticality_code, N'') THEN CONCAT(N'criticality ', @o_crit, N' -> ', @service_criticality_code) END,
        CASE WHEN ISNULL(@o_data, N'') <> ISNULL(@data_code, N'') THEN CONCAT(N'data exposure ', @o_data, N' -> ', @data_code) END,
        CASE WHEN ISNULL(@o_cust, N'') <> ISNULL(@customer_impact_code, N'') THEN CONCAT(N'customer impact ', @o_cust, N' -> ', @customer_impact_code) END,
        CASE WHEN ISNULL(@o_sub, N'') <> ISNULL(@substitutability_code, N'') THEN CONCAT(N'substitutability ', @o_sub, N' -> ', @substitutability_code) END), N'');
    EXEC grac_practice.sp_tprm_engagement_flag_material @engagement_id, @stage, @material, @actor_employee_id, @actor, @flagged OUTPUT;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Scope & exposure saved: ', @added, N' proposed item(s) added, ', @removed, N' removed.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'EXPOSURE_SAVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;

    SELECT @engagement_id AS EngagementId, CASE WHEN @flagged = 1 THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- restored from 522
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_get
    @organization_id BIGINT,
    @engagement_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57630, 'That engagement was not found.', 1;

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           t.lifecycle_status_code AS ThirdPartyStatusCode, ts.label AS ThirdPartyStatus,
           grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) AS ThirdPartyStatusMeaning,
           e.service_description AS ServiceDescription, e.scope_description AS ScopeDescription, e.business_purpose AS BusinessPurpose,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.engagement_type_code AS EngagementTypeCode, et.label AS EngagementType,
           e.service_model_code AS ServiceModelCode, sm.label AS ServiceModel,
           e.delivery_locations AS DeliveryLocations, e.is_existing AS IsExisting,
           e.contract_id AS ContractId, e.contract_reference AS ContractReference, e.contract_value AS ContractValue,
           e.currency_code AS CurrencyCode, e.contract_start_dt AS ContractStartDt, e.contract_end_dt AS ContractEndDt,
           e.contract_documents AS ContractDocuments,
           e.proposed_start_dt AS ProposedStartDt, e.proposed_end_dt AS ProposedEndDt,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.renewal_dt AS RenewalDt,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           e.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.data_exposure_code AS DataExposureCode, de.label AS DataExposure, e.data_processing_details AS DataProcessingDetails,
           e.rto_hours AS RtoHours, e.rpo_hours AS RpoHours, e.sla_summary AS SlaSummary,
           e.service_recipient AS ServiceRecipient, e.substitutability_code AS SubstitutabilityCode, sb.label AS Substitutability,
           e.customer_impact_code AS CustomerImpactCode, ci.label AS CustomerImpact, e.exit_dependencies AS ExitDependencies,
           e.app_access_answer AS AppAccessAnswer, e.premises_access_answer AS PremisesAccessAnswer,
           e.data_processing_answer AS DataProcessingAnswer, e.subcontracting_answer AS SubcontractingAnswer,
           e.important_process_answer AS ImportantProcessAnswer, e.disruption_impact_answer AS DisruptionImpactAnswer,
           e.service_commitment_answer AS ServiceCommitmentAnswer, e.contract_answer AS ContractAnswer,
           e.exposure_saved_dt AS ExposureSavedDt, e.exposure_saved_by AS ExposureSavedBy,
           e.stage_code AS StageCode, e.stage_dt AS StageDt,
           e.current_risk_assessment_id AS CurrentRiskAssessmentId, e.risk_model_version_id AS RiskModelVersionId,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.dd_tier_code AS DdTierCode, dt.label AS DdTier,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.acceptance_until AS AcceptanceUntil, e.next_review_dt AS NextReviewDt, e.last_review_dt AS LastReviewDt,
           e.reassessment_required AS ReassessmentRequired, e.reassessment_reason AS ReassessmentReason,
           e.notes AS Notes, e.is_sample AS IsSample, CONVERT(BIGINT, e.record_version) AS RecordVersion,
           (SELECT TOP (1) a.assessment_id FROM grac_practice.tprm_risk_assessment a
             WHERE a.engagement_id = e.engagement_id AND a.status = N'DRAFT') AS DraftRiskAssessmentId,
           e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt, e.updated_by AS UpdatedBy, e.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref ts ON ts.list_code = N'TP_STATUS' AND ts.value_code = t.lifecycle_status_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref et ON et.list_code = N'ENGAGEMENT_TYPE' AND et.value_code = e.engagement_type_code
    LEFT   JOIN ref sm ON sm.list_code = N'SERVICE_MODEL' AND sm.value_code = e.service_model_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref de ON de.list_code = N'DATA_EXPOSURE' AND de.value_code = e.data_exposure_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN ref sb ON sb.list_code = N'SUBSTITUTABILITY' AND sb.value_code = e.substitutability_code
    LEFT   JOIN ref ci ON ci.list_code = N'CUSTOMER_IMPACT' AND ci.value_code = e.customer_impact_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = e.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = e.assessor_employee_id
    WHERE  e.engagement_id = @engagement_id;

    SELECT s.scope_item_id AS ScopeItemId, s.item_kind AS ItemKind, s.exposure_mode AS ExposureMode, s.ref_id AS RefId,
           s.item_code AS ItemCode, s.item_name AS ItemName, s.criticality_code AS CriticalityCode, s.country AS Country,
           s.is_critical AS IsCritical, s.notes AS Notes, s.entered_by AS EnteredBy, s.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_scope s
    WHERE  s.engagement_id = @engagement_id AND s.status = N'Active'
    ORDER  BY s.exposure_mode, s.item_kind, s.item_name;

    SELECT l.link_id AS LinkId, l.link_kind AS LinkKind, l.target_id AS TargetId, l.target_label AS TargetLabel,
           l.link_source AS LinkSource, l.is_validated AS IsValidated, l.validated_by AS ValidatedBy, l.validated_dt AS ValidatedDt,
           l.note AS Note, l.status AS Status, l.entered_by AS EnteredBy, l.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_link l
    WHERE  l.engagement_id = @engagement_id AND l.status = N'Active'
    ORDER  BY l.link_kind, l.target_label;

    SELECT s.snapshot_id AS SnapshotId, s.snapshot_kind AS SnapshotKind, s.summary_json AS SummaryJson,
           s.taken_by AS TakenBy, s.taken_dt AS TakenDt
    FROM   grac_practice.tprm_exposure_snapshot s
    WHERE  s.engagement_id = @engagement_id
    ORDER  BY s.snapshot_id DESC;

    SELECT h.history_id AS HistoryId, h.event_code AS EventCode, h.from_stage_code AS FromStageCode, h.to_stage_code AS ToStageCode,
           h.detail AS Detail, h.actor AS Actor, ae.employee_name AS ActorName, h.event_dt AS EventDt
    FROM   grac_practice.tprm_engagement_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    WHERE  h.engagement_id = @engagement_id
    ORDER  BY h.history_id DESC;

    SELECT cv.field_id AS FieldId, cv.field_code AS FieldCode, cv.label AS Label, cv.data_type AS DataType, cv.value_string AS Value
    FROM   grac_practice.fn_tprm_custom_values(@organization_id, N'ENGAGEMENT', @engagement_id) cv;

    SELECT d.dimension_code AS DimensionCode, md.dimension_name AS DimensionName, d.weight AS Weight,
           d.inherent_score AS InherentScore, d.reduction_pct AS ReductionPct, d.uplift_pct AS UpliftPct,
           d.residual_score AS ResidualScore, d.safeguard_summary AS SafeguardSummary
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_risk_assessment_dimension d ON d.assessment_id = e.current_risk_assessment_id
    JOIN   grac_practice.tprm_rm_dimension md ON md.dimension_id = d.dimension_id
    WHERE  e.engagement_id = @engagement_id
    ORDER  BY md.display_order;
END
GO

-- restored from 522
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_assessment_start
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @trigger_code      NVARCHAR(60)  = N'INITIAL',
    @trigger_note      NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED', N'EXITING') THROW 57640, 'A closed engagement cannot be reassessed.', 1;
    IF @stage = N'PENDING_DECISION' THROW 57660, 'A decision is pending. Withdraw it before reassessing.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment WHERE engagement_id = @engagement_id AND status = N'DRAFT')
        THROW 57661, 'An assessment is already in progress.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id
                 AND (exposure_saved_dt IS NULL OR service_criticality_code IS NULL))
        THROW 58071, 'Save Scope & Exposure (with the service criticality) before assessing risk.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND data_exposure_code IS NOT NULL)
        THROW 57662, 'Record the scope (at least the data exposure) before assessing risk.', 1;

    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 57663, 'No risk model is in force. Activate one in Third-Party Settings.', 1;
    SET @trigger_code = ISNULL(NULLIF(LTRIM(RTRIM(@trigger_code)), N''), N'INITIAL');

    DECLARE @id BIGINT, @no INT;
    BEGIN TRAN;
        SELECT @no = ISNULL(MAX(assessment_no), 0) + 1 FROM grac_practice.tprm_risk_assessment WITH (UPDLOCK, HOLDLOCK)
         WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_risk_assessment
            (engagement_id, organization_id, assessment_no, risk_model_version_id, trigger_code, trigger_note, status,
             assessed_by_employee_id, entered_by)
        VALUES (@engagement_id, @organization_id, @no, @version, @trigger_code, @trigger_note, N'DRAFT', @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();

        -- prefill from the scope
        ;WITH sig AS (SELECT * FROM grac_practice.fn_tprm_engagement_signals(@engagement_id)),
        ranked AS (
            SELECT f.factor_id, o.option_id, o.score,
                   ROW_NUMBER() OVER (PARTITION BY f.factor_id
                                      ORDER BY ISNULL(rv.rank_no, 0) DESC, o.score DESC) AS rn
            FROM   grac_practice.tprm_rm_factor f
            JOIN   grac_practice.tprm_rm_factor_option o ON o.factor_id = f.factor_id
            CROSS  JOIN sig
            CROSS  APPLY grac_practice.fn_tprm_split_codes(o.prefill_match_code) m
            OUTER  APPLY (SELECT TOP (1) r.rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                          WHERE r.value_code = m.code
                            AND r.list_code = CASE f.prefill_source WHEN N'DATA_EXPOSURE' THEN N'DATA_EXPOSURE'
                                                                    WHEN N'ACCESS' THEN N'ACCESS_CATEGORY'
                                                                    WHEN N'SERVICE_CRITICALITY' THEN N'CRITICALITY' ELSE N'-' END) rv
            WHERE  f.version_id = @version
              AND  f.prefill_source IS NOT NULL
              AND  (   (f.prefill_source = N'SERVICE_CRITICALITY' AND m.code = sig.service_criticality_code)
                    OR (f.prefill_source = N'SERVICE_MODEL' AND m.code = sig.service_model_code)
                    OR (f.prefill_source = N'IS_EXISTING' AND m.code = CASE WHEN sig.is_existing = 1 THEN N'YES' ELSE N'NO' END)
                    OR (f.prefill_source = N'DATA_EXPOSURE' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.data_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'ACCESS' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.access_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'FOURTH_PARTY_COUNT'
                        AND m.code = CASE WHEN sig.fourth_party_count >= 3 THEN N'3+' ELSE CAST(sig.fourth_party_count AS NVARCHAR(5)) END)
                    OR (f.prefill_source = N'LOCATION_COUNT'
                        AND m.code = CASE WHEN sig.location_count >= 3 THEN N'3+' ELSE CAST(sig.location_count AS NVARCHAR(5)) END))
        )
        INSERT grac_practice.tprm_risk_assessment_answer (assessment_id, factor_id, option_id, score, is_prefilled, updated_by)
        SELECT @id, factor_id, option_id, score, 1, @actor FROM ranked WHERE rn = 1;

        EXEC grac_practice.sp_tprm_risk_score @id;
    COMMIT;

    DECLARE @sdetail NVARCHAR(2000) = CONCAT(N'Inherent assessment ', @no, N' started (', @trigger_code, N').');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'RISK_ASSESSMENT_STARTED', @stage, @stage, @sdetail, @actor_employee_id, @actor;
    SELECT @id AS AssessmentId, N'STARTED' AS Result;
END
GO

-- restored from 522
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_sample_load
    @organization_id   BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 57600, 'Select an organization.', 1;

    DECLARE @loaded INT = 0, @code NVARCHAR(60), @tp BIGINT, @eng BIGINT, @next INT, @tcode NVARCHAR(20), @ecode NVARCHAR(20);
    DECLARE @active NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'ACTIVE'), N'ACTIVE');
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.sample_code FROM grac_practice.tprm_sample_profile p
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t
                           WHERE t.organization_id = @organization_id AND t.is_sample = 1 AND t.legal_name = p.legal_name)
        ORDER BY p.display_order;
    OPEN c;
    FETCH NEXT FROM c INTO @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @tcode = N'TP-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, normalized_name, provider_type_code, primary_service_category_code,
             country, lifecycle_status_code, first_activated_dt, relationship_owner_employee_id, profile_notes, is_sample, entered_by)
        SELECT @organization_id, @tcode, p.legal_name, grac_practice.fn_tprm_normalize_name(p.legal_name), p.provider_type_code,
               p.service_category_code, p.country, @active, SYSUTCDATETIME(), @actor_employee_id,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @active, N'Sample record loaded (registered and activated).', 0, @actor_employee_id, @actor);

        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, notes, is_sample, stage_code, exposure_saved_dt, exposure_saved_by, entered_by)
        SELECT @organization_id, @tp, @ecode, p.engagement_title, p.service_description, p.scope_description, p.business_purpose,
               p.service_category_code, p.engagement_type_code, p.service_model_code, p.country, 0, p.criticality_code,
               p.data_exposure_code, p.rto_hours, p.rpo_hours,
               CONCAT(N'Sample guidance -- key safeguards: ', p.key_safeguards, N'. Evidence expected: ', p.evidence_expectations,
                      N'. Review triggers: ', p.review_triggers, N'.'),
               1, N'SCOPING', SYSUTCDATETIME(), @actor, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @eng = SCOPE_IDENTITY();

        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'DATA_CATEGORY', N'PROPOSED', p.data_exposure_code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'DATA_EXPOSURE' AND value_code = p.data_exposure_code), p.data_exposure_code), @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code AND p.data_exposure_code IS NOT NULL;
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'ACCESS', N'PROPOSED', a.code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'ACCESS_CATEGORY' AND value_code = a.code), a.code), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY grac_practice.fn_tprm_split_codes(p.access_codes) a
        WHERE p.sample_code = @code;
        -- fourth parties: name|category|country;...
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, country, entered_by)
        SELECT @eng, @organization_id, N'FOURTH_PARTY', N'PROPOSED',
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 2), N''),
               LEFT(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3), 300),
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 1), N''), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY STRING_SPLIT(ISNULL(p.fourth_parties, N''), N';') f
        WHERE p.sample_code = @code AND LTRIM(RTRIM(f.value)) <> N''
          AND PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3) IS NOT NULL;

        -- the gating questions, answered from what the sample records
        EXEC grac_practice.sp_tprm_engagement_answers_derive @eng, @actor;
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Sample engagement loaded.', @actor_employee_id, @actor;
        COMMIT;
        SET @loaded = @loaded + 1;
        FETCH NEXT FROM c INTO @code;
    END
    CLOSE c;
    DEALLOCATE c;

    EXEC grac_practice.sp_tprm_audit N'tprm-sample', @organization_id, N'LOAD', NULL, @actor;
    SELECT @loaded AS LoadedCount, N'LOADED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_list
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @third_party_id     BIGINT        = NULL,
    @stage_code         NVARCHAR(30)  = NULL,   -- a stage, OPEN (not closed) or CLOSED
    @band_code          NVARCHAR(60)  = NULL,   -- residual band, else inherent
    @criticality_code   NVARCHAR(60)  = NULL,
    @owner_employee_id  BIGINT        = NULL,
    @attention          NVARCHAR(30)  = NULL,   -- REASSESS / REVIEW_DUE / MINE
    @caller_employee_id BIGINT        = NULL,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           e.stage_code AS StageCode, e.stage_dt AS StageDt, e.is_existing AS IsExisting, e.is_sample AS IsSample,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.dd_tier_code AS DdTierCode, dt.label AS DdTier,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.next_review_dt AS NextReviewDt, e.reassessment_required AS ReassessmentRequired,
           e.proposed_end_dt AS ProposedEndDt, e.actual_end_dt AS ActualEndDt,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    WHERE  e.organization_id = @organization_id
      AND  (@third_party_id IS NULL OR e.third_party_id = @third_party_id)
      AND  (@stage_code IS NULL
            OR e.stage_code = @stage_code
            OR (@stage_code = N'OPEN' AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            OR (@stage_code = N'CLOSED' AND e.stage_code IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            OR (@stage_code = N'IN_ASSESSMENT' AND e.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION')))
      AND  (@band_code IS NULL OR COALESCE(e.residual_band_code, e.inherent_band_code) = @band_code)
      AND  (@criticality_code IS NULL OR e.service_criticality_code = @criticality_code)
      AND  (@owner_employee_id IS NULL OR @owner_employee_id IN (e.business_owner_employee_id, e.relationship_owner_employee_id, e.assessor_employee_id))
      AND  (@attention IS NULL
            OR (@attention = N'REASSESS' AND e.reassessment_required = 1)
            OR (@attention = N'REVIEW_DUE' AND e.next_review_dt IS NOT NULL AND e.next_review_dt <= DATEADD(DAY, 30, @today))
            OR (@attention = N'MINE' AND @caller_employee_id IN (e.business_owner_employee_id, e.relationship_owner_employee_id, e.assessor_employee_id)))
      AND  (@s IS NULL OR e.engagement_title LIKE N'%' + @s + N'%' OR e.engagement_code LIKE N'%' + @s + N'%'
            OR t.legal_name LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value cv
                        JOIN grac_practice.tprm_custom_field cf ON cf.field_id = cv.field_id AND cf.is_searchable = 1
                        WHERE cv.entity_code = N'ENGAGEMENT' AND cv.record_id = e.engagement_id
                          AND cv.value_text LIKE N'%' + @s + N'%'))
    ORDER  BY CASE WHEN e.stage_code IN (N'EXITED', N'REJECTED', N'CANCELLED') THEN 1 ELSE 0 END,
              e.engagement_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO


-- =====================================================================
-- 2. Objects 523 added
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_admission_withdraw;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_admission_act;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_applicability_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_applicability_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_screening_run;
GO
DROP TABLE IF EXISTS grac_practice.tprm_admission_approval;
DROP TABLE IF EXISTS grac_practice.tprm_admission;
DROP TABLE IF EXISTS grac_practice.tprm_applicability_decision;
DROP TABLE IF EXISTS grac_practice.tprm_screening_observation;
DROP TABLE IF EXISTS grac_practice.tprm_screening_report;
GO
DECLARE @drop NVARCHAR(MAX) = N'';
SELECT @drop = @drop + N'ALTER TABLE grac_practice.tprm_engagement DROP CONSTRAINT ' + QUOTENAME(o.name) + N';'
FROM sys.objects o
WHERE o.parent_object_id = OBJECT_ID('grac_practice.tprm_engagement')
  AND o.name IN (N'ck_pm_tprm_eng_applic', N'df_pm_tprm_eng_applic');
SELECT @drop = @drop + N'ALTER TABLE grac_practice.tprm_engagement DROP COLUMN ' + QUOTENAME(c.name) + N';'
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('grac_practice.tprm_engagement')
  AND c.name IN (N'applicability_status', N'current_screening_report_id', N'admitted_dt');
IF @drop <> N'' EXEC sp_executesql @drop;
PRINT '523 rollback: engagement columns dropped.';
GO
DELETE o FROM grac_practice.tprm_reference_value o
JOIN grac_practice.tprm_reference_value b ON b.value_id = o.baseline_value_id
WHERE b.list_code = N'SCREENING_INDICATOR';
DELETE FROM grac_practice.tprm_reference_value WHERE list_code = N'SCREENING_INDICATOR';
DELETE FROM grac_practice.tprm_reference_list WHERE list_code = N'SCREENING_INDICATOR';
GO

-- =====================================================================
-- 3. Verification
-- =====================================================================
SELECT '523 rollback: 523 objects gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_screening_report', 'U') IS NULL
             AND OBJECT_ID('grac_practice.tprm_admission', 'U') IS NULL
             AND OBJECT_ID('grac_practice.sp_tprm_screening_run', 'P') IS NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_list WHERE list_code = N'SCREENING_INDICATOR')
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO

PRINT '523 rollback complete.';
GO
