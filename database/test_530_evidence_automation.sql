-- =====================================================================
-- test_530_evidence_automation.sql   (UAT / demo only -- NOT production)
--
-- End-to-end test of migration 530 against a real database. Runs every
-- procedure the API calls, checks the results, then DELETES everything it
-- created (marker: binding name 'ZZ-530-TEST'). Run after
-- 530_evidence_automation_intake.sql, in SSMS, as one script.
--
-- Picks the first organization with an active obligation that has an
-- active owner. To test a specific one, set @pick_pio below.
--
-- What it checks
--   T01 create a Webhook source (as admin)          T12 accept -> Accepted, nothing linked
--   T02 token set + resolve by hash                 T13 reject needs a reason (58423)
--   T03 ingest -> Proposed event + Evidence Center  T14 reject -> Rejected + item Retired
--       item (owner, tags, validity, title)         T15 overdue -> notice to the owner
--   T04 same eventId again -> no second event       T16 second sweep -> no duplicate notice
--   T05 bad result -> 58418                         T17 sources list shows Overdue
--   T06 future period -> 58417                      T18 non-owner cannot change it (58402)
--   T07 wrong channel -> 58425                      T19 notice list / mark read
--   T08 paused -> 58415, resume works               T20 existing Evidence Center procedures
--   T09 file drop source + folder validation (58410)     unchanged by 530
--   T10 targets procedure runs                      T21 Evidence Center grid shows the item
--   T11 event list shows the waiting event      T22-T24 (531) email: senders list rules,
--                                                    allowed sender received, other refused
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT OFF;   -- the expected-error tests are caught below
GO

IF OBJECT_ID('grac_practice.sp_evidence_automation_ingest','P') IS NULL
BEGIN
    RAISERROR('Run 530_evidence_automation_intake.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (id INT IDENTITY, test NVARCHAR(10), what NVARCHAR(300), result NVARCHAR(4), detail NVARCHAR(1000));
GO

DECLARE @pick_pio BIGINT = NULL;   -- optional: a practice_instance_obligation_id to test with

DECLARE @org BIGINT, @pio BIGINT, @owner BIGINT, @other BIGINT, @today DATE = CONVERT(DATE, SYSUTCDATETIME());
SELECT TOP 1 @org = pio.organization_id, @pio = pio.practice_instance_obligation_id, @owner = pio.owner_employee_id
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = pio.practice_instance_id AND pi.status = N'Active'
JOIN   grac_practice.organization_employee e ON e.employee_id = pio.owner_employee_id AND e.status = N'Active'
WHERE  pio.status = N'Active' AND (@pick_pio IS NULL OR pio.practice_instance_obligation_id = @pick_pio)
ORDER  BY pio.organization_id, pio.practice_instance_obligation_id;
SELECT TOP 1 @other = e.employee_id FROM grac_practice.organization_employee e
WHERE e.organization_id = @org AND e.status = N'Active' AND e.employee_id <> @owner ORDER BY e.employee_id;

IF @pio IS NULL
BEGIN
    INSERT #r VALUES (N'T00', N'test data', N'FAIL', N'No active obligation with an active owner found -- set @pick_pio.');
    GOTO done;
END
INSERT #r VALUES (N'T00', N'test data', N'INFO', CONCAT(N'org ', @org, N', obligation ', @pio, N', owner ', @owner, N', other employee ', ISNULL(CONVERT(NVARCHAR(20), @other), N'(none)')));

DECLARE @b BIGINT, @fb BIGINT, @e1 BIGINT, @e2 BIGINT, @item1 BIGINT, @item2 BIGINT, @n INT, @err INT, @msg NVARCHAR(2000);
DECLARE @name NVARCHAR(200) = N'ZZ-530-TEST webhook';
DECLARE @file VARBINARY(MAX) = CAST(N'530 test evidence file' AS VARBINARY(MAX));
DECLARE @token NVARCHAR(100) = N'grac_ei_ZZ530TEST' + REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N'');
DECLARE @hash VARBINARY(32) = HASHBYTES('SHA2_256', CAST(@token AS VARCHAR(100)));   -- UTF-8 = ASCII here, as the API hashes it
DECLARE @t1 NVARCHAR(40) = N'zz530-' + CONVERT(NVARCHAR(36), NEWID());

-- T01 create
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_binding_save
         @organization_id = @org, @binding_name = @name, @practice_instance_obligation_id = @pio,
         @channel = N'Webhook', @source_system = N'TestSystem', @expected_cadence = N'None', @validity_days = 30,
         @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
    SELECT @b = binding_id FROM grac_practice.evidence_automation_binding WHERE binding_name = @name AND organization_id = @org;
    INSERT #r SELECT N'T01', N'create Webhook source', CASE WHEN @b IS NOT NULL THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'binding ', @b);
END TRY BEGIN CATCH INSERT #r VALUES (N'T01', N'create Webhook source', N'FAIL', ERROR_MESSAGE()); GOTO done; END CATCH

-- T02 token
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_binding_token_set @organization_id = @org, @binding_id = @b,
         @token_hash = @hash, @token_hint = N'TEST', @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
    CREATE TABLE #tok (BindingId BIGINT, OrganizationId BIGINT, BindingCode NVARCHAR(40), Channel NVARCHAR(20), Status NVARCHAR(20));
    INSERT #tok EXEC grac_practice.sp_evidence_automation_binding_resolve_token @token_hash = @hash;
    INSERT #r SELECT N'T02', N'token stored as hash and resolves to the source',
           CASE WHEN EXISTS (SELECT 1 FROM #tok WHERE BindingId = @b)
                 AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding WHERE binding_id = @b AND CAST(token_hash AS NVARCHAR(MAX)) LIKE N'%ZZ530%')
                THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T02', N'token', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T03 ingest
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @external_event_id = @t1,
         @period_to = @today, @result = N'passed', @metric_value = N'0 failed jobs', @summary = N'test',
         @file_name = N'zz530-report.txt', @content_type = N'text/plain', @file_data = @file;
    SELECT @e1 = event_id, @item1 = evidence_item_id FROM grac_practice.evidence_automation_event WHERE binding_id = @b AND external_event_id = @t1;
    INSERT #r SELECT N'T03', N'ingest -> Proposed event + Evidence Center item (owner, tags, validity, result normalised)',
           CASE WHEN e.status = N'Proposed' AND e.result = N'Pass' AND i.owner_employee_id = @owner AND i.tags LIKE N'automated,eab-%'
                 AND i.valid_from = @today AND i.valid_to = DATEADD(DAY, 30, @today) AND i.status = N'Active'
                 AND f.file_sha256 = HASHBYTES('SHA2_256', @file) AND b.last_result = N'Pass' AND b.last_period_to = @today
                THEN N'PASS' ELSE N'FAIL' END,
           CONCAT(N'event ', @e1, N', item ', @item1, N' "', i.evidence_title, N'"')
    FROM grac_practice.evidence_automation_event e
    JOIN grac_practice.evidence_item i ON i.evidence_item_id = e.evidence_item_id
    JOIN grac_practice.evidence_item_file f ON f.evidence_file_id = e.evidence_file_id
    JOIN grac_practice.evidence_automation_binding b ON b.binding_id = e.binding_id
    WHERE e.event_id = @e1;
    IF @e1 IS NULL INSERT #r VALUES (N'T03', N'ingest', N'FAIL', N'no event row');
END TRY BEGIN CATCH INSERT #r VALUES (N'T03', N'ingest', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T04 idempotent
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @external_event_id = @t1,
         @result = N'Pass', @file_name = N'again.txt', @file_data = @file;
    SELECT @n = COUNT(*) FROM grac_practice.evidence_automation_event WHERE binding_id = @b;
    INSERT #r SELECT N'T04', N'same eventId again -> still one event', CASE WHEN @n = 1 THEN N'PASS' ELSE N'FAIL' END, CONCAT(@n, N' event(s)');
END TRY BEGIN CATCH INSERT #r VALUES (N'T04', N'idempotency', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T05-T07 refusals
SET @err = NULL; BEGIN TRY EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @result = N'maybe', @file_name = N'x.txt', @file_data = @file; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r SELECT N'T05', N'invalid result refused', CASE WHEN @err = 58418 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
SET @err = NULL; DECLARE @future DATE = DATEADD(DAY, 5, @today);
BEGIN TRY EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @period_to = @future, @file_name = N'x.txt', @file_data = @file; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r SELECT N'T06', N'future period refused', CASE WHEN @err = 58417 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
SET @err = NULL; BEGIN TRY EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'FileDrop', @file_name = N'x.txt', @file_data = @file; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT #r SELECT N'T07', N'wrong channel refused', CASE WHEN @err = 58425 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);

-- T08 pause / resume
SET @err = NULL;
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_binding_status @organization_id = @org, @binding_id = @b, @action = N'Pause', @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
    BEGIN TRY EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @file_name = N'x.txt', @file_data = @file; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    EXEC grac_practice.sp_evidence_automation_binding_status @organization_id = @org, @binding_id = @b, @action = N'Resume', @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
    INSERT #r SELECT N'T08', N'paused source refuses (58415), resume re-activates',
           CASE WHEN @err = 58415 AND EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding WHERE binding_id = @b AND status = N'Active') THEN N'PASS' ELSE N'FAIL' END,
           CONCAT(N'error ', @err);
END TRY BEGIN CATCH INSERT #r VALUES (N'T08', N'pause / resume', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T09 file drop source + folder validation
SET @err = NULL;
BEGIN TRY EXEC grac_practice.sp_evidence_automation_binding_save @organization_id = @org, @binding_name = N'ZZ-530-TEST bad folder',
     @practice_instance_obligation_id = @pio, @channel = N'FileDrop', @drop_folder = N'../escape', @caller_employee_id = @owner, @caller_is_admin = 1;
END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_binding_save @organization_id = @org, @binding_name = N'ZZ-530-TEST filedrop',
         @practice_instance_obligation_id = @pio, @channel = N'FileDrop', @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
    SELECT @fb = binding_id FROM grac_practice.evidence_automation_binding WHERE binding_name = N'ZZ-530-TEST filedrop' AND organization_id = @org;
    INSERT #r SELECT N'T09', N'"../" folder refused (58410); file drop source defaults its folder to its code',
           CASE WHEN @err = 58410 AND EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding WHERE binding_id = @fb AND drop_folder = binding_code) THEN N'PASS' ELSE N'FAIL' END,
           CONCAT(N'error ', @err);
END TRY BEGIN CATCH INSERT #r VALUES (N'T09', N'file drop source', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T10 targets
BEGIN TRY
    CREATE TABLE #tg (TargetType NVARCHAR(40), TargetId BIGINT, TargetLabel NVARCHAR(600), PeriodDate DATE, NotLinkableReason NVARCHAR(200), Suggested BIT);
    INSERT #tg EXEC grac_practice.sp_evidence_automation_event_targets @organization_id = @org, @event_id = @e1, @caller_employee_id = @owner, @caller_is_admin = 1;
    SELECT @n = COUNT(*) FROM #tg;
    INSERT #r SELECT N'T10', N'targets procedure runs', N'PASS', CONCAT(@n, N' target(s) offered (open scheduled tasks / one-time evidence of this obligation)');
END TRY BEGIN CATCH INSERT #r VALUES (N'T10', N'targets', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T11 event list
BEGIN TRY
    CREATE TABLE #ev (EventId BIGINT, BindingId BIGINT, BindingName NVARCHAR(200), BindingCode NVARCHAR(40), Independence NVARCHAR(20), Channel NVARCHAR(20),
        ReceivedDt DATETIME2, PeriodFrom DATE, PeriodTo DATE, Result NVARCHAR(20), MetricValue NVARCHAR(200), Summary NVARCHAR(2000), SourceSystem NVARCHAR(200),
        SourceFileName NVARCHAR(500), EvidenceItemId BIGINT, EvidenceFileId BIGINT, EvidenceTitle NVARCHAR(300), VersionNo INT, Status NVARCHAR(20),
        DecisionTargetType NVARCHAR(40), DecisionTargetId BIGINT, DecidedBy NVARCHAR(100), DecidedDt DATETIME2, DecisionNote NVARCHAR(1000),
        PracticeInstanceId BIGINT, InstanceName NVARCHAR(300), ObligationName NVARCHAR(500), CanDecide BIT, TotalRows INT);
    INSERT #ev EXEC grac_practice.sp_evidence_automation_event_list @organization_id = @org, @binding_id = @b, @status = N'Proposed', @caller_employee_id = @owner, @caller_is_admin = 0;
    INSERT #r SELECT N'T11', N'owner sees the waiting event (not as admin)', CASE WHEN EXISTS (SELECT 1 FROM #ev WHERE EventId = @e1 AND CanDecide = 1) THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T11', N'event list', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T12 accept, keep only
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_event_accept @organization_id = @org, @event_id = @e1, @target_type = N'None', @decision_note = N'test', @caller_employee_id = @owner, @caller_is_admin = 0, @actor = N'test-530';
    INSERT #r SELECT N'T12', N'accept (keep in Evidence Center only) -> Accepted, no link',
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_automation_event WHERE event_id = @e1 AND status = N'Accepted' AND evidence_link_id IS NULL)
                 AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link WHERE evidence_item_id = @item1) THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T12', N'accept', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T13 / T14 reject
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @b, @channel = N'Webhook', @result = N'Fail', @file_name = N'zz530-second.txt', @file_data = 0x5A5A353330;
    SELECT TOP 1 @e2 = event_id, @item2 = evidence_item_id FROM grac_practice.evidence_automation_event WHERE binding_id = @b ORDER BY event_id DESC;
    SET @err = NULL;
    BEGIN TRY EXEC grac_practice.sp_evidence_automation_event_reject @organization_id = @org, @event_id = @e2, @decision_note = N'', @caller_employee_id = @owner, @caller_is_admin = 0; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT #r SELECT N'T13', N'reject without a reason refused', CASE WHEN @err = 58423 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
    EXEC grac_practice.sp_evidence_automation_event_reject @organization_id = @org, @event_id = @e2, @decision_note = N'test reject', @caller_employee_id = @owner, @caller_is_admin = 0, @actor = N'test-530';
    INSERT #r SELECT N'T14', N'reject -> Rejected, its unused item Retired',
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_automation_event WHERE event_id = @e2 AND status = N'Rejected')
                 AND EXISTS (SELECT 1 FROM grac_practice.evidence_item WHERE evidence_item_id = @item2 AND status = N'Retired') THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T14', N'reject', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T15 / T16 overdue notice (test-only backdating of this source)
BEGIN TRY
    UPDATE grac_practice.evidence_automation_binding
       SET expected_cadence = N'Daily', grace_days = 0, active_from = DATEADD(DAY, -5, @today), last_period_to = DATEADD(DAY, -5, @today)
     WHERE binding_id = @b;
    EXEC grac_practice.sp_evidence_automation_missing_sweep @organization_id = @org;
    SELECT @n = COUNT(*) FROM grac_practice.evidence_automation_notice WHERE binding_id = @b AND recipient_employee_id = @owner AND due_period_end = DATEADD(DAY, -1, @today);
    INSERT #r SELECT N'T15', N'nothing for 5 days (daily, 0 grace) -> one notice to the owner for yesterday', CASE WHEN @n = 1 THEN N'PASS' ELSE N'FAIL' END, CONCAT(@n, N' notice(s)');
    EXEC grac_practice.sp_evidence_automation_missing_sweep @organization_id = @org;
    SELECT @n = COUNT(*) FROM grac_practice.evidence_automation_notice WHERE binding_id = @b;
    INSERT #r SELECT N'T16', N'second sweep raises no duplicate', CASE WHEN @n = 1 THEN N'PASS' ELSE N'FAIL' END, CONCAT(@n, N' notice(s) in total');
END TRY BEGIN CATCH INSERT #r VALUES (N'T15', N'missing sweep', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T17 list health
BEGIN TRY
    CREATE TABLE #bl (BindingId BIGINT, BindingCode NVARCHAR(40), BindingName NVARCHAR(200), Channel NVARCHAR(20), SourceSystem NVARCHAR(200), Independence NVARCHAR(20),
        ExpectedCadence NVARCHAR(20), Status NVARCHAR(20), Health NVARCHAR(20), LastReceivedDt DATETIME2, LastPeriodTo DATE, LastResult NVARCHAR(20), LastError NVARCHAR(1000),
        LastErrorDt DATETIME2, MissedPeriodEnd DATE, NextPeriodEnd DATE, ProposedCount INT, OwnerEmployeeId BIGINT, OwnerName NVARCHAR(300), PracticeInstanceId BIGINT,
        InstanceCode NVARCHAR(100), InstanceName NVARCHAR(300), PracticeInstanceObligationId BIGINT, ObligationName NVARCHAR(500), CanEdit BIT, TotalRows INT);
    INSERT #bl EXEC grac_practice.sp_evidence_automation_binding_list @organization_id = @org, @search = N'ZZ-530-TEST', @caller_employee_id = @owner, @caller_is_admin = 0, @page_size = 50;
    INSERT #r SELECT N'T17', N'sources list: Overdue, missing yesterday', CASE WHEN EXISTS (SELECT 1 FROM #bl WHERE BindingId = @b AND Health = N'Overdue' AND MissedPeriodEnd = DATEADD(DAY, -1, @today)) THEN N'PASS' ELSE N'FAIL' END,
           (SELECT TOP 1 CONCAT(Health, N' / ', MissedPeriodEnd) FROM #bl WHERE BindingId = @b);
END TRY BEGIN CATCH INSERT #r VALUES (N'T17', N'binding list', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T18 rights
IF @other IS NULL
    INSERT #r VALUES (N'T18', N'non-owner cannot change the source', N'SKIP', N'no second active employee in this organization');
ELSE
BEGIN
    SET @err = NULL;
    BEGIN TRY EXEC grac_practice.sp_evidence_automation_binding_status @organization_id = @org, @binding_id = @b, @action = N'Pause', @caller_employee_id = @other, @caller_is_admin = 0; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT #r SELECT N'T18', N'non-owner, non-admin cannot change the source', CASE WHEN @err = 58402 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
END

-- T19 notices
BEGIN TRY
    EXEC grac_practice.sp_evidence_automation_notice_mark @recipient_employee_id = @owner, @organization_id = @org;
    INSERT #r SELECT N'T19', N'mark read', CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.evidence_automation_notice WHERE binding_id = @b AND read_dt IS NULL AND recipient_employee_id = @owner) THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T19', N'notices', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T20 existing procedures untouched
INSERT #r SELECT N'T20', N'existing Evidence Center / task link procedures not modified by 530',
       CASE WHEN MAX(o.modify_date) < (SELECT create_date FROM sys.objects WHERE object_id = OBJECT_ID('grac_practice.sp_evidence_automation_ingest'))
            THEN N'PASS' ELSE N'CHECK' END,
       CONCAT(N'latest change ', CONVERT(NVARCHAR(30), MAX(o.modify_date), 120))
FROM sys.objects o
WHERE o.object_id IN (OBJECT_ID('grac_practice.sp_evidence_item_store'), OBJECT_ID('grac_practice.sp_evidence_link_add'),
                      OBJECT_ID('grac_practice.sp_task_evidence_link_add'), OBJECT_ID('grac_practice.sp_evidence_center_list'),
                      OBJECT_ID('grac_practice.sp_evidence_center_get'), OBJECT_ID('grac_practice.sp_evidence_expiry_sweep'));

-- T21 the item is an ordinary Evidence Center item
BEGIN TRY
    SELECT @n = COUNT(*) FROM grac_practice.evidence_item WHERE evidence_item_id = @item1 AND organization_id = @org AND status = N'Active';
    INSERT #r SELECT N'T21', N'received item is an ordinary active Evidence Center item', CASE WHEN @n = 1 THEN N'PASS' ELSE N'FAIL' END, NULL;
END TRY BEGIN CATCH INSERT #r VALUES (N'T21', N'evidence center', N'FAIL', ERROR_MESSAGE()); END CATCH

-- T22-T24 (531) Email channel: allowed senders
IF COL_LENGTH('grac_practice.evidence_automation_binding','allowed_senders') IS NULL
    INSERT #r VALUES (N'T22', N'email channel', N'SKIP', N'531 not run');
ELSE
BEGIN
    DECLARE @eb BIGINT;
    SET @err = NULL;
    BEGIN TRY EXEC grac_practice.sp_evidence_automation_binding_save @organization_id = @org, @binding_name = N'ZZ-530-TEST email bad',
         @practice_instance_obligation_id = @pio, @channel = N'Email', @allowed_senders = N'reports@x.com, example.com',
         @caller_employee_id = @owner, @caller_is_admin = 1;
    END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT #r SELECT N'T22', N'email source: sender entry without @ refused (58427)', CASE WHEN @err = 58427 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
    BEGIN TRY
        EXEC grac_practice.sp_evidence_automation_binding_save @organization_id = @org, @binding_name = N'ZZ-530-TEST email',
             @practice_instance_obligation_id = @pio, @channel = N'Email', @allowed_senders = N'Reports@Veeam.local; @backup-vendor.com',
             @caller_employee_id = @owner, @caller_is_admin = 1, @actor = N'test-530';
        SELECT @eb = binding_id FROM grac_practice.evidence_automation_binding WHERE binding_name = N'ZZ-530-TEST email' AND organization_id = @org;
        EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @eb, @channel = N'Email', @external_event_id = N'mail:zz530-1',
             @result = N'Pass', @file_name = N'zz530-mail.eml', @file_data = @file, @sender_address = N'noreply@BACKUP-vendor.com';
        INSERT #r SELECT N'T23', N'email from an allowed domain is received (list normalised)',
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_automation_event WHERE binding_id = @eb AND channel = N'Email')
                     AND EXISTS (SELECT 1 FROM grac_practice.evidence_automation_binding WHERE binding_id = @eb AND allowed_senders = N',reports@veeam.local,@backup-vendor.com,')
                    THEN N'PASS' ELSE N'FAIL' END, NULL;
    END TRY BEGIN CATCH INSERT #r VALUES (N'T23', N'email receive', N'FAIL', ERROR_MESSAGE()); END CATCH
    SET @err = NULL;
    BEGIN TRY EXEC grac_practice.sp_evidence_automation_ingest @binding_id = @eb, @channel = N'Email', @result = N'Pass',
         @file_name = N'x.eml', @file_data = @file, @sender_address = N'attacker@evil.com'; END TRY BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT #r SELECT N'T24', N'email from a sender not on the list refused (58426)', CASE WHEN @err = 58426 THEN N'PASS' ELSE N'FAIL' END, CONCAT(N'error ', @err);
END

done:
SELECT test AS Test, what AS [What], result AS Result, detail AS Detail FROM #r ORDER BY id;
SELECT SUM(CASE WHEN result = N'PASS' THEN 1 ELSE 0 END) AS Passed,
       SUM(CASE WHEN result = N'FAIL' THEN 1 ELSE 0 END) AS Failed FROM #r;
GO

-- =====================================================================
-- Cleanup -- everything the test created (marker 'ZZ-530-TEST'). Runs even
-- if a test above failed.
-- =====================================================================
SET NOEXEC OFF;
GO
IF OBJECT_ID('grac_practice.evidence_automation_binding','U') IS NOT NULL
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @bids TABLE (binding_id BIGINT PRIMARY KEY);
    INSERT @bids SELECT binding_id FROM grac_practice.evidence_automation_binding WHERE binding_name LIKE N'ZZ-530-TEST%';
    DECLARE @items TABLE (evidence_item_id BIGINT PRIMARY KEY);
    INSERT @items SELECT DISTINCT evidence_item_id FROM grac_practice.evidence_automation_event WHERE binding_id IN (SELECT binding_id FROM @bids);
    DECLARE @events TABLE (event_id BIGINT PRIMARY KEY);
    INSERT @events SELECT event_id FROM grac_practice.evidence_automation_event WHERE binding_id IN (SELECT binding_id FROM @bids);

    DELETE FROM grac_practice.evidence_automation_notice WHERE binding_id IN (SELECT binding_id FROM @bids);
    DELETE FROM grac_practice.evidence_automation_event  WHERE binding_id IN (SELECT binding_id FROM @bids);
    DELETE FROM grac_practice.evidence_link              WHERE evidence_item_id IN (SELECT evidence_item_id FROM @items);
    DELETE FROM grac_practice.practice_audit_trace
     WHERE (entity_type = N'evidence-item-file' AND entity_id IN (SELECT evidence_file_id FROM grac_practice.evidence_item_file WHERE evidence_item_id IN (SELECT evidence_item_id FROM @items)))
        OR (entity_type = N'evidence-item' AND entity_id IN (SELECT evidence_item_id FROM @items))
        OR (entity_type = N'evidence-automation-event' AND entity_id IN (SELECT event_id FROM @events))
        OR (entity_type = N'evidence-automation-binding' AND entity_id IN (SELECT binding_id FROM @bids));
    DELETE FROM grac_practice.evidence_item_file WHERE evidence_item_id IN (SELECT evidence_item_id FROM @items);
    DELETE FROM grac_practice.evidence_item      WHERE evidence_item_id IN (SELECT evidence_item_id FROM @items);
    DELETE FROM grac_practice.evidence_automation_binding WHERE binding_id IN (SELECT binding_id FROM @bids);
    COMMIT;
    PRINT 'test_530 cleanup: removed ' + CAST((SELECT COUNT(*) FROM @bids) AS NVARCHAR(10)) + ' test source(s) and their events, notices and Evidence Center items.';
END
GO
