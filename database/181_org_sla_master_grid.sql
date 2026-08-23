-- =====================================================================
-- 181 Organization SLA -- master-first grid + status actions
--
-- Redesign notes (2026-08-13):
--   The initial design in 178/179 modeled the screen as an "adopt SLA"
--   flow -- user picks a master and creates an org_sla_config. Product
--   direction has since flipped:
--
--     * The grid must list EVERY grac_new.sla_master row for the org.
--     * Each row shows a status: Not Configured / Active / Inactive.
--     * 3-dot menu offers Configure and Inactivate; a configured row
--       becomes Active automatically. Inactivate flips is_active = 0.
--     * Only Active configurations flow into the process selection.
--
-- Additionally the actual grac_new.sla_master schema (confirmed
-- 2026-08-13 from user's DB) has these columns:
--
--     sla_id, sla_code, process_code, classification, duration_value,
--     duration_unit, time_basis, warning_pct, escalation_pct,
--     effective_from, remarks, status, entered_by, entered_dt,
--     updated_by, updated_dt
--
--   -- no `name` column, no `total_sla_days` column. My original
--   defensive discovery in 179 missed this because it looked for
--   `name`/`label`/`display_name`; every row was dropped. This
--   migration replaces `sp_ctrl_sla_master_list` with a
--   schema-accurate implementation.
--
-- What this migration adds / changes:
--   * CREATE OR ALTER sp_ctrl_sla_master_list
--        Reads actual columns. Derives Name from sla_code +
--        classification. Computes TotalSlaDays from duration_value
--        and duration_unit.
--
--   * CREATE PROCEDURE sp_org_sla_master_grid
--        Master-first grid. Returns every grac_new.sla_master row for
--        the org LEFT JOINed with org_sla_config, plus a synthesised
--        ConfigStatusCode column (NotConfigured / Active / Inactive).
--
--   * CREATE PROCEDURE sp_org_sla_config_set_active
--        Toggle handler for the Inactivate / Reactivate menu items.
--
--   * CREATE OR ALTER sp_org_sla_config_upsert
--        Idempotent by (organization_id, sla_master_id) -- no more
--        THROW on re-adopt. Fresh config is inserted with is_active=1.
--        Update path leaves is_active untouched (the explicit
--        Inactivate action is the only way to flip status).
--
-- Depends on: 178 (schema), 179 (procs), grac_practice.organization,
--             grac_practice.record_status_master.
--
-- Rollback: 181_org_sla_master_grid_rollback.sql (restores the 179
--           versions of the two affected procs and drops the two new
--           ones).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_sla_config','U') IS NULL
BEGIN
    RAISERROR('181: run 178 schema + 179 procs first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_ctrl_sla_master_list  (REWRITTEN)
--   Column mapping fixed to the actual grac_new.sla_master shape:
--     Id            = sla_id
--     Code          = sla_code
--     Name          = COALESCE(NULLIF(classification,''), sla_code)
--                     -- master has no `name`; classification is the
--                     -- closest human-readable label. Fall back to
--                     -- the code so the UI never renders blank.
--     Description   = remarks
--     TotalSlaDays  = duration_value converted to days via duration_unit
--
--   Also surfaces the extra columns the new grid needs:
--     ProcessCode, Classification, DurationValue, DurationUnit,
--     TimeBasis, WarningPct, EscalationPct, EffectiveFrom, Status.
--
--   status = 'Active' filter applied so retired masters do not clutter
--   the org grid; ops can override by changing this filter later.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_ctrl_sla_master_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.sla_master','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)        AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS INT)           AS TotalSlaDays,
               CAST(NULL AS NVARCHAR(160)) AS ProcessCode,
               CAST(NULL AS NVARCHAR(40))  AS Classification,
               CAST(NULL AS INT)           AS DurationValue,
               CAST(NULL AS NVARCHAR(20))  AS DurationUnit,
               CAST(NULL AS NVARCHAR(60))  AS TimeBasis,
               CAST(NULL AS DECIMAL(5,2))  AS WarningPct,
               CAST(NULL AS DECIMAL(5,2))  AS EscalationPct,
               CAST(NULL AS DATE)          AS EffectiveFrom,
               CAST(NULL AS NVARCHAR(40))  AS Status
        WHERE 1 = 0;
        RETURN;
    END

    SELECT
        m.sla_id                                             AS Id,
        m.sla_code                                           AS Code,
        COALESCE(NULLIF(LTRIM(RTRIM(m.classification)), N''),
                 m.sla_code)                                 AS Name,
        m.remarks                                            AS Description,
        -- Duration -> days conversion. Master stores value + unit; days
        -- is the canonical unit downstream sweeps operate in, so we
        -- normalise here. Unknown units fall through unchanged.
        CASE UPPER(LEFT(ISNULL(m.duration_unit, N''), 3))
            WHEN 'DAY' THEN m.duration_value
            WHEN 'HOU' THEN CAST(CEILING(m.duration_value / 24.0)    AS INT)
            WHEN 'MIN' THEN CAST(CEILING(m.duration_value / 1440.0)  AS INT)
            WHEN 'WEE' THEN m.duration_value * 7
            WHEN 'MON' THEN m.duration_value * 30
            WHEN 'YEA' THEN m.duration_value * 365
            ELSE m.duration_value
        END                                                  AS TotalSlaDays,
        m.process_code                                       AS ProcessCode,
        m.classification                                     AS Classification,
        m.duration_value                                     AS DurationValue,
        m.duration_unit                                      AS DurationUnit,
        m.time_basis                                         AS TimeBasis,
        m.warning_pct                                        AS WarningPct,
        m.escalation_pct                                     AS EscalationPct,
        m.effective_from                                     AS EffectiveFrom,
        m.status                                             AS Status
    FROM grac_new.sla_master m
    WHERE ISNULL(m.status, N'Active') = N'Active'
    ORDER BY m.sla_code;
END
GO

-- =====================================================================
-- sp_org_sla_master_grid
--   Master-first grid. Every active grac_new.sla_master row for the
--   caller's org, LEFT JOINed with org_sla_config so the caller can
--   render the status badge without a second round-trip.
--
--   ConfigStatusCode:
--     NotConfigured  -- no matching org_sla_config row
--     Active         -- config row exists, is_active = 1
--     Inactive       -- config row exists, is_active = 0
--
--   When a config row exists, the tuned WarningDays / EscalationDays
--   come from the config; when it does not, we fall back to the
--   master's warning_pct / escalation_pct applied to the derived
--   TotalSlaDays so the user sees a sensible pre-populated value in
--   the Configure dialog.
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
        -- Return an empty result set with the full grid shape so the
        -- UI does not crash when Control Management is not yet in
        -- this database.
        SELECT CAST(NULL AS BIGINT)       AS SlaMasterId,
               CAST(NULL AS NVARCHAR(120)) AS SlaMasterCode,
               CAST(NULL AS NVARCHAR(200)) AS SlaMasterName,
               CAST(NULL AS NVARCHAR(1000)) AS Description,
               CAST(NULL AS NVARCHAR(160)) AS ProcessCode,
               CAST(NULL AS NVARCHAR(40))  AS Classification,
               CAST(NULL AS INT)           AS DurationValue,
               CAST(NULL AS NVARCHAR(20))  AS DurationUnit,
               CAST(NULL AS NVARCHAR(60))  AS TimeBasis,
               CAST(NULL AS DECIMAL(5,2))  AS WarningPct,
               CAST(NULL AS DECIMAL(5,2))  AS EscalationPct,
               CAST(NULL AS INT)           AS TotalSlaDays,
               CAST(NULL AS DATE)          AS EffectiveFrom,
               CAST(NULL AS BIGINT)        AS OrgSlaConfigId,
               CAST(NULL AS NVARCHAR(30))  AS ConfigStatusCode,
               CAST(NULL AS NVARCHAR(30))  AS ConfigStatusLabel,
               CAST(NULL AS INT)           AS WarningBeforeDueDays,
               CAST(NULL AS INT)           AS EscalationAfterDueDays,
               CAST(NULL AS INT)           AS NotifyRoleCount,
               CAST(NULL AS INT)           AS ProcessBindingCount,
               CAST(NULL AS DATETIME2)     AS ConfiguredDt
        WHERE 1 = 0;
        RETURN;
    END

    -- Build the derived master rows first so the LEFT JOIN downstream
    -- can reuse the days computation without repeating the CASE.
    ;WITH master_view AS (
        SELECT
            m.sla_id                                             AS SlaMasterId,
            m.sla_code                                           AS SlaMasterCode,
            COALESCE(NULLIF(LTRIM(RTRIM(m.classification)), N''),
                     m.sla_code)                                 AS SlaMasterName,
            m.remarks                                            AS Description,
            m.process_code                                       AS ProcessCode,
            m.classification                                     AS Classification,
            m.duration_value                                     AS DurationValue,
            m.duration_unit                                      AS DurationUnit,
            m.time_basis                                         AS TimeBasis,
            m.warning_pct                                        AS WarningPct,
            m.escalation_pct                                     AS EscalationPct,
            CASE UPPER(LEFT(ISNULL(m.duration_unit, N''), 3))
                WHEN 'DAY' THEN m.duration_value
                WHEN 'HOU' THEN CAST(CEILING(m.duration_value / 24.0)    AS INT)
                WHEN 'MIN' THEN CAST(CEILING(m.duration_value / 1440.0)  AS INT)
                WHEN 'WEE' THEN m.duration_value * 7
                WHEN 'MON' THEN m.duration_value * 30
                WHEN 'YEA' THEN m.duration_value * 365
                ELSE m.duration_value
            END                                                  AS TotalSlaDays,
            m.effective_from                                     AS EffectiveFrom
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
        v.TimeBasis,
        v.WarningPct,
        v.EscalationPct,
        v.TotalSlaDays,
        v.EffectiveFrom,
        c.org_sla_config_id                                    AS OrgSlaConfigId,
        CASE
            WHEN c.org_sla_config_id IS NULL              THEN N'NotConfigured'
            WHEN c.is_active = 1                          THEN N'Active'
            ELSE                                                N'Inactive'
        END                                                    AS ConfigStatusCode,
        CASE
            WHEN c.org_sla_config_id IS NULL              THEN N'Not Configured'
            WHEN c.is_active = 1                          THEN N'Active'
            ELSE                                                N'Inactive'
        END                                                    AS ConfigStatusLabel,
        -- Tuned thresholds when configured; sensible default derived
        -- from master pct otherwise so the dialog opens with useful
        -- pre-filled values.
        COALESCE(
            c.warning_before_due_days,
            CASE WHEN v.WarningPct IS NOT NULL AND v.TotalSlaDays IS NOT NULL
                 THEN CAST(CEILING(v.TotalSlaDays * v.WarningPct / 100.0) AS INT)
                 ELSE 0 END
        )                                                      AS WarningBeforeDueDays,
        COALESCE(
            c.escalation_after_due_days,
            CASE WHEN v.EscalationPct IS NOT NULL AND v.TotalSlaDays IS NOT NULL
                 THEN CAST(CEILING(v.TotalSlaDays * v.EscalationPct / 100.0) AS INT)
                 ELSE 0 END
        )                                                      AS EscalationAfterDueDays,
        ISNULL((SELECT COUNT(*)
                  FROM grac_practice.org_sla_config_notify_role n
                 WHERE n.org_sla_config_id = c.org_sla_config_id
                   AND n.is_active = 1), 0)                    AS NotifyRoleCount,
        ISNULL((SELECT COUNT(*)
                  FROM grac_practice.org_sla_process_binding b
                 WHERE b.org_sla_config_id = c.org_sla_config_id
                   AND b.is_active = 1), 0)                    AS ProcessBindingCount,
        COALESCE(c.updated_dt, c.entered_dt)                   AS ConfiguredDt
    FROM master_view v
    LEFT JOIN grac_practice.org_sla_config c
           ON c.sla_master_id   = v.SlaMasterId
          AND c.organization_id = @organization_id
    ORDER BY
        -- Not Configured first so the operator sees pending work at
        -- the top; then Active, then Inactive; alpha within each.
        CASE WHEN c.org_sla_config_id IS NULL THEN 0
             WHEN c.is_active = 1             THEN 1
             ELSE                                  2 END,
        v.SlaMasterCode;
END
GO

-- =====================================================================
-- sp_org_sla_config_set_active
--   Toggles is_active on an existing org_sla_config row. The caller
--   passes @sla_master_id (grid identity) rather than
--   @org_sla_config_id so the same handler works from the "Not
--   Configured" state (which does not yet have a config row -- in
--   that case we throw a friendly error so the UI can hint the user
--   to Configure first).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_set_active
    @organization_id BIGINT,
    @sla_master_id   BIGINT,
    @is_active       BIT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @sla_master_id IS NULL
        THROW 53820, 'organization_id and sla_master_id are required.', 1;
    IF @is_active IS NULL
        THROW 53821, 'is_active is required (0 or 1).', 1;

    DECLARE @config_id BIGINT = (
        SELECT TOP 1 org_sla_config_id
        FROM grac_practice.org_sla_config
        WHERE organization_id = @organization_id
          AND sla_master_id   = @sla_master_id);

    IF @config_id IS NULL
        THROW 53822,
            'This SLA has no configuration yet. Configure it first before activating or inactivating.', 1;

    UPDATE grac_practice.org_sla_config
    SET is_active  = @is_active,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_sla_config_id = @config_id;
END
GO

-- =====================================================================
-- sp_org_sla_config_upsert  (REWRITTEN)
--   Now idempotent by (organization_id, sla_master_id):
--     * No existing config row -> INSERT with is_active = 1 (a fresh
--       configuration is Active by design).
--     * Existing row (Active or Inactive) -> UPDATE thresholds / notes
--       ONLY; is_active is untouched so the explicit
--       Activate / Inactivate action remains the single source of
--       truth for status transitions.
--
--   @org_sla_config_id is retained as an input for backward
--   compatibility with the earlier code path but is now derived from
--   (organization_id, sla_master_id) when NULL, and validated when
--   supplied.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_upsert
    @organization_id            BIGINT,
    @org_sla_config_id          BIGINT        = NULL,
    @sla_master_id              BIGINT,
    @sla_master_code            NVARCHAR(120) = NULL,
    @sla_master_name            NVARCHAR(200) = NULL,
    @total_sla_days             INT           = NULL,
    @warning_before_due_days    INT,
    @escalation_after_due_days  INT,
    @notes                      NVARCHAR(1000) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @out_org_sla_config_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @sla_master_id IS NULL
        THROW 53783, 'organization_id and sla_master_id are required.', 1;
    IF @warning_before_due_days IS NULL OR @warning_before_due_days < 0
        THROW 53784, 'warning_before_due_days must be >= 0.', 1;
    IF @escalation_after_due_days IS NULL OR @escalation_after_due_days < 0
        THROW 53785, 'escalation_after_due_days must be >= 0.', 1;
    IF @total_sla_days IS NOT NULL AND @warning_before_due_days > @total_sla_days
        THROW 53786, 'warning_before_due_days cannot exceed total_sla_days.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- Locate an existing row (by explicit id first, else by natural
    -- key). Either path lands us in the same UPDATE branch.
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
        -- Isolation guard when caller supplied id directly.
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.org_sla_config
            WHERE org_sla_config_id = @existing_id
              AND organization_id   = @organization_id
              AND sla_master_id     = @sla_master_id)
            THROW 53788,
                'SLA config not found for this organization / master.', 1;
    END

    BEGIN TRAN;

    IF @existing_id IS NULL
    BEGIN
        -- First-time configuration -> Active.
        INSERT INTO grac_practice.org_sla_config
            (organization_id, sla_master_id, sla_master_code, sla_master_name,
             total_sla_days, warning_before_due_days, escalation_after_due_days,
             notes, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @sla_master_id, @sla_master_code, @sla_master_name,
             @total_sla_days, @warning_before_due_days, @escalation_after_due_days,
             @notes, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @out_org_sla_config_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- Re-configuration -> keep is_active as-is (explicit
        -- Activate/Inactivate is the only way to change status).
        UPDATE grac_practice.org_sla_config
        SET sla_master_code           = COALESCE(@sla_master_code, sla_master_code),
            sla_master_name           = COALESCE(@sla_master_name, sla_master_name),
            total_sla_days            = @total_sla_days,
            warning_before_due_days   = @warning_before_due_days,
            escalation_after_due_days = @escalation_after_due_days,
            notes                     = @notes,
            updated_by                = @actor,
            updated_dt                = SYSUTCDATETIME()
        WHERE org_sla_config_id = @existing_id;

        SET @out_org_sla_config_id = @existing_id;
    END

    COMMIT;
END
GO

PRINT '181 Organization SLA master-first grid + status actions deployed.';
GO
