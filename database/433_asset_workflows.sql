-- =====================================================================
-- 433  Asset workflows -- owner change, location transfer, breakdown and
--      disposal (Asset & Contract Management, Phase 4 increment 5b)
--
-- REQUEST
-- -------
--   BRD v1.7 11 "Ownership, Incident and Disposal Workflows":
--     Owner Change: Request -> Validate -> Handover -> Current Owner
--       Confirm -> New Owner Accept -> Access Review -> Approve
--     Location Transfer: Request -> Origin Controls -> Transport ->
--       Destination Rule Evaluation -> Install/Validate -> Approve
--     Breakdown: Report -> Assess Impact -> Quarantine/Controlled Use ->
--       Diagnose -> Repair -> Test/Calibrate -> Approve -> Return
--     Disposal: Request -> Dependency Review -> Approve -> Remove Service ->
--       Data/Record Review -> Revoke Access/Licence -> Sanitize/Decontaminate
--       -> Dispose -> Verify -> Archive
--   with the lifecycle gates of 5.4.3 / 19.9 (429), 5.3.1 attestation type
--   Transfer, 5.3.2 acknowledgement on an ownership change, 1 effective-dated
--   ownership / location history (431). Plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_workflow_definition / asset_workflow_step -- the four BRD 11
--      workflows as data: each step's actor (worker, approver, current
--      owner, new owner), what it needs (note, evidence, reference), the
--      lifecycle status it moves the asset to (through the 429 matrix --
--      only configured transitions) and its effect (apply the new owner,
--      check / apply the destination, containment choice).
--   2. asset_workflow_case (one open case per asset) and
--      asset_workflow_case_step (every completion, approval, confirmation
--      and rejection -- the case history).
--   3. sp_asset_workflow_start, sp_asset_workflow_step (COMPLETE /
--      APPROVE / REJECT / CONFIRM), sp_asset_workflow_cancel, internal
--      sp_asset_workflow_lifecycle (moves the asset with the step's note /
--      reference / evidence; approval gates are met by the workflow's own
--      approval step -- D31), readers.
--   4. Effects: Owner change approval sets the new asset owner, writes the
--      assignment history and raises the new owner's acknowledgement when
--      the attestation profile includes owners (431); Location transfer
--      approval sets site / building / floor / room, writes the history
--      and raises a Transfer attestation for the custodian / owner per the
--      profile (5.3.1); Breakdown and Disposal move the asset through
--      Quarantined / Repair / Active and Pending Decommission / Sanitization
--      Pending / Disposal Approval / Disposed / Archived (Disposed raises the
--      decommissioning event through 429).
--
-- NOT DONE HERE: tasks, SLAs and notifications per step (Phase 6);
--   Return attestations (no return workflow in the BRD); calibration
--   scheduling (activities, Phase 6); automatic reversal of the lifecycle
--   on cancel (D33: the asset is moved back on the Lifecycle tab, with
--   approval where the matrix requires it).
--
-- ERROR NUMBERS: 54450-54489
--   54450 organization not found          54451 case not found
--   54452 case is not open                54453 case changed by someone else
--   54454 unknown workflow / action       54455 an open case exists for the asset
--   54456 a lifecycle change awaits approval 54457 new owner not valid
--   54458 destination not valid           54459 reason required
--   54460 asset status does not allow the workflow 54461 wrong action for the step
--   54462 not the owner this step waits for 54463 segregation of duties
--   54464 note required                   54465 evidence required
--   54466 reference required              54467 containment choice required
--   54468 only the requester can cancel   54469 lifecycle transition not configured
--   54470 asset not found
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   asset-register.cshtml / .js (Workflows tab, Workflow cases dialog), docs.
-- DEPENDS ON: 423, 429, 431.
-- Rollback: 433_asset_workflows_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_lifecycle_apply','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_assignment_snapshot','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_attestation_create','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_field_value_set','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_field_options') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_transition_gate','U') IS NULL
BEGIN
    RAISERROR('ABORT (433): run 423, 429 and 431 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Definitions (BRD 11)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_workflow_definition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_workflow_definition (
        workflow_code      NVARCHAR(30)  NOT NULL CONSTRAINT pk_pm_asset_wf_def PRIMARY KEY,
        workflow_name      NVARCHAR(100) NOT NULL,
        brd_source         NVARCHAR(30)  NOT NULL,
        start_status_codes NVARCHAR(400) NULL,      -- comma list; NULL = any status with a configured first move
        display_order      INT           NOT NULL,
        is_active          BIT           NOT NULL CONSTRAINT df_pm_asset_wf_def_active DEFAULT 1,
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_wf_def_eby DEFAULT N'system',
        entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_asset_wf_def_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '433: asset_workflow_definition created.';
END
GO

IF OBJECT_ID('grac_practice.asset_workflow_step','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_workflow_step (
        workflow_code       NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_asset_wf_step_def REFERENCES grac_practice.asset_workflow_definition(workflow_code),
        step_no             INT           NOT NULL,
        step_code           NVARCHAR(40)  NOT NULL,
        step_name           NVARCHAR(100) NOT NULL,
        actor_kind          NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_wf_step_actor CHECK (actor_kind IN (N'START', N'WORKER', N'APPROVER', N'CURRENT_OWNER', N'NEW_OWNER')),
        requires_note       BIT           NOT NULL CONSTRAINT df_pm_asset_wf_step_note DEFAULT 0,
        requires_evidence   BIT           NOT NULL CONSTRAINT df_pm_asset_wf_step_ev DEFAULT 0,
        requires_reference  BIT           NOT NULL CONSTRAINT df_pm_asset_wf_step_ref DEFAULT 0,
        lifecycle_to_status NVARCHAR(60)  NULL,
        effect_code         NVARCHAR(30)  NULL
            CONSTRAINT ck_pm_asset_wf_step_effect CHECK (effect_code IN (N'APPLY_OWNER', N'CHECK_DESTINATION', N'APPLY_LOCATION', N'CONTAINMENT_CHOICE')),
        guidance            NVARCHAR(400) NULL,
        entered_by          NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_wf_step_eby DEFAULT N'system',
        entered_dt          DATETIME2     NOT NULL CONSTRAINT df_pm_asset_wf_step_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_asset_wf_step PRIMARY KEY (workflow_code, step_no),
        CONSTRAINT uq_pm_asset_wf_step_code UNIQUE (workflow_code, step_code)
    );
    PRINT '433: asset_workflow_step created.';
END
GO

MERGE grac_practice.asset_workflow_definition AS t
USING (VALUES
    (N'OWNER_CHANGE',      N'Owner change',      N'11', N'ACTIVE',         10),
    (N'LOCATION_TRANSFER', N'Location transfer', N'11', N'ACTIVE,STORAGE', 20),
    (N'BREAKDOWN',         N'Breakdown',         N'11', N'ACTIVE',         30),
    (N'DISPOSAL',          N'Disposal',          N'11', NULL,              40)
) AS s(workflow_code, workflow_name, brd_source, start_status_codes, display_order)
ON t.workflow_code = s.workflow_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (workflow_code, workflow_name, brd_source, start_status_codes, display_order, entered_by)
    VALUES (s.workflow_code, s.workflow_name, s.brd_source, s.start_status_codes, s.display_order, N'seed-433');
PRINT CONCAT('433: workflows inserted: ', @@ROWCOUNT);
GO

-- Columns: workflow, no, code, name, actor, note, evidence, reference, lifecycle to, effect, guidance
MERGE grac_practice.asset_workflow_step AS t
USING (VALUES
    (N'OWNER_CHANGE', 1, N'REQUEST', N'Request', N'START', 0, 0, 0, N'OWNER_CHANGE_PENDING', NULL, N'New owner and reason.'),
    (N'OWNER_CHANGE', 2, N'VALIDATE', N'Validate', N'WORKER', 1, 0, 0, NULL, NULL, N'Confirm the request, the new owner and the business need.'),
    (N'OWNER_CHANGE', 3, N'HANDOVER', N'Handover', N'WORKER', 1, 1, 0, NULL, NULL, N'Handover of the asset, documents and responsibilities; record the handover evidence.'),
    (N'OWNER_CHANGE', 4, N'CURRENT_OWNER_CONFIRM', N'Current owner confirm', N'CURRENT_OWNER', 0, 0, 0, NULL, NULL, N'The current owner confirms the handover.'),
    (N'OWNER_CHANGE', 5, N'NEW_OWNER_ACCEPT', N'New owner accept', N'NEW_OWNER', 0, 0, 0, NULL, NULL, N'The new owner accepts the asset and its responsibilities.'),
    (N'OWNER_CHANGE', 6, N'ACCESS_REVIEW', N'Access review', N'WORKER', 1, 0, 0, NULL, NULL, N'Review and adjust access linked to the asset.'),
    (N'OWNER_CHANGE', 7, N'APPROVE', N'Approve', N'APPROVER', 0, 0, 0, N'ACTIVE', N'APPLY_OWNER', N'Approval applies the new owner and returns the asset to Active.'),
    (N'LOCATION_TRANSFER', 1, N'REQUEST', N'Request', N'START', 0, 0, 1, N'TRANSFER_PENDING', NULL, N'Destination, reason and the destination / handover reference.'),
    (N'LOCATION_TRANSFER', 2, N'ORIGIN_CONTROLS', N'Origin controls', N'WORKER', 1, 0, 0, NULL, NULL, N'Dependencies, data and custody checks at the origin.'),
    (N'LOCATION_TRANSFER', 3, N'TRANSPORT', N'Transport', N'WORKER', 1, 1, 0, N'TRANSFERRED', NULL, N'Dispatch and receipt; record the transport / handover evidence.'),
    (N'LOCATION_TRANSFER', 4, N'DESTINATION_RULES', N'Destination rule evaluation', N'WORKER', 1, 0, 0, NULL, N'CHECK_DESTINATION', N'The destination site must be active; building / floor / room must belong to it.'),
    (N'LOCATION_TRANSFER', 5, N'INSTALL_VALIDATE', N'Install / validate', N'WORKER', 1, 1, 0, NULL, NULL, N'Installation and validation at the destination with evidence.'),
    (N'LOCATION_TRANSFER', 6, N'APPROVE', N'Approve', N'APPROVER', 0, 0, 0, N'ACTIVE', N'APPLY_LOCATION', N'Approval applies the destination, returns the asset to Active and raises the Transfer attestation.'),
    (N'BREAKDOWN', 1, N'REPORT', N'Report', N'START', 0, 0, 0, NULL, NULL, N'What failed and when.'),
    (N'BREAKDOWN', 2, N'ASSESS_IMPACT', N'Assess impact', N'WORKER', 1, 0, 0, NULL, NULL, N'Operational, safety and service impact.'),
    (N'BREAKDOWN', 3, N'CONTAINMENT', N'Quarantine / controlled use', N'WORKER', 1, 0, 1, N'QUARANTINED', N'CONTAINMENT_CHOICE', N'Quarantine moves the asset to Quarantined; controlled use keeps it Active.'),
    (N'BREAKDOWN', 4, N'DIAGNOSE', N'Diagnose', N'WORKER', 1, 0, 1, N'REPAIR', NULL, N'Diagnosis and the work order / incident reference; the asset moves to Repair.'),
    (N'BREAKDOWN', 5, N'REPAIR', N'Repair', N'WORKER', 1, 1, 0, NULL, NULL, N'Repair performed, with the work record.'),
    (N'BREAKDOWN', 6, N'TEST_CALIBRATE', N'Test / calibrate', N'WORKER', 1, 1, 0, NULL, NULL, N'Test and calibration results.'),
    (N'BREAKDOWN', 7, N'APPROVE_RETURN', N'Approve and return', N'APPROVER', 0, 0, 0, N'ACTIVE', NULL, N'Approval returns the asset to service (Active).'),
    (N'DISPOSAL', 1, N'REQUEST', N'Request', N'START', 0, 0, 0, N'PENDING_DECOMMISSION', NULL, N'Reason for disposal.'),
    (N'DISPOSAL', 2, N'DEPENDENCY_REVIEW', N'Dependency review', N'WORKER', 1, 0, 0, NULL, NULL, N'Dependency, service, contract, data and retention impact.'),
    (N'DISPOSAL', 3, N'APPROVE', N'Approve', N'APPROVER', 0, 0, 0, NULL, NULL, N'Approval of the disposal.'),
    (N'DISPOSAL', 4, N'REMOVE_SERVICE', N'Remove service', N'WORKER', 1, 0, 0, NULL, NULL, N'Remove the asset from service and dependencies.'),
    (N'DISPOSAL', 5, N'DATA_RECORD_REVIEW', N'Data / record review', N'WORKER', 1, 0, 0, NULL, NULL, N'Data held, records to retain or transfer.'),
    (N'DISPOSAL', 6, N'REVOKE_ACCESS', N'Revoke access / licence', N'WORKER', 1, 0, 0, N'SANITIZATION_PENDING', NULL, N'Access and licence removal; the asset moves to Sanitization Pending.'),
    (N'DISPOSAL', 7, N'SANITIZE', N'Sanitize / decontaminate', N'WORKER', 1, 1, 0, N'DISPOSAL_APPROVAL', NULL, N'Sanitization or decontamination with evidence; the asset moves to Disposal Approval.'),
    (N'DISPOSAL', 8, N'DISPOSE', N'Dispose', N'WORKER', 1, 1, 0, N'DISPOSED', NULL, N'Disposal with certificate / evidence; the asset moves to Disposed.'),
    (N'DISPOSAL', 9, N'VERIFY', N'Verify', N'APPROVER', 0, 0, 0, NULL, NULL, N'Independent verification of the disposal evidence.'),
    (N'DISPOSAL', 10, N'ARCHIVE', N'Archive', N'WORKER', 1, 0, 0, N'ARCHIVED', NULL, N'Closure and retention controls; the asset moves to Archived.')
) AS s(workflow_code, step_no, step_code, step_name, actor_kind, requires_note, requires_evidence, requires_reference,
       lifecycle_to_status, effect_code, guidance)
ON t.workflow_code = s.workflow_code AND t.step_no = s.step_no
WHEN NOT MATCHED BY TARGET THEN
    INSERT (workflow_code, step_no, step_code, step_name, actor_kind, requires_note, requires_evidence, requires_reference,
            lifecycle_to_status, effect_code, guidance, entered_by)
    VALUES (s.workflow_code, s.step_no, s.step_code, s.step_name, s.actor_kind, s.requires_note, s.requires_evidence,
            s.requires_reference, s.lifecycle_to_status, s.effect_code, s.guidance, N'seed-433');
PRINT CONCAT('433: workflow steps inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Cases
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_workflow_case','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_workflow_case (
        case_id                  BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_wf_case PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        asset_id                 BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_wf_case_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        workflow_code            NVARCHAR(30)   NOT NULL
            CONSTRAINT fk_pm_asset_wf_case_def REFERENCES grac_practice.asset_workflow_definition(workflow_code),
        case_status              NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_wf_case_status CHECK (case_status IN (N'OPEN', N'COMPLETED', N'CANCELLED')),
        current_step_no          INT            NOT NULL,
        start_status_code        NVARCHAR(60)   NOT NULL,
        reason                   NVARCHAR(1000) NOT NULL,
        reference_text           NVARCHAR(400)  NULL,
        previous_owner_id        BIGINT         NULL,
        new_owner_id             BIGINT         NULL,
        origin_location_id       BIGINT         NULL,
        dest_location_id         BIGINT         NULL,
        dest_building            NVARCHAR(160)  NULL,
        dest_floor               NVARCHAR(160)  NULL,
        dest_room                NVARCHAR(160)  NULL,
        containment              NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_asset_wf_case_contain CHECK (containment IN (N'QUARANTINE', N'CONTROLLED_USE')),
        requested_by             NVARCHAR(100)  NOT NULL,
        requested_by_employee_id BIGINT         NULL,
        requested_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_wf_case_rdt DEFAULT SYSUTCDATETIME(),
        closed_dt                DATETIME2      NULL,
        cancel_reason            NVARCHAR(1000) NULL,
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL,
        record_version           ROWVERSION     NOT NULL
    );
    CREATE UNIQUE INDEX ux_pm_asset_wf_case_open ON grac_practice.asset_workflow_case(asset_id) WHERE case_status = N'OPEN';
    CREATE INDEX ix_pm_asset_wf_case_org ON grac_practice.asset_workflow_case(organization_id, case_status, workflow_code);
    PRINT '433: asset_workflow_case created.';
END
GO

IF OBJECT_ID('grac_practice.asset_workflow_case_step','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_workflow_case_step (
        case_step_id             BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_wf_cstep PRIMARY KEY,
        case_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_wf_cstep_case REFERENCES grac_practice.asset_workflow_case(case_id),
        step_no                  INT            NOT NULL,
        step_code                NVARCHAR(40)   NOT NULL,
        step_outcome             NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_wf_cstep_outcome CHECK (step_outcome IN (N'DONE', N'APPROVED', N'CONFIRMED', N'REJECTED')),
        choice                   NVARCHAR(20)   NULL,
        note                     NVARCHAR(1000) NULL,
        evidence_text            NVARCHAR(1000) NULL,
        reference_text           NVARCHAR(400)  NULL,
        lifecycle_change_id      BIGINT         NULL
            CONSTRAINT fk_pm_asset_wf_cstep_change REFERENCES grac_practice.asset_lifecycle_change(change_id),
        completed_by             NVARCHAR(100)  NOT NULL,
        completed_by_employee_id BIGINT         NULL,
        completed_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_wf_cstep_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_wf_cstep_case ON grac_practice.asset_workflow_case_step(case_id, completed_dt);
    PRINT '433: asset_workflow_case_step created.';
END
GO

-- =====================================================================
-- 3. Lifecycle move for a workflow step (internal)
-- =====================================================================
-- Only configured transitions (429 matrix). The reason / reference /
-- evidence gates are met from the step (or the case); its approval gate is
-- met by the approval step of the workflow (D31). Writes the
-- asset_lifecycle_change row so the Lifecycle tab shows the move.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_lifecycle
    @case_id           BIGINT,
    @to_status_code    NVARCHAR(60),
    @reason_text       NVARCHAR(1000),
    @reference_text    NVARCHAR(400)  = NULL,
    @evidence_text     NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @out_change_id     BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @org BIGINT, @asset BIGINT, @wf NVARCHAR(30);
    SELECT @org = organization_id, @asset = asset_id, @wf = workflow_code FROM grac_practice.asset_workflow_case WHERE case_id = @case_id;
    DECLARE @from NVARCHAR(60);
    SELECT @from = COALESCE(cs.status_code, ls.status_code)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset;
    IF @from = @to_status_code RETURN;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset AND change_status = N'PENDING_APPROVAL')
        THROW 54456, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    DECLARE @rule INT, @ref_label NVARCHAR(200), @req_ev BIT;
    SELECT TOP 1 @rule = r.transition_rule_id, @ref_label = g.reference_label, @req_ev = g.requires_evidence
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(400) = CONCAT(N'The lifecycle matrix has no active move from ', @from, N' to ', @to_status_code,
                                            N'. The asset may have been moved outside this workflow; cancel the case or restore the status.');
        THROW 54469, @msg, 1;
    END
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N' for this step.');
        THROW 54466, @ref_msg, 1;
    END
    -- An approval step relies on the evidence already recorded on the case (e.g. test / install / disposal evidence).
    IF @req_ev = 1 AND @evidence_text IS NULL
        SELECT TOP 1 @evidence_text = evidence_text FROM grac_practice.asset_workflow_case_step
         WHERE case_id = @case_id AND evidence_text IS NOT NULL AND step_outcome <> N'REJECTED'
         ORDER BY completed_dt DESC, case_step_id DESC;
    IF @req_ev = 1 AND @evidence_text IS NULL
        THROW 54465, 'This step moves the asset through a lifecycle gate that needs evidence; record it on the step.', 1;

    DECLARE @log BIGINT, @full_reason NVARCHAR(1000) = LEFT(CONCAT(N'Workflow #', @case_id, N' (', @wf, N'): ', @reason_text), 1000);
    BEGIN TRAN;
    EXEC grac_practice.sp_asset_lifecycle_apply
         @organization_id = @org, @asset_id = @asset, @from_status_code = @from, @to_status_code = @to_status_code,
         @reason_code = N'WORKFLOW', @reason_text = @full_reason,
         @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log OUTPUT;
    INSERT grac_practice.asset_lifecycle_change
        (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
         reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
    VALUES (@org, @asset, @rule, @from, @to_status_code, N'COMPLETED',
            @full_reason, @reference_text, @evidence_text, @actor, @actor_employee_id, @log);
    SET @out_change_id = SCOPE_IDENTITY();
    COMMIT;
END
GO

-- =====================================================================
-- 4. Start, step, cancel
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_start
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @workflow_code     NVARCHAR(30),
    @reason            NVARCHAR(1000) = NULL,
    @reference_text    NVARCHAR(400)  = NULL,
    @new_owner_id      BIGINT         = NULL,
    @dest_location_id  BIGINT         = NULL,
    @dest_building     NVARCHAR(160)  = NULL,
    @dest_floor        NVARCHAR(160)  = NULL,
    @dest_room         NVARCHAR(160)  = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @out_case_id       BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @workflow_code = UPPER(LTRIM(RTRIM(ISNULL(@workflow_code, N''))));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @dest_building = NULLIF(LTRIM(RTRIM(@dest_building)), N'');
    SET @dest_floor = NULLIF(LTRIM(RTRIM(@dest_floor)), N'');
    SET @dest_room = NULLIF(LTRIM(RTRIM(@dest_room)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54450, 'Organization not found.', 1;
    DECLARE @starts NVARCHAR(400), @found_wf BIT = 0;
    SELECT @found_wf = 1, @starts = start_status_codes FROM grac_practice.asset_workflow_definition
     WHERE workflow_code = @workflow_code AND is_active = 1;
    IF @found_wf = 0 THROW 54454, 'Unknown workflow.', 1;
    DECLARE @found BIT = 0, @owner BIGINT, @loc BIGINT, @status NVARCHAR(60);
    SELECT @found = 1, @owner = a.owner_id, @loc = a.location_id, @status = COALESCE(cs.status_code, ls.status_code)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54470, 'Asset not found for this organization.', 1;
    IF @reason IS NULL THROW 54459, 'Give the reason for this workflow.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_workflow_case WHERE asset_id = @asset_id AND case_status = N'OPEN')
        THROW 54455, 'This asset already has an open workflow case; complete or cancel it first.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54456, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;

    -- The asset status must allow the workflow: listed start statuses, and a configured first move.
    DECLARE @first_to NVARCHAR(60), @first_ref BIT;
    SELECT @first_to = lifecycle_to_status, @first_ref = requires_reference
      FROM grac_practice.asset_workflow_step WHERE workflow_code = @workflow_code AND step_no = 1;
    IF (@starts IS NOT NULL AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(@starts, N',') x WHERE LTRIM(RTRIM(x.[value])) = @status))
       OR (@first_to IS NOT NULL AND @status <> @first_to AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule r
                                                  WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
                                                    AND r.from_status_code = @status AND r.to_status_code = @first_to))
    BEGIN
        DECLARE @st_msg NVARCHAR(400) = CONCAT(N'This workflow cannot start while the asset is ', @status,
                                               CASE WHEN @starts IS NULL THEN N'.' ELSE N' (allowed: ' + @starts + N').' END);
        THROW 54460, @st_msg, 1;
    END
    IF @first_ref = 1 AND @reference_text IS NULL
        THROW 54466, 'Enter the reference for this request.', 1;
    -- The first move happens at the request, before any workflow approval: it must not need one (D31).
    IF @first_to IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule r
                                          WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
                                            AND r.from_status_code = @status AND r.to_status_code = @first_to AND r.requires_approval = 1)
    BEGIN
        DECLARE @ap_msg NVARCHAR(400) = CONCAT(N'Moving the asset from ', @status, N' to ', @first_to,
            N' needs an approved lifecycle change; request it on the Lifecycle tab, then start this workflow.');
        THROW 54460, @ap_msg, 1;
    END

    IF @workflow_code = N'OWNER_CHANGE'
       AND (@new_owner_id IS NULL OR @new_owner_id = ISNULL(@owner, -1)
            OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                            WHERE employee_id = @new_owner_id AND organization_id = @organization_id AND status = N'Active'))
        THROW 54457, 'Select an active employee of this organization, other than the current owner, as the new owner.', 1;
    IF @workflow_code = N'OWNER_CHANGE' AND @owner IS NULL
        THROW 54457, 'The asset has no current owner to hand over from; set the owner on the form instead.', 1;
    IF @workflow_code = N'LOCATION_TRANSFER'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location
                        WHERE location_id = @dest_location_id AND organization_id = @organization_id AND status = N'Active')
            THROW 54458, 'Select an active destination site of this organization.', 1;
        DECLARE @opt TABLE (option_group NVARCHAR(100) NOT NULL, option_value NVARCHAR(160) NOT NULL, parent_value NVARCHAR(160) NULL);
        INSERT @opt (option_group, option_value, parent_value)
        -- Option groups are stored as asset_field.<field key> (423).
        SELECT REPLACE(OptionGroup, N'asset_field.', N''), OptionValue, ParentValue FROM grac_practice.fn_asset_field_options(@organization_id)
         WHERE OptionGroup IN (N'asset_field.building', N'asset_field.floor', N'asset_field.room');
        IF (@dest_building IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @opt WHERE option_group = N'building' AND option_value = @dest_building
                                                         AND (parent_value IS NULL OR parent_value = CAST(@dest_location_id AS NVARCHAR(40)))))
           OR (@dest_floor IS NOT NULL AND (@dest_building IS NULL OR NOT EXISTS (SELECT 1 FROM @opt WHERE option_group = N'floor'
                                                         AND option_value = @dest_floor AND (parent_value IS NULL OR parent_value = @dest_building))))
           OR (@dest_room IS NOT NULL AND (@dest_floor IS NULL OR NOT EXISTS (SELECT 1 FROM @opt WHERE option_group = N'room'
                                                         AND option_value = @dest_room AND (parent_value IS NULL OR parent_value = @dest_floor))))
            THROW 54458, 'The building must belong to the destination site, the floor to the building and the room to the floor.', 1;
    END

    DECLARE @change BIGINT;
    BEGIN TRAN;
    INSERT grac_practice.asset_workflow_case
        (organization_id, asset_id, workflow_code, case_status, current_step_no, start_status_code, reason, reference_text,
         previous_owner_id, new_owner_id, origin_location_id, dest_location_id, dest_building, dest_floor, dest_room,
         requested_by, requested_by_employee_id)
    VALUES (@organization_id, @asset_id, @workflow_code, N'OPEN', 2, @status, @reason, @reference_text,
            @owner, CASE WHEN @workflow_code = N'OWNER_CHANGE' THEN @new_owner_id END, @loc,
            CASE WHEN @workflow_code = N'LOCATION_TRANSFER' THEN @dest_location_id END,
            CASE WHEN @workflow_code = N'LOCATION_TRANSFER' THEN @dest_building END,
            CASE WHEN @workflow_code = N'LOCATION_TRANSFER' THEN @dest_floor END,
            CASE WHEN @workflow_code = N'LOCATION_TRANSFER' THEN @dest_room END,
            @actor, @actor_employee_id);
    SET @out_case_id = SCOPE_IDENTITY();
    IF @first_to IS NOT NULL
        EXEC grac_practice.sp_asset_workflow_lifecycle
             @case_id = @out_case_id, @to_status_code = @first_to, @reason_text = @reason, @reference_text = @reference_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_change_id = @change OUTPUT;
    INSERT grac_practice.asset_workflow_case_step
        (case_id, step_no, step_code, step_outcome, note, reference_text, lifecycle_change_id, completed_by, completed_by_employee_id)
    SELECT @out_case_id, 1, s.step_code, N'DONE', @reason, @reference_text, @change, @actor, @actor_employee_id
      FROM grac_practice.asset_workflow_step s WHERE s.workflow_code = @workflow_code AND s.step_no = 1;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-workflow', @out_case_id, N'START', NULL,
            (SELECT @asset_id AS assetId, @workflow_code AS workflowCode, @reason AS reason, @reference_text AS reference,
                    @new_owner_id AS newOwnerId, @dest_location_id AS destLocationId, @dest_building AS destBuilding,
                    @dest_floor AS destFloor, @dest_room AS destRoom, @status AS startStatus FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_case_id AS CaseId, N'OPEN' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_step_action
    @organization_id         BIGINT,
    @case_id                 BIGINT,
    @action                  NVARCHAR(20),       -- COMPLETE (worker) | APPROVE / REJECT (approver) | CONFIRM / DECLINE (owner)
    @note                    NVARCHAR(1000) = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @choice                  NVARCHAR(20)   = NULL,   -- containment: QUARANTINE | CONTROLLED_USE
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
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @choice = UPPER(NULLIF(LTRIM(RTRIM(@choice)), N''));

    DECLARE @found BIT = 0, @asset BIGINT, @wf NVARCHAR(30), @cstatus NVARCHAR(20), @step INT, @rv BIGINT, @req_by NVARCHAR(100),
            @req_emp BIGINT, @prev_owner BIGINT, @new_owner BIGINT, @dest BIGINT, @b NVARCHAR(160), @f NVARCHAR(160), @r NVARCHAR(160),
            @case_ref NVARCHAR(400), @case_reason NVARCHAR(1000);
    SELECT @found = 1, @asset = asset_id, @wf = workflow_code, @cstatus = case_status, @step = current_step_no,
           @rv = CONVERT(BIGINT, record_version), @req_by = requested_by, @req_emp = requested_by_employee_id,
           @prev_owner = previous_owner_id, @new_owner = new_owner_id, @dest = dest_location_id,
           @b = dest_building, @f = dest_floor, @r = dest_room, @case_ref = reference_text, @case_reason = reason
      FROM grac_practice.asset_workflow_case WHERE case_id = @case_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54451, 'Workflow case not found for this organization.', 1;
    IF @cstatus <> N'OPEN' THROW 54452, 'This workflow case is not open.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54453, 'This case was changed by someone else. Reload and try again.', 1;
    IF @action NOT IN (N'COMPLETE', N'APPROVE', N'REJECT', N'CONFIRM', N'DECLINE') THROW 54454, 'Unknown action.', 1;

    DECLARE @code NVARCHAR(40), @name NVARCHAR(100), @kind NVARCHAR(20), @req_note BIT, @req_ev BIT, @req_ref BIT,
            @to NVARCHAR(60), @effect NVARCHAR(30), @last INT;
    SELECT @code = step_code, @name = step_name, @kind = actor_kind, @req_note = requires_note, @req_ev = requires_evidence,
           @req_ref = requires_reference, @to = lifecycle_to_status, @effect = effect_code
      FROM grac_practice.asset_workflow_step WHERE workflow_code = @wf AND step_no = @step;
    SET @last = (SELECT MAX(step_no) FROM grac_practice.asset_workflow_step WHERE workflow_code = @wf);

    -- The action must fit the actor of the step (D32).
    IF NOT (   (@kind = N'WORKER' AND @action = N'COMPLETE')
            OR (@kind = N'APPROVER' AND @action IN (N'APPROVE', N'REJECT'))
            OR (@kind IN (N'CURRENT_OWNER', N'NEW_OWNER') AND @action IN (N'CONFIRM', N'DECLINE')))
        THROW 54461, 'This action does not fit the current step of the case.', 1;
    IF (@kind = N'CURRENT_OWNER' AND ISNULL(@actor_employee_id, -1) <> ISNULL(@prev_owner, -2))
       OR (@kind = N'NEW_OWNER' AND ISNULL(@actor_employee_id, -1) <> ISNULL(@new_owner, -2))
        THROW 54462, 'This step waits for the confirmation of a specific owner; only that person can confirm or decline it.', 1;
    IF @kind = N'APPROVER' AND (@req_by = @actor OR (@req_emp IS NOT NULL AND @req_emp = @actor_employee_id))
        THROW 54463, 'Segregation of duties: the person who started this workflow cannot approve or verify it.', 1;
    -- An owner declining is a rejection of the step (the case goes back one step).
    IF @action = N'DECLINE' SET @action = N'REJECT';
    IF @action = N'REJECT' AND @note IS NULL THROW 54464, 'Give the reason for the rejection.', 1;
    IF @action <> N'REJECT'
    BEGIN
        IF @req_note = 1 AND @note IS NULL THROW 54464, 'Add a note for this step.', 1;
        IF @req_ev = 1 AND @evidence_text IS NULL THROW 54465, 'Record the evidence for this step.', 1;
        IF @req_ref = 1 AND @reference_text IS NULL THROW 54466, 'Enter the reference for this step.', 1;
        IF @effect = N'CONTAINMENT_CHOICE' AND ISNULL(@choice, N'') NOT IN (N'QUARANTINE', N'CONTROLLED_USE')
            THROW 54467, 'Choose quarantine or controlled use.', 1;
        IF @effect IN (N'CHECK_DESTINATION', N'APPLY_LOCATION')
           AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_location
                            WHERE location_id = @dest AND organization_id = @organization_id AND status = N'Active')
            THROW 54458, 'The destination site is no longer active; cancel the case and request a new transfer.', 1;
    END

    DECLARE @outcome NVARCHAR(20) = CASE @action WHEN N'APPROVE' THEN N'APPROVED' WHEN N'CONFIRM' THEN N'CONFIRMED'
                                                 WHEN N'REJECT' THEN N'REJECTED' ELSE N'DONE' END;
    DECLARE @change BIGINT, @move_to NVARCHAR(60) = CASE WHEN @action = N'REJECT' THEN NULL
                                                         WHEN @effect = N'CONTAINMENT_CHOICE' AND @choice <> N'QUARANTINE' THEN NULL
                                                         ELSE @to END;
    DECLARE @step_reason NVARCHAR(1000) = CONCAT(@name, N': ', ISNULL(@note, @case_reason));
    DECLARE @step_ref NVARCHAR(400) = ISNULL(@reference_text, @case_ref);
    DECLARE @complete BIT = CASE WHEN @action <> N'REJECT' AND @step = @last THEN 1 ELSE 0 END;

    BEGIN TRAN;
    IF @move_to IS NOT NULL
        EXEC grac_practice.sp_asset_workflow_lifecycle
             @case_id = @case_id, @to_status_code = @move_to, @reason_text = @step_reason, @reference_text = @step_ref,
             @evidence_text = @evidence_text, @actor_employee_id = @actor_employee_id, @actor = @actor, @out_change_id = @change OUTPUT;

    IF @action <> N'REJECT' AND @effect = N'APPLY_OWNER'
    BEGIN
        UPDATE grac_practice.organization_dependency_asset
           SET owner_id = @new_owner, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset;
        DECLARE @own_src NVARCHAR(100) = CONCAT(N'Owner change #', @case_id);
        EXEC grac_practice.sp_asset_assignment_snapshot
             @organization_id = @organization_id, @asset_id = @asset, @source = @own_src, @raise_acknowledgement = 1, @actor = @actor;
    END
    IF @action <> N'REJECT' AND @effect = N'APPLY_LOCATION'
    BEGIN
        UPDATE grac_practice.organization_dependency_asset
           SET location_id = @dest, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset;
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = N'building', @value = @b, @actor = @actor;
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = N'floor', @value = @f, @actor = @actor;
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = N'room', @value = @r, @actor = @actor;
        DECLARE @loc_src NVARCHAR(100) = CONCAT(N'Location transfer #', @case_id);
        EXEC grac_practice.sp_asset_assignment_snapshot
             @organization_id = @organization_id, @asset_id = @asset, @source = @loc_src, @raise_acknowledgement = 0, @actor = @actor;
        -- 5.3.1 attestation type Transfer, for the participants of the profile.
        DECLARE @participant NVARCHAR(20), @window INT, @required BIT;
        SELECT @participant = Participant, @window = DueWindowDays, @required = AttestationRequired
          FROM grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset);
        IF @required = 1
        BEGIN
            DECLARE @due DATE = DATEADD(DAY, ISNULL(@window, 7), CAST(SYSUTCDATETIME() AS DATE)), @att BIGINT, @skip NVARCHAR(100),
                    @key NVARCHAR(200);
            IF @participant IN (N'CUSTODIAN', N'BOTH')
            BEGIN
                SET @key = CONCAT(N'TRANSFER:', @case_id, N':CUSTODIAN');
                EXEC grac_practice.sp_asset_attestation_create
                     @organization_id = @organization_id, @asset_id = @asset, @attestation_type = N'TRANSFER',
                     @assignee_role = N'CUSTODIAN', @occurrence_key = @key, @due_date = @due, @actor = @actor,
                     @out_attestation_id = @att OUTPUT, @out_skip_reason = @skip OUTPUT;
            END
            IF @participant IN (N'OWNER', N'BOTH')
            BEGIN
                SET @key = CONCAT(N'TRANSFER:', @case_id, N':OWNER');
                EXEC grac_practice.sp_asset_attestation_create
                     @organization_id = @organization_id, @asset_id = @asset, @attestation_type = N'TRANSFER',
                     @assignee_role = N'OWNER', @occurrence_key = @key, @due_date = @due, @actor = @actor,
                     @out_attestation_id = @att OUTPUT, @out_skip_reason = @skip OUTPUT;
            END
        END
    END
    IF @action <> N'REJECT' AND @effect = N'CONTAINMENT_CHOICE'
        UPDATE grac_practice.asset_workflow_case SET containment = @choice WHERE case_id = @case_id;

    INSERT grac_practice.asset_workflow_case_step
        (case_id, step_no, step_code, step_outcome, choice, note, evidence_text, reference_text, lifecycle_change_id,
         completed_by, completed_by_employee_id)
    VALUES (@case_id, @step, @code, @outcome, @choice, @note, @evidence_text, @reference_text, @change, @actor, @actor_employee_id);
    -- A rejection sends the case back one step (never before the first worker step); the lifecycle stays where it is.
    UPDATE grac_practice.asset_workflow_case
       SET current_step_no = CASE WHEN @action = N'REJECT' THEN CASE WHEN @step > 2 THEN @step - 1 ELSE 2 END
                                  WHEN @complete = 1 THEN @step ELSE @step + 1 END,
           case_status = CASE WHEN @complete = 1 THEN N'COMPLETED' ELSE case_status END,
           closed_dt = CASE WHEN @complete = 1 THEN SYSUTCDATETIME() ELSE closed_dt END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE case_id = @case_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-workflow', @case_id, @action,
            (SELECT @step AS stepNo, @code AS stepCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @outcome AS outcome, @choice AS choice, @note AS note, @evidence_text AS evidence, @reference_text AS reference,
                    @move_to AS lifecycleTo, @complete AS completed FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @case_id AS CaseId, CASE WHEN @complete = 1 THEN N'COMPLETED' ELSE @outcome END AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_cancel
    @organization_id         BIGINT,
    @case_id                 BIGINT,
    @reason                  NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @found BIT = 0, @cstatus NVARCHAR(20), @rv BIGINT, @req_by NVARCHAR(100), @req_emp BIGINT;
    SELECT @found = 1, @cstatus = case_status, @rv = CONVERT(BIGINT, record_version), @req_by = requested_by,
           @req_emp = requested_by_employee_id
      FROM grac_practice.asset_workflow_case WHERE case_id = @case_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54451, 'Workflow case not found for this organization.', 1;
    IF @cstatus <> N'OPEN' THROW 54452, 'This workflow case is not open.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54453, 'This case was changed by someone else. Reload and try again.', 1;
    IF NOT (@req_by = @actor OR (@req_emp IS NOT NULL AND @req_emp = @actor_employee_id))
        THROW 54468, 'Only the person who started this workflow can cancel it.', 1;
    IF @reason IS NULL THROW 54459, 'Give the reason for cancelling.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_workflow_case
       SET case_status = N'CANCELLED', cancel_reason = @reason, closed_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE case_id = @case_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-workflow', @case_id, N'CANCEL', (SELECT N'OPEN' AS caseStatus FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT N'CANCELLED' AS caseStatus, @reason AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;

    SELECT @case_id AS CaseId, N'CANCELLED' AS Result;
END
GO
PRINT '433: workflow procedures created.';
GO

-- =====================================================================
-- 5. Readers
-- =====================================================================
-- 1. workflows  2. steps  3. building / floor / room options (destination pickers)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_definitions
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT workflow_code AS WorkflowCode, workflow_name AS WorkflowName, brd_source AS BrdSource,
           start_status_codes AS StartStatusCodes
      FROM grac_practice.asset_workflow_definition WHERE is_active = 1 ORDER BY display_order;
    SELECT workflow_code AS WorkflowCode, step_no AS StepNo, step_code AS StepCode, step_name AS StepName, actor_kind AS ActorKind,
           requires_note AS RequiresNote, requires_evidence AS RequiresEvidence, requires_reference AS RequiresReference,
           lifecycle_to_status AS LifecycleToStatus, effect_code AS EffectCode, guidance AS Guidance
      FROM grac_practice.asset_workflow_step ORDER BY workflow_code, step_no;
    SELECT REPLACE(OptionGroup, N'asset_field.', N'') AS OptionGroup, OptionValue, OptionLabel, ParentValue
      FROM grac_practice.fn_asset_field_options(@organization_id)
     WHERE OptionGroup IN (N'asset_field.building', N'asset_field.floor', N'asset_field.room')
     ORDER BY OptionGroup, DisplayOrder, OptionLabel;
END
GO

-- Cases: one asset (@asset_id) or the organization; open only by default.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_cases
    @organization_id   BIGINT,
    @asset_id          BIGINT = NULL,
    @open_only         BIT    = 1,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 200 c.case_id AS CaseId, c.asset_id AS AssetId, a.asset_name AS AssetName, c.workflow_code AS WorkflowCode,
           d.workflow_name AS WorkflowName, c.case_status AS CaseStatus, c.current_step_no AS CurrentStepNo,
           s.step_name AS CurrentStepName, s.actor_kind AS CurrentActorKind,
           (SELECT MAX(step_no) FROM grac_practice.asset_workflow_step x WHERE x.workflow_code = c.workflow_code) AS StepCount,
           c.reason AS Reason, c.requested_by AS RequestedBy, rq.employee_name AS RequestedByName, c.requested_dt AS RequestedDt,
           c.closed_dt AS ClosedDt,
           CASE WHEN c.case_status = N'OPEN'
                     AND ((s.actor_kind = N'CURRENT_OWNER' AND c.previous_owner_id = @actor_employee_id)
                          OR (s.actor_kind = N'NEW_OWNER' AND c.new_owner_id = @actor_employee_id)) THEN 1 ELSE 0 END AS AwaitingMe
      FROM grac_practice.asset_workflow_case c
      JOIN grac_practice.asset_workflow_definition d ON d.workflow_code = c.workflow_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = c.asset_id
      LEFT JOIN grac_practice.asset_workflow_step s ON s.workflow_code = c.workflow_code AND s.step_no = c.current_step_no
      LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = c.requested_by_employee_id
     WHERE c.organization_id = @organization_id
       AND (@asset_id IS NULL OR c.asset_id = @asset_id)
       AND (ISNULL(@open_only, 1) = 0 OR c.case_status = N'OPEN')
     ORDER BY CASE c.case_status WHEN N'OPEN' THEN 0 ELSE 1 END, c.requested_dt DESC, c.case_id DESC;
END
GO

-- 1. the case  2. its steps with the latest completion  3. every completion / rejection (history)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_workflow_case_get
    @organization_id   BIGINT,
    @case_id           BIGINT,
    @actor_employee_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_workflow_case WHERE case_id = @case_id AND organization_id = @organization_id)
        THROW 54451, 'Workflow case not found for this organization.', 1;
    SELECT c.case_id AS CaseId, c.asset_id AS AssetId, a.asset_name AS AssetName, c.workflow_code AS WorkflowCode,
           d.workflow_name AS WorkflowName, c.case_status AS CaseStatus, c.current_step_no AS CurrentStepNo,
           c.start_status_code AS StartStatusCode, c.reason AS Reason, c.reference_text AS ReferenceText,
           po.employee_name AS PreviousOwnerName, nw.employee_name AS NewOwnerName,
           ol.location_name AS OriginLocationName, dl.location_name AS DestLocationName,
           c.dest_building AS DestBuilding, c.dest_floor AS DestFloor, c.dest_room AS DestRoom, c.containment AS Containment,
           c.requested_by AS RequestedBy, rq.employee_name AS RequestedByName, c.requested_dt AS RequestedDt,
           c.closed_dt AS ClosedDt, c.cancel_reason AS CancelReason,
           CASE WHEN c.requested_by_employee_id = @actor_employee_id THEN 1 ELSE 0 END AS IsRequester,
           CASE WHEN c.previous_owner_id = @actor_employee_id THEN 1 ELSE 0 END AS IsPreviousOwner,
           CASE WHEN c.new_owner_id = @actor_employee_id THEN 1 ELSE 0 END AS IsNewOwner,
           CONVERT(BIGINT, c.record_version) AS RecordVersion
      FROM grac_practice.asset_workflow_case c
      JOIN grac_practice.asset_workflow_definition d ON d.workflow_code = c.workflow_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = c.asset_id
      LEFT JOIN grac_practice.organization_employee po ON po.employee_id = c.previous_owner_id
      LEFT JOIN grac_practice.organization_employee nw ON nw.employee_id = c.new_owner_id
      LEFT JOIN grac_practice.organization_location ol ON ol.location_id = c.origin_location_id
      LEFT JOIN grac_practice.organization_location dl ON dl.location_id = c.dest_location_id
      LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = c.requested_by_employee_id
     WHERE c.case_id = @case_id;

    SELECT s.step_no AS StepNo, s.step_code AS StepCode, s.step_name AS StepName, s.actor_kind AS ActorKind,
           s.requires_note AS RequiresNote, s.requires_evidence AS RequiresEvidence, s.requires_reference AS RequiresReference,
           s.lifecycle_to_status AS LifecycleToStatus, s.effect_code AS EffectCode, s.guidance AS Guidance,
           lastc.step_outcome AS LastOutcome, lastc.completed_by AS CompletedBy, lastc.completed_dt AS CompletedDt
      FROM grac_practice.asset_workflow_case c
      JOIN grac_practice.asset_workflow_step s ON s.workflow_code = c.workflow_code
      OUTER APPLY (SELECT TOP 1 cs.step_outcome, cs.completed_by, cs.completed_dt
                     FROM grac_practice.asset_workflow_case_step cs
                    WHERE cs.case_id = c.case_id AND cs.step_no = s.step_no
                    ORDER BY cs.completed_dt DESC, cs.case_step_id DESC) lastc
     WHERE c.case_id = @case_id
     ORDER BY s.step_no;

    SELECT cs.case_step_id AS CaseStepId, cs.step_no AS StepNo, s.step_name AS StepName, cs.step_outcome AS StepOutcome,
           cs.choice AS Choice, cs.note AS Note, cs.evidence_text AS EvidenceText, cs.reference_text AS ReferenceText,
           lc.from_status_code AS LifecycleFrom, lc.to_status_code AS LifecycleTo,
           cs.completed_by AS CompletedBy, e.employee_name AS CompletedByName, cs.completed_dt AS CompletedDt
      FROM grac_practice.asset_workflow_case_step cs
      JOIN grac_practice.asset_workflow_case c ON c.case_id = cs.case_id
      LEFT JOIN grac_practice.asset_workflow_step s ON s.workflow_code = c.workflow_code AND s.step_no = cs.step_no
      LEFT JOIN grac_practice.asset_lifecycle_change lc ON lc.change_id = cs.lifecycle_change_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = cs.completed_by_employee_id
     WHERE cs.case_id = @case_id
     ORDER BY cs.completed_dt DESC, cs.case_step_id DESC;
END
GO
PRINT '433: workflow readers created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '433-a the four BRD 11 workflows with their steps' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_workflow_definition) = 4
             AND (SELECT COUNT(*) FROM grac_practice.asset_workflow_step WHERE workflow_code = N'OWNER_CHANGE') = 7
             AND (SELECT COUNT(*) FROM grac_practice.asset_workflow_step WHERE workflow_code = N'LOCATION_TRANSFER') = 6
             AND (SELECT COUNT(*) FROM grac_practice.asset_workflow_step WHERE workflow_code = N'BREAKDOWN') = 7
             AND (SELECT COUNT(*) FROM grac_practice.asset_workflow_step WHERE workflow_code = N'DISPOSAL') = 10
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '433-b every lifecycle move a workflow makes is a seeded Asset status',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_workflow_step s
                              WHERE s.lifecycle_to_status IS NOT NULL
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = s.lifecycle_to_status))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '433-c the moves each workflow makes in order are configured transitions (429)',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'ACTIVE' AND to_status_code = N'OWNER_CHANGE_PENDING')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'OWNER_CHANGE_PENDING' AND to_status_code = N'ACTIVE')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'TRANSFER_PENDING' AND to_status_code = N'TRANSFERRED')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'TRANSFERRED' AND to_status_code = N'ACTIVE')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'QUARANTINED' AND to_status_code = N'REPAIR')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'REPAIR' AND to_status_code = N'ACTIVE')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'PENDING_DECOMMISSION' AND to_status_code = N'SANITIZATION_PENDING')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'SANITIZATION_PENDING' AND to_status_code = N'DISPOSAL_APPROVAL')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'DISPOSAL_APPROVAL' AND to_status_code = N'DISPOSED')
             AND EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND is_active = 1 AND from_status_code = N'DISPOSED' AND to_status_code = N'ARCHIVED')
            THEN 'PASS' ELSE 'FAIL: a PROPOSED 429 row a workflow needs was switched off' END
UNION ALL
SELECT '433-d tables, one-open-case index and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.asset_workflow_case','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_workflow_case_step','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_wf_case_open')
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_workflow_lifecycle', 'sp_asset_workflow_start', 'sp_asset_workflow_step_action',
                                'sp_asset_workflow_cancel', 'sp_asset_workflow_definitions', 'sp_asset_workflow_cases',
                                'sp_asset_workflow_case_get')) = 7
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs an Active asset with an owner, two more users with logins
--   (new owner; an approver who did not start the case).
--   1. Asset Register -> asset -> Workflows -> Start Owner change (new
--      owner, reason): the asset becomes Owner Change Pending; the case
--      shows step 2 of 7. A second case on the same asset is refused.
--   2. Validate, Handover (evidence required). Current owner confirm -- only
--      the current owner can; New owner accept -- only the new owner can
--      (sign in as each). Access review. Approve as the starter -- refused
--      (segregation); as the approver -- the owner changes, the Custody tab
--      shows a new assignment row (and an acknowledgement for the new owner
--      when the profile includes owners), the asset is Active, the Lifecycle
--      tab shows both moves.
--   3. Location transfer: building not in the destination site -- refused;
--      Transport moves the asset to Transferred; Approve sets the location,
--      raises a Transfer attestation (profile permitting), Active again.
--   4. Breakdown: Containment = Quarantine -> Quarantined; Diagnose with the
--      work order -> Repair; Repair, Test / calibrate (evidence); Approve
--      and return -> Active.
--   5. Disposal: Pending Decommission -> ... -> Sanitization Pending ->
--      Disposal Approval -> Disposed (legacy Decommissioned, decommissioning
--      event) -> Verify (not the starter) -> Archived.
--   6. Reject at an approval step (reason) -> the case returns one step.
--      Cancel (reason) by the starter -> Cancelled; the asset status stays
--      and is restored on the Lifecycle tab.
-- =====================================================================
