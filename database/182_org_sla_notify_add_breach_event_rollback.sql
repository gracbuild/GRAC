-- =====================================================================
-- 182 Organization SLA -- BREACH event -- ROLLBACK
--
-- Restores the two-event CHECK (WARNING / ESCALATION) and restores
-- sp_org_sla_config_notify_role_set's filter to the 179 shape.
--
-- Removes any BREACH rows first so the tightened CHECK can apply.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

DELETE FROM grac_practice.org_sla_config_notify_role
 WHERE notify_event_code = N'BREACH';

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_org_sla_nr_event')
    ALTER TABLE grac_practice.org_sla_config_notify_role
        DROP CONSTRAINT ck_pm_org_sla_nr_event;

ALTER TABLE grac_practice.org_sla_config_notify_role
    ADD CONSTRAINT ck_pm_org_sla_nr_event
        CHECK (notify_event_code IN (N'WARNING', N'ESCALATION'));

COMMIT TRAN;
GO

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
    WHERE UPPER(d.notify_event_code) IN (N'WARNING', N'ESCALATION');

    UPDATE grac_practice.org_sla_config
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_sla_config_id = @org_sla_config_id;

    COMMIT;
END
GO

PRINT '182 rolled back -- BREACH event removed.';
GO
