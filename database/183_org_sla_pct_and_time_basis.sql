-- =====================================================================
-- 183 Organization SLA -- switch tunables from days to percentages,
-- and expose time_basis as an org-editable field.
--
-- Rationale:
--   grac_new.sla_master already carries the org-tuneable dimensions
--   as PERCENTAGES (warning_pct, escalation_pct) plus a `time_basis`
--   column that says whether the SLA duration is counted in Calendar
--   Days or Business Days. The correct org override, therefore, is
--   the percentage and the time_basis, not a derived "days before /
--   after due" pair. Days are downstream (a computed convenience).
--
-- Schema change:
--   * ADD warning_pct    DECIMAL(5,2) NULL   (0..100)
--   * ADD escalation_pct DECIMAL(5,2) NULL   (0..100)
--   * ADD time_basis     NVARCHAR(60) NULL   (snapshot from master, override allowed)
--   * DROP CHECK ck_pm_org_sla_thresholds
--   * DROP CHECK ck_pm_org_sla_warning_within_total
--   * DROP DEFAULT df_pm_org_sla_warning     on warning_before_due_days
--   * DROP DEFAULT df_pm_org_sla_escalation  on escalation_after_due_days
--   * DROP COLUMN warning_before_due_days
--   * DROP COLUMN escalation_after_due_days
--   * ADD CHECK ck_pm_org_sla_warning_pct        (0..100 or NULL)
--   * ADD CHECK ck_pm_org_sla_escalation_pct     (0..100 or NULL)
--   * ADD CHECK ck_pm_org_sla_pct_order          (warning <= escalation)
--
-- Proc changes: sp_org_sla_config_upsert, _list, _get, _master_grid,
-- _for_process all switched to the pct + time_basis contract.
--
-- Data note: warning_before_due_days / escalation_after_due_days rows
-- are NOT backfilled to the new pct columns. Any existing config rows
-- (this module is not yet live) will end up with NULL warning_pct /
-- escalation_pct until the user re-configures. UI opens the dialog
-- with the master's warning_pct / escalation_pct as sensible defaults.
--
-- Rollback: 183_..._rollback.sql restores the day columns + old
-- procs and drops the three new columns.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
BEGIN
    RAISERROR('183: run 178 schema first.', 16, 1);
    RETURN;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Drop CHECK constraints that reference the old day columns.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_thresholds')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT ck_pm_org_sla_thresholds;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_warning_within_total')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT ck_pm_org_sla_warning_within_total;

-- =====================================================================
-- 2. Drop DEFAULT constraints on the old day columns before DROP COLUMN.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_org_sla_warning')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT df_pm_org_sla_warning;

IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_org_sla_escalation')
    ALTER TABLE grac_practice.org_sla_config DROP CONSTRAINT df_pm_org_sla_escalation;

-- =====================================================================
-- 2b. Drop the covering index that INCLUDE-references the old day
--     columns. Without this DROP INDEX, the DROP COLUMN below fails
--     with Msg 5074 (index dependency). Recreated with the new
--     columns after the DROP COLUMN completes.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_pm_org_sla_org'
             AND object_id = OBJECT_ID('grac_practice.org_sla_config'))
    DROP INDEX ix_pm_org_sla_org ON grac_practice.org_sla_config;

-- =====================================================================
-- 3. Add the new columns (idempotent).
-- =====================================================================
IF COL_LENGTH('grac_practice.org_sla_config','warning_pct') IS NULL
    ALTER TABLE grac_practice.org_sla_config
        ADD warning_pct DECIMAL(5,2) NULL;

IF COL_LENGTH('grac_practice.org_sla_config','escalation_pct') IS NULL
    ALTER TABLE grac_practice.org_sla_config
        ADD escalation_pct DECIMAL(5,2) NULL;

IF COL_LENGTH('grac_practice.org_sla_config','time_basis') IS NULL
    ALTER TABLE grac_practice.org_sla_config
        ADD time_basis NVARCHAR(60) NULL;

COMMIT TRAN;
GO

-- =====================================================================
-- 4. Drop the old day columns now that DEFAULTs are gone.
-- =====================================================================
IF COL_LENGTH('grac_practice.org_sla_config','warning_before_due_days') IS NOT NULL
    ALTER TABLE grac_practice.org_sla_config DROP COLUMN warning_before_due_days;
GO

IF COL_LENGTH('grac_practice.org_sla_config','escalation_after_due_days') IS NOT NULL
    ALTER TABLE grac_practice.org_sla_config DROP COLUMN escalation_after_due_days;
GO

-- =====================================================================
-- 4b. Recreate the covering index with the NEW columns in the
--     INCLUDE list. Same key columns (organization_id, is_active)
--     as migration 178; the INCLUDE list now covers the pct + time
--     basis columns the grid + resolver read.
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_org_sla_org'
                 AND object_id = OBJECT_ID('grac_practice.org_sla_config'))
    CREATE INDEX ix_pm_org_sla_org
        ON grac_practice.org_sla_config(organization_id, is_active)
        INCLUDE (sla_master_id, sla_master_name, warning_pct,
                 escalation_pct, time_basis);
GO

-- =====================================================================
-- 5. Add new CHECK constraints (each nullable so an in-progress
--    config can be saved before the operator sets the pct values).
--    Order guard forces warning_pct <= escalation_pct when both set,
--    matching the WARNING -> ESCALATION -> BREACH order the resolver
--    fires them in.
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_warning_pct')
    ALTER TABLE grac_practice.org_sla_config
        ADD CONSTRAINT ck_pm_org_sla_warning_pct
            CHECK (warning_pct IS NULL OR (warning_pct >= 0 AND warning_pct <= 100));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_escalation_pct')
    ALTER TABLE grac_practice.org_sla_config
        ADD CONSTRAINT ck_pm_org_sla_escalation_pct
            CHECK (escalation_pct IS NULL OR (escalation_pct >= 0 AND escalation_pct <= 100));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_pct_order')
    ALTER TABLE grac_practice.org_sla_config
        ADD CONSTRAINT ck_pm_org_sla_pct_order
            CHECK (warning_pct IS NULL OR escalation_pct IS NULL
                   OR warning_pct <= escalation_pct);
GO

-- =====================================================================
-- 6. sp_org_sla_config_upsert -- new contract
--    Now accepts @warning_pct, @escalation_pct, @time_basis. Fresh
--    row created with is_active = 1 (same policy as 181).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_upsert
    @organization_id            BIGINT,
    @org_sla_config_id          BIGINT        = NULL,
    @sla_master_id              BIGINT,
    @sla_master_code            NVARCHAR(120) = NULL,
    @sla_master_name            NVARCHAR(200) = NULL,
    @total_sla_days             INT           = NULL,
    @warning_pct                DECIMAL(5,2),
    @escalation_pct             DECIMAL(5,2),
    @time_basis                 NVARCHAR(60)  = NULL,
    @notes                      NVARCHAR(1000) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @out_org_sla_config_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @sla_master_id IS NULL
        THROW 53783, 'organization_id and sla_master_id are required.', 1;
    IF @warning_pct IS NULL OR @warning_pct < 0 OR @warning_pct > 100
        THROW 53784, 'warning_pct must be between 0 and 100.', 1;
    IF @escalation_pct IS NULL OR @escalation_pct < 0 OR @escalation_pct > 100
        THROW 53785, 'escalation_pct must be between 0 and 100.', 1;
    IF @warning_pct > @escalation_pct
        THROW 53786, 'warning_pct cannot exceed escalation_pct (WARNING must fire before ESCALATION).', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @existing_id BIGINT = @org_sla_config_id;
    IF @existing_id IS NULL
    BEGIN
        SELECT TOP 1 @existing_id = org_sla_config_id
        FROM grac_practice.org_sla_config
        WHERE organization_id = @organization_id
          AND sla_master_id   = @sla_master_id;
    END
    ELSE
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE org_sla_config_id = @existing_id
              AND organization_id   = @organization_id
              AND sla_master_id     = @sla_master_id)
            THROW 53788, 'SLA config not found for this organization / master.', 1;
    END

    BEGIN TRAN;

    IF @existing_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_sla_config
            (organization_id, sla_master_id, sla_master_code, sla_master_name,
             total_sla_days, warning_pct, escalation_pct, time_basis,
             notes, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @sla_master_id, @sla_master_code, @sla_master_name,
             @total_sla_days, @warning_pct, @escalation_pct, @time_basis,
             @notes, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @out_org_sla_config_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.org_sla_config
        SET sla_master_code = COALESCE(@sla_master_code, sla_master_code),
            sla_master_name = COALESCE(@sla_master_name, sla_master_name),
            total_sla_days  = @total_sla_days,
            warning_pct     = @warning_pct,
            escalation_pct  = @escalation_pct,
            time_basis      = @time_basis,
            notes           = @notes,
            updated_by      = @actor,
            updated_dt      = SYSUTCDATETIME()
        WHERE org_sla_config_id = @existing_id;

        SET @out_org_sla_config_id = @existing_id;
    END

    COMMIT;
END
GO

-- =====================================================================
-- 7. sp_org_sla_config_list -- swap day columns for pct + time_basis
-- =====================================================================
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
                   AND n.is_active = 1) AS notify_role_count,
               (SELECT COUNT(*)
                  FROM grac_practice.org_sla_process_binding b
                 WHERE b.org_sla_config_id = c.org_sla_config_id
                   AND b.is_active = 1) AS process_binding_count
        FROM grac_practice.org_sla_config c
        WHERE c.organization_id = @organization_id
          AND c.is_active       = 1
          AND (@search IS NULL
               OR c.sla_master_name LIKE '%' + @search + '%'
               OR c.sla_master_code LIKE '%' + @search + '%')
    )
    SELECT
        org_sla_config_id     AS OrgSlaConfigId,
        organization_id       AS OrganizationId,
        sla_master_id         AS SlaMasterId,
        sla_master_code       AS SlaMasterCode,
        sla_master_name       AS SlaMasterName,
        total_sla_days        AS TotalSlaDays,
        warning_pct           AS WarningPct,
        escalation_pct        AS EscalationPct,
        time_basis            AS TimeBasis,
        notes                 AS Notes,
        notify_role_count     AS NotifyRoleCount,
        process_binding_count AS ProcessBindingCount,
        entered_by            AS EnteredBy,
        entered_dt            AS EnteredDt,
        updated_by            AS UpdatedBy,
        updated_dt            AS UpdatedDt,
        (SELECT COUNT(*) FROM filtered) AS TotalCount
    FROM filtered
    ORDER BY sla_master_name, org_sla_config_id
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 8. sp_org_sla_config_get -- same three result sets, updated header
-- =====================================================================
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

    SELECT
        n.org_sla_config_notify_role_id AS NotifyRoleId,
        n.notify_event_code             AS NotifyEventCode,
        n.role_id                       AS RoleId,
        n.role_name                     AS RoleName
    FROM grac_practice.org_sla_config_notify_role n
    WHERE n.org_sla_config_id = @org_sla_config_id
      AND n.is_active         = 1
    ORDER BY n.notify_event_code, n.role_name, n.role_id;

    SELECT
        b.org_sla_process_binding_id AS BindingId,
        b.process_type_code          AS ProcessTypeCode,
        pt.process_type_name         AS ProcessTypeName,
        b.process_scope_ref_id       AS ProcessScopeRefId,
        b.process_scope_label        AS ProcessScopeLabel
    FROM grac_practice.org_sla_process_binding b
    JOIN grac_practice.sla_process_type_master pt
         ON pt.process_type_code = b.process_type_code
    WHERE b.org_sla_config_id = @org_sla_config_id
      AND b.is_active         = 1
    ORDER BY pt.display_order, b.process_scope_ref_id;
END
GO

-- =====================================================================
-- 9. sp_org_sla_master_grid -- swap tuned days for tuned pct;
--    fallback pre-populated values now come DIRECTLY from the master's
--    warning_pct / escalation_pct / time_basis (no derivation needed).
-- =====================================================================
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
               CAST(NULL AS INT)           AS ProcessBindingCount,
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
        -- Effective tunables: fall back to master values when the org
        -- has not (yet) overridden them.
        COALESCE(c.warning_pct,    v.MasterWarningPct)    AS WarningPct,
        COALESCE(c.escalation_pct, v.MasterEscalationPct) AS EscalationPct,
        COALESCE(c.time_basis,     v.MasterTimeBasis)     AS TimeBasis,
        ISNULL((SELECT COUNT(*)
                  FROM grac_practice.org_sla_config_notify_role n
                 WHERE n.org_sla_config_id = c.org_sla_config_id
                   AND n.is_active = 1), 0) AS NotifyRoleCount,
        ISNULL((SELECT COUNT(*)
                  FROM grac_practice.org_sla_process_binding b
                 WHERE b.org_sla_config_id = c.org_sla_config_id
                   AND b.is_active = 1), 0) AS ProcessBindingCount,
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

-- =====================================================================
-- 10. sp_org_sla_config_for_process -- switch to pct + time_basis
--     Downstream sweeps compute event fire times as:
--         warning_at    = start + total * warning_pct    / 100
--         escalation_at = start + total * escalation_pct / 100
--         breach_at     = start + total                    (100%)
--     using days-of-time_basis for "total".
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_for_process
    @organization_id      BIGINT,
    @process_type_code    NVARCHAR(60),
    @process_scope_ref_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @process_type_code IS NULL
        THROW 53797, 'organization_id and process_type_code are required.', 1;

    DECLARE @config_id BIGINT;

    IF @process_scope_ref_id IS NOT NULL
    BEGIN
        SELECT TOP 1 @config_id = b.org_sla_config_id
        FROM grac_practice.org_sla_process_binding b
        WHERE b.organization_id     = @organization_id
          AND b.process_type_code   = @process_type_code
          AND b.process_scope_ref_id = @process_scope_ref_id
          AND b.is_active           = 1;
    END

    IF @config_id IS NULL
    BEGIN
        SELECT TOP 1 @config_id = b.org_sla_config_id
        FROM grac_practice.org_sla_process_binding b
        WHERE b.organization_id     = @organization_id
          AND b.process_type_code   = @process_type_code
          AND b.process_scope_ref_id IS NULL
          AND b.is_active           = 1;
    END

    SELECT
        c.org_sla_config_id AS OrgSlaConfigId,
        c.organization_id   AS OrganizationId,
        c.sla_master_id     AS SlaMasterId,
        c.sla_master_code   AS SlaMasterCode,
        c.sla_master_name   AS SlaMasterName,
        c.total_sla_days    AS TotalSlaDays,
        c.warning_pct       AS WarningPct,
        c.escalation_pct    AS EscalationPct,
        c.time_basis        AS TimeBasis
    FROM grac_practice.org_sla_config c
    WHERE @config_id IS NOT NULL
      AND c.org_sla_config_id = @config_id
      AND c.is_active         = 1;

    SELECT
        n.notify_event_code AS NotifyEventCode,
        n.role_id           AS RoleId,
        n.role_name         AS RoleName
    FROM grac_practice.org_sla_config_notify_role n
    WHERE @config_id IS NOT NULL
      AND n.org_sla_config_id = @config_id
      AND n.is_active         = 1
    ORDER BY n.notify_event_code, n.role_name;
END
GO

PRINT '183 Organization SLA: pct + time_basis contract deployed.';
GO
