-- =====================================================================
-- 054 Custom Gap -- schema
--
-- First-class entity for manually-recorded gaps in Gap Center.
--
-- Design decisions:
--   * Independent from practice_task -- gap identification and task
--     execution are distinct concepts (as agreed when Task Center's
--     Gaps tab was extracted into Gap Center).
--   * linked_task_id kept nullable so a follow-up can attach the task
--     that was created to address the gap without altering schema.
--   * status uses free-text NVARCHAR(30) (Open / InProgress / Closed /
--     Cancelled) for now to keep this migration small. Migrate to a
--     lookup table when we add proper transitions.
--   * gap_type_code kept nullable / defaulted 'Custom' so future gap
--     origins (assurance, exception, risk, audit) can share this table
--     if desired.
--
-- ASCII-only, no CTE-then-MERGE constructs.
-- Rollback: database/054_custom_gap_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    RAISERROR('054: schema grac_practice missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
CREATE TABLE grac_practice.custom_gap(
    custom_gap_id       BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_custom_gap PRIMARY KEY,
    organization_id     BIGINT        NOT NULL,
    gap_type_code       NVARCHAR(60)  NOT NULL
        CONSTRAINT df_pm_custom_gap_type DEFAULT N'Custom',
    title               NVARCHAR(250) NOT NULL,
    description         NVARCHAR(MAX) NULL,
    priority            NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_custom_gap_priority DEFAULT N'Medium',
    owner_employee_id   BIGINT        NULL,
    due_date            DATE          NULL,
    status              NVARCHAR(30)  NOT NULL
        CONSTRAINT df_pm_custom_gap_status DEFAULT N'Open',
    remarks             NVARCHAR(1000) NULL,
    -- Optional linkage for when a task is opened to address this gap.
    linked_task_id      BIGINT        NULL,
    entered_by          NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_custom_gap_entered_by DEFAULT 'system',
    entered_dt          DATETIME2     NOT NULL
        CONSTRAINT df_pm_custom_gap_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by          NVARCHAR(100) NULL,
    updated_dt          DATETIME2     NULL,
    CONSTRAINT ck_pm_custom_gap_priority
        CHECK (priority IN (N'Low', N'Medium', N'High', N'Critical')),
    CONSTRAINT ck_pm_custom_gap_status
        CHECK (status   IN (N'Open', N'InProgress', N'Closed', N'Cancelled'))
);
GO

-- Filter-friendly indexes.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_custom_gap_org_status' AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    CREATE INDEX ix_pm_custom_gap_org_status
        ON grac_practice.custom_gap(organization_id, status)
        INCLUDE (priority, due_date);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_custom_gap_owner' AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    CREATE INDEX ix_pm_custom_gap_owner
        ON grac_practice.custom_gap(owner_employee_id)
        INCLUDE (organization_id, status);
GO

PRINT '054 custom_gap schema installed.';
GO

SET NOEXEC OFF;
GO
