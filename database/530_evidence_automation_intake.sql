-- =====================================================================
-- 530_evidence_automation_intake.sql
--
-- REQUEST (2026-11-12)
-- --------------------
--   "GRAC Evidence Automation & Storage Platform" plan (v1.0,
--   21 Oct 2026), Part A / Phase 1 -- universal intake -- integrated
--   with the existing modules WITHOUT changing them. Decisions taken
--   with sir on 2026-11-12:
--     * Scope: Phase 1 only. Phase 0 (moving file bytes to S3 / Azure
--       Blob / MinIO) is NOT done here; received files are stored in the
--       Evidence Center exactly like an upload today.
--     * Channels: Webhook / Intake API, and File drop (watched folder).
--       Intake email and the pull connectors are later phases.
--     * Always propose: received evidence is stored and recorded with its
--       pass / fail result, but NOTHING is linked, completed or changed
--       until a person accepts it. Accepting links the item through the
--       existing link procedures (476 / 477 / 482), unchanged.
--     * Missing evidence: a "not received" notice to the binding owner
--       and the obligation owner (My Notifications). No Gap Centre rows.
--
-- WHAT THIS FILE DOES
-- -------------------
--   1. Tables (all NEW; no existing table is altered)
--        evidence_automation_binding  one obligation (+ optional evidence
--                                     row) fed by one channel. Webhook
--                                     token stored as a SHA-256 hash only.
--        evidence_automation_event    every evidence event received: period,
--                                     result, metric, the Evidence Center
--                                     item it was stored as, and the
--                                     person's decision (Proposed /
--                                     Accepted / Rejected).
--        evidence_automation_notice   "expected automated evidence not
--                                     received" notices.
--   2. Functions
--        fn_pm_evidence_automation_can_manage  admin / binding owner /
--                                              obligation owner
--        fn_pm_evidence_automation_due         cadence arithmetic
--   3. Procedures (all NEW)
--        sp_evidence_automation_lookups, _obligation_search,
--        _obligation_evidence, _binding_list, _binding_get, _binding_save,
--        _binding_status, _binding_token_set, _binding_resolve_token,
--        _binding_error, _filedrop_bindings, _ingest, _event_list,
--        _event_targets, _event_accept, _event_reject, _missing_sweep,
--        _notice_list, _notice_mark.
--   4. Menu row 'evidence-automation' (Policies & Documents -> Evidence
--      Automation, display order 16) + permissions the 476 way.
--      274_menu_master_seed.sql carries the row as well.
--
-- EXISTING OBJECTS THIS FILE CALLS BUT DOES NOT CHANGE
--   sp_evidence_item_store (476)      stores the received file as an item
--   sp_evidence_link_add   (476)      accept -> one-time evidence row
--   sp_task_evidence_link_add (482)   accept -> open scheduled task
--   fn_pm_task_recurring_evidence (482), vw_pm_instance_evidence_cadence
--   (473/475).
--
-- ERROR NUMBERS: 58400-58429 (user-facing sentences).
-- DEPENDS ON: 254, 412, 449, 476, 477, 482.
-- Rollback: 530_evidence_automation_intake_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2016+ (HASHBYTES on MAX).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.evidence_item','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_evidence_item_store','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_evidence_link_add','P') IS NULL
BEGIN PRINT 'ABORT (530): Evidence Center missing. Run 476 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND (OBJECT_ID('grac_practice.sp_task_evidence_link_add','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_pm_task_evidence_period','IF') IS NULL)
BEGIN PRINT 'ABORT (530): Evidence Center task links missing. Run 477 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND (OBJECT_ID('grac_practice.fn_pm_task_recurring_evidence','IF') IS NULL
   OR COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_evidence_link_add')) NOT LIKE '%instance_evidence_id%')
BEGIN PRINT 'ABORT (530): recurring task evidence missing. Run 482 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
BEGIN PRINT 'ABORT (530): schedule_occurrence_task missing. Run 449 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND (COL_LENGTH('grac_practice.practice_instance_obligation','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','obligation_name') IS NULL)
BEGIN PRINT 'ABORT (530): practice_instance_obligation.owner_employee_id missing. Run 412 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND (COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL)
BEGIN PRINT 'ABORT (530): practice_instance_evidence source columns missing. Run 140 / 232 / 254 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
BEGIN PRINT 'ABORT (530): vw_pm_instance_evidence_cadence missing. Run 473 / 475 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents')
BEGIN PRINT 'ABORT (530): nav-documents (Policies & Documents) menu row missing. Run 384 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('530_evidence_automation_intake: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_automation_binding','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_automation_binding(
        binding_id                      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_ea_binding PRIMARY KEY,
        organization_id                 BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_binding_org
                REFERENCES grac_practice.organization(organization_id),
        -- Public, non-guessable reference (file-drop folder default, logs).
        binding_code                    NVARCHAR(40)   NOT NULL,
        binding_name                    NVARCHAR(200)  NOT NULL,
        practice_instance_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_binding_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id),
        practice_instance_obligation_id BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_binding_pio
                REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id),
        -- Optional: the evidence row of that obligation the files answer.
        instance_evidence_id            BIGINT NULL
            CONSTRAINT fk_pm_ea_binding_evidence
                REFERENCES grac_practice.practice_instance_evidence(evidence_id),
        channel                         NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_ea_binding_channel CHECK (channel IN (N'Webhook', N'FileDrop')),
        source_system                   NVARCHAR(200)  NULL,
        external_control_ref            NVARCHAR(300)  NULL,
        -- Plan 4.5: self-attested (the system that runs the control also
        -- reports it) or independent. Shown to reviewers and auditors.
        independence                    NVARCHAR(20)   NOT NULL
            CONSTRAINT df_pm_ea_binding_indep DEFAULT N'SelfAttested'
            CONSTRAINT ck_pm_ea_binding_indep CHECK (independence IN (N'SelfAttested', N'Independent')),
        expected_cadence                NVARCHAR(20)   NOT NULL
            CONSTRAINT df_pm_ea_binding_cadence DEFAULT N'None'
            CONSTRAINT ck_pm_ea_binding_cadence
                CHECK (expected_cadence IN (N'None', N'Daily', N'Weekly', N'Monthly', N'Quarterly', N'HalfYearly', N'Yearly')),
        grace_days                      INT            NOT NULL
            CONSTRAINT df_pm_ea_binding_grace DEFAULT 1
            CONSTRAINT ck_pm_ea_binding_grace CHECK (grace_days BETWEEN 0 AND 90),
        -- Days a received file stays valid after its period ends. NULL =
        -- no expiry. Becomes the Evidence Center item's valid_to.
        validity_days                   INT            NULL
            CONSTRAINT ck_pm_ea_binding_validity CHECK (validity_days IS NULL OR validity_days BETWEEN 1 AND 3650),
        evidence_type_id                INT            NULL
            CONSTRAINT fk_pm_ea_binding_type
                REFERENCES grac_practice.evidence_type_master(evidence_type_id),
        -- Owner of every item received; reviews the proposals; gets notices.
        owner_employee_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_ea_binding_owner
                REFERENCES grac_practice.organization_employee(employee_id),
        classification                  NVARCHAR(30)   NOT NULL
            CONSTRAINT df_pm_ea_binding_class DEFAULT N'Internal'
            CONSTRAINT ck_pm_ea_binding_class CHECK (classification IN (N'Internal', N'Confidential', N'Restricted')),
        -- FileDrop: folder under <FileDropRoot>/<organization_id>/.
        drop_folder                     NVARCHAR(200)  NULL,
        -- Webhook: SHA-256 of the token; the token itself is never stored.
        token_hash                      VARBINARY(32)  NULL,
        token_hint                      NVARCHAR(12)   NULL,
        token_issued_dt                 DATETIME2      NULL,
        status                          NVARCHAR(20)   NOT NULL
            CONSTRAINT df_pm_ea_binding_status DEFAULT N'Active'
            CONSTRAINT ck_pm_ea_binding_status CHECK (status IN (N'Active', N'Paused', N'Retired')),
        -- Start of the missing-evidence watch (set again on Resume).
        active_from                     DATE           NOT NULL
            CONSTRAINT df_pm_ea_binding_from DEFAULT CONVERT(DATE, SYSUTCDATETIME()),
        last_event_id                   BIGINT         NULL,
        last_received_dt                DATETIME2      NULL,
        last_period_to                  DATE           NULL,
        last_result                     NVARCHAR(20)   NULL,
        last_error                      NVARCHAR(1000) NULL,
        last_error_dt                   DATETIME2      NULL,
        created_by_employee_id          BIGINT         NULL
            CONSTRAINT fk_pm_ea_binding_creator
                REFERENCES grac_practice.organization_employee(employee_id),
        entered_by                      NVARCHAR(100)  NOT NULL,
        entered_dt                      DATETIME2      NOT NULL
            CONSTRAINT df_pm_ea_binding_dt DEFAULT SYSUTCDATETIME(),
        updated_by                      NVARCHAR(100)  NULL,
        updated_dt                      DATETIME2      NULL
    );
    CREATE UNIQUE INDEX ux_pm_ea_binding_code ON grac_practice.evidence_automation_binding(binding_code);
    CREATE UNIQUE INDEX ux_pm_ea_binding_token
        ON grac_practice.evidence_automation_binding(token_hash) WHERE token_hash IS NOT NULL;
    CREATE UNIQUE INDEX ux_pm_ea_binding_folder
        ON grac_practice.evidence_automation_binding(organization_id, drop_folder)
        WHERE drop_folder IS NOT NULL AND status IN (N'Active', N'Paused');
    CREATE INDEX ix_pm_ea_binding_org
        ON grac_practice.evidence_automation_binding(organization_id, status)
        INCLUDE (practice_instance_obligation_id, owner_employee_id, channel, expected_cadence);
    PRINT '530: evidence_automation_binding created.';
END
GO

IF OBJECT_ID('grac_practice.evidence_automation_event','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_automation_event(
        event_id               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_ea_event PRIMARY KEY,
        organization_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_event_org
                REFERENCES grac_practice.organization(organization_id),
        binding_id             BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_event_binding
                REFERENCES grac_practice.evidence_automation_binding(binding_id),
        channel                NVARCHAR(20)   NOT NULL,
        -- The sender's id for the event; a repeat returns the first event.
        external_event_id      NVARCHAR(200)  NULL,
        received_dt            DATETIME2      NOT NULL
            CONSTRAINT df_pm_ea_event_dt DEFAULT SYSUTCDATETIME(),
        occurred_at            DATETIME2      NULL,
        period_from            DATE           NOT NULL,
        period_to              DATE           NOT NULL,
        result                 NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_ea_event_result CHECK (result IN (N'Pass', N'Fail', N'Unknown')),
        metric_value           NVARCHAR(200)  NULL,
        summary                NVARCHAR(2000) NULL,
        source_system          NVARCHAR(200)  NULL,
        source_file_name       NVARCHAR(500)  NULL,
        evidence_item_id       BIGINT         NOT NULL
            CONSTRAINT fk_pm_ea_event_item
                REFERENCES grac_practice.evidence_item(evidence_item_id),
        evidence_file_id       BIGINT         NOT NULL
            CONSTRAINT fk_pm_ea_event_file
                REFERENCES grac_practice.evidence_item_file(evidence_file_id),
        status                 NVARCHAR(20)   NOT NULL
            CONSTRAINT df_pm_ea_event_status DEFAULT N'Proposed'
            CONSTRAINT ck_pm_ea_event_status CHECK (status IN (N'Proposed', N'Accepted', N'Rejected')),
        decision_target_type   NVARCHAR(40)   NULL,
        decision_target_id     BIGINT         NULL,
        evidence_link_id       BIGINT         NULL,
        decided_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_ea_event_decider
                REFERENCES grac_practice.organization_employee(employee_id),
        decided_by             NVARCHAR(100)  NULL,
        decided_dt             DATETIME2      NULL,
        decision_note          NVARCHAR(1000) NULL,
        -- What was received, without the file bytes.
        payload_json           NVARCHAR(MAX)  NULL
    );
    CREATE UNIQUE INDEX ux_pm_ea_event_external
        ON grac_practice.evidence_automation_event(binding_id, external_event_id)
        WHERE external_event_id IS NOT NULL;
    CREATE INDEX ix_pm_ea_event_org
        ON grac_practice.evidence_automation_event(organization_id, status, received_dt)
        INCLUDE (binding_id, result, evidence_item_id);
    CREATE INDEX ix_pm_ea_event_binding
        ON grac_practice.evidence_automation_event(binding_id, received_dt);
    PRINT '530: evidence_automation_event created.';
END
GO

IF OBJECT_ID('grac_practice.evidence_automation_notice','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_automation_notice(
        notice_id             BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_ea_notice PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_notice_org
                REFERENCES grac_practice.organization(organization_id),
        binding_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_notice_binding
                REFERENCES grac_practice.evidence_automation_binding(binding_id),
        recipient_employee_id BIGINT NOT NULL
            CONSTRAINT fk_pm_ea_notice_recipient
                REFERENCES grac_practice.organization_employee(employee_id),
        -- The period end the evidence was expected for.
        due_period_end        DATE      NOT NULL,
        last_received_dt      DATETIME2 NULL,
        raised_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_ea_notice_dt DEFAULT SYSUTCDATETIME(),
        read_dt               DATETIME2 NULL,
        CONSTRAINT uq_pm_ea_notice UNIQUE (binding_id, recipient_employee_id, due_period_end)
    );
    CREATE INDEX ix_pm_ea_notice_recipient
        ON grac_practice.evidence_automation_notice(recipient_employee_id, read_dt)
        INCLUDE (organization_id, binding_id, due_period_end, raised_dt);
    PRINT '530: evidence_automation_notice created.';
END
GO

-- =====================================================================
-- 2. Functions
-- =====================================================================
-- Who may configure a binding and decide its evidence: an organisation
-- admin, the binding owner, or the obligation owner.
CREATE OR ALTER FUNCTION grac_practice.fn_pm_evidence_automation_can_manage
    (@binding_owner_employee_id    BIGINT,
     @obligation_owner_employee_id BIGINT,
     @caller_employee_id           BIGINT,
     @caller_is_admin              BIT)
RETURNS TABLE
AS
RETURN
SELECT CAST(1 AS BIT) AS can_manage
WHERE  ISNULL(@caller_is_admin, 0) = 1
   OR (@caller_employee_id IS NOT NULL
       AND (@caller_employee_id = @binding_owner_employee_id
            OR @caller_employee_id = @obligation_owner_employee_id));
GO

-- Cadence arithmetic. Period ends are base + k * step. The evidence for
-- a period end E is due by E + grace days; it is MISSED when today is
-- later than that. Returns the latest missed period end (NULL = nothing
-- missed) and the next period end still to come.
CREATE OR ALTER FUNCTION grac_practice.fn_pm_evidence_automation_due
    (@cadence    NVARCHAR(20),
     @base_date  DATE,
     @grace_days INT,
     @today      DATE)
RETURNS TABLE
AS
RETURN
WITH u AS (
    SELECT CASE @cadence WHEN N'Daily' THEN 1 WHEN N'Weekly' THEN 7 ELSE NULL END AS step_days,
           CASE @cadence WHEN N'Monthly' THEN 1 WHEN N'Quarterly' THEN 3
                         WHEN N'HalfYearly' THEN 6 WHEN N'Yearly' THEN 12 ELSE NULL END AS step_months,
           DATEADD(DAY, -ISNULL(@grace_days, 0), @today) AS cutoff
), k AS (
    SELECT u.step_days, u.step_months, u.cutoff,
           CASE WHEN @base_date IS NULL OR u.cutoff <= @base_date THEN 0
                WHEN u.step_days   IS NOT NULL THEN (DATEDIFF(DAY, @base_date, u.cutoff) - 1) / u.step_days
                WHEN u.step_months IS NOT NULL THEN DATEDIFF(MONTH, @base_date, u.cutoff) / u.step_months
                ELSE 0 END AS k0
    FROM u
), m AS (
    SELECT k.step_days, k.step_months,
           CASE WHEN k.step_months IS NOT NULL AND k.k0 > 0
                     AND DATEADD(MONTH, k.k0 * k.step_months, @base_date) >= k.cutoff
                THEN k.k0 - 1 ELSE k.k0 END AS k_missed
    FROM k
)
SELECT CASE WHEN m.k_missed >= 1 AND m.step_days IS NOT NULL
                 THEN DATEADD(DAY, m.k_missed * m.step_days, @base_date)
            WHEN m.k_missed >= 1 AND m.step_months IS NOT NULL
                 THEN DATEADD(MONTH, m.k_missed * m.step_months, @base_date)
            ELSE NULL END AS missed_period_end,
       CASE WHEN @base_date IS NULL OR (m.step_days IS NULL AND m.step_months IS NULL) THEN NULL
            WHEN m.step_days IS NOT NULL THEN DATEADD(DAY, (m.k_missed + 1) * m.step_days, @base_date)
            ELSE DATEADD(MONTH, (m.k_missed + 1) * m.step_months, @base_date) END AS next_period_end
FROM m;
GO

-- =====================================================================
-- 3. Lookups for the binding form
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 58400, 'Select an organization.', 1;

    SELECT t.evidence_type_id   AS EvidenceTypeId,
           t.evidence_type_name AS EvidenceType
    FROM   grac_practice.evidence_type_master t
    WHERE  t.is_active = 1
    ORDER  BY t.display_order, t.evidence_type_name;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_name AS EmployeeName,
           e.employee_code AS EmployeeCode
    FROM   grac_practice.organization_employee e
    WHERE  e.organization_id = @organization_id
      AND  e.status = N'Active'
    ORDER  BY e.employee_name;
END
GO

-- Obligations the caller may bind: every active one for an admin, the
-- caller's own otherwise. practice_instance is under View Data Scope (415).
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_obligation_search
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 58400, 'Select an organization.', 1;

    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

    SELECT TOP (50)
           pio.practice_instance_obligation_id AS PracticeInstanceObligationId,
           pio.obligation_name                 AS ObligationName,
           pio.assurance_type                  AS AssuranceType,
           pi.practice_instance_id             AS PracticeInstanceId,
           pi.instance_code                    AS InstanceCode,
           pi.instance_name                    AS InstanceName,
           pio.owner_employee_id               AS OwnerEmployeeId,
           ow.employee_name                    AS OwnerName
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pio.practice_instance_id
    LEFT   JOIN grac_practice.organization_employee ow
           ON ow.employee_id = pio.owner_employee_id
    WHERE  pio.organization_id = @organization_id
      AND  pio.status = N'Active'
      AND  pi.status  = N'Active'
      AND  (ISNULL(@caller_is_admin, 0) = 1
            OR (@caller_employee_id IS NOT NULL AND pio.owner_employee_id = @caller_employee_id))
      AND  (@s IS NULL
            OR pio.obligation_name LIKE N'%' + @s + N'%'
            OR pi.instance_name    LIKE N'%' + @s + N'%'
            OR pi.instance_code    LIKE N'%' + @s + N'%')
    ORDER  BY pi.instance_name, pio.obligation_name;
END
GO

-- The evidence rows of one obligation (the predicate 482 uses).
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_obligation_evidence
    @organization_id                 BIGINT,
    @practice_instance_obligation_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @practice_instance_obligation_id IS NULL
        THROW 58403, 'That obligation was not found in this organization.', 1;

    SELECT pie.evidence_id                                   AS EvidenceId,
           COALESCE(pie.evidence_name, et.evidence_type_name) AS EvidenceName,
           pie.evidence_type_id                              AS EvidenceTypeId,
           et.evidence_type_name                             AS EvidenceType,
           c.EvidenceCadence                                 AS EvidenceCadence
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.practice_instance_evidence pie
           ON pie.practice_instance_id = pio.practice_instance_id
          AND pie.status = N'Active'
          AND (   (pio.obligation_id IS NOT NULL AND pie.source_obligation_id = pio.obligation_id)
               OR pie.source_practice_instance_obligation_id = pio.practice_instance_obligation_id)
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = pie.evidence_type_id
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = pie.evidence_id
    WHERE  pio.practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pio.organization_id = @organization_id
    ORDER  BY EvidenceName;
END
GO

-- =====================================================================
-- 4. Bindings
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_list
    @organization_id    BIGINT,
    @search             NVARCHAR(200) = NULL,
    @channel            NVARCHAR(20)  = NULL,
    @status             NVARCHAR(20)  = NULL,   -- Active / Paused / Retired / NULL = not retired
    @health             NVARCHAR(20)  = NULL,   -- OnTrack / Waiting / Overdue / Failing
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 58400, 'Select an organization.', 1;

    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;

    ;WITH b AS (
        SELECT b.binding_id, b.binding_code, b.binding_name, b.channel, b.source_system,
               b.independence, b.expected_cadence, b.status, b.last_received_dt,
               b.last_period_to, b.last_result, b.last_error, b.last_error_dt,
               b.owner_employee_id, ow.employee_name AS owner_name,
               b.practice_instance_id, pi.instance_name, pi.instance_code,
               pio.practice_instance_obligation_id, pio.obligation_name,
               pio.owner_employee_id AS obligation_owner_employee_id,
               d.missed_period_end, d.next_period_end,
               (SELECT COUNT(*) FROM grac_practice.evidence_automation_event e
                 WHERE e.binding_id = b.binding_id AND e.status = N'Proposed') AS proposed_count,
               CASE WHEN b.status = N'Retired' THEN N'Retired'
                    WHEN b.status = N'Paused'  THEN N'Paused'
                    WHEN d.missed_period_end IS NOT NULL THEN N'Overdue'
                    WHEN b.last_result = N'Fail' THEN N'Failing'
                    WHEN b.last_event_id IS NULL THEN N'Waiting'
                    ELSE N'OnTrack' END AS health,
               CASE WHEN cm.can_manage = 1 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS can_edit
        FROM   grac_practice.evidence_automation_binding b
        JOIN   grac_practice.practice_instance pi
               ON pi.practice_instance_id = b.practice_instance_id
        JOIN   grac_practice.practice_instance_obligation pio
               ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
        LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = b.owner_employee_id
        OUTER  APPLY grac_practice.fn_pm_evidence_automation_due(
                   b.expected_cadence,
                   CASE WHEN b.last_period_to >= b.active_from THEN b.last_period_to ELSE b.active_from END,
                   b.grace_days, @today) d
        OUTER  APPLY grac_practice.fn_pm_evidence_automation_can_manage(
                   b.owner_employee_id, pio.owner_employee_id, @caller_employee_id, @caller_is_admin) cm
        WHERE  b.organization_id = @organization_id
          AND  cm.can_manage = 1
          AND  ((@status IS NULL AND b.status <> N'Retired') OR b.status = @status OR @status = N'All')
          AND  (@channel IS NULL OR b.channel = @channel)
          AND  (@s IS NULL
                OR b.binding_name     LIKE N'%' + @s + N'%'
                OR b.binding_code     LIKE N'%' + @s + N'%'
                OR b.source_system    LIKE N'%' + @s + N'%'
                OR pio.obligation_name LIKE N'%' + @s + N'%'
                OR pi.instance_name   LIKE N'%' + @s + N'%')
    )
    SELECT b.binding_id                      AS BindingId,
           b.binding_code                    AS BindingCode,
           b.binding_name                    AS BindingName,
           b.channel                         AS Channel,
           b.source_system                   AS SourceSystem,
           b.independence                    AS Independence,
           b.expected_cadence                AS ExpectedCadence,
           b.status                          AS Status,
           b.health                          AS Health,
           b.last_received_dt                AS LastReceivedDt,
           b.last_period_to                  AS LastPeriodTo,
           b.last_result                     AS LastResult,
           b.last_error                      AS LastError,
           b.last_error_dt                   AS LastErrorDt,
           b.missed_period_end               AS MissedPeriodEnd,
           b.next_period_end                 AS NextPeriodEnd,
           b.proposed_count                  AS ProposedCount,
           b.owner_employee_id               AS OwnerEmployeeId,
           b.owner_name                      AS OwnerName,
           b.practice_instance_id            AS PracticeInstanceId,
           b.instance_code                   AS InstanceCode,
           b.instance_name                   AS InstanceName,
           b.practice_instance_obligation_id AS PracticeInstanceObligationId,
           b.obligation_name                 AS ObligationName,
           b.can_edit                        AS CanEdit,
           COUNT(*) OVER()                   AS TotalRows
    FROM   b
    WHERE  @health IS NULL OR b.health = @health
    ORDER  BY CASE b.health WHEN N'Overdue' THEN 0 WHEN N'Failing' THEN 1 ELSE 2 END,
              b.binding_name, b.binding_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_get
    @organization_id    BIGINT,
    @binding_id         BIGINT,
    @caller_employee_id BIGINT = NULL,
    @caller_is_admin    BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    -- Result 1: the binding (never the token hash). No row = not found or
    -- not the caller's.
    SELECT b.binding_id                      AS BindingId,
           b.binding_code                    AS BindingCode,
           b.binding_name                    AS BindingName,
           b.channel                         AS Channel,
           b.source_system                   AS SourceSystem,
           b.external_control_ref            AS ExternalControlRef,
           b.independence                    AS Independence,
           b.expected_cadence                AS ExpectedCadence,
           b.grace_days                      AS GraceDays,
           b.validity_days                   AS ValidityDays,
           b.evidence_type_id                AS EvidenceTypeId,
           et.evidence_type_name             AS EvidenceType,
           b.owner_employee_id               AS OwnerEmployeeId,
           ow.employee_name                  AS OwnerName,
           b.classification                  AS Classification,
           b.drop_folder                     AS DropFolder,
           CASE WHEN b.token_hash IS NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS HasToken,
           b.token_hint                      AS TokenHint,
           b.token_issued_dt                 AS TokenIssuedDt,
           b.status                          AS Status,
           b.active_from                     AS ActiveFrom,
           b.last_received_dt                AS LastReceivedDt,
           b.last_period_to                  AS LastPeriodTo,
           b.last_result                     AS LastResult,
           b.last_error                      AS LastError,
           b.last_error_dt                   AS LastErrorDt,
           d.missed_period_end               AS MissedPeriodEnd,
           d.next_period_end                 AS NextPeriodEnd,
           b.practice_instance_id            AS PracticeInstanceId,
           pi.instance_code                  AS InstanceCode,
           pi.instance_name                  AS InstanceName,
           b.practice_instance_obligation_id AS PracticeInstanceObligationId,
           pio.obligation_name               AS ObligationName,
           pio.owner_employee_id             AS ObligationOwnerEmployeeId,
           oo.employee_name                  AS ObligationOwnerName,
           b.instance_evidence_id            AS InstanceEvidenceId,
           COALESCE(pie.evidence_name, pet.evidence_type_name) AS InstanceEvidenceName,
           c.EvidenceCadence                 AS InstanceEvidenceCadence,
           b.entered_by                      AS EnteredBy,
           b.entered_dt                      AS EnteredDt,
           CAST(1 AS BIT)                    AS CanEdit
    FROM   grac_practice.evidence_automation_binding b
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = b.practice_instance_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = b.owner_employee_id
    LEFT   JOIN grac_practice.organization_employee oo ON oo.employee_id = pio.owner_employee_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = b.evidence_type_id
    LEFT   JOIN grac_practice.practice_instance_evidence pie ON pie.evidence_id = b.instance_evidence_id
    LEFT   JOIN grac_practice.evidence_type_master pet ON pet.evidence_type_id = pie.evidence_type_id
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = b.instance_evidence_id
    OUTER  APPLY grac_practice.fn_pm_evidence_automation_due(
               b.expected_cadence,
               CASE WHEN b.last_period_to >= b.active_from THEN b.last_period_to ELSE b.active_from END,
               b.grace_days, @today) d
    CROSS  APPLY grac_practice.fn_pm_evidence_automation_can_manage(
               b.owner_employee_id, pio.owner_employee_id, @caller_employee_id, @caller_is_admin) cm
    WHERE  b.binding_id = @binding_id
      AND  b.organization_id = @organization_id;

    -- Result 2: the latest events.
    SELECT TOP (20)
           e.event_id          AS EventId,
           e.received_dt       AS ReceivedDt,
           e.period_from       AS PeriodFrom,
           e.period_to         AS PeriodTo,
           e.result            AS Result,
           e.metric_value      AS MetricValue,
           e.status            AS Status,
           e.evidence_item_id  AS EvidenceItemId,
           e.source_file_name  AS SourceFileName
    FROM   grac_practice.evidence_automation_event e
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    CROSS  APPLY grac_practice.fn_pm_evidence_automation_can_manage(
               b.owner_employee_id, pio.owner_employee_id, @caller_employee_id, @caller_is_admin) cm
    WHERE  e.binding_id = @binding_id
      AND  e.organization_id = @organization_id
    ORDER  BY e.received_dt DESC, e.event_id DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_save
    @organization_id                 BIGINT,
    @binding_id                      BIGINT         = NULL,   -- NULL = new
    @binding_name                    NVARCHAR(200),
    @practice_instance_obligation_id BIGINT,
    @instance_evidence_id            BIGINT         = NULL,
    @channel                         NVARCHAR(20),
    @source_system                   NVARCHAR(200)  = NULL,
    @external_control_ref            NVARCHAR(300)  = NULL,
    @independence                    NVARCHAR(20)   = N'SelfAttested',
    @expected_cadence                NVARCHAR(20)   = N'None',
    @grace_days                      INT            = 1,
    @validity_days                   INT            = NULL,
    @evidence_type_id                INT            = NULL,
    @owner_employee_id               BIGINT         = NULL,
    @classification                  NVARCHAR(30)   = N'Internal',
    @drop_folder                     NVARCHAR(200)  = NULL,
    @caller_employee_id              BIGINT         = NULL,
    @caller_is_admin                 BIT            = 0,
    @actor                           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 58400, 'Select an organization.', 1;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    SET @binding_name = NULLIF(LTRIM(RTRIM(@binding_name)), N'');
    IF @binding_name IS NULL
        THROW 58405, 'Enter a name for this automated evidence source.', 1;
    SET @channel = NULLIF(LTRIM(RTRIM(@channel)), N'');
    IF @channel IS NULL OR @channel NOT IN (N'Webhook', N'FileDrop')
        THROW 58406, 'Choose how the evidence arrives: Webhook or File drop.', 1;
    SET @independence     = ISNULL(NULLIF(LTRIM(RTRIM(@independence)), N''), N'SelfAttested');
    SET @expected_cadence = ISNULL(NULLIF(LTRIM(RTRIM(@expected_cadence)), N''), N'None');
    SET @grace_days       = ISNULL(@grace_days, 1);
    IF @independence NOT IN (N'SelfAttested', N'Independent')
       OR @expected_cadence NOT IN (N'None', N'Daily', N'Weekly', N'Monthly', N'Quarterly', N'HalfYearly', N'Yearly')
       OR @grace_days NOT BETWEEN 0 AND 90
       OR (@validity_days IS NOT NULL AND @validity_days NOT BETWEEN 1 AND 3650)
        THROW 58407, 'Check the source independence, expected cadence, grace days (0-90) and validity days (1-3650).', 1;
    SET @classification = ISNULL(NULLIF(LTRIM(RTRIM(@classification)), N''), N'Internal');
    IF @classification NOT IN (N'Internal', N'Confidential', N'Restricted')
        THROW 58409, 'Classification must be Internal, Confidential or Restricted.', 1;
    IF @evidence_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t
                        WHERE t.evidence_type_id = @evidence_type_id AND t.is_active = 1)
        THROW 58424, 'That evidence type is not available.', 1;

    -- The obligation and its owner.
    DECLARE @instance_id BIGINT, @obligation_id BIGINT, @obligation_owner BIGINT;
    SELECT @instance_id = pio.practice_instance_id, @obligation_id = pio.obligation_id,
           @obligation_owner = pio.owner_employee_id
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = pio.practice_instance_id
    WHERE  pio.practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pio.organization_id = @organization_id
      AND  pio.status = N'Active';
    IF @instance_id IS NULL
        THROW 58403, 'That obligation was not found in this organization.', 1;

    IF @instance_evidence_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence pie
                        WHERE pie.evidence_id = @instance_evidence_id
                          AND pie.practice_instance_id = @instance_id
                          AND pie.status = N'Active'
                          AND (   (@obligation_id IS NOT NULL AND pie.source_obligation_id = @obligation_id)
                               OR pie.source_practice_instance_obligation_id = @practice_instance_obligation_id))
        THROW 58404, 'That evidence is not asked for by this obligation.', 1;

    SET @owner_employee_id = COALESCE(@owner_employee_id, @obligation_owner, @caller_employee_id);
    IF @owner_employee_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                       WHERE oe.employee_id = @owner_employee_id
                         AND oe.organization_id = @organization_id
                         AND oe.status = N'Active')
        THROW 58408, 'Choose an active employee of this organization as the owner.', 1;

    -- Existing binding: rights are checked against what it is NOW.
    DECLARE @old_status NVARCHAR(20), @old_owner BIGINT, @old_obligation_owner BIGINT, @code NVARCHAR(40),
            @before NVARCHAR(MAX);
    IF @binding_id IS NOT NULL
    BEGIN
        SELECT @old_status = b.status, @old_owner = b.owner_employee_id,
               @old_obligation_owner = pio.owner_employee_id, @code = b.binding_code
        FROM   grac_practice.evidence_automation_binding b
        JOIN   grac_practice.practice_instance_obligation pio
               ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
        WHERE  b.binding_id = @binding_id AND b.organization_id = @organization_id;
        IF @old_status IS NULL
            THROW 58401, 'That automated evidence source was not found.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                           @old_owner, @old_obligation_owner, @caller_employee_id, @caller_is_admin))
            THROW 58402, 'Only an organization administrator, the source owner or the obligation owner can change this source.', 1;
        IF @old_status = N'Retired'
            THROW 58412, 'This source is retired and cannot be changed.', 1;
    END
    -- New, or moved to another obligation: the caller must manage THAT one.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                       NULL, @obligation_owner, @caller_employee_id, @caller_is_admin))
       AND (@binding_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding b
                            WHERE b.binding_id = @binding_id
                              AND b.practice_instance_obligation_id = @practice_instance_obligation_id))
        THROW 58402, 'You can set up automated evidence only for obligations you own, or as an organization administrator.', 1;

    IF @binding_id IS NULL
        SET @code = N'eab-' + LOWER(LEFT(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), 20));

    -- File drop folder: relative, plain characters, no traversal.
    SET @drop_folder = NULLIF(LTRIM(RTRIM(REPLACE(@drop_folder, N'\', N'/'))), N'');
    WHILE @drop_folder IS NOT NULL AND LEFT(@drop_folder, 1) = N'/'  SET @drop_folder = NULLIF(SUBSTRING(@drop_folder, 2, 200), N'');
    WHILE @drop_folder IS NOT NULL AND RIGHT(@drop_folder, 1) = N'/' SET @drop_folder = NULLIF(LEFT(@drop_folder, LEN(@drop_folder) - 1), N'');
    IF @channel = N'FileDrop'
    BEGIN
        SET @drop_folder = ISNULL(@drop_folder, @code);
        IF @drop_folder LIKE N'%..%' OR @drop_folder LIKE N'%:%'
           OR @drop_folder LIKE N'%[^-A-Za-z0-9_ ./]%'
           OR @drop_folder LIKE N'%/[_]processed%' OR @drop_folder LIKE N'%/[_]failed%'
           OR @drop_folder LIKE N'[_]processed%'  OR @drop_folder LIKE N'[_]failed%'
            THROW 58410, 'The drop folder may use letters, digits, spaces, dot, dash, underscore and / only, and must stay inside the organization folder.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding b
                    WHERE b.organization_id = @organization_id
                      AND b.drop_folder = @drop_folder
                      AND b.status <> N'Retired'
                      AND (@binding_id IS NULL OR b.binding_id <> @binding_id))
            THROW 58411, 'Another automated evidence source already uses that drop folder.', 1;
    END
    ELSE
        SET @drop_folder = NULL;

    DECLARE @id BIGINT = @binding_id;

    BEGIN TRAN;

    IF @binding_id IS NULL
    BEGIN
        INSERT grac_practice.evidence_automation_binding
            (organization_id, binding_code, binding_name, practice_instance_id, practice_instance_obligation_id,
             instance_evidence_id, channel, source_system, external_control_ref, independence, expected_cadence,
             grace_days, validity_days, evidence_type_id, owner_employee_id, classification, drop_folder,
             status, active_from, created_by_employee_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @code, @binding_name, @instance_id, @practice_instance_obligation_id,
             @instance_evidence_id, @channel, NULLIF(LTRIM(RTRIM(@source_system)), N''),
             NULLIF(LTRIM(RTRIM(@external_control_ref)), N''), @independence, @expected_cadence,
             @grace_days, @validity_days, @evidence_type_id, @owner_employee_id, @classification, @drop_folder,
             N'Active', CONVERT(DATE, SYSUTCDATETIME()), @caller_employee_id, @actor, SYSUTCDATETIME());
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        SET @before = (SELECT b.binding_name AS name, b.practice_instance_obligation_id AS obligationId,
                              b.instance_evidence_id AS evidenceId, b.channel AS channel,
                              b.expected_cadence AS cadence, b.owner_employee_id AS ownerEmployeeId,
                              b.drop_folder AS dropFolder, b.independence AS independence
                       FROM grac_practice.evidence_automation_binding b WHERE b.binding_id = @binding_id
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        UPDATE grac_practice.evidence_automation_binding
           SET binding_name = @binding_name,
               practice_instance_id = @instance_id,
               practice_instance_obligation_id = @practice_instance_obligation_id,
               instance_evidence_id = @instance_evidence_id,
               channel = @channel,
               source_system = NULLIF(LTRIM(RTRIM(@source_system)), N''),
               external_control_ref = NULLIF(LTRIM(RTRIM(@external_control_ref)), N''),
               independence = @independence,
               expected_cadence = @expected_cadence,
               grace_days = @grace_days,
               validity_days = @validity_days,
               evidence_type_id = @evidence_type_id,
               owner_employee_id = @owner_employee_id,
               classification = @classification,
               drop_folder = @drop_folder,
               -- A file-drop source has no webhook token.
               token_hash = CASE WHEN @channel = N'Webhook' THEN token_hash END,
               token_hint = CASE WHEN @channel = N'Webhook' THEN token_hint END,
               token_issued_dt = CASE WHEN @channel = N'Webhook' THEN token_issued_dt END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE binding_id = @binding_id;
    END

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-automation-binding', @id, CASE WHEN @binding_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
           (SELECT b.binding_name AS name, b.practice_instance_obligation_id AS obligationId,
                   b.instance_evidence_id AS evidenceId, b.channel AS channel,
                   b.expected_cadence AS cadence, b.owner_employee_id AS ownerEmployeeId,
                   b.drop_folder AS dropFolder, b.independence AS independence
            FROM grac_practice.evidence_automation_binding b WHERE b.binding_id = @id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT @id AS BindingId, @code AS BindingCode, @drop_folder AS DropFolder,
           CASE WHEN @binding_id IS NULL THEN N'Automated evidence source created.'
                ELSE N'Automated evidence source saved.' END AS Message;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_status
    @organization_id    BIGINT,
    @binding_id         BIGINT,
    @action             NVARCHAR(20),   -- Pause / Resume / Retire
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    DECLARE @status NVARCHAR(20), @owner BIGINT, @obligation_owner BIGINT;
    SELECT @status = b.status, @owner = b.owner_employee_id, @obligation_owner = pio.owner_employee_id
    FROM   grac_practice.evidence_automation_binding b
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    WHERE  b.binding_id = @binding_id AND b.organization_id = @organization_id;
    IF @status IS NULL
        THROW 58401, 'That automated evidence source was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                       @owner, @obligation_owner, @caller_employee_id, @caller_is_admin))
        THROW 58402, 'Only an organization administrator, the source owner or the obligation owner can change this source.', 1;
    IF @status = N'Retired'
        THROW 58412, 'This source is retired and cannot be changed.', 1;

    DECLARE @new NVARCHAR(20) = CASE @action WHEN N'Pause' THEN N'Paused' WHEN N'Resume' THEN N'Active'
                                             WHEN N'Retire' THEN N'Retired' ELSE NULL END;
    IF @new IS NULL
        THROW 58413, 'Choose Pause, Resume or Retire.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.evidence_automation_binding
       SET status = @new,
           -- Resume restarts the missing-evidence watch from today, so a
           -- pause never raises notices for the paused weeks.
           active_from = CASE WHEN @new = N'Active' AND @status <> N'Active'
                              THEN CONVERT(DATE, SYSUTCDATETIME()) ELSE active_from END,
           -- Retire revokes the webhook token.
           token_hash = CASE WHEN @new = N'Retired' THEN NULL ELSE token_hash END,
           token_hint = CASE WHEN @new = N'Retired' THEN NULL ELSE token_hint END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE binding_id = @binding_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'evidence-automation-binding', @binding_id, UPPER(@action),
            N'{"status":"' + @status + N'"}', N'{"status":"' + @new + N'"}', N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           CASE @new WHEN N'Paused' THEN N'Source paused. Evidence sent to it is refused until it is resumed.'
                     WHEN N'Active' THEN N'Source resumed.'
                     ELSE N'Source retired. Its token no longer works.' END AS Message;
END
GO

-- Webhook token: the API generates it, shows it ONCE and sends only its
-- SHA-256 here. Issuing a new one revokes the previous one.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_token_set
    @organization_id    BIGINT,
    @binding_id         BIGINT,
    @token_hash         VARBINARY(32),
    @token_hint         NVARCHAR(12),
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    DECLARE @status NVARCHAR(20), @channel NVARCHAR(20), @owner BIGINT, @obligation_owner BIGINT, @had BIT;
    SELECT @status = b.status, @channel = b.channel, @owner = b.owner_employee_id,
           @obligation_owner = pio.owner_employee_id,
           @had = CASE WHEN b.token_hash IS NULL THEN 0 ELSE 1 END
    FROM   grac_practice.evidence_automation_binding b
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    WHERE  b.binding_id = @binding_id AND b.organization_id = @organization_id;
    IF @status IS NULL
        THROW 58401, 'That automated evidence source was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                       @owner, @obligation_owner, @caller_employee_id, @caller_is_admin))
        THROW 58402, 'Only an organization administrator, the source owner or the obligation owner can change this source.', 1;
    IF @status = N'Retired'
        THROW 58412, 'This source is retired and cannot be changed.', 1;
    IF @channel <> N'Webhook'
        THROW 58414, 'Only a Webhook source has a token.', 1;
    IF @token_hash IS NULL OR DATALENGTH(@token_hash) <> 32
        THROW 58414, 'The token could not be issued.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.evidence_automation_binding
       SET token_hash = @token_hash, token_hint = @token_hint, token_issued_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE binding_id = @binding_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'evidence-automation-binding', @binding_id, CASE WHEN @had = 1 THEN N'TOKEN_ROTATE' ELSE N'TOKEN_ISSUE' END,
            NULL, N'{"tokenHint":"' + ISNULL(@token_hint, N'') + N'"}', N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           CASE WHEN @had = 1 THEN N'New token issued. The previous token no longer works.'
                ELSE N'Token issued.' END AS Message;
END
GO

-- INTERNAL (intake): which binding a token belongs to.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_resolve_token
    @token_hash VARBINARY(32)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.binding_id      AS BindingId,
           b.organization_id AS OrganizationId,
           b.binding_code    AS BindingCode,
           b.channel         AS Channel,
           b.status          AS Status
    FROM   grac_practice.evidence_automation_binding b
    WHERE  b.token_hash = @token_hash
      AND  b.status <> N'Retired';
END
GO

-- INTERNAL (intake / file drop): remember why the last delivery was refused,
-- so the owner sees it on the screen instead of it vanishing.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_binding_error
    @binding_id BIGINT,
    @error      NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE grac_practice.evidence_automation_binding
       SET last_error = LEFT(@error, 1000), last_error_dt = SYSUTCDATETIME()
     WHERE binding_id = @binding_id;
END
GO

-- INTERNAL (file drop worker): the folders to watch.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_filedrop_bindings
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.binding_id      AS BindingId,
           b.organization_id AS OrganizationId,
           b.binding_code    AS BindingCode,
           b.drop_folder     AS DropFolder
    FROM   grac_practice.evidence_automation_binding b
    WHERE  b.channel = N'FileDrop'
      AND  b.status  = N'Active'
      AND  b.drop_folder IS NOT NULL
      AND  (@organization_id IS NULL OR b.organization_id = @organization_id)
    ORDER  BY b.organization_id, b.binding_id;
END
GO

-- =====================================================================
-- 5. Intake: store the file in the Evidence Center and record the event
--    as a PROPOSAL. Nothing is linked here.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_ingest
    @binding_id        BIGINT,
    @channel           NVARCHAR(20),
    @external_event_id NVARCHAR(200)  = NULL,
    @occurred_at       DATETIME2      = NULL,
    @period_from       DATE           = NULL,
    @period_to         DATE           = NULL,
    @result            NVARCHAR(20)   = NULL,
    @metric_value      NVARCHAR(200)  = NULL,
    @summary           NVARCHAR(2000) = NULL,
    @source_system     NVARCHAR(200)  = NULL,
    @file_name         NVARCHAR(500),
    @content_type      NVARCHAR(200)  = NULL,
    @file_data         VARBINARY(MAX),
    @payload_json      NVARCHAR(MAX)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org BIGINT, @status NVARCHAR(20), @b_channel NVARCHAR(20), @code NVARCHAR(40),
            @b_source NVARCHAR(200), @independence NVARCHAR(20), @validity_days INT,
            @type_id INT, @owner BIGINT, @class NVARCHAR(30), @obligation_name NVARCHAR(500),
            @binding_name NVARCHAR(200);
    SELECT @org = b.organization_id, @status = b.status, @b_channel = b.channel, @code = b.binding_code,
           @b_source = b.source_system, @independence = b.independence, @validity_days = b.validity_days,
           @type_id = COALESCE(b.evidence_type_id, pie.evidence_type_id), @owner = b.owner_employee_id,
           @class = b.classification, @obligation_name = pio.obligation_name, @binding_name = b.binding_name
    FROM   grac_practice.evidence_automation_binding b
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    LEFT   JOIN grac_practice.practice_instance_evidence pie ON pie.evidence_id = b.instance_evidence_id
    WHERE  b.binding_id = @binding_id;

    IF @org IS NULL OR @status = N'Retired'
        THROW 58416, 'This automated evidence source does not exist or has been retired.', 1;
    IF @status = N'Paused'
        THROW 58415, 'This automated evidence source is paused. Ask its owner to resume it.', 1;
    IF @b_channel <> @channel
        THROW 58425, 'This source does not accept evidence on this channel.', 1;

    -- Idempotency: the same event id again returns the first event.
    SET @external_event_id = NULLIF(LTRIM(RTRIM(@external_event_id)), N'');
    IF @external_event_id IS NOT NULL
    BEGIN
        DECLARE @existing BIGINT, @existing_item BIGINT;
        SELECT @existing = e.event_id, @existing_item = e.evidence_item_id
        FROM   grac_practice.evidence_automation_event e
        WHERE  e.binding_id = @binding_id AND e.external_event_id = @external_event_id;
        IF @existing IS NOT NULL
        BEGIN
            SELECT @existing AS EventId, @existing_item AS EvidenceItemId, CAST(1 AS BIT) AS Duplicate,
                   N'This event was already received.' AS Message;
            RETURN;
        END
    END

    -- Period and result.
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    SET @period_to   = COALESCE(@period_to, CONVERT(DATE, @occurred_at), @period_from, @today);
    SET @period_from = COALESCE(@period_from, @period_to);
    IF @period_from > @period_to OR @period_to > DATEADD(DAY, 1, @today) OR @period_from < DATEADD(YEAR, -10, @today)
        THROW 58417, 'The evidence period is not valid: periodFrom must not be after periodTo, and periodTo must not be in the future.', 1;
    SET @result = CASE UPPER(LTRIM(RTRIM(ISNULL(@result, N''))))
                      WHEN N'PASS' THEN N'Pass' WHEN N'PASSED' THEN N'Pass' WHEN N'SUCCESS' THEN N'Pass' WHEN N'OK' THEN N'Pass'
                      WHEN N'FAIL' THEN N'Fail' WHEN N'FAILED' THEN N'Fail' WHEN N'FAILURE' THEN N'Fail' WHEN N'ERROR' THEN N'Fail'
                      WHEN N'' THEN N'Unknown' WHEN N'UNKNOWN' THEN N'Unknown'
                      ELSE NULL END;
    IF @result IS NULL
        THROW 58418, 'result must be Pass, Fail or Unknown.', 1;

    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 58419, 'The evidence file is empty.', 1;
    SET @file_name = NULLIF(LTRIM(RTRIM(@file_name)), N'');
    IF @file_name IS NULL
        THROW 58419, 'The evidence file needs a name.', 1;

    SET @source_system = COALESCE(NULLIF(LTRIM(RTRIM(@source_system)), N''), @b_source);
    SET @summary       = NULLIF(LTRIM(RTRIM(@summary)), N'');
    SET @metric_value  = NULLIF(LTRIM(RTRIM(@metric_value)), N'');

    -- The Evidence Center item (sp_evidence_item_store takes variables only).
    DECLARE @sha VARBINARY(32) = HASHBYTES('SHA2_256', @file_data);
    DECLARE @title NVARCHAR(300) = LEFT(COALESCE(@obligation_name, @binding_name) + N' - automated '
                                        + CONVERT(NVARCHAR(10), @period_to, 23), 300);
    DECLARE @description NVARCHAR(2000) = LEFT(CONCAT(
            N'Automated evidence received via ', CASE @channel WHEN N'FileDrop' THEN N'file drop' ELSE N'webhook' END,
            N' from ', ISNULL(@source_system, N'(source not given)'),
            N'. Result: ', @result,
            CASE WHEN @metric_value IS NOT NULL THEN N' (' + @metric_value + N')' ELSE N'' END,
            N'. Period: ', CONVERT(NVARCHAR(10), @period_from, 23), N' to ', CONVERT(NVARCHAR(10), @period_to, 23),
            N'. Source: ', CASE @independence WHEN N'Independent' THEN N'independent' ELSE N'self-attested' END, N'.',
            CASE WHEN @summary IS NOT NULL THEN N' ' + @summary ELSE N'' END), 2000);
    DECLARE @tags NVARCHAR(500) = LEFT(N'automated,' + @code
                                       + CASE WHEN @source_system IS NOT NULL THEN N',' + @source_system ELSE N'' END, 500);
    DECLARE @valid_to DATE = CASE WHEN @validity_days IS NULL THEN NULL ELSE DATEADD(DAY, @validity_days, @period_to) END;
    DECLARE @actor NVARCHAR(100) = LEFT(N'evidence-automation:' + @code, 100);
    DECLARE @version_note NVARCHAR(1000) = LEFT(N'Received automatically (' + @result + N').', 1000);
    DECLARE @item_id BIGINT = NULL, @file_id BIGINT = NULL, @version_no INT = NULL, @event_id BIGINT;

    BEGIN TRAN;

    EXEC grac_practice.sp_evidence_item_store
         @organization_id      = @org,
         @evidence_item_id     = @item_id OUTPUT,
         @file_name            = @file_name,
         @content_type         = @content_type,
         @file_data            = @file_data,
         @file_sha256          = @sha,
         @version_note         = @version_note,
         @evidence_title       = @title,
         @evidence_type_id     = @type_id,
         @evidence_description = @description,
         @owner_employee_id    = @owner,
         @valid_from           = @period_from,
         @valid_to             = @valid_to,
         @classification       = @class,
         @tags                 = @tags,
         @caller_employee_id   = NULL,
         @actor                = @actor,
         @evidence_file_id     = @file_id OUTPUT,
         @version_no           = @version_no OUTPUT;

    INSERT grac_practice.evidence_automation_event
        (organization_id, binding_id, channel, external_event_id, received_dt, occurred_at,
         period_from, period_to, result, metric_value, summary, source_system, source_file_name,
         evidence_item_id, evidence_file_id, status, payload_json)
    VALUES
        (@org, @binding_id, @channel, @external_event_id, SYSUTCDATETIME(), @occurred_at,
         @period_from, @period_to, @result, @metric_value, @summary, @source_system, @file_name,
         @item_id, @file_id, N'Proposed', @payload_json);
    SET @event_id = SCOPE_IDENTITY();

    UPDATE grac_practice.evidence_automation_binding
       SET last_event_id = @event_id,
           last_received_dt = SYSUTCDATETIME(),
           last_period_to = CASE WHEN last_period_to IS NULL OR @period_to > last_period_to THEN @period_to ELSE last_period_to END,
           last_result = @result,
           last_error = NULL, last_error_dt = NULL
     WHERE binding_id = @binding_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-automation-event', @event_id, N'RECEIVE', NULL,
           (SELECT @binding_id AS bindingId, @channel AS channel, @result AS result,
                   @period_from AS periodFrom, @period_to AS periodTo, @item_id AS evidenceItemId,
                   @external_event_id AS externalEventId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT @event_id AS EventId, @item_id AS EvidenceItemId, CAST(0 AS BIT) AS Duplicate,
           N'Evidence received. It is waiting for review.' AS Message;
END
GO

-- =====================================================================
-- 6. Received evidence -- review
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_event_list
    @organization_id    BIGINT,
    @binding_id         BIGINT        = NULL,
    @status             NVARCHAR(20)  = N'Proposed',   -- Proposed / Accepted / Rejected / All
    @result             NVARCHAR(20)  = NULL,
    @search             NVARCHAR(200) = NULL,
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 58400, 'Select an organization.', 1;

    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @status = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Proposed');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;

    SELECT e.event_id            AS EventId,
           e.binding_id          AS BindingId,
           b.binding_name        AS BindingName,
           b.binding_code        AS BindingCode,
           b.independence        AS Independence,
           e.channel             AS Channel,
           e.received_dt         AS ReceivedDt,
           e.period_from         AS PeriodFrom,
           e.period_to           AS PeriodTo,
           e.result              AS Result,
           e.metric_value        AS MetricValue,
           e.summary             AS Summary,
           e.source_system       AS SourceSystem,
           e.source_file_name    AS SourceFileName,
           e.evidence_item_id    AS EvidenceItemId,
           e.evidence_file_id    AS EvidenceFileId,
           i.evidence_title      AS EvidenceTitle,
           f.version_no          AS VersionNo,
           e.status              AS Status,
           e.decision_target_type AS DecisionTargetType,
           e.decision_target_id  AS DecisionTargetId,
           e.decided_by          AS DecidedBy,
           e.decided_dt          AS DecidedDt,
           e.decision_note       AS DecisionNote,
           b.practice_instance_id AS PracticeInstanceId,
           pi.instance_name      AS InstanceName,
           pio.obligation_name   AS ObligationName,
           CASE WHEN e.status = N'Proposed' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS CanDecide,
           COUNT(*) OVER()       AS TotalRows
    FROM   grac_practice.evidence_automation_event e
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = b.practice_instance_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = e.evidence_item_id
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = e.evidence_file_id
    CROSS  APPLY grac_practice.fn_pm_evidence_automation_can_manage(
               b.owner_employee_id, pio.owner_employee_id, @caller_employee_id, @caller_is_admin) cm
    WHERE  e.organization_id = @organization_id
      AND  (@binding_id IS NULL OR e.binding_id = @binding_id)
      AND  (@status = N'All' OR e.status = @status)
      AND  (@result IS NULL OR e.result = @result)
      AND  (@s IS NULL
            OR b.binding_name     LIKE N'%' + @s + N'%'
            OR pio.obligation_name LIKE N'%' + @s + N'%'
            OR pi.instance_name   LIKE N'%' + @s + N'%'
            OR e.source_system    LIKE N'%' + @s + N'%'
            OR e.source_file_name LIKE N'%' + @s + N'%')
    ORDER  BY e.received_dt DESC, e.event_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Where a received item may be linked when it is accepted:
--   InstanceEvidence  the binding's evidence row, when it is one-time
--   Task              an open scheduled task of the binding's obligation
-- Linkable / NotLinkableReason mirror the checks of the link procedures.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_event_targets
    @organization_id    BIGINT,
    @event_id           BIGINT,
    @caller_employee_id BIGINT = NULL,
    @caller_is_admin    BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item BIGINT, @pio BIGINT, @evidence BIGINT, @p_from DATE, @p_to DATE,
            @valid_from DATE, @valid_to DATE, @item_status NVARCHAR(30), @event_status NVARCHAR(20);
    SELECT @item = e.evidence_item_id, @pio = b.practice_instance_obligation_id,
           @evidence = b.instance_evidence_id, @p_from = e.period_from, @p_to = e.period_to,
           @valid_from = i.valid_from, @valid_to = i.valid_to, @item_status = i.status,
           @event_status = e.status
    FROM   grac_practice.evidence_automation_event e
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = e.evidence_item_id
    CROSS  APPLY grac_practice.fn_pm_evidence_automation_can_manage(
               b.owner_employee_id, pio.owner_employee_id, @caller_employee_id, @caller_is_admin) cm
    WHERE  e.event_id = @event_id AND e.organization_id = @organization_id;

    IF @item IS NULL
        THROW 58420, 'That received evidence was not found.', 1;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    SELECT TOP (50) x.*
    FROM (
        SELECT N'InstanceEvidence' AS TargetType,
               pie.evidence_id     AS TargetId,
               N'Operationalize evidence: ' + COALESCE(pie.evidence_name, et.evidence_type_name, N'evidence') AS TargetLabel,
               CAST(NULL AS DATE)  AS PeriodDate,
               CASE WHEN @item_status <> N'Active' THEN N'The evidence item is not active.'
                    WHEN @valid_to IS NOT NULL AND @valid_to < @today THEN N'The evidence has expired.'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                                  WHERE l.target_type = N'InstanceEvidence' AND l.target_id = pie.evidence_id
                                    AND l.evidence_item_id = @item AND l.status = N'Active')
                         THEN N'Already attached.'
                    ELSE NULL END AS NotLinkableReason,
               CAST(1 AS BIT)      AS Suggested
        FROM   grac_practice.practice_instance_evidence pie
        JOIN   grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = pie.evidence_id
        LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = pie.evidence_type_id
        WHERE  pie.evidence_id = @evidence
          AND  pie.status = N'Active'
          AND  c.EvidenceCadence = N'OneTime'
        UNION ALL
        SELECT N'Task',
               t.task_id,
               ISNULL(t.task_number + N' - ', N'') + ISNULL(t.subject_title, N'Task'),
               sx.occurrence_date,
               CASE WHEN @item_status <> N'Active' THEN N'The evidence item is not active.'
                    WHEN (@valid_from IS NOT NULL AND @valid_from > sx.occurrence_date)
                      OR (@valid_to   IS NOT NULL AND @valid_to   < sx.occurrence_date)
                         THEN N'The evidence is not valid on the task period.'
                    WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                                  WHERE l.target_type = N'Task' AND l.target_id = t.task_id
                                    AND l.evidence_item_id = @item AND l.status = N'Active')
                         THEN N'Already attached.'
                    ELSE NULL END,
               CASE WHEN sx.occurrence_date BETWEEN @p_from AND @p_to THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END
        FROM   grac_practice.schedule_occurrence_task sx
        JOIN   grac_practice.practice_task t
               ON t.task_id = sx.task_id
              AND t.source_type_code = N'Schedule'
              AND t.source_record_id = sx.occurrence_task_id
        WHERE  sx.practice_instance_obligation_id = @pio
          AND  t.organization_id = @organization_id
          AND  t.closed_at IS NULL
    ) x
    ORDER BY x.Suggested DESC, CASE WHEN x.NotLinkableReason IS NULL THEN 0 ELSE 1 END, x.PeriodDate DESC;
END
GO

-- Accept: link through the EXISTING link procedures (unchanged), or
-- target 'None' = keep in the Evidence Center only. The rights are checked
-- HERE (admin / source owner / obligation owner); the link procedure is then
-- told the caller may see the item, which is what that check established.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_event_accept
    @organization_id    BIGINT,
    @event_id           BIGINT,
    @target_type        NVARCHAR(40),     -- InstanceEvidence / Task / None
    @target_id          BIGINT         = NULL,
    @decision_note      NVARCHAR(1000) = NULL,
    @caller_employee_id BIGINT         = NULL,
    @caller_is_admin    BIT            = 0,
    @actor              NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');
    SET @target_type = ISNULL(NULLIF(LTRIM(RTRIM(@target_type)), N''), N'None');

    DECLARE @status NVARCHAR(20), @item BIGINT, @pio BIGINT, @instance BIGINT, @evidence BIGINT,
            @owner BIGINT, @obligation_owner BIGINT;
    SELECT @status = e.status, @item = e.evidence_item_id, @pio = b.practice_instance_obligation_id,
           @instance = b.practice_instance_id, @evidence = b.instance_evidence_id,
           @owner = b.owner_employee_id, @obligation_owner = pio.owner_employee_id
    FROM   grac_practice.evidence_automation_event e
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    WHERE  e.event_id = @event_id AND e.organization_id = @organization_id;

    IF @status IS NULL
        THROW 58420, 'That received evidence was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                       @owner, @obligation_owner, @caller_employee_id, @caller_is_admin))
        THROW 58402, 'Only an organization administrator, the source owner or the obligation owner can review this evidence.', 1;
    IF @status <> N'Proposed'
        THROW 58421, 'This evidence has already been reviewed.', 1;

    -- The target must be one the targets procedure offers.
    DECLARE @task_evidence BIGINT = NULL;
    IF @target_type = N'InstanceEvidence'
    BEGIN
        IF @target_id IS NULL OR @evidence IS NULL OR @target_id <> @evidence
            THROW 58422, 'Choose where to attach the evidence from the list offered.', 1;
    END
    ELSE IF @target_type = N'Task'
    BEGIN
        IF @target_id IS NULL
           OR NOT EXISTS (SELECT 1
                          FROM   grac_practice.schedule_occurrence_task x
                          JOIN   grac_practice.practice_task t
                                 ON t.task_id = x.task_id
                                AND t.source_type_code = N'Schedule'
                                AND t.source_record_id = x.occurrence_task_id
                          WHERE  t.task_id = @target_id
                            AND  x.practice_instance_obligation_id = @pio
                            AND  t.organization_id = @organization_id
                            AND  t.closed_at IS NULL)
            THROW 58422, 'Choose where to attach the evidence from the list offered.', 1;
        -- The task's own recurring evidence row, when it is the binding's.
        IF @evidence IS NOT NULL
           AND EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(@target_id) r
                        WHERE r.evidence_id = @evidence)
            SET @task_evidence = @evidence;
    END
    ELSE IF @target_type <> N'None'
        THROW 58422, 'Choose where to attach the evidence from the list offered.', 1;

    DECLARE @admin_for_link BIT = 1;   -- see the header comment
    DECLARE @link_id BIGINT = NULL;

    BEGIN TRAN;

    IF @target_type = N'InstanceEvidence'
    BEGIN
        EXEC grac_practice.sp_evidence_link_add
             @organization_id      = @organization_id,
             @practice_instance_id = @instance,
             @evidence_id          = @target_id,
             @evidence_item_id     = @item,
             @link_note            = @decision_note,
             @caller_employee_id   = @caller_employee_id,
             @caller_is_admin      = @admin_for_link,
             @actor                = @actor;
        SELECT @link_id = l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'InstanceEvidence' AND l.target_id = @target_id
          AND  l.evidence_item_id = @item AND l.status = N'Active';
    END
    ELSE IF @target_type = N'Task'
    BEGIN
        EXEC grac_practice.sp_task_evidence_link_add
             @task_id              = @target_id,
             @organization_id      = @organization_id,
             @evidence_item_id     = @item,
             @link_note            = @decision_note,
             @caller_employee_id   = @caller_employee_id,
             @caller_is_admin      = @admin_for_link,
             @caller_display_name  = @actor,
             @instance_evidence_id = @task_evidence;
        SELECT @link_id = l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'Task' AND l.target_id = @target_id
          AND  l.evidence_item_id = @item AND l.status = N'Active';
    END

    UPDATE grac_practice.evidence_automation_event
       SET status = N'Accepted',
           decision_target_type = @target_type,
           decision_target_id = CASE WHEN @target_type = N'None' THEN NULL ELSE @target_id END,
           evidence_link_id = @link_id,
           decided_by_employee_id = @caller_employee_id,
           decided_by = @actor, decided_dt = SYSUTCDATETIME(),
           decision_note = @decision_note
     WHERE event_id = @event_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-automation-event', @event_id, N'ACCEPT', N'{"status":"Proposed"}',
           (SELECT @target_type AS targetType, @target_id AS targetId, @link_id AS evidenceLinkId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, @link_id AS EvidenceLinkId,
           CASE @target_type WHEN N'Task' THEN N'Accepted and attached to the task.'
                             WHEN N'InstanceEvidence' THEN N'Accepted and attached to the obligation evidence.'
                             ELSE N'Accepted. The file stays in the Evidence Center.' END AS Message;
END
GO

-- Reject: the event is kept (audit); the item it created is retired when
-- nothing links it, so it cannot be picked by mistake later.
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_event_reject
    @organization_id    BIGINT,
    @event_id           BIGINT,
    @decision_note      NVARCHAR(1000),
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');
    IF @decision_note IS NULL
        THROW 58423, 'Say why this evidence is rejected.', 1;

    DECLARE @status NVARCHAR(20), @item BIGINT, @owner BIGINT, @obligation_owner BIGINT;
    SELECT @status = e.status, @item = e.evidence_item_id,
           @owner = b.owner_employee_id, @obligation_owner = pio.owner_employee_id
    FROM   grac_practice.evidence_automation_event e
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    WHERE  e.event_id = @event_id AND e.organization_id = @organization_id;

    IF @status IS NULL
        THROW 58420, 'That received evidence was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_evidence_automation_can_manage(
                       @owner, @obligation_owner, @caller_employee_id, @caller_is_admin))
        THROW 58402, 'Only an organization administrator, the source owner or the obligation owner can review this evidence.', 1;
    IF @status <> N'Proposed'
        THROW 58421, 'This evidence has already been reviewed.', 1;

    DECLARE @retired BIT = 0;

    BEGIN TRAN;
    UPDATE grac_practice.evidence_automation_event
       SET status = N'Rejected', decided_by_employee_id = @caller_employee_id,
           decided_by = @actor, decided_dt = SYSUTCDATETIME(), decision_note = @decision_note
     WHERE event_id = @event_id;

    -- Only the item this event created, and only while nothing links it.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                    WHERE l.evidence_item_id = @item AND l.status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_automation_event o
                        WHERE o.evidence_item_id = @item AND o.event_id <> @event_id)
    BEGIN
        UPDATE grac_practice.evidence_item
           SET status = N'Retired', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE evidence_item_id = @item AND status = N'Active';
        IF @@ROWCOUNT > 0
        BEGIN
            SET @retired = 1;
            INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
            VALUES (N'evidence-item', @item, N'RETIRE', N'{"status":"Active"}', N'{"status":"Retired","reason":"automated evidence rejected"}', N'Retired', @actor);
        END
    END

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-automation-event', @event_id, N'REJECT', N'{"status":"Proposed"}',
           (SELECT @decision_note AS note, @retired AS itemRetired FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           CASE WHEN @retired = 1 THEN N'Rejected. The file was retired in the Evidence Center.'
                ELSE N'Rejected.' END AS Message;
END
GO

-- =====================================================================
-- 7. Missing evidence -- "not received" notices (worker pass)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_missing_sweep
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @lock INT;

    -- Transaction-owned lock: released by COMMIT, or by the rollback that
    -- XACT_ABORT performs on any error. A second API instance skips.
    BEGIN TRAN;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.evidence_automation_missing_sweep', @LockMode = N'Exclusive',
                               @LockOwner = N'Transaction', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        COMMIT;
        SELECT 0 AS NoticesRaised, N'SKIPPED' AS Result;
        RETURN;
    END

    INSERT grac_practice.evidence_automation_notice
        (organization_id, binding_id, recipient_employee_id, due_period_end, last_received_dt, raised_dt)
    SELECT DISTINCT b.organization_id, b.binding_id, r.employee_id, d.missed_period_end, b.last_received_dt, SYSUTCDATETIME()
    FROM   grac_practice.evidence_automation_binding b
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    CROSS  APPLY grac_practice.fn_pm_evidence_automation_due(
               b.expected_cadence,
               CASE WHEN b.last_period_to >= b.active_from THEN b.last_period_to ELSE b.active_from END,
               b.grace_days, @today) d
    CROSS  APPLY (VALUES (b.owner_employee_id), (pio.owner_employee_id)) r(employee_id)
    JOIN   grac_practice.organization_employee oe
           ON oe.employee_id = r.employee_id
          AND oe.organization_id = b.organization_id
          AND oe.status = N'Active'
    WHERE  b.status = N'Active'
      AND  b.expected_cadence <> N'None'
      AND  d.missed_period_end IS NOT NULL
      AND  (@organization_id IS NULL OR b.organization_id = @organization_id)
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_automation_notice n
                        WHERE n.binding_id = b.binding_id
                          AND n.recipient_employee_id = r.employee_id
                          AND n.due_period_end = d.missed_period_end);

    DECLARE @raised INT = @@ROWCOUNT;
    COMMIT;

    SELECT @raised AS NoticesRaised, N'DONE' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_notice_list
    @recipient_employee_id BIGINT,
    @organization_id       BIGINT       = NULL,
    @status                NVARCHAR(10) = N'Unread',   -- Unread / Read / All
    @page_number           INT          = 1,
    @page_size             INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Unread');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;

    DECLARE @unread INT = (SELECT COUNT(*) FROM grac_practice.evidence_automation_notice n
                            WHERE n.recipient_employee_id = @recipient_employee_id
                              AND n.read_dt IS NULL
                              AND (@organization_id IS NULL OR n.organization_id = @organization_id));

    SELECT n.notice_id           AS NoticeId,
           n.organization_id     AS OrganizationId,
           n.binding_id          AS BindingId,
           b.binding_name        AS BindingName,
           b.expected_cadence    AS ExpectedCadence,
           b.source_system       AS SourceSystem,
           pio.obligation_name   AS ObligationName,
           pi.instance_name      AS InstanceName,
           n.due_period_end      AS DuePeriodEnd,
           n.last_received_dt    AS LastReceivedDt,
           b.last_received_dt    AS CurrentLastReceivedDt,
           n.raised_dt           AS RaisedDt,
           n.read_dt             AS ReadDt,
           CASE WHEN b.owner_employee_id = n.recipient_employee_id AND pio.owner_employee_id = n.recipient_employee_id
                     THEN N'Source and obligation owner'
                WHEN b.owner_employee_id = n.recipient_employee_id THEN N'Source owner'
                ELSE N'Obligation owner' END AS WhyYou,
           COUNT(*) OVER()       AS TotalRows,
           @unread               AS UnreadCount
    FROM   grac_practice.evidence_automation_notice n
    JOIN   grac_practice.evidence_automation_binding b ON b.binding_id = n.binding_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = b.practice_instance_obligation_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = b.practice_instance_id
    WHERE  n.recipient_employee_id = @recipient_employee_id
      AND  (@organization_id IS NULL OR n.organization_id = @organization_id)
      AND  (@status = N'All' OR (@status = N'Unread' AND n.read_dt IS NULL) OR (@status = N'Read' AND n.read_dt IS NOT NULL))
    ORDER  BY n.raised_dt DESC, n.notice_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_notice_mark
    @recipient_employee_id BIGINT,
    @notice_id             BIGINT = NULL,   -- NULL = all unread
    @organization_id       BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE grac_practice.evidence_automation_notice
       SET read_dt = SYSUTCDATETIME()
     WHERE recipient_employee_id = @recipient_employee_id
       AND read_dt IS NULL
       AND (@notice_id IS NULL OR notice_id = @notice_id)
       AND (@organization_id IS NULL OR organization_id = @organization_id);
    SELECT @@ROWCOUNT AS MarkedCount;
END
GO

-- =====================================================================
-- 8. Menu: Policies & Documents -> Evidence Automation
-- =====================================================================
DECLARE @documents_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'evidence-automation', N'Evidence Automation', N'Practice/Index/evidence-automation', 16, N'plug')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @documents_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Policies & Documents',
    status = N'Active', updated_by = 'seed-530', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @documents_id, src.display_order,
     src.icon_class, N'Policies & Documents', N'Active', 'seed-530');
PRINT '530: evidence-automation menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Every active role in every active organisation, as 476 did. The
-- procedures still decide which sources a user sees and may change
-- (admin / source owner / obligation owner); narrow the menu in Role Menu
-- Permissions if wanted.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-530', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'evidence-automation'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '530: evidence-automation permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 9. Verification
-- =====================================================================
SELECT '530 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.evidence_automation_binding','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.evidence_automation_event','U')   IS NOT NULL
             AND OBJECT_ID('grac_practice.evidence_automation_notice','U')  IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '530 functions',
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_evidence_automation_can_manage','IF') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_pm_evidence_automation_due','IF')        IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '530 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_evidence_automation_lookups','P')               IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_obligation_search','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_obligation_evidence','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_list','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_get','P')           IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_save','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_status','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_token_set','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_resolve_token','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_binding_error','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_filedrop_bindings','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_ingest','P')                IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_event_list','P')            IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_event_targets','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_event_accept','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_event_reject','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_missing_sweep','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_notice_list','P')           IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_automation_notice_mark','P')           IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The Evidence Center procedures this file calls are unchanged (same names
-- and parameters it binds).
SELECT '530 existing link procedures still take the parameters used',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_evidence_item_store'))     LIKE '%@evidence_file_id%OUTPUT%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_evidence_link_add'))       LIKE '%@caller_is_admin%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_evidence_link_add'))  LIKE '%@instance_evidence_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '530 cadence arithmetic (daily, 1 grace day)',
       CASE WHEN (SELECT missed_period_end FROM grac_practice.fn_pm_evidence_automation_due(N'Daily', '2026-11-10', 1, '2026-11-12')) IS NULL
             AND (SELECT missed_period_end FROM grac_practice.fn_pm_evidence_automation_due(N'Daily', '2026-11-10', 1, '2026-11-13')) = '2026-11-11'
             AND (SELECT missed_period_end FROM grac_practice.fn_pm_evidence_automation_due(N'Monthly', '2026-01-31', 0, '2026-03-01')) = '2026-02-28'
             AND (SELECT missed_period_end FROM grac_practice.fn_pm_evidence_automation_due(N'None', '2026-01-01', 0, '2026-11-12')) IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '530 evidence-automation sits under Policies & Documents',
       CASE WHEN EXISTS (
              SELECT 1 FROM grac_practice.menu_master m
              JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
              WHERE m.menu_key = N'evidence-automation' AND p.menu_key = N'nav-documents'
                AND m.status = N'Active' AND m.menu_url = N'Practice/Index/evidence-automation')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '530 complete.';
GO
