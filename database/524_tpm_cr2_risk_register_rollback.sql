-- =====================================================================
-- 524_tpm_cr2_risk_register_rollback.sql
--
-- Reverses 524_tpm_cr2_risk_register.sql:
--   * The procedure bodies 524 re-issued are restored verbatim
--     (sp_tprm_admission_act, sp_tprm_engagement_get from 523;
--     sp_tprm_engagement_lifecycle, sp_tprm_decision_act from 489).
--   * The register procedures and fn_tprm_register_overall are dropped,
--     and the register tables (tprm_register_history,
--     tprm_register_impact_review, tprm_register_profile_rating,
--     tprm_register_engagement, tprm_risk_register) are dropped WITH
--     their data.
--   * The list VENDOR_PROFILE_AREA is removed (baseline values,
--     organization values and overrides).
--   * The menu row tprm-risk-register and its grants are removed.
--   Not undone: admissions withdrawn by cancelling an engagement stay
--   withdrawn; engagement history rows REGISTER_LINKED stay.
-- Deploy the previous API / Web build first. Run AFTER the 525 rollback
-- (refuses while 525 is installed) and BEFORE the 523 rollback.
-- 274 and 490 carry the 524 menu row: after this rollback, re-run them
-- only from the versions of 523 (version control).
-- Generated from the 523 / 489 sources. ASCII-only. SAFE TO RE-RUN.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.tprm_admission','U') IS NULL
BEGIN
    PRINT '524 rollback: 523 is not installed -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- 525 builds on 524 (it re-issues the register procedures): roll 525 back first.
IF OBJECT_ID('grac_practice.tprm_register_profile_review', 'U') IS NOT NULL
BEGIN
    PRINT '524 rollback ABORTED: 525 is installed. Run 525_tpm_dashboard_tasks_profile_review_rollback.sql first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Procedures as they were before 524
-- =====================================================================

-- restored from 523
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_admission_act
    @organization_id          BIGINT,
    @admission_id             BIGINT,
    @action                   NVARCHAR(20),
    @rationale                NVARCHAR(2000) = NULL,
    @on_behalf_of_employee_id BIGINT         = NULL,
    @actor_employee_id        BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 58115, 'Approving needs a sign-in linked to an employee.', 1;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @levels INT, @sod BIT, @submitter BIGINT, @decision_id BIGINT, @no INT;
    SELECT @eng = engagement_id, @status = status, @levels = required_levels, @sod = sod_required, @submitter = submitted_by_employee_id,
           @decision_id = applicability_decision_id, @no = admission_no
    FROM grac_practice.tprm_admission WHERE admission_id = @admission_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 58116, 'That admission was not found.', 1;
    IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
    SET @action = UPPER(NULLIF(LTRIM(RTRIM(@action)), N''));
    IF @action IS NULL OR @action NOT IN (N'APPROVE', N'REJECT', N'RETURN') THROW 58118, 'Choose approve, reject or return.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 58119, 'Record the rationale.', 1;

    DECLARE @approval BIGINT, @level INT, @role NVARCHAR(120), @stage NVARCHAR(30), @applic NVARCHAR(30);
    BEGIN TRAN;
    -- Every check below runs under a lock on the admission and its
    -- engagement, so two approvers cannot act on the same level, and an
    -- engagement that was closed or re-decided cannot be admitted.
    SELECT @status = status FROM grac_practice.tprm_admission WITH (UPDLOCK, HOLDLOCK) WHERE admission_id = @admission_id;
    IF @status <> N'PENDING' THROW 58117, 'That admission is no longer pending.', 1;
    SELECT @stage = stage_code, @applic = applicability_status
    FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK) WHERE engagement_id = @eng;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF @applic <> N'ADMISSION_PENDING'
       OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_applicability_decision WHERE decision_id = @decision_id AND status = N'CURRENT')
        THROW 58126, 'The engagement is no longer awaiting this admission. Refresh the page.', 1;
    SELECT TOP (1) @approval = approval_id, @level = level_no, @role = required_role_name
    FROM grac_practice.tprm_admission_approval WHERE admission_id = @admission_id AND status = N'PENDING' ORDER BY level_no;

    IF @on_behalf_of_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_delegation
                        WHERE organization_id = @organization_id AND from_employee_id = @on_behalf_of_employee_id
                          AND to_employee_id = @actor_employee_id AND status = N'Active'
                          AND CONVERT(DATE, SYSUTCDATETIME()) BETWEEN valid_from AND valid_to)
        THROW 58120, 'You have no active delegation from that approver.', 1;
    DECLARE @authority BIGINT = COALESCE(@on_behalf_of_employee_id, @actor_employee_id);
    IF @role IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_role WHERE organization_id = @organization_id
                                       AND role_name = @role AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
                        WHERE e.employee_id = @authority AND r.role_name = @role)
    BEGIN
        DECLARE @role_msg NVARCHAR(400) = CONCAT(N'Approval level ', @level, N' needs the role "', @role, N'".');
        THROW 58121, @role_msg, 1;
    END
    IF @sod = 1
    BEGIN
        IF @actor_employee_id = @submitter OR @authority = @submitter
            THROW 58122, 'Segregation of duties: the decision-maker who included the engagement cannot approve its admission.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_admission_approval WHERE admission_id = @admission_id AND status = N'APPROVED'
                     AND (approver_employee_id IN (@actor_employee_id, @authority) OR on_behalf_of_employee_id IN (@actor_employee_id, @authority)))
            THROW 58123, 'Segregation of duties: each approval level needs a different person.', 1;
    END

    DECLARE @final BIT = CASE WHEN @action <> N'APPROVE' OR @level >= @levels THEN 1 ELSE 0 END;
    DECLARE @outcome NVARCHAR(20) = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'RETURNED' END;
    DECLARE @to_status NVARCHAR(30) = CASE @action WHEN N'APPROVE' THEN N'ADMITTED' WHEN N'REJECT' THEN N'ADMISSION_REJECTED' ELSE N'SCREENED' END;
        UPDATE grac_practice.tprm_admission_approval
           SET status = @outcome, approver_employee_id = @actor_employee_id, on_behalf_of_employee_id = @on_behalf_of_employee_id,
               comment = @rationale, decided_dt = SYSUTCDATETIME()
         WHERE approval_id = @approval AND status = N'PENDING';
        IF @@ROWCOUNT = 0 THROW 58117, 'That admission is no longer pending.', 1;
        IF @final = 1
        BEGIN
            UPDATE grac_practice.tprm_admission_approval SET status = N'WITHDRAWN' WHERE admission_id = @admission_id AND status = N'PENDING';
            UPDATE grac_practice.tprm_admission
               SET status = @outcome, outcome_rationale = @rationale, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
             WHERE admission_id = @admission_id;
            -- returned: the INCLUDE decision no longer stands; a new decision is needed
            IF @action = N'RETURN'
                UPDATE grac_practice.tprm_applicability_decision SET status = N'SUPERSEDED', superseded_dt = SYSUTCDATETIME()
                 WHERE decision_id = @decision_id AND status = N'CURRENT';
            UPDATE grac_practice.tprm_engagement
               SET applicability_status = @to_status,
                   admitted_dt = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE admitted_dt END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE engagement_id = @eng;
        END
        DECLARE @detail NVARCHAR(2000) = LEFT(CASE WHEN @final = 1
            THEN CONCAT(N'Admission ', @no, N' ', LOWER(@outcome), N'. ', @rationale,
                        CASE WHEN @action = N'APPROVE' THEN N' The engagement is admitted to formal TPRM.' ELSE N'' END)
            ELSE CONCAT(N'Admission ', @no, N': approval level ', @level, N' approved. ', @rationale) END, 2000);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'ADMISSION', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;
    DECLARE @audit_json NVARCHAR(MAX) = (SELECT @action AS action, @level AS levelNo, @rationale AS rationale,
                                                @on_behalf_of_employee_id AS onBehalfOfEmployeeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC grac_practice.sp_tprm_audit N'tprm-admission', @admission_id, @action, @audit_json, @actor;
    SELECT @admission_id AS AdmissionId, CASE WHEN @final = 1 THEN @to_status ELSE N'LEVEL_APPROVED' END AS Result;
END
GO

-- restored from 523
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
           e.applicability_status AS ApplicabilityStatus, e.current_screening_report_id AS CurrentScreeningReportId,
           sr.version_no AS ScreeningVersionNo, sr.classification AS ScreeningClassification, sr.generated_dt AS ScreeningDt,
           e.admitted_dt AS AdmittedDt,
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
    LEFT   JOIN grac_practice.tprm_screening_report sr ON sr.report_id = e.current_screening_report_id
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

-- restored from 489
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_lifecycle
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @action            NVARCHAR(20),
    @reason            NVARCHAR(1000) = NULL,
    @new_end_dt        DATE           = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30), @tp BIGINT, @end DATE;
    SELECT @stage = stage_code, @tp = third_party_id, @end = COALESCE(actual_end_dt, proposed_end_dt)
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @stage IS NULL THROW 57700, 'That engagement was not found.', 1;
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    IF @reason IS NULL THROW 57804, 'Give the reason.', 1;
    DECLARE @to NVARCHAR(30) = @stage, @rid BIGINT, @due DATE = DATEADD(DAY, 30, CONVERT(DATE, SYSUTCDATETIME()));

    BEGIN TRAN;
    IF @action = N'SUSPEND'
    BEGIN
        IF @stage <> N'ACTIVE' BEGIN ROLLBACK; THROW 57805, 'Only an active engagement can be suspended.', 1; END
        SET @to = N'SUSPENDED';
    END
    ELSE IF @action = N'RESUME'
    BEGIN
        IF @stage <> N'SUSPENDED' BEGIN ROLLBACK; THROW 57806, 'Only a suspended engagement can be resumed.', 1; END
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND reassessment_required = 1)
        BEGIN ROLLBACK; THROW 57807, 'The engagement needs reassessment before it can resume.', 1; END
        SET @to = N'ACTIVE';
    END
    ELSE IF @action = N'RENEW'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED') BEGIN ROLLBACK; THROW 57808, 'Only a live engagement can be renewed.', 1; END
        IF @new_end_dt IS NULL OR (@end IS NOT NULL AND @new_end_dt <= @end) BEGIN ROLLBACK; THROW 57809, 'Give a new end date after the current one.', 1; END
        UPDATE grac_practice.tprm_engagement SET actual_end_dt = @new_end_dt, renewal_dt = CONVERT(DATE, SYSUTCDATETIME()) WHERE engagement_id = @engagement_id;
        DECLARE @rkey NVARCHAR(200) = CONCAT(N'RENEWAL:', @engagement_id, N':', CONVERT(NVARCHAR(10), @new_end_dt, 23));
        EXEC grac_practice.sp_tprm_review_create @organization_id, @engagement_id, N'TRIGGERED', N'CONTRACT_RENEWAL', @reason, @due, NULL, @rkey, @actor, @rid OUTPUT;
    END
    ELSE IF @action = N'SCOPE_CHANGE'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING', N'APPROVED') BEGIN ROLLBACK; THROW 57810, 'Scope changes are recorded for approved or live engagements.', 1; END
        UPDATE grac_practice.tprm_engagement SET reassessment_required = 1, reassessment_reason = LEFT(CONCAT(N'Material scope change: ', @reason), 1000)
         WHERE engagement_id = @engagement_id;
        DECLARE @skey NVARCHAR(200) = CONCAT(N'SCOPE:', @engagement_id, N':', CONVERT(NVARCHAR(36), NEWID()));
        EXEC grac_practice.sp_tprm_review_create @organization_id, @engagement_id, N'TRIGGERED', N'SCOPE_CHANGE', @reason, @due, NULL, @skey, @actor, @rid OUTPUT;
    END
    ELSE IF @action = N'START_EXIT'
    BEGIN
        IF @stage NOT IN (N'ACTIVE', N'SUSPENDED', N'APPROVED', N'ONBOARDING') BEGIN ROLLBACK; THROW 57811, 'Exit starts from an approved or live engagement.', 1; END
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision WHERE engagement_id = @engagement_id AND status = N'PENDING')
        BEGIN ROLLBACK; THROW 57812, 'Withdraw the pending decision first.', 1; END
        EXEC grac_practice.sp_tprm_checks_create @organization_id, @engagement_id, N'EXIT', @actor;
        SET @to = N'EXITING';
    END
    ELSE IF @action = N'COMPLETE_EXIT'
    BEGIN
        IF @stage <> N'EXITING' BEGIN ROLLBACK; THROW 57813, 'Start the exit first.', 1; END
        DECLARE @pending INT = (SELECT COUNT(*) FROM grac_practice.tprm_onboarding_item WHERE engagement_id = @engagement_id
                                  AND phase = N'EXIT' AND is_mandatory = 1 AND status = N'PENDING');
        IF @pending > 0
        BEGIN
            ROLLBACK;
            DECLARE @emsg NVARCHAR(300) = CONCAT(@pending, N' mandatory exit check(s) are not done or waived (data return, deletion evidence, access, dependencies).');
            THROW 57814, @emsg, 1;
        END
        UPDATE grac_practice.tprm_engagement SET actual_end_dt = COALESCE(actual_end_dt, CONVERT(DATE, SYSUTCDATETIME())), next_review_dt = NULL
         WHERE engagement_id = @engagement_id;
        UPDATE grac_practice.tprm_review SET status = N'CANCELLED', outcome_note = N'Engagement exited.' WHERE engagement_id = @engagement_id AND status = N'OPEN';
        UPDATE grac_practice.tprm_finding SET status = N'CANCELLED', status_note = N'Engagement exited.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status IN (N'OPEN', N'IN_PROGRESS') AND custom_gap_id IS NULL;
        SET @to = N'EXITED';
    END
    ELSE IF @action = N'CANCEL'
    BEGIN
        IF @stage NOT IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'APPROVED', N'ONBOARDING')
        BEGIN ROLLBACK; THROW 57815, 'Only an engagement that is not yet active can be cancelled (withdraw a pending decision first).', 1; END
        UPDATE grac_practice.tprm_dd_assessment SET status = N'CANCELLED' WHERE engagement_id = @engagement_id AND status = N'IN_PROGRESS';
        UPDATE grac_practice.tprm_risk_assessment SET status = N'DISCARDED' WHERE engagement_id = @engagement_id AND status = N'DRAFT';
        UPDATE grac_practice.tprm_finding SET status = N'CANCELLED', status_note = N'Engagement cancelled.', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id AND status IN (N'OPEN', N'IN_PROGRESS') AND custom_gap_id IS NULL;
        UPDATE grac_practice.tprm_review SET status = N'CANCELLED', outcome_note = N'Engagement cancelled.' WHERE engagement_id = @engagement_id AND status = N'OPEN';
        SET @to = N'CANCELLED';
    END
    ELSE BEGIN ROLLBACK; THROW 57816, 'Unknown lifecycle action.', 1; END

    IF @to <> @stage
        UPDATE grac_practice.tprm_engagement SET stage_code = @to, stage_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @engagement_id;
    COMMIT;

    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @evt NVARCHAR(40) = CONCAT(N'LIFECYCLE_', @action);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, @evt, @stage, @to, @reason, @actor_employee_id, @actor;
    SELECT @engagement_id AS EngagementId, @to AS Result;
END
GO

-- restored from 489
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_decision_act
    @organization_id          BIGINT,
    @decision_id              BIGINT,
    @action                   NVARCHAR(20),
    @outcome_code             NVARCHAR(60)   = NULL,
    @rationale                NVARCHAR(2000) = NULL,
    @risk_accepted            BIT            = 0,
    @acceptance_until         DATE           = NULL,
    @mandatory_review_dt      DATE           = NULL,
    @conditions_json          NVARCHAR(MAX)  = NULL,   -- [{"title","description","severity","ownerEmployeeId","dueDt"}]
    @on_behalf_of_employee_id BIGINT         = NULL,
    @actor_employee_id        BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @actor_employee_id IS NULL THROW 57765, 'Approving needs a sign-in linked to an employee.', 1;
    DECLARE @eng BIGINT, @status NVARCHAR(20), @levels INT, @sod BIT, @submitter BIGINT, @prior NVARCHAR(30), @rule_json NVARCHAR(MAX), @dd BIGINT;
    SELECT @eng = engagement_id, @status = status, @levels = required_levels, @sod = sod_required, @submitter = submitted_by_employee_id,
           @prior = prior_stage_code, @rule_json = rule_snapshot_json, @dd = dd_id
    FROM grac_practice.tprm_decision WHERE decision_id = @decision_id AND organization_id = @organization_id;
    IF @eng IS NULL THROW 57766, 'That decision was not found.', 1;
    IF @status <> N'PENDING' THROW 57767, 'That decision is no longer pending.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'RETURN') THROW 57768, 'Unknown decision action.', 1;
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @rationale IS NULL THROW 57769, 'Record the rationale for the decision.', 1;

    DECLARE @approval BIGINT, @level INT, @role NVARCHAR(120);
    SELECT TOP (1) @approval = approval_id, @level = level_no, @role = required_role_name
    FROM grac_practice.tprm_decision_approval WHERE decision_id = @decision_id AND status = N'PENDING' ORDER BY level_no;

    -- delegation
    IF @on_behalf_of_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_approval_delegation
                        WHERE organization_id = @organization_id AND from_employee_id = @on_behalf_of_employee_id
                          AND to_employee_id = @actor_employee_id AND status = N'Active'
                          AND CONVERT(DATE, SYSUTCDATETIME()) BETWEEN valid_from AND valid_to)
        THROW 57770, 'You have no active delegation from that approver.', 1;
    DECLARE @authority BIGINT = COALESCE(@on_behalf_of_employee_id, @actor_employee_id);

    -- role
    IF @role IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_role WHERE organization_id = @organization_id
                                       AND role_name = @role AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
                        WHERE e.employee_id = @authority AND r.role_name = @role)
    BEGIN
        DECLARE @role_msg NVARCHAR(400) = CONCAT(N'Approval level ', @level, N' needs the role "', @role, N'".');
        THROW 57771, @role_msg, 1;
    END

    -- segregation of duties
    IF @sod = 1
    BEGIN
        IF @actor_employee_id = @submitter OR @authority = @submitter
            THROW 57772, 'Segregation of duties: the person who requested the decision cannot approve it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @eng AND assessor_employee_id IN (@actor_employee_id, @authority))
           OR EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE dd_id = @dd AND assessor_employee_id IN (@actor_employee_id, @authority))
            THROW 57773, 'Segregation of duties: the assessor of this engagement cannot approve it.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_decision_approval WHERE decision_id = @decision_id AND status = N'APPROVED'
                     AND (approver_employee_id IN (@actor_employee_id, @authority) OR on_behalf_of_employee_id IN (@actor_employee_id, @authority)))
            THROW 57774, 'Segregation of duties: each approval level needs a different person.', 1;
    END

    DECLARE @final BIT = CASE WHEN @action <> N'APPROVE' OR @level >= @levels THEN 1 ELSE 0 END;
    DECLARE @meaning NVARCHAR(40), @max_months INT = TRY_CONVERT(INT, JSON_VALUE(@rule_json, '$.max_acceptance_months')),
            @allowed NVARCHAR(400) = JSON_VALUE(@rule_json, '$.allowed_decision_codes');
    IF @final = 1
    BEGIN
        IF @action = N'APPROVE'
        BEGIN
            SELECT TOP (1) @meaning = meaning_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
             WHERE list_code = N'DECISION' AND value_code = @outcome_code;
            IF @meaning NOT IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') OR @meaning IS NULL
                THROW 57775, 'Choose an approval outcome.', 1;
            IF @allowed IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(@allowed) x WHERE x.code = @outcome_code)
                THROW 57776, 'That outcome is not allowed by the approval rule.', 1;
        END
        ELSE
        BEGIN
            SET @meaning = @action;
            IF @outcome_code IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                     WHERE list_code = N'DECISION' AND value_code = @outcome_code AND meaning_code = @meaning)
                SET @outcome_code = grac_practice.fn_tprm_meaning_code(@organization_id, N'DECISION', @meaning);
        END
        IF @conditions_json IS NOT NULL AND ISJSON(@conditions_json) <> 1 THROW 57777, 'Conditions are not valid.', 1;
        IF @meaning = N'APPROVE_WITH_CONDITIONS'
           AND NOT EXISTS (SELECT 1 FROM OPENJSON(ISNULL(@conditions_json, N'[]')) WITH (title NVARCHAR(300) '$.title') WHERE NULLIF(LTRIM(RTRIM(title)), N'') IS NOT NULL)
           AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_finding WHERE engagement_id = @eng AND finding_kind = N'CONDITION' AND status IN (N'OPEN', N'IN_PROGRESS'))
            THROW 57778, 'Approval with conditions needs at least one condition.', 1;
        IF ISNULL(@risk_accepted, 0) = 1
        BEGIN
            IF @meaning NOT IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THROW 57779, 'Risk is accepted only with an approval.', 1;
            IF @acceptance_until IS NULL OR @acceptance_until <= CONVERT(DATE, SYSUTCDATETIME())
                THROW 57780, 'Risk acceptance is time-bound: give a future end date.', 1;
            IF @max_months IS NOT NULL AND @acceptance_until > DATEADD(MONTH, @max_months, CONVERT(DATE, SYSUTCDATETIME()))
            BEGIN
                DECLARE @acc_msg NVARCHAR(300) = CONCAT(N'The approval rule allows risk acceptance for at most ', @max_months, N' months.');
                THROW 57781, @acc_msg, 1;
            END
            SET @mandatory_review_dt = COALESCE(@mandatory_review_dt, @acceptance_until);
        END
        IF @mandatory_review_dt IS NOT NULL AND @mandatory_review_dt <= CONVERT(DATE, SYSUTCDATETIME())
            THROW 57782, 'The mandatory review date must be in the future.', 1;
    END

    DECLARE @new_stage NVARCHAR(30);
    BEGIN TRAN;
        UPDATE grac_practice.tprm_decision_approval
           SET status = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'RETURNED' END,
               approver_employee_id = @actor_employee_id, on_behalf_of_employee_id = @on_behalf_of_employee_id,
               comment = @rationale, decided_dt = SYSUTCDATETIME()
         WHERE approval_id = @approval;

        IF @final = 1
        BEGIN
            UPDATE grac_practice.tprm_decision_approval SET status = N'WITHDRAWN' WHERE decision_id = @decision_id AND status = N'PENDING';
            UPDATE grac_practice.tprm_decision
               SET status = N'DECIDED', outcome_code = @outcome_code, outcome_meaning = @meaning, rationale = @rationale,
                   risk_accepted = ISNULL(@risk_accepted, 0), acceptance_until = CASE WHEN @risk_accepted = 1 THEN @acceptance_until END,
                   mandatory_review_dt = @mandatory_review_dt, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME()
             WHERE decision_id = @decision_id;

            -- conditions become CONDITION findings that must be met before activation
            IF @conditions_json IS NOT NULL
            BEGIN
                DECLARE @c_title NVARCHAR(300), @c_desc NVARCHAR(2000), @c_sev NVARCHAR(60), @c_owner BIGINT, @c_due DATE, @c_no NVARCHAR(20);
                DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
                    SELECT LEFT(LTRIM(RTRIM(title)), 300), description, UPPER(ISNULL(NULLIF(severity, N''), N'MEDIUM')), ownerEmployeeId, dueDt
                    FROM OPENJSON(@conditions_json) WITH (title NVARCHAR(300) '$.title', description NVARCHAR(2000) '$.description',
                                                          severity NVARCHAR(60) '$.severity', ownerEmployeeId BIGINT '$.ownerEmployeeId', dueDt DATE '$.dueDt')
                    WHERE NULLIF(LTRIM(RTRIM(title)), N'') IS NOT NULL;
                OPEN cc;
                FETCH NEXT FROM cc INTO @c_title, @c_desc, @c_sev, @c_owner, @c_due;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    EXEC grac_practice.sp_tprm_next_number @organization_id, N'TPF-', @c_no OUTPUT;
                    INSERT grac_practice.tprm_finding
                        (organization_id, engagement_id, dd_id, finding_number, finding_kind, source_kind, source_id, is_automatic, title,
                         description, severity_code, owner_employee_id, due_dt, is_mandatory_for_activation, status, entered_by)
                    VALUES (@organization_id, @eng, @dd, @c_no, N'CONDITION', N'DECISION', @decision_id, 0, @c_title, @c_desc,
                            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                               WHERE list_code = N'FINDING_SEVERITY' AND value_code = @c_sev) THEN @c_sev ELSE N'MEDIUM' END,
                            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_employee WHERE employee_id = @c_owner AND organization_id = @organization_id)
                                 THEN @c_owner END,
                            @c_due, 1, N'OPEN', @actor);
                    FETCH NEXT FROM cc INTO @c_title, @c_desc, @c_sev, @c_owner, @c_due;
                END
                CLOSE cc;
                DEALLOCATE cc;
            END

            SET @new_stage = CASE
                WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THEN CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING') THEN @prior ELSE N'APPROVED' END
                WHEN @meaning = N'REJECT' THEN CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED') THEN N'SUSPENDED' ELSE N'REJECTED' END
                ELSE CASE WHEN @prior IN (N'ACTIVE', N'SUSPENDED') THEN @prior ELSE N'DUE_DILIGENCE' END END;
            UPDATE grac_practice.tprm_engagement
               SET stage_code = @new_stage, stage_dt = SYSUTCDATETIME(),
                   acceptance_until = CASE WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') AND @risk_accepted = 1 THEN @acceptance_until
                                           WHEN @meaning IN (N'APPROVE', N'APPROVE_WITH_CONDITIONS') THEN NULL ELSE acceptance_until END,
                   next_review_dt = CASE WHEN @mandatory_review_dt IS NOT NULL THEN @mandatory_review_dt ELSE next_review_dt END,
                   reassessment_required = CASE WHEN @meaning IN (N'RETURN', N'REJECT') AND @prior IN (N'ACTIVE', N'SUSPENDED') THEN 1 ELSE reassessment_required END,
                   reassessment_reason = CASE WHEN @meaning IN (N'RETURN', N'REJECT') AND @prior IN (N'ACTIVE', N'SUSPENDED')
                                              THEN LEFT(CONCAT(CASE WHEN @meaning = N'REJECT' THEN N'Decision rejected: ' ELSE N'Decision returned: ' END, @rationale), 1000)
                                              ELSE reassessment_reason END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE engagement_id = @eng;
            -- returned: due diligence reopens for more information
            IF @meaning = N'RETURN' AND @dd IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_dd_assessment WHERE engagement_id = @eng AND status = N'IN_PROGRESS')
                UPDATE grac_practice.tprm_dd_assessment SET status = N'IN_PROGRESS', completed_by = NULL, completed_dt = NULL WHERE dd_id = @dd;
        END
    COMMIT;

    DECLARE @tp BIGINT = (SELECT third_party_id FROM grac_practice.tprm_engagement WHERE engagement_id = @eng);
    IF @final = 1 EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    DECLARE @audit_json NVARCHAR(MAX) = (SELECT @action AS action, @level AS levelNo, @outcome_code AS outcomeCode, @rationale AS rationale,
                                                @risk_accepted AS riskAccepted, @acceptance_until AS acceptanceUntil,
                                                @on_behalf_of_employee_id AS onBehalfOfEmployeeId
                                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC grac_practice.sp_tprm_audit N'tprm-decision', @decision_id, @action, @audit_json, @actor;
    DECLARE @detail NVARCHAR(2000) = CASE WHEN @final = 1
        THEN CONCAT(N'Decision: ', @outcome_code, CASE WHEN @risk_accepted = 1 THEN CONCAT(N'; risk accepted until ', CONVERT(NVARCHAR(10), @acceptance_until, 23)) ELSE N'' END,
                    N'. ', @rationale)
        ELSE CONCAT(N'Approval level ', @level, N' approved. ', @rationale) END;
    DECLARE @from_stage NVARCHAR(30) = CASE WHEN @final = 1 THEN N'PENDING_DECISION' END;
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'DECISION', @from_stage, @new_stage, @detail, @actor_employee_id, @actor;
    SELECT @decision_id AS DecisionId, CASE WHEN @final = 1 THEN N'DECIDED' ELSE N'LEVEL_APPROVED' END AS Result;
END
GO


-- =====================================================================
-- 2. Objects 524 added
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_close;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_impact_review_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_rating_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_sync_engagement;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_link;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_register_event;
DROP FUNCTION IF EXISTS grac_practice.fn_tprm_register_overall;
GO
DROP TABLE IF EXISTS grac_practice.tprm_register_history;
DROP TABLE IF EXISTS grac_practice.tprm_register_impact_review;
DROP TABLE IF EXISTS grac_practice.tprm_register_profile_rating;
DROP TABLE IF EXISTS grac_practice.tprm_register_engagement;
DROP TABLE IF EXISTS grac_practice.tprm_risk_register;
GO
DELETE o FROM grac_practice.tprm_reference_value o
JOIN grac_practice.tprm_reference_value b ON b.value_id = o.baseline_value_id
WHERE b.list_code = N'VENDOR_PROFILE_AREA';
DELETE FROM grac_practice.tprm_reference_value WHERE list_code = N'VENDOR_PROFILE_AREA';
DELETE FROM grac_practice.tprm_reference_list WHERE list_code = N'VENDOR_PROFILE_AREA';
GO
DELETE p FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE m.menu_key = N'tprm-risk-register';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'tprm-risk-register';
GO

-- =====================================================================
-- 3. Verification
-- =====================================================================
SELECT '524 rollback: 524 objects gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.tprm_risk_register', 'U') IS NULL
             AND OBJECT_ID('grac_practice.sp_tprm_register_link', 'P') IS NULL
             AND OBJECT_ID('grac_practice.fn_tprm_register_overall') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'tprm-risk-register')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_list WHERE list_code = N'VENDOR_PROFILE_AREA')
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO

PRINT '524 rollback complete.';
GO
