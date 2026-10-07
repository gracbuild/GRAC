-- =====================================================================
-- 429  Asset lifecycle transitions -- matrix, gates, approvals, history
--      (Asset & Contract Management, Phase 4 increment 2)
--
-- REQUEST
-- -------
--   BRD v1.7 19.9 "Lifecycle State Machine and Transition Rules" (from
--   state -> permitted targets -> minimum gate; "Disposed or Archived
--   records shall not return directly to Active"; "UI, API, import,
--   discovery and bulk operations use the same transition engine"; "A
--   failed side effect leaves a visible recoverable state and does not
--   silently complete the transition"), 5.4.3 "Lifecycle Transition
--   Governance" (minimum control per transition), 5.1.16 "Status
--   transition -- only configured transitions", 11 (owner change,
--   location transfer, breakdown and disposal workflows), 5.3.10 (a lost
--   asset's final status follows the approved investigation outcome),
--   17 "All status changes use configured transitions and required
--   approvals / evidence". Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. Transition matrix for entity Asset on the state-machine framework
--      (035, entity_state_transition_rule): every 19.9 row whose target
--      is one of the 27 BRD 5 statuses, the extra 5.4.3 transitions
--      (Draft -> Received, Received -> Active, Pending Decommission ->
--      Disposed), and -- marked PROPOSED / 11 / 5.3.10 -- exits for the
--      statuses 19.9 lists no row for (Storage, Owner Change Pending,
--      Transferred, Out of Service, Quarantined, Lost, Stolen, Recalled,
--      Obsolete, Non-Compliant), so no asset can be stranded. Every row
--      carries its BRD source; PROPOSED rows are for confirmation and can
--      be switched off (is_active = 0) without code (decision D16).
--      19.9 targets that are not BRD 5 statuses (Cancelled, Rejected,
--      Returned) are mapped only where an existing status says the same
--      thing; the rest are listed as open questions in the doc.
--   2. asset_lifecycle_transition_gate -- the minimum gate of each rule:
--      BRD source and wording, mapping note, reference label (a reference
--      is required when set: work order, purchase order, receipt ...),
--      evidence required, asset saved on its form template required,
--      owner required. Reason and approval use the framework's own
--      requires_reason / requires_approval columns (not duplicated).
--   3. asset_lifecycle_change -- one row per lifecycle change: the
--      reason, reference and evidence given, who asked, who decided, and
--      the transition-log row it produced. Changes without an approval
--      gate complete at once (COMPLETED); the others wait as
--      PENDING_APPROVAL (one per asset) until a different person approves
--      (APPROVED) or rejects (REJECTED), or the requester cancels.
--   4. sp_asset_lifecycle_transition -- the one transition engine for the
--      UI and the API: configured transition only, Disposed / Archived ->
--      Active refused outright, gates checked, then completed or queued.
--      sp_asset_lifecycle_decide -- approve / reject / cancel, with
--      segregation of duties (the requester cannot decide) and a re-check
--      that the asset is still in the status the request was made from.
--      sp_asset_lifecycle_apply (internal) -- logs the transition, sets the
--      status and keeps the legacy lifecycle_status in step (decision
--      D5): Planned -> Commissioned and -> Decommissioned go through the
--      existing sp_event_raise_asset_lifecycle, so the commissioning /
--      decommissioning event and its obligations are raised exactly as the
--      Commission / Decommission action does. If raising fails the whole
--      change is refused with the reason (19.9: nothing completes
--      silently).
--   5. Readers: sp_asset_lifecycle_get (current status, the moves open
--      from it with their gates, change history), sp_asset_lifecycle_matrix
--      (the whole matrix for review); sp_asset_register_list re-issued
--      with the pending change and a "pending approval only" filter.
--   6. Admin grant on Asset Register gains APPROVE.
--
-- NOT DONE HERE (later increments, see the doc): checklist / coverage /
--   dependency checks named in the gates (checklists Phase 6, coverage
--   Phase 5, relationships Phase 7) -- the gate text is shown and the
--   reference / evidence / approval it asks for are enforced; evidence is
--   a reference (document number, link), not an uploaded file, until the
--   task evidence of Phase 6; owner / location history and the owner
--   change hand-over steps (4.4); verification exceptions and security
--   review for Lost (4.5); restoring a Disposed / Archived asset through a
--   controlled correction workflow (not built -- refused).
--
-- ERROR NUMBERS: 54970-54999
--   54970 organization not found          54971 asset not found
--   54972 asset changed by someone else   54973 a change is awaiting approval
--   54974 transition not configured       54975 Disposed / Archived -> Active
--   54976 reason required                 54977 reference required
--   54978 evidence required               54979 save the asset on its form first
--   54980 owner required                  54981 change not found
--   54982 change no longer pending        54983 segregation of duties
--   54984 rejection needs a note          54985 only the requester can cancel
--   54986 asset status moved since request 54987 change edited by someone else
--   54988 unknown decision
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   asset-register.cshtml + asset-register.js, docs.
-- DEPENDS ON: 035, 335, 428.
-- Rollback: 429_asset_lifecycle_transitions_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_lifecycle_status_phase','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_register_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NULL
   OR (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'Asset') <> 27
BEGIN
    RAISERROR('ABORT (429): run 428 first (and 035 / 335).', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Gate table
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_lifecycle_transition_gate','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_lifecycle_transition_gate (
        transition_rule_id       INT            NOT NULL
            CONSTRAINT pk_pm_asset_lc_gate PRIMARY KEY
            CONSTRAINT fk_pm_asset_lc_gate_rule REFERENCES grac_practice.entity_state_transition_rule(transition_rule_id),
        brd_source               NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_lc_gate_source CHECK (brd_source IN
                (N'19.9', N'5.4.3', N'19.9 / 5.4.3', N'11', N'5.3.10', N'PROPOSED')),
        minimum_gate             NVARCHAR(400)  NOT NULL,
        mapping_note             NVARCHAR(400)  NULL,
        reference_label          NVARCHAR(200)  NULL,      -- set = a reference is required
        requires_evidence        BIT            NOT NULL CONSTRAINT df_pm_asset_lc_gate_ev DEFAULT 0,
        requires_registered_form BIT            NOT NULL CONSTRAINT df_pm_asset_lc_gate_form DEFAULT 0,
        requires_owner           BIT            NOT NULL CONSTRAINT df_pm_asset_lc_gate_owner DEFAULT 0,
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_lc_gate_eby DEFAULT N'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_asset_lc_gate_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL
    );
    PRINT '429: asset_lifecycle_transition_gate created.';
END
GO

-- =====================================================================
-- 2. The matrix (insert-only; an administrator's later change to a row
--    -- e.g. is_active = 0 on a PROPOSED row -- is never overwritten)
--    Columns: from, to, BRD source, reason, reference label, evidence,
--    approval, saved on form, owner, minimum gate, mapping note
-- =====================================================================
DECLARE @m TABLE (
    from_code NVARCHAR(60) NOT NULL, to_code NVARCHAR(60) NOT NULL, src NVARCHAR(30) NOT NULL,
    req_reason BIT NOT NULL, ref_label NVARCHAR(200) NULL, req_evidence BIT NOT NULL, req_approval BIT NOT NULL,
    req_form BIT NOT NULL, req_owner BIT NOT NULL, gate NVARCHAR(400) NOT NULL, note NVARCHAR(400) NULL,
    PRIMARY KEY (from_code, to_code));
INSERT @m (from_code, to_code, src, req_reason, ref_label, req_evidence, req_approval, req_form, req_owner, gate, note)
VALUES
-- ---------------------------------------------------------------- Acquisition (19.9)
(N'DRAFT', N'REQUESTED', N'19.9', 0, NULL, 0, 0, 1, 0, N'Required draft fields and authorization', NULL),
(N'DRAFT', N'RECEIVED', N'5.4.3', 0, NULL, 0, 0, 1, 1, N'Required identification, ownership and source validation', NULL),
(N'REQUESTED', N'APPROVED', N'19.9', 1, NULL, 0, 1, 1, 0, N'Approval and rationale', NULL),
(N'REQUESTED', N'DRAFT', N'19.9', 1, NULL, 0, 0, 0, 0, N'Approval and rationale',
    N'19.9 targets Rejected / Returned are not BRD 5 statuses; the request goes back to Draft for rework.'),
(N'APPROVED', N'ORDERED', N'19.9', 0, N'Purchase order / funding reference', 0, 0, 1, 0, N'Funding/procurement controls', NULL),
(N'ORDERED', N'RECEIVED', N'19.9', 0, N'Order and receipt reference', 0, 0, 1, 1, N'Order and receipt references', NULL),
-- ---------------------------------------------------------------- Readiness (19.9, 5.4.3)
(N'RECEIVED', N'UNDER_INSPECTION', N'19.9', 0, NULL, 0, 0, 1, 1, N'Identity, owner and source validation', NULL),
(N'RECEIVED', N'PENDING_INSTALLATION', N'19.9', 0, NULL, 0, 0, 1, 1, N'Identity, owner and source validation', NULL),
(N'RECEIVED', N'PENDING_COMMISSIONING', N'19.9', 0, NULL, 0, 0, 1, 1, N'Identity, owner and source validation', NULL),
(N'RECEIVED', N'ACTIVE', N'5.4.3', 0, NULL, 1, 1, 1, 1, N'Commissioning, mandatory checklist, applicable coverage and approval complete', NULL),
(N'UNDER_INSPECTION', N'ACTIVE', N'19.9', 0, NULL, 1, 1, 1, 1, N'Checklists, coverage, security/safety and approval', NULL),
(N'UNDER_INSPECTION', N'QUARANTINED', N'19.9', 1, NULL, 0, 0, 1, 0, N'Checklists, coverage, security/safety and approval', NULL),
(N'PENDING_COMMISSIONING', N'ACTIVE', N'19.9', 0, NULL, 1, 1, 1, 1, N'Checklists, coverage, security/safety and approval', NULL),
(N'PENDING_COMMISSIONING', N'QUARANTINED', N'19.9', 1, NULL, 0, 0, 1, 0, N'Checklists, coverage, security/safety and approval', NULL),
(N'UNDER_INSPECTION', N'PENDING_INSTALLATION', N'PROPOSED', 0, NULL, 0, 0, 1, 0, N'Inspection passed',
    N'Readiness order of BRD 5 (Under Inspection, Pending Installation, Pending Commissioning); 19.9 gives no row.'),
(N'UNDER_INSPECTION', N'PENDING_COMMISSIONING', N'PROPOSED', 0, NULL, 0, 0, 1, 0, N'Inspection passed',
    N'Readiness order of BRD 5; 19.9 gives no row.'),
(N'PENDING_INSTALLATION', N'PENDING_COMMISSIONING', N'PROPOSED', 0, NULL, 0, 0, 1, 0, N'Installation complete',
    N'Readiness order of BRD 5; 19.9 gives no row for Pending Installation.'),
-- ---------------------------------------------------------------- Operation (19.9, 5.4.3)
(N'ACTIVE', N'MAINTENANCE', N'19.9 / 5.4.3', 1, N'Work order or incident reference', 0, 0, 0, 0, N'Work order or incident reference and operational impact recorded', NULL),
(N'ACTIVE', N'REPAIR', N'19.9 / 5.4.3', 1, N'Work order or incident reference', 0, 0, 0, 0, N'Work order or incident reference and operational impact recorded', NULL),
(N'ACTIVE', N'TRANSFER_PENDING', N'19.9 / 5.4.3', 1, N'Destination and handover reference', 0, 0, 0, 0, N'Destination, handover, dependency and custody review', NULL),
(N'ACTIVE', N'OUT_OF_SERVICE', N'19.9', 1, N'Transition reference', 0, 0, 0, 0, N'Transition reference and impact review', NULL),
(N'ACTIVE', N'QUARANTINED', N'19.9', 1, N'Transition reference', 0, 0, 0, 0, N'Transition reference and impact review', NULL),
(N'ACTIVE', N'PENDING_DECOMMISSION', N'19.9 / 5.4.3', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review', NULL),
(N'MAINTENANCE', N'ACTIVE', N'19.9', 0, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'MAINTENANCE', N'OUT_OF_SERVICE', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'MAINTENANCE', N'QUARANTINED', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'MAINTENANCE', N'PENDING_DECOMMISSION', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'REPAIR', N'ACTIVE', N'19.9', 0, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'REPAIR', N'OUT_OF_SERVICE', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'REPAIR', N'QUARANTINED', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'REPAIR', N'PENDING_DECOMMISSION', N'19.9', 1, NULL, 1, 1, 0, 0, N'Work result, test and approval', NULL),
(N'OUT_OF_SERVICE', N'REPAIR', N'11', 1, N'Work order or incident reference', 0, 0, 0, 0, N'Breakdown: diagnose and repair',
    N'BRD 11 Breakdown workflow (Report -> Assess Impact -> Quarantine / Controlled Use -> Diagnose -> Repair -> Test -> Approve -> Return).'),
(N'OUT_OF_SERVICE', N'ACTIVE', N'PROPOSED', 0, NULL, 1, 1, 0, 0, N'Work result, test and approval',
    N'Mirrors the 19.9 Maintenance / Repair -> Active gate; 19.9 gives no row for Out of Service.'),
(N'OUT_OF_SERVICE', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review',
    N'Mirrors the 5.4.3 Active -> Pending Decommission control.'),
(N'QUARANTINED', N'REPAIR', N'11', 1, N'Work order or incident reference', 0, 0, 0, 0, N'Breakdown: diagnose and repair',
    N'BRD 11 Breakdown workflow (Quarantine / Controlled Use -> Diagnose -> Repair).'),
(N'QUARANTINED', N'ACTIVE', N'PROPOSED', 0, NULL, 1, 1, 0, 0, N'Checklists, coverage, security/safety and approval',
    N'Release from quarantine; mirrors the 19.9 Inspection / Commissioning -> Active gate.'),
(N'QUARANTINED', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review',
    N'Mirrors the 5.4.3 Active -> Pending Decommission control.'),
-- ---------------------------------------------------------------- Movement (19.9, 11)
(N'TRANSFER_PENDING', N'TRANSFERRED', N'19.9', 0, NULL, 1, 0, 0, 0, N'Handover, destination, custody and dependency controls', NULL),
(N'TRANSFER_PENDING', N'ACTIVE', N'19.9', 1, NULL, 0, 0, 0, 0, N'Handover, destination, custody and dependency controls',
    N'Covers the 19.9 target Cancelled: the transfer is cancelled and the asset stays in service.'),
(N'TRANSFERRED', N'ACTIVE', N'11', 0, NULL, 1, 1, 0, 0, N'Destination rule evaluation, install / validate and approval',
    N'BRD 11 Location Transfer (Request -> Origin Controls -> Transport -> Destination Rule Evaluation -> Install / Validate -> Approve).'),
(N'ACTIVE', N'OWNER_CHANGE_PENDING', N'11', 1, NULL, 0, 0, 0, 0, N'Owner change request validated',
    N'BRD 11 Owner Change (Request -> Validate -> Handover -> Current Owner Confirm -> New Owner Accept -> Access Review -> Approve). Hand-over steps arrive with 4.4.'),
(N'OWNER_CHANGE_PENDING', N'ACTIVE', N'11', 0, NULL, 0, 1, 0, 0, N'Handover, owner confirmation and acceptance, access review and approval',
    N'BRD 11 Owner Change: ends with Approve (or the request is withdrawn; give the reason in the note).'),
(N'ACTIVE', N'STORAGE', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Controlled storage location recorded',
    N'BRD 5 lists Storage (Movement) and 5.1 requires a storage location in storage; 19.9 gives no row.'),
(N'STORAGE', N'ACTIVE', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Returned to service', N'19.9 gives no row for Storage.'),
(N'STORAGE', N'TRANSFER_PENDING', N'PROPOSED', 1, N'Destination and handover reference', 0, 0, 0, 0, N'Destination, handover, dependency and custody review',
    N'Mirrors the 5.4.3 Active -> Transfer Pending control.'),
(N'STORAGE', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review',
    N'Mirrors the 5.4.3 Active -> Pending Decommission control.'),
-- ---------------------------------------------------------------- Exception (5.3.10, proposed)
(N'ACTIVE', N'LOST', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported lost', N'5.3.10: a Lost response opens the security review (verification exceptions arrive with 4.5).'),
(N'STORAGE', N'LOST', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported lost', NULL),
(N'TRANSFER_PENDING', N'LOST', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported lost', NULL),
(N'ACTIVE', N'STOLEN', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported stolen', N'Same security handling as Lost (5.3.10).'),
(N'STORAGE', N'STOLEN', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported stolen', NULL),
(N'TRANSFER_PENDING', N'STOLEN', N'5.3.10', 1, NULL, 0, 0, 0, 0, N'Asset reported stolen', NULL),
(N'LOST', N'ACTIVE', N'5.3.10', 1, NULL, 1, 1, 0, 0, N'Approved investigation outcome: recovered', N'5.3.10: the final status follows the approved investigation outcome.'),
(N'LOST', N'PENDING_DECOMMISSION', N'5.3.10', 1, NULL, 1, 1, 0, 0, N'Approved investigation outcome: write-off',
    N'5.3.10: never marked Disposed automatically; it goes through the retirement controls.'),
(N'STOLEN', N'ACTIVE', N'5.3.10', 1, NULL, 1, 1, 0, 0, N'Approved investigation outcome: recovered', NULL),
(N'STOLEN', N'PENDING_DECOMMISSION', N'5.3.10', 1, NULL, 1, 1, 0, 0, N'Approved investigation outcome: write-off', NULL),
(N'ACTIVE', N'RECALLED', N'PROPOSED', 1, N'Recall notice reference', 0, 0, 0, 0, N'Manufacturer / regulator recall recorded',
    N'BRD 5 lists Recalled (Exception); 5.1 recall status field. 19.9 gives no row.'),
(N'RECALLED', N'REPAIR', N'PROPOSED', 1, N'Work order or incident reference', 0, 0, 0, 0, N'Corrective action', NULL),
(N'RECALLED', N'ACTIVE', N'PROPOSED', 0, NULL, 1, 1, 0, 0, N'Corrective action complete, test and approval', NULL),
(N'RECALLED', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review', NULL),
(N'ACTIVE', N'OBSOLETE', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Obsolescence recorded', N'BRD 5 lists Obsolete (Exception); 19.9 gives no row.'),
(N'OBSOLETE', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review',
    N'5.1 decommission reason includes Obsolete.'),
(N'ACTIVE', N'NON_COMPLIANT', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Non-compliance recorded',
    N'BRD 5 lists Non-Compliant (Exception); 4.8: unsupported firmware / OS can set it unless an exception applies. 19.9 gives no row.'),
(N'NON_COMPLIANT', N'ACTIVE', N'PROPOSED', 0, NULL, 1, 1, 0, 0, N'Remediation verified or exception approved', NULL),
(N'NON_COMPLIANT', N'QUARANTINED', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Transition reference and impact review', NULL),
(N'NON_COMPLIANT', N'PENDING_DECOMMISSION', N'PROPOSED', 1, NULL, 0, 0, 0, 0, N'Dependency, service, contract, data and retention impact review', NULL),
-- ---------------------------------------------------------------- Retirement (19.9, 5.4.3)
(N'PENDING_DECOMMISSION', N'SANITIZATION_PENDING', N'19.9', 0, NULL, 0, 0, 0, 0, N'Dependency, retention, contract, access and data review', NULL),
(N'PENDING_DECOMMISSION', N'DISPOSAL_APPROVAL', N'19.9', 0, NULL, 0, 0, 0, 0, N'Dependency, retention, contract, access and data review', NULL),
(N'PENDING_DECOMMISSION', N'ACTIVE', N'19.9', 1, NULL, 0, 1, 0, 0, N'Dependency, retention, contract, access and data review',
    N'19.9 "approved cancellation": the decommission is cancelled and the asset returns to service.'),
(N'PENDING_DECOMMISSION', N'DISPOSED', N'5.4.3', 0, NULL, 1, 1, 0, 0, N'Sanitization, access/licence removal, evidence and final approval', NULL),
(N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL', N'19.9', 0, NULL, 1, 0, 0, 0, N'Sanitization evidence and verification', NULL),
(N'SANITIZATION_PENDING', N'PENDING_DECOMMISSION', N'19.9', 1, NULL, 0, 0, 0, 0, N'Sanitization evidence and verification',
    N'19.9 target Returned is not a BRD 5 status; the asset goes back to Pending Decommission.'),
(N'DISPOSAL_APPROVAL', N'DISPOSED', N'19.9', 0, NULL, 1, 1, 0, 0, N'Final authorization and evidence', NULL),
(N'DISPOSAL_APPROVAL', N'PENDING_DECOMMISSION', N'19.9', 1, NULL, 0, 0, 0, 0, N'Final authorization and evidence',
    N'19.9 target Returned is not a BRD 5 status; the asset goes back to Pending Decommission.'),
(N'DISPOSED', N'ARCHIVED', N'19.9', 1, NULL, 0, 0, 0, 0, N'Closure and retention controls', NULL);

-- Every code must be a seeded Asset status.
IF EXISTS (SELECT 1 FROM @m x
            WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = x.from_code)
               OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = x.to_code))
    THROW 54974, '429: the matrix names a status that is not seeded.', 1;

MERGE grac_practice.entity_state_transition_rule AS t
USING @m AS s
ON t.entity_type = N'Asset' AND t.from_status_code = s.from_code AND t.to_status_code = s.to_code AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'Asset', s.from_code, s.to_code, NULL, s.req_reason, s.req_approval, LEFT(CONCAT(N'BRD ', s.src, N': ', s.gate), 400), N'seed-429');
PRINT CONCAT('429: Asset transition rules inserted: ', @@ROWCOUNT);

MERGE grac_practice.asset_lifecycle_transition_gate AS t
USING (SELECT r.transition_rule_id, s.*
         FROM @m s
         JOIN grac_practice.entity_state_transition_rule r
           ON r.entity_type = N'Asset' AND r.from_status_code = s.from_code AND r.to_status_code = s.to_code
          AND r.actor_role_code IS NULL) AS s
ON t.transition_rule_id = s.transition_rule_id
WHEN NOT MATCHED BY TARGET THEN
    INSERT (transition_rule_id, brd_source, minimum_gate, mapping_note, reference_label, requires_evidence,
            requires_registered_form, requires_owner, entered_by)
    VALUES (s.transition_rule_id, s.src, s.gate, s.note, s.ref_label, s.req_evidence, s.req_form, s.req_owner, N'seed-429');
PRINT CONCAT('429: transition gates inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Lifecycle change record (completed at once, or awaiting approval)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_lifecycle_change (
        change_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_lc_change PRIMARY KEY,
        organization_id           BIGINT         NOT NULL,
        asset_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_lc_change_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        transition_rule_id        INT            NOT NULL
            CONSTRAINT fk_pm_asset_lc_change_rule REFERENCES grac_practice.entity_state_transition_rule(transition_rule_id),
        from_status_code          NVARCHAR(60)   NOT NULL,
        to_status_code            NVARCHAR(60)   NOT NULL,
        change_status             NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_lc_change_status CHECK (change_status IN
                (N'COMPLETED', N'PENDING_APPROVAL', N'APPROVED', N'REJECTED', N'CANCELLED')),
        reason_text               NVARCHAR(1000) NULL,
        reference_text            NVARCHAR(400)  NULL,
        evidence_text             NVARCHAR(1000) NULL,
        requested_by              NVARCHAR(100)  NOT NULL,
        requested_by_employee_id  BIGINT         NULL,
        requested_dt              DATETIME2      NOT NULL CONSTRAINT df_pm_asset_lc_change_rdt DEFAULT SYSUTCDATETIME(),
        decided_by                NVARCHAR(100)  NULL,
        decided_by_employee_id    BIGINT         NULL,
        decided_dt                DATETIME2      NULL,
        decision_note             NVARCHAR(1000) NULL,
        transition_log_id         BIGINT         NULL,     -- entity_state_transition_log row it produced
        record_version            ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_asset_lc_change_asset ON grac_practice.asset_lifecycle_change(asset_id, requested_dt DESC);
    CREATE INDEX ix_pm_asset_lc_change_org_status ON grac_practice.asset_lifecycle_change(organization_id, change_status);
    -- One change awaiting approval per asset.
    CREATE UNIQUE INDEX ux_pm_asset_lc_change_pending ON grac_practice.asset_lifecycle_change(asset_id)
        WHERE change_status = N'PENDING_APPROVAL';
    PRINT '429: asset_lifecycle_change created.';
END
GO

-- =====================================================================
-- 4. Engine
-- =====================================================================
-- Internal: performs one transition the caller has already validated.
-- Logs it (035), sets the register status and keeps the legacy
-- lifecycle_status in step; Planned -> Commissioned and -> Decommissioned
-- raise the asset lifecycle event through the existing procedure (335).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_apply
    @organization_id    BIGINT,
    @asset_id           BIGINT,
    @from_status_code   NVARCHAR(60),
    @to_status_code     NVARCHAR(60),
    @reason_code        NVARCHAR(60),
    @reason_text        NVARCHAR(1000) = NULL,
    @actor_employee_id  BIGINT         = NULL,
    @actor              NVARCHAR(100)  = N'system',
    @out_log_id         BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @current_id INT, @current_code NVARCHAR(60), @legacy_now NVARCHAR(30), @found BIT = 0;
    SELECT @found = 1, @current_id = a.current_status_id, @current_code = COALESCE(cs.status_code, ls.status_code),
           @legacy_now = a.lifecycle_status
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF ISNULL(@current_code, N'') <> @from_status_code
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    DECLARE @legacy_to NVARCHAR(30);
    SELECT @legacy_to = legacy_lifecycle_status FROM grac_practice.asset_lifecycle_status_phase WHERE status_code = @to_status_code;
    DECLARE @to_id INT, @log_id BIGINT, @raised INT = 0;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'Asset', @entity_id = @asset_id,
         @from_status_code = @from_status_code, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    -- Optimistic: the status must still be the one the caller validated.
    UPDATE grac_practice.organization_dependency_asset
       SET current_status_id = @to_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE asset_id = @asset_id AND organization_id = @organization_id
       AND ISNULL(current_status_id, -1) = ISNULL(@current_id, -1);
    IF @@ROWCOUNT <> 1
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;

    IF @legacy_to = N'Commissioned' AND @legacy_now IN (N'Planned', N'Decommissioned')
        EXEC grac_practice.sp_event_raise_asset_lifecycle
             @organization_id = @organization_id, @asset_id = @asset_id, @lifecycle_action = N'COMMISSION',
             @trigger_source = N'AssetLifecycle', @actor_employee_id = @actor_employee_id,
             @out_raised_count = @raised OUTPUT;
    ELSE IF @legacy_to = N'Decommissioned' AND ISNULL(@legacy_now, N'') <> N'Decommissioned'
        EXEC grac_practice.sp_event_raise_asset_lifecycle
             @organization_id = @organization_id, @asset_id = @asset_id, @lifecycle_action = N'DECOMMISSION',
             @trigger_source = N'AssetLifecycle', @actor_employee_id = @actor_employee_id,
             @out_raised_count = @raised OUTPUT;
    ELSE IF ISNULL(@legacy_now, N'') <> @legacy_to
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = @legacy_to
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
    COMMIT;

    SET @out_log_id = @log_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_transition
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_change_id           BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54970, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @from NVARCHAR(60), @template_id BIGINT, @owner_id BIGINT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, a.record_version), @from = COALESCE(cs.status_code, ls.status_code),
           @template_id = a.template_id, @owner_id = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54973, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    IF @from IN (N'DISPOSED', N'ARCHIVED') AND @to_status_code = N'ACTIVE'
        THROW 54975, 'A disposed or archived asset cannot return to Active (BRD 5.4.3 / 19.9). Register a replacement asset instead.', 1;

    DECLARE @rule_id INT, @req_reason BIT, @req_approval BIT, @ref_label NVARCHAR(200), @req_evidence BIT,
            @req_form BIT, @req_owner BIT;
    SELECT TOP 1 @rule_id = r.transition_rule_id, @req_reason = r.requires_reason, @req_approval = r.requires_approval,
           @ref_label = g.reference_label, @req_evidence = g.requires_evidence, @req_form = g.requires_registered_form,
           @req_owner = g.requires_owner
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule_id IS NULL
    BEGIN
        DECLARE @allowed NVARCHAR(1000) = (
            SELECT STRING_AGG(s.status_name, N', ') WITHIN GROUP (ORDER BY s.display_order)
              FROM grac_practice.entity_state_transition_rule r
              JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
              JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
             WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL AND r.from_status_code = @from);
        DECLARE @from_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                             WHERE entity_type = N'Asset' AND status_code = @from);
        DECLARE @target_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                               WHERE entity_type = N'Asset' AND status_code = @to_status_code);
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'This asset cannot move from ', ISNULL(@from_name, @from), N' to ',
            ISNULL(@target_name, @to_status_code), N'. Configured moves: ', ISNULL(@allowed, N'none'), N'.');
        THROW 54974, @msg, 1;
    END

    IF @req_form = 1 AND @template_id IS NULL
        THROW 54979, 'Open the asset and save it on its form template first, so its required fields are validated.', 1;
    IF @req_owner = 1 AND @owner_id IS NULL
        THROW 54980, 'Set the asset owner first (identity, owner and source validation).', 1;
    IF @req_reason = 1 AND @reason_text IS NULL
        THROW 54976, 'A reason is required for this change.', 1;
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N'.');
        THROW 54977, @ref_msg, 1;
    END
    IF @req_evidence = 1 AND @evidence_text IS NULL
        THROW 54978, 'Evidence is required for this change (document number, report or link).', 1;

    DECLARE @log_id BIGINT;
    BEGIN TRAN;
    IF @req_approval = 1
    BEGIN
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'PENDING_APPROVAL',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to_status_code,
             @reason_code = N'LIFECYCLE', @reason_text = @reason_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'COMPLETED',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id, @log_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'COMPLETED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, CASE WHEN @req_approval = 1 THEN N'REQUEST' ELSE N'TRANSITION' END,
            (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @out_change_id AS changeId, @to_status_code AS toStatusCode, @out_result AS result,
                    @reason_text AS reason, @reference_text AS reference, @evidence_text AS evidence, @log_id AS transitionLogId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_change_id AS ChangeId, @out_result AS Result,
           CASE WHEN @out_result = N'COMPLETED' THEN @to_status_code ELSE @from END AS StatusCode;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_decide
    @organization_id         BIGINT,
    @change_id               BIGINT,
    @decision                NVARCHAR(10),
    @decision_note           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @decision = UPPER(LTRIM(RTRIM(ISNULL(@decision, N''))));
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');

    DECLARE @found BIT = 0, @asset_id BIGINT, @rule_id INT, @from NVARCHAR(60), @to NVARCHAR(60), @status NVARCHAR(20),
            @rv BIGINT, @req_by NVARCHAR(100), @req_emp BIGINT, @reason NVARCHAR(1000);
    SELECT @found = 1, @asset_id = asset_id, @rule_id = transition_rule_id, @from = from_status_code, @to = to_status_code,
           @status = change_status, @rv = CONVERT(BIGINT, record_version), @req_by = requested_by,
           @req_emp = requested_by_employee_id, @reason = reason_text
      FROM grac_practice.asset_lifecycle_change
     WHERE change_id = @change_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54981, 'Lifecycle change not found for this organization.', 1;
    IF @decision NOT IN (N'APPROVE', N'REJECT', N'CANCEL')
        THROW 54988, 'The decision must be Approve, Reject or Cancel.', 1;
    IF @status <> N'PENDING_APPROVAL'
        THROW 54982, 'This change is no longer awaiting approval.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54987, 'This change was updated by someone else. Reload and try again.', 1;
    IF @decision = N'CANCEL' AND @req_by <> @actor
        THROW 54985, 'Only the person who asked for this change can cancel it.', 1;
    IF @decision IN (N'APPROVE', N'REJECT')
       AND (@req_by = @actor OR (@req_emp IS NOT NULL AND @req_emp = @actor_employee_id))
        THROW 54983, 'Segregation of duties: the person who asked for this change cannot approve or reject it.', 1;
    IF @decision = N'REJECT' AND @decision_note IS NULL
        THROW 54984, 'Give the reason for rejecting this change.', 1;

    DECLARE @log_id BIGINT;
    IF @decision = N'APPROVE'
    BEGIN
        DECLARE @now_code NVARCHAR(60);
        SELECT @now_code = COALESCE(cs.status_code, ls.status_code)
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
         WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
        IF ISNULL(@now_code, N'') <> @from
            THROW 54986, 'The asset is no longer in the status this change was requested from. Reject it and ask again.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE transition_rule_id = @rule_id AND is_active = 1)
            THROW 54974, 'This transition is no longer configured. Reject the change.', 1;
    END

    BEGIN TRAN;
    IF @decision = N'APPROVE'
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to,
             @reason_code = N'APPROVED', @reason_text = @reason,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
    UPDATE grac_practice.asset_lifecycle_change
       SET change_status = CASE @decision WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'CANCELLED' END,
           decided_by = @actor, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME(),
           decision_note = @decision_note, transition_log_id = @log_id
     WHERE change_id = @change_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, @decision,
            (SELECT @change_id AS changeId, N'PENDING_APPROVAL' AS changeStatus FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @change_id AS changeId, @decision AS decision, @decision_note AS note, @from AS fromStatusCode,
                    @to AS toStatusCode, @log_id AS transitionLogId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @change_id AS ChangeId, CASE @decision WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'CANCELLED' END AS Result;
END
GO
PRINT '429: lifecycle engine created.';
GO

-- =====================================================================
-- 5. Readers
-- =====================================================================
-- 1. current status  2. moves open from it (none while a change waits)
-- 3. change history
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54971, 'Asset not found for this organization.', 1;

    DECLARE @from NVARCHAR(60), @has_form BIT, @has_owner BIT, @rv BIGINT;
    SELECT @from = COALESCE(cs.status_code, ls.status_code),
           @has_form = CASE WHEN a.template_id IS NULL THEN 0 ELSE 1 END,
           @has_owner = CASE WHEN a.owner_id IS NULL THEN 0 ELSE 1 END,
           @rv = CONVERT(BIGINT, a.record_version)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id;
    DECLARE @pending BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change
                                              WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL') THEN 1 ELSE 0 END;

    SELECT @asset_id AS AssetId, @from AS StatusCode, s.status_name AS StatusName, p.phase_name AS PhaseName,
           @rv AS RecordVersion, @has_form AS HasForm, @has_owner AS HasOwner, @pending AS HasPendingChange
      FROM grac_practice.entity_status_master s
      LEFT JOIN grac_practice.asset_lifecycle_status_phase p ON p.status_code = s.status_code
     WHERE s.entity_type = N'Asset' AND s.status_code = @from;

    SELECT r.to_status_code AS ToStatusCode, s.status_name AS ToStatusName, p.phase_name AS ToPhaseName,
           g.brd_source AS BrdSource, g.minimum_gate AS MinimumGate, g.mapping_note AS MappingNote,
           r.requires_reason AS RequiresReason, g.reference_label AS ReferenceLabel, g.requires_evidence AS RequiresEvidence,
           r.requires_approval AS RequiresApproval, g.requires_registered_form AS RequiresRegisteredForm,
           g.requires_owner AS RequiresOwner,
           CASE WHEN g.requires_registered_form = 1 AND @has_form = 0 THEN N'Save the asset on its form template first.'
                WHEN g.requires_owner = 1 AND @has_owner = 0 THEN N'Set the asset owner first.' END AS BlockedReason
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
      JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase p ON p.status_code = r.to_status_code
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND @pending = 0
     ORDER BY s.display_order;

    SELECT c.change_id AS ChangeId, c.from_status_code AS FromStatusCode, fs.status_name AS FromStatusName,
           c.to_status_code AS ToStatusCode, ts.status_name AS ToStatusName, c.change_status AS ChangeStatus,
           c.reason_text AS ReasonText, c.reference_text AS ReferenceText, c.evidence_text AS EvidenceText,
           g.reference_label AS ReferenceLabel,
           c.requested_by AS RequestedBy, c.requested_by_employee_id AS RequestedByEmployeeId, re.employee_name AS RequestedByName,
           c.requested_dt AS RequestedDt, c.decided_by AS DecidedBy, de.employee_name AS DecidedByName, c.decided_dt AS DecidedDt,
           c.decision_note AS DecisionNote, CONVERT(BIGINT, c.record_version) AS RecordVersion
      FROM grac_practice.asset_lifecycle_change c
      LEFT JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = c.transition_rule_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_type = N'Asset' AND fs.status_code = c.from_status_code
      LEFT JOIN grac_practice.entity_status_master ts ON ts.entity_type = N'Asset' AND ts.status_code = c.to_status_code
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = c.requested_by_employee_id
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = c.decided_by_employee_id
     WHERE c.asset_id = @asset_id
     ORDER BY c.requested_dt DESC, c.change_id DESC;
END
GO

-- The whole matrix, for review (D16).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_matrix
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.transition_rule_id AS TransitionRuleId,
           r.from_status_code AS FromStatusCode, fs.status_name AS FromStatusName, fp.phase_name AS FromPhaseName,
           r.to_status_code AS ToStatusCode, ts.status_name AS ToStatusName, tp.phase_name AS ToPhaseName,
           g.brd_source AS BrdSource, g.minimum_gate AS MinimumGate, g.mapping_note AS MappingNote,
           r.requires_reason AS RequiresReason, g.reference_label AS ReferenceLabel, g.requires_evidence AS RequiresEvidence,
           r.requires_approval AS RequiresApproval, g.requires_registered_form AS RequiresRegisteredForm,
           g.requires_owner AS RequiresOwner, r.is_active AS IsActive
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
      JOIN grac_practice.entity_status_master fs ON fs.entity_type = N'Asset' AND fs.status_code = r.from_status_code
      JOIN grac_practice.entity_status_master ts ON ts.entity_type = N'Asset' AND ts.status_code = r.to_status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase fp ON fp.status_code = r.from_status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase tp ON tp.status_code = r.to_status_code
     WHERE r.entity_type = N'Asset'
     ORDER BY fs.display_order, ts.display_order;
END
GO

-- 428 list, re-issued: + the change awaiting approval and a filter for it.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @pending_only    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    SET @pending_only = ISNULL(@pending_only, 0);

    ;WITH rows_ AS (
        SELECT a.asset_id, a.asset_name, a.asset_type_id, a.template_id, a.owner_id, a.location_id, a.criticality_id,
               a.asset_category_id, a.asset_subcategory_id, a.updated_dt, a.entered_dt,
               COALESCE(cs.status_code, ls.status_code) AS status_code
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
         WHERE a.organization_id = @organization_id
           AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(a.asset_id AS NVARCHAR(30)) = @search)
    )
    SELECT r.asset_id AS AssetId, r.asset_name AS AssetName,
           c.asset_category_name AS CategoryName, s.subcategory_name AS SubcategoryName,
           r.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           r.status_code AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           r.template_id AS TemplateId, tpl.version_no AS TemplateVersion,
           e.employee_name AS OwnerName, l.location_name AS LocationName, cr.criticality_name AS CriticalityName,
           ISNULL(r.updated_dt, r.entered_dt) AS LastChanged,
           pc.change_id AS PendingChangeId, pcs.status_name AS PendingToStatusName,
           COUNT(*) OVER () AS TotalRows
      FROM rows_ r
      LEFT JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = r.asset_category_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = r.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = r.asset_type_id
      LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = r.status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase ph ON ph.status_code = r.status_code
      LEFT JOIN grac_practice.asset_form_template tpl ON tpl.template_id = r.template_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = r.location_id
      LEFT JOIN grac_practice.criticality_master cr ON cr.criticality_id = r.criticality_id
      LEFT JOIN grac_practice.asset_lifecycle_change pc ON pc.asset_id = r.asset_id AND pc.change_status = N'PENDING_APPROVAL'
      LEFT JOIN grac_practice.entity_status_master pcs ON pcs.entity_type = N'Asset' AND pcs.status_code = pc.to_status_code
     WHERE (@status_code IS NULL OR r.status_code = @status_code)
       AND (@pending_only = 0 OR pc.change_id IS NOT NULL)
     ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.asset_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '429: lifecycle readers created; sp_asset_register_list re-issued.';
GO

-- =====================================================================
-- 6. Admin grant: Asset Register APPROVE (lifecycle approvals)
-- =====================================================================
UPDATE p
   SET can_approve = 1, updated_by = N'seed-429', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.organization_role r ON r.role_id = p.role_id AND r.role_name = N'Admin' AND r.status = N'Active'
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id AND m.menu_key = N'asset-register'
 WHERE p.can_approve = 0;
PRINT CONCAT('429: Admin APPROVE grants set: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '429-a every Asset transition rule (except creation) has a gate' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule r
                              WHERE r.entity_type = N'Asset' AND r.from_status_code IS NOT NULL
                                AND r.actor_role_code IS NULL   -- 444: role-bound merge rules have no gate
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_transition_gate g
                                                 WHERE g.transition_rule_id = r.transition_rule_id))
             AND (SELECT COUNT(*) FROM grac_practice.asset_lifecycle_transition_gate) >= 75
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '429-b no configured way back from Disposed / Archived to Active (5.4.3 / 19.9)',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule
                              WHERE entity_type = N'Asset' AND is_active = 1
                                AND actor_role_code IS NULL   -- 444: merge recovery (ASSET_MERGE) is not a user move
                                AND from_status_code IN (N'DISPOSED', N'ARCHIVED') AND to_status_code <> N'ARCHIVED')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '429-c every non-terminal status has a configured way out',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.entity_status_master s
                              WHERE s.entity_type = N'Asset' AND s.is_terminal = 0
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule r
                                                 WHERE r.entity_type = N'Asset' AND r.from_status_code = s.status_code))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '429-d change table + one-pending index present',
       CASE WHEN OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_lc_change_pending') THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '429-e procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_lifecycle_apply', 'sp_asset_lifecycle_transition', 'sp_asset_lifecycle_decide',
                                'sp_asset_lifecycle_get', 'sp_asset_lifecycle_matrix')) = 5
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_list')) LIKE '%pending_only%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '429-f Admin can approve on Asset Register',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission p
                               JOIN grac_practice.organization_role r ON r.role_id = p.role_id AND r.role_name = N'Admin' AND r.status = N'Active'
                               JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id AND m.menu_key = N'asset-register'
                              WHERE p.can_approve = 0) THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the APPROVE grant)
--   1. Asset Register -> open a Draft asset saved on its form. Lifecycle
--      shows the moves open from Draft (Requested, Received) with their
--      BRD gate; Received asks for the owner first if none is set.
--   2. Draft -> Requested completes at once (history row, status chip).
--   3. Requested -> Approved needs a reason and waits for approval; the
--      list shows "awaiting Approved" and "Pending approval only" finds
--      it. The same user's Approve is refused (segregation of duties);
--      another user with APPROVE approves -> status Approved.
--   4. Approved -> Ordered without a purchase order reference is refused.
--   5. Take an asset to Active (e.g. Received -> Active with evidence and
--      approval): its legacy lifecycle becomes Commissioned and the asset
--      commissioning event is raised (Events / obligations show it).
--   6. Active -> Pending Decommission -> Disposed (evidence + approval):
--      legacy Decommissioned, decommissioning event raised. Disposed ->
--      Active is refused; only Archived is offered.
--   7. Reject needs a note; the requester can cancel their own request.
--   8. Transition rules (list toolbar) shows the whole matrix with its
--      BRD source; PROPOSED rows are the ones to confirm (D16).
-- =====================================================================
