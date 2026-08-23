-- =====================================================================
-- 093 Organization Assurance Triggers -- Stage 3 stored procedures
--
-- Depends on 092 (schema).
--
-- Procedures:
--   sp_org_assurance_trigger_type_list           SCHEDULED/EVENT/CONTINUOUS/MANUAL
--   sp_org_assurance_schedule_frequency_list     DAILY/WEEKLY/MONTHLY/QUARTERLY/ANNUAL
--   sp_org_assurance_event_code_list             8 BRD examples + CUSTOM
--   sp_org_assurance_continuous_source_list      API/RULE/DATA_FEED
--   sp_org_assurance_trigger_list                All triggers for a version
--   sp_org_assurance_trigger_get                 Single trigger
--   sp_org_assurance_trigger_save                Draft-only upsert
--   sp_org_assurance_trigger_delete              Draft-only soft delete
--
-- Rollback: 093_org_assurance_trigger_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_trigger_config','U') IS NULL
BEGIN
    RAISERROR('093: run 092 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- Fixed vocab lookups
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_trigger_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TriggerTypeCode, TriggerTypeName, DisplayOrder
    FROM (VALUES
        (N'SCHEDULED',    N'Scheduled',    1),
        (N'EVENT_DRIVEN', N'Event Driven', 2),
        (N'CONTINUOUS',   N'Continuous',   3),
        (N'MANUAL',       N'Manual',       4)
    ) t(TriggerTypeCode, TriggerTypeName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_schedule_frequency_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT FrequencyCode, FrequencyName, DisplayOrder
    FROM (VALUES
        (N'DAILY',     N'Daily',     1),
        (N'WEEKLY',    N'Weekly',    2),
        (N'MONTHLY',   N'Monthly',   3),
        (N'QUARTERLY', N'Quarterly', 4),
        (N'ANNUAL',    N'Annual',    5)
    ) t(FrequencyCode, FrequencyName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_event_code_list
AS
BEGIN
    SET NOCOUNT ON;
    -- BRD Sec 9 examples + CUSTOM catch-all.
    SELECT EventCode, EventName, DisplayOrder
    FROM (VALUES
        (N'LICENSE_EXPIRY',        N'License Expiry',         1),
        (N'USER_TERMINATION',      N'User Termination',       2),
        (N'VENDOR_RENEWAL',        N'Vendor Renewal',         3),
        (N'HIGH_VALUE_TRANSACTION',N'High Value Transaction', 4),
        (N'NEW_ASSET',             N'New Asset',              5),
        (N'POLICY_CHANGE',         N'Policy Change',          6),
        (N'SECURITY_INCIDENT',     N'Security Incident',      7),
        (N'CUSTOM',                N'Custom',                 8)
    ) t(EventCode, EventName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_continuous_source_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SourceCode, SourceName, DisplayOrder
    FROM (VALUES
        (N'API',       N'API',        1),
        (N'RULE',      N'Rule',       2),
        (N'DATA_FEED', N'Data Feed',  3)
    ) t(SourceCode, SourceName, DisplayOrder)
    ORDER BY DisplayOrder;
END
GO

-- =====================================================================
-- sp_org_assurance_trigger_list  (header + rows for a version)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_trigger_list
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    -- 1) Header
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- 2) Triggers
    SELECT t.org_assurance_trigger_config_id AS TriggerId,
           t.trigger_code                    AS TriggerCode,
           t.trigger_name                    AS TriggerName,
           t.trigger_type                    AS TriggerType,
           t.is_enabled                      AS IsEnabled,
           t.description                     AS Description,
           t.schedule_frequency_code         AS ScheduleFrequencyCode,
           t.schedule_frequency_id           AS ScheduleFrequencyId,
           t.schedule_frequency_name         AS ScheduleFrequencyName,
           t.schedule_start_date             AS ScheduleStartDate,
           t.schedule_end_date               AS ScheduleEndDate,
           t.schedule_time                   AS ScheduleTime,
           t.day_of_week                     AS DayOfWeek,
           t.day_of_month                    AS DayOfMonth,
           t.month_of_year                   AS MonthOfYear,
           t.next_run_at                     AS NextRunAt,
           t.last_run_at                     AS LastRunAt,
           t.event_code                      AS EventCode,
           t.event_name                      AS EventName,
           t.event_source                    AS EventSource,
           t.event_filter_json               AS EventFilterJson,
           t.continuous_source_code          AS ContinuousSourceCode,
           t.continuous_endpoint             AS ContinuousEndpoint,
           t.continuous_rule_code            AS ContinuousRuleCode
    FROM grac_practice.org_assurance_trigger_config t
    WHERE t.organization_id = @organization_id
      AND t.org_assurance_definition_version_id = @version_id
      AND t.is_active = 1
    ORDER BY t.trigger_type, t.trigger_name, t.org_assurance_trigger_config_id;
END
GO

-- =====================================================================
-- sp_org_assurance_trigger_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_trigger_get
    @organization_id BIGINT,
    @trigger_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @trigger_id IS NULL
        THROW 53602, 'organization_id and trigger_id are required.', 1;

    SELECT t.org_assurance_trigger_config_id AS TriggerId,
           t.org_assurance_definition_id     AS DefinitionId,
           t.org_assurance_definition_version_id AS DefinitionVersionId,
           t.trigger_code                    AS TriggerCode,
           t.trigger_name                    AS TriggerName,
           t.trigger_type                    AS TriggerType,
           t.is_enabled                      AS IsEnabled,
           t.description                     AS Description,
           t.schedule_frequency_code         AS ScheduleFrequencyCode,
           t.schedule_frequency_id           AS ScheduleFrequencyId,
           t.schedule_frequency_name         AS ScheduleFrequencyName,
           t.schedule_start_date             AS ScheduleStartDate,
           t.schedule_end_date               AS ScheduleEndDate,
           t.schedule_time                   AS ScheduleTime,
           t.day_of_week                     AS DayOfWeek,
           t.day_of_month                    AS DayOfMonth,
           t.month_of_year                   AS MonthOfYear,
           t.next_run_at                     AS NextRunAt,
           t.last_run_at                     AS LastRunAt,
           t.event_code                      AS EventCode,
           t.event_name                      AS EventName,
           t.event_source                    AS EventSource,
           t.event_filter_json               AS EventFilterJson,
           t.continuous_source_code          AS ContinuousSourceCode,
           t.continuous_endpoint             AS ContinuousEndpoint,
           t.continuous_rule_code            AS ContinuousRuleCode,
           t.entered_by                      AS EnteredBy,
           t.entered_dt                      AS EnteredDt,
           t.updated_by                      AS UpdatedBy,
           t.updated_dt                      AS UpdatedDt
    FROM grac_practice.org_assurance_trigger_config t
    WHERE t.org_assurance_trigger_config_id = @trigger_id
      AND t.organization_id = @organization_id
      AND t.is_active = 1;
END
GO

-- =====================================================================
-- sp_org_assurance_trigger_save  (Draft-only upsert)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_trigger_save
    @organization_id             BIGINT,
    @definition_id               BIGINT,
    @trigger_id                  BIGINT        = NULL,
    @trigger_code                NVARCHAR(80),
    @trigger_name                NVARCHAR(200),
    @trigger_type                NVARCHAR(30),
    @is_enabled                  BIT           = 1,
    @description                 NVARCHAR(MAX) = NULL,
    -- Scheduled
    @schedule_frequency_code     NVARCHAR(30)  = NULL,
    @schedule_frequency_id       INT           = NULL,
    @schedule_frequency_name     NVARCHAR(120) = NULL,
    @schedule_start_date         DATE          = NULL,
    @schedule_end_date           DATE          = NULL,
    @schedule_time               TIME          = NULL,
    @day_of_week                 INT           = NULL,
    @day_of_month                INT           = NULL,
    @month_of_year               INT           = NULL,
    -- Event
    @event_code                  NVARCHAR(60)  = NULL,
    @event_name                  NVARCHAR(200) = NULL,
    @event_source                NVARCHAR(100) = NULL,
    @event_filter_json           NVARCHAR(MAX) = NULL,
    -- Continuous
    @continuous_source_code      NVARCHAR(30)  = NULL,
    @continuous_endpoint         NVARCHAR(500) = NULL,
    @continuous_rule_code        NVARCHAR(80)  = NULL,
    @actor                       NVARCHAR(100) = 'system',
    @trigger_id_out              BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @trigger_code IS NULL OR LEN(LTRIM(RTRIM(@trigger_code))) = 0
        THROW 54001, 'trigger_code is required.', 1;
    IF @trigger_name IS NULL OR LEN(LTRIM(RTRIM(@trigger_name))) = 0
        THROW 54002, 'trigger_name is required.', 1;
    IF @trigger_type NOT IN (N'SCHEDULED', N'EVENT_DRIVEN', N'CONTINUOUS', N'MANUAL')
        THROW 54003, 'trigger_type must be SCHEDULED / EVENT_DRIVEN / CONTINUOUS / MANUAL.', 1;
    IF ISNULL(@is_enabled, 1) = 1 SET @is_enabled = 1;

    -- Validate JSON if provided.
    IF @event_filter_json IS NOT NULL AND ISJSON(@event_filter_json) = 0
        THROW 54004, 'event_filter_json is not a valid JSON document.', 1;

    -- Ownership + Draft-only.
    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Triggers can only be edited when the current version is Draft.', 1;

    -- Clear polymorphic fields that don't apply to the picked type.
    IF @trigger_type <> N'SCHEDULED'
    BEGIN
        SET @schedule_frequency_code = NULL; SET @schedule_frequency_id   = NULL;
        SET @schedule_frequency_name = NULL; SET @schedule_start_date     = NULL;
        SET @schedule_end_date       = NULL; SET @schedule_time           = NULL;
        SET @day_of_week             = NULL; SET @day_of_month            = NULL;
        SET @month_of_year           = NULL;
    END
    IF @trigger_type <> N'EVENT_DRIVEN'
    BEGIN
        SET @event_code = NULL; SET @event_name = NULL;
        SET @event_source = NULL; SET @event_filter_json = NULL;
    END
    IF @trigger_type <> N'CONTINUOUS'
    BEGIN
        SET @continuous_source_code = NULL; SET @continuous_endpoint = NULL;
        SET @continuous_rule_code   = NULL;
    END

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @trigger_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_trigger_config
            WHERE org_assurance_definition_version_id = @current_version_id
              AND trigger_code = @trigger_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 54005, 'A trigger with this code already exists on this definition version.', 1;
        END

        INSERT INTO grac_practice.org_assurance_trigger_config
            (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
             trigger_code, trigger_name, trigger_type, is_enabled, description,
             schedule_frequency_code, schedule_frequency_id, schedule_frequency_name,
             schedule_start_date, schedule_end_date, schedule_time,
             day_of_week, day_of_month, month_of_year,
             event_code, event_name, event_source, event_filter_json,
             continuous_source_code, continuous_endpoint, continuous_rule_code,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id, @current_version_id, @organization_id,
             @trigger_code, @trigger_name, @trigger_type, ISNULL(@is_enabled, 1), @description,
             @schedule_frequency_code, @schedule_frequency_id, @schedule_frequency_name,
             @schedule_start_date, @schedule_end_date, @schedule_time,
             @day_of_week, @day_of_month, @month_of_year,
             @event_code, @event_name, @event_source, @event_filter_json,
             @continuous_source_code, @continuous_endpoint, @continuous_rule_code,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @trigger_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @tg_org BIGINT, @tg_version BIGINT;
        SELECT @tg_org = organization_id, @tg_version = org_assurance_definition_version_id
        FROM grac_practice.org_assurance_trigger_config
        WHERE org_assurance_trigger_config_id = @trigger_id AND is_active = 1;

        IF @tg_org IS NULL     BEGIN ROLLBACK; THROW 54006, 'Trigger not found.', 1; END
        IF @tg_org <> @organization_id
        BEGIN ROLLBACK; THROW 53607, 'Trigger belongs to a different organization.', 1; END
        IF @tg_version <> @current_version_id
        BEGIN ROLLBACK; THROW 54007, 'Trigger belongs to a different definition version.', 1; END

        UPDATE grac_practice.org_assurance_trigger_config
        SET trigger_name             = @trigger_name,
            trigger_type             = @trigger_type,
            is_enabled               = ISNULL(@is_enabled, 1),
            description              = @description,
            schedule_frequency_code  = @schedule_frequency_code,
            schedule_frequency_id    = @schedule_frequency_id,
            schedule_frequency_name  = @schedule_frequency_name,
            schedule_start_date      = @schedule_start_date,
            schedule_end_date        = @schedule_end_date,
            schedule_time            = @schedule_time,
            day_of_week              = @day_of_week,
            day_of_month             = @day_of_month,
            month_of_year            = @month_of_year,
            event_code               = @event_code,
            event_name               = @event_name,
            event_source             = @event_source,
            event_filter_json        = @event_filter_json,
            continuous_source_code   = @continuous_source_code,
            continuous_endpoint      = @continuous_endpoint,
            continuous_rule_code     = @continuous_rule_code,
            updated_by               = @actor,
            updated_dt               = SYSUTCDATETIME()
        WHERE org_assurance_trigger_config_id = @trigger_id;

        SET @trigger_id_out = @trigger_id;
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_trigger_delete  (Draft-only soft delete)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_trigger_delete
    @organization_id BIGINT,
    @trigger_id      BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @trigger_id IS NULL
        THROW 53602, 'organization_id and trigger_id are required.', 1;

    DECLARE @tg_org BIGINT, @definition_id BIGINT;
    SELECT @tg_org = organization_id, @definition_id = org_assurance_definition_id
    FROM grac_practice.org_assurance_trigger_config
    WHERE org_assurance_trigger_config_id = @trigger_id AND is_active = 1;

    IF @tg_org IS NULL      THROW 54006, 'Trigger not found.', 1;
    IF @tg_org <> @organization_id
        THROW 53607, 'Trigger belongs to a different organization.', 1;

    -- Draft-only enforcement.
    DECLARE @status_code NVARCHAR(60);
    SELECT @status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @status_code <> N'Draft'
        THROW 53608, 'Triggers can only be deleted when the current version is Draft.', 1;

    UPDATE grac_practice.org_assurance_trigger_config
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_trigger_config_id = @trigger_id;
END
GO

PRINT '093 Organization Assurance Trigger procedures deployed.';
GO
