-- =====================================================================
-- 453  Asset report schedules, distribution and delivery retention
--      (Asset & Contract Management, Phase 8 increment 5b)
--
-- REQUEST
-- -------
--   BRD v1.7 13.4 ("governed report definitions with ... schedule,
--   retention and distribution rules"), 13.4.1 ("scheduled delivery shall
--   validate recipient authorization at delivery time and record
--   distribution results"; "exports shall record report / version,
--   filters, columns, user, tenant, generation time and classification";
--   "sensitive exports may require ... expiry or download restrictions").
--   Standing instruction: use the existing background worker
--   (TaskNotificationWorker). Plan: docs/asset-contract-management.md
--   (Phase 8.5b, D211-D224).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_report_schedule -- a report of the 452 catalogue with fixed
--      filters (a date window of the last N days for date-range reports),
--      frequency (daily, weekly on a weekday, monthly on a day 1-28), next
--      run date, active flag and how long delivered files are kept.
--   2. asset_report_schedule_recipient -- the distribution list: named
--      employees and organization roles (every active holder at delivery).
--   3. asset_report_delivery / _delivery_recipient -- one delivery per
--      run; per recipient DELIVERED, SKIPPED (with the reason the
--      authorization check gave) or FAILED, row count, the columns and
--      rows produced under that recipient (View Data Scope included),
--      downloads, and when the file was removed by retention.
--   4. asset_report_export.delivery_recipient_id -- a download of a
--      delivered file is recorded as an export like any other (452).
--   5. fn_asset_report_next_run, fn_asset_report_employee_access (the menu
--      permissions of an employee: primary role plus assigned roles, the
--      sign-in rule) and fn_asset_report_employee_in_org (sign-in rule).
--   6. Procedures: sp_asset_report_schedules, _schedule_save,
--      _delivery_start (claims due schedules or one schedule now, checks
--      every recipient, purges files past retention, returns the work),
--      _delivery_store, _deliveries, _delivery_recipients,
--      _my_deliveries, _delivery_download.
--   The rows are produced by the API (AssetConfigService.RunReport
--   DeliveriesAsync) through sp_asset_report_run, per recipient and under
--   the recipient own View Data Scope; TaskNotificationWorker runs it.
--
-- NOT DONE HERE: e-mail / Teams delivery (no dispatcher exists in the
--   codebase -- as 437 D57, delivery is in the application: Asset Reports
--   -> My deliveries); encrypted files; schedules run by SQL Agent alone
--   (the rows are produced in the API).
--
-- ERROR NUMBERS: 53120-53139
--   53120 organization not found        53121 schedule not found
--   53122 report cannot be scheduled (unknown, not available, disabled)
--   53123 no permission for the report screen
--   53124 schedule invalid (name, frequency, day, window, retention, filters)
--   53125 recipients invalid            53126 delivery not found / not yours
--   53127 file not available (not delivered or removed by retention)
--   53128 changed by someone else       53129 download not allowed now
--
-- ALSO EDITED: API (AssetConfig service / controller / models,
--   TaskNotificationWorker, appsettings), Web proxy, asset-reports.cshtml
--   / .js, docs. 452 objects are not re-issued.
-- DEPENDS ON: 452.
-- Rollback: 453_asset_report_schedules_rollback.sql (drops the 453 objects
--   and the export column; schedules, deliveries and their files are lost).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_report_run','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_report_export','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_report_effective') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
   OR OBJECT_ID('grac_practice.user_organization_map','U') IS NULL
   OR COL_LENGTH('grac_practice.menu_master', 'parent_menu_id') IS NULL
BEGIN
    RAISERROR('ABORT (453): run 452 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schedules and distribution lists
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_report_schedule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_schedule (
        schedule_id       BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arpt_sch PRIMARY KEY,
        organization_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_arpt_sch_org REFERENCES grac_practice.organization(organization_id),
        report_code       NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_arpt_sch_def REFERENCES grac_practice.asset_report_definition(report_code),
        schedule_name     NVARCHAR(160)  NOT NULL,
        search_text       NVARCHAR(200)  NULL,
        status_code       NVARCHAR(60)   NULL,
        asset_type_id     INT            NULL,
        days              INT            NULL,
        date_window_days  INT            NULL,       -- date-range reports: the last N days up to the run date
        frequency         NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_arpt_sch_freq CHECK (frequency IN (N'DAILY', N'WEEKLY', N'MONTHLY')),
        day_of_week       TINYINT        NULL        -- 1 Monday .. 7 Sunday (WEEKLY)
            CONSTRAINT ck_pm_arpt_sch_dow CHECK (day_of_week IS NULL OR day_of_week BETWEEN 1 AND 7),
        day_of_month      TINYINT        NULL        -- 1 .. 28 (MONTHLY)
            CONSTRAINT ck_pm_arpt_sch_dom CHECK (day_of_month IS NULL OR day_of_month BETWEEN 1 AND 28),
        retention_days    INT            NOT NULL CONSTRAINT df_pm_arpt_sch_ret DEFAULT 90
            CONSTRAINT ck_pm_arpt_sch_ret CHECK (retention_days BETWEEN 1 AND 3650),
        next_run_date     DATE           NULL,
        last_delivery_id  BIGINT         NULL,
        is_active         BIT            NOT NULL CONSTRAINT df_pm_arpt_sch_act DEFAULT 1,
        owner_employee_id BIGINT         NULL,
        entered_by        NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_arpt_sch_eby DEFAULT N'system',
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_arpt_sch_edt DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100)  NULL,
        updated_dt        DATETIME2      NULL,
        record_version    ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_arpt_sch_due ON grac_practice.asset_report_schedule(is_active, next_run_date);
    PRINT '453: asset_report_schedule created.';
END
GO

IF OBJECT_ID('grac_practice.asset_report_schedule_recipient','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_schedule_recipient (
        recipient_id   BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arpt_srcp PRIMARY KEY,
        schedule_id    BIGINT        NOT NULL
            CONSTRAINT fk_pm_arpt_srcp_sch REFERENCES grac_practice.asset_report_schedule(schedule_id),
        recipient_kind NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_arpt_srcp_kind CHECK (recipient_kind IN (N'EMPLOYEE', N'ROLE')),
        employee_id    BIGINT        NULL
            CONSTRAINT fk_pm_arpt_srcp_emp REFERENCES grac_practice.organization_employee(employee_id),
        role_id        BIGINT        NULL
            CONSTRAINT fk_pm_arpt_srcp_role REFERENCES grac_practice.organization_role(role_id),
        entered_by     NVARCHAR(100) NOT NULL CONSTRAINT df_pm_arpt_srcp_eby DEFAULT N'system',
        entered_dt     DATETIME2     NOT NULL CONSTRAINT df_pm_arpt_srcp_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_arpt_srcp_ref CHECK ((recipient_kind = N'EMPLOYEE' AND employee_id IS NOT NULL AND role_id IS NULL)
                                           OR (recipient_kind = N'ROLE' AND role_id IS NOT NULL AND employee_id IS NULL))
    );
    CREATE UNIQUE INDEX ux_pm_arpt_srcp ON grac_practice.asset_report_schedule_recipient(schedule_id, recipient_kind, employee_id, role_id);
    PRINT '453: asset_report_schedule_recipient created.';
END
GO

-- =====================================================================
-- 2. Deliveries and distribution results
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_report_delivery','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_delivery (
        delivery_id     BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arpt_dlv PRIMARY KEY,
        schedule_id     BIGINT         NOT NULL
            CONSTRAINT fk_pm_arpt_dlv_sch REFERENCES grac_practice.asset_report_schedule(schedule_id),
        organization_id BIGINT         NOT NULL,
        report_code     NVARCHAR(40)   NOT NULL,
        report_version  INT            NOT NULL,
        report_name     NVARCHAR(120)  NOT NULL,
        classification  NVARCHAR(20)   NOT NULL,
        filters_json    NVARCHAR(MAX)  NULL,      -- as recorded with an export (452)
        search_text     NVARCHAR(200)  NULL,      -- the filters the run used
        status_code     NVARCHAR(60)   NULL,
        asset_type_id   INT            NULL,
        date_from       DATE           NULL,
        date_to         DATE           NULL,
        days            INT            NULL,
        run_date        DATE           NOT NULL,
        trigger_code    NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_arpt_dlv_trg CHECK (trigger_code IN (N'SCHEDULED', N'MANUAL')),
        status          NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_arpt_dlv_status CHECK (status IN (N'RUNNING', N'COMPLETED', N'PARTIAL', N'FAILED', N'SKIPPED')),
        recipient_count INT            NOT NULL CONSTRAINT df_pm_arpt_dlv_rc DEFAULT 0,
        delivered_count INT            NOT NULL CONSTRAINT df_pm_arpt_dlv_dc DEFAULT 0,
        skipped_count   INT            NOT NULL CONSTRAINT df_pm_arpt_dlv_sc DEFAULT 0,
        failed_count    INT            NOT NULL CONSTRAINT df_pm_arpt_dlv_fc DEFAULT 0,
        retention_days  INT            NOT NULL,
        started_by      NVARCHAR(100)  NOT NULL,
        started_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_arpt_dlv_sdt DEFAULT SYSUTCDATETIME(),
        completed_dt    DATETIME2      NULL
    );
    -- One scheduled delivery per schedule and day (a second worker or pass claims nothing).
    CREATE UNIQUE INDEX ux_pm_arpt_dlv_day ON grac_practice.asset_report_delivery(schedule_id, run_date) WHERE trigger_code = N'SCHEDULED';
    CREATE INDEX ix_pm_arpt_dlv_org ON grac_practice.asset_report_delivery(organization_id, started_dt DESC);
    PRINT '453: asset_report_delivery created.';
END
GO

IF OBJECT_ID('grac_practice.asset_report_delivery_recipient','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_report_delivery_recipient (
        delivery_recipient_id BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arpt_drcp PRIMARY KEY,
        delivery_id           BIGINT         NOT NULL
            CONSTRAINT fk_pm_arpt_drcp_dlv REFERENCES grac_practice.asset_report_delivery(delivery_id),
        employee_id           BIGINT         NOT NULL,
        recipient_name        NVARCHAR(200)  NULL,
        via_role_name         NVARCHAR(200)  NULL,
        status                NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_arpt_drcp_status CHECK (status IN (N'PENDING', N'DELIVERED', N'SKIPPED', N'FAILED')),
        reason                NVARCHAR(1000) NULL,
        allowed_areas         NVARCHAR(2000) NULL,   -- the recipient report screens at delivery time
        can_approve           BIT            NOT NULL CONSTRAINT df_pm_arpt_drcp_appr DEFAULT 0,
        row_count             INT            NULL,
        columns_json          NVARCHAR(MAX)  NULL,
        rows_json             NVARCHAR(MAX)  NULL,
        delivered_dt          DATETIME2      NULL,
        first_downloaded_dt   DATETIME2      NULL,
        download_count        INT            NOT NULL CONSTRAINT df_pm_arpt_drcp_dl DEFAULT 0,
        purged_dt             DATETIME2      NULL,
        entered_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_arpt_drcp_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX ux_pm_arpt_drcp ON grac_practice.asset_report_delivery_recipient(delivery_id, employee_id);
    CREATE INDEX ix_pm_arpt_drcp_emp ON grac_practice.asset_report_delivery_recipient(employee_id, delivery_id DESC);
    PRINT '453: asset_report_delivery_recipient created.';
END
GO

IF COL_LENGTH('grac_practice.asset_report_export', 'delivery_recipient_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.asset_report_export ADD delivery_recipient_id BIGINT NULL
        CONSTRAINT fk_pm_arpt_exp_drcp REFERENCES grac_practice.asset_report_delivery_recipient(delivery_recipient_id);
    PRINT '453: asset_report_export.delivery_recipient_id added.';
END
GO

-- =====================================================================
-- 3. Functions
-- =====================================================================
-- First run date on or after @from: every day, a weekday (1 Monday ..
-- 7 Sunday; 1900-01-01 was a Monday, so no dependence on DATEFIRST) or a
-- day of the month (1-28, present in every month).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_next_run
(
    @frequency    NVARCHAR(10),
    @day_of_week  TINYINT,
    @day_of_month TINYINT,
    @from         DATE
)
RETURNS TABLE
AS
RETURN
    SELECT MIN(c.d) AS NextRunDate
      FROM (SELECT DATEADD(DAY, n.n, @from) AS d
              FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14), (15),
                           (16), (17), (18), (19), (20), (21), (22), (23), (24), (25), (26), (27), (28), (29), (30), (31)) n(n)) c
     WHERE @frequency = N'DAILY'
        OR (@frequency = N'WEEKLY' AND DATEDIFF(DAY, CAST('19000101' AS DATE), c.d) % 7 + 1 = @day_of_week)
        OR (@frequency = N'MONTHLY' AND DAY(c.d) = @day_of_month);
GO

-- An active employee who may act on the organization: the sign-in rule
-- (PracticeAuthenticationService) -- active record, and the organization
-- is the employee organization or mapped to the employee in
-- user_organization_map.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_employee_in_org (@organization_id BIGINT, @employee_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT e.employee_id AS EmployeeId, e.employee_name AS EmployeeName, e.email AS Email
      FROM grac_practice.organization_employee e
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
     WHERE e.employee_id = @employee_id AND e.status = N'Active'
       AND (rs.status_code = N'ACTIVE' OR rs.status_name = N'Active')
       AND (e.organization_id = @organization_id
            OR EXISTS (SELECT 1 FROM grac_practice.user_organization_map m
                        WHERE m.organization_id = @organization_id AND m.status = N'Active'
                          AND LOWER(m.user_email) IN (LOWER(e.email), LOWER(e.employee_code))));
GO

-- The menu permissions of an employee: the sign-in rule (primary role plus
-- every active assigned role; Active grants on Active menu rows).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_report_employee_access (@employee_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT m.menu_key AS MenuKey,
           CAST(MAX(CAST(p.can_view AS INT)) AS BIT) AS CanView,
           CAST(MAX(CAST(p.can_approve AS INT)) AS BIT) AS CanApprove
      FROM grac_practice.organization_role_menu_permission p
      JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id AND m.status = N'Active'
     WHERE p.status = N'Active'
       AND p.role_id IN (SELECT er.role_id FROM grac_practice.organization_employee_role er
                          WHERE er.employee_id = @employee_id AND er.status = N'Active'
                         UNION
                         SELECT e.role_id FROM grac_practice.organization_employee e
                          WHERE e.employee_id = @employee_id AND e.role_id IS NOT NULL)
     GROUP BY m.menu_key;
GO
PRINT '453: functions created.';
GO

-- =====================================================================
-- 4. Schedules: list and save
-- =====================================================================
-- 1. schedules of the reports the caller may view   2. recipients
-- 3. active employees of the organization          4. active roles
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_schedules
    @organization_id BIGINT,
    @allowed_areas   NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53120, 'Organization not found.', 1;
    DECLARE @areas NVARCHAR(2004) = N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',';

    SELECT s.schedule_id AS ScheduleId, s.schedule_name AS ScheduleName, s.report_code AS ReportCode, d.report_name AS ReportName,
           d.family_name AS FamilyName, s.search_text AS SearchText, s.status_code AS StatusCode, s.asset_type_id AS AssetTypeId,
           s.days AS Days, s.date_window_days AS DateWindowDays, s.frequency AS Frequency, s.day_of_week AS DayOfWeek,
           s.day_of_month AS DayOfMonth, s.retention_days AS RetentionDays, s.next_run_date AS NextRunDate, s.is_active AS IsActive,
           ow.employee_name AS OwnerName, ld.status AS LastStatus, ld.started_dt AS LastRunDt, ld.delivered_count AS LastDelivered,
           ld.skipped_count AS LastSkipped, ld.failed_count AS LastFailed, rc.names AS Recipients,
           CONVERT(BIGINT, s.record_version) AS RecordVersion
      FROM grac_practice.asset_report_schedule s
      JOIN grac_practice.asset_report_definition d ON d.report_code = s.report_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = s.owner_employee_id
      LEFT JOIN grac_practice.asset_report_delivery ld ON ld.delivery_id = s.last_delivery_id
     OUTER APPLY (SELECT STRING_AGG(CAST(CASE WHEN r.recipient_kind = N'ROLE' THEN CONCAT(rl.role_name, N' (role)')
                                              ELSE e.employee_name END AS NVARCHAR(MAX)), N'; ') AS names
                    FROM grac_practice.asset_report_schedule_recipient r
                    LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                    LEFT JOIN grac_practice.organization_role rl ON rl.role_id = r.role_id
                   WHERE r.schedule_id = s.schedule_id) rc
     WHERE s.organization_id = @organization_id AND CHARINDEX(N',' + d.view_area + N',', @areas) > 0
     ORDER BY s.is_active DESC, s.schedule_name, s.schedule_id;

    SELECT r.schedule_id AS ScheduleId, r.recipient_kind AS RecipientKind, r.employee_id AS EmployeeId, r.role_id AS RoleId,
           CASE WHEN r.recipient_kind = N'ROLE' THEN rl.role_name ELSE e.employee_name END AS Name
      FROM grac_practice.asset_report_schedule_recipient r
      JOIN grac_practice.asset_report_schedule s ON s.schedule_id = r.schedule_id AND s.organization_id = @organization_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
      LEFT JOIN grac_practice.organization_role rl ON rl.role_id = r.role_id
     ORDER BY r.schedule_id, r.recipient_kind, Name;

    SELECT e.employee_id AS EmployeeId, e.employee_name AS EmployeeName, e.email AS Email
      FROM grac_practice.organization_employee e
     WHERE e.organization_id = @organization_id AND e.status = N'Active'
     ORDER BY e.employee_name;

    SELECT r.role_id AS RoleId, r.role_name AS RoleName
      FROM grac_practice.organization_role r
     WHERE r.organization_id = @organization_id AND r.status = N'Active'
     ORDER BY r.role_name;
END
GO

-- New when @schedule_id is NULL. The report is fixed once saved. Filters
-- the report does not take are dropped; a status must be one of its
-- options (the sp_asset_report_run rule). Recipients: JSON array of
-- {"kind": "EMPLOYEE" | "ROLE", "id": n}; the list is replaced. A new
-- schedule, a changed frequency / day or a reactivation recomputes the
-- next run date from today.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_schedule_save
    @organization_id         BIGINT,
    @schedule_id             BIGINT         = NULL,
    @report_code             NVARCHAR(40)   = NULL,
    @schedule_name           NVARCHAR(160)  = NULL,
    @search                  NVARCHAR(200)  = NULL,
    @status                  NVARCHAR(60)   = NULL,
    @asset_type_id           INT            = NULL,
    @days                    INT            = NULL,
    @date_window_days        INT            = NULL,
    @frequency               NVARCHAR(10)   = NULL,
    @day_of_week             TINYINT        = NULL,
    @day_of_month            TINYINT        = NULL,
    @retention_days          INT            = NULL,
    @is_active               BIT            = 1,
    @recipients_json         NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @allowed_areas           NVARCHAR(2000) = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @actor_employee_id       BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @report_code = UPPER(NULLIF(LTRIM(RTRIM(@report_code)), N''));
    SET @schedule_name = NULLIF(LTRIM(RTRIM(@schedule_name)), N'');
    SET @frequency = UPPER(NULLIF(LTRIM(RTRIM(@frequency)), N''));
    SET @is_active = ISNULL(@is_active, 1);
    SET @retention_days = ISNULL(@retention_days, 90);
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53120, 'Organization not found.', 1;

    DECLARE @old_report NVARCHAR(40), @old_freq NVARCHAR(10), @old_dow TINYINT, @old_dom TINYINT, @old_active BIT,
            @old_next DATE, @old_version BIGINT;
    IF @schedule_id IS NOT NULL
    BEGIN
        SELECT @old_report = report_code, @old_freq = frequency, @old_dow = day_of_week, @old_dom = day_of_month,
               @old_active = is_active, @old_next = next_run_date, @old_version = CONVERT(BIGINT, record_version)
          FROM grac_practice.asset_report_schedule
         WHERE schedule_id = @schedule_id AND organization_id = @organization_id;
        IF @old_report IS NULL
            THROW 53121, 'Schedule not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @old_version
            THROW 53128, 'The schedule was changed by someone else; reload it.', 1;
        IF @report_code IS NOT NULL AND @report_code <> @old_report
            THROW 53124, 'The report of a schedule cannot be changed; create a new schedule.', 1;
        SET @report_code = @old_report;
    END

    DECLARE @area NVARCHAR(100), @available BIT, @keys NVARCHAR(204), @options NVARCHAR(1000), @default_days INT, @enabled BIT;
    SELECT @area = d.view_area, @available = d.is_available, @keys = N',' + d.filter_keys + N',', @options = d.status_options,
           @default_days = d.default_days, @enabled = e.IsEnabled
      FROM grac_practice.asset_report_definition d
      JOIN grac_practice.fn_asset_report_effective(@organization_id) e ON e.ReportCode = d.report_code
     WHERE d.report_code = @report_code AND d.is_active = 1;
    IF @area IS NULL OR @available = 0 OR @enabled = 0
        THROW 53122, 'The report is unknown, not available or disabled for the organization; it cannot be scheduled.', 1;
    IF CHARINDEX(N',' + @area + N',', N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',') = 0
        THROW 53123, 'You do not have permission to view the screen this report is based on.', 1;
    IF @schedule_name IS NULL OR LEN(@schedule_name) > 160
        THROW 53124, 'A schedule name is required (at most 160 characters).', 1;
    IF @frequency IS NULL OR @frequency NOT IN (N'DAILY', N'WEEKLY', N'MONTHLY')
       OR (@frequency = N'WEEKLY' AND (@day_of_week IS NULL OR @day_of_week NOT BETWEEN 1 AND 7))
       OR (@frequency = N'MONTHLY' AND (@day_of_month IS NULL OR @day_of_month NOT BETWEEN 1 AND 28))
        THROW 53124, 'Frequency must be DAILY, WEEKLY with a weekday (1 Monday - 7 Sunday) or MONTHLY with a day 1-28.', 1;
    IF @retention_days NOT BETWEEN 1 AND 3650
        THROW 53124, 'Delivered files are kept between 1 and 3650 days.', 1;
    SELECT @day_of_week = CASE WHEN @frequency = N'WEEKLY' THEN @day_of_week END,
           @day_of_month = CASE WHEN @frequency = N'MONTHLY' THEN @day_of_month END;

    -- Filters the report does not take are dropped (the run rule of 452).
    SET @search = CASE WHEN CHARINDEX(N',SEARCH,', @keys) > 0 THEN NULLIF(LTRIM(RTRIM(@search)), N'') END;
    SET @status = CASE WHEN CHARINDEX(N',STATUS,', @keys) > 0 THEN NULLIF(UPPER(LTRIM(RTRIM(@status))), N'') END;
    SET @asset_type_id = CASE WHEN CHARINDEX(N',ASSET_TYPE,', @keys) > 0 THEN @asset_type_id END;
    SET @days = CASE WHEN CHARINDEX(N',DAYS,', @keys) > 0 THEN ISNULL(@days, @default_days) END;
    SET @date_window_days = CASE WHEN CHARINDEX(N',DATE_RANGE,', @keys) > 0 THEN @date_window_days END;
    IF @status IS NOT NULL
       AND NOT ((@options = N'@ASSET_STATUS'
                 AND EXISTS (SELECT 1 FROM grac_practice.entity_status_master WHERE entity_type = N'Asset' AND status_code = @status))
                OR (@options <> N'@ASSET_STATUS' AND CHARINDEX(N'|' + @status + N'=', N'|' + @options) > 0))
        THROW 53124, 'Unknown status for this report.', 1;
    IF (@days IS NOT NULL AND @days NOT BETWEEN 1 AND 3650)
       OR (@date_window_days IS NOT NULL AND @date_window_days NOT BETWEEN 1 AND 3650)
        THROW 53124, 'Days and the date window must be between 1 and 3650.', 1;

    DECLARE @rcp TABLE (recipient_kind NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, ref_id BIGINT NOT NULL,
                        PRIMARY KEY (recipient_kind, ref_id));
    IF @recipients_json IS NULL OR ISJSON(@recipients_json) = 0
        THROW 53125, 'Recipients must be a JSON array of {kind, id}.', 1;
    INSERT @rcp (recipient_kind, ref_id)
    SELECT DISTINCT UPPER(j.kind), j.id
      FROM OPENJSON(@recipients_json) WITH (kind NVARCHAR(10) '$.kind', id BIGINT '$.id') j
     WHERE j.id IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @rcp)
        THROW 53125, 'Add at least one recipient (an employee or a role).', 1;
    IF EXISTS (SELECT 1 FROM @rcp r
                WHERE NOT (   (r.recipient_kind = N'EMPLOYEE'
                               AND EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                            WHERE e.employee_id = r.ref_id AND e.organization_id = @organization_id AND e.status = N'Active'))
                           OR (r.recipient_kind = N'ROLE'
                               AND EXISTS (SELECT 1 FROM grac_practice.organization_role rl
                                            WHERE rl.role_id = r.ref_id AND rl.organization_id = @organization_id AND rl.status = N'Active'))))
        THROW 53125, 'A recipient is not an active employee or role of the organization.', 1;

    DECLARE @next DATE = @old_next;
    IF @schedule_id IS NULL OR @frequency <> @old_freq OR ISNULL(@day_of_week, 0) <> ISNULL(@old_dow, 0)
       OR ISNULL(@day_of_month, 0) <> ISNULL(@old_dom, 0) OR (@is_active = 1 AND @old_active = 0)
        SET @next = (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(@frequency, @day_of_week, @day_of_month,
                                                                                  CAST(SYSUTCDATETIME() AS DATE)));

    DECLARE @before NVARCHAR(MAX) = (SELECT s.schedule_name AS scheduleName, s.search_text AS search, s.status_code AS status,
                                            s.asset_type_id AS assetTypeId, s.days, s.date_window_days AS dateWindowDays,
                                            s.frequency, s.day_of_week AS dayOfWeek, s.day_of_month AS dayOfMonth,
                                            s.retention_days AS retentionDays, s.is_active AS isActive,
                                            (SELECT r.recipient_kind AS kind, COALESCE(r.employee_id, r.role_id) AS id
                                               FROM grac_practice.asset_report_schedule_recipient r
                                              WHERE r.schedule_id = s.schedule_id FOR JSON PATH) AS recipients
                                       FROM grac_practice.asset_report_schedule s
                                      WHERE s.schedule_id = @schedule_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @result NVARCHAR(10) = CASE WHEN @schedule_id IS NULL THEN N'CREATED' ELSE N'SAVED' END;
    BEGIN TRAN;
    IF @schedule_id IS NULL
    BEGIN
        INSERT grac_practice.asset_report_schedule (organization_id, report_code, schedule_name, search_text, status_code, asset_type_id,
                                                    days, date_window_days, frequency, day_of_week, day_of_month, retention_days,
                                                    next_run_date, is_active, owner_employee_id, entered_by)
        VALUES (@organization_id, @report_code, @schedule_name, @search, @status, @asset_type_id, @days, @date_window_days,
                @frequency, @day_of_week, @day_of_month, @retention_days, @next, @is_active, @actor_employee_id, @actor);
        SET @schedule_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_report_schedule
           SET schedule_name = @schedule_name, search_text = @search, status_code = @status, asset_type_id = @asset_type_id,
               days = @days, date_window_days = @date_window_days, frequency = @frequency, day_of_week = @day_of_week,
               day_of_month = @day_of_month, retention_days = @retention_days, next_run_date = @next, is_active = @is_active,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE schedule_id = @schedule_id;
        DELETE FROM grac_practice.asset_report_schedule_recipient WHERE schedule_id = @schedule_id;
    END
    INSERT grac_practice.asset_report_schedule_recipient (schedule_id, recipient_kind, employee_id, role_id, entered_by)
    SELECT @schedule_id, r.recipient_kind, CASE WHEN r.recipient_kind = N'EMPLOYEE' THEN r.ref_id END,
           CASE WHEN r.recipient_kind = N'ROLE' THEN r.ref_id END, @actor
      FROM @rcp r;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-report-schedule', @schedule_id, @result, @before,
            (SELECT @report_code AS reportCode, @schedule_name AS scheduleName, @search AS search, @status AS status,
                    @asset_type_id AS assetTypeId, @days AS days, @date_window_days AS dateWindowDays, @frequency AS frequency,
                    @day_of_week AS dayOfWeek, @day_of_month AS dayOfMonth, @retention_days AS retentionDays,
                    @is_active AS isActive, JSON_QUERY(@recipients_json) AS recipients FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @schedule_id AS ScheduleId, @result AS Result;
END
GO
PRINT '453: schedule procedures created.';
GO

-- =====================================================================
-- 5. Deliveries: start, store, finish
-- =====================================================================
-- Status of a delivery from its recipients: RUNNING while any is pending;
-- COMPLETED (all delivered), PARTIAL (some delivered), FAILED (none
-- delivered, one failed), SKIPPED (nobody passed the checks).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_delivery_finish
    @delivery_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE d
       SET recipient_count = c.total, delivered_count = c.delivered, skipped_count = c.skipped, failed_count = c.failed,
           status = CASE WHEN c.pending > 0 THEN N'RUNNING'
                         WHEN c.delivered > 0 AND c.skipped + c.failed = 0 THEN N'COMPLETED'
                         WHEN c.delivered > 0 THEN N'PARTIAL'
                         WHEN c.failed > 0 THEN N'FAILED'
                         ELSE N'SKIPPED' END,
           completed_dt = CASE WHEN c.pending > 0 THEN NULL ELSE ISNULL(d.completed_dt, SYSUTCDATETIME()) END
      FROM grac_practice.asset_report_delivery d
     CROSS APPLY (SELECT COUNT(*) AS total,
                         ISNULL(SUM(CASE WHEN r.status = N'DELIVERED' THEN 1 ELSE 0 END), 0) AS delivered,
                         ISNULL(SUM(CASE WHEN r.status = N'SKIPPED' THEN 1 ELSE 0 END), 0) AS skipped,
                         ISNULL(SUM(CASE WHEN r.status = N'FAILED' THEN 1 ELSE 0 END), 0) AS failed,
                         ISNULL(SUM(CASE WHEN r.status = N'PENDING' THEN 1 ELSE 0 END), 0) AS pending
                    FROM grac_practice.asset_report_delivery_recipient r
                   WHERE r.delivery_id = d.delivery_id) c
     WHERE d.delivery_id = @delivery_id;
END
GO

-- Starts deliveries: every active schedule due today (@schedule_id NULL,
-- SCHEDULED; one per schedule and day) or one schedule now (MANUAL, its
-- screen must be in the caller @allowed_areas). Housekeeping first:
-- recipients left pending for 6 hours fail as interrupted, and delivered
-- files past the retention of their schedule are removed (the
-- distribution result stays). Every recipient is checked AT DELIVERY TIME
-- (13.4.1): active employee with access to the organization, Asset
-- Reports VIEW, VIEW on the report screen, report enabled, export policy
-- (Approver needs Asset Reports APPROVE; Disabled delivers to nobody).
-- 1. the work: one row per recipient to produce (the API runs the report
--    under that recipient and stores the result)   2. the deliveries started
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_delivery_start
    @organization_id   BIGINT         = NULL,
    @schedule_id       BIGINT         = NULL,
    @trigger_code      NVARCHAR(10)   = N'SCHEDULED',
    @allowed_areas     NVARCHAR(2000) = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @trigger_code = CASE WHEN @schedule_id IS NULL THEN N'SCHEDULED' ELSE N'MANUAL' END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE), @now DATETIME2 = SYSUTCDATETIME();

    IF @schedule_id IS NOT NULL
    BEGIN
        DECLARE @m_area NVARCHAR(100);
        SELECT @m_area = d.view_area
          FROM grac_practice.asset_report_schedule s
          JOIN grac_practice.asset_report_definition d ON d.report_code = s.report_code
         WHERE s.schedule_id = @schedule_id AND s.organization_id = @organization_id;
        IF @m_area IS NULL
            THROW 53121, 'Schedule not found.', 1;
        IF CHARINDEX(N',' + @m_area + N',', N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',') = 0
            THROW 53123, 'You do not have permission to view the screen this report is based on.', 1;
    END

    -- Housekeeping: interrupted recipients, then retention.
    DECLARE @stale TABLE (delivery_id BIGINT NOT NULL);   -- one row per interrupted recipient
    UPDATE r
       SET status = N'FAILED', reason = N'Interrupted: the delivery pass stopped before the file was produced.'
    OUTPUT inserted.delivery_id INTO @stale (delivery_id)
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
     WHERE r.status = N'PENDING' AND d.started_dt < DATEADD(HOUR, -6, @now)
       AND (@organization_id IS NULL OR d.organization_id = @organization_id);
    DECLARE @sd BIGINT = (SELECT MIN(delivery_id) FROM @stale);
    WHILE @sd IS NOT NULL
    BEGIN
        EXEC grac_practice.sp_asset_report_delivery_finish @delivery_id = @sd;
        SET @sd = (SELECT MIN(delivery_id) FROM @stale WHERE delivery_id > @sd);
    END
    UPDATE r
       SET columns_json = NULL, rows_json = NULL, purged_dt = @now
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
     WHERE r.purged_dt IS NULL AND r.rows_json IS NOT NULL
       AND DATEADD(DAY, d.retention_days, ISNULL(r.delivered_dt, d.started_dt)) < @now
       AND (@organization_id IS NULL OR d.organization_id = @organization_id);

    -- Schedules to run.
    DECLARE @due TABLE (schedule_id BIGINT PRIMARY KEY);
    IF @schedule_id IS NOT NULL
    BEGIN
        INSERT @due (schedule_id) VALUES (@schedule_id);
    END
    ELSE
    BEGIN
        INSERT @due (schedule_id)
        SELECT s.schedule_id
          FROM grac_practice.asset_report_schedule s
         WHERE s.is_active = 1 AND s.next_run_date <= @today
           AND (@organization_id IS NULL OR s.organization_id = @organization_id)
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery x
                            WHERE x.schedule_id = s.schedule_id AND x.run_date = @today AND x.trigger_code = N'SCHEDULED');
    END

    CREATE TABLE #rcp (
        employee_id    BIGINT         NOT NULL PRIMARY KEY,
        recipient_name NVARCHAR(200)  COLLATE DATABASE_DEFAULT NULL,
        via_role_name  NVARCHAR(200)  COLLATE DATABASE_DEFAULT NULL,
        in_org         BIT            NOT NULL DEFAULT 0,
        areas          NVARCHAR(2000) COLLATE DATABASE_DEFAULT NULL,
        reports_view   BIT            NOT NULL DEFAULT 0,
        reports_appr   BIT            NOT NULL DEFAULT 0
    );
    DECLARE @started TABLE (delivery_id BIGINT PRIMARY KEY);
    DECLARE @sch BIGINT, @org BIGINT, @code NVARCHAR(40), @area NVARCHAR(100), @available BIT, @enabled BIT, @policy NVARCHAR(10),
            @version INT, @rname NVARCHAR(120), @cls NVARCHAR(20), @search NVARCHAR(200), @status NVARCHAR(60), @atype INT,
            @days INT, @window INT, @retention INT, @freq NVARCHAR(10), @dow TINYINT, @dom TINYINT, @dlv BIGINT, @all_skip NVARCHAR(400);

    DECLARE sch_cur CURSOR LOCAL STATIC FOR SELECT schedule_id FROM @due ORDER BY schedule_id;
    OPEN sch_cur;
    FETCH NEXT FROM sch_cur INTO @sch;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @org = s.organization_id, @code = s.report_code, @area = d.view_area, @available = d.is_available, @enabled = e.IsEnabled,
               @policy = e.ExportPolicy, @version = d.version_no, @rname = d.report_name, @cls = e.Classification,
               @search = s.search_text, @status = s.status_code, @atype = s.asset_type_id, @days = s.days,
               @window = s.date_window_days, @retention = s.retention_days, @freq = s.frequency, @dow = s.day_of_week,
               @dom = s.day_of_month
          FROM grac_practice.asset_report_schedule s
          JOIN grac_practice.asset_report_definition d ON d.report_code = s.report_code
         CROSS APPLY (SELECT x.IsEnabled, x.ExportPolicy, x.Classification
                        FROM grac_practice.fn_asset_report_effective(s.organization_id) x WHERE x.ReportCode = s.report_code) e
         WHERE s.schedule_id = @sch;
        SET @all_skip = CASE WHEN @available = 0 OR @enabled = 0 THEN N'The report is not available or is disabled for the organization.'
                             WHEN @policy = N'DISABLED' THEN N'Export of this report is disabled by the organization policy.' END;

        BEGIN TRY
        BEGIN TRAN;
        INSERT grac_practice.asset_report_delivery (schedule_id, organization_id, report_code, report_version, report_name, classification,
                                                    filters_json, search_text, status_code, asset_type_id, date_from, date_to, days,
                                                    run_date, trigger_code, status, retention_days, started_by)
        SELECT @sch, @org, @code, @version, @rname, @cls,
               (SELECT @search AS search, @status AS status, @atype AS assetTypeId,
                       CONVERT(NVARCHAR(10), DATEADD(DAY, -@window, @today), 23) AS dateFrom,
                       CASE WHEN @window IS NOT NULL THEN CONVERT(NVARCHAR(10), @today, 23) END AS dateTo,
                       @days AS days FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               @search, @status, @atype, DATEADD(DAY, -@window, @today), CASE WHEN @window IS NOT NULL THEN @today END, @days,
               @today, @trigger_code, N'RUNNING', @retention, @actor;
        SET @dlv = SCOPE_IDENTITY();

        -- Distribution list: named employees, and every active holder of a role (primary or assigned).
        TRUNCATE TABLE #rcp;
        INSERT #rcp (employee_id, recipient_name, via_role_name)
        SELECT x.employee_id, MAX(e.employee_name), MIN(x.via_role)
          FROM (SELECT r.employee_id, CAST(NULL AS NVARCHAR(200)) AS via_role
                  FROM grac_practice.asset_report_schedule_recipient r
                 WHERE r.schedule_id = @sch AND r.recipient_kind = N'EMPLOYEE'
                UNION ALL
                SELECT e2.employee_id, rl.role_name
                  FROM grac_practice.asset_report_schedule_recipient r
                  JOIN grac_practice.organization_role rl ON rl.role_id = r.role_id
                  JOIN grac_practice.organization_employee e2 ON e2.organization_id = @org AND e2.status = N'Active'
                       AND (e2.role_id = r.role_id
                            OR EXISTS (SELECT 1 FROM grac_practice.organization_employee_role er
                                        WHERE er.employee_id = e2.employee_id AND er.role_id = r.role_id AND er.status = N'Active'))
                 WHERE r.schedule_id = @sch AND r.recipient_kind = N'ROLE') x
          JOIN grac_practice.organization_employee e ON e.employee_id = x.employee_id
         GROUP BY x.employee_id;

        UPDATE c
           SET in_org = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_asset_report_employee_in_org(@org, c.employee_id)) THEN 1 ELSE 0 END,
               areas = a.areas, reports_view = ISNULL(a.rv, 0), reports_appr = ISNULL(a.ra, 0)
          FROM #rcp c
         OUTER APPLY (SELECT STRING_AGG(CASE WHEN p.CanView = 1 AND p.MenuKey <> N'asset-reports' THEN p.MenuKey END, N',') AS areas,
                             MAX(CASE WHEN p.MenuKey = N'asset-reports' AND p.CanView = 1 THEN 1 ELSE 0 END) AS rv,
                             MAX(CASE WHEN p.MenuKey = N'asset-reports' AND p.CanApprove = 1 THEN 1 ELSE 0 END) AS ra
                        FROM grac_practice.fn_asset_report_employee_access(c.employee_id) p
                       WHERE p.MenuKey = N'asset-reports'
                          OR p.MenuKey IN (SELECT v.view_area FROM grac_practice.asset_report_definition v)) a;

        INSERT grac_practice.asset_report_delivery_recipient (delivery_id, employee_id, recipient_name, via_role_name, status, reason,
                                                              allowed_areas, can_approve)
        SELECT @dlv, c.employee_id, c.recipient_name, c.via_role_name,
               CASE WHEN k.reason IS NULL THEN N'PENDING' ELSE N'SKIPPED' END, k.reason, c.areas, c.reports_appr
          FROM #rcp c
         CROSS APPLY (SELECT CASE WHEN @all_skip IS NOT NULL THEN @all_skip
                                  WHEN c.in_org = 0 THEN N'Not an active employee with access to the organization.'
                                  WHEN c.reports_view = 0 THEN N'No VIEW permission on Asset Reports.'
                                  WHEN CHARINDEX(N',' + @area + N',', N',' + ISNULL(c.areas, N'') + N',') = 0
                                       THEN CONCAT(N'No VIEW permission on the screen the report is based on (', @area, N').')
                                  WHEN @policy = N'APPROVER' AND c.reports_appr = 0
                                       THEN N'The export policy of this report needs Asset Reports APPROVE.' END AS reason) k;

        UPDATE grac_practice.asset_report_schedule
           SET last_delivery_id = @dlv,
               next_run_date = CASE WHEN @trigger_code = N'SCHEDULED'
                                    THEN (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(@freq, @dow, @dom, DATEADD(DAY, 1, @today)))
                                    ELSE next_run_date END
         WHERE schedule_id = @sch;
        EXEC grac_practice.sp_asset_report_delivery_finish @delivery_id = @dlv;
        COMMIT;
        INSERT @started (delivery_id) VALUES (@dlv);
        END TRY
        BEGIN CATCH
            -- One schedule must not stop the others (a manual run reports its error).
            IF XACT_STATE() <> 0 ROLLBACK;
            IF @schedule_id IS NOT NULL THROW;
            INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
            VALUES (N'asset-report-schedule', @sch, N'DELIVERY_ERROR', NULL,
                    (SELECT ERROR_NUMBER() AS errorNumber, ERROR_MESSAGE() AS errorMessage FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                    N'Active', @actor);
        END CATCH
        FETCH NEXT FROM sch_cur INTO @sch;
    END
    CLOSE sch_cur;
    DEALLOCATE sch_cur;

    SELECT r.delivery_recipient_id AS DeliveryRecipientId, r.delivery_id AS DeliveryId, d.organization_id AS OrganizationId,
           d.report_code AS ReportCode, r.employee_id AS EmployeeId, r.allowed_areas AS AllowedAreas, r.can_approve AS CanApprove,
           d.search_text AS Search, d.status_code AS Status, d.asset_type_id AS AssetTypeId, d.date_from AS DateFrom,
           d.date_to AS DateTo, d.days AS Days
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
      JOIN @started s ON s.delivery_id = d.delivery_id
     WHERE r.status = N'PENDING'
     ORDER BY r.delivery_id, r.delivery_recipient_id;

    SELECT d.delivery_id AS DeliveryId, d.schedule_id AS ScheduleId, d.status AS Status, d.recipient_count AS RecipientCount,
           d.skipped_count AS SkippedCount
      FROM grac_practice.asset_report_delivery d
      JOIN @started s ON s.delivery_id = d.delivery_id
     ORDER BY d.delivery_id;
END
GO

-- The result for one recipient: DELIVERED with the columns and rows (JSON
-- written by the API), or FAILED with the reason. Only a pending
-- recipient is written.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_delivery_store
    @delivery_recipient_id BIGINT,
    @status                NVARCHAR(10),
    @reason                NVARCHAR(1000) = NULL,
    @row_count             INT            = NULL,
    @columns_json          NVARCHAR(MAX)  = NULL,
    @rows_json             NVARCHAR(MAX)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @status = UPPER(@status);
    IF @status NOT IN (N'DELIVERED', N'FAILED')
       OR (@status = N'DELIVERED' AND (@row_count IS NULL OR ISJSON(@columns_json) = 0 OR ISJSON(@rows_json) = 0))
        THROW 53124, 'Delivery result invalid.', 1;
    DECLARE @dlv BIGINT = (SELECT delivery_id FROM grac_practice.asset_report_delivery_recipient
                            WHERE delivery_recipient_id = @delivery_recipient_id AND status = N'PENDING');
    IF @dlv IS NULL
        THROW 53126, 'Delivery recipient not found or no longer pending.', 1;
    BEGIN TRAN;
    UPDATE grac_practice.asset_report_delivery_recipient
       SET status = @status, reason = CASE WHEN @status = N'FAILED' THEN LEFT(@reason, 1000) END,
           row_count = CASE WHEN @status = N'DELIVERED' THEN @row_count END,
           columns_json = CASE WHEN @status = N'DELIVERED' THEN @columns_json END,
           rows_json = CASE WHEN @status = N'DELIVERED' THEN @rows_json END,
           delivered_dt = CASE WHEN @status = N'DELIVERED' THEN SYSUTCDATETIME() END
     WHERE delivery_recipient_id = @delivery_recipient_id;
    EXEC grac_practice.sp_asset_report_delivery_finish @delivery_id = @dlv;
    COMMIT;
    SELECT @delivery_recipient_id AS DeliveryRecipientId, @status AS Result;
END
GO

-- =====================================================================
-- 6. Readers and download
-- =====================================================================
-- Deliveries of the reports the caller may view (optionally of one schedule).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_deliveries
    @organization_id BIGINT,
    @allowed_areas   NVARCHAR(2000) = NULL,
    @schedule_id     BIGINT         = NULL,
    @page_number     INT            = 1,
    @page_size       INT            = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53120, 'Organization not found.', 1;
    DECLARE @areas NVARCHAR(2004) = N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',';
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;

    SELECT d.delivery_id AS DeliveryId, d.schedule_id AS ScheduleId, s.schedule_name AS ScheduleName, d.report_name AS ReportName,
           d.report_version AS ReportVersion, d.classification AS Classification, d.run_date AS RunDate, d.trigger_code AS TriggerCode,
           d.status AS Status, d.recipient_count AS RecipientCount, d.delivered_count AS DeliveredCount,
           d.skipped_count AS SkippedCount, d.failed_count AS FailedCount, d.filters_json AS FiltersJson,
           d.started_by AS StartedBy, d.started_dt AS StartedDt, d.completed_dt AS CompletedDt,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_report_delivery d
      JOIN grac_practice.asset_report_schedule s ON s.schedule_id = d.schedule_id
      JOIN grac_practice.asset_report_definition def ON def.report_code = d.report_code
     WHERE d.organization_id = @organization_id AND CHARINDEX(N',' + def.view_area + N',', @areas) > 0
       AND (@schedule_id IS NULL OR d.schedule_id = @schedule_id)
     ORDER BY d.started_dt DESC, d.delivery_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Distribution result of one delivery: every recipient with its status and
-- reason (no file content).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_delivery_recipients
    @organization_id BIGINT,
    @delivery_id     BIGINT,
    @allowed_areas   NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_report_delivery d
                     JOIN grac_practice.asset_report_definition def ON def.report_code = d.report_code
                    WHERE d.delivery_id = @delivery_id AND d.organization_id = @organization_id
                      AND CHARINDEX(N',' + def.view_area + N',', N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',') > 0)
        THROW 53126, 'Delivery not found.', 1;
    SELECT r.delivery_recipient_id AS DeliveryRecipientId, r.employee_id AS EmployeeId, r.recipient_name AS RecipientName,
           r.via_role_name AS ViaRoleName, r.status AS Status, r.reason AS Reason, r.row_count AS [RowCount],
           r.delivered_dt AS DeliveredDt, r.download_count AS DownloadCount, r.first_downloaded_dt AS FirstDownloadedDt,
           r.purged_dt AS PurgedDt
      FROM grac_practice.asset_report_delivery_recipient r
     WHERE r.delivery_id = @delivery_id
     ORDER BY CASE r.status WHEN N'FAILED' THEN 1 WHEN N'SKIPPED' THEN 2 WHEN N'PENDING' THEN 3 ELSE 4 END, r.recipient_name;
END
GO

-- The caller own delivered files in the organization.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_my_deliveries
    @organization_id BIGINT,
    @employee_id     BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    SELECT r.delivery_recipient_id AS DeliveryRecipientId, s.schedule_name AS ScheduleName, d.report_name AS ReportName,
           d.report_version AS ReportVersion, d.classification AS Classification, d.run_date AS RunDate, r.row_count AS [RowCount],
           r.delivered_dt AS DeliveredDt, DATEADD(DAY, d.retention_days, r.delivered_dt) AS AvailableUntilDt,
           CAST(CASE WHEN r.purged_dt IS NULL AND r.rows_json IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsAvailable,
           r.download_count AS DownloadCount, d.filters_json AS FiltersJson,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
      JOIN grac_practice.asset_report_schedule s ON s.schedule_id = d.schedule_id
     WHERE d.organization_id = @organization_id AND r.employee_id = @employee_id AND r.status = N'DELIVERED'
     ORDER BY r.delivered_dt DESC, r.delivery_recipient_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Download of a delivered file by its recipient. Checked again now: the
-- recipient, the file still kept, the report screen still viewable, the
-- report enabled and the export policy. Recorded as an export (452) with
-- the delivery reference; returns the export heading, the columns and the
-- rows.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_report_delivery_download
    @organization_id       BIGINT,
    @delivery_recipient_id BIGINT,
    @employee_id           BIGINT,
    @allowed_areas         NVARCHAR(2000) = NULL,
    @can_approve           BIT            = 0,
    @actor                 NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    DECLARE @rcp_status NVARCHAR(10), @purged DATETIME2, @has_rows BIT, @code NVARCHAR(40), @area NVARCHAR(100),
            @enabled BIT, @available BIT, @policy NVARCHAR(10);
    SELECT @rcp_status = r.status, @purged = r.purged_dt, @has_rows = CASE WHEN r.rows_json IS NULL THEN 0 ELSE 1 END,
           @code = d.report_code, @area = def.view_area, @enabled = e.IsEnabled, @available = def.is_available, @policy = e.ExportPolicy
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
      JOIN grac_practice.asset_report_definition def ON def.report_code = d.report_code
     CROSS APPLY (SELECT x.IsEnabled, x.ExportPolicy FROM grac_practice.fn_asset_report_effective(d.organization_id) x
                   WHERE x.ReportCode = d.report_code) e
     WHERE r.delivery_recipient_id = @delivery_recipient_id AND d.organization_id = @organization_id
       AND r.employee_id = @employee_id AND @employee_id IS NOT NULL;
    IF @code IS NULL
        THROW 53126, 'Delivered file not found.', 1;
    IF @rcp_status <> N'DELIVERED' OR @purged IS NOT NULL OR @has_rows = 0
        THROW 53127, 'The file is not available: it was not delivered or has been removed after its retention period.', 1;
    IF CHARINDEX(N',' + @area + N',', N',' + REPLACE(ISNULL(@allowed_areas, N''), N' ', N'') + N',') = 0
       OR @enabled = 0 OR @available = 0
       OR NOT (@policy = N'ALLOWED' OR (@policy = N'APPROVER' AND ISNULL(@can_approve, 0) = 1))
        THROW 53129, 'You may no longer download this report (screen permission, report disabled or export policy).', 1;

    DECLARE @id TABLE (export_id BIGINT NOT NULL);
    BEGIN TRAN;
    INSERT grac_practice.asset_report_export (organization_id, report_code, report_version, report_name, classification, filters_json,
                                              columns_json, row_count, exported_by, exported_employee_id, delivery_recipient_id)
    OUTPUT inserted.export_id INTO @id (export_id)
    SELECT d.organization_id, d.report_code, d.report_version, d.report_name, d.classification, d.filters_json,
           r.columns_json, r.row_count, @actor, @employee_id, r.delivery_recipient_id
      FROM grac_practice.asset_report_delivery_recipient r
      JOIN grac_practice.asset_report_delivery d ON d.delivery_id = r.delivery_id
     WHERE r.delivery_recipient_id = @delivery_recipient_id;
    UPDATE grac_practice.asset_report_delivery_recipient
       SET download_count = download_count + 1, first_downloaded_dt = ISNULL(first_downloaded_dt, SYSUTCDATETIME())
     WHERE delivery_recipient_id = @delivery_recipient_id;
    COMMIT;

    SELECT x.export_id AS ExportId, x.report_code AS ReportCode, x.report_name AS ReportName, x.report_version AS ReportVersion,
           x.classification AS Classification, o.organization_name AS OrganizationName, x.row_count AS [RowCount],
           COALESCE(emp.employee_name, x.exported_by) AS ExportedBy, x.exported_dt AS ExportedDt, x.filters_json AS FiltersJson,
           r.delivered_dt AS GeneratedDt, r.columns_json AS ColumnsJson, r.rows_json AS RowsJson
      FROM grac_practice.asset_report_export x
      JOIN @id i ON i.export_id = x.export_id
      JOIN grac_practice.organization o ON o.organization_id = x.organization_id
      JOIN grac_practice.asset_report_delivery_recipient r ON r.delivery_recipient_id = x.delivery_recipient_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = x.exported_employee_id;
END
GO
PRINT '453: delivery procedures created.';
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
SELECT '453-a tables and export column' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_report_schedule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_report_schedule_recipient','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_report_delivery','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_report_delivery_recipient','U') IS NOT NULL
             AND COL_LENGTH('grac_practice.asset_report_export', 'delivery_recipient_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '453-b functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_report_next_run') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_employee_in_org') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_report_employee_access') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_report_schedules', 'sp_asset_report_schedule_save', 'sp_asset_report_delivery_finish',
                                'sp_asset_report_delivery_start', 'sp_asset_report_delivery_store', 'sp_asset_report_deliveries',
                                'sp_asset_report_delivery_recipients', 'sp_asset_report_my_deliveries',
                                'sp_asset_report_delivery_download')) = 9
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- 2026-10-06 is a Tuesday: daily -> same day, weekly Monday -> 2026-10-12,
-- weekly Tuesday -> same day, monthly day 5 -> 2026-11-05, monthly day 28 -> 2026-10-28.
SELECT '453-c next run dates',
       CASE WHEN (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(N'DAILY', NULL, NULL, '20261006')) = '20261006'
             AND (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(N'WEEKLY', 1, NULL, '20261006')) = '20261012'
             AND (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(N'WEEKLY', 2, NULL, '20261006')) = '20261006'
             AND (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(N'MONTHLY', NULL, 5, '20261006')) = '20261105'
             AND (SELECT NextRunDate FROM grac_practice.fn_asset_report_next_run(N'MONTHLY', NULL, 28, '20261006')) = '20261028'
            THEN 'PASS' ELSE 'FAIL' END;
GO

/* =====================================================================
   UAT (re-login after 453; Admin, plus one employee with VIEW on Asset
   Reports and Asset Register only)
   ---------------------------------------------------------------------
   1. Asset Reports -> Schedules -> New: Complete Asset Register, status
      Active, weekly on Monday, keep files 30 days, recipients: the Admin
      employee, the second employee and a role -> next run is the coming
      Monday (or today when it is Monday).
   2. Run now: the run lists one row per recipient -- DELIVERED with the
      row count, or SKIPPED with the reason (for example a role member
      without Asset Reports VIEW). Schedule Vendor Contact Matrix (Asset
      Contracts screen) to the second employee -> SKIPPED: no VIEW on
      asset-contracts.
   3. As the second employee: Asset Reports -> My deliveries lists the
      file; Download writes the CSV with the watermark heading; Export
      history shows the download with the same filters and row count.
   4. Set the report export policy to Approver in Settings -> the next run
      skips recipients without Asset Reports APPROVE; a file delivered
      before can no longer be downloaded by them (53129).
   5. Leave the API running: the worker delivers due schedules once per
      day each (TaskNotification:AssetReportDeliveryEnabled); a second
      pass the same day starts nothing.
   6. Files older than the retention are removed on the next pass; the
      run keeps the distribution result and My deliveries shows the file
      as removed.
   ===================================================================== */
