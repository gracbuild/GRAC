-- =====================================================================
-- 439  Asset activity results, approvals, reschedule / waive / not
--      applicable / exception, evidence expiry and restrictive-use
--      reviews (Asset & Contract Management, Phase 6 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 7.1 (an activity that produces an asset-specific result,
--   certificate or pass / fail decision is an individual asset task);
--   7.1.2 calibration (result, certificate, pass / fail, reviewer approval
--   and next date per asset; "Calibration fails: set Calibration Status to
--   Failed; create repair, adjustment, recalibration or restricted-use
--   action; the asset cannot return to compliant / active use until the
--   acceptance criteria are met"); 7.1.3 standalone licence renewed /
--   not renewed; 7.1.5 "Rescheduled, waived, not-applicable and exception
--   outcomes require a reason, approver where configured and a new review /
--   expiry date"; 7.1.6 (calibration task approved -> last date, next date,
--   certificate, status Valid; calibration overdue -> evaluate restricted
--   use based on criticality; calibration failed -> status Failed and a
--   recalibration task; standalone licence renewed -> expiry; licence
--   expired -> remediation); 5.1.7 (last calibration date cannot be in the
--   future; calibration status N/A / Valid / Due Soon / Overdue / Failed;
--   certificate number required after a successful calibration;
--   certificate expiry must follow the certificate issue date and drives
--   evidence-expiry notifications); 9.1 "Snooze / reschedule: reason,
--   revised date and audit record mandatory"; "completion, cancellation or
--   approved rescheduling recalculates future notifications without
--   deleting"; 9.1.4 (failed calibration -> critical notification);
--   9.1.7 (evidence-expiry reminders from certificate, insurance, licence
--   and other evidence expiry dates); 9.1.9 restrictive actions
--   (calibration expired, vehicle insurance / fitness / permit expired,
--   licence expired). Plan: docs/asset-contract-management.md (Phase 6.3,
--   D69-D80).
--
-- WHAT THIS DOES
-- --------------
--   1. Activity results (asset_activity_result, one per occurrence): the
--      outcome (Pass / Fail for execution, Renewed / Not renewed for
--      renewal), performed date, certificate number and expiry, new expiry,
--      evidence reference and note. Draft -> Submitted -> Approved (or
--      Returned) by another person when the organization requires a
--      reviewer for the activity (Calibration by default); otherwise the
--      submitted result is approved at once.
--   2. An approved result completes the occurrence on the performed date and
--      writes the register: last date (Pass), certificate number and expiry
--      (Pass), new expiry (Renewed). A Fail opens a re-test occurrence
--      after the re-test days (status Failed, critical notification); a Not
--      renewed lets the expiry pass (Overdue -> restrictive review).
--   3. A Task Centre task closed without an approved result no longer
--      completes a result activity: the occurrence stays open and is flagged.
--   4. Dispositions (asset_activity_disposition): Reschedule (revised due
--      date), Waive, Not applicable, Exception (review date) with a reason;
--      approved by another person when the organization requires it (the
--      default). Reschedule moves the due date of the occurrence, its task
--      SLA and its notifications; the others close the occurrence as Waived
--      until the review date and cancel the open task.
--   5. Evidence expiry: a catalogue of evidence date fields (calibration
--      certificate, insurance, fitness, pollution, permit, registration,
--      road tax); the 437 Evidence / certificate expiry profile now has a
--      source (sweep re-issued; parties re-issued with the evidence owner).
--   6. Restrictive-use reviews (asset_restrictive_review, 9.1.9): raised by
--      the scheduler for a failed result, an overdue activity on an asset
--      whose criticality the policy names (calibration: Critical and High),
--      an expired equipment licence and expired restricting evidence
--      (insurance, fitness, permit, registration); decided with one of the
--      BRD actions and a note; resolved automatically when the cause clears.
--   7. Organization settings per activity: reviewer required, approval of
--      dispositions required, restricted-use policy on overdue and on fail.
--   8. Readers / writers for the Asset Activities screen.
--
-- NOT DONE HERE: the Task Centre task is not closed by an approved result
--   (its owner completes it; sp_task_complete returns a result set);
--   lifecycle changes from a review decision (the 429 Lifecycle tab is
--   used); linked control status from expired evidence (Phase 8);
--   attachments (evidence is a reference); corrective-action task types.
--
-- ERROR NUMBERS: 54670-54699
--   54670 occurrence not found              54671 occurrence not open / not an asset task
--   54672 outcome not valid for activity    54673 performed date missing or in the future
--   54674 certificate number required       54675 certificate expiry before performed date
--   54676 new expiry required / too early   54677 note / reason required
--   54678 result not in a state for that    54679 segregation of duties
--   54680 changed by someone else           54681 decision not valid
--   54682 disposition type not valid        54683 revised due date not valid
--   54684 review date not valid             54685 a disposition is already pending
--   54686 disposition not found             54687 disposition not pending / not yours
--   54688 review not found                  54689 review action not valid for the trigger
--   54690 review already resolved           54691 restricted-use policy not valid
--   54692 unknown template / organization
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   asset-activities.cshtml / .js, docs.
-- DEPENDS ON: 192-196, 437, 438.
-- Rollback: 439_asset_activity_results_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_activity_run','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_activity_occurrence','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_activity_add','P') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','approved_extended_due_at') IS NULL
BEGIN
    RAISERROR('ABORT (439): run 192-196, 437 and 438 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Template result / disposition / restriction defaults (global)
-- =====================================================================
IF COL_LENGTH('grac_practice.asset_activity_template', 'result_required') IS NULL
    ALTER TABLE grac_practice.asset_activity_template ADD
        result_required              BIT           NOT NULL CONSTRAINT df_pm_asset_act_tpl_resreq DEFAULT 1,
        default_result_review        BIT           NOT NULL CONSTRAINT df_pm_asset_act_tpl_review DEFAULT 0,
        default_disposition_approval BIT           NOT NULL CONSTRAINT df_pm_asset_act_tpl_dispapp DEFAULT 1,
        retest_days                  INT           NULL,
        certificate_number_field_key NVARCHAR(100) NULL,
        certificate_expiry_field_key NVARCHAR(100) NULL,
        default_restrict_on_overdue  NVARCHAR(100) NULL,     -- ALL | NONE | CRITICAL,HIGH,MEDIUM,LOW
        default_restrict_on_fail     BIT           NOT NULL CONSTRAINT df_pm_asset_act_tpl_rfail DEFAULT 0;
GO

-- The templates are system-maintained (no editing screen): the values are set
-- on every run.
UPDATE t
   SET result_required = 1, default_result_review = x.review, default_disposition_approval = 1, retest_days = x.retest,
       certificate_number_field_key = x.cert_no, certificate_expiry_field_key = x.cert_exp,
       default_restrict_on_overdue = x.on_overdue, default_restrict_on_fail = x.on_fail
  FROM grac_practice.asset_activity_template t
  JOIN (VALUES (N'CALIBRATION',            1, 7,    N'calibration_certificate_number', N'calibration_certificate_expiry', N'CRITICAL,HIGH', 1),
               (N'PREVENTIVE_MAINTENANCE', 0, 7,    NULL, NULL, NULL,  0),
               (N'STATUTORY_INSPECTION',   0, 7,    NULL, NULL, NULL,  0),
               (N'EQUIPMENT_LICENCE',      0, NULL, NULL, NULL, N'ALL', 0))
       AS x(template_code, review, retest, cert_no, cert_exp, on_overdue, on_fail)
    ON x.template_code = t.template_code;
PRINT CONCAT('439: template result defaults set: ', @@ROWCOUNT);
GO

-- Organization overrides (NULL = the template default).
IF COL_LENGTH('grac_practice.asset_activity_setting', 'result_review_required') IS NULL
    ALTER TABLE grac_practice.asset_activity_setting ADD
        result_review_required        BIT           NULL,
        disposition_approval_required BIT           NULL,
        restrict_on_overdue           NVARCHAR(100) NULL,
        restrict_on_fail              BIT           NULL;
GO

-- =====================================================================
-- 2. Occurrence / schedule columns, widened vocabularies
-- =====================================================================
IF COL_LENGTH('grac_practice.asset_activity_occurrence', 'revised_due_date') IS NULL
    ALTER TABLE grac_practice.asset_activity_occurrence ADD
        revised_due_date DATE NULL,      -- approved reschedule
        review_date      DATE NULL,      -- waived / not applicable / exception until
        is_retest        BIT  NOT NULL CONSTRAINT df_pm_asset_act_occ_retest DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_asset_act_occ_status' AND definition LIKE '%WAIVED%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_act_occ_status')
        ALTER TABLE grac_practice.asset_activity_occurrence DROP CONSTRAINT ck_pm_asset_act_occ_status;
    ALTER TABLE grac_practice.asset_activity_occurrence WITH CHECK
        ADD CONSTRAINT ck_pm_asset_act_occ_status
            CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED', N'COVERED', N'WAIVED'));
    PRINT '439: occurrence statuses widened (WAIVED).';
END
GO

IF COL_LENGTH('grac_practice.asset_activity_schedule', 'revised_due_date') IS NULL
    ALTER TABLE grac_practice.asset_activity_schedule ADD revised_due_date DATE NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%ASSET_EVIDENCE%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj')
        ALTER TABLE grac_practice.asset_notification_occurrence DROP CONSTRAINT ck_pm_asset_ntf_occ_obj;
    ALTER TABLE grac_practice.asset_notification_occurrence WITH NOCHECK
        ADD CONSTRAINT ck_pm_asset_ntf_occ_obj
            CHECK (object_type IN (N'CONTRACT_VERSION', N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE',
                                   N'TECH_EXCEPTION', N'ATTESTATION', N'ACTIVITY', N'ASSET_EVIDENCE'));
    PRINT '439: notification object types widened (ASSET_EVIDENCE).';
END
GO

UPDATE grac_practice.asset_notification_activity
   SET source_available = 1, source_note = N'Raised from the evidence date fields of the asset register (439).'
 WHERE activity_code = N'EVIDENCE_EXPIRY' AND source_available = 0;
PRINT CONCAT('439: evidence expiry has a source now: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Results
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_activity_result','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_result (
        result_id                BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_act_res PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        occurrence_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_act_res_occ REFERENCES grac_practice.asset_activity_occurrence(occurrence_id),
        state                    NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_act_res_state CHECK (state IN (N'DRAFT', N'SUBMITTED', N'RETURNED', N'APPROVED')),
        outcome                  NVARCHAR(12)   NULL
            CONSTRAINT ck_pm_asset_act_res_outcome CHECK (outcome IS NULL OR outcome IN (N'PASS', N'FAIL', N'RENEWED', N'NOT_RENEWED')),
        performed_date           DATE           NULL,
        certificate_number       NVARCHAR(100)  NULL,
        certificate_expiry       DATE           NULL,
        new_expiry               DATE           NULL,
        evidence_reference       NVARCHAR(400)  NULL,
        result_note              NVARCHAR(2000) NULL,
        submitted_by             NVARCHAR(100)  NULL,
        submitted_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_res_sub REFERENCES grac_practice.organization_employee(employee_id),
        submitted_dt             DATETIME2      NULL,
        decided_by               NVARCHAR(100)  NULL,
        decided_by_employee_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_res_dec REFERENCES grac_practice.organization_employee(employee_id),
        decided_dt               DATETIME2      NULL,
        decision_note            NVARCHAR(1000) NULL,
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_act_res_eby DEFAULT N'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_asset_act_res_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL,
        record_version           ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_asset_act_res_occ UNIQUE (occurrence_id)
    );
    CREATE INDEX ix_pm_asset_act_res_org ON grac_practice.asset_activity_result(organization_id, state);
    PRINT '439: asset_activity_result created.';
END
GO

-- =====================================================================
-- 4. Dispositions (7.1.5)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_activity_disposition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_disposition (
        disposition_id           BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_act_disp PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        occurrence_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_act_disp_occ REFERENCES grac_practice.asset_activity_occurrence(occurrence_id),
        disposition_type         NVARCHAR(16)   NOT NULL
            CONSTRAINT ck_pm_asset_act_disp_type CHECK (disposition_type IN (N'RESCHEDULE', N'WAIVE', N'NOT_APPLICABLE', N'EXCEPTION')),
        reason                   NVARCHAR(1000) NOT NULL,
        previous_due_date        DATE           NOT NULL,
        revised_due_date         DATE           NULL,
        review_date              DATE           NULL,
        status                   NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_act_disp_status CHECK (status IN (N'PENDING', N'APPROVED', N'REJECTED', N'WITHDRAWN')),
        requested_by             NVARCHAR(100)  NOT NULL,
        requested_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_disp_req REFERENCES grac_practice.organization_employee(employee_id),
        requested_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_act_disp_rdt DEFAULT SYSUTCDATETIME(),
        decided_by               NVARCHAR(100)  NULL,
        decided_by_employee_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_disp_dec REFERENCES grac_practice.organization_employee(employee_id),
        decided_dt               DATETIME2      NULL,
        decision_note            NVARCHAR(1000) NULL,
        task_note                NVARCHAR(400)  NULL,      -- what happened to the Task Centre task
        record_version           ROWVERSION     NOT NULL
    );
    CREATE UNIQUE INDEX ux_pm_asset_act_disp_pending ON grac_practice.asset_activity_disposition(occurrence_id) WHERE status = N'PENDING';
    CREATE INDEX ix_pm_asset_act_disp_org ON grac_practice.asset_activity_disposition(organization_id, status);
    PRINT '439: asset_activity_disposition created.';
END
GO

-- =====================================================================
-- 5. Evidence date fields (global catalogue, 9.1.7 / 9.1.9)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_evidence_field','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_evidence_field (
        field_key          NVARCHAR(100) NOT NULL CONSTRAINT pk_pm_asset_evid_fld PRIMARY KEY,
        evidence_name      NVARCHAR(160) NOT NULL,
        owner_field_key    NVARCHAR(100) NULL,      -- evidence owner (person), else the asset owner
        restrict_on_expiry BIT           NOT NULL,  -- raise a restrictive-use review when expired
        is_active          BIT           NOT NULL CONSTRAINT df_pm_asset_evid_fld_act DEFAULT 1,
        display_order      INT           NOT NULL,
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_evid_fld_eby DEFAULT N'system',
        entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_asset_evid_fld_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '439: asset_evidence_field created.';
END
GO

MERGE grac_practice.asset_evidence_field AS t
USING (VALUES
    (N'calibration_certificate_expiry', N'Calibration certificate', N'calibration_owner', 0, 10),
    (N'insurance_expiry',               N'Vehicle insurance',       NULL,                1, 20),
    (N'fitness_certificate_expiry',     N'Fitness certificate',     NULL,                1, 30),
    (N'pollution_certificate_expiry',   N'Pollution certificate',   NULL,                0, 40),
    (N'permit_expiry',                  N'Permit',                  NULL,                1, 50),
    (N'registration_expiry',            N'Vehicle registration',    NULL,                1, 60),
    (N'road_tax_expiry',                N'Road tax',                NULL,                0, 70)
) AS s(field_key, evidence_name, owner_field_key, restrict_on_expiry, display_order)
ON t.field_key = s.field_key
WHEN NOT MATCHED BY TARGET THEN
    INSERT (field_key, evidence_name, owner_field_key, restrict_on_expiry, display_order, entered_by)
    VALUES (s.field_key, s.evidence_name, s.owner_field_key, s.restrict_on_expiry, s.display_order, N'seed-439');
PRINT CONCAT('439: evidence fields inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 6. Restrictive-use reviews (9.1.9)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_restrictive_review','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_restrictive_review (
        review_id              BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_rr PRIMARY KEY,
        organization_id        BIGINT         NOT NULL,
        asset_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_rr_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        source_kind            NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_rr_kind CHECK (source_kind IN (N'ACTIVITY', N'EVIDENCE')),
        source_code            NVARCHAR(100)  NOT NULL,   -- template code or evidence field key
        trigger_code           NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_rr_trigger CHECK (trigger_code IN (N'FAILED', N'OVERDUE', N'EXPIRED')),
        trigger_date           DATE           NOT NULL,
        review_key             NVARCHAR(250)  NOT NULL,
        title                  NVARCHAR(400)  NOT NULL,
        severity_code          NVARCHAR(10)   NOT NULL,
        occurrence_id          BIGINT         NULL
            CONSTRAINT fk_pm_asset_rr_occ REFERENCES grac_practice.asset_activity_occurrence(occurrence_id),
        status                 NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_rr_status CHECK (status IN (N'OPEN', N'DECIDED', N'RESOLVED')),
        decision_code          NVARCHAR(30)   NULL,
        decision_note          NVARCHAR(1000) NULL,
        decided_by             NVARCHAR(100)  NULL,
        decided_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_asset_rr_dec REFERENCES grac_practice.organization_employee(employee_id),
        decided_dt             DATETIME2      NULL,
        resolved_dt            DATETIME2      NULL,
        resolved_reason        NVARCHAR(400)  NULL,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_rr_eby DEFAULT N'scheduler',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_rr_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        record_version         ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_asset_rr_key UNIQUE (organization_id, review_key)
    );
    -- One active review per asset, source and trigger.
    CREATE UNIQUE INDEX ux_pm_asset_rr_active ON grac_practice.asset_restrictive_review(asset_id, source_kind, source_code, trigger_code)
        WHERE status IN (N'OPEN', N'DECIDED');
    CREATE INDEX ix_pm_asset_rr_org ON grac_practice.asset_restrictive_review(organization_id, status);
    PRINT '439: asset_restrictive_review created.';
END
GO

-- =====================================================================
-- 7. Re-issued 438 bodies (439 lines marked; the rest is verbatim)
-- =====================================================================
-- 438 body + the result / disposition / restriction settings.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_settings (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind,
           CAST(ISNULL(s.is_active, 1) AS BIT) AS IsActive, ISNULL(s.lead_days, t.default_lead_days) AS LeadDays,
           ISNULL(s.due_soon_days, t.default_due_soon_days) AS DueSoonDays, ISNULL(s.grouping_mode, N'INDIVIDUAL') AS GroupingMode,
           s.campaign_owner_employee_id AS CampaignOwnerEmployeeId,
           -- 439: results, dispositions and restricted use (NULL setting = template default)
           CAST(t.result_required AS BIT) AS ResultRequired,
           CAST(ISNULL(s.result_review_required, t.default_result_review) AS BIT) AS ResultReviewRequired,
           CAST(ISNULL(s.disposition_approval_required, t.default_disposition_approval) AS BIT) AS DispositionApprovalRequired,
           ISNULL(s.restrict_on_overdue, ISNULL(t.default_restrict_on_overdue, N'NONE')) AS RestrictOnOverdue,
           CAST(ISNULL(s.restrict_on_fail, t.default_restrict_on_fail) AS BIT) AS RestrictOnFail,
           t.retest_days AS RetestDays
      FROM grac_practice.asset_activity_template t
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code;
GO

-- 438 body + result activities completed by their approved result (D71).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_task_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @completed       INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @completed = 0;
    DECLARE @done TABLE (occurrence_id BIGINT NOT NULL, asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL,
                         status NVARCHAR(12) NOT NULL, completed_dt DATETIME2 NULL);
    -- 439: a result activity is completed by its approved result, not by the
    -- task; a task closed first leaves the occurrence open and flagged (D71).
    UPDATE o
       SET needs_reconciliation = 1,
           reconciliation_reason = N'The Task Centre task was closed without an approved result; record and approve the result.',
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = o.template_code
      JOIN grac_practice.practice_task t ON t.task_id = o.task_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND tp.result_required = 1
       AND s.status_code <> N'Cancelled' AND (s.status_code = N'Closed' OR t.completed_dt IS NOT NULL)
       AND o.needs_reconciliation = 0
       AND ISNULL(o.reconciliation_reason, N'') <> N'The Task Centre task was closed without an approved result; record and approve the result.';

    BEGIN TRAN;
    UPDATE o
       SET status = CASE WHEN s.status_code = N'Cancelled' THEN N'CANCELLED' ELSE N'COMPLETED' END,
           completed_dt = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE COALESCE(t.completed_dt, t.closed_at, SYSUTCDATETIME()) END,
           completed_by_employee_id = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE t.completed_by_employee_id END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.occurrence_id, inserted.asset_id, inserted.template_code, inserted.status, inserted.completed_dt
      INTO @done (occurrence_id, asset_id, template_code, status, completed_dt)
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.practice_task t ON t.task_id = o.task_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = o.template_code     -- 439
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN'
       AND (s.status_code IN (N'Closed', N'Cancelled') OR t.completed_dt IS NOT NULL)
       AND (s.status_code = N'Cancelled' OR tp.result_required = 0);                          -- 439
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', d.occurrence_id, d.status, N'{"status":"OPEN"}',
           (SELECT d.status AS status, d.completed_dt AS completedDt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor
      FROM @done d;
    COMMIT;
    SET @completed = (SELECT COUNT(*) FROM @done WHERE status = N'COMPLETED');

    -- The last date field follows the completion (never moves back).
    DECLARE @asset BIGINT, @key NVARCHAR(100), @dt DATE, @cur DATE, @val NVARCHAR(400);
    DECLARE last_cur CURSOR LOCAL STATIC FOR
        SELECT d.asset_id, t.last_date_field_key, CAST(d.completed_dt AS DATE)
          FROM @done d
          JOIN grac_practice.asset_activity_template t ON t.template_code = d.template_code
         WHERE d.status = N'COMPLETED' AND t.last_date_field_key IS NOT NULL;
    OPEN last_cur;
    FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cur = (SELECT v.value_date FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @key
                     WHERE v.asset_id = @asset);
        IF @cur IS NULL OR @cur < @dt
        BEGIN
            SET @val = CONVERT(NVARCHAR(10), @dt, 23);
            EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @key, @value = @val, @actor = @actor;
        END
        FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    END
    CLOSE last_cur;
    DEALLOCATE last_cur;
END
GO

-- 438 body + revised due dates, waivers (review date) and failed results
-- (re-test) (D72, D74).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedule_sync
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #cov (asset_id BIGINT NOT NULL, coverage_type NVARCHAR(160) NOT NULL, version_id BIGINT NOT NULL, eff_end DATE NULL);
    INSERT #cov (asset_id, coverage_type, version_id, eff_end)
    SELECT AssetId, CoverageType, VersionId, EffectiveEnd
      FROM grac_practice.fn_asset_coverage_line_view(@organization_id)
     WHERE LineStatus IN (N'COVERED', N'EXPIRING');

    CREATE TABLE #in (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, activity_kind NVARCHAR(12) NOT NULL,
        due_soon_days INT NOT NULL, coverage_types NVARCHAR(200) NULL,
        required_val NVARCHAR(400) NULL, frequency_text NVARCHAR(400) NULL, basis NVARCHAR(400) NULL,
        field_last DATE NULL, expiry DATE NULL, occ_due DATE NULL, occ_done DATE NULL, open_due DATE NULL,
        occ_status NVARCHAR(12) NULL, occ_outcome NVARCHAR(12) NULL, occ_review DATE NULL,       -- 439
        open_revised DATE NULL, retest_days INT NULL,                                             -- 439
        PRIMARY KEY (asset_id, template_code));
    INSERT #in (asset_id, template_code, activity_kind, due_soon_days, coverage_types, required_val, frequency_text, basis,
                field_last, expiry, occ_due, occ_done, open_due,
                occ_status, occ_outcome, occ_review, open_revised, retest_days)                -- 439
    SELECT a.asset_id, t.template_code, t.activity_kind, st.DueSoonDays, t.coverage_types,
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.required_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.frequency_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.basis_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.last_date_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.expiry_field_key
             WHERE v.asset_id = a.asset_id),
           lo.due_date, CAST(lo.completed_dt AS DATE),
           (SELECT o.due_date FROM grac_practice.asset_activity_occurrence o
             WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'OPEN'),
           lo.status, lo.outcome, lo.review_date,                                                 -- 439
           (SELECT o.revised_due_date FROM grac_practice.asset_activity_occurrence o
             WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'OPEN'),
           st.RetestDays
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     CROSS JOIN grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code AND st.IsActive = 1
     -- 439: the last finished occurrence is completed (with its approved
     -- result, if any) or waived (until its review date).
     OUTER APPLY (SELECT TOP 1 o.due_date, o.completed_dt, o.status, r.outcome, o.review_date
                    FROM grac_practice.asset_activity_occurrence o
                    LEFT JOIN grac_practice.asset_activity_result r ON r.occurrence_id = o.occurrence_id AND r.state = N'APPROVED'
                   WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status IN (N'COMPLETED', N'WAIVED')
                   ORDER BY o.due_date DESC, o.occurrence_id DESC) lo
     WHERE a.organization_id = @organization_id
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    CREATE TABLE #out (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, schedule_state NVARCHAR(16) NOT NULL,
        not_scheduled_reason NVARCHAR(300) NULL, frequency_text NVARCHAR(100) NULL, interval_value INT NULL, interval_unit NVARCHAR(10) NULL,
        basis NVARCHAR(40) NULL, last_done_date DATE NULL, next_due_date DATE NULL, due_source NVARCHAR(30) NULL,
        status_code NVARCHAR(16) NOT NULL, contract_version_id BIGINT NULL, coverage_end DATE NULL,
        revised_due_date DATE NULL);                                                                -- 439
    INSERT #out (asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit, basis,
                 last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end,
                 revised_due_date)                                                                  -- 439
    SELECT i.asset_id, i.template_code, z.state, z.reason, LEFT(i.frequency_text, 100), iv.IntervalValue, iv.IntervalUnit,
           LEFT(i.basis, 40), CASE WHEN z.state = N'SCHEDULED' THEN n.last_done END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.next_due END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.source END,
           CASE WHEN z.state = N'NOT_APPLICABLE' THEN N'NOT_APPLICABLE'
                WHEN z.state = N'NOT_SCHEDULED' THEN N'NOT_SCHEDULED'
                WHEN n.source = N'FAILED_RESULT' THEN N'FAILED'                                          -- 439
                WHEN i.activity_kind = N'RENEWAL' AND cv.version_id IS NOT NULL
                     AND ISNULL(cv.eff_end, CAST('9999-12-31' AS DATE)) >= n.next_due THEN N'COVERED'
                WHEN n.source = N'WAIVED_REVIEW' AND n.next_due > DATEADD(DAY, i.due_soon_days, @today) THEN N'WAIVED'   -- 439
                WHEN ISNULL(i.open_revised, n.next_due) < @today THEN N'OVERDUE'                         -- 439: revised due
                WHEN ISNULL(i.open_revised, n.next_due) <= DATEADD(DAY, i.due_soon_days, @today) THEN N'DUE_SOON'
                ELSE N'VALID' END,
           cv.version_id, cv.eff_end,
           CASE WHEN z.state = N'SCHEDULED' THEN i.open_revised END                                    -- 439
      FROM #in i
     OUTER APPLY grac_practice.fn_asset_activity_interval(i.frequency_text) iv
     CROSS APPLY (SELECT CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'APPROVED_COMPLETION_DATE', N'COMPLETION_DATE') THEN N'COMPLETION'
                              WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'USAGE', N'RUN_HOURS', N'MANUFACTURER') THEN N'UNSUPPORTED'
                              ELSE N'SCHEDULED' END AS basis_class) b
     -- 439: a waiver lasts until its review date while nothing newer was
     -- recorded on the register; a failed result is re-tested after the
     -- re-test days (D72, D74).
     CROSS APPLY (SELECT CASE WHEN i.occ_status = N'WAIVED' AND i.occ_review IS NOT NULL
                               AND ((i.activity_kind = N'RENEWAL' AND (i.expiry IS NULL OR i.expiry <= i.occ_due))
                                    OR (i.activity_kind = N'EXECUTION' AND (i.field_last IS NULL OR i.field_last <= i.occ_due)))
                              THEN 1 ELSE 0 END AS waived,
                         CASE WHEN i.activity_kind = N'EXECUTION' AND i.occ_status = N'COMPLETED' AND i.occ_outcome = N'FAIL'
                               AND i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last)
                              THEN 1 ELSE 0 END AS failed) w
     CROSS APPLY (SELECT
            CASE WHEN w.waived = 1 THEN i.occ_review                                                   -- 439
                 WHEN w.failed = 1 THEN DATEADD(DAY, ISNULL(i.retest_days, 0), i.occ_done)             -- 439
                 WHEN i.activity_kind = N'RENEWAL' THEN i.expiry
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last)
                     THEN grac_practice.fn_asset_activity_add(CASE WHEN b.basis_class = N'COMPLETION' THEN i.occ_done ELSE i.occ_due END,
                                                              iv.IntervalValue, iv.IntervalUnit)
                 WHEN i.field_last IS NOT NULL THEN grac_practice.fn_asset_activity_add(i.field_last, iv.IntervalValue, iv.IntervalUnit)
                 ELSE ISNULL(i.open_due, @today) END AS next_due,      -- no history: due now (D61), kept while it is open
            CASE WHEN i.activity_kind = N'RENEWAL' THEN NULL
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN i.occ_done
                 ELSE i.field_last END AS last_done,
            CASE WHEN w.waived = 1 THEN N'WAIVED_REVIEW'                                               -- 439
                 WHEN w.failed = 1 THEN N'FAILED_RESULT'                                               -- 439
                 WHEN i.activity_kind = N'RENEWAL' THEN N'EXPIRY_FIELD'
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN N'COMPLETED_OCCURRENCE'
                 WHEN i.field_last IS NOT NULL THEN N'LAST_DATE_FIELD'
                 ELSE N'NO_HISTORY' END AS source) n
     CROSS APPLY (SELECT
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN N'NOT_APPLICABLE'
                 WHEN w.waived = 1 THEN N'SCHEDULED'                                                   -- 439
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED' THEN N'NOT_SCHEDULED'
                 ELSE N'SCHEDULED' END AS state,
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN NULL
                 WHEN w.waived = 1 THEN NULL                                                           -- 439
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'No expiry date is recorded on the asset.'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL
                     THEN N'The frequency is missing or not understood (for example "12 months").'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED'
                     THEN CONCAT(N'The ', LOWER(REPLACE(i.basis, N'_', N' ')), N' basis needs meter readings; it is not scheduled yet.') END AS reason) z
     OUTER APPLY (SELECT TOP 1 c.version_id, c.eff_end
                    FROM #cov c
                   WHERE c.asset_id = i.asset_id AND i.coverage_types IS NOT NULL
                     AND CHARINDEX(N',' + c.coverage_type + N',', N',' + i.coverage_types + N',') > 0
                   ORDER BY ISNULL(c.eff_end, CAST('9999-12-31' AS DATE)) DESC, c.version_id DESC) cv;

    BEGIN TRAN;
    DELETE grac_practice.asset_activity_schedule WHERE organization_id = @organization_id;
    INSERT grac_practice.asset_activity_schedule
        (organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
         basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end,
         revised_due_date)                                                                                 -- 439
    SELECT @organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
           basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end,
           revised_due_date
      FROM #out;
    COMMIT;
END
GO
PRINT '439: settings, task sync and schedule sync re-issued.';
GO

-- =====================================================================
-- 8. Restrictive-use reviews (9.1.9; D77-D78)
-- =====================================================================
-- Causes, recalculated on every pass from the schedules and the register:
--   FAILED   a failed result (schedule status Failed) of an activity whose
--            fail policy is on (Calibration by default)
--   OVERDUE  an overdue execution activity, EXPIRED an overdue renewal
--            (licence), on an asset whose severity (criticality) the
--            overdue policy names: ALL, NONE or a list (Calibration:
--            CRITICAL,HIGH; Equipment licence: ALL)
--   EXPIRED  an expired evidence date whose catalogue row restricts on
--            expiry (insurance, fitness, permit, registration)
-- One active (open or decided) review per asset, source and trigger; an
-- active review whose cause cleared is resolved, never deleted.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_restrictive_review_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @raised          INT           = NULL OUTPUT,
    @resolved        INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @raised = 0, @resolved = 0;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #cause (
        asset_id      BIGINT        NOT NULL,
        source_kind   NVARCHAR(10)  NOT NULL,
        source_code   NVARCHAR(100) NOT NULL,
        trigger_code  NVARCHAR(10)  NOT NULL,
        trigger_date  DATE          NOT NULL,
        title         NVARCHAR(400) NOT NULL,
        severity_code NVARCHAR(10)  NOT NULL,
        occurrence_id BIGINT        NULL,
        PRIMARY KEY (asset_id, source_kind, source_code, trigger_code)
    );

    -- Failed result.
    INSERT #cause (asset_id, source_kind, source_code, trigger_code, trigger_date, title, severity_code, occurrence_id)
    SELECT s.asset_id, N'ACTIVITY', s.template_code, N'FAILED', ISNULL(s.last_done_date, @today),
           LEFT(CONCAT(t.template_name, N' failed: ', a.asset_name), 400), N'CRITICAL', o.occurrence_id
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = s.template_code
                                                                         AND st.IsActive = 1 AND st.RestrictOnFail = 1
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = s.asset_id
      LEFT JOIN grac_practice.asset_activity_occurrence o ON o.asset_id = s.asset_id AND o.template_code = s.template_code
                                                         AND o.status = N'OPEN'
     WHERE s.organization_id = @organization_id AND s.status_code = N'FAILED';

    -- Overdue execution / expired renewal for the severities the policy names.
    INSERT #cause (asset_id, source_kind, source_code, trigger_code, trigger_date, title, severity_code, occurrence_id)
    SELECT s.asset_id, N'ACTIVITY', s.template_code, CASE WHEN t.activity_kind = N'RENEWAL' THEN N'EXPIRED' ELSE N'OVERDUE' END,
           ISNULL(s.revised_due_date, s.next_due_date),
           LEFT(CONCAT(t.template_name, CASE WHEN t.activity_kind = N'RENEWAL' THEN N' expired: ' ELSE N' overdue: ' END, a.asset_name), 400),
           sv.severity_code, o.occurrence_id
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = s.template_code AND st.IsActive = 1
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = s.asset_id
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_asset_severity(s.asset_id) AS severity_code) sv
      LEFT JOIN grac_practice.asset_activity_occurrence o ON o.asset_id = s.asset_id AND o.template_code = s.template_code
                                                         AND o.status = N'OPEN'
     WHERE s.organization_id = @organization_id AND s.status_code = N'OVERDUE' AND s.next_due_date IS NOT NULL
       AND st.RestrictOnOverdue <> N'NONE'
       AND (st.RestrictOnOverdue = N'ALL'
            OR CHARINDEX(N',' + sv.severity_code + N',', N',' + REPLACE(st.RestrictOnOverdue, N' ', N'') + N',') > 0);

    -- Expired evidence that restricts use (assets in use, as 431 D24).
    INSERT #cause (asset_id, source_kind, source_code, trigger_code, trigger_date, title, severity_code, occurrence_id)
    SELECT a.asset_id, N'EVIDENCE', ef.field_key, N'EXPIRED', v.value_date,
           LEFT(CONCAT(ef.evidence_name, N' expired: ', a.asset_name), 400),
           grac_practice.fn_asset_ntf_asset_severity(a.asset_id), NULL
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_value v ON v.asset_id = a.asset_id AND v.value_date IS NOT NULL
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id
      JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key AND ef.is_active = 1 AND ef.restrict_on_expiry = 1
     WHERE a.organization_id = @organization_id AND v.value_date < @today
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    DECLARE @chg TABLE (review_id BIGINT NOT NULL, action_type NVARCHAR(20) NOT NULL);
    BEGIN TRAN;
    UPDATE r
       SET status = N'RESOLVED', resolved_dt = SYSUTCDATETIME(),
           resolved_reason = N'The cause cleared (result approved, rescheduled, renewed, covered, or the asset left use).',
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.review_id, N'RESOLVE' INTO @chg (review_id, action_type)
      FROM grac_practice.asset_restrictive_review r
     WHERE r.organization_id = @organization_id AND r.status IN (N'OPEN', N'DECIDED')
       AND NOT EXISTS (SELECT 1 FROM #cause c
                        WHERE c.asset_id = r.asset_id AND c.source_kind = r.source_kind AND c.source_code = r.source_code
                          AND c.trigger_code = r.trigger_code);
    SET @resolved = @@ROWCOUNT;

    INSERT grac_practice.asset_restrictive_review
        (organization_id, asset_id, source_kind, source_code, trigger_code, trigger_date, review_key, title, severity_code,
         occurrence_id, status, entered_by)
    OUTPUT inserted.review_id, N'CREATE' INTO @chg (review_id, action_type)
    SELECT @organization_id, c.asset_id, c.source_kind, c.source_code, c.trigger_code, c.trigger_date, k.review_key, c.title,
           c.severity_code, c.occurrence_id, N'OPEN', @actor
      FROM #cause c
     CROSS APPLY (SELECT CONCAT(c.source_kind, N':', c.source_code, N':', c.trigger_code, N':', c.asset_id, N':',
                                CONVERT(NVARCHAR(8), c.trigger_date, 112)) AS review_key) k
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_restrictive_review r
                        WHERE r.asset_id = c.asset_id AND r.source_kind = c.source_kind AND r.source_code = c.source_code
                          AND r.trigger_code = c.trigger_code AND r.status IN (N'OPEN', N'DECIDED'))
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_restrictive_review r
                        WHERE r.organization_id = @organization_id AND r.review_key = k.review_key);
    SET @raised = @@ROWCOUNT;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-restrictive-review', x.review_id, x.action_type, NULL,
           (SELECT r.review_key AS reviewKey, r.status AS status, r.title AS title FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor
      FROM @chg x JOIN grac_practice.asset_restrictive_review r ON r.review_id = x.review_id;
    COMMIT;
END
GO
PRINT '439: sp_asset_restrictive_review_sync created.';
GO

-- 438 body + re-test occurrences and waived due dates (D72, D74).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_generate
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @tasks           INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @tasks = 0, @errors = 0, @error_text = NULL;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- a. Reconciliation flags (a reason already reconciled is not raised again).
    UPDATE o
       SET needs_reconciliation = 1, reconciliation_reason = r.reason, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      LEFT JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     CROSS APPLY (SELECT CASE
               WHEN s.schedule_state IS NULL OR s.schedule_state <> N'SCHEDULED'
                   THEN N'The activity no longer applies or is no longer scheduled for this asset.'
               WHEN s.status_code = N'COVERED'
                   THEN N'A contract now covers this renewal; complete or cancel the task after reconciling (BRD 7.1.5).'
               WHEN s.next_due_date <> o.due_date
                   THEN CONCAT(N'The due date is now ', CONVERT(NVARCHAR(10), s.next_due_date, 23), N'.') END AS reason) r
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.needs_reconciliation = 0
       AND r.reason IS NOT NULL AND r.reason <> ISNULL(o.reconciliation_reason, N'');

    -- b. Coverage no longer reaches a covered renewal: it becomes an asset task.
    UPDATE o
       SET status = N'OPEN', decision = N'ASSET_TASK',
           decision_reason = N'The matching contract no longer covers the asset through the due date (BRD 7.1.3).',
           contract_version_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     WHERE o.organization_id = @organization_id AND o.status = N'COVERED' AND s.schedule_state = N'SCHEDULED'
       AND s.next_due_date = o.due_date AND s.status_code <> N'COVERED'
       AND DATEADD(DAY, -(SELECT LeadDays FROM grac_practice.fn_asset_activity_settings(@organization_id) x
                           WHERE x.TemplateCode = o.template_code), o.due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = o.asset_id AND z.template_code = o.template_code AND z.status = N'OPEN');

    -- c. New occurrences.
    DECLARE @new TABLE (occurrence_id BIGINT NOT NULL);
    INSERT grac_practice.asset_activity_occurrence
        (organization_id, asset_id, template_code, due_date, sequence_no, occurrence_key, decision, decision_reason,
         contract_version_id, status, entered_by, is_retest)                                       -- 439
    OUTPUT inserted.occurrence_id INTO @new (occurrence_id)
    SELECT @organization_id, s.asset_id, s.template_code, s.next_due_date, q.seq,
           CONCAT(N'AA-', s.template_code, N'-', s.asset_id, N'-', CONVERT(NVARCHAR(8), s.next_due_date, 112), N'-', q.seq),
           CASE WHEN s.status_code = N'COVERED' THEN N'CONTRACT_COVERED' ELSE N'ASSET_TASK' END,
           CASE WHEN s.status_code = N'FAILED' THEN N'Re-test after a failed result (BRD 7.1.6). ' ELSE N'' END   -- 439
           + CASE WHEN s.due_source = N'WAIVED_REVIEW' THEN N'Review date of a waived occurrence (BRD 7.1.5). ' ELSE N'' END
           + CASE WHEN s.status_code = N'COVERED'
                    THEN N'A matching contract covers the asset through the due date: contract-level renewal, no separate task (BRD 7.1.3).'
                WHEN t.activity_kind = N'EXECUTION' AND s.contract_version_id IS NOT NULL
                    THEN N'Asset-specific result: one task per asset; the covering contract is linked (BRD 7.1.2).'
                WHEN t.activity_kind = N'EXECUTION' THEN N'Asset-specific result: one task per asset (BRD 7.1.4).'
                ELSE N'No matching contract covers the asset: individual renewal task (BRD 7.1.3).' END
           + CASE WHEN q.seq > 1 THEN N' The previous task for this due date was cancelled.' ELSE N'' END,
           s.contract_version_id,
           CASE WHEN s.status_code = N'COVERED' THEN N'COVERED' ELSE N'OPEN' END, @actor,
           CASE WHEN s.status_code = N'FAILED' THEN 1 ELSE 0 END                                     -- 439
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = s.template_code AND st.IsActive = 1
     CROSS APPLY (SELECT 1 + COUNT(*) AS seq FROM grac_practice.asset_activity_occurrence z
                   WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code AND z.due_date = s.next_due_date) q
     WHERE s.organization_id = @organization_id AND s.schedule_state = N'SCHEDULED'
       AND DATEADD(DAY, -st.LeadDays, s.next_due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code
                          AND (z.status = N'OPEN' OR (z.due_date = s.next_due_date AND z.status IN (N'COMPLETED', N'COVERED', N'WAIVED')
                                                       AND NOT (s.status_code = N'FAILED' AND z.status = N'COMPLETED' AND z.is_retest = 0))));   -- 439
    SET @opened = @@ROWCOUNT;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', o.occurrence_id, N'CREATE', NULL,
           (SELECT o.occurrence_key AS occurrenceKey, o.asset_id AS assetId, o.template_code AS templateCode, o.due_date AS dueDate,
                   o.decision AS decision, o.contract_version_id AS contractVersionId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor
      FROM @new n JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = n.occurrence_id;

    -- d. Tasks.
    DECLARE @occ BIGINT, @asset BIGINT, @tpl NVARCHAR(40), @due DATE, @key NVARCHAR(200), @ver BIGINT,
            @tpl_name NVARCHAR(160), @owner_key NVARCHAR(100), @grouping NVARCHAR(12), @cmp_owner BIGINT,
            @asset_name NVARCHAR(400), @asset_owner BIGINT, @crit NVARCHAR(40), @reason NVARCHAR(400),
            @assignee BIGINT, @prio NVARCHAR(30), @title NVARCHAR(250), @descr NVARCHAR(MAX), @ref NVARCHAR(200),
            @cmp BIGINT, @cmp_key NVARCHAR(120), @period CHAR(6), @tid BIGINT, @contract_text NVARCHAR(400), @target DATETIME2;
    DECLARE task_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.asset_id, o.template_code, o.due_date, o.occurrence_key, o.contract_version_id, o.decision_reason,
               t.template_name, t.owner_field_key, st.GroupingMode, st.CampaignOwnerEmployeeId,
               a.asset_name, a.owner_id, c.criticality_code
          FROM grac_practice.asset_activity_occurrence o
          JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
          JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = o.template_code
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
          LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
         WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.decision = N'ASSET_TASK' AND o.task_id IS NULL
         ORDER BY o.due_date, o.occurrence_id;
    OPEN task_cur;
    FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                  @asset_name, @asset_owner, @crit;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @assignee = NULL, @cmp = NULL, @cmp_key = NULL, @tid = NULL, @contract_text = NULL;
            -- Owner: the template owner field (a person), else the asset owner (D65).
            IF @owner_key IS NOT NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id,
                    (SELECT LEFT(v.value_text, 100) FROM grac_practice.asset_field_value v
                       JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @owner_key
                      WHERE v.asset_id = @asset));
            IF @assignee IS NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id, CAST(@asset_owner AS NVARCHAR(30)));
            SET @prio = CASE @crit WHEN N'Critical' THEN N'Critical' WHEN N'High' THEN N'High' WHEN N'Low' THEN N'Low' ELSE N'Medium' END;
            IF @ver IS NOT NULL
                SELECT @contract_text = CONCAT(c.contract_number, N' version ', v.version_no, N' (', c.contract_name, N')')
                  FROM grac_practice.asset_contract_version v
                  JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
                 WHERE v.version_id = @ver;

            IF @grouping = N'CAMPAIGN'
            BEGIN
                SET @period = CONVERT(CHAR(6), @due, 112);
                SET @cmp_key = CONCAT(N'AC-', @tpl, N'-', @period);
                SELECT @cmp = campaign_id FROM grac_practice.asset_activity_campaign
                 WHERE organization_id = @organization_id AND campaign_key = @cmp_key;
                IF @cmp IS NULL
                BEGIN
                    INSERT grac_practice.asset_activity_campaign
                        (organization_id, template_code, period_key, campaign_key, campaign_name, owner_employee_id, entered_by)
                    VALUES (@organization_id, @tpl, @period, @cmp_key,
                            CONCAT(@tpl_name, N' campaign ', LEFT(@period, 4), N'-', RIGHT(@period, 2)), @cmp_owner, @actor);
                    SET @cmp = SCOPE_IDENTITY();
                END
            END

            SET @title = LEFT(CONCAT(@tpl_name, N' - ', @asset_name, N' (due ', CONVERT(NVARCHAR(10), @due, 23), N')'), 250);
            SET @descr = CONCAT(@tpl_name, N' of ', @asset_name, N', due ', CONVERT(NVARCHAR(10), @due, 23), N'.', CHAR(13), CHAR(10),
                                N'Occurrence: ', @key, CHAR(13), CHAR(10),
                                CASE WHEN @cmp_key IS NULL THEN N'' ELSE CONCAT(N'Campaign: ', @cmp_key, CHAR(13), CHAR(10)) END,
                                CASE WHEN @contract_text IS NULL THEN N'' ELSE CONCAT(N'Contract: ', @contract_text, CHAR(13), CHAR(10)) END,
                                @reason);
            SET @ref = ISNULL(@cmp_key, @key);
            SET @target = CAST(@due AS DATETIME2);
            EXEC grac_practice.sp_task_open
                 @organization_id         = @organization_id,
                 @task_type_code          = N'AssetActivity',
                 @subject_entity_type     = N'AssetActivityOccurrence',
                 @subject_entity_id       = @occ,
                 @subject_title           = @title,
                 @subject_description     = @descr,
                 @priority                = @prio,
                 @criticality             = @crit,
                 @origin_code             = N'GRAC',
                 @assigned_to_employee_id = @assignee,
                 @target_date             = @target,
                 @source_type_code        = N'Asset',
                 @source_record_id        = @occ,
                 @source_reference        = @ref,
                 @resolve_owner           = 0,
                 @task_id                 = @tid OUTPUT;
            UPDATE grac_practice.asset_activity_occurrence
               SET task_id = @tid, campaign_id = @cmp, task_error = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
            SET @tasks = @tasks + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Activity occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
            UPDATE grac_practice.asset_activity_occurrence
               SET task_error = LEFT(ERROR_MESSAGE(), 1000), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
        END CATCH
        FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                      @asset_name, @asset_owner, @crit;
    END
    CLOSE task_cur;
    DEALLOCATE task_cur;
END
GO

-- 438 body + the restrictive-use review step.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_run
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @tasks           INT           = NULL OUTPUT,
    @opened          INT           = NULL OUTPUT,
    @completed       INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT,
    @reviews         INT           = NULL OUTPUT      -- 439: restrictive-use reviews raised
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SELECT @tasks = 0, @opened = 0, @completed = 0, @errors = 0, @error_text = NULL, @reviews = 0;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @completed OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    EXEC grac_practice.sp_asset_activity_generate @organization_id = @organization_id, @actor = @actor,
         @opened = @opened OUTPUT, @tasks = @tasks OUTPUT, @errors = @errors OUTPUT, @error_text = @error_text OUTPUT;
    -- 439: restrictive-use reviews (9.1.9).
    DECLARE @resolved INT;
    EXEC grac_practice.sp_asset_restrictive_review_sync @organization_id = @organization_id, @actor = @actor,
         @raised = @reviews OUTPUT, @resolved = @resolved OUTPUT;
END
GO
PRINT '439: generate and run re-issued.';
GO

-- =====================================================================
-- 9. Re-issued notification / register bodies (439 lines marked)
-- =====================================================================
-- 438 body + the Failed calibration status (5.1.7).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stored_values (@asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, c.val AS Value
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY (VALUES
        (N'asset_id',             CAST(a.asset_id AS NVARCHAR(MAX))),
        (N'asset_name',           CAST(a.asset_name AS NVARCHAR(MAX))),
        (N'asset_category_id',    CAST(a.asset_category_id AS NVARCHAR(MAX))),
        (N'asset_subcategory_id', CAST(a.asset_subcategory_id AS NVARCHAR(MAX))),
        (N'asset_type_id',        CAST(a.asset_type_id AS NVARCHAR(MAX))),
        (N'organization_id',      CAST(a.organization_id AS NVARCHAR(MAX))),
        (N'location_id',          CAST(a.location_id AS NVARCHAR(MAX))),
        (N'owner_id',             CAST(a.owner_id AS NVARCHAR(MAX))),
        (N'purchase_dt',          CONVERT(NVARCHAR(MAX), a.purchase_dt, 23)),
        (N'warranty_expiry_dt',   CONVERT(NVARCHAR(MAX), a.warranty_expiry_dt, 23)),
        (N'amc_expiry_dt',        CONVERT(NVARCHAR(MAX), a.amc_expiry_dt, 23)),
        (N'criticality_id',       CAST(a.criticality_id AS NVARCHAR(MAX))),
        (N'remarks',              CAST(a.remarks AS NVARCHAR(MAX))),
        (N'entered_by',           CAST(a.entered_by AS NVARCHAR(MAX))),
        (N'entered_dt',           CONVERT(NVARCHAR(MAX), a.entered_dt, 126)),
        (N'updated_by',           CAST(a.updated_by AS NVARCHAR(MAX))),
        (N'updated_dt',           CONVERT(NVARCHAR(MAX), a.updated_dt, 126))
     ) AS c(column_name, val)
      JOIN grac_practice.asset_field_definition d ON d.storage_kind = N'COLUMN' AND d.column_name = c.column_name
     WHERE a.asset_id = @asset_id AND c.val IS NOT NULL
    UNION ALL
    SELECT v.field_definition_id, d.field_key, v.value_text
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
     WHERE v.asset_id = @asset_id
    UNION ALL
    SELECT d.field_definition_id, d.field_key, s.status_code
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'asset_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 435: the calculated coverage status (5.1.11).
    SELECT d.field_definition_id, d.field_key, cs.CoverageStatusLabel
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY grac_practice.fn_asset_coverage_summary(a.organization_id, a.asset_id) cs
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'coverage_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 438: next calibration / maintenance / inspection date and calibration /
    -- maintenance status from the activity schedule (5.1.7), unless a value
    -- is stored for the field.
    SELECT d.field_definition_id, d.field_key, x.val
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
     CROSS APPLY (VALUES
        (t.next_date_field_key, CONVERT(NVARCHAR(MAX), s.next_due_date, 23)),
        (t.status_field_key,
         CASE WHEN t.status_field_key = N'maintenance_status'
                   AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o
                                WHERE o.asset_id = s.asset_id AND o.template_code = s.template_code
                                  AND o.status = N'OPEN' AND o.task_id IS NOT NULL) THEN N'In Progress'
              WHEN t.status_field_key = N'maintenance_status' THEN
                   CASE s.status_code WHEN N'VALID' THEN N'Not Due' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'FAILED' THEN N'Overdue' END                                   -- 439
              ELSE CASE s.status_code WHEN N'VALID' THEN N'Valid' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'NOT_APPLICABLE' THEN N'N/A' WHEN N'FAILED' THEN N'Failed' END END)   -- 439: Failed
     ) AS x(field_key, val)
      JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key
     WHERE s.asset_id = @asset_id AND x.val IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                        WHERE v.asset_id = @asset_id AND v.field_definition_id = d.field_definition_id);
GO
PRINT '439: fn_asset_stored_values re-issued.';
GO

-- 438 body + the ASSET_EVIDENCE branch.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_parties
    @occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @ref BIGINT;              -- 439: @ref
    SELECT @org = organization_id, @otype = object_type, @oid = object_id, @asset = asset_id, @ref = ref_id
      FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id;
    IF @org IS NULL RETURN;

    DECLARE @raw TABLE (party_code NVARCHAR(30) NOT NULL, val NVARCHAR(100) NOT NULL);

    IF @asset IS NOT NULL
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ASSET_OWNER', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset AND a.owner_id IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT CASE v.FieldKey WHEN N'business_owner' THEN N'BUSINESS_OWNER' WHEN N'technical_owner' THEN N'TECHNICAL_OWNER'
                               WHEN N'custodian' THEN N'CUSTODIAN' WHEN N'maintenance_owner' THEN N'MAINTENANCE_OWNER'
                               WHEN N'compliance_owner' THEN N'COMPLIANCE_OWNER' WHEN N'privacy_owner' THEN N'PRIVACY_OWNER'
                               ELSE N'SECURITY_OWNER' END,
               LEFT(LTRIM(RTRIM(v.Value)), 100)
          FROM grac_practice.fn_asset_stored_values(@asset) v
         WHERE v.FieldKey IN (N'business_owner', N'technical_owner', N'custodian', N'maintenance_owner', N'compliance_owner',
                              N'privacy_owner', N'information_security_owner')
           AND NULLIF(LTRIM(RTRIM(v.Value)), N'') IS NOT NULL;
    END

    IF @otype = N'CONTRACT_VERSION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_contract_version cv
         CROSS APPLY (VALUES (N'CONTRACT_OWNER', cv.contract_owner_id), (N'PROCUREMENT_OWNER', cv.procurement_owner_id),
                             (N'ACTIVITY_OWNER', COALESCE(cv.contract_owner_id, cv.procurement_owner_id))) x(code, emp)
         WHERE cv.version_id = @oid AND x.emp IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT DISTINCT N'AFFECTED_ASSET_OWNERS', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_contract_coverage cc
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = cc.asset_id
         WHERE cc.version_id = @oid AND cc.coverage_state <> N'EXCLUDED' AND a.owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'TECH_EXCEPTION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_technology_exception t
         CROSS APPLY (VALUES (N'ACTIVITY_OWNER', t.owner_employee_id), (N'EXCEPTION_APPROVER', t.decided_by_employee_id)) x(code, emp)
         WHERE t.exception_id = @oid AND x.emp IS NOT NULL;
    END
    ELSE IF @otype = N'ATTESTATION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ACTIVITY_OWNER', CASE WHEN t.assignee_employee_id IS NOT NULL THEN CAST(t.assignee_employee_id AS NVARCHAR(30))
                                       ELSE N'T:' + CAST(t.assignee_team_id AS NVARCHAR(30)) END
          FROM grac_practice.asset_attestation t
         WHERE t.attestation_id = @oid AND (t.assignee_employee_id IS NOT NULL OR t.assignee_team_id IS NOT NULL);
    END
    ELSE IF @otype = N'ACTIVITY'                                                       -- 438
    BEGIN
        -- Activity owner: the task owner, else the template owner field, else
        -- the asset owner; the owner of the linked contract version too (9.1.4).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, CAST(t.assigned_to_employee_id AS NVARCHAR(100)) AS val
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.practice_task t ON t.task_id = ao.task_id
                 WHERE ao.occurrence_id = @oid AND t.assigned_to_employee_id IS NOT NULL
                UNION ALL
                SELECT 1, LEFT(v.value_text, 100)
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
                  JOIN grac_practice.asset_field_value v ON v.asset_id = ao.asset_id
                  JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                             AND f.field_key = tp.owner_field_key
                 WHERE ao.occurrence_id = @oid
                UNION ALL
                SELECT 2, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
        INSERT @raw (party_code, val)
        SELECT N'CONTRACT_OWNER', CAST(cv.contract_owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_activity_occurrence ao
          JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
         WHERE ao.occurrence_id = @oid AND cv.contract_owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'ASSET_EVIDENCE'                                                 -- 439
    BEGIN
        -- Evidence owner: the owner field named by the evidence catalogue
        -- (a person), else the asset owner (9.1 evidence / certificate expiry).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, LEFT(v.value_text, 100) AS val
                  FROM grac_practice.asset_field_definition fd
                  JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key
                  JOIN grac_practice.asset_field_definition f ON f.field_key = ef.owner_field_key
                  JOIN grac_practice.asset_field_value v ON v.asset_id = @asset AND v.field_definition_id = f.field_definition_id
                 WHERE fd.field_definition_id = @ref
                UNION ALL
                SELECT 1, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
    END
    ELSE IF @otype IN (N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE')
    BEGIN
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', val
          FROM @raw WHERE party_code IN (N'TECHNICAL_OWNER', N'ASSET_OWNER')
         ORDER BY CASE party_code WHEN N'TECHNICAL_OWNER' THEN 0 ELSE 1 END;
    END

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT r.party_code, e.employee_id
      FROM @raw r
     CROSS APPLY (SELECT CASE WHEN r.val LIKE N'T:%' THEN NULL
                              WHEN r.val LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40))
                              ELSE TRY_CONVERT(BIGINT, r.val) END AS emp,
                         CASE WHEN r.val LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40)) END AS team) x
      JOIN grac_practice.organization_employee e
        ON e.organization_id = @org AND e.status = N'Active'
       AND (e.employee_id = x.emp
            OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                        WHERE m.team_id = x.team AND m.employee_id = e.employee_id AND m.status = N'Active'));

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'MANAGER', m.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_employee m ON m.employee_id = e.reporting_officer_id AND m.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'DEPARTMENT_HEAD', h.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_department d ON d.department_id = e.department_id
      JOIN grac_practice.organization_employee h ON h.employee_id = d.head_employee_id AND h.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';
END
GO
PRINT '439: sp_asset_notification_parties re-issued.';
GO

-- 438 body + revised due dates, re-test severity and the evidence source.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_sweep
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @closed          INT           = NULL OUTPUT,
    @queued          INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @closed = 0, @queued = 0, @errors = 0, @error_text = NULL;
    DECLARE @org BIGINT = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #due (
        occurrence_key NVARCHAR(200) NOT NULL PRIMARY KEY,
        activity_code  NVARCHAR(40)  NOT NULL,
        object_type    NVARCHAR(30)  NOT NULL,
        object_id      BIGINT        NOT NULL,
        ref_id         BIGINT        NULL,
        asset_id       BIGINT        NULL,
        contract_id    BIGINT        NULL,
        trigger_date   DATE          NOT NULL,
        object_ref     NVARCHAR(200) NULL,
        object_title   NVARCHAR(400) NULL,
        severity_code  NVARCHAR(10)  NOT NULL
    );

    -- Contract renewal (9.1.5): earliest of notice, decision and end date of
    -- the version in force; stops once a renewal of that version completes.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), t.d, 112)), x.act, N'CONTRACT_VERSION', cv.version_id,
           NULL, NULL, c.contract_id, t.d, c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N')'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_contract_activity(c.contract_type) AS act) x
     WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
       AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
                        WHERE r.prior_version_id = cv.version_id AND s.status_code = N'COMPLETED');

    -- Contract expiry (9.1.5): the version in force expired without a successor.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CONTRACT_EXPIRY:CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), DATEADD(DAY, 1, cv.effective_end), 112)),
           N'CONTRACT_EXPIRY', N'CONTRACT_VERSION', cv.version_id, NULL, NULL, c.contract_id, DATEADD(DAY, 1, cv.effective_end),
           c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N') expired'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = cv.current_status_id
     WHERE c.organization_id = @org AND s.status_code = N'EXPIRED' AND cv.effective_end IS NOT NULL;

    -- Assets that are in use for the technology sources (as 431 D24: not in
    -- acquisition, not lost / stolen, not disposed / archived).
    DECLARE @in_use TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, asset_name NVARCHAR(400) NULL, severity_code NVARCHAR(10) NOT NULL);
    INSERT @in_use (asset_id, asset_name, severity_code)
    SELECT a.asset_id, a.asset_name, grac_practice.fn_asset_ntf_asset_severity(a.asset_id)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @org
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    -- Model support end (9.1.3 "Model or OS support end"; D50).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT DISTINCT CONCAT(N'TECH_SUPPORT_END:MODEL:', u.asset_id, N':', m.model_id, N':', CONVERT(NVARCHAR(8), x.d, 112)),
           N'TECH_SUPPORT_END', N'ASSET_MODEL', u.asset_id, m.model_id, u.asset_id, NULL, x.d,
           u.asset_name, CONCAT(N'Model ', m.model_name, N' support ends'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id AND fd.field_key = N'model'
      JOIN grac_practice.asset_model m ON m.model_id = v.value_ref
     CROSS APPLY (SELECT COALESCE(m.end_extended_support_date, m.end_security_support_date, m.end_standard_support_date) AS d) x
     WHERE x.d IS NOT NULL;

    -- Installed OS / firmware release support end (the 430 technology status).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':', t.Kind, N':', u.asset_id, N':', t.CurrentReleaseId, N':', CONVERT(NVARCHAR(8), t.SupportEndDate, 112)),
           x.act, CASE t.Kind WHEN N'OS' THEN N'ASSET_OS' ELSE N'ASSET_FIRMWARE' END, u.asset_id, t.CurrentReleaseId, u.asset_id, NULL,
           t.SupportEndDate, u.asset_name, CONCAT(t.CurrentLabel, N' support ends'), u.severity_code
      FROM grac_practice.fn_asset_technology_status(@org, NULL) t
      JOIN @in_use u ON u.asset_id = t.AssetId
     CROSS APPLY (SELECT CASE t.Kind WHEN N'OS' THEN N'TECH_SUPPORT_END' ELSE N'FIRMWARE_SUPPORT_END' END AS act) x
     WHERE t.CurrentReleaseId IS NOT NULL AND t.SupportEndDate IS NOT NULL;

    -- Technology exception expiry (430).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EXCEPTION_EXPIRY:EXC:', x.exception_id, N':', CONVERT(NVARCHAR(8), x.expiry_date, 112)),
           N'EXCEPTION_EXPIRY', N'TECH_EXCEPTION', x.exception_id, NULL, x.asset_id, NULL, x.expiry_date,
           CONCAT(N'Exception #', x.exception_id),
           CONCAT(CASE x.technology_kind WHEN N'OS' THEN N'OS' ELSE N'Firmware' END, N' exception for ',
                  COALESCE(a.asset_name, N'model ' + m.model_name, N'-')),
           CASE WHEN x.asset_id IS NULL THEN N'MEDIUM' ELSE grac_practice.fn_asset_ntf_asset_severity(x.asset_id) END
      FROM grac_practice.asset_technology_exception x
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.asset_model m ON m.model_id = x.model_id
     WHERE x.organization_id = @org AND x.status = N'APPROVED';

    -- Custodian attestation (431): open attestations by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CUSTODIAN_ATTESTATION:ATT:', t.attestation_id, N':', CONVERT(NVARCHAR(8), t.due_date, 112)),
           N'CUSTODIAN_ATTESTATION', N'ATTESTATION', t.attestation_id, NULL, t.asset_id, NULL, t.due_date,
           a.asset_name, CONCAT(N'Attestation of ', a.asset_name, N' (', LOWER(t.assignee_role), N')'),
           grac_practice.fn_asset_ntf_asset_severity(t.asset_id)
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
     WHERE t.organization_id = @org AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE', N'ESCALATED');

    -- 438: recurring asset activities -- open asset-task occurrences by due date.
    -- 439: by the approved revised due date when rescheduled (the old
    -- occurrence is superseded, not deleted); a re-test after a failed
    -- result with the fail policy on is Critical (9.1.4).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(tp.notification_activity_code, N':ACT:', ao.occurrence_id, N':',
                  CONVERT(NVARCHAR(8), ISNULL(ao.revised_due_date, ao.due_date), 112)),                -- 439
           tp.notification_activity_code, N'ACTIVITY', ao.occurrence_id, NULL, ao.asset_id, cv.contract_id,
           ISNULL(ao.revised_due_date, ao.due_date),                                                   -- 439
           a.asset_name, CONCAT(tp.template_name, CASE WHEN ao.is_retest = 1 THEN N' re-test' ELSE N'' END, N' of ', a.asset_name),
           CASE WHEN ao.is_retest = 1 AND st.RestrictOnFail = 1 THEN N'CRITICAL'                        -- 439
                ELSE grac_practice.fn_asset_ntf_asset_severity(ao.asset_id) END
      FROM grac_practice.asset_activity_occurrence ao
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
      JOIN grac_practice.fn_asset_activity_settings(@org) st ON st.TemplateCode = ao.template_code      -- 439
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = ao.asset_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
     WHERE ao.organization_id = @org AND ao.status = N'OPEN' AND ao.decision = N'ASSET_TASK';

    -- 439: evidence / certificate expiry (9.1.7) -- the evidence date fields of
    -- assets in use.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EVIDENCE_EXPIRY:EV:', u.asset_id, N':', fd.field_definition_id, N':', CONVERT(NVARCHAR(8), v.value_date, 112)),
           N'EVIDENCE_EXPIRY', N'ASSET_EVIDENCE', u.asset_id, fd.field_definition_id, u.asset_id, NULL, v.value_date,
           u.asset_name, CONCAT(ef.evidence_name, N' of ', u.asset_name, N' expires'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id AND v.value_date IS NOT NULL
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id
      JOIN grac_practice.asset_evidence_field ef ON ef.field_key = fd.field_key AND ef.is_active = 1;

    -- 2. Close / reopen.
    UPDATE o
       SET status = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                AND d.object_id = o.object_id)
                         THEN N'SUPERSEDED' ELSE N'COMPLETED' END,
           close_reason = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                      AND d.object_id = o.object_id)
                               THEN N'The trigger date or reference changed; a new occurrence replaces it.'
                               ELSE N'No longer due (completed, renewed, changed or withdrawn).' END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
     WHERE o.organization_id = @org AND o.status = N'OPEN'
       AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.occurrence_key = o.occurrence_key);
    SET @closed = @@ROWCOUNT;

    UPDATE o
       SET status = N'OPEN', closed_dt = NULL, close_reason = NULL, object_ref = d.object_ref, object_title = d.object_title,
           severity_code = d.severity_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
      JOIN #due d ON d.occurrence_key = o.occurrence_key
     WHERE o.organization_id = @org
       AND (o.status <> N'OPEN' OR ISNULL(o.object_title, N'') <> ISNULL(d.object_title, N'') OR o.severity_code <> d.severity_code
            OR ISNULL(o.object_ref, N'') <> ISNULL(d.object_ref, N''));

    -- 3. Open.
    INSERT grac_practice.asset_notification_occurrence
        (organization_id, occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
         object_ref, object_title, severity_code, status, entered_by)
    SELECT @org, d.occurrence_key, d.activity_code, d.object_type, d.object_id, d.ref_id, d.asset_id, d.contract_id, d.trigger_date,
           d.object_ref, d.object_title, d.severity_code, N'OPEN', @actor
      FROM #due d
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence o
                        WHERE o.organization_id = @org AND o.occurrence_key = d.occurrence_key);
    SET @opened = @@ROWCOUNT;

    -- 4. Fire.
    CREATE TABLE #np (party_code NVARCHAR(30) NOT NULL, employee_id BIGINT NOT NULL);
    CREATE TABLE #rcp (employee_id BIGINT NULL, role_id BIGINT NULL, role_name NVARCHAR(200) NULL, reason_code NVARCHAR(30) NOT NULL);
    CREATE TABLE #holders (
        EmployeeId BIGINT, EmployeeCode NVARCHAR(100), EmployeeName NVARCHAR(240),
        Email NVARCHAR(250), Designation NVARCHAR(200), Department NVARCHAR(200),
        RoleId BIGINT, RoleName NVARCHAR(200)
    );

    DECLARE @occ BIGINT, @act NVARCHAR(40), @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @contract BIGINT, @trigger DATE,
            @ref NVARCHAR(200), @title NVARCHAR(400), @sev NVARCHAR(10), @last_date DATE,
            @p BIGINT, @pver INT, @ack NVARCHAR(10), @wdays BIT, @channels NVARCHAR(60),
            @stage BIGINT, @sdate DATE, @kind NVARCHAR(12), @offset INT, @level TINYINT, @class NVARCHAR(20),
            @act_name NVARCHAR(160), @basis NVARCHAR(30), @subject NVARCHAR(400), @body NVARCHAR(MAX), @n INT,
            @role BIGINT, @role_name NVARCHAR(200);

    DECLARE occ_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.activity_code, o.object_type, o.object_id, o.asset_id, o.contract_id, o.trigger_date,
               o.object_ref, o.object_title, o.severity_code, o.last_stage_date
          FROM grac_practice.asset_notification_occurrence o
         WHERE o.organization_id = @org AND o.status = N'OPEN'
           AND (o.snoozed_until IS NULL OR o.snoozed_until <= @today)
         ORDER BY o.trigger_date, o.occurrence_id;
    OPEN occ_cur;
    FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @p = NULL, @pver = NULL, @ack = NULL, @wdays = NULL, @channels = NULL,
                   @stage = NULL, @sdate = NULL, @kind = NULL, @offset = NULL, @level = NULL, @class = NULL;
            SELECT @p = ProfileId, @pver = VersionNo, @ack = AckMode, @wdays = WorkingDaysOnly, @channels = Channels
              FROM grac_practice.fn_asset_ntf_profile_for(@org, @act, @sev, @today);

            IF @p IS NOT NULL
                SELECT TOP 1 @stage = s.stage_id, @sdate = x.d, @kind = s.stage_kind, @offset = s.offset_days,
                       @level = s.escalation_level, @class = s.notification_class
                  FROM grac_practice.asset_notification_stage s
                 CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(@trigger, s.stage_kind, s.offset_days, @wdays) AS d) x
                 WHERE s.profile_id = @p AND s.is_active = 1 AND x.d <= @today
                 ORDER BY x.d DESC, s.escalation_level DESC, s.stage_id DESC;

            IF @stage IS NOT NULL AND @sdate > ISNULL(@last_date, CONVERT(DATE, '19000101', 112))
            BEGIN
                -- 9.1.2: an escalation on a critical object is a Critical notification (D53).
                IF @sev = N'CRITICAL' AND @kind = N'ESCALATION' SET @class = N'CRITICAL';

                DELETE FROM #np;
                DELETE FROM #rcp;
                EXEC grac_practice.sp_asset_notification_parties @occurrence_id = @occ;

                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, sr.recipient_code
                  FROM grac_practice.asset_notification_stage_recipient sr
                  JOIN #np np ON np.party_code = sr.recipient_code
                 WHERE sr.stage_id = @stage AND sr.recipient_code <> N'ROLE';
                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, m.recipient_code
                  FROM grac_practice.asset_escalation_matrix m
                  JOIN #np np ON np.party_code = m.recipient_code
                 WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                   AND m.recipient_code <> N'ROLE';

                DECLARE role_cur CURSOR LOCAL STATIC FOR
                    SELECT DISTINCT r.role_id, r.role_name
                      FROM (SELECT sr.role_id FROM grac_practice.asset_notification_stage_recipient sr
                             WHERE sr.stage_id = @stage AND sr.recipient_code = N'ROLE'
                            UNION
                            SELECT m.role_id FROM grac_practice.asset_escalation_matrix m
                             WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                               AND m.recipient_code = N'ROLE') x
                      JOIN grac_practice.organization_role r ON r.role_id = x.role_id;
                OPEN role_cur;
                FETCH NEXT FROM role_cur INTO @role, @role_name;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DELETE FROM #holders;
                    INSERT INTO #holders
                        EXEC grac_practice.sp_org_role_holders_list @organization_id = @org, @role_id = @role;
                    IF EXISTS (SELECT 1 FROM #holders)
                    BEGIN
                        INSERT #rcp (employee_id, role_id, role_name, reason_code)
                        SELECT EmployeeId, RoleId, RoleName, N'ROLE' FROM #holders;
                    END
                    ELSE
                    BEGIN
                        -- An empty role still records the obligation (213 precedent).
                        INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, @role, @role_name, N'ROLE');
                    END
                    FETCH NEXT FROM role_cur INTO @role, @role_name;
                END
                CLOSE role_cur;
                DEALLOCATE role_cur;

                IF NOT EXISTS (SELECT 1 FROM #rcp)
                    INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, NULL, NULL, N'UNRESOLVED');

                SELECT @act_name = activity_name, @basis = trigger_basis
                  FROM grac_practice.asset_notification_activity WHERE activity_code = @act;
                SET @subject = LEFT(CONCAT(N'[GRAC] ',
                    CASE @class WHEN N'INFORMATIONAL' THEN N'Information' WHEN N'REMINDER' THEN N'Reminder'
                                WHEN N'ESCALATION' THEN N'Escalation' ELSE N'Critical' END,
                    N': ', @act_name, N' - ', ISNULL(@ref, N'-'),
                    CASE @kind WHEN N'REMINDER' THEN CONCAT(N' due in ', @offset, N' day(s)')
                               WHEN N'DUE' THEN N' due today'
                               ELSE CASE WHEN @offset = 0 THEN N' reached its date' ELSE CONCAT(N' ', @offset, N' day(s) overdue') END END), 400);
                SET @body = CONCAT(
                    @act_name, CHAR(13), CHAR(10), CHAR(13), CHAR(10),
                    N'Reference: ', ISNULL(@ref, N'-'), CHAR(13), CHAR(10),
                    N'Subject:   ', ISNULL(@title, N'-'), CHAR(13), CHAR(10),
                    N'Date:      ', CONVERT(NVARCHAR(10), @trigger, 23), N' (', LOWER(REPLACE(@basis, N'_', N' ')), N')', CHAR(13), CHAR(10),
                    N'Stage:     ', CASE @kind WHEN N'REMINDER' THEN CONCAT(@offset, N' day(s) before')
                                               WHEN N'DUE' THEN N'due date'
                                               ELSE CONCAT(N'escalation level ', @level, N', ', @offset, N' day(s) after') END, CHAR(13), CHAR(10),
                    N'Severity:  ', @sev, CHAR(13), CHAR(10),
                    CASE @ack WHEN N'ACTION' THEN N'Acknowledge with the action taken.'
                              WHEN N'MANAGER' THEN N'Acknowledge with the action taken; your manager confirms the acknowledgement.'
                              WHEN N'READ' THEN N'Mark as read once seen.' ELSE N'' END);

                BEGIN TRAN;
                INSERT grac_practice.asset_notification_outbox
                    (organization_id, occurrence_id, profile_id, profile_version, stage_id, stage_kind, stage_offset_days, stage_date,
                     escalation_level, notification_class, activity_code, object_type, object_id, asset_id, contract_id, object_ref,
                     object_title, trigger_date, severity_code, recipient_employee_id, recipient_name, recipient_email,
                     recipient_manager_id, role_id, role_name, recipient_reason_code, channels, ack_mode, subject, body_text,
                     status_code, failure_reason, entered_by)
                SELECT @org, @occ, @p, @pver, @stage, @kind, @offset, @sdate, @level, @class, @act, @otype, @oid, @asset, @contract, @ref,
                       @title, @trigger, @sev, r.employee_id, e.employee_name, e.email, e.reporting_officer_id, r.role_id, r.role_name,
                       r.reason_code, @channels, @ack, @subject, @body,
                       CASE WHEN r.employee_id IS NULL THEN N'Suppressed' ELSE N'Pending' END,
                       CASE WHEN r.employee_id IS NULL AND r.reason_code = N'ROLE' THEN N'The role has no active holder.'
                            WHEN r.employee_id IS NULL THEN N'No recipient could be resolved for this stage.' END,
                       @actor
                  FROM (SELECT employee_id, role_id, role_name, reason_code,
                               ROW_NUMBER() OVER (PARTITION BY ISNULL(employee_id, -1)
                                                  ORDER BY CASE WHEN role_id IS NULL THEN 0 ELSE 1 END, reason_code) AS rn
                          FROM #rcp) r
                  LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                 WHERE r.rn = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_outbox x
                                    WHERE x.occurrence_id = @occ AND x.stage_id = @stage
                                      AND ((x.recipient_employee_id IS NULL AND r.employee_id IS NULL)
                                           OR x.recipient_employee_id = r.employee_id));
                SET @n = @@ROWCOUNT;
                UPDATE grac_practice.asset_notification_occurrence
                   SET last_stage_id = @stage, last_stage_date = @sdate,
                       escalation_level = CASE WHEN @level > escalation_level THEN @level ELSE escalation_level END,
                       last_notified_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_id = @occ;
                COMMIT;
                SET @queued = @queued + @n;
            END
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            IF CURSOR_STATUS('local', 'role_cur') >= -1
            BEGIN
                IF CURSOR_STATUS('local', 'role_cur') >= 0 CLOSE role_cur;
                DEALLOCATE role_cur;
            END
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
        END CATCH
        FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    END
    CLOSE occ_cur;
    DEALLOCATE occ_cur;
END
GO
PRINT '439: sp_asset_notification_sweep re-issued.';
GO

-- =====================================================================
-- 9b. Re-issued 438 readers / writers (439 lines marked)
-- =====================================================================
-- 438 body + the 439 settings and the evidence catalogue.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind, t.description AS Description,
           t.required_field_key AS RequiredFieldKey, t.frequency_field_key AS FrequencyFieldKey, t.basis_field_key AS BasisFieldKey,
           t.last_date_field_key AS LastDateFieldKey, t.expiry_field_key AS ExpiryFieldKey, t.owner_field_key AS OwnerFieldKey,
           t.coverage_types AS CoverageTypes, t.notification_activity_code AS NotificationActivityCode, na.activity_name AS NotificationActivityName,
           st.IsActive, st.LeadDays, st.DueSoonDays, st.GroupingMode, st.CampaignOwnerEmployeeId, ow.employee_name AS CampaignOwnerName,
           t.default_lead_days AS DefaultLeadDays, t.default_due_soon_days AS DefaultDueSoonDays,
           CASE WHEN s.organization_id IS NULL THEN 0 ELSE 1 END AS IsCustomized,
           -- 439: results, dispositions, restricted use
           st.ResultRequired, st.ResultReviewRequired, st.DispositionApprovalRequired, st.RestrictOnOverdue, st.RestrictOnFail,
           st.RetestDays, t.certificate_number_field_key AS CertificateNumberFieldKey,
           t.certificate_expiry_field_key AS CertificateExpiryFieldKey,
           t.default_result_review AS DefaultResultReview, t.default_disposition_approval AS DefaultDispositionApproval,
           ISNULL(t.default_restrict_on_overdue, N'NONE') AS DefaultRestrictOnOverdue, t.default_restrict_on_fail AS DefaultRestrictOnFail
      FROM grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code
      JOIN grac_practice.asset_notification_activity na ON na.activity_code = t.notification_activity_code
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = st.CampaignOwnerEmployeeId
     ORDER BY t.display_order;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
    -- 439: 3. the evidence date fields (evidence expiry notifications and reviews).
    SELECT ef.field_key AS FieldKey, ef.evidence_name AS EvidenceName, fd.display_label AS FieldLabel,
           ef.owner_field_key AS OwnerFieldKey, ef.restrict_on_expiry AS RestrictOnExpiry, ef.is_active AS IsActive
      FROM grac_practice.asset_evidence_field ef
      LEFT JOIN grac_practice.asset_field_definition fd ON fd.field_key = ef.field_key
     ORDER BY ef.display_order;
END
GO

-- 438 body + the 439 settings.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_setting_save
    @organization_id            BIGINT,
    @template_code              NVARCHAR(40),
    @is_active                  BIT           = 1,
    @lead_days                  INT           = NULL,
    @due_soon_days              INT           = NULL,
    @grouping_mode              NVARCHAR(12)  = N'INDIVIDUAL',
    @campaign_owner_employee_id BIGINT        = NULL,
    @result_review_required        BIT           = NULL,     -- 439: NULL = the template default
    @disposition_approval_required BIT           = NULL,
    @restrict_on_overdue           NVARCHAR(100) = NULL,     -- ALL | NONE | CRITICAL,HIGH,MEDIUM,LOW
    @restrict_on_fail              BIT           = NULL,
    @actor                      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @grouping_mode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@grouping_mode)), N''), N'INDIVIDUAL'));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_template WHERE template_code = @template_code)
        THROW 54651, 'Unknown activity template.', 1;
    IF @lead_days IS NULL OR @lead_days NOT BETWEEN 0 AND 365 OR @due_soon_days IS NULL OR @due_soon_days NOT BETWEEN 0 AND 365
        THROW 54652, 'Task lead days and due-soon days must be between 0 and 365.', 1;
    IF @grouping_mode NOT IN (N'INDIVIDUAL', N'CAMPAIGN')
        THROW 54653, 'Tasks are created individually or grouped in a monthly campaign.', 1;
    IF @campaign_owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                                WHERE employee_id = @campaign_owner_employee_id
                                                                  AND organization_id = @organization_id AND status = N'Active')
        THROW 54654, 'The campaign owner must be an active employee of the organization.', 1;
    -- 439: restricted-use policy on overdue.
    SET @restrict_on_overdue = NULLIF(UPPER(REPLACE(LTRIM(RTRIM(@restrict_on_overdue)), N' ', N'')), N'');
    IF @restrict_on_overdue IS NOT NULL AND @restrict_on_overdue NOT IN (N'ALL', N'NONE')
       AND EXISTS (SELECT 1 FROM STRING_SPLIT(@restrict_on_overdue, N',') x
                    WHERE x.value NOT IN (N'CRITICAL', N'HIGH', N'MEDIUM', N'LOW'))
        THROW 54691, 'The restricted-use policy is All, None or a list of Critical, High, Medium, Low.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT is_active AS isActive, lead_days AS leadDays, due_soon_days AS dueSoonDays,
                                            grouping_mode AS groupingMode, campaign_owner_employee_id AS campaignOwnerEmployeeId,
                                            result_review_required AS resultReviewRequired,                  -- 439
                                            disposition_approval_required AS dispositionApprovalRequired,
                                            restrict_on_overdue AS restrictOnOverdue, restrict_on_fail AS restrictOnFail
                                       FROM grac_practice.asset_activity_setting
                                      WHERE organization_id = @organization_id AND template_code = @template_code
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    MERGE grac_practice.asset_activity_setting AS t
    USING (SELECT @organization_id AS organization_id, @template_code AS template_code) AS s
    ON t.organization_id = s.organization_id AND t.template_code = s.template_code
    WHEN MATCHED THEN UPDATE SET
        is_active = ISNULL(@is_active, 1), lead_days = @lead_days, due_soon_days = @due_soon_days, grouping_mode = @grouping_mode,
        campaign_owner_employee_id = @campaign_owner_employee_id, updated_by = @actor, updated_dt = SYSUTCDATETIME(),
        result_review_required = @result_review_required, disposition_approval_required = @disposition_approval_required,   -- 439
        restrict_on_overdue = @restrict_on_overdue, restrict_on_fail = @restrict_on_fail
    WHEN NOT MATCHED THEN
        INSERT (organization_id, template_code, is_active, lead_days, due_soon_days, grouping_mode, campaign_owner_employee_id, entered_by,
                result_review_required, disposition_approval_required, restrict_on_overdue, restrict_on_fail)            -- 439
        VALUES (@organization_id, @template_code, ISNULL(@is_active, 1), @lead_days, @due_soon_days, @grouping_mode,
                @campaign_owner_employee_id, @actor,
                @result_review_required, @disposition_approval_required, @restrict_on_overdue, @restrict_on_fail);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-setting', @organization_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @template_code AS templateCode, ISNULL(@is_active, 1) AS isActive, @lead_days AS leadDays, @due_soon_days AS dueSoonDays,
                    @grouping_mode AS groupingMode, @campaign_owner_employee_id AS campaignOwnerEmployeeId,
                    @result_review_required AS resultReviewRequired, @disposition_approval_required AS dispositionApprovalRequired,   -- 439
                    @restrict_on_overdue AS restrictOnOverdue, @restrict_on_fail AS restrictOnFail FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO

-- 438 body + revised due date, Failed first.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedules
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(16)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @done INT;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @done OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT s.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName, s.template_code AS TemplateCode,
           t.template_name AS TemplateName, t.activity_kind AS ActivityKind, s.schedule_state AS ScheduleState,
           s.not_scheduled_reason AS NotScheduledReason, s.frequency_text AS FrequencyText, s.basis AS Basis,
           s.last_done_date AS LastDoneDate, s.next_due_date AS NextDueDate, DATEDIFF(DAY, @today, s.next_due_date) AS DaysToDue,
           s.due_source AS DueSource, s.status_code AS StatusCode, s.revised_due_date AS RevisedDueDate,   -- 439
           c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo, s.coverage_end AS CoverageEnd,
           o.occurrence_id AS OpenOccurrenceId, o.occurrence_key AS OpenOccurrenceKey, o.task_id AS OpenTaskId,
           o.needs_reconciliation AS NeedsReconciliation,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = s.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = s.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_occurrence o ON o.asset_id = s.asset_id AND o.template_code = s.template_code AND o.status = N'OPEN'
     WHERE s.organization_id = @organization_id
       AND (@template_code IS NULL OR s.template_code = @template_code)
       AND ((@status IS NULL AND s.status_code <> N'NOT_APPLICABLE') OR @status = N'ALL' OR s.status_code = @status)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR ty.asset_type_name LIKE N'%' + @search + N'%')
     ORDER BY CASE s.status_code WHEN N'FAILED' THEN 0 WHEN N'OVERDUE' THEN 0 WHEN N'DUE_SOON' THEN 1 WHEN N'VALID' THEN 2   -- 439: FAILED
                                 WHEN N'WAIVED' THEN 3 WHEN N'COVERED' THEN 3 WHEN N'NOT_SCHEDULED' THEN 4 ELSE 5 END,
              s.next_due_date, a.asset_name, t.display_order
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 438 body + result / disposition columns and the awaiting-decision filter.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_occurrences
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(12)  = N'OPEN',
    @reconcile_only  BIT           = 0,
    @campaign_id     BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @awaiting_decision BIT         = 0,        -- 439: a submitted result or a pending disposition
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'OPEN'));
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.asset_id AS AssetId, a.asset_name AS AssetName,
           o.template_code AS TemplateCode, t.template_name AS TemplateName, o.due_date AS DueDate,
           DATEDIFF(DAY, @today, o.due_date) AS DaysToDue, o.sequence_no AS SequenceNo, o.decision AS Decision,
           o.decision_reason AS DecisionReason, c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo,
           cm.campaign_key AS CampaignKey, cm.campaign_name AS CampaignName, o.task_id AS TaskId, pt.task_number AS TaskNumber,
           ts.status_name AS TaskStatusName, ae.employee_name AS TaskOwnerName, o.task_error AS TaskError, o.status AS Status,
           o.needs_reconciliation AS NeedsReconciliation, o.reconciliation_reason AS ReconciliationReason,
           o.reconciled_note AS ReconciledNote, o.reconciled_by AS ReconciledBy, o.reconciled_dt AS ReconciledDt,
           o.completed_dt AS CompletedDt, cb.employee_name AS CompletedByName, o.entered_dt AS OpenedDt,
           CONVERT(BIGINT, o.record_version) AS RecordVersion,
           o.revised_due_date AS RevisedDueDate, o.review_date AS ReviewDate, o.is_retest AS IsRetest,          -- 439
           rs.state AS ResultState, rs.outcome AS ResultOutcome, pd.disposition_type AS PendingDispositionType,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = o.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_campaign cm ON cm.campaign_id = o.campaign_id
      LEFT JOIN grac_practice.practice_task pt ON pt.task_id = o.task_id
      LEFT JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = pt.current_status_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = pt.assigned_to_employee_id
      LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = o.completed_by_employee_id
      LEFT JOIN grac_practice.asset_activity_result rs ON rs.occurrence_id = o.occurrence_id                         -- 439
      LEFT JOIN grac_practice.asset_activity_disposition pd ON pd.occurrence_id = o.occurrence_id AND pd.status = N'PENDING'
     WHERE o.organization_id = @organization_id
       AND (@template_code IS NULL OR o.template_code = @template_code)
       AND (@status = N'ALL' OR o.status = @status)
       AND (ISNULL(@reconcile_only, 0) = 0 OR o.needs_reconciliation = 1)
       AND (@campaign_id IS NULL OR o.campaign_id = @campaign_id)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR o.occurrence_key LIKE N'%' + @search + N'%')
       AND (ISNULL(@awaiting_decision, 0) = 0 OR rs.state = N'SUBMITTED' OR pd.disposition_id IS NOT NULL)          -- 439
     ORDER BY o.due_date, o.occurrence_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '439: 438 readers / writers re-issued.';
GO

-- =====================================================================
-- 10. Results (7.1.2, 7.1.6; D69-D72)
-- =====================================================================
-- Applies an approved result (inside the transaction of the caller): the
-- occurrence is completed on the performed date; the register is updated --
-- Pass: last date (never moved back), certificate number and expiry;
-- Renewed: the expiry date; Fail / Not renewed: nothing (the schedule
-- turns Failed / Overdue). A reconciliation flag raised because the task
-- was closed first is cleared.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_result_apply
    @result_id BIGINT,
    @actor     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @occ BIGINT, @asset BIGINT, @outcome NVARCHAR(12), @performed DATE, @cert_no NVARCHAR(100), @cert_exp DATE,
            @new_exp DATE, @sub_emp BIGINT, @last_key NVARCHAR(100), @cert_no_key NVARCHAR(100), @cert_exp_key NVARCHAR(100),
            @expiry_key NVARCHAR(100), @cur DATE, @val NVARCHAR(400);
    SELECT @occ = r.occurrence_id, @asset = o.asset_id, @outcome = r.outcome, @performed = r.performed_date,
           @cert_no = r.certificate_number, @cert_exp = r.certificate_expiry, @new_exp = r.new_expiry,
           @sub_emp = r.submitted_by_employee_id, @last_key = t.last_date_field_key,
           @cert_no_key = t.certificate_number_field_key, @cert_exp_key = t.certificate_expiry_field_key,
           @expiry_key = t.expiry_field_key
      FROM grac_practice.asset_activity_result r
      JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = r.occurrence_id
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
     WHERE r.result_id = @result_id AND r.state = N'APPROVED';
    IF @occ IS NULL RETURN;

    UPDATE grac_practice.asset_activity_occurrence
       SET status = N'COMPLETED', completed_dt = CAST(@performed AS DATETIME2), completed_by_employee_id = @sub_emp,
           closed_dt = SYSUTCDATETIME(),
           needs_reconciliation = CASE WHEN reconciliation_reason LIKE N'The Task Centre task was closed without an approved result%'
                                       THEN 0 ELSE needs_reconciliation END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE occurrence_id = @occ AND status = N'OPEN';
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-occurrence', @occ, N'COMPLETED', N'{"status":"OPEN"}',
            (SELECT N'COMPLETED' AS status, @outcome AS outcome, @performed AS performedDate FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);

    IF @outcome = N'PASS' AND @last_key IS NOT NULL
    BEGIN
        SET @cur = (SELECT v.value_date FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @last_key
                     WHERE v.asset_id = @asset);
        IF @cur IS NULL OR @cur < @performed
        BEGIN
            SET @val = CONVERT(NVARCHAR(10), @performed, 23);
            EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @last_key, @value = @val, @actor = @actor;
        END
    END
    IF @outcome = N'PASS' AND @cert_no_key IS NOT NULL AND @cert_no IS NOT NULL
    BEGIN
        SET @val = @cert_no;
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @cert_no_key, @value = @val, @actor = @actor;
    END
    IF @outcome = N'PASS' AND @cert_exp_key IS NOT NULL AND @cert_exp IS NOT NULL
    BEGIN
        SET @val = CONVERT(NVARCHAR(10), @cert_exp, 23);
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @cert_exp_key, @value = @val, @actor = @actor;
    END
    IF @outcome = N'RENEWED' AND @expiry_key IS NOT NULL AND @new_exp IS NOT NULL
    BEGIN
        SET @val = CONVERT(NVARCHAR(10), @new_exp, 23);
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @expiry_key, @value = @val, @actor = @actor;
    END
END
GO

-- Save (draft) or submit the result of an open asset-task occurrence.
-- Submitted: approved at once when the organization does not require a
-- reviewer for the activity, else waiting for another person (D70).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_result_save
    @organization_id         BIGINT,
    @occurrence_id           BIGINT,
    @outcome                 NVARCHAR(12)   = NULL,     -- PASS | FAIL (execution), RENEWED | NOT_RENEWED (renewal)
    @performed_date          DATE           = NULL,
    @certificate_number      NVARCHAR(100)  = NULL,
    @certificate_expiry      DATE           = NULL,
    @new_expiry              DATE           = NULL,
    @evidence_reference      NVARCHAR(400)  = NULL,
    @result_note             NVARCHAR(2000) = NULL,
    @submit                  BIT            = 0,
    @expected_record_version BIGINT         = NULL,     -- of the result
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @outcome = NULLIF(UPPER(LTRIM(RTRIM(@outcome))), N'');
    SET @certificate_number = NULLIF(LTRIM(RTRIM(@certificate_number)), N'');
    SET @evidence_reference = NULLIF(LTRIM(RTRIM(@evidence_reference)), N'');
    SET @result_note = NULLIF(LTRIM(RTRIM(@result_note)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @found BIT = 0, @status NVARCHAR(12), @decision NVARCHAR(20), @tpl NVARCHAR(40), @kind NVARCHAR(12), @asset BIGINT,
            @cert_key NVARCHAR(100), @expiry_key NVARCHAR(100), @review BIT, @cur_exp DATE;
    SELECT @found = 1, @status = o.status, @decision = o.decision, @tpl = o.template_code, @kind = t.activity_kind,
           @asset = o.asset_id, @cert_key = t.certificate_number_field_key, @expiry_key = t.expiry_field_key
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
     WHERE o.occurrence_id = @occurrence_id AND o.organization_id = @organization_id;
    IF @found = 0 THROW 54670, 'Activity occurrence not found for this organization.', 1;
    IF @status <> N'OPEN' OR @decision <> N'ASSET_TASK'
        THROW 54671, 'A result is recorded only on an open asset task occurrence.', 1;
    SET @review = (SELECT ResultReviewRequired FROM grac_practice.fn_asset_activity_settings(@organization_id) WHERE TemplateCode = @tpl);

    DECLARE @rid BIGINT, @rstate NVARCHAR(12), @rv BIGINT, @before NVARCHAR(MAX);
    SELECT @rid = result_id, @rstate = state, @rv = CONVERT(BIGINT, record_version),
           @before = (SELECT r2.state AS state, r2.outcome AS outcome, r2.performed_date AS performedDate
                        FROM grac_practice.asset_activity_result r2 WHERE r2.result_id = r.result_id
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
      FROM grac_practice.asset_activity_result r
     WHERE r.occurrence_id = @occurrence_id;
    IF @rstate IN (N'SUBMITTED', N'APPROVED')
        THROW 54678, 'The result is waiting for review or already approved; it cannot be changed.', 1;
    IF @expected_record_version IS NOT NULL AND @rv IS NOT NULL AND @expected_record_version <> @rv
        THROW 54680, 'The result was changed by someone else; reload it and try again.', 1;

    IF @outcome IS NOT NULL
       AND NOT ((@kind = N'EXECUTION' AND @outcome IN (N'PASS', N'FAIL')) OR (@kind = N'RENEWAL' AND @outcome IN (N'RENEWED', N'NOT_RENEWED')))
        THROW 54672, 'The outcome is Pass or Fail for this activity, Renewed or Not renewed for a renewal.', 1;
    IF @performed_date > @today
        THROW 54673, 'The performed date cannot be in the future.', 1;
    IF @certificate_expiry IS NOT NULL AND @performed_date IS NOT NULL AND @certificate_expiry <= @performed_date
        THROW 54675, 'The certificate expiry must follow the performed (certificate issue) date.', 1;
    IF ISNULL(@submit, 0) = 1
    BEGIN
        IF @outcome IS NULL
            THROW 54672, 'Select the outcome before submitting.', 1;
        IF @performed_date IS NULL
            THROW 54673, 'Enter the performed date before submitting.', 1;
        IF @outcome = N'PASS' AND @cert_key IS NOT NULL AND @certificate_number IS NULL
            THROW 54674, 'The certificate number is required after a successful result.', 1;
        IF @outcome = N'RENEWED'
        BEGIN
            SET @cur_exp = (SELECT v.value_date FROM grac_practice.asset_field_value v
                              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                                         AND f.field_key = @expiry_key
                             WHERE v.asset_id = @asset);
            IF @new_expiry IS NULL OR @new_expiry <= @performed_date OR (@cur_exp IS NOT NULL AND @new_expiry <= @cur_exp)
                THROW 54676, 'Enter the new expiry date: after the performed date and after the current expiry.', 1;
        END
        IF @outcome IN (N'FAIL', N'NOT_RENEWED') AND @result_note IS NULL
            THROW 54677, 'Describe the failure or the reason it was not renewed in the note.', 1;
    END

    DECLARE @new_state NVARCHAR(12) = CASE WHEN ISNULL(@submit, 0) = 0 THEN N'DRAFT'
                                           WHEN ISNULL(@review, 0) = 1 THEN N'SUBMITTED' ELSE N'APPROVED' END;
    BEGIN TRAN;
    IF @rid IS NULL
    BEGIN
        INSERT grac_practice.asset_activity_result
            (organization_id, occurrence_id, state, outcome, performed_date, certificate_number, certificate_expiry, new_expiry,
             evidence_reference, result_note, entered_by)
        VALUES (@organization_id, @occurrence_id, N'DRAFT', @outcome, @performed_date, @certificate_number, @certificate_expiry,
                @new_expiry, @evidence_reference, @result_note, @actor);
        SET @rid = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.asset_activity_result
           SET outcome = @outcome, performed_date = @performed_date, certificate_number = @certificate_number,
               certificate_expiry = @certificate_expiry, new_expiry = @new_expiry, evidence_reference = @evidence_reference,
               result_note = @result_note, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE result_id = @rid;

    UPDATE grac_practice.asset_activity_result
       SET state = @new_state,
           submitted_by = CASE WHEN @new_state = N'DRAFT' THEN submitted_by ELSE @actor END,
           submitted_by_employee_id = CASE WHEN @new_state = N'DRAFT' THEN submitted_by_employee_id ELSE @actor_employee_id END,
           submitted_dt = CASE WHEN @new_state = N'DRAFT' THEN submitted_dt ELSE SYSUTCDATETIME() END,
           decided_by = CASE WHEN @new_state = N'APPROVED' THEN @actor ELSE NULL END,
           decided_by_employee_id = CASE WHEN @new_state = N'APPROVED' THEN @actor_employee_id ELSE NULL END,
           decided_dt = CASE WHEN @new_state = N'APPROVED' THEN SYSUTCDATETIME() ELSE NULL END,
           decision_note = CASE WHEN @new_state = N'APPROVED' THEN N'No reviewer is required for this activity by the organization settings.'
                                ELSE NULL END
     WHERE result_id = @rid;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-result', @rid, CASE @new_state WHEN N'DRAFT' THEN N'SAVE' ELSE N'SUBMIT' END, @before,
            (SELECT @new_state AS state, @outcome AS outcome, @performed_date AS performedDate, @certificate_number AS certificateNumber,
                    @certificate_expiry AS certificateExpiry, @new_expiry AS newExpiry, @evidence_reference AS evidenceReference
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    IF @new_state = N'APPROVED'
        EXEC grac_practice.sp_asset_activity_result_apply @result_id = @rid, @actor = @actor;
    COMMIT;
    SELECT @occurrence_id AS OccurrenceId, @new_state AS Result;
END
GO

-- Approve or return a submitted result. The person who submitted it
-- cannot decide it (segregation of duties).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_result_decide
    @organization_id         BIGINT,
    @occurrence_id           BIGINT,
    @decision                NVARCHAR(10),       -- APPROVE | RETURN
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
    DECLARE @found BIT = 0, @ostatus NVARCHAR(12);
    SELECT @found = 1, @ostatus = status FROM grac_practice.asset_activity_occurrence
     WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54670, 'Activity occurrence not found for this organization.', 1;
    DECLARE @rid BIGINT, @rstate NVARCHAR(12), @rv BIGINT, @sub_by NVARCHAR(100), @sub_emp BIGINT;
    SELECT @rid = result_id, @rstate = state, @rv = CONVERT(BIGINT, record_version), @sub_by = submitted_by,
           @sub_emp = submitted_by_employee_id
      FROM grac_practice.asset_activity_result WHERE occurrence_id = @occurrence_id;
    IF @decision NOT IN (N'APPROVE', N'RETURN')
        THROW 54681, 'The decision must be Approve or Return.', 1;
    IF @rid IS NULL OR @rstate <> N'SUBMITTED'
        THROW 54678, 'There is no submitted result waiting for review.', 1;
    IF @ostatus <> N'OPEN'
        THROW 54671, 'The occurrence is no longer open.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54680, 'The result was changed by someone else; reload it and try again.', 1;
    IF @sub_by = @actor OR (@sub_emp IS NOT NULL AND @sub_emp = @actor_employee_id)
        THROW 54679, 'Segregation of duties: the person who submitted the result cannot review it.', 1;
    IF @decision = N'RETURN' AND @decision_note IS NULL
        THROW 54677, 'Give the reason for returning the result.', 1;

    DECLARE @new_state NVARCHAR(12) = CASE @decision WHEN N'APPROVE' THEN N'APPROVED' ELSE N'RETURNED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_activity_result
       SET state = @new_state, decided_by = @actor, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME(),
           decision_note = @decision_note, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE result_id = @rid;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-result', @rid, @decision, N'{"state":"SUBMITTED"}',
            (SELECT @new_state AS state, @decision_note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    IF @new_state = N'APPROVED'
        EXEC grac_practice.sp_asset_activity_result_apply @result_id = @rid, @actor = @actor;
    COMMIT;
    SELECT @occurrence_id AS OccurrenceId, @new_state AS Result;
END
GO
PRINT '439: result procedures created.';
GO

-- =====================================================================
-- 11. Dispositions (7.1.5; D73-D76)
-- =====================================================================
-- Applies an approved disposition (inside the transaction of the caller).
--   Reschedule: the occurrence keeps its due date and gets the revised due
--     date; an open task gets it as its approved extended due date (the
--     192 invariant sla_due_at = COALESCE(extended, standard)) with a task
--     activity entry; notifications move with it (437 sweep re-issued).
--   Waive / Not applicable / Exception: the occurrence is Waived until the
--     review date; an Open / Assigned / In progress task is cancelled with
--     the reason; a task in another state is left to its owner (noted).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_disposition_apply
    @disposition_id    BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @occ BIGINT, @type NVARCHAR(16), @reason NVARCHAR(1000), @revised DATE, @review DATE, @task BIGINT,
            @task_status NVARCHAR(60), @old_due DATETIME2, @new_due DATETIME2, @note NVARCHAR(400), @remark NVARCHAR(MAX),
            @from NVARCHAR(400), @to NVARCHAR(400), @reason_text NVARCHAR(1000);
    SELECT @occ = d.occurrence_id, @type = d.disposition_type, @reason = d.reason, @revised = d.revised_due_date,
           @review = d.review_date, @task = o.task_id
      FROM grac_practice.asset_activity_disposition d
      JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = d.occurrence_id
     WHERE d.disposition_id = @disposition_id AND d.status = N'APPROVED';
    IF @occ IS NULL RETURN;
    SELECT @task_status = s.status_code, @old_due = t.sla_due_at
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.task_id = @task;

    IF @type = N'RESCHEDULE'
    BEGIN
        UPDATE grac_practice.asset_activity_occurrence
           SET revised_due_date = @revised, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE occurrence_id = @occ;
        IF @task IS NOT NULL AND @task_status NOT IN (N'Closed', N'Cancelled')
        BEGIN
            SET @new_due = CAST(@revised AS DATETIME2);
            UPDATE grac_practice.practice_task
               SET approved_extended_due_at = @new_due, sla_due_at = @new_due, sla_source_code = N'EXTENDED',
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE task_id = @task;
            SELECT @remark = CONCAT(N'Asset activity rescheduled (approved disposition ', @disposition_id, N'): ', @reason),
                   @from = CONVERT(NVARCHAR(30), @old_due, 126), @to = CONVERT(NVARCHAR(30), @new_due, 126);
            EXEC grac_practice.sp_task_activity_add @task_id = @task, @activity_type_code = N'SlaExtensionApproved',
                 @remark = @remark, @from_value = @from, @to_value = @to,
                 @actor_employee_id = @actor_employee_id, @caller_display_name = @actor;
            SET @note = CONCAT(N'Task due date moved to ', CONVERT(NVARCHAR(10), @revised, 23), N'.');
        END
        ELSE IF @task IS NOT NULL
            SET @note = CONCAT(N'The task is ', @task_status, N'; its due date was not changed.');
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_activity_occurrence
           SET status = N'WAIVED', review_date = @review, closed_dt = SYSUTCDATETIME(), needs_reconciliation = 0,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE occurrence_id = @occ AND status = N'OPEN';
        IF @task IS NOT NULL AND @task_status IN (N'Open', N'Assigned', N'InProgress')
        BEGIN
            SET @reason_text = LEFT(CONCAT(CASE @type WHEN N'WAIVE' THEN N'Waived' WHEN N'NOT_APPLICABLE' THEN N'Not applicable'
                                                      ELSE N'Exception' END,
                                           N' until ', CONVERT(NVARCHAR(10), @review, 23), N': ', @reason), 1000);
            EXEC grac_practice.sp_task_transition @task_id = @task, @to_status_code = N'Cancelled',
                 @actor_employee_id = @actor_employee_id, @reason_code = N'ASSET_DISPOSITION', @reason_text = @reason_text;
            SET @note = N'Task cancelled.';
        END
        ELSE IF @task IS NOT NULL AND @task_status NOT IN (N'Closed', N'Cancelled')
            SET @note = CONCAT(N'The task is ', @task_status, N'; close or cancel it in Task Centre.');
    END
    UPDATE grac_practice.asset_activity_disposition SET task_note = @note WHERE disposition_id = @disposition_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-occurrence', @occ, @type, NULL,
            (SELECT @disposition_id AS dispositionId, @revised AS revisedDueDate, @review AS reviewDate, @note AS taskNote
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
END
GO

-- Request a reschedule, waiver, not-applicable or exception outcome for an
-- open occurrence: reason always; revised due date (reschedule) or review
-- date (the others). Approved at once when the organization does not
-- require approval for the activity.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_disposition_request
    @organization_id         BIGINT,
    @occurrence_id           BIGINT,
    @disposition_type        NVARCHAR(16),
    @reason                  NVARCHAR(1000) = NULL,
    @revised_due_date        DATE           = NULL,
    @review_date             DATE           = NULL,
    @expected_record_version BIGINT         = NULL,     -- of the occurrence
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @disposition_type = UPPER(LTRIM(RTRIM(ISNULL(@disposition_type, N''))));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @found BIT = 0, @status NVARCHAR(12), @due DATE, @eff_due DATE, @tpl NVARCHAR(40), @rv BIGINT, @approval BIT;
    SELECT @found = 1, @status = status, @due = due_date, @eff_due = ISNULL(revised_due_date, due_date), @tpl = template_code,
           @rv = CONVERT(BIGINT, record_version)
      FROM grac_practice.asset_activity_occurrence
     WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54670, 'Activity occurrence not found for this organization.', 1;
    IF @status <> N'OPEN' THROW 54671, 'Only an open occurrence can be rescheduled, waived or excepted.', 1;
    IF @disposition_type NOT IN (N'RESCHEDULE', N'WAIVE', N'NOT_APPLICABLE', N'EXCEPTION')
        THROW 54682, 'The outcome is Reschedule, Waive, Not applicable or Exception.', 1;
    IF @reason IS NULL THROW 54677, 'Enter the reason.', 1;
    IF @disposition_type = N'RESCHEDULE' AND (@revised_due_date IS NULL OR @revised_due_date < @today OR @revised_due_date = @eff_due)
        THROW 54683, 'Enter a revised due date from today on, different from the current due date.', 1;
    IF @disposition_type <> N'RESCHEDULE' AND (@review_date IS NULL OR @review_date <= @today)
        THROW 54684, 'Enter the review date (after today) until which the outcome applies.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_activity_disposition WHERE occurrence_id = @occurrence_id AND status = N'PENDING')
        THROW 54685, 'A request is already waiting for approval on this occurrence.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54680, 'The occurrence was changed by someone else; reload it and try again.', 1;
    SET @approval = (SELECT DispositionApprovalRequired FROM grac_practice.fn_asset_activity_settings(@organization_id)
                      WHERE TemplateCode = @tpl);

    DECLARE @id BIGINT, @new_status NVARCHAR(12) = CASE WHEN ISNULL(@approval, 1) = 1 THEN N'PENDING' ELSE N'APPROVED' END;
    BEGIN TRAN;
    INSERT grac_practice.asset_activity_disposition
        (organization_id, occurrence_id, disposition_type, reason, previous_due_date, revised_due_date, review_date, status,
         requested_by, requested_by_employee_id, decided_by, decided_by_employee_id, decided_dt, decision_note)
    VALUES (@organization_id, @occurrence_id, @disposition_type, @reason, @eff_due,
            CASE WHEN @disposition_type = N'RESCHEDULE' THEN @revised_due_date END,
            CASE WHEN @disposition_type <> N'RESCHEDULE' THEN @review_date END,
            @new_status, @actor, @actor_employee_id,
            CASE WHEN @new_status = N'APPROVED' THEN @actor END,
            CASE WHEN @new_status = N'APPROVED' THEN @actor_employee_id END,
            CASE WHEN @new_status = N'APPROVED' THEN SYSUTCDATETIME() END,
            CASE WHEN @new_status = N'APPROVED' THEN N'No approval is required for this activity by the organization settings.' END);
    SET @id = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-disposition', @id, N'REQUEST', NULL,
            (SELECT @occurrence_id AS occurrenceId, @disposition_type AS dispositionType, @reason AS reason,
                    @revised_due_date AS revisedDueDate, @review_date AS reviewDate, @new_status AS status
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    IF @new_status = N'APPROVED'
        EXEC grac_practice.sp_asset_activity_disposition_apply @disposition_id = @id, @actor_employee_id = @actor_employee_id, @actor = @actor;
    COMMIT;
    SELECT @id AS DispositionId, @new_status AS Result;
END
GO

-- Approve / reject (another person; reject needs a note) or withdraw (the
-- requester) a pending disposition.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_disposition_decide
    @organization_id         BIGINT,
    @disposition_id          BIGINT,
    @decision                NVARCHAR(10),       -- APPROVE | REJECT | WITHDRAW
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
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @found BIT = 0, @status NVARCHAR(12), @rv BIGINT, @req_by NVARCHAR(100), @req_emp BIGINT, @type NVARCHAR(16),
            @revised DATE, @review DATE, @ostatus NVARCHAR(12);
    SELECT @found = 1, @status = d.status, @rv = CONVERT(BIGINT, d.record_version), @req_by = d.requested_by,
           @req_emp = d.requested_by_employee_id, @type = d.disposition_type, @revised = d.revised_due_date,
           @review = d.review_date, @ostatus = o.status
      FROM grac_practice.asset_activity_disposition d
      JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = d.occurrence_id
     WHERE d.disposition_id = @disposition_id AND d.organization_id = @organization_id;
    IF @found = 0 THROW 54686, 'Disposition request not found for this organization.', 1;
    IF @decision NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW')
        THROW 54681, 'The decision must be Approve, Reject or Withdraw.', 1;
    IF @status <> N'PENDING'
        THROW 54687, 'This request is no longer waiting for a decision.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54680, 'The request was changed by someone else; reload it and try again.', 1;
    IF @decision = N'WITHDRAW' AND @req_by <> @actor
        THROW 54687, 'Only the person who made the request can withdraw it.', 1;
    IF @decision IN (N'APPROVE', N'REJECT')
       AND (@req_by = @actor OR (@req_emp IS NOT NULL AND @req_emp = @actor_employee_id))
        THROW 54679, 'Segregation of duties: the person who made the request cannot approve or reject it.', 1;
    IF @decision = N'REJECT' AND @decision_note IS NULL
        THROW 54677, 'Give the reason for rejecting the request.', 1;
    IF @decision = N'APPROVE' AND @ostatus <> N'OPEN'
        THROW 54671, 'The occurrence is no longer open; reject or withdraw the request.', 1;
    IF @decision = N'APPROVE' AND @type = N'RESCHEDULE' AND @revised < @today
        THROW 54683, 'The revised due date has passed; reject the request and raise a new one.', 1;
    IF @decision = N'APPROVE' AND @type <> N'RESCHEDULE' AND @review <= @today
        THROW 54684, 'The review date has passed; reject the request and raise a new one.', 1;

    DECLARE @new_status NVARCHAR(12) = CASE @decision WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED'
                                                      ELSE N'WITHDRAWN' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_activity_disposition
       SET status = @new_status, decided_by = @actor, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME(),
           decision_note = @decision_note
     WHERE disposition_id = @disposition_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-disposition', @disposition_id, @decision, N'{"status":"PENDING"}',
            (SELECT @new_status AS status, @decision_note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    IF @new_status = N'APPROVED'
        EXEC grac_practice.sp_asset_activity_disposition_apply @disposition_id = @disposition_id,
             @actor_employee_id = @actor_employee_id, @actor = @actor;
    COMMIT;
    SELECT @disposition_id AS DispositionId, @new_status AS Result;
END
GO
PRINT '439: disposition procedures created.';
GO

-- =====================================================================
-- 12. Restrictive-use review decisions (9.1.9; D78)
-- =====================================================================
-- Actions by trigger (BRD 9.1.9 / 7.1.2 / 7.1.3):
--   activity failed / overdue  CONTROLLED_USE, RESTRICTED_USE, REMOVED_FROM_SERVICE,
--                              EXCEPTION_APPROVED, NO_ACTION_REQUIRED
--   licence (renewal) expired  DISABLE, UNINSTALL, REPLACE, PURCHASE, RESTRICTED_USE,
--                              EXCEPTION_APPROVED
--   evidence expired           RESTRICTED_USE, REMOVED_FROM_SERVICE, EXCEPTION_APPROVED,
--                              NO_ACTION_REQUIRED
-- A decided review can be decided again while its cause lasts. The decision
-- does not change the asset lifecycle status (the Lifecycle tab does).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_restrictive_review_decide
    @organization_id         BIGINT,
    @review_id               BIGINT,
    @decision_code           NVARCHAR(30),
    @decision_note           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @decision_code = UPPER(LTRIM(RTRIM(ISNULL(@decision_code, N''))));
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');
    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @kind NVARCHAR(10), @trigger NVARCHAR(10), @before NVARCHAR(MAX);
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @kind = source_kind, @trigger = trigger_code,
           @before = (SELECT r2.status AS status, r2.decision_code AS decisionCode, r2.decision_note AS note
                        FROM grac_practice.asset_restrictive_review r2 WHERE r2.review_id = r.review_id
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
      FROM grac_practice.asset_restrictive_review r
     WHERE r.review_id = @review_id AND r.organization_id = @organization_id;
    IF @found = 0 THROW 54688, 'Restrictive-use review not found for this organization.', 1;
    IF @status = N'RESOLVED' THROW 54690, 'This review was resolved because its cause cleared.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54680, 'The review was changed by someone else; reload it and try again.', 1;
    IF NOT ((@kind = N'ACTIVITY' AND @trigger IN (N'FAILED', N'OVERDUE')
             AND @decision_code IN (N'CONTROLLED_USE', N'RESTRICTED_USE', N'REMOVED_FROM_SERVICE', N'EXCEPTION_APPROVED', N'NO_ACTION_REQUIRED'))
         OR (@kind = N'ACTIVITY' AND @trigger = N'EXPIRED'
             AND @decision_code IN (N'DISABLE', N'UNINSTALL', N'REPLACE', N'PURCHASE', N'RESTRICTED_USE', N'EXCEPTION_APPROVED'))
         OR (@kind = N'EVIDENCE'
             AND @decision_code IN (N'RESTRICTED_USE', N'REMOVED_FROM_SERVICE', N'EXCEPTION_APPROVED', N'NO_ACTION_REQUIRED')))
        THROW 54689, 'That action is not available for this review.', 1;
    IF @decision_note IS NULL THROW 54677, 'Record the reason for the decision.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_restrictive_review
       SET status = N'DECIDED', decision_code = @decision_code, decision_note = @decision_note, decided_by = @actor,
           decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE review_id = @review_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-restrictive-review', @review_id, N'DECIDE', @before,
            (SELECT N'DECIDED' AS status, @decision_code AS decisionCode, @decision_note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @review_id AS ReviewId, N'DECIDED' AS Result;
END
GO
PRINT '439: review decision created.';
GO

-- =====================================================================
-- 13. Readers
-- =====================================================================
-- One occurrence: 1. header  2. result (0 or 1 row)  3. dispositions
-- 4. restrictive-use reviews of the asset and activity.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_occurrence_get
    @organization_id BIGINT,
    @occurrence_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence
                    WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id)
        THROW 54670, 'Activity occurrence not found for this organization.', 1;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.asset_id AS AssetId, a.asset_name AS AssetName,
           o.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind,
           o.due_date AS DueDate, o.revised_due_date AS RevisedDueDate,
           DATEDIFF(DAY, @today, ISNULL(o.revised_due_date, o.due_date)) AS DaysToDue, o.review_date AS ReviewDate,
           o.is_retest AS IsRetest, o.decision AS Decision, o.decision_reason AS DecisionReason, o.status AS Status,
           c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo, o.task_id AS TaskId, pt.task_number AS TaskNumber,
           ts.status_name AS TaskStatusName, ae.employee_name AS TaskOwnerName, o.task_error AS TaskError,
           o.needs_reconciliation AS NeedsReconciliation, o.reconciliation_reason AS ReconciliationReason,
           o.completed_dt AS CompletedDt, cb.employee_name AS CompletedByName,
           st.ResultRequired, st.ResultReviewRequired, st.DispositionApprovalRequired,
           t.certificate_number_field_key AS CertificateNumberFieldKey, t.certificate_expiry_field_key AS CertificateExpiryFieldKey,
           CONVERT(BIGINT, o.record_version) AS RecordVersion
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = o.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = o.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.practice_task pt ON pt.task_id = o.task_id
      LEFT JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = pt.current_status_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = pt.assigned_to_employee_id
      LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = o.completed_by_employee_id
     WHERE o.occurrence_id = @occurrence_id;

    SELECT r.result_id AS ResultId, r.state AS State, r.outcome AS Outcome, r.performed_date AS PerformedDate,
           r.certificate_number AS CertificateNumber, r.certificate_expiry AS CertificateExpiry, r.new_expiry AS NewExpiry,
           r.evidence_reference AS EvidenceReference, r.result_note AS ResultNote, r.submitted_by AS SubmittedBy,
           se.employee_name AS SubmittedByName, r.submitted_dt AS SubmittedDt, r.decided_by AS DecidedBy,
           de.employee_name AS DecidedByName, r.decided_dt AS DecidedDt, r.decision_note AS DecisionNote,
           CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_activity_result r
      LEFT JOIN grac_practice.organization_employee se ON se.employee_id = r.submitted_by_employee_id
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = r.decided_by_employee_id
     WHERE r.occurrence_id = @occurrence_id;

    SELECT d.disposition_id AS DispositionId, d.disposition_type AS DispositionType, d.reason AS Reason,
           d.previous_due_date AS PreviousDueDate, d.revised_due_date AS RevisedDueDate, d.review_date AS ReviewDate,
           d.status AS Status, d.requested_by AS RequestedBy, re.employee_name AS RequestedByName, d.requested_dt AS RequestedDt,
           d.decided_by AS DecidedBy, de.employee_name AS DecidedByName, d.decided_dt AS DecidedDt, d.decision_note AS DecisionNote,
           d.task_note AS TaskNote, CONVERT(BIGINT, d.record_version) AS RecordVersion
      FROM grac_practice.asset_activity_disposition d
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = d.requested_by_employee_id
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = d.decided_by_employee_id
     WHERE d.occurrence_id = @occurrence_id
     ORDER BY d.disposition_id DESC;

    SELECT rr.review_id AS ReviewId, rr.trigger_code AS TriggerCode, rr.trigger_date AS TriggerDate, rr.title AS Title,
           rr.status AS Status, rr.decision_code AS DecisionCode, rr.decision_note AS DecisionNote, rr.decided_dt AS DecidedDt,
           rr.resolved_dt AS ResolvedDt
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_restrictive_review rr ON rr.asset_id = o.asset_id AND rr.source_kind = N'ACTIVITY'
                                                    AND rr.source_code = o.template_code
     WHERE o.occurrence_id = @occurrence_id
     ORDER BY rr.review_id DESC;
END
GO

-- Restrictive-use reviews (recalculated first). @status: NULL = active
-- (open and decided), OPEN, DECIDED, RESOLVED, ALL.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_restrictive_reviews
    @organization_id BIGINT,
    @status          NVARCHAR(10)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54692, 'Organization not found.', 1;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @done INT, @raised INT, @resolved INT;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @done OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    EXEC grac_practice.sp_asset_restrictive_review_sync @organization_id = @organization_id, @actor = @actor,
         @raised = @raised OUTPUT, @resolved = @resolved OUTPUT;

    SELECT r.review_id AS ReviewId, r.asset_id AS AssetId, a.asset_name AS AssetName, r.source_kind AS SourceKind,
           r.source_code AS SourceCode, COALESCE(t.template_name, ef.evidence_name, r.source_code) AS SourceName,
           t.activity_kind AS ActivityKind, r.trigger_code AS TriggerCode, r.trigger_date AS TriggerDate, r.title AS Title,
           r.severity_code AS SeverityCode, r.occurrence_id AS OccurrenceId, r.status AS Status, r.decision_code AS DecisionCode,
           r.decision_note AS DecisionNote, r.decided_by AS DecidedBy, de.employee_name AS DecidedByName, r.decided_dt AS DecidedDt,
           r.resolved_dt AS ResolvedDt, r.resolved_reason AS ResolvedReason, r.entered_dt AS RaisedDt,
           CONVERT(BIGINT, r.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_restrictive_review r
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id
      LEFT JOIN grac_practice.asset_activity_template t ON r.source_kind = N'ACTIVITY' AND t.template_code = r.source_code
      LEFT JOIN grac_practice.asset_evidence_field ef ON r.source_kind = N'EVIDENCE' AND ef.field_key = r.source_code
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = r.decided_by_employee_id
     WHERE r.organization_id = @organization_id
       AND ((@status IS NULL AND r.status IN (N'OPEN', N'DECIDED')) OR @status = N'ALL' OR r.status = @status)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR r.title LIKE N'%' + @search + N'%')
     ORDER BY CASE r.status WHEN N'OPEN' THEN 0 WHEN N'DECIDED' THEN 1 ELSE 2 END,
              CASE r.severity_code WHEN N'CRITICAL' THEN 0 WHEN N'HIGH' THEN 1 WHEN N'MEDIUM' THEN 2 ELSE 3 END,
              r.trigger_date, r.review_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '439: readers created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '439-a template defaults and organization overrides' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.asset_activity_template', 'default_restrict_on_overdue') IS NOT NULL
             AND COL_LENGTH('grac_practice.asset_activity_setting', 'restrict_on_fail') IS NOT NULL
             AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_template
                          WHERE template_code = N'CALIBRATION' AND default_result_review = 1 AND retest_days = 7
                            AND certificate_number_field_key = N'calibration_certificate_number'
                            AND default_restrict_on_overdue = N'CRITICAL,HIGH' AND default_restrict_on_fail = 1)
             AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_template
                          WHERE template_code = N'EQUIPMENT_LICENCE' AND default_restrict_on_overdue = N'ALL')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '439-b occurrence / schedule columns and widened vocabularies',
       CASE WHEN COL_LENGTH('grac_practice.asset_activity_occurrence', 'revised_due_date') IS NOT NULL
             AND COL_LENGTH('grac_practice.asset_activity_occurrence', 'is_retest') IS NOT NULL
             AND COL_LENGTH('grac_practice.asset_activity_schedule', 'revised_due_date') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_act_occ_status' AND definition LIKE '%WAIVED%')
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%ASSET_EVIDENCE%')
             AND EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity
                          WHERE activity_code = N'EVIDENCE_EXPIRY' AND source_available = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '439-c result, disposition, evidence and review tables',
       CASE WHEN OBJECT_ID('grac_practice.asset_activity_result','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_activity_disposition','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_restrictive_review','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM grac_practice.asset_evidence_field) >= 7
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_act_disp_pending' AND is_unique = 1)
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_rr_active' AND is_unique = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '439-d procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_activity_result_apply', 'sp_asset_activity_result_save', 'sp_asset_activity_result_decide',
                                'sp_asset_activity_disposition_apply', 'sp_asset_activity_disposition_request',
                                'sp_asset_activity_disposition_decide', 'sp_asset_restrictive_review_sync',
                                'sp_asset_restrictive_review_decide', 'sp_asset_activity_occurrence_get',
                                'sp_asset_restrictive_reviews')) = 10
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '439-e re-issues carry the 439 additions',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('grac_practice.fn_asset_activity_settings')
                                                     AND name = 'RestrictOnOverdue')
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_task_sync')) LIKE '%result_required%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_schedule_sync')) LIKE '%FAILED_RESULT%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_generate')) LIKE '%is_retest%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_run')) LIKE '%sp_asset_restrictive_review_sync%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) LIKE '%Failed%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) LIKE '%coverage_status%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_parties')) LIKE '%ASSET_EVIDENCE%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) LIKE '%EVIDENCE_EXPIRY:EV:%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) LIKE '%revised_due_date%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_config_get')) LIKE '%asset_evidence_field%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_setting_save')) LIKE '%restrict_on_overdue%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_schedules')) LIKE '%revised_due_date%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_occurrences')) LIKE '%awaiting_decision%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs: users R (records results) and V (reviewer / approver), both with
--   asset-activities; asset A (criticality High) with an open Calibration
--   occurrence and task; asset C with an open Equipment licence renewal
--   task; a vehicle V1 in use with Insurance expiry in 10 days.
--   1. Asset Activities -> Occurrences -> A -> Result: Pass, performed
--      today, no certificate number -> refused (54674). Add the number and
--      expiry, Submit -> Submitted (Calibration needs a reviewer). R tries
--      to approve -> refused (54679). V approves -> occurrence Completed;
--      Register: last calibration date, certificate number / expiry set,
--      Calibration status Valid; next date = performed + 12 months.
--   2. Next occurrence of A (or another asset): Result Fail with a note,
--      approved by V -> schedule Failed, Calibration status Failed, a
--      re-test occurrence opens due performed + 7 days (Critical
--      notification); Restrictive reviews tab shows "Calibration failed"
--      for A. Decide Restricted use with a note -> Decided. Pass the
--      re-test -> the review is Resolved on the next run.
--   3. Close a Calibration task in Task Centre before any result: Run now
--      -> the occurrence stays open, flagged "closed without an approved
--      result".
--   4. Occurrence -> Reschedule to a date 20 days later with a reason (R):
--      Pending; V approves -> due date shown as revised; Task Centre task
--      due date moved (activity "SlaExtensionApproved"); the reminder
--      occurrence in Asset Notifications is superseded and a new one opens.
--   5. Occurrence -> Waive until a date with a reason, approved -> status
--      Waived, task Cancelled; schedule Waived until the review date.
--   6. C -> Result Renewed with a new expiry -> licence expiry updated,
--      schedule next = new expiry. Another licence left Not renewed and
--      expired -> review "Equipment licence renewal expired" with the
--      licence actions (Disable / Uninstall / Replace / Purchase / Restrict /
--      Exception).
--   7. V1: Asset Notifications -> occurrences show "Vehicle insurance of V1
--      expires" (Evidence / certificate expiry); after the date passes a
--      review "Vehicle insurance expired" is raised.
--   8. Templates -> Calibration settings: reviewer off -> a submitted
--      result is approved at once; approval off -> a reschedule applies at
--      once; overdue policy NONE -> no overdue reviews.
-- =====================================================================
