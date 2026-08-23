-- =====================================================================
-- 092 Organization Assurance (Phase 2) -- Stage 3 Trigger Config
--
-- Business context (BRD Part 2 Sec 9):
--   Support four trigger kinds:
--     SCHEDULED     Daily / Weekly / Monthly / Quarterly / Annual
--     EVENT_DRIVEN  License Expiry, User Termination, Vendor Renewal,
--                   High Value Transaction, New Asset, Policy Change,
--                   Security Incident, ...
--     CONTINUOUS    Triggered by APIs, rules or data feeds
--     MANUAL        On-demand execution
--
-- Triggers are tied to a definition version, like Scope / Evidence /
-- Workflow / Scoring. Edits require the current version to be Draft.
--
-- Single polymorphic table -- fields per type are nullable; a CHECK
-- keeps trigger_type constrained. A row can hold either a schedule,
-- an event, a continuous source, or (for MANUAL) just enable/disable.
--
-- Rollback: 092_org_assurance_trigger_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
BEGIN
    RAISERROR('092: run 069 first (org_assurance_definition schema missing).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

IF OBJECT_ID('grac_practice.org_assurance_trigger_config','U') IS NULL
CREATE TABLE grac_practice.org_assurance_trigger_config(
    org_assurance_trigger_config_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_trigger PRIMARY KEY,
    org_assurance_definition_id         BIGINT NOT NULL,
    org_assurance_definition_version_id BIGINT NOT NULL,
    organization_id                     BIGINT NOT NULL,

    trigger_code                        NVARCHAR(80)  NOT NULL,
    trigger_name                        NVARCHAR(200) NOT NULL,
    -- SCHEDULED / EVENT_DRIVEN / CONTINUOUS / MANUAL
    trigger_type                        NVARCHAR(30)  NOT NULL,

    is_enabled                          BIT NOT NULL CONSTRAINT df_pm_oa_trigger_enabled DEFAULT 1,
    description                         NVARCHAR(MAX) NULL,

    -- ---------- SCHEDULED ----------
    schedule_frequency_code             NVARCHAR(30)  NULL,   -- DAILY / WEEKLY / MONTHLY / QUARTERLY / ANNUAL
    schedule_frequency_id               INT           NULL,   -- soft ref to frequency_master
    schedule_frequency_name             NVARCHAR(120) NULL,
    schedule_start_date                 DATE          NULL,
    schedule_end_date                   DATE          NULL,
    schedule_time                       TIME          NULL,
    day_of_week                         INT           NULL,   -- 1-7 (Mon=1)
    day_of_month                        INT           NULL,   -- 1-31
    month_of_year                       INT           NULL,   -- 1-12 (for ANNUAL / QUARTERLY hints)
    next_run_at                         DATETIME2     NULL,   -- populated by the Stage 3 scheduler
    last_run_at                         DATETIME2     NULL,

    -- ---------- EVENT_DRIVEN ----------
    event_code                          NVARCHAR(60)  NULL,   -- LICENSE_EXPIRY / USER_TERMINATION / ...
    event_name                          NVARCHAR(200) NULL,
    event_source                        NVARCHAR(100) NULL,   -- Entity type / system
    event_filter_json                   NVARCHAR(MAX) NULL,   -- structured filter (no code, no SQL)

    -- ---------- CONTINUOUS ----------
    continuous_source_code              NVARCHAR(30)  NULL,   -- API / RULE / DATA_FEED
    continuous_endpoint                 NVARCHAR(500) NULL,
    continuous_rule_code                NVARCHAR(80)  NULL,

    is_active                           BIT NOT NULL CONSTRAINT df_pm_oa_trigger_active DEFAULT 1,
    record_status_id                    INT NOT NULL,
    entered_by                          NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_trigger_ent_by DEFAULT 'system',
    entered_dt                          DATETIME2 NOT NULL CONSTRAINT df_pm_oa_trigger_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by                          NVARCHAR(100) NULL,
    updated_dt                          DATETIME2 NULL,

    CONSTRAINT fk_pm_oa_trigger_definition
        FOREIGN KEY(org_assurance_definition_id)
        REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id),
    CONSTRAINT fk_pm_oa_trigger_version
        FOREIGN KEY(org_assurance_definition_version_id)
        REFERENCES grac_practice.org_assurance_definition_version(org_assurance_definition_version_id),
    CONSTRAINT fk_pm_oa_trigger_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_oa_trigger_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT ck_pm_oa_trigger_type CHECK (
        trigger_type IN (N'SCHEDULED', N'EVENT_DRIVEN', N'CONTINUOUS', N'MANUAL')),
    CONSTRAINT ck_pm_oa_trigger_period CHECK (
        schedule_start_date IS NULL OR schedule_end_date IS NULL
        OR schedule_end_date >= schedule_start_date),
    CONSTRAINT uq_pm_oa_trigger_code
        UNIQUE(org_assurance_definition_version_id, trigger_code)
);
GO

CREATE INDEX ix_pm_oa_trigger_version
    ON grac_practice.org_assurance_trigger_config(
        org_assurance_definition_version_id, trigger_type, org_assurance_trigger_config_id)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_trigger_org
    ON grac_practice.org_assurance_trigger_config(organization_id, is_active, is_enabled)
    WHERE is_active = 1;
GO

COMMIT TRAN;
GO

SELECT 'org_assurance_trigger_config present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_trigger_config','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '092 Organization Assurance Trigger schema deployed.';
GO

SET NOEXEC OFF;
GO
