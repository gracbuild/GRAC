-- =====================================================================
-- 186 rollback -- restore the org_sla_process_binding surface
--
-- Recreates sla_process_type_master + org_sla_process_binding + their
-- procs to the post-183 shape (pct + time_basis contract). Grid /
-- list / get procs are restored to include ProcessBindingCount + the
-- 3rd result set. Data cannot be recovered.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Recreate sla_process_type_master + seed rows.
IF OBJECT_ID('grac_practice.sla_process_type_master','U') IS NULL
CREATE TABLE grac_practice.sla_process_type_master(
    sla_process_type_id   INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_sla_process_type PRIMARY KEY,
    process_type_code     NVARCHAR(60)  NOT NULL
        CONSTRAINT uq_pm_sla_process_type_code UNIQUE,
    process_type_name     NVARCHAR(200) NOT NULL,
    description           NVARCHAR(500) NULL,
    scope_ref_hint        NVARCHAR(200) NULL,
    display_order         INT           NOT NULL DEFAULT 100,
    is_active             BIT           NOT NULL DEFAULT 1,
    entered_by            NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt            DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by            NVARCHAR(100) NULL,
    updated_dt            DATETIME2     NULL);
GO

;WITH src AS (
    SELECT * FROM (VALUES
        (N'GAP',         N'Gap Analysis',         N'Custom gap lifecycle SLA.',       10),
        (N'TASK',        N'Task',                 N'Practice task engine SLA.',       20),
        (N'OBSERVATION', N'Assurance Observation',N'Assurance observation SLA.',      30),
        (N'EXCEPTION',   N'Exception',            N'Exception centre closure SLA.',   40)
    ) t(process_type_code, process_type_name, description, display_order)
)
MERGE grac_practice.sla_process_type_master AS tgt
USING src ON tgt.process_type_code = src.process_type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (process_type_code, process_type_name, description, display_order, entered_by)
    VALUES (src.process_type_code, src.process_type_name, src.description, src.display_order, 'seed-186-rb');
GO

-- 2. Recreate org_sla_process_binding.
IF OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NULL
CREATE TABLE grac_practice.org_sla_process_binding(
    org_sla_process_binding_id  BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_sla_process_binding PRIMARY KEY,
    organization_id             BIGINT        NOT NULL,
    org_sla_config_id           BIGINT        NOT NULL,
    process_type_code           NVARCHAR(60)  NOT NULL,
    process_scope_ref_id        BIGINT        NULL,
    process_scope_label         NVARCHAR(200) NULL,
    is_active                   BIT           NOT NULL DEFAULT 1,
    record_status_id            INT           NOT NULL,
    entered_by                  NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt                  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2     NULL,
    CONSTRAINT fk_pm_org_sla_bind_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_org_sla_bind_config
        FOREIGN KEY(org_sla_config_id) REFERENCES grac_practice.org_sla_config(org_sla_config_id),
    CONSTRAINT fk_pm_org_sla_bind_process_type
        FOREIGN KEY(process_type_code) REFERENCES grac_practice.sla_process_type_master(process_type_code),
    CONSTRAINT fk_pm_org_sla_bind_record_status
        FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id));
GO

-- Procs, grid/list/get restore -- re-run migrations 179 / 181 / 183 to
-- get their full-shape versions back rather than duplicating them
-- inline here (the shapes span ~300 lines each and duplication is a
-- known drift hazard).
PRINT '186 rollback -- tables restored. Re-run 179 / 181 / 183 to restore procs.';
GO
