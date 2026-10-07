-- =====================================================================
-- 17  Regression tests -- Asset & Contract reports, exports, schedules,
--     distribution and retention (migrations 452 / 453; Phase 9)
--
-- Calls the procedures the API calls, with the permission inputs the Web
-- tier would stamp, and checks the outcome or the error number of each
-- rule: report permission (screen), availability, unknown report,
-- filters, organization settings (disabled, classification, export
-- policy), schedule validation, recipient checks at delivery time,
-- delivered-file storage, download checks and export record, retention.
--
-- WRITES TEST DATA and removes it at the end (schedules, deliveries,
-- export rows and organization report settings it created, audit rows
-- written by the test actor). Organization settings that existed before
-- are restored. Run on UAT, never on production: set @confirm = 1.
--
-- Data-dependent tests need, in the organization: an active employee with
-- VIEW on Asset Reports and Asset Register (the "permitted" recipient) and
-- one without Asset Reports VIEW (the "refused" recipient). Without them
-- those tests report SKIPPED.
--
-- Output: one row per test -- PASS / FAIL / SKIPPED, expected, actual.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @confirm BIT = 0;                  -- <<< 1 to run (writes and removes test data)
DECLARE @organization_id BIGINT = NULL;    -- <<< NULL = the first organization with assets
IF @confirm = 0
BEGIN
    RAISERROR('17: set @confirm = 1 to run the regression tests (UAT only).', 16, 1);
    RETURN;
END
IF OBJECT_ID('grac_practice.sp_asset_report_delivery_start','P') IS NULL
BEGIN
    RAISERROR('17: run 452 and 453 first.', 16, 1);
    RETURN;
END

DECLARE @actor NVARCHAR(100) = N'uat-test-17';
DECLARE @org BIGINT = ISNULL(@organization_id, (SELECT TOP (1) organization_id FROM grac_practice.organization_dependency_asset ORDER BY organization_id));
DECLARE @all NVARCHAR(2000) = (SELECT STRING_AGG(v.view_area, N',') FROM (SELECT DISTINCT view_area FROM grac_practice.asset_report_definition) v);
DECLARE @t TABLE (seq INT IDENTITY(1,1), test_id NVARCHAR(10), test_name NVARCHAR(300), expected NVARCHAR(100), actual NVARCHAR(400),
                  result NVARCHAR(10));
DECLARE @err INT, @msg NVARCHAR(4000), @n INT;

-- Recipients for the distribution tests (the 453 permission rule).
DECLARE @emp_ok BIGINT = (SELECT TOP (1) e.employee_id FROM grac_practice.organization_employee e
                           WHERE e.organization_id = @org AND e.status = N'Active'
                             AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_in_org(@org, e.employee_id))
                             AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_access(e.employee_id) a
                                          WHERE a.MenuKey = N'asset-reports' AND a.CanView = 1)
                             AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_access(e.employee_id) a
                                          WHERE a.MenuKey = N'asset-register' AND a.CanView = 1)
                           ORDER BY e.employee_id);
DECLARE @emp_no BIGINT = (SELECT TOP (1) e.employee_id FROM grac_practice.organization_employee e
                           WHERE e.organization_id = @org AND e.status = N'Active'
                             AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_in_org(@org, e.employee_id))
                             AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_access(e.employee_id) a
                                              WHERE a.MenuKey = N'asset-reports' AND a.CanView = 1)
                           ORDER BY e.employee_id);
SELECT @org AS OrganizationId, @emp_ok AS PermittedEmployeeId, @emp_no AS RefusedEmployeeId;

-- Organization settings that exist before the tests (restored at the end).
DECLARE @saved TABLE (report_code NVARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, is_enabled BIT, classification NVARCHAR(20) COLLATE DATABASE_DEFAULT,
                      export_policy NVARCHAR(10) COLLATE DATABASE_DEFAULT);
INSERT @saved SELECT report_code, is_enabled, classification, export_policy FROM grac_practice.asset_report_org_setting
 WHERE organization_id = @org AND report_code IN (N'ASSET_REGISTER', N'CON_CONTACTS');

-- ---------------------------------------------------------------- report runs (452)
BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @page_number = 1, @page_size = 1;
    INSERT @t VALUES (N'T01', N'Run a report whose screen is allowed', N'rows', N'rows', N'PASS');
END TRY
BEGIN CATCH
    INSERT @t VALUES (N'T01', N'Run a report whose screen is allowed', N'rows', CONCAT(ERROR_NUMBER(), N' ', ERROR_MESSAGE()), N'FAIL');
END CATCH

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = N'asset-contracts';
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T02', N'Report refused without VIEW on its screen', N'53103', @err, CASE WHEN @err = 53103 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'CON_VERSION_COMPARE', @allowed_areas = @all;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T03', N'Not-available report cannot be run', N'53102', @err, CASE WHEN @err = 53102 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'NO_SUCH_REPORT', @allowed_areas = @all;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T04', N'Unknown report', N'53101', @err, CASE WHEN @err = 53101 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @status = N'NOT_A_STATUS';
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T05', N'Status outside the report options', N'53106', @err, CASE WHEN @err = 53106 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_MOVEMENT', @allowed_areas = @all,
         @date_from = '20261031', @date_to = '20261001';
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T06', N'From date after to date', N'53106', @err, CASE WHEN @err = 53106 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'CON_EXPIRY', @allowed_areas = @all, @days = 0;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T07', N'Days outside 1-3650', N'53106', @err, CASE WHEN @err = 53106 THEN N'PASS' ELSE N'FAIL' END);

-- ---------------------------------------------------------------- organization settings (452)
BEGIN TRY
    EXEC grac_practice.sp_asset_report_org_setting_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @is_enabled = 0, @actor = @actor;
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T08', N'Disabled report cannot be run', N'53104', @err, CASE WHEN @err = 53104 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_org_setting_save @organization_id = @org, @report_code = N'CON_CONTACTS', @allowed_areas = @all,
         @is_enabled = 1, @classification = N'INTERNAL', @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T09', N'Classification below the default refused', N'53108', @err, CASE WHEN @err = 53108 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_org_setting_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @is_enabled = 1, @export_policy = N'APPROVER', @actor = @actor;
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @can_approve = 0, @for_export = 1;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T10', N'Approver policy: export without Asset Reports APPROVE refused', N'53105', @err,
                  CASE WHEN @err = 53105 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_run @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @can_approve = 1, @for_export = 1, @search = N'zz-no-asset-matches-this-zz';
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T11', N'Approver policy: export with APPROVE allowed', N'0', @err, CASE WHEN @err = 0 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_org_setting_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
         @export_policy = N'SOMETIMES', @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T12', N'Unknown export policy refused', N'53109', @err, CASE WHEN @err = 53109 THEN N'PASS' ELSE N'FAIL' END);

-- Back to the default for the schedule tests (restored to the saved state at the end).
EXEC grac_practice.sp_asset_report_org_setting_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @allowed_areas = @all,
     @is_enabled = 1, @export_policy = NULL, @actor = @actor;

-- ---------------------------------------------------------------- schedules (453)
DECLARE @rcp NVARCHAR(MAX) = (SELECT kind, id FROM (VALUES (N'EMPLOYEE', @emp_ok), (N'EMPLOYEE', @emp_no)) v(kind, id)
                               WHERE id IS NOT NULL FOR JSON PATH);
DECLARE @sch BIGINT;

BEGIN TRY
    EXEC grac_practice.sp_asset_report_schedule_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @schedule_name = N'UAT test 17',
         @frequency = N'DAILY', @recipients_json = N'[]', @allowed_areas = @all, @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T13', N'Schedule without recipients refused', N'53125', @err, CASE WHEN @err = 53125 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_schedule_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @schedule_name = N'UAT test 17',
         @frequency = N'WEEKLY', @recipients_json = @rcp, @allowed_areas = @all, @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T14', N'Weekly schedule without a weekday refused', N'53124', @err, CASE WHEN @err = 53124 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_schedule_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @schedule_name = N'UAT test 17',
         @frequency = N'MONTHLY', @day_of_month = 29, @recipients_json = @rcp, @allowed_areas = @all, @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T15', N'Monthly schedule on day 29 refused (1-28)', N'53124', @err, CASE WHEN @err = 53124 THEN N'PASS' ELSE N'FAIL' END);

BEGIN TRY
    EXEC grac_practice.sp_asset_report_schedule_save @organization_id = @org, @report_code = N'ASSET_REGISTER', @schedule_name = N'UAT test 17',
         @frequency = N'DAILY', @recipients_json = @rcp, @allowed_areas = N'asset-contracts', @actor = @actor;
    SET @err = 0;
END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
INSERT @t VALUES (N'T16', N'Scheduling a report whose screen is not allowed refused', N'53123', @err,
                  CASE WHEN @err = 53123 THEN N'PASS' ELSE N'FAIL' END);

IF @emp_ok IS NULL
BEGIN
    INSERT @t VALUES (N'T17', N'Schedule created, next run today (daily)', N'CREATED', N'no permitted employee', N'SKIPPED');
END
ELSE
BEGIN
    BEGIN TRY
        EXEC grac_practice.sp_asset_report_schedule_save @organization_id = @org, @report_code = N'ASSET_REGISTER',
             @schedule_name = N'UAT test 17', @frequency = N'DAILY', @retention_days = 30, @recipients_json = @rcp,
             @allowed_areas = @all, @actor = @actor;
        SET @sch = (SELECT MAX(schedule_id) FROM grac_practice.asset_report_schedule
                     WHERE organization_id = @org AND schedule_name = N'UAT test 17' AND entered_by = @actor);
        SET @n = (SELECT COUNT(*) FROM grac_practice.asset_report_schedule
                   WHERE schedule_id = @sch AND next_run_date = CAST(SYSUTCDATETIME() AS DATE));
        INSERT @t VALUES (N'T17', N'Schedule created, next run today (daily)', N'created, next run today',
                          CASE WHEN @sch IS NULL THEN N'not created' WHEN @n = 1 THEN N'created, next run today' ELSE N'created, other next run' END,
                          CASE WHEN @sch IS NOT NULL AND @n = 1 THEN N'PASS' ELSE N'FAIL' END);
    END TRY
    BEGIN CATCH
        INSERT @t VALUES (N'T17', N'Schedule created, next run today (daily)', N'CREATED', CONCAT(ERROR_NUMBER(), N' ', ERROR_MESSAGE()), N'FAIL');
    END CATCH
END

-- ---------------------------------------------------------------- delivery (453)
DECLARE @dlv BIGINT, @drcp_ok BIGINT, @drcp_no BIGINT;
IF @sch IS NULL
BEGIN
    INSERT @t VALUES (N'T18', N'Run now: permitted recipient pending, refused recipient skipped', N'PENDING / SKIPPED', N'no schedule', N'SKIPPED');
END
ELSE
BEGIN
    BEGIN TRY
        -- Its two result sets (the work, the deliveries started) are shown; the checks read the tables.
        EXEC grac_practice.sp_asset_report_delivery_start @organization_id = @org, @schedule_id = @sch,
             @allowed_areas = @all, @actor = @actor;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
    END CATCH
    SET @dlv = (SELECT TOP (1) delivery_id FROM grac_practice.asset_report_delivery WHERE schedule_id = @sch ORDER BY delivery_id DESC);
    SET @drcp_ok = (SELECT delivery_recipient_id FROM grac_practice.asset_report_delivery_recipient WHERE delivery_id = @dlv AND employee_id = @emp_ok);
    SET @drcp_no = (SELECT delivery_recipient_id FROM grac_practice.asset_report_delivery_recipient WHERE delivery_id = @dlv AND employee_id = @emp_no);
    INSERT @t VALUES (N'T18', N'Run now: permitted recipient pending, refused recipient skipped', N'PENDING / SKIPPED',
                      CONCAT(ISNULL(@msg + N' ', N''),
                             (SELECT status FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok), N' / ',
                             ISNULL((SELECT CONCAT(status, N': ', reason) FROM grac_practice.asset_report_delivery_recipient
                                      WHERE delivery_recipient_id = @drcp_no), N'(no refused employee)')),
                      CASE WHEN (SELECT status FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok) = N'PENDING'
                            AND (@emp_no IS NULL
                                 OR (SELECT status FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_no) = N'SKIPPED')
                           THEN N'PASS' ELSE N'FAIL' END);
END

-- The API stores what the report produced for the recipient; a small file stands in for it here.
IF @drcp_ok IS NULL
BEGIN
    INSERT @t VALUES (N'T19', N'Store delivered file; delivery status from recipients', N'DELIVERED', N'no pending recipient', N'SKIPPED');
END
ELSE
BEGIN
    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_store @delivery_recipient_id = @drcp_ok, @status = N'DELIVERED', @row_count = 1,
             @columns_json = N'["assetId","assetName"]', @rows_json = N'[{"assetId":1,"assetName":"UAT test 17"}]';
        INSERT @t VALUES (N'T19', N'Store delivered file; delivery status from recipients', N'DELIVERED + ' + CASE WHEN @drcp_no IS NULL THEN N'COMPLETED' ELSE N'PARTIAL' END,
                          CONCAT((SELECT status FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok), N' + ',
                                 (SELECT status FROM grac_practice.asset_report_delivery WHERE delivery_id = @dlv)),
                          CASE WHEN (SELECT status FROM grac_practice.asset_report_delivery WHERE delivery_id = @dlv)
                                    = CASE WHEN @drcp_no IS NULL THEN N'COMPLETED' ELSE N'PARTIAL' END THEN N'PASS' ELSE N'FAIL' END);
    END TRY
    BEGIN CATCH
        INSERT @t VALUES (N'T19', N'Store delivered file; delivery status from recipients', N'DELIVERED', CONCAT(ERROR_NUMBER(), N' ', ERROR_MESSAGE()), N'FAIL');
    END CATCH

    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_store @delivery_recipient_id = @drcp_ok, @status = N'FAILED', @reason = N'test';
        SET @err = 0;
    END TRY
    BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT @t VALUES (N'T20', N'A stored result cannot be overwritten', N'53126', @err, CASE WHEN @err = 53126 THEN N'PASS' ELSE N'FAIL' END);

    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_download @organization_id = @org, @delivery_recipient_id = @drcp_ok,
             @employee_id = @emp_no, @allowed_areas = @all, @actor = @actor;
        SET @err = 0;
    END TRY
    BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT @t VALUES (N'T21', N'Another employee cannot download the file', N'53126', @err, CASE WHEN @err = 53126 THEN N'PASS' ELSE N'FAIL' END);

    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_download @organization_id = @org, @delivery_recipient_id = @drcp_ok,
             @employee_id = @emp_ok, @allowed_areas = N'asset-contracts', @actor = @actor;
        SET @err = 0;
    END TRY
    BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT @t VALUES (N'T22', N'Recipient who lost VIEW on the screen cannot download', N'53129', @err, CASE WHEN @err = 53129 THEN N'PASS' ELSE N'FAIL' END);

    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_download @organization_id = @org, @delivery_recipient_id = @drcp_ok,
             @employee_id = @emp_ok, @allowed_areas = @all, @actor = @actor;
        INSERT @t VALUES (N'T23', N'Recipient downloads; recorded as an export with the delivery reference', N'export row, 1 download',
                          CONCAT((SELECT COUNT(*) FROM grac_practice.asset_report_export WHERE delivery_recipient_id = @drcp_ok), N' export row(s), ',
                                 (SELECT download_count FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok), N' download(s)'),
                          CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_report_export WHERE delivery_recipient_id = @drcp_ok) = 1
                                AND (SELECT download_count FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok) = 1
                               THEN N'PASS' ELSE N'FAIL' END);
    END TRY
    BEGIN CATCH
        INSERT @t VALUES (N'T23', N'Recipient downloads; recorded as an export with the delivery reference', N'export row', CONCAT(ERROR_NUMBER(), N' ', ERROR_MESSAGE()), N'FAIL');
    END CATCH

    -- Retention: age the file past its 30 days; the housekeeping of the next pass removes it. A Run now of the test
    -- schedule is used (the scheduled pass would also start the real schedules due today, which this script must not).
    UPDATE grac_practice.asset_report_delivery_recipient SET delivered_dt = DATEADD(DAY, -31, delivered_dt) WHERE delivery_recipient_id = @drcp_ok;
    EXEC grac_practice.sp_asset_report_delivery_start @organization_id = @org, @schedule_id = @sch, @allowed_areas = @all, @actor = @actor;
    BEGIN TRY
        EXEC grac_practice.sp_asset_report_delivery_download @organization_id = @org, @delivery_recipient_id = @drcp_ok,
             @employee_id = @emp_ok, @allowed_areas = @all, @actor = @actor;
        SET @err = 0;
    END TRY
    BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH
    INSERT @t VALUES (N'T24', N'File past its retention is removed; download refused', N'53127', @err,
                      CASE WHEN @err = 53127 AND (SELECT purged_dt FROM grac_practice.asset_report_delivery_recipient WHERE delivery_recipient_id = @drcp_ok) IS NOT NULL
                           THEN N'PASS' ELSE N'FAIL' END);
END

-- ---------------------------------------------------------------- clean-up
-- Only rows of the test schedule are removed (the housekeeping of T18 / T24 is legitimate and stays).
DELETE x FROM grac_practice.asset_report_export x
  JOIN grac_practice.asset_report_delivery_recipient r ON r.delivery_recipient_id = x.delivery_recipient_id
  JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
 WHERE d.schedule_id = @sch;
DELETE r FROM grac_practice.asset_report_delivery_recipient r
  JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
 WHERE d.schedule_id = @sch;
UPDATE grac_practice.asset_report_schedule SET last_delivery_id = NULL WHERE schedule_id = @sch;
DELETE FROM grac_practice.asset_report_delivery WHERE schedule_id = @sch;
DELETE FROM grac_practice.asset_report_schedule_recipient WHERE schedule_id = @sch;
DELETE FROM grac_practice.asset_report_schedule WHERE schedule_id = @sch;
DELETE FROM grac_practice.asset_report_org_setting
 WHERE organization_id = @org AND report_code IN (N'ASSET_REGISTER', N'CON_CONTACTS')
   AND report_code NOT IN (SELECT report_code FROM @saved);
UPDATE s SET is_enabled = v.is_enabled, classification = v.classification, export_policy = v.export_policy
  FROM grac_practice.asset_report_org_setting s
  JOIN @saved v ON v.report_code = s.report_code
 WHERE s.organization_id = @org;
DELETE FROM grac_practice.practice_audit_trace
 WHERE entered_by = @actor AND entity_type IN (N'asset-report-org-setting', N'asset-report-schedule');

SELECT test_id AS Test, test_name AS Scenario, expected AS Expected, actual AS Actual, result AS Result FROM @t ORDER BY seq;
SELECT SUM(CASE WHEN result = N'PASS' THEN 1 ELSE 0 END) AS Passed, SUM(CASE WHEN result = N'FAIL' THEN 1 ELSE 0 END) AS Failed,
       SUM(CASE WHEN result = N'SKIPPED' THEN 1 ELSE 0 END) AS Skipped
  FROM @t;
GO
