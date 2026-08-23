-- =====================================================================
-- 110 Rename Assurance-owned supporting tables into custom_gap_*
-- so they can serve unified Gap Center (all sources).
--
--   org_assurance_gap_observation -> custom_gap_observation
--   org_assurance_gap_action      -> custom_gap_action
--   org_assurance_gap_history     -> custom_gap_history
--
-- Approach: CREATE the new tables (idempotent), copy rows from the
-- old tables (guarded by NOT EXISTS on unique keys), and repoint the
-- FKs so the copied rows reference the correct custom_gap_id.
--
-- IMPORTANT: at this step we do NOT drop the old tables (that happens
-- in 113). This keeps the source data intact for the 111 data
-- migration and for rollback safety.
--
-- Rollback: 110_custom_gap_supporting_tables_rename_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN
    RAISERROR('110: run 109 first (custom_gap extensions).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. custom_gap_observation (junction) -- matches shape of the old
--    org_assurance_gap_observation table but FKs custom_gap.
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap_observation','U') IS NULL
CREATE TABLE grac_practice.custom_gap_observation(
    custom_gap_observation_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_custom_gap_obs PRIMARY KEY,
    custom_gap_id             BIGINT NOT NULL,
    org_assurance_observation_id BIGINT NOT NULL,
    organization_id           BIGINT NOT NULL,

    link_source               NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_custom_gap_obs_source DEFAULT N'AUTO',
    linked_by                 NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_custom_gap_obs_by DEFAULT 'system',
    linked_dt                 DATETIME2 NOT NULL
        CONSTRAINT df_pm_custom_gap_obs_dt DEFAULT SYSUTCDATETIME(),
    detach_by                 NVARCHAR(100)  NULL,
    detach_dt                 DATETIME2      NULL,
    detach_reason             NVARCHAR(1000) NULL,
    notes                     NVARCHAR(1000) NULL,
    is_active                 BIT NOT NULL
        CONSTRAINT df_pm_custom_gap_obs_active DEFAULT 1,

    CONSTRAINT fk_pm_custom_gap_obs_gap
        FOREIGN KEY(custom_gap_id) REFERENCES grac_practice.custom_gap(custom_gap_id),
    CONSTRAINT fk_pm_custom_gap_obs_observation
        FOREIGN KEY(org_assurance_observation_id)
        REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
    CONSTRAINT fk_pm_custom_gap_obs_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_custom_gap_obs_source CHECK (
        link_source IN (N'AUTO', N'MANUAL', N'MERGE'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='uq_pm_custom_gap_obs_active'
                 AND object_id = OBJECT_ID('grac_practice.custom_gap_observation'))
CREATE UNIQUE INDEX uq_pm_custom_gap_obs_active
    ON grac_practice.custom_gap_observation(custom_gap_id, org_assurance_observation_id)
    WHERE is_active = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='ix_pm_custom_gap_obs_gap'
                 AND object_id = OBJECT_ID('grac_practice.custom_gap_observation'))
CREATE INDEX ix_pm_custom_gap_obs_gap
    ON grac_practice.custom_gap_observation(
        custom_gap_id, is_active,
        custom_gap_observation_id DESC)
    WHERE is_active = 1;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='ix_pm_custom_gap_obs_observation'
                 AND object_id = OBJECT_ID('grac_practice.custom_gap_observation'))
CREATE INDEX ix_pm_custom_gap_obs_observation
    ON grac_practice.custom_gap_observation(
        org_assurance_observation_id, is_active,
        custom_gap_observation_id DESC)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. custom_gap_action -- unified corrective-action table
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap_action','U') IS NULL
CREATE TABLE grac_practice.custom_gap_action(
    custom_gap_action_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_custom_gap_action PRIMARY KEY,
    custom_gap_id        BIGINT NOT NULL,
    organization_id      BIGINT NOT NULL,

    action_order         INT NOT NULL
        CONSTRAINT df_pm_custom_gap_action_order DEFAULT 0,
    action_title         NVARCHAR(300) NOT NULL,
    action_description   NVARCHAR(MAX) NULL,

    assigned_employee_id  BIGINT NULL,
    assigned_display_name NVARCHAR(240) NULL,
    due_date             DATE NULL,
    completed_dt         DATETIME2 NULL,

    action_status_code   NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_custom_gap_action_status DEFAULT N'Pending',
    task_id              BIGINT NULL,
    notes                NVARCHAR(MAX) NULL,

    is_active            BIT NOT NULL
        CONSTRAINT df_pm_custom_gap_action_active DEFAULT 1,
    entered_by           NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_custom_gap_action_ent_by DEFAULT 'system',
    entered_dt           DATETIME2 NOT NULL
        CONSTRAINT df_pm_custom_gap_action_ent_dt DEFAULT SYSUTCDATETIME(),
    updated_by           NVARCHAR(100) NULL,
    updated_dt           DATETIME2 NULL,

    CONSTRAINT fk_pm_custom_gap_action_gap
        FOREIGN KEY(custom_gap_id) REFERENCES grac_practice.custom_gap(custom_gap_id),
    CONSTRAINT fk_pm_custom_gap_action_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_custom_gap_action_status CHECK (
        action_status_code IN (N'Pending', N'InProgress', N'Completed', N'Cancelled'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='ix_pm_custom_gap_action_gap'
                 AND object_id = OBJECT_ID('grac_practice.custom_gap_action'))
CREATE INDEX ix_pm_custom_gap_action_gap
    ON grac_practice.custom_gap_action(
        custom_gap_id, action_order, custom_gap_action_id)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 3. custom_gap_history -- unified lifecycle audit log
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap_history','U') IS NULL
CREATE TABLE grac_practice.custom_gap_history(
    custom_gap_history_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_custom_gap_history PRIMARY KEY,
    custom_gap_id         BIGINT NOT NULL,
    organization_id       BIGINT NOT NULL,
    action_code           NVARCHAR(40)  NOT NULL,

    -- Free-text from/to labels rather than FK to a status master --
    -- keeps history table decoupled from status-vocabulary changes.
    from_status_code      NVARCHAR(60)  NULL,
    to_status_code        NVARCHAR(60)  NULL,

    reason_text           NVARCHAR(1000) NULL,
    actor_display_name    NVARCHAR(240)  NULL,
    entered_by            NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_custom_gap_hist_ent_by DEFAULT 'system',
    entered_dt            DATETIME2 NOT NULL
        CONSTRAINT df_pm_custom_gap_hist_ent_dt DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_pm_custom_gap_hist_gap
        FOREIGN KEY(custom_gap_id) REFERENCES grac_practice.custom_gap(custom_gap_id),
    CONSTRAINT fk_pm_custom_gap_hist_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name='ix_pm_custom_gap_hist_gap'
                 AND object_id = OBJECT_ID('grac_practice.custom_gap_history'))
CREATE INDEX ix_pm_custom_gap_hist_gap
    ON grac_practice.custom_gap_history(custom_gap_id, entered_dt DESC);
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'custom_gap_observation present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.custom_gap_observation','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'custom_gap_action present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.custom_gap_action','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'custom_gap_history present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '110 Custom Gap supporting tables created.';
GO

SET NOEXEC OFF;
GO
