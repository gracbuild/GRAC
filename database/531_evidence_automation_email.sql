-- =====================================================================
-- 531_evidence_automation_email.sql
--
-- REQUEST (2026-11-12)
-- --------------------
--   "channel lu email koodi include cheyyamo?" -- add Intake email as a third
--   channel of Evidence Automation (530). Decisions taken with sir:
--     * Mailbox: any mailbox read over IMAP (MailKit in the Api).
--     * Senders: each email source lists the senders it accepts (full
--       addresses or @domain); mail from anyone else is refused and shown
--       on the source as "last refused".
--   Routing: one intake mailbox for the installation; a source is reached
--   at <local>+<source code>@<domain> (plus-addressing), or by putting the
--   source code in the subject, e.g. "[eab-1a2b...]".
--
-- WHAT THIS FILE DOES (530 objects only -- nothing older is touched)
--   1. evidence_automation_binding: channel CHECK widened to 'Email';
--      new column allowed_senders (normalised ',a@x.com,@y.org,').
--   2. Re-issued from the 530 bodies, with ONLY these additions:
--        sp_evidence_automation_binding_save  + @allowed_senders (validated,
--                                               required for Email)
--        sp_evidence_automation_binding_get   + AllowedSenders column
--        sp_evidence_automation_ingest        + @sender_address; an Email
--                                               source refuses senders not
--                                               on its list (58426)
--      All new parameters are optional and last, so callers built for 530
--      keep working.
--   3. New: sp_evidence_automation_email_bindings (the worker's routing list).
--
-- ERROR NUMBERS: 58426 sender not allowed, 58427 allowed-senders list invalid.
-- DEPENDS ON: 530. Rollback: 531_evidence_automation_email_rollback.sql
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.evidence_automation_binding','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_evidence_automation_ingest','P') IS NULL
BEGIN
    RAISERROR('531_evidence_automation_email: run 530_evidence_automation_intake.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Table changes (530's own table)
-- =====================================================================
IF COL_LENGTH('grac_practice.evidence_automation_binding','allowed_senders') IS NULL
BEGIN
    ALTER TABLE grac_practice.evidence_automation_binding ADD allowed_senders NVARCHAR(2000) NULL;
    PRINT '531: evidence_automation_binding.allowed_senders added.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = N'ck_pm_ea_binding_channel'
                  AND definition LIKE N'%Email%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_ea_binding_channel')
        ALTER TABLE grac_practice.evidence_automation_binding DROP CONSTRAINT ck_pm_ea_binding_channel;
    ALTER TABLE grac_practice.evidence_automation_binding
        ADD CONSTRAINT ck_pm_ea_binding_channel CHECK (channel IN (N'Webhook', N'FileDrop', N'Email'));
    PRINT '531: channel Email allowed.';
END
GO

-- =====================================================================
-- 2. Re-issued 530 procedures (530 body + the 531 lines marked "531")
-- =====================================================================
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
    @actor                           NVARCHAR(100)  = N'system',
    @allowed_senders                 NVARCHAR(2000) = NULL     -- 531: Email channel
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
    IF @channel IS NULL OR @channel NOT IN (N'Webhook', N'FileDrop', N'Email')
        THROW 58406, 'Choose how the evidence arrives: Webhook, File drop or Email.', 1;
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

    -- 531: Email -- the senders allowed to send evidence to this source,
    -- stored as ',reports@example.com,@example.org,' so the intake can test
    -- one address with CHARINDEX (never LIKE: '_' and '%' are legal in an
    -- address and would widen the match).
    DECLARE @senders NVARCHAR(2000) = NULL;
    IF @channel = N'Email'
    BEGIN
        SET @senders = LOWER(ISNULL(@allowed_senders, N''));
        SET @senders = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@senders, NCHAR(13), N','), NCHAR(10), N','), N';', N','), N' ', N''), NCHAR(9), N'');
        WHILE CHARINDEX(N',,', @senders) > 0 SET @senders = REPLACE(@senders, N',,', N',');
        IF REPLACE(@senders, N',', N'') = N''
            THROW 58427, 'List the senders allowed to send evidence: full addresses (reports@example.com) or whole domains (@example.com), separated by commas.', 1;
        IF LEFT(@senders, 1)  <> N',' SET @senders = N',' + @senders;
        IF RIGHT(@senders, 1) <> N',' SET @senders = @senders + N',';
        DECLARE @sender_entries INT = LEN(@senders) - LEN(REPLACE(@senders, N',', N'')) - 1;
        DECLARE @sender_ats     INT = LEN(@senders) - LEN(REPLACE(@senders, N'@', N''));
        IF @sender_entries < 1 OR @sender_ats <> @sender_entries OR CHARINDEX(N'@,', @senders) > 0 OR LEN(@senders) > 2000
            THROW 58427, 'List the senders allowed to send evidence: full addresses (reports@example.com) or whole domains (@example.com), separated by commas.', 1;
    END

    DECLARE @id BIGINT = @binding_id;

    BEGIN TRAN;

    IF @binding_id IS NULL
    BEGIN
        INSERT grac_practice.evidence_automation_binding
            (organization_id, binding_code, binding_name, practice_instance_id, practice_instance_obligation_id,
             instance_evidence_id, channel, source_system, external_control_ref, independence, expected_cadence,
             grace_days, validity_days, evidence_type_id, owner_employee_id, classification, drop_folder,
             status, active_from, created_by_employee_id, entered_by, entered_dt, allowed_senders)
        VALUES
            (@organization_id, @code, @binding_name, @instance_id, @practice_instance_obligation_id,
             @instance_evidence_id, @channel, NULLIF(LTRIM(RTRIM(@source_system)), N''),
             NULLIF(LTRIM(RTRIM(@external_control_ref)), N''), @independence, @expected_cadence,
             @grace_days, @validity_days, @evidence_type_id, @owner_employee_id, @classification, @drop_folder,
             N'Active', CONVERT(DATE, SYSUTCDATETIME()), @caller_employee_id, @actor, SYSUTCDATETIME(), @senders);
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
               allowed_senders = @senders,                                  -- 531
               -- A file-drop or email source has no webhook token.
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
           b.allowed_senders                 AS AllowedSenders,          -- 531
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
    @payload_json      NVARCHAR(MAX)  = NULL,
    @sender_address    NVARCHAR(320)  = NULL    -- 531: Email channel, the From address
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org BIGINT, @status NVARCHAR(20), @b_channel NVARCHAR(20), @code NVARCHAR(40),
            @b_source NVARCHAR(200), @independence NVARCHAR(20), @validity_days INT,
            @type_id INT, @owner BIGINT, @class NVARCHAR(30), @obligation_name NVARCHAR(500),
            @binding_name NVARCHAR(200), @senders NVARCHAR(2000);
    SELECT @org = b.organization_id, @status = b.status, @b_channel = b.channel, @code = b.binding_code,
           @b_source = b.source_system, @independence = b.independence, @validity_days = b.validity_days,
           @type_id = COALESCE(b.evidence_type_id, pie.evidence_type_id), @owner = b.owner_employee_id,
           @class = b.classification, @obligation_name = pio.obligation_name, @binding_name = b.binding_name,
           @senders = b.allowed_senders
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

    -- 531: an email source accepts mail only from its allowed senders
    -- (a full address, or '@domain' for a whole domain).
    IF @b_channel = N'Email'
    BEGIN
        DECLARE @sender NVARCHAR(320) = LOWER(LTRIM(RTRIM(ISNULL(@sender_address, N''))));
        DECLARE @sender_domain NVARCHAR(320) =
            CASE WHEN CHARINDEX(N'@', @sender) > 0 THEN RIGHT(@sender, CHARINDEX(N'@', REVERSE(@sender))) END;
        IF @sender = N'' OR @sender_domain IS NULL OR @senders IS NULL
           OR (CHARINDEX(N',' + @sender + N',', @senders) = 0 AND CHARINDEX(N',' + @sender_domain + N',', @senders) = 0)
            THROW 58426, 'This sender is not allowed to send evidence to this source.', 1;
    END

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
            N'Automated evidence received via ', CASE @channel WHEN N'FileDrop' THEN N'file drop' WHEN N'Email' THEN N'email' ELSE N'webhook' END,
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
-- 3. The email worker's routing list: active Email sources.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_automation_email_bindings
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.binding_id      AS BindingId,
           b.organization_id AS OrganizationId,
           b.binding_code    AS BindingCode
    FROM   grac_practice.evidence_automation_binding b
    WHERE  b.channel = N'Email'
      AND  b.status  = N'Active'
    ORDER  BY b.binding_id;
END
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
SELECT '531 Email channel allowed' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_ea_binding_channel' AND definition LIKE N'%Email%')
             AND COL_LENGTH('grac_practice.evidence_automation_binding','allowed_senders') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '531 procedures take the new parameters',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_evidence_automation_binding_save') AND name = N'@allowed_senders')
             AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_evidence_automation_ingest') AND name = N'@sender_address')
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_evidence_automation_binding_get')) LIKE N'%AllowedSenders%'
             AND OBJECT_ID('grac_practice.sp_evidence_automation_email_bindings','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '531 complete.';
GO
