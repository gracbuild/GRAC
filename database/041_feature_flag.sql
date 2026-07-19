-- =====================================================================
-- 041 Feature flag registry  (charter §7 cross-cut, brought forward)
--
-- Charter §7 requires "every new screen defaulted OFF" via a feature_flag
-- table. The original TDD placed this at migration 061 alongside other
-- cross-cuts, but §12.1.3 introduces the first new screen (`tasks`) so
-- the table is needed now.
--
-- Contents:
--   * feature_flag_master     — the catalog of flags (code + description)
--   * feature_flag            — per-organization enable/disable
--   * fn_pm_feature_enabled   — inline scalar helper
--   * Seeds: register the 11 workflow-layer screens as OFF
--
-- Rollback: database/041_feature_flag_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- Prerequisite guard — see 037_task_engine.sql for the pattern explanation.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (041): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('041_feature_flag: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. feature_flag_master — catalog
-- =====================================================================
IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
CREATE TABLE grac_practice.feature_flag_master(
    feature_flag_id      INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_feature_flag_master PRIMARY KEY,
    feature_code         NVARCHAR(80)  NOT NULL
        CONSTRAINT uq_pm_feature_flag_code UNIQUE,
    feature_name         NVARCHAR(200) NOT NULL,
    description          NVARCHAR(400) NULL,
    category             NVARCHAR(60)  NOT NULL DEFAULT N'Screen',   -- Screen / Api / Behaviour
    default_enabled      BIT           NOT NULL DEFAULT 0,
    is_active            BIT           NOT NULL DEFAULT 1,
    entered_by           NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt           DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by           NVARCHAR(100) NULL,
    updated_dt           DATETIME2     NULL
);
GO

-- =====================================================================
-- 2. feature_flag — per-organization
--    Absence of a row for (organization_id, feature_flag_id) means
--    "inherit default_enabled from feature_flag_master".
-- =====================================================================
IF OBJECT_ID('grac_practice.feature_flag','U') IS NULL
CREATE TABLE grac_practice.feature_flag(
    feature_flag_id_id   BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_feature_flag PRIMARY KEY,
    organization_id      BIGINT        NOT NULL,
    feature_flag_id      INT           NOT NULL
        CONSTRAINT fk_pm_feature_flag_master
        REFERENCES grac_practice.feature_flag_master(feature_flag_id),
    is_enabled           BIT           NOT NULL DEFAULT 0,
    notes                NVARCHAR(400) NULL,
    entered_by           NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt           DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by           NVARCHAR(100) NULL,
    updated_dt           DATETIME2     NULL,
    CONSTRAINT uq_pm_feature_flag_org_feature
        UNIQUE (organization_id, feature_flag_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_feature_flag_lookup' AND object_id = OBJECT_ID('grac_practice.feature_flag'))
    CREATE INDEX ix_pm_feature_flag_lookup
        ON grac_practice.feature_flag(organization_id, feature_flag_id)
        INCLUDE (is_enabled);
GO

-- =====================================================================
-- 3. fn_pm_feature_enabled(organization_id, feature_code) -> BIT
--    Precedence: per-org row > master default > 0
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_feature_enabled
(
    @organization_id BIGINT,
    @feature_code    NVARCHAR(80)
)
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    IF @feature_code IS NULL RETURN 0;

    DECLARE @enabled BIT = NULL;

    IF @organization_id IS NOT NULL
    BEGIN
        SELECT @enabled = ff.is_enabled
        FROM grac_practice.feature_flag ff
        JOIN grac_practice.feature_flag_master m ON m.feature_flag_id = ff.feature_flag_id
        WHERE ff.organization_id = @organization_id
          AND m.feature_code = @feature_code
          AND m.is_active = 1;
    END

    IF @enabled IS NULL
    BEGIN
        SELECT @enabled = default_enabled
        FROM grac_practice.feature_flag_master
        WHERE feature_code = @feature_code
          AND is_active = 1;
    END

    RETURN ISNULL(@enabled, 0);
END;
GO

-- =====================================================================
-- 4. Seed — register the 11 workflow-layer screens as flags, default OFF
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        (N'screen.tasks',                  N'Task Center',                     N'§12.1.3'),
        (N'screen.waivers',                N'Waivers & Exceptions',            N'§12.1.5'),
        (N'screen.applicability-decision', N'Applicability & NA Decisions',    N'§12.2.5'),
        (N'screen.ownership-tree',         N'Ownership Tree',                  N'§12.4.1'),
        (N'screen.my-assignments',         N'My Assignments (Inbox)',          N'§12.4.2'),
        (N'screen.gap-view',               N'Gap View',                        N'§12.4.3'),
        (N'screen.handover',               N'Handover / Bulk Reassign',        N'§12.4.4'),
        (N'screen.auditor-workbench',      N'Auditor Workbench',               N'§12.5.3'),
        (N'screen.risk-register',          N'Risk Register',                   N'§12.5.5'),
        (N'screen.kri-dashboard',          N'KRI Dashboard',                   N'§12.5.6'),
        (N'screen.adapter-bindings',       N'Assurance Adapter Bindings',      N'§12.3.3')
    ) v(feature_code, feature_name, description)
)
MERGE grac_practice.feature_flag_master AS t
USING src
   ON t.feature_code = src.feature_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (feature_code, feature_name, description, category, default_enabled, entered_by)
    VALUES (src.feature_code, src.feature_name, src.description, N'Screen', 0, 'seed-041');
GO

PRINT '041 feature-flag registry installed.';
GO

SELECT '041 feature-flag migration complete.' AS Message,
       (SELECT COUNT(*) FROM grac_practice.feature_flag_master) AS FeatureFlagCount;
GO

SET NOEXEC OFF;
GO
