-- =====================================================================
-- 184 Gap SLA auto-match + SLA override via Exception Centre
--
-- BEHAVIOUR (sir's spec 2026-08-13):
--   1. When a gap is created OR its analysis is saved, look up an Active
--      org_sla_config whose grac_new.sla_master.classification matches
--      the gap's severity_code, and auto-populate the gap's effective
--      SLA. The org-level tuned pct + time_basis + total_sla_days drive
--      the number of days that lands on the gap.
--
--   2. From the gap detail screen, the operator can OVERRIDE the
--      auto-applied SLA. Override raises an Exception Centre request
--      with request_type_code = 'SLA_CANDIDATE'. Approver enters
--      nothing extra -- the requested days were captured at request
--      time. Approve applies the new SLA to the gap; reject just
--      updates the request status. Only one Pending SLA override per
--      gap at a time (enforced by filtered unique index).
--
--   3. Exception Centre gains TWO tabs:
--        Gap Candidate -- request_type_code = 'GAP_CANDIDATE' (existing)
--        SLA Candidate -- request_type_code = 'SLA_CANDIDATE' (new)
--      Reject-side risk auto-creation stays intact for Gap Candidate
--      only. SLA Candidate rejects DO NOT create a risk (governance
--      rationale: the underlying gap is still tracked with its
--      original SLA; refusing a longer SLA is not a "gap ignored"
--      event).
--
-- WHAT THIS MIGRATION ADDS / CHANGES
-- ---------------------------------
--   Schema:
--     ALTER custom_gap ADD:
--         sla_master_id       BIGINT NULL         (soft ref grac_new.sla_master.sla_id)
--         sla_days_effective  INT    NULL
--         sla_source_code     NVARCHAR(30) NULL   CHECK IN (AUTO, OVERRIDDEN)
--     ALTER exception_request ADD:
--         request_type_code   NVARCHAR(30) NOT NULL DEFAULT 'GAP_CANDIDATE'
--         sla_days_original   INT NULL
--         sla_days_requested  INT NULL
--     Filtered UNIQUE INDEX ux_pm_exception_request_sla_pending
--         (custom_gap_id) WHERE status_code='Pending' AND request_type_code='SLA_CANDIDATE'
--
--   Procs (new):
--     sp_org_sla_match_for_severity
--     sp_custom_gap_apply_sla
--     sp_sla_override_request_create
--     sp_sla_override_approve
--
--   Procs (rewritten):
--     sp_exception_request_reject   -- request_type_code aware; skips risk for SLA_CANDIDATE
--     sp_exception_request_list     -- accepts optional @request_type_code filter for tabs
--
-- ROLLBACK: 184_gap_sla_match_and_override_rollback.sql
-- ERROR CODE RANGE: 55300-55399
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.exception_request','U') IS NULL
   OR OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
BEGIN
    RAISERROR('184: prerequisites missing. Run 054/109/161/178 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Extend custom_gap with SLA provenance columns.
-- =====================================================================
BEGIN TRAN;

IF COL_LENGTH('grac_practice.custom_gap','sla_master_id') IS NULL
    ALTER TABLE grac_practice.custom_gap ADD sla_master_id BIGINT NULL;

IF COL_LENGTH('grac_practice.custom_gap','sla_days_effective') IS NULL
    ALTER TABLE grac_practice.custom_gap ADD sla_days_effective INT NULL;

IF COL_LENGTH('grac_practice.custom_gap','sla_source_code') IS NULL
    ALTER TABLE grac_practice.custom_gap ADD sla_source_code NVARCHAR(30) NULL;

COMMIT TRAN;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_sla_source')
    ALTER TABLE grac_practice.custom_gap
        ADD CONSTRAINT ck_pm_custom_gap_sla_source
            CHECK (sla_source_code IS NULL
                OR sla_source_code IN (N'AUTO', N'OVERRIDDEN'));
GO

-- =====================================================================
-- 2. Extend exception_request with request type + SLA payload columns.
-- =====================================================================
BEGIN TRAN;

IF COL_LENGTH('grac_practice.exception_request','request_type_code') IS NULL
    ALTER TABLE grac_practice.exception_request
        ADD request_type_code NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_exception_request_type DEFAULT N'GAP_CANDIDATE';

IF COL_LENGTH('grac_practice.exception_request','sla_days_original') IS NULL
    ALTER TABLE grac_practice.exception_request ADD sla_days_original INT NULL;

IF COL_LENGTH('grac_practice.exception_request','sla_days_requested') IS NULL
    ALTER TABLE grac_practice.exception_request ADD sla_days_requested INT NULL;

COMMIT TRAN;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request
        ADD CONSTRAINT ck_pm_exception_request_type
            CHECK (request_type_code IN (N'GAP_CANDIDATE', N'SLA_CANDIDATE'));
GO

-- One Pending SLA override per gap. Filtered UNIQUE INDEX -- SQL Server
-- treats each NULL in a filtered UNIQUE as a distinct value only when
-- there are multiple; the filter restricts to non-NULL rows where the
-- pair matters, so one active override is enforced. Gap Candidate is
-- untouched by this index (already allows multiple lifecycle transitions).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_exception_request_sla_pending'
                  AND object_id = OBJECT_ID('grac_practice.exception_request'))
    CREATE UNIQUE INDEX ux_pm_exception_request_sla_pending
        ON grac_practice.exception_request(custom_gap_id)
        WHERE status_code = N'Pending' AND request_type_code = N'SLA_CANDIDATE';
GO

-- =====================================================================
-- 3. sp_org_sla_match_for_severity
--   Given (organization_id, severity_code), returns the Active
--   org_sla_config whose SLA master's classification matches the
--   severity. Case-insensitive match. Returns 0 or 1 row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_match_for_severity
    @organization_id BIGINT,
    @severity_code   NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55300, 'organization_id is required.', 1;

    IF @severity_code IS NULL OR LEN(LTRIM(RTRIM(@severity_code))) = 0
       OR OBJECT_ID('grac_new.sla_master','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS OrgSlaConfigId,
               CAST(NULL AS BIGINT) AS SlaMasterId,
               CAST(NULL AS NVARCHAR(120)) AS SlaMasterCode,
               CAST(NULL AS NVARCHAR(200)) AS SlaMasterName,
               CAST(NULL AS INT)    AS TotalSlaDays,
               CAST(NULL AS DECIMAL(5,2)) AS WarningPct,
               CAST(NULL AS DECIMAL(5,2)) AS EscalationPct,
               CAST(NULL AS NVARCHAR(60)) AS TimeBasis
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH master_matches AS (
        SELECT
            m.sla_id       AS SlaMasterId,
            m.sla_code     AS SlaMasterCode,
            COALESCE(NULLIF(LTRIM(RTRIM(m.classification)), N''),
                     m.sla_code) AS SlaMasterName,
            CASE UPPER(LEFT(ISNULL(m.duration_unit, N''), 3))
                WHEN 'DAY' THEN m.duration_value
                WHEN 'HOU' THEN CAST(CEILING(m.duration_value / 24.0)    AS INT)
                WHEN 'MIN' THEN CAST(CEILING(m.duration_value / 1440.0)  AS INT)
                WHEN 'WEE' THEN m.duration_value * 7
                WHEN 'MON' THEN m.duration_value * 30
                WHEN 'YEA' THEN m.duration_value * 365
                ELSE m.duration_value
            END           AS TotalSlaDays,
            m.warning_pct    AS MasterWarningPct,
            m.escalation_pct AS MasterEscalationPct,
            m.time_basis     AS MasterTimeBasis
        FROM grac_new.sla_master m
        WHERE ISNULL(m.status, N'Active') = N'Active'
          AND UPPER(LTRIM(RTRIM(m.classification))) = UPPER(LTRIM(RTRIM(@severity_code)))
    )
    SELECT TOP 1
        c.org_sla_config_id                        AS OrgSlaConfigId,
        mm.SlaMasterId                             AS SlaMasterId,
        mm.SlaMasterCode                           AS SlaMasterCode,
        mm.SlaMasterName                           AS SlaMasterName,
        COALESCE(c.total_sla_days, mm.TotalSlaDays) AS TotalSlaDays,
        COALESCE(c.warning_pct,    mm.MasterWarningPct)    AS WarningPct,
        COALESCE(c.escalation_pct, mm.MasterEscalationPct) AS EscalationPct,
        COALESCE(c.time_basis,     mm.MasterTimeBasis)     AS TimeBasis
    FROM master_matches mm
    JOIN grac_practice.org_sla_config c
         ON c.sla_master_id   = mm.SlaMasterId
        AND c.organization_id = @organization_id
        AND c.is_active       = 1
    ORDER BY c.updated_dt DESC, c.org_sla_config_id DESC;
END
GO

-- =====================================================================
-- 4. sp_custom_gap_apply_sla
--   Called by the API tier immediately after sp_custom_gap_create or
--   sp_custom_gap_analysis_save. Idempotent. Resolves the matching
--   SLA and writes sla_master_id + sla_days_effective + due_date on
--   the gap. Skips silently when sla_source_code is 'OVERRIDDEN' so
--   the operator's approved override survives severity re-computes.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_apply_sla
    @custom_gap_id       BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @custom_gap_id IS NULL
        THROW 55310, 'custom_gap_id is required.', 1;

    DECLARE @organization_id BIGINT, @severity_code NVARCHAR(30),
            @current_source NVARCHAR(30), @gap_entered_dt DATETIME2;
    SELECT @organization_id = organization_id,
           @severity_code   = severity_code,
           @current_source  = sla_source_code,
           @gap_entered_dt  = entered_dt
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL
        THROW 55311, 'gap not found.', 1;

    -- Do not clobber an operator-approved override.
    IF @current_source = N'OVERRIDDEN' RETURN;

    IF @severity_code IS NULL OR LEN(LTRIM(RTRIM(@severity_code))) = 0 RETURN;

    -- Resolve the match into locals (proc-in-proc rowset would work but
    -- locals keep the UPDATE compact).
    DECLARE @out TABLE (
        OrgSlaConfigId BIGINT, SlaMasterId BIGINT, SlaMasterCode NVARCHAR(120),
        SlaMasterName NVARCHAR(200), TotalSlaDays INT,
        WarningPct DECIMAL(5,2), EscalationPct DECIMAL(5,2), TimeBasis NVARCHAR(60));

    INSERT @out
    EXEC grac_practice.sp_org_sla_match_for_severity
        @organization_id = @organization_id,
        @severity_code   = @severity_code;

    DECLARE @sla_master_id BIGINT, @total_days INT;
    SELECT TOP 1
        @sla_master_id = SlaMasterId,
        @total_days    = TotalSlaDays
    FROM @out;

    IF @sla_master_id IS NULL OR @total_days IS NULL RETURN;

    UPDATE grac_practice.custom_gap
    SET sla_master_id      = @sla_master_id,
        sla_days_effective = @total_days,
        sla_source_code    = N'AUTO',
        -- due_date honours whatever was captured at gap creation; the
        -- proc pushes it out to entered_dt + N days when NULL, else
        -- leaves an existing user-set date alone unless it predates
        -- the auto SLA (in which case bump).
        due_date           = CASE
            WHEN due_date IS NULL
              OR due_date < DATEADD(DAY, @total_days, CAST(@gap_entered_dt AS DATE))
              THEN DATEADD(DAY, @total_days, CAST(@gap_entered_dt AS DATE))
            ELSE due_date
        END,
        updated_by         = @caller_display_name,
        updated_dt         = SYSUTCDATETIME()
    WHERE custom_gap_id = @custom_gap_id;
END
GO

-- =====================================================================
-- 5. sp_sla_override_request_create
--   Raises an SLA_CANDIDATE exception request for a gap. Blocks when
--   a Pending SLA override already exists for the same gap (filtered
--   UNIQUE index enforces this; we pre-check to return a friendly
--   error). Snapshots current sla_days_effective as sla_days_original
--   for audit.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_sla_override_request_create
    @custom_gap_id            BIGINT,
    @sla_days_requested       INT,
    @request_reason           NVARCHAR(MAX),
    @requested_by_employee_id BIGINT,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @custom_gap_id IS NULL
        THROW 55320, 'custom_gap_id is required.', 1;
    IF @sla_days_requested IS NULL OR @sla_days_requested < 0
        THROW 55321, 'sla_days_requested must be >= 0.', 1;
    IF @request_reason IS NULL OR LEN(LTRIM(RTRIM(@request_reason))) = 0
        THROW 55322, 'request_reason is required.', 1;
    IF @requested_by_employee_id IS NULL
        THROW 55323, 'requested_by_employee_id is required.', 1;

    DECLARE @organization_id BIGINT, @gap_title NVARCHAR(250),
            @sla_days_original INT;
    SELECT @organization_id   = organization_id,
           @gap_title          = title,
           @sla_days_original  = sla_days_effective
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL
        THROW 55324, 'gap not found.', 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.exception_request
        WHERE custom_gap_id     = @custom_gap_id
          AND request_type_code = N'SLA_CANDIDATE'
          AND status_code       = N'Pending')
        THROW 55325,
            'A Pending SLA override request already exists for this gap. Approve, reject or withdraw it before raising another.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @title NVARCHAR(300) =
        CONCAT(N'SLA override: ', LEFT(ISNULL(@gap_title, N''), 200),
               N' (', CAST(@sla_days_requested AS NVARCHAR(10)), N' days)');

    BEGIN TRAN;

    INSERT INTO grac_practice.exception_request
        (organization_id, custom_gap_id, request_title, request_reason,
         status_code, request_type_code, sla_days_original, sla_days_requested,
         requested_by_employee_id, requested_dt,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@organization_id, @custom_gap_id, @title, @request_reason,
         N'Pending', N'SLA_CANDIDATE', @sla_days_original, @sla_days_requested,
         @requested_by_employee_id, SYSUTCDATETIME(),
         @active_record_status_id, @caller_display_name, SYSUTCDATETIME());

    DECLARE @request_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@request_id, N'Create', NULL, N'Pending',
         CONCAT(N'SLA override requested: ', CAST(@sla_days_requested AS NVARCHAR(10)),
                N' days (was ', ISNULL(CAST(@sla_days_original AS NVARCHAR(10)), N'unset'), N'). Reason: ',
                @request_reason),
         @requested_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @request_id AS ExceptionRequestId, N'Pending' AS StatusCode,
           N'SLA_CANDIDATE' AS RequestTypeCode;
END
GO

-- =====================================================================
-- 6. sp_sla_override_approve
--   Approves a Pending SLA_CANDIDATE request and applies the new SLA
--   to the gap: sla_days_effective := sla_days_requested,
--   sla_source_code := 'OVERRIDDEN', due_date recomputed from
--   entered_dt + new days. No effective_until or approval_note (this
--   is not an exception acceptance).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_sla_override_approve
    @exception_request_id    BIGINT,
    @approved_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @exception_request_id IS NULL
        THROW 55330, 'exception_request_id is required.', 1;
    IF @approved_by_employee_id IS NULL
        THROW 55331, 'approved_by_employee_id is required.', 1;

    DECLARE @custom_gap_id BIGINT, @type NVARCHAR(30),
            @current NVARCHAR(30), @sla_days_requested INT;
    SELECT @custom_gap_id      = custom_gap_id,
           @type               = request_type_code,
           @current            = status_code,
           @sla_days_requested = sla_days_requested
    FROM grac_practice.exception_request
    WHERE exception_request_id = @exception_request_id;

    IF @custom_gap_id IS NULL   THROW 55332, 'request not found.', 1;
    IF @type <> N'SLA_CANDIDATE' THROW 55333, 'Not an SLA override request. Use sp_exception_request_approve for Gap Candidate approvals.', 1;
    IF @current <> N'Pending'    THROW 55334, 'Only Pending SLA override requests can be approved.', 1;
    IF @sla_days_requested IS NULL THROW 55335, 'Request is missing sla_days_requested; cannot apply.', 1;

    DECLARE @gap_entered_dt DATETIME2;
    SELECT @gap_entered_dt = entered_dt
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;

    BEGIN TRAN;

    UPDATE grac_practice.exception_request
       SET status_code             = N'Approved',
           approved_by_employee_id = @approved_by_employee_id,
           approved_dt             = SYSUTCDATETIME(),
           updated_by              = @caller_display_name,
           updated_dt              = SYSUTCDATETIME()
     WHERE exception_request_id = @exception_request_id;

    INSERT INTO grac_practice.exception_request_history
        (exception_request_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@exception_request_id, N'Approve', N'Pending', N'Approved',
         CONCAT(N'SLA override approved: ', CAST(@sla_days_requested AS NVARCHAR(10)), N' days applied to gap.'),
         @approved_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    -- Apply the override to the gap.
    UPDATE grac_practice.custom_gap
       SET sla_days_effective = @sla_days_requested,
           sla_source_code    = N'OVERRIDDEN',
           due_date           = DATEADD(DAY, @sla_days_requested, CAST(@gap_entered_dt AS DATE)),
           updated_by         = @caller_display_name,
           updated_dt         = SYSUTCDATETIME()
     WHERE custom_gap_id = @custom_gap_id;

    COMMIT;

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Approved' AS StatusCode,
           @custom_gap_id AS CustomGapId,
           @sla_days_requested AS SlaDaysApplied;
END
GO

-- =====================================================================
-- 7. sp_exception_request_reject  (REWRITE)
--   Same behaviour as 176 for GAP_CANDIDATE (risk auto-create on reject).
--   For SLA_CANDIDATE, the risk auto-create is SKIPPED -- refusing a
--   longer SLA does not turn the gap into an unresolved acceptance.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_reject
    @exception_request_id    BIGINT,
    @rejection_reason        NVARCHAR(MAX),
    @rejected_by_employee_id BIGINT,
    @caller_display_name     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @exception_request_id IS NULL
        THROW 55240, 'sp_exception_request_reject: exception_request_id is required.', 1;
    IF @rejection_reason IS NULL OR LEN(LTRIM(RTRIM(@rejection_reason))) = 0
        THROW 55241, 'sp_exception_request_reject: rejection_reason is required.', 1;
    IF @rejected_by_employee_id IS NULL
        THROW 55242, 'sp_exception_request_reject: rejected_by_employee_id is required.', 1;

    DECLARE @current NVARCHAR(30), @type NVARCHAR(30);
    SELECT @current = status_code, @type = request_type_code
      FROM grac_practice.exception_request WHERE exception_request_id = @exception_request_id;
    IF @current IS NULL
        THROW 55243, 'sp_exception_request_reject: request not found.', 1;
    IF @current <> N'Pending'
        THROW 55244, 'sp_exception_request_reject: only Pending requests can be rejected.', 1;

    BEGIN TRY
        BEGIN TRAN;

        UPDATE grac_practice.exception_request
           SET status_code             = N'Rejected',
               rejected_by_employee_id = @rejected_by_employee_id,
               rejected_dt             = SYSUTCDATETIME(),
               rejection_reason        = @rejection_reason,
               updated_by              = @caller_display_name,
               updated_dt              = SYSUTCDATETIME()
         WHERE exception_request_id = @exception_request_id;

        INSERT INTO grac_practice.exception_request_history
            (exception_request_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@exception_request_id, N'Reject', N'Pending', N'Rejected',
             @rejection_reason, @rejected_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- Risk auto-create ONLY for Gap Candidate (176's behaviour). SLA
    -- Candidate rejects are governance-neutral -- the gap's original
    -- SLA still stands and no acceptance was requested / refused.
    IF @type = N'GAP_CANDIDATE'
    BEGIN
        BEGIN TRY
            DECLARE @gap_id BIGINT;
            SELECT @gap_id = custom_gap_id
              FROM grac_practice.exception_request
             WHERE exception_request_id = @exception_request_id;

            DECLARE @risk_summary NVARCHAR(MAX) =
                CONCAT(N'Auto-raised because exception request #',
                       CAST(@exception_request_id AS NVARCHAR(20)),
                       N' was rejected. Rejection reason: ',
                       @rejection_reason);

            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @risk_summary,
                @requested_by_employee_id = @rejected_by_employee_id,
                @caller_display_name      = @caller_display_name;
        END TRY
        BEGIN CATCH
            DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_exception_request_reject: risk auto-create warning: ', @msg);
        END CATCH
    END

    SELECT @exception_request_id AS ExceptionRequestId,
           N'Rejected' AS StatusCode,
           @type AS RequestTypeCode;
END
GO

-- =====================================================================
-- 8. sp_exception_request_list  (REWRITE)
--   Keeps every column 166 added (ExceptionTypeName, EffectiveFrom,
--   TotalRows -- consumed by ExceptionCentreService) and ADDS the
--   184 columns (RequestTypeCode, SlaDaysOriginal, SlaDaysRequested)
--   plus an optional @request_type_code filter for the new tabs.
--   Passing NULL returns both types (backwards-compatible default).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
      JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.custom_gap_id
 LEFT JOIN grac_practice.exception_type_master   et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee   rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee   ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee   rj ON rj.employee_id       = r.rejected_by_employee_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '184 gap SLA auto-match + override via Exception Centre deployed.';
GO

SET NOEXEC OFF;
GO
