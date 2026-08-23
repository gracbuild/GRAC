-- =====================================================================
-- 186 Remove the org_sla_process_binding surface
--
-- Bind Processes was originally scaffolded to let an org bind an SLA
-- config to one or more process types (GAP / TASK / OBSERVATION /
-- EXCEPTION). The gap flow ultimately settled on a different lookup
-- pattern (severity -> sla_master.classification -> org_sla_config
-- via sp_org_sla_match_for_severity, 184), and no other process type
-- currently reads the bindings. That leaves sp_org_sla_config_for_process
-- + org_sla_process_binding + sla_process_type_master as dead surface --
-- rows nobody reads and a UI action operators find confusing.
--
-- This migration removes them cleanly. If a future feature (Task SLA,
-- Observation SLA, ...) needs the resolver back, we re-introduce it
-- alongside the caller so both go live together.
--
-- What this drops:
--   * PROC sp_org_sla_config_for_process
--   * PROC sp_org_sla_process_binding_set
--   * PROC sp_org_sla_process_type_list
--   * TABLE grac_practice.org_sla_process_binding  (child of config)
--   * TABLE grac_practice.sla_process_type_master  (leaf catalog)
--
-- What this rewrites (to stop emitting binding counts / 3rd result set):
--   * sp_org_sla_master_grid  -- drops ProcessBindingCount column
--   * sp_org_sla_config_list  -- drops ProcessBindingCount column
--   * sp_org_sla_config_get   -- drops 3rd result set (bindings)
--
-- Rollback: 186_..._rollback.sql restores the tables + procs +
-- previous grid/list/get shapes. Re-adopt data manually if needed.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Drop procs first (avoids FK/dependency reordering headaches).
IF OBJECT_ID('grac_practice.sp_org_sla_config_for_process','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_for_process;
IF OBJECT_ID('grac_practice.sp_org_sla_process_binding_set','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_process_binding_set;
IF OBJECT_ID('grac_practice.sp_org_sla_process_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_process_type_list;
GO

-- 2. Drop tables (binding is the child of both config + type_master).
IF OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NOT NULL
    DROP TABLE grac_practice.org_sla_process_binding;
GO

IF OBJECT_ID('grac_practice.sla_process_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.sla_process_type_master;
GO

-- 3. Rewrite sp_org_sla_master_grid without ProcessBindingCount.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_master_grid
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53810, 'organization_id is required.', 1;

    IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS SlaMasterId,
               CAST(NULL AS NVARCHAR(120)) AS SlaMasterCode,
               CAST(NULL AS NVARCHAR(200)) AS SlaMasterName,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS NVARCHAR(160)) AS ProcessCode,
               CAST(NULL AS NVARCHAR(40))  AS Classification,
               CAST(NULL AS INT)           AS DurationValue,
               CAST(NULL AS NVARCHAR(20))  AS DurationUnit,
               CAST(NULL AS NVARCHAR(60))  AS MasterTimeBasis,
               CAST(NULL AS DECIMAL(5,2))  AS MasterWarningPct,
               CAST(NULL AS DECIMAL(5,2))  AS MasterEscalationPct,
               CAST(NULL AS INT)           AS TotalSlaDays,
               CAST(NULL AS DATE)          AS EffectiveFrom,
               CAST(NULL AS BIGINT)        AS OrgSlaConfigId,
               CAST(NULL AS NVARCHAR(30))  AS ConfigStatusCode,
               CAST(NULL AS NVARCHAR(30))  AS ConfigStatusLabel,
               CAST(NULL AS DECIMAL(5,2))  AS WarningPct,
               CAST(NULL AS DECIMAL(5,2))  AS EscalationPct,
               CAST(NULL AS NVARCHAR(60))  AS TimeBasis,
               CAST(NULL AS INT)           AS NotifyRoleCount,
               CAST(NULL AS DATETIME2)     AS ConfiguredDt
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH master_view AS (
        SELECT
            m.sla_id             AS SlaMasterId,
            m.sla_code           AS SlaMasterCode,
            COALESCE(NULLIF(LTRIM(RTRIM(m.classification)), N''),
                     m.sla_code) AS SlaMasterName,
            m.remarks            AS Description,
            m.process_code       AS ProcessCode,
            m.classification     AS Classification,
            m.duration_value     AS DurationValue,
            m.duration_unit      AS DurationUnit,
            m.time_basis         AS MasterTimeBasis,
            m.warning_pct        AS MasterWarningPct,
            m.escalation_pct     AS MasterEscalationPct,
            CASE UPPER(LEFT(ISNULL(m.duration_unit, N''), 3))
                WHEN 'DAY' THEN m.duration_value
                WHEN 'HOU' THEN CAST(CEILING(m.duration_value / 24.0)    AS INT)
                WHEN 'MIN' THEN CAST(CEILING(m.duration_value / 1440.0)  AS INT)
                WHEN 'WEE' THEN m.duration_value * 7
                WHEN 'MON' THEN m.duration_value * 30
                WHEN 'YEA' THEN m.duration_value * 365
                ELSE m.duration_value
            END                  AS TotalSlaDays,
            m.effective_from     AS EffectiveFrom
        FROM grac_new.sla_master m
        WHERE ISNULL(m.status, N'Active') = N'Active'
          AND (@search IS NULL
               OR m.sla_code       LIKE '%' + @search + '%'
               OR m.classification LIKE '%' + @search + '%'
               OR m.process_code   LIKE '%' + @search + '%')
    )
    SELECT
        v.SlaMasterId,
        v.SlaMasterCode,
        v.SlaMasterName,
        v.Description,
        v.ProcessCode,
        v.Classification,
        v.DurationValue,
        v.DurationUnit,
        v.MasterTimeBasis,
        v.MasterWarningPct,
        v.MasterEscalationPct,
        v.TotalSlaDays,
        v.EffectiveFrom,
        c.org_sla_config_id AS OrgSlaConfigId,
        CASE
            WHEN c.org_sla_config_id IS NULL THEN N'NotConfigured'
            WHEN c.is_active = 1             THEN N'Active'
            ELSE                                  N'Inactive'
        END                 AS ConfigStatusCode,
        CASE
            WHEN c.org_sla_config_id IS NULL THEN N'Not Configured'
            WHEN c.is_active = 1             THEN N'Active'
            ELSE                                  N'Inactive'
        END                 AS ConfigStatusLabel,
        COALESCE(c.warning_pct,    v.MasterWarningPct)    AS WarningPct,
        COALESCE(c.escalation_pct, v.MasterEscalationPct) AS EscalationPct,
        COALESCE(c.time_basis,     v.MasterTimeBasis)     AS TimeBasis,
        ISNULL((SELECT COUNT(*)
                  FROM grac_practice.org_sla_config_notify_role n
                 WHERE n.org_sla_config_id = c.org_sla_config_id
                   AND n.is_active = 1), 0) AS NotifyRoleCount,
        COALESCE(c.updated_dt, c.entered_dt) AS ConfiguredDt
    FROM master_view v
    LEFT JOIN grac_practice.org_sla_config c
           ON c.sla_master_id   = v.SlaMasterId
          AND c.organization_id = @organization_id
    ORDER BY
        CASE WHEN c.org_sla_config_id IS NULL THEN 0
             WHEN c.is_active = 1             THEN 1
             ELSE                                  2 END,
        v.SlaMasterCode;
END
GO

-- 4. Rewrite sp_org_sla_config_list without ProcessBindingCount.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53780, 'organization_id is required.', 1;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT c.org_sla_config_id,
               c.organization_id,
               c.sla_master_id,
               c.sla_master_code,
               c.sla_master_name,
               c.total_sla_days,
               c.warning_pct,
               c.escalation_pct,
               c.time_basis,
               c.notes,
               c.is_active,
               c.entered_by, c.entered_dt, c.updated_by, c.updated_dt,
               (SELECT COUNT(*)
                  FROM grac_practice.org_sla_config_notify_role n
                 WHERE n.org_sla_config_id = c.org_sla_config_id
                   AND n.is_active = 1) AS notify_role_count
        FROM grac_practice.org_sla_config c
        WHERE c.organization_id = @organization_id
          AND c.is_active       = 1
          AND (@search IS NULL
               OR c.sla_master_name LIKE '%' + @search + '%'
               OR c.sla_master_code LIKE '%' + @search + '%')
    )
    SELECT
        org_sla_config_id AS OrgSlaConfigId,
        organization_id   AS OrganizationId,
        sla_master_id     AS SlaMasterId,
        sla_master_code   AS SlaMasterCode,
        sla_master_name   AS SlaMasterName,
        total_sla_days    AS TotalSlaDays,
        warning_pct       AS WarningPct,
        escalation_pct    AS EscalationPct,
        time_basis        AS TimeBasis,
        notes             AS Notes,
        notify_role_count AS NotifyRoleCount,
        entered_by        AS EnteredBy,
        entered_dt        AS EnteredDt,
        updated_by        AS UpdatedBy,
        updated_dt        AS UpdatedDt,
        (SELECT COUNT(*) FROM filtered) AS TotalCount
    FROM filtered
    ORDER BY sla_master_name, org_sla_config_id
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 5. Rewrite sp_org_sla_config_get -- drop 3rd result set (bindings).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_get
    @organization_id   BIGINT,
    @org_sla_config_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @org_sla_config_id IS NULL
        THROW 53781, 'organization_id and org_sla_config_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_sla_config
        WHERE org_sla_config_id = @org_sla_config_id
          AND organization_id   = @organization_id)
        THROW 53782, 'SLA config not found for this organization.', 1;

    -- Result set 1: header
    SELECT
        c.org_sla_config_id AS OrgSlaConfigId,
        c.organization_id   AS OrganizationId,
        c.sla_master_id     AS SlaMasterId,
        c.sla_master_code   AS SlaMasterCode,
        c.sla_master_name   AS SlaMasterName,
        c.total_sla_days    AS TotalSlaDays,
        c.warning_pct       AS WarningPct,
        c.escalation_pct    AS EscalationPct,
        c.time_basis        AS TimeBasis,
        c.notes             AS Notes,
        c.entered_by        AS EnteredBy,
        c.entered_dt        AS EnteredDt,
        c.updated_by        AS UpdatedBy,
        c.updated_dt        AS UpdatedDt
    FROM grac_practice.org_sla_config c
    WHERE c.org_sla_config_id = @org_sla_config_id;

    -- Result set 2: notify roles
    SELECT
        n.org_sla_config_notify_role_id AS NotifyRoleId,
        n.notify_event_code             AS NotifyEventCode,
        n.role_id                       AS RoleId,
        n.role_name                     AS RoleName
    FROM grac_practice.org_sla_config_notify_role n
    WHERE n.org_sla_config_id = @org_sla_config_id
      AND n.is_active         = 1
    ORDER BY n.notify_event_code, n.role_name, n.role_id;
END
GO

PRINT '186 org_sla_process_binding surface removed.';
GO
