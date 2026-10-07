-- =====================================================================
-- 432  Asset Verification Exceptions -- investigation of attestation
--      disagreements (Asset & Contract Management, Phase 4 increment 5a)
--
-- REQUEST
-- -------
--   BRD v1.7 5.3.5 ("Disagree: set Disputed / Exception; create exception
--   ..."; "Resolved as record correction: apply approved asset /
--   assignment correction; retain original response and exception
--   history"; "Resolved as lost / damaged / retired: update asset posture
--   only through the applicable incident, maintenance or retirement
--   workflow"), 5.3.7 exception fields and statuses (Open, Assigned, Under
--   Review, Awaiting Evidence, Awaiting Approval, Resolved, Closed,
--   Cancelled), 5.3.8 default assignment and SLA matrix ("configurable
--   defaults"), 5.3.9 SLA / escalation (timers start at creation;
--   reassignment does not reset the SLA; Level 1 / 2 / 3 at 7 / 15 / 30
--   overdue days; pause only for Awaiting Evidence with original and
--   revised due dates visible; closure blocked until evidence, resolution
--   and approval are complete), 5.3.10 lost-asset security review, 5.3.12
--   ("a disagreement submission creates one exception per attestation
--   response"). Plan in docs/asset-contract-management.md.
--   4.5 is split: 432 = verification exceptions (5.3.7-5.3.10); 433 =
--   owner change, location transfer, breakdown and disposal workflows (11).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_verification_sla_rule -- the 5.3.8 matrix seeded as global
--      defaults (primary assignment, supporting assignment, start /
--      resolution SLA, Lost immediate) plus closure approval / evidence
--      flags (D28); an organization may override a category.
--      asset_verification_settings -- per organization: asset
--      administrator, fallback team, escalation levels (7 / 15 / 30).
--   2. asset_verification_exception -- the 5.3.7 record: asset and
--      attestation (one exception per response -- unique), category,
--      description, reported by / date, criticality snapshot and severity
--      (Critical for a lost asset or a Critical asset -- D27), assigned
--      investigator (employee or team) from the rule with fallback, SLA rule
--      and start / original / revised resolution due dates, pause tracking,
--      lost-asset security review items (5.3.10), outcome, narrative,
--      closure evidence, approval and closure. Status on the state-machine
--      framework (entity AssetVerificationException, 8 BRD statuses,
--      transition log = escalation / status history).
--   3. sp_asset_verification_exception_create -- one exception per
--      disagreement; sp_asset_attestation_respond (431) re-issued to call it
--      (the occurrence moves to Exception); existing Disputed occurrences
--      get their exception now.
--   4. sp_asset_verification_exception_action -- Start review, Await
--      evidence (pauses the SLA; reason), Resume (revised due = original +
--      paused days), Resolve (controlled outcome + narrative; evidence and
--      security items when required; approval when required), Approve /
--      Reject (a different person), Close (posture check: a lost / damaged
--      / retired outcome needs the asset moved through its lifecycle
--      first -- 429; the occurrence becomes Resolved and the asset
--      Verified or Not verified), Reassign (no SLA reset), Cancel (reason).
--   5. Readers: exception list (all / mine) with SLA state and escalation
--      level, exception detail with history, settings + effective rules;
--      sp_asset_custody_get (431) re-issued with the asset's exceptions.
--
-- NOT DONE HERE: category tasks and their SLA timers, notifications and
--   escalation messages (Phase 6 -- the escalation level is calculated and
--   shown); security incident integration (5.3.10 "according to
--   integration configuration" -- none exists); business-day SLAs (D23);
--   approved SLA extensions.
--
-- ERROR NUMBERS: 54410-54449
--   54410 organization not found          54411 exception not found
--   54412 exception changed by someone else 54413 unknown action
--   54414 action not allowed in this status 54415 not the investigator
--   54416 note / reason required          54417 outcome required / invalid
--   54418 narrative required              54419 closure evidence required
--   54420 security review items required  54421 segregation of duties
--   54422 asset posture not updated yet   54423 investigator not valid
--   54424 rule values invalid             54425 settings values invalid
--   54426 settings changed by someone else
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   asset-attestation.cshtml / .js (Exceptions + Exception settings tabs),
--   asset-register.js (Custody tab), docs.
-- DEPENDS ON: 429, 431.
-- Rollback: 432_asset_verification_exceptions_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_attestation','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_attestation_respond','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_custody_get','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_attestation_next_date') IS NULL
   OR COL_LENGTH('grac_practice.asset_attestation','disagreement_category') IS NULL
BEGIN
    RAISERROR('ABORT (432): run 429 and 431 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Exception statuses (5.3.7) on the state-machine framework
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'AssetVerificationException', N'OPEN',              N'Open',              10, 0, 1),
    (N'AssetVerificationException', N'ASSIGNED',          N'Assigned',          20, 0, 1),
    (N'AssetVerificationException', N'UNDER_REVIEW',      N'Under Review',      30, 0, 0),
    (N'AssetVerificationException', N'AWAITING_EVIDENCE', N'Awaiting Evidence', 40, 0, 0),
    (N'AssetVerificationException', N'AWAITING_APPROVAL', N'Awaiting Approval', 50, 0, 0),
    (N'AssetVerificationException', N'RESOLVED',          N'Resolved',          60, 0, 0),
    (N'AssetVerificationException', N'CLOSED',            N'Closed',            70, 1, 0),
    (N'AssetVerificationException', N'CANCELLED',         N'Cancelled',         80, 1, 0)
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial,
            N'BRD v1.7 5.3.7 asset verification exception status.', N'seed-432');
PRINT CONCAT('432: exception statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'OPEN', 0, N'Created without an investigator (no rule or fallback resolved).'),
    (NULL, N'ASSIGNED', 0, N'Created and assigned from the assignment rule.'),
    (N'OPEN', N'ASSIGNED', 1, N'Investigator assigned.'),
    (N'ASSIGNED', N'ASSIGNED', 1, N'Reassigned (SLA not reset).'),
    (N'UNDER_REVIEW', N'UNDER_REVIEW', 1, N'Reassigned during review (SLA not reset).'),
    (N'AWAITING_EVIDENCE', N'AWAITING_EVIDENCE', 1, N'Reassigned while awaiting evidence (SLA not reset).'),
    (N'ASSIGNED', N'UNDER_REVIEW', 0, N'Investigation started.'),
    (N'UNDER_REVIEW', N'AWAITING_EVIDENCE', 1, N'Waiting for evidence; SLA paused.'),
    (N'AWAITING_EVIDENCE', N'UNDER_REVIEW', 0, N'Evidence received; SLA resumed with the revised due date.'),
    (N'UNDER_REVIEW', N'AWAITING_APPROVAL', 0, N'Resolution proposed; approval required.'),
    (N'UNDER_REVIEW', N'RESOLVED', 0, N'Resolved (no approval required).'),
    (N'AWAITING_APPROVAL', N'RESOLVED', 0, N'Resolution approved.'),
    (N'AWAITING_APPROVAL', N'UNDER_REVIEW', 1, N'Resolution rejected.'),
    (N'RESOLVED', N'CLOSED', 0, N'Closed.'),
    (N'OPEN', N'CANCELLED', 1, N'Cancelled.'),
    (N'ASSIGNED', N'CANCELLED', 1, N'Cancelled.'),
    (N'UNDER_REVIEW', N'CANCELLED', 1, N'Cancelled.'),
    (N'AWAITING_EVIDENCE', N'CANCELLED', 1, N'Cancelled.'),
    (N'AWAITING_APPROVAL', N'CANCELLED', 1, N'Cancelled.'),
    (N'RESOLVED', N'CANCELLED', 1, N'Cancelled.')
) AS s(from_status_code, to_status_code, requires_reason, description)
ON t.entity_type = N'AssetVerificationException'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'AssetVerificationException', s.from_status_code, s.to_status_code, NULL, s.requires_reason, 0, s.description, N'seed-432');
PRINT CONCAT('432: exception transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Configuration
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_verification_sla_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_verification_sla_rule (
        rule_id                   BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ver_rule PRIMARY KEY,
        organization_id           BIGINT        NULL,      -- NULL = BRD 5.3.8 default
        category                  NVARCHAR(40)  NOT NULL
            CONSTRAINT ck_pm_asset_ver_rule_cat CHECK (category IN (N'ASSET_NOT_FOUND', N'WRONG_CUSTODIAN', N'ASSET_RETURNED',
                N'ASSET_REPLACED', N'ASSET_DAMAGED', N'ASSET_LOST', N'LOCATION_INCORRECT', N'INFORMATION_INCORRECT',
                N'DUPLICATE_RECORD', N'ASSET_RETIRED', N'OTHER')),
        primary_assignment        NVARCHAR(30)  NOT NULL
            CONSTRAINT ck_pm_asset_ver_rule_primary CHECK (primary_assignment IN
                (N'ASSET_OWNER', N'ASSET_ADMINISTRATOR', N'MAINTENANCE_TEAM', N'SECURITY', N'FALLBACK_TEAM')),
        supporting_assignment     NVARCHAR(200) NULL,
        start_sla_days            INT           NOT NULL,
        start_immediate           BIT           NOT NULL CONSTRAINT df_pm_asset_ver_rule_imm DEFAULT 0,
        resolution_sla_days       INT           NOT NULL,
        closure_approval_required BIT           NOT NULL CONSTRAINT df_pm_asset_ver_rule_appr DEFAULT 0,
        closure_evidence_required BIT           NOT NULL CONSTRAINT df_pm_asset_ver_rule_ev DEFAULT 0,
        entered_by                NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ver_rule_eby DEFAULT N'system',
        entered_dt                DATETIME2     NOT NULL CONSTRAINT df_pm_asset_ver_rule_edt DEFAULT SYSUTCDATETIME(),
        updated_by                NVARCHAR(100) NULL,
        updated_dt                DATETIME2     NULL,
        CONSTRAINT ck_pm_asset_ver_rule_days CHECK (start_sla_days BETWEEN 0 AND 365 AND resolution_sla_days BETWEEN 1 AND 365
                                                    AND resolution_sla_days >= start_sla_days)
    );
    CREATE UNIQUE INDEX ux_pm_asset_ver_rule ON grac_practice.asset_verification_sla_rule(organization_id, category);
    PRINT '432: asset_verification_sla_rule created.';
END
GO

-- BRD 5.3.8 defaults (business days in the BRD; calendar days until a business calendar exists -- D23).
MERGE grac_practice.asset_verification_sla_rule AS t
USING (VALUES
    (N'ASSET_NOT_FOUND',       N'ASSET_OWNER',         N'Department Manager; Compliance Owner',            2, 0,  7, 1, 1),
    (N'WRONG_CUSTODIAN',       N'ASSET_OWNER',         N'Department Manager / Asset Administrator',        2, 0,  5, 0, 0),
    (N'ASSET_RETURNED',        N'ASSET_ADMINISTRATOR', N'Asset Owner',                                     1, 0,  3, 0, 0),
    (N'ASSET_REPLACED',        N'ASSET_ADMINISTRATOR', N'Asset Owner / Technical Owner',                   2, 0,  5, 0, 0),
    (N'ASSET_DAMAGED',         N'MAINTENANCE_TEAM',    N'Asset Owner',                                     2, 0, 10, 0, 1),
    (N'ASSET_LOST',            N'SECURITY',            N'Information Security Manager; Compliance Owner',  1, 1, 15, 1, 1),
    (N'LOCATION_INCORRECT',    N'ASSET_ADMINISTRATOR', N'Asset Owner / Site Coordinator',                  2, 0,  5, 0, 0),
    (N'INFORMATION_INCORRECT', N'ASSET_ADMINISTRATOR', N'Asset Owner / Data Steward',                      2, 0,  5, 0, 0),
    (N'DUPLICATE_RECORD',      N'ASSET_ADMINISTRATOR', N'Compliance Owner',                                2, 0, 10, 0, 0),
    (N'ASSET_RETIRED',         N'ASSET_OWNER',         N'Asset Administrator / Disposal Owner',            2, 0,  7, 1, 1),
    (N'OTHER',                 N'FALLBACK_TEAM',       N'Asset Owner / Compliance',                        2, 0, 10, 0, 0)
) AS s(category, primary_assignment, supporting_assignment, start_sla_days, start_immediate, resolution_sla_days,
       closure_approval_required, closure_evidence_required)
ON t.organization_id IS NULL AND t.category = s.category
WHEN NOT MATCHED BY TARGET THEN
    INSERT (organization_id, category, primary_assignment, supporting_assignment, start_sla_days, start_immediate,
            resolution_sla_days, closure_approval_required, closure_evidence_required, entered_by)
    VALUES (NULL, s.category, s.primary_assignment, s.supporting_assignment, s.start_sla_days, s.start_immediate,
            s.resolution_sla_days, s.closure_approval_required, s.closure_evidence_required, N'seed-432');
PRINT CONCAT('432: default SLA rules inserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_verification_settings','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_verification_settings (
        organization_id                 BIGINT        NOT NULL CONSTRAINT pk_pm_asset_ver_settings PRIMARY KEY,
        asset_administrator_employee_id BIGINT        NULL,
        fallback_team_id                BIGINT        NULL,
        escalation_level1_days          INT           NOT NULL CONSTRAINT df_pm_asset_ver_set_l1 DEFAULT 7,
        escalation_level2_days          INT           NOT NULL CONSTRAINT df_pm_asset_ver_set_l2 DEFAULT 15,
        escalation_level3_days          INT           NOT NULL CONSTRAINT df_pm_asset_ver_set_l3 DEFAULT 30,
        updated_by                      NVARCHAR(100) NULL,
        updated_dt                      DATETIME2     NULL,
        record_version                  ROWVERSION    NOT NULL,
        CONSTRAINT ck_pm_asset_ver_set_levels CHECK (escalation_level1_days >= 1 AND escalation_level2_days > escalation_level1_days
                                                     AND escalation_level3_days > escalation_level2_days)
    );
    PRINT '432: asset_verification_settings created.';
END
GO

-- =====================================================================
-- 3. The exception record (5.3.7)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_verification_exception','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_verification_exception (
        exception_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ver_exc PRIMARY KEY,
        organization_id         BIGINT         NOT NULL,
        asset_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ver_exc_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        attestation_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ver_exc_att REFERENCES grac_practice.asset_attestation(attestation_id),
        category                NVARCHAR(40)   NOT NULL,
        description             NVARCHAR(2000) NOT NULL,
        reported_by             NVARCHAR(100)  NOT NULL,
        reported_by_employee_id BIGINT         NULL,
        reported_dt             DATETIME2      NOT NULL,
        criticality_id          INT            NULL,
        criticality_name        NVARCHAR(80)   NULL,
        severity                NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_ver_exc_sev CHECK (severity IN (N'CRITICAL', N'STANDARD')),
        investigator_employee_id BIGINT        NULL,
        investigator_team_id    BIGINT         NULL,
        assignment_basis        NVARCHAR(60)   NULL,      -- which rule / fallback produced the investigator
        supporting_assignment   NVARCHAR(200)  NULL,
        sla_rule_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ver_exc_rule REFERENCES grac_practice.asset_verification_sla_rule(rule_id),
        start_due_date          DATE           NOT NULL,
        original_resolution_due DATE           NOT NULL,
        resolution_due          DATE           NOT NULL,
        pause_started_dt        DATETIME2      NULL,
        paused_days             INT            NOT NULL CONSTRAINT df_pm_asset_ver_exc_paused DEFAULT 0,
        started_dt              DATETIME2      NULL,
        current_status_id       INT            NOT NULL
            CONSTRAINT fk_pm_asset_ver_exc_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        approval_required       BIT            NOT NULL,
        evidence_required       BIT            NOT NULL,
        -- 5.3.10 lost-asset security review (DONE | NA)
        sec_remote_lock_wipe    NVARCHAR(4)    NULL,
        sec_credential_review   NVARCHAR(4)    NULL,
        sec_privacy_assessment  NVARCHAR(4)    NULL,
        sec_access_revocation   NVARCHAR(4)    NULL,
        sec_monitoring          NVARCHAR(4)    NULL,
        outcome                 NVARCHAR(30)   NULL
            CONSTRAINT ck_pm_asset_ver_exc_outcome CHECK (outcome IN (N'NO_CHANGE', N'RECORD_CORRECTION', N'LOST_CONFIRMED',
                N'DAMAGE_CONFIRMED', N'RETIREMENT_CONFIRMED', N'DUPLICATE_CONFIRMED', N'OTHER')),
        resolution_narrative    NVARCHAR(2000) NULL,
        closure_evidence        NVARCHAR(1000) NULL,
        resolved_by             NVARCHAR(100)  NULL,
        resolved_by_employee_id BIGINT         NULL,
        resolved_dt             DATETIME2      NULL,
        approved_by             NVARCHAR(100)  NULL,
        approved_by_employee_id BIGINT         NULL,
        approved_dt             DATETIME2      NULL,
        closed_dt               DATETIME2      NULL,
        last_note               NVARCHAR(1000) NULL,
        updated_by              NVARCHAR(100)  NULL,
        updated_dt              DATETIME2      NULL,
        record_version          ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_ver_exc_sec CHECK (
            ISNULL(sec_remote_lock_wipe, N'NA') IN (N'DONE', N'NA') AND ISNULL(sec_credential_review, N'NA') IN (N'DONE', N'NA')
            AND ISNULL(sec_privacy_assessment, N'NA') IN (N'DONE', N'NA') AND ISNULL(sec_access_revocation, N'NA') IN (N'DONE', N'NA')
            AND ISNULL(sec_monitoring, N'NA') IN (N'DONE', N'NA'))
    );
    -- 5.3.12: one exception per attestation response.
    CREATE UNIQUE INDEX ux_pm_asset_ver_exc_att ON grac_practice.asset_verification_exception(attestation_id);
    CREATE INDEX ix_pm_asset_ver_exc_org ON grac_practice.asset_verification_exception(organization_id, current_status_id, resolution_due);
    CREATE INDEX ix_pm_asset_ver_exc_asset ON grac_practice.asset_verification_exception(asset_id);
    PRINT '432: asset_verification_exception created.';
END
GO

-- =====================================================================
-- 4. Creation (one per disagreement)
-- =====================================================================
-- Effective SLA rule of a category: the organization override, else the default.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_verification_rule (@organization_id BIGINT, @category NVARCHAR(40))
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 r.rule_id AS RuleId, r.primary_assignment AS PrimaryAssignment, r.supporting_assignment AS SupportingAssignment,
           r.start_sla_days AS StartSlaDays, r.start_immediate AS StartImmediate, r.resolution_sla_days AS ResolutionSlaDays,
           r.closure_approval_required AS ClosureApprovalRequired, r.closure_evidence_required AS ClosureEvidenceRequired,
           CASE WHEN r.organization_id IS NULL THEN 0 ELSE 1 END AS IsOverride
      FROM grac_practice.asset_verification_sla_rule r
     WHERE r.category = @category AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
     ORDER BY CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_exception_create
    @attestation_id   BIGINT,
    @actor            NVARCHAR(100) = N'system',
    @out_exception_id BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @out_exception_id = (SELECT exception_id FROM grac_practice.asset_verification_exception WHERE attestation_id = @attestation_id);
    IF @out_exception_id IS NOT NULL RETURN;      -- 5.3.12: one per response

    DECLARE @org BIGINT, @asset BIGINT, @category NVARCHAR(40), @comments NVARCHAR(2000), @by NVARCHAR(100), @by_emp BIGINT,
            @response_dt DATETIME2, @status NVARCHAR(20);
    SELECT @org = organization_id, @asset = asset_id, @category = disagreement_category, @comments = comments,
           @by = attested_by, @by_emp = attested_by_employee_id, @response_dt = response_dt, @status = status
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id;
    IF @category IS NULL OR @status NOT IN (N'DISPUTED', N'EXCEPTION') RETURN;

    DECLARE @rule BIGINT, @primary NVARCHAR(30), @supporting NVARCHAR(200), @start_days INT, @immediate BIT, @res_days INT,
            @appr BIT, @ev BIT;
    SELECT @rule = RuleId, @primary = PrimaryAssignment, @supporting = SupportingAssignment, @start_days = StartSlaDays,
           @immediate = StartImmediate, @res_days = ResolutionSlaDays, @appr = ClosureApprovalRequired, @ev = ClosureEvidenceRequired
      FROM grac_practice.fn_asset_verification_rule(@org, @category);

    -- Criticality snapshot and severity (D27).
    DECLARE @crit_id INT, @crit_name NVARCHAR(80), @crit_code NVARCHAR(40), @owner BIGINT;
    SELECT @crit_id = a.criticality_id, @crit_name = c.criticality_name, @crit_code = c.criticality_code, @owner = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
     WHERE a.asset_id = @asset;
    DECLARE @severity NVARCHAR(20) = CASE WHEN @category = N'ASSET_LOST' OR @crit_code = N'Critical' THEN N'CRITICAL' ELSE N'STANDARD' END;

    -- Investigator: the primary assignment of the rule, then the fallback team, the asset administrator, the asset owner.
    DECLARE @v TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @v (field_key, val)
    SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset)
     WHERE FieldKey IN (N'maintenance_owner', N'support_group', N'information_security_owner');
    DECLARE @admin BIGINT, @fallback_team BIGINT;
    SELECT @admin = asset_administrator_employee_id, @fallback_team = fallback_team_id
      FROM grac_practice.asset_verification_settings WHERE organization_id = @org;
    DECLARE @pick NVARCHAR(40) = CASE @primary
        WHEN N'ASSET_OWNER' THEN N'E:' + CAST(@owner AS NVARCHAR(30))
        WHEN N'ASSET_ADMINISTRATOR' THEN N'E:' + CAST(@admin AS NVARCHAR(30))
        WHEN N'MAINTENANCE_TEAM' THEN COALESCE(LEFT((SELECT val FROM @v WHERE field_key = N'maintenance_owner'), 40),
                                               N'T:' + LEFT((SELECT val FROM @v WHERE field_key = N'support_group'), 30))
        WHEN N'SECURITY' THEN COALESCE(LEFT((SELECT val FROM @v WHERE field_key = N'information_security_owner'), 40),
                                       N'E:' + CAST(@owner AS NVARCHAR(30)))
        WHEN N'FALLBACK_TEAM' THEN N'T:' + CAST(@fallback_team AS NVARCHAR(30)) END;
    DECLARE @basis NVARCHAR(60) = @primary;
    IF @pick IS NULL AND @fallback_team IS NOT NULL SELECT @pick = N'T:' + CAST(@fallback_team AS NVARCHAR(30)), @basis = N'FALLBACK_TEAM';
    IF @pick IS NULL AND @admin IS NOT NULL SELECT @pick = N'E:' + CAST(@admin AS NVARCHAR(30)), @basis = N'ASSET_ADMINISTRATOR';
    IF @pick IS NULL AND @owner IS NOT NULL SELECT @pick = N'E:' + CAST(@owner AS NVARCHAR(30)), @basis = N'ASSET_OWNER';
    DECLARE @inv_emp BIGINT = CASE WHEN @pick LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@pick, 3, 38)) END,
            @inv_team BIGINT = CASE WHEN @pick LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@pick, 3, 38)) END;
    IF @inv_emp IS NULL AND @inv_team IS NULL SET @basis = NULL;

    DECLARE @reported DATE = CAST(ISNULL(@response_dt, SYSUTCDATETIME()) AS DATE);
    DECLARE @to NVARCHAR(60) = CASE WHEN @basis IS NULL THEN N'OPEN' ELSE N'ASSIGNED' END;
    DECLARE @to_id INT = grac_practice.fn_get_entity_status_id(N'AssetVerificationException', @to), @log BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_verification_exception
        (organization_id, asset_id, attestation_id, category, description, reported_by, reported_by_employee_id, reported_dt,
         criticality_id, criticality_name, severity, investigator_employee_id, investigator_team_id, assignment_basis,
         supporting_assignment, sla_rule_id, start_due_date, original_resolution_due, resolution_due, current_status_id,
         approval_required, evidence_required, updated_by, updated_dt)
    VALUES (@org, @asset, @attestation_id, @category, ISNULL(@comments, N'(no description)'), ISNULL(@by, @actor), @by_emp,
            ISNULL(@response_dt, SYSUTCDATETIME()), @crit_id, @crit_name, @severity, @inv_emp, @inv_team, @basis,
            @supporting, @rule, CASE WHEN @immediate = 1 THEN @reported ELSE DATEADD(DAY, @start_days, @reported) END,
            DATEADD(DAY, @res_days, @reported), DATEADD(DAY, @res_days, @reported), @to_id,
            @appr, @ev, @actor, SYSUTCDATETIME());
    SET @out_exception_id = SCOPE_IDENTITY();
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetVerificationException', @entity_id = @out_exception_id,
         @from_status_code = NULL, @to_status_code = @to, @actor_employee_id = @by_emp, @actor_role_code = NULL,
         @reason_code = N'CREATED', @reason_text = @basis,
         @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
    UPDATE grac_practice.asset_attestation
       SET status = N'EXCEPTION', updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    COMMIT;
END
GO
PRINT '432: exception creation created.';
GO

-- =====================================================================
-- 5. sp_asset_attestation_respond (431) re-issued -- marked 432
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_respond
    @organization_id         BIGINT,
    @attestation_id          BIGINT,
    @response                NVARCHAR(10),
    @asset_exists            BIT            = NULL,
    @custody_confirmed       BIT            = NULL,
    @location_verified       BIT            = NULL,
    @tag_verified            BIT            = NULL,
    @serial_verified         BIT            = NULL,
    @assigned_user_verified  BIT            = NULL,
    @information_correct     BIT            = NULL,
    @business_use_confirmed  BIT            = NULL,
    @condition_code          NVARCHAR(30)   = NULL,
    @disagreement_category   NVARCHAR(40)   = NULL,
    @comments                NVARCHAR(2000) = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @channel                 NVARCHAR(30)   = N'Web',
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @response = UPPER(LTRIM(RTRIM(ISNULL(@response, N''))));
    SET @condition_code = UPPER(NULLIF(LTRIM(RTRIM(@condition_code)), N''));
    SET @disagreement_category = UPPER(NULLIF(LTRIM(RTRIM(@disagreement_category)), N''));
    SET @comments = NULLIF(LTRIM(RTRIM(@comments)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');
    SET @channel = ISNULL(NULLIF(LTRIM(RTRIM(@channel)), N''), N'Web');

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @emp BIGINT, @team BIGINT, @evidence_req NVARCHAR(20), @mgr BIT, @asset_id BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @emp = assignee_employee_id, @team = assignee_team_id,
           @evidence_req = evidence_requirement, @mgr = manager_approval_required, @asset_id = asset_id
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54357, 'Attestation not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54358, 'This attestation was changed by someone else. Reload and try again.', 1;
    IF @status NOT IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE')
        THROW 54359, 'This attestation is not open for a response.', 1;
    -- 5.3.2: no response on behalf of another custodian (no delegated authority is configured).
    IF @actor_employee_id IS NULL
       OR NOT (@actor_employee_id = @emp
               OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                           WHERE m.team_id = @team AND m.employee_id = @actor_employee_id AND m.status = N'Active'))
        THROW 54360, 'Only the assigned custodian or owner (or a member of the assigned team) can respond to this attestation.', 1;
    IF @response NOT IN (N'CONFIRM', N'DISAGREE')
        THROW 54361, 'The response must be Confirm or Disagree.', 1;
    IF @condition_code IS NULL OR @condition_code NOT IN
        (N'GOOD', N'FAIR', N'POOR', N'DAMAGED', N'LOST', N'NOT_FOUND', N'RETURNED', N'REPLACED', N'RETIRED')
        THROW 54362, 'Select the condition of the asset.', 1;
    IF @response = N'CONFIRM'
    BEGIN
        IF ISNULL(@asset_exists, 0) = 0 OR ISNULL(@custody_confirmed, 0) = 0 OR @condition_code IN (N'LOST', N'NOT_FOUND')
            THROW 54366, 'A confirmation needs the asset to exist and custody confirmed; a lost or missing asset is a disagreement.', 1;
        -- Conditional confirmation: a check left open or a condition other than Good needs a comment.
        IF @comments IS NULL AND (@condition_code <> N'GOOD' OR ISNULL(@location_verified, 0) = 0 OR ISNULL(@tag_verified, 0) = 0
               OR ISNULL(@serial_verified, 0) = 0 OR ISNULL(@assigned_user_verified, 0) = 0 OR ISNULL(@information_correct, 0) = 0
               OR ISNULL(@business_use_confirmed, 0) = 0)
            THROW 54364, 'Add a comment explaining the checks not confirmed or the condition.', 1;
        SET @disagreement_category = NULL;
    END
    ELSE
    BEGIN
        IF @disagreement_category IS NULL OR @disagreement_category NOT IN
            (N'ASSET_NOT_FOUND', N'WRONG_CUSTODIAN', N'ASSET_RETURNED', N'ASSET_REPLACED', N'ASSET_DAMAGED', N'ASSET_LOST',
             N'LOCATION_INCORRECT', N'INFORMATION_INCORRECT', N'DUPLICATE_RECORD', N'ASSET_RETIRED', N'OTHER')
            THROW 54363, 'Select the disagreement category.', 1;
        IF @comments IS NULL
            THROW 54364, 'Explain the disagreement in the comments.', 1;
    END
    IF @evidence_req = N'MANDATORY' AND @evidence_text IS NULL
        THROW 54365, 'Evidence is required for this attestation (photo, scan, document or other reference).', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT status, response, condition_code, disagreement_category, comments
                                       FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @new_status NVARCHAR(20) = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED'
                                            WHEN @mgr = 1 THEN N'CONFIRMED' ELSE N'CLOSED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET response = @response, asset_exists = @asset_exists, custody_confirmed = @custody_confirmed,
           location_verified = @location_verified, tag_verified = @tag_verified, serial_verified = @serial_verified,
           assigned_user_verified = @assigned_user_verified, information_correct = @information_correct,
           business_use_confirmed = @business_use_confirmed, condition_code = @condition_code,
           disagreement_category = @disagreement_category, comments = @comments, evidence_text = @evidence_text,
           attested_by = @actor, attested_by_employee_id = @actor_employee_id, channel = @channel, response_dt = SYSUTCDATETIME(),
           status = CASE WHEN @new_status = N'CLOSED' THEN N'CONFIRMED' ELSE @new_status END,
           verification_status = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED' END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    IF @new_status = N'CLOSED'
        EXEC grac_practice.sp_asset_attestation_close_verified @attestation_id = @attestation_id, @actor = @actor;
    IF @response = N'DISAGREE'
        MERGE grac_practice.asset_attestation_state AS t
        USING (SELECT @asset_id AS asset_id) AS s ON t.asset_id = s.asset_id
        WHEN MATCHED THEN UPDATE SET verification_status = N'DISPUTED', last_attestation_id = @attestation_id,
                                     updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (asset_id, organization_id, verification_status, last_attestation_id, updated_by, updated_dt)
                              VALUES (@asset_id, @organization_id, N'DISPUTED', @attestation_id, @actor, SYSUTCDATETIME());
    -- 432: a disagreement opens one Asset Verification Exception (5.3.5 / 5.3.12).
    DECLARE @exc_id BIGINT;
    IF @response = N'DISAGREE'
        EXEC grac_practice.sp_asset_verification_exception_create
             @attestation_id = @attestation_id, @actor = @actor, @out_exception_id = @exc_id OUTPUT;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation', @attestation_id, @response, @before,
            (SELECT @response AS response, @new_status AS status, @condition_code AS conditionCode,
                    @disagreement_category AS disagreementCategory, @comments AS comments, @evidence_text AS evidence,
                    @asset_exists AS assetExists, @custody_confirmed AS custodyConfirmed, @location_verified AS locationVerified,
                    @tag_verified AS tagVerified, @serial_verified AS serialVerified, @assigned_user_verified AS assignedUserVerified,
                    @information_correct AS informationCorrect, @business_use_confirmed AS businessUseConfirmed, @channel AS channel
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @attestation_id AS AttestationId, CASE WHEN @exc_id IS NOT NULL THEN N'EXCEPTION' ELSE @new_status END AS Result,
           @exc_id AS ExceptionId;
END
GO
PRINT '432: sp_asset_attestation_respond re-issued.';
GO

-- Existing disagreements (431) get their exception now.
DECLARE @att BIGINT, @exc BIGINT, @n INT = 0;
DECLARE att_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.attestation_id FROM grac_practice.asset_attestation a
     WHERE a.status = N'DISPUTED' AND a.disagreement_category IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_verification_exception x WHERE x.attestation_id = a.attestation_id);
OPEN att_cur;
FETCH NEXT FROM att_cur INTO @att;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_asset_verification_exception_create @attestation_id = @att, @actor = N'seed-432', @out_exception_id = @exc OUTPUT;
    SET @n = @n + 1;
    FETCH NEXT FROM att_cur INTO @att;
END
CLOSE att_cur;
DEALLOCATE att_cur;
PRINT CONCAT('432: exceptions created for existing disagreements: ', @n);
GO

-- =====================================================================
-- 6. Investigation actions
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_exception_action
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
    @outcome                 NVARCHAR(30)   = NULL,
    @narrative               NVARCHAR(2000) = NULL,
    @closure_evidence        NVARCHAR(1000) = NULL,
    @sec_remote_lock_wipe    NVARCHAR(4)    = NULL,
    @sec_credential_review   NVARCHAR(4)    = NULL,
    @sec_privacy_assessment  NVARCHAR(4)    = NULL,
    @sec_access_revocation   NVARCHAR(4)    = NULL,
    @sec_monitoring          NVARCHAR(4)    = NULL,
    @investigator            NVARCHAR(40)   = NULL,     -- REASSIGN: E:<employee_id> | T:<team_id>
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    SET @outcome = UPPER(NULLIF(LTRIM(RTRIM(@outcome)), N''));
    SET @narrative = NULLIF(LTRIM(RTRIM(@narrative)), N'');
    SET @closure_evidence = NULLIF(LTRIM(RTRIM(@closure_evidence)), N'');
    SET @investigator = NULLIF(LTRIM(RTRIM(@investigator)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54410, 'Organization not found.', 1;
    DECLARE @found BIT = 0, @status NVARCHAR(60), @rv BIGINT, @inv_emp BIGINT, @inv_team BIGINT, @appr BIT, @ev BIT,
            @category NVARCHAR(40), @asset BIGINT, @att BIGINT, @resolved_by NVARCHAR(100), @resolved_emp BIGINT,
            @pause DATETIME2, @cur_outcome NVARCHAR(30);
    SELECT @found = 1, @status = s.status_code, @rv = CONVERT(BIGINT, x.record_version), @inv_emp = x.investigator_employee_id,
           @inv_team = x.investigator_team_id, @appr = x.approval_required, @ev = x.evidence_required, @category = x.category,
           @asset = x.asset_id, @att = x.attestation_id, @resolved_by = x.resolved_by, @resolved_emp = x.resolved_by_employee_id,
           @pause = x.pause_started_dt, @cur_outcome = x.outcome
      FROM grac_practice.asset_verification_exception x
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
     WHERE x.exception_id = @exception_id AND x.organization_id = @organization_id;
    IF @found = 0 THROW 54411, 'Verification exception not found for this organization.', 1;
    IF @action NOT IN (N'START_REVIEW', N'AWAIT_EVIDENCE', N'RESUME', N'RESOLVE', N'APPROVE', N'REJECT', N'CLOSE', N'REASSIGN', N'CANCEL')
        THROW 54413, 'Unknown action.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54412, 'This exception was changed by someone else. Reload and try again.', 1;

    DECLARE @to NVARCHAR(60) = CASE
        WHEN @action = N'START_REVIEW'   AND @status = N'ASSIGNED' THEN N'UNDER_REVIEW'
        WHEN @action = N'AWAIT_EVIDENCE' AND @status = N'UNDER_REVIEW' THEN N'AWAITING_EVIDENCE'
        WHEN @action = N'RESUME'         AND @status = N'AWAITING_EVIDENCE' THEN N'UNDER_REVIEW'
        WHEN @action = N'RESOLVE'        AND @status = N'UNDER_REVIEW' THEN CASE WHEN @appr = 1 THEN N'AWAITING_APPROVAL' ELSE N'RESOLVED' END
        WHEN @action = N'APPROVE'        AND @status = N'AWAITING_APPROVAL' THEN N'RESOLVED'
        WHEN @action = N'REJECT'         AND @status = N'AWAITING_APPROVAL' THEN N'UNDER_REVIEW'
        WHEN @action = N'CLOSE'          AND @status = N'RESOLVED' THEN N'CLOSED'
        WHEN @action = N'REASSIGN'       AND @status = N'OPEN' THEN N'ASSIGNED'
        WHEN @action = N'REASSIGN'       AND @status IN (N'ASSIGNED', N'UNDER_REVIEW', N'AWAITING_EVIDENCE') THEN @status
        WHEN @action = N'CANCEL'         AND @status NOT IN (N'CLOSED', N'CANCELLED') THEN N'CANCELLED' END;
    IF @to IS NULL
        THROW 54414, 'This action is not allowed in the current status of the exception.', 1;

    -- The investigator (or a member of the investigator team) works the case.
    IF @action IN (N'START_REVIEW', N'AWAIT_EVIDENCE', N'RESUME', N'RESOLVE', N'CLOSE')
       AND NOT (@actor_employee_id IS NOT NULL
                AND (@actor_employee_id = @inv_emp
                     OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                                 WHERE m.team_id = @inv_team AND m.employee_id = @actor_employee_id AND m.status = N'Active')))
        THROW 54415, 'Only the assigned investigator (or a member of the assigned team) can do this.', 1;
    IF @action IN (N'APPROVE', N'REJECT')
       AND (@resolved_by = @actor OR (@resolved_emp IS NOT NULL AND @resolved_emp = @actor_employee_id))
        THROW 54421, 'Segregation of duties: the person who resolved this exception cannot approve or reject it.', 1;
    IF @action IN (N'AWAIT_EVIDENCE', N'REJECT', N'REASSIGN', N'CANCEL') AND @note IS NULL
        THROW 54416, 'Give the reason for this action.', 1;

    IF @action = N'RESOLVE'
    BEGIN
        IF @outcome IS NULL OR @outcome NOT IN (N'NO_CHANGE', N'RECORD_CORRECTION', N'LOST_CONFIRMED', N'DAMAGE_CONFIRMED',
                                                N'RETIREMENT_CONFIRMED', N'DUPLICATE_CONFIRMED', N'OTHER')
            THROW 54417, 'Select the outcome of the investigation.', 1;
        IF @narrative IS NULL
            THROW 54418, 'Describe the resolution.', 1;
        IF @ev = 1 AND @closure_evidence IS NULL
            THROW 54419, 'Closure evidence is required for this exception.', 1;
        -- 5.3.10: every security review item answered (Done or Not applicable) for a lost asset.
        IF @category = N'ASSET_LOST'
           AND (ISNULL(@sec_remote_lock_wipe, N'') NOT IN (N'DONE', N'NA') OR ISNULL(@sec_credential_review, N'') NOT IN (N'DONE', N'NA')
                OR ISNULL(@sec_privacy_assessment, N'') NOT IN (N'DONE', N'NA') OR ISNULL(@sec_access_revocation, N'') NOT IN (N'DONE', N'NA')
                OR ISNULL(@sec_monitoring, N'') NOT IN (N'DONE', N'NA'))
            THROW 54420, 'Record the lost-asset security review: remote lock / wipe, credential and token exposure, data-loss / privacy, access revocation and monitoring (Done or Not applicable).', 1;
    END

    -- 5.3.5: a lost / damaged / retired outcome changes the asset only through its lifecycle (429).
    IF @action = N'CLOSE' AND @cur_outcome IN (N'LOST_CONFIRMED', N'DAMAGE_CONFIRMED', N'RETIREMENT_CONFIRMED')
    BEGIN
        DECLARE @asset_status NVARCHAR(60) = (SELECT s.status_code FROM grac_practice.organization_dependency_asset a
                                                JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                                               WHERE a.asset_id = @asset);
        DECLARE @pending_to NVARCHAR(60) = (SELECT to_status_code FROM grac_practice.asset_lifecycle_change
                                             WHERE asset_id = @asset AND change_status = N'PENDING_APPROVAL');
        DECLARE @retirement BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_status_phase
                                                     WHERE phase_code = N'RETIREMENT' AND status_code IN (@asset_status, ISNULL(@pending_to, N'')))
                                       THEN 1 ELSE 0 END;
        IF NOT (   (@cur_outcome = N'LOST_CONFIRMED' AND (@retirement = 1 OR @asset_status IN (N'LOST', N'STOLEN') OR @pending_to IN (N'LOST', N'STOLEN')))
                OR (@cur_outcome = N'DAMAGE_CONFIRMED' AND (@retirement = 1
                        OR @asset_status IN (N'MAINTENANCE', N'REPAIR', N'OUT_OF_SERVICE', N'QUARANTINED')
                        OR @pending_to IN (N'MAINTENANCE', N'REPAIR', N'OUT_OF_SERVICE', N'QUARANTINED')))
                OR (@cur_outcome = N'RETIREMENT_CONFIRMED' AND @retirement = 1))
            THROW 54422, 'Move the asset through its lifecycle first (Asset Register -> Lifecycle: Lost, Repair / Maintenance or Pending Decommission); the exception closes after that.', 1;
    END

    DECLARE @new_emp BIGINT, @new_team BIGINT;
    IF @action = N'REASSIGN'
    BEGIN
        SET @new_emp = CASE WHEN @investigator LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@investigator, 3, 38)) END;
        SET @new_team = CASE WHEN @investigator LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@investigator, 3, 38)) END;
        IF NOT (   (@new_emp IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                      WHERE employee_id = @new_emp AND organization_id = @organization_id AND status = N'Active'))
                OR (@new_team IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_team
                                                       WHERE team_id = @new_team AND organization_id = @organization_id AND status = N'Active')))
            THROW 54423, 'Select an active employee or team of this organization as investigator.', 1;
    END

    DECLARE @paused INT = CASE WHEN @action = N'RESUME' AND @pause IS NOT NULL
                               THEN CASE WHEN DATEDIFF(DAY, @pause, SYSUTCDATETIME()) > 0 THEN DATEDIFF(DAY, @pause, SYSUTCDATETIME()) ELSE 0 END
                               ELSE 0 END;
    DECLARE @to_id INT, @log BIGINT, @reason_code NVARCHAR(60) = @action;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetVerificationException', @entity_id = @exception_id,
         @from_status_code = @status, @to_status_code = @to, @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @note,
         @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
    UPDATE grac_practice.asset_verification_exception
       SET current_status_id = @to_id,
           started_dt = CASE WHEN @action = N'START_REVIEW' AND started_dt IS NULL THEN SYSUTCDATETIME() ELSE started_dt END,
           pause_started_dt = CASE WHEN @action = N'AWAIT_EVIDENCE' THEN SYSUTCDATETIME() WHEN @action IN (N'RESUME', N'CANCEL') THEN NULL ELSE pause_started_dt END,
           paused_days = paused_days + @paused,
           resolution_due = DATEADD(DAY, @paused, resolution_due),                       -- 5.3.9 revised due; original kept
           investigator_employee_id = CASE WHEN @action = N'REASSIGN' THEN @new_emp ELSE investigator_employee_id END,
           investigator_team_id = CASE WHEN @action = N'REASSIGN' THEN @new_team ELSE investigator_team_id END,
           assignment_basis = CASE WHEN @action = N'REASSIGN' THEN N'REASSIGNED' ELSE assignment_basis END,
           outcome = CASE WHEN @action = N'RESOLVE' THEN @outcome WHEN @action = N'REJECT' THEN NULL ELSE outcome END,
           resolution_narrative = CASE WHEN @action = N'RESOLVE' THEN @narrative ELSE resolution_narrative END,
           closure_evidence = CASE WHEN @action = N'RESOLVE' THEN @closure_evidence ELSE closure_evidence END,
           sec_remote_lock_wipe = CASE WHEN @action = N'RESOLVE' THEN @sec_remote_lock_wipe ELSE sec_remote_lock_wipe END,
           sec_credential_review = CASE WHEN @action = N'RESOLVE' THEN @sec_credential_review ELSE sec_credential_review END,
           sec_privacy_assessment = CASE WHEN @action = N'RESOLVE' THEN @sec_privacy_assessment ELSE sec_privacy_assessment END,
           sec_access_revocation = CASE WHEN @action = N'RESOLVE' THEN @sec_access_revocation ELSE sec_access_revocation END,
           sec_monitoring = CASE WHEN @action = N'RESOLVE' THEN @sec_monitoring ELSE sec_monitoring END,
           resolved_by = CASE WHEN @action = N'RESOLVE' THEN @actor WHEN @action = N'REJECT' THEN NULL ELSE resolved_by END,
           resolved_by_employee_id = CASE WHEN @action = N'RESOLVE' THEN @actor_employee_id WHEN @action = N'REJECT' THEN NULL ELSE resolved_by_employee_id END,
           resolved_dt = CASE WHEN @action = N'RESOLVE' THEN SYSUTCDATETIME() WHEN @action = N'REJECT' THEN NULL ELSE resolved_dt END,
           approved_by = CASE WHEN @action = N'APPROVE' THEN @actor ELSE approved_by END,
           approved_by_employee_id = CASE WHEN @action = N'APPROVE' THEN @actor_employee_id ELSE approved_by_employee_id END,
           approved_dt = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() ELSE approved_dt END,
           closed_dt = CASE WHEN @to IN (N'CLOSED', N'CANCELLED') THEN SYSUTCDATETIME() ELSE closed_dt END,
           last_note = ISNULL(@note, last_note), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE exception_id = @exception_id;

    IF @to IN (N'CLOSED', N'CANCELLED')
    BEGIN
        -- The occurrence keeps the original response (5.3.12) and becomes Resolved / Cancelled.
        UPDATE grac_practice.asset_attestation
           SET status = CASE WHEN @to = N'CLOSED' THEN N'RESOLVED' ELSE N'CANCELLED' END, closed_dt = SYSUTCDATETIME(),
               decision_note = CASE WHEN @to = N'CANCELLED' THEN @note ELSE decision_note END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE attestation_id = @att;
        IF @to = N'CLOSED'
        BEGIN
            DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
            DECLARE @next DATE = (SELECT grac_practice.fn_asset_attestation_next_date(@today, p.frequency, p.custom_interval_days)
                                    FROM grac_practice.asset_attestation t
                                    JOIN grac_practice.asset_attestation_profile p ON p.profile_id = t.profile_id
                                   WHERE t.attestation_id = @att);
            DECLARE @verified BIT = CASE WHEN @cur_outcome IN (N'NO_CHANGE', N'RECORD_CORRECTION') THEN 1 ELSE 0 END;
            UPDATE grac_practice.asset_attestation_state
               SET verification_status = CASE WHEN @verified = 1 THEN N'VERIFIED' ELSE N'NOT_VERIFIED' END,
                   next_attestation_date = CASE WHEN @verified = 1 THEN @next ELSE next_attestation_date END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE asset_id = @asset AND last_attestation_id = @att;
        END
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-verification-exception', @exception_id, @action,
            (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @to AS status, @note AS note, @outcome AS outcome, @narrative AS narrative, @closure_evidence AS closureEvidence,
                    @investigator AS investigator, @paused AS pausedDays FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @exception_id AS ExceptionId, @to AS Result;
END
GO
PRINT '432: exception actions created.';
GO

-- =====================================================================
-- 7. Readers
-- =====================================================================
-- One display shape for the list and the detail: SLA state and the
-- 5.3.9 escalation level (overdue days against the organization levels).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_verification_exception_view (@organization_id BIGINT, @actor_employee_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT x.exception_id AS ExceptionId, x.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
           x.attestation_id AS AttestationId, x.category AS Category, x.description AS Description,
           x.reported_by AS ReportedBy, rep.employee_name AS ReportedByName, x.reported_dt AS ReportedDt,
           x.criticality_name AS CriticalityName, x.severity AS Severity,
           x.investigator_employee_id AS InvestigatorEmployeeId, x.investigator_team_id AS InvestigatorTeamId,
           COALESCE(ie.employee_name, it.team_name + N' (team)') AS InvestigatorName, x.assignment_basis AS AssignmentBasis,
           x.supporting_assignment AS SupportingAssignment,
           x.start_due_date AS StartDueDate, x.started_dt AS StartedDt, x.original_resolution_due AS OriginalResolutionDue,
           x.resolution_due AS ResolutionDue, x.paused_days AS PausedDays, x.pause_started_dt AS PauseStartedDt,
           s.status_code AS StatusCode, s.status_name AS StatusName, x.approval_required AS ApprovalRequired,
           x.evidence_required AS EvidenceRequired,
           x.sec_remote_lock_wipe AS SecRemoteLockWipe, x.sec_credential_review AS SecCredentialReview,
           x.sec_privacy_assessment AS SecPrivacyAssessment, x.sec_access_revocation AS SecAccessRevocation, x.sec_monitoring AS SecMonitoring,
           x.outcome AS Outcome, x.resolution_narrative AS ResolutionNarrative, x.closure_evidence AS ClosureEvidence,
           x.resolved_by AS ResolvedBy, rs.employee_name AS ResolvedByName, x.resolved_dt AS ResolvedDt,
           x.approved_by AS ApprovedBy, ap.employee_name AS ApprovedByName, x.approved_dt AS ApprovedDt,
           x.closed_dt AS ClosedDt, x.last_note AS LastNote,
           CASE WHEN s.is_terminal = 0 AND x.started_dt IS NULL AND s.status_code IN (N'OPEN', N'ASSIGNED')
                     AND x.start_due_date < CAST(SYSUTCDATETIME() AS DATE) THEN 1 ELSE 0 END AS StartOverdue,
           CASE WHEN s.is_terminal = 0 AND s.status_code NOT IN (N'RESOLVED', N'AWAITING_EVIDENCE')
                     AND x.resolution_due < CAST(SYSUTCDATETIME() AS DATE)
                THEN DATEDIFF(DAY, x.resolution_due, CAST(SYSUTCDATETIME() AS DATE)) ELSE 0 END AS OverdueDays,
           CASE WHEN s.is_terminal = 1 OR s.status_code IN (N'RESOLVED', N'AWAITING_EVIDENCE')
                     OR x.resolution_due >= CAST(SYSUTCDATETIME() AS DATE) THEN 0
                WHEN DATEDIFF(DAY, x.resolution_due, CAST(SYSUTCDATETIME() AS DATE)) >= ISNULL(st.escalation_level3_days, 30) THEN 3
                WHEN DATEDIFF(DAY, x.resolution_due, CAST(SYSUTCDATETIME() AS DATE)) >= ISNULL(st.escalation_level2_days, 15) THEN 2
                WHEN DATEDIFF(DAY, x.resolution_due, CAST(SYSUTCDATETIME() AS DATE)) >= ISNULL(st.escalation_level1_days, 7) THEN 1
                ELSE 0 END AS EscalationLevel,
           CASE WHEN @actor_employee_id IS NOT NULL
                     AND (@actor_employee_id = x.investigator_employee_id
                          OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                                      WHERE m.team_id = x.investigator_team_id AND m.employee_id = @actor_employee_id AND m.status = N'Active'))
                THEN 1 ELSE 0 END AS IsInvestigator,
           CASE WHEN s.status_code = N'AWAITING_APPROVAL' AND ISNULL(x.resolved_by_employee_id, -1) <> ISNULL(@actor_employee_id, -2)
                THEN 1 ELSE 0 END AS CanDecide,
           CONVERT(BIGINT, x.record_version) AS RecordVersion
      FROM grac_practice.asset_verification_exception x
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.organization_employee rep ON rep.employee_id = x.reported_by_employee_id
      LEFT JOIN grac_practice.organization_employee ie ON ie.employee_id = x.investigator_employee_id
      LEFT JOIN grac_practice.organization_team it ON it.team_id = x.investigator_team_id
      LEFT JOIN grac_practice.organization_employee rs ON rs.employee_id = x.resolved_by_employee_id
      LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = x.approved_by_employee_id
      LEFT JOIN grac_practice.asset_verification_settings st ON st.organization_id = x.organization_id
     WHERE x.organization_id = @organization_id;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_exception_list
    @organization_id   BIGINT,
    @scope             NVARCHAR(20)  = N'ALL',     -- ALL | MINE (investigator)
    @status_code       NVARCHAR(60)  = NULL,       -- a status, or OPEN_ALL for every open one
    @search            NVARCHAR(200) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @page_number       INT           = 1,
    @page_size         INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @scope = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@scope)), N''), N'ALL'));
    SET @status_code = NULLIF(LTRIM(RTRIM(@status_code)), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;

    SELECT v.*, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.fn_asset_verification_exception_view(@organization_id, @actor_employee_id) v
     WHERE (@scope = N'ALL' OR (@scope = N'MINE' AND v.IsInvestigator = 1))
       AND (@status_code IS NULL OR v.StatusCode = @status_code
            OR (@status_code = N'OPEN_ALL' AND v.StatusCode NOT IN (N'CLOSED', N'CANCELLED')))
       AND (@search IS NULL OR v.AssetName LIKE N'%' + @search + N'%' OR CAST(v.AssetId AS NVARCHAR(30)) = @search
            OR CAST(v.ExceptionId AS NVARCHAR(30)) = @search)
     ORDER BY CASE WHEN v.StatusCode IN (N'CLOSED', N'CANCELLED') THEN 1 ELSE 0 END,
              CASE v.Severity WHEN N'CRITICAL' THEN 0 ELSE 1 END, v.ResolutionDue, v.ExceptionId DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 1. the exception  2. its status / escalation history (transition log)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_exception_get
    @organization_id   BIGINT,
    @exception_id      BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_verification_exception WHERE exception_id = @exception_id AND organization_id = @organization_id)
        THROW 54411, 'Verification exception not found for this organization.', 1;
    SELECT v.* FROM grac_practice.fn_asset_verification_exception_view(@organization_id, @actor_employee_id) v
     WHERE v.ExceptionId = @exception_id;
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           emp.employee_name AS ActorName, l.actor_employee_id AS ActorEmployeeId, l.reason_code AS ReasonCode,
           l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'AssetVerificationException' AND l.entity_id = @exception_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;
END
GO

-- 1. settings (defaults when none saved)  2. effective rule per category
-- 3. active employees  4. active teams (pickers)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_settings_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @organization_id AS OrganizationId, st.asset_administrator_employee_id AS AssetAdministratorEmployeeId,
           e.employee_name AS AssetAdministratorName, st.fallback_team_id AS FallbackTeamId, t.team_name AS FallbackTeamName,
           ISNULL(st.escalation_level1_days, 7) AS EscalationLevel1Days, ISNULL(st.escalation_level2_days, 15) AS EscalationLevel2Days,
           ISNULL(st.escalation_level3_days, 30) AS EscalationLevel3Days, CONVERT(BIGINT, st.record_version) AS RecordVersion
      FROM (SELECT 1 AS x) one
      LEFT JOIN grac_practice.asset_verification_settings st ON st.organization_id = @organization_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = st.asset_administrator_employee_id
      LEFT JOIN grac_practice.organization_team t ON t.team_id = st.fallback_team_id;

    SELECT d.category AS Category, r.PrimaryAssignment, r.SupportingAssignment, r.StartSlaDays, r.StartImmediate,
           r.ResolutionSlaDays, r.ClosureApprovalRequired, r.ClosureEvidenceRequired, r.IsOverride
      FROM grac_practice.asset_verification_sla_rule d
      CROSS APPLY grac_practice.fn_asset_verification_rule(@organization_id, d.category) r
     WHERE d.organization_id IS NULL
     ORDER BY d.rule_id;

    SELECT e.employee_id AS EmployeeId, e.employee_name AS EmployeeName
      FROM grac_practice.organization_employee e WHERE e.organization_id = @organization_id AND e.status = N'Active'
     ORDER BY e.employee_name;
    SELECT t.team_id AS TeamId, t.team_name AS TeamName
      FROM grac_practice.organization_team t WHERE t.organization_id = @organization_id AND t.status = N'Active'
     ORDER BY t.team_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_settings_save
    @organization_id                 BIGINT,
    @asset_administrator_employee_id BIGINT        = NULL,
    @fallback_team_id                BIGINT        = NULL,
    @escalation_level1_days          INT           = 7,
    @escalation_level2_days          INT           = 15,
    @escalation_level3_days          INT           = 30,
    @expected_record_version         BIGINT        = NULL,
    @actor                           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54410, 'Organization not found.', 1;
    DECLARE @rv BIGINT = (SELECT CONVERT(BIGINT, record_version) FROM grac_practice.asset_verification_settings WHERE organization_id = @organization_id);
    IF @expected_record_version IS NOT NULL AND ISNULL(@rv, -1) <> @expected_record_version
        THROW 54426, 'These settings were changed by someone else. Reload and try again.', 1;
    IF (@asset_administrator_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
            WHERE employee_id = @asset_administrator_employee_id AND organization_id = @organization_id AND status = N'Active'))
       OR (@fallback_team_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_team
            WHERE team_id = @fallback_team_id AND organization_id = @organization_id AND status = N'Active'))
       OR ISNULL(@escalation_level1_days, 0) < 1 OR ISNULL(@escalation_level2_days, 0) <= @escalation_level1_days
       OR ISNULL(@escalation_level3_days, 0) <= @escalation_level2_days
        THROW 54425, 'Select an active asset administrator and fallback team of this organization; escalation levels must increase.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT asset_administrator_employee_id, fallback_team_id, escalation_level1_days,
                                            escalation_level2_days, escalation_level3_days
                                       FROM grac_practice.asset_verification_settings WHERE organization_id = @organization_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    MERGE grac_practice.asset_verification_settings AS t
    USING (SELECT @organization_id AS organization_id) AS s ON t.organization_id = s.organization_id
    WHEN MATCHED THEN UPDATE SET asset_administrator_employee_id = @asset_administrator_employee_id, fallback_team_id = @fallback_team_id,
                                 escalation_level1_days = @escalation_level1_days, escalation_level2_days = @escalation_level2_days,
                                 escalation_level3_days = @escalation_level3_days, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (organization_id, asset_administrator_employee_id, fallback_team_id, escalation_level1_days,
                                  escalation_level2_days, escalation_level3_days, updated_by, updated_dt)
                          VALUES (@organization_id, @asset_administrator_employee_id, @fallback_team_id, @escalation_level1_days,
                                  @escalation_level2_days, @escalation_level3_days, @actor, SYSUTCDATETIME());
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-verification-settings', @organization_id, N'SAVE', @before,
            (SELECT @asset_administrator_employee_id AS assetAdministratorEmployeeId, @fallback_team_id AS fallbackTeamId,
                    @escalation_level1_days AS level1, @escalation_level2_days AS level2, @escalation_level3_days AS level3
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- Organization override of the rule of one category; @reset = 1 returns to the BRD default.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_verification_rule_save
    @organization_id           BIGINT,
    @category                  NVARCHAR(40),
    @primary_assignment        NVARCHAR(30)  = NULL,
    @supporting_assignment     NVARCHAR(200) = NULL,
    @start_sla_days            INT           = NULL,
    @start_immediate           BIT           = 0,
    @resolution_sla_days       INT           = NULL,
    @closure_approval_required BIT           = 0,
    @closure_evidence_required BIT           = 0,
    @reset                     BIT           = 0,
    @actor                     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @category = UPPER(LTRIM(RTRIM(ISNULL(@category, N''))));
    SET @primary_assignment = UPPER(LTRIM(RTRIM(ISNULL(@primary_assignment, N''))));
    SET @supporting_assignment = NULLIF(LTRIM(RTRIM(@supporting_assignment)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54410, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_verification_sla_rule WHERE organization_id IS NULL AND category = @category)
        THROW 54424, 'Unknown disagreement category.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT * FROM grac_practice.asset_verification_sla_rule
                                      WHERE organization_id = @organization_id AND category = @category FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    IF ISNULL(@reset, 0) = 0
       AND (@primary_assignment NOT IN (N'ASSET_OWNER', N'ASSET_ADMINISTRATOR', N'MAINTENANCE_TEAM', N'SECURITY', N'FALLBACK_TEAM')
            OR ISNULL(@start_sla_days, -1) NOT BETWEEN 0 AND 365 OR ISNULL(@resolution_sla_days, 0) NOT BETWEEN 1 AND 365
            OR @resolution_sla_days < @start_sla_days)
        THROW 54424, 'Check the primary assignment and the SLA days (start 0-365, resolution 1-365 and not before the start).', 1;

    BEGIN TRAN;
    IF ISNULL(@reset, 0) = 1
    BEGIN
        -- An override already used by exceptions is kept (history) but takes the default values.
        UPDATE o
           SET primary_assignment = d.primary_assignment, supporting_assignment = d.supporting_assignment,
               start_sla_days = d.start_sla_days, start_immediate = d.start_immediate, resolution_sla_days = d.resolution_sla_days,
               closure_approval_required = d.closure_approval_required, closure_evidence_required = d.closure_evidence_required,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.asset_verification_sla_rule o
          JOIN grac_practice.asset_verification_sla_rule d ON d.organization_id IS NULL AND d.category = o.category
         WHERE o.organization_id = @organization_id AND o.category = @category
           AND EXISTS (SELECT 1 FROM grac_practice.asset_verification_exception x WHERE x.sla_rule_id = o.rule_id);
        DELETE o
          FROM grac_practice.asset_verification_sla_rule o
         WHERE o.organization_id = @organization_id AND o.category = @category
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_verification_exception x WHERE x.sla_rule_id = o.rule_id);
    END
    ELSE
        MERGE grac_practice.asset_verification_sla_rule AS t
        USING (SELECT @organization_id AS organization_id, @category AS category) AS s
        ON t.organization_id = s.organization_id AND t.category = s.category
        WHEN MATCHED THEN UPDATE SET primary_assignment = @primary_assignment, supporting_assignment = @supporting_assignment,
                                     start_sla_days = @start_sla_days, start_immediate = ISNULL(@start_immediate, 0),
                                     resolution_sla_days = @resolution_sla_days, closure_approval_required = ISNULL(@closure_approval_required, 0),
                                     closure_evidence_required = ISNULL(@closure_evidence_required, 0),
                                     updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (organization_id, category, primary_assignment, supporting_assignment, start_sla_days, start_immediate,
                                      resolution_sla_days, closure_approval_required, closure_evidence_required, entered_by)
                              VALUES (@organization_id, @category, @primary_assignment, @supporting_assignment, @start_sla_days,
                                      ISNULL(@start_immediate, 0), @resolution_sla_days, ISNULL(@closure_approval_required, 0),
                                      ISNULL(@closure_evidence_required, 0), @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-verification-rule', @organization_id, CASE WHEN ISNULL(@reset, 0) = 1 THEN N'RESET' ELSE N'SAVE' END, @before,
            (SELECT * FROM grac_practice.asset_verification_sla_rule
              WHERE organization_id = @organization_id AND category = @category FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO
PRINT '432: readers and settings procedures created.';
GO

-- =====================================================================
-- 8. sp_asset_custody_get (431) re-issued -- result set 4 added (432)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_custody_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54351, 'Asset not found for this organization.', 1;

    SELECT @asset_id AS AssetId, ISNULL(st.verification_status, N'NOT_VERIFIED') AS VerificationStatus,
           st.last_attested_date AS LastAttestedDate, st.next_attestation_date AS NextAttestationDate,
           p.ProfileId, p.AttestationRequired, p.Participant, p.Frequency, p.CustomIntervalDays, p.DueWindowDays,
           p.EvidenceRequirement, p.ManagerApprovalRequired, p.VersionNo AS ProfileVersion
      FROM (SELECT 1 AS x) one
      LEFT JOIN grac_practice.asset_attestation_state st ON st.asset_id = @asset_id
      OUTER APPLY grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset_id) p;

    SELECT h.assignment_id AS AssignmentId, ow.employee_name AS OwnerName,
           COALESCE(ce.employee_name, ct.team_name + N' (team)') AS CustodianName,
           d.department_name AS DepartmentName, l.location_name AS LocationName,
           h.building AS Building, h.floor AS Floor, h.room AS Room,
           h.effective_from AS EffectiveFrom, h.effective_to AS EffectiveTo, h.is_current AS IsCurrent,
           h.change_source AS ChangeSource, h.entered_by AS EnteredBy, h.entered_dt AS EnteredDt
      FROM grac_practice.asset_assignment_history h
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = h.asset_owner_id
      LEFT JOIN grac_practice.organization_employee ce ON h.custodian LIKE N'E:%' AND ce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_team ct ON h.custodian LIKE N'T:%' AND ct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_department d ON d.department_id = h.department_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = h.location_id
     WHERE h.asset_id = @asset_id
     ORDER BY h.effective_from DESC, h.assignment_id DESC;

    SELECT t.attestation_id AS AttestationId, t.attestation_type AS AttestationType, t.assignee_role AS AssigneeRole,
           COALESCE(e.employee_name, tm.team_name + N' (team)') AS AssigneeName, t.due_date AS DueDate,
           CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < CAST(SYSUTCDATETIME() AS DATE)
                THEN N'OVERDUE' ELSE t.status END AS DisplayStatus,
           t.response AS Response, t.condition_code AS ConditionCode, t.disagreement_category AS DisagreementCategory,
           t.comments AS Comments, at.employee_name AS AttestedByName, t.response_dt AS ResponseDt, t.closed_dt AS ClosedDt,
           t.decision_note AS DecisionNote
      FROM grac_practice.asset_attestation t
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assignee_employee_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = t.assignee_team_id
      LEFT JOIN grac_practice.organization_employee at ON at.employee_id = t.attested_by_employee_id
     WHERE t.asset_id = @asset_id
     ORDER BY t.generated_dt DESC, t.attestation_id DESC;

    -- 432: 4. verification exceptions of the asset
    SELECT x.exception_id AS ExceptionId, x.attestation_id AS AttestationId, x.category AS Category, x.severity AS Severity,
           s.status_code AS StatusCode, s.status_name AS StatusName, x.outcome AS Outcome,
           COALESCE(ie.employee_name, it.team_name + N' (team)') AS InvestigatorName,
           x.reported_dt AS ReportedDt, x.resolution_due AS ResolutionDue, x.closed_dt AS ClosedDt
      FROM grac_practice.asset_verification_exception x
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
      LEFT JOIN grac_practice.organization_employee ie ON ie.employee_id = x.investigator_employee_id
      LEFT JOIN grac_practice.organization_team it ON it.team_id = x.investigator_team_id
     WHERE x.asset_id = @asset_id
     ORDER BY x.reported_dt DESC, x.exception_id DESC;
END
GO
PRINT '432: sp_asset_custody_get re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '432-a the 8 BRD exception statuses and their transitions' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'AssetVerificationException') = 8
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetVerificationException') >= 20
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '432-b the 11 BRD 5.3.8 default rules',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_verification_sla_rule WHERE organization_id IS NULL) = 11 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '432-c every disagreement has exactly one exception',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_attestation a
                              WHERE a.response = N'DISAGREE' AND a.status IN (N'DISPUTED', N'EXCEPTION')
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_verification_exception x WHERE x.attestation_id = a.attestation_id))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '432-d respond and custody re-issued',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_attestation_respond')) LIKE '%sp_asset_verification_exception_create%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_custody_get')) LIKE '%asset_verification_exception%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '432-e objects present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_verification_exception_create', 'sp_asset_verification_exception_action',
                                'sp_asset_verification_exception_list', 'sp_asset_verification_exception_get',
                                'sp_asset_verification_settings_get', 'sp_asset_verification_settings_save',
                                'sp_asset_verification_rule_save')) = 7
             AND OBJECT_ID('grac_practice.fn_asset_verification_rule') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_verification_exception_view') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs 431 set up (profile, custodian, an open attestation) and an
--   investigator with a login (asset owner, or Exception settings ->
--   asset administrator / fallback team).
--   1. As the custodian, Disagree (Asset Not Found) -> the occurrence shows
--      Exception; Asset Attestation -> Exceptions lists one exception,
--      Assigned to the asset owner, start due +2 days, resolution due +7.
--      Submitting the same response again is impossible (not open).
--   2. As someone else, Start review -> refused (not the investigator).
--   3. As the investigator: Start review; Await evidence (reason) -> paused;
--      Resume next day -> revised due later by the paused days, original due
--      unchanged.
--   4. Resolve with No change -> approval and evidence required for Asset
--      Not Found (5.3.8 defaults): without evidence refused; with it ->
--      Awaiting approval. The investigator cannot approve; another user
--      with APPROVE approves -> Resolved -> Close -> Closed; the occurrence
--      is Resolved, the asset Verified.
--   5. Disagree with Asset Lost -> Critical, start due today; Resolve
--      without the five security items -> refused; Resolve as Lost confirmed,
--      approve, Close -> refused until the asset is moved to Lost on the
--      Lifecycle tab (or such a change is pending).
--   6. Reassign (reason) keeps the due dates; Cancel needs a reason.
--   7. Exception settings: override Asset Damaged to 5 days; reset returns
--      the BRD default.
-- =====================================================================
