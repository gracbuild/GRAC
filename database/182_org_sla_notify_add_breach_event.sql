-- =====================================================================
-- 182 Organization SLA -- add BREACH as a third notify event
--
-- Migration 178 seeded the CHECK constraint with two events:
--    notify_event_code IN (N'WARNING', N'ESCALATION')
--
-- Product direction now requires a third event -- BREACH -- so operators
-- can notify a distinct set of roles when the SLA is crossed (as
-- opposed to the pre-due WARNING nudge and the post-breach ESCALATION
-- follow-up). BREACH fires exactly at due_date; WARNING fires
-- warning_before_due_days earlier; ESCALATION fires
-- escalation_after_due_days later. All three read from the same
-- org_sla_config row.
--
-- Changes:
--   1. DROP + re-add ck_pm_org_sla_nr_event with WARNING/BREACH/ESCALATION.
--   2. CREATE OR ALTER sp_org_sla_config_notify_role_set to allow the
--      new event code through the filter (previously dropped any row
--      whose event code was not WARNING or ESCALATION).
--
-- No data migration: no existing row uses N'BREACH' so the widened
-- CHECK cannot fail. If any legacy row somehow already carries a
-- non-conforming value, the ALTER TABLE ... ADD CHECK statement will
-- raise before commit -- do a sanity SELECT beforehand.
--
-- Rollback: 182_org_sla_notify_add_breach_event_rollback.sql restores
-- the two-event CHECK and the original proc filter.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NULL
BEGIN
    RAISERROR('182: run 178 schema first.', 16, 1);
    RETURN;
END
GO

-- Safety scan: any row that would violate the new CHECK?
IF EXISTS (
    SELECT 1 FROM grac_practice.org_sla_config_notify_role
    WHERE notify_event_code NOT IN (N'WARNING', N'BREACH', N'ESCALATION'))
BEGIN
    RAISERROR('182: notify_event_code values exist outside {WARNING, BREACH, ESCALATION}. Clean these up before running 182.', 16, 1);
    RETURN;
END
GO

BEGIN TRAN;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_nr_event')
    ALTER TABLE grac_practice.org_sla_config_notify_role
        DROP CONSTRAINT ck_pm_org_sla_nr_event;

ALTER TABLE grac_practice.org_sla_config_notify_role
    ADD CONSTRAINT ck_pm_org_sla_nr_event
        CHECK (notify_event_code IN (N'WARNING', N'BREACH', N'ESCALATION'));

COMMIT TRAN;
GO

-- =====================================================================
-- sp_org_sla_config_notify_role_set  (widened filter)
--   Same shape as 179; only the terminal WHERE clause changes to
--   accept BREACH alongside WARNING and ESCALATION.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_sla_config_notify_role_set
    @organization_id   BIGINT,
    @org_sla_config_id BIGINT,
    @roles_json        NVARCHAR(MAX),
    @actor             NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @org_sla_config_id IS NULL
        THROW 53790, 'organization_id and org_sla_config_id are required.', 1;
    IF @roles_json IS NULL SET @roles_json = N'[]';
    IF ISJSON(@roles_json) = 0
        THROW 53791, 'roles_json is not a valid JSON document.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_sla_config
        WHERE org_sla_config_id = @org_sla_config_id
          AND organization_id   = @organization_id
          AND is_active         = 1)
        THROW 53792, 'SLA config not found for this organization.', 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.org_sla_config_notify_role
    WHERE org_sla_config_id = @org_sla_config_id;

    ;WITH src AS (
        SELECT x.notifyEventCode AS notify_event_code,
               x.roleId          AS role_id
        FROM OPENJSON(@roles_json)
        WITH (
            notifyEventCode NVARCHAR(30) '$.notifyEventCode',
            roleId          BIGINT       '$.roleId'
        ) x
        WHERE x.notifyEventCode IS NOT NULL
          AND x.roleId IS NOT NULL
    ),
    dedup AS (
        SELECT DISTINCT notify_event_code, role_id FROM src
    )
    INSERT INTO grac_practice.org_sla_config_notify_role
        (org_sla_config_id, organization_id, notify_event_code,
         role_id, role_name, is_active, entered_by, entered_dt)
    SELECT
        @org_sla_config_id,
        @organization_id,
        UPPER(d.notify_event_code),
        d.role_id,
        r.role_name,
        1,
        @actor,
        SYSUTCDATETIME()
    FROM dedup d
    LEFT JOIN grac_practice.organization_role r
           ON r.role_id = d.role_id
          AND r.organization_id = @organization_id
    WHERE UPPER(d.notify_event_code) IN (N'WARNING', N'BREACH', N'ESCALATION');

    UPDATE grac_practice.org_sla_config
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_sla_config_id = @org_sla_config_id;

    COMMIT;
END
GO

PRINT '182 Organization SLA notify: BREACH event enabled.';
GO
