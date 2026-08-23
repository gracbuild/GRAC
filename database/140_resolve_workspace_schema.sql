-- =====================================================================
-- 140 Resolve workspace -- obligation adoption schema
--
-- WHAT RESOLVE BECOMES
-- --------------------
-- Resolve was a tabbed workbench keyed on dependency category: pick a
-- register, find the instances that need something from it, resolve one
-- category at a time. That is the register's point of view, not the
-- owner's. The person who actually has to make an instance operational
-- cares about one instance and everything it still needs.
--
-- So Resolve becomes two screens:
--     1. a flat list of instances the signed-in user owns (an
--        organization-scoped admin sees all of them)
--     2. a full-page workspace for one instance, carrying its details,
--        its obligations and its dependencies as separate cards
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
-- grac_practice.practice_instance_obligation -- which published
-- obligations this instance has taken on, and whether it took them as
-- published or with its own parameters.
--
-- WHY A NEW TABLE
-- ---------------
-- Obligations live in GRAC_New and are read-only here: the authority
-- publishes them, the organization does not edit them. But an instance
-- adopting an obligation is an organization decision with organization
-- parameters -- who is responsible here, how often here, how long we
-- keep it here. That decision has nowhere to live today. Writing it back
-- into GRAC_New would corrupt the published master for every subscriber.
--
-- The two flags mirror practice_instance_evidence, which already models
-- exactly this distinction:
--     inherited_from_repository -- came from the published obligation
--     organization_modified     -- the organization changed a parameter
-- Keeping the same pair means "adopted as published" versus "adopted and
-- changed" reads identically for evidence and for obligations, and a
-- future release-diff can ask one question of both tables.
--
-- FREQUENCY IS STORED TWICE, ON PURPOSE
-- -------------------------------------
-- The published obligation's frequency is a GRAC_New.reference_option
-- label; the practice side picks from grac_practice.frequency_master.
-- They are different catalogs. Adopting as published stores the label
-- with no id (nothing in the practice catalog was chosen); editing
-- stores both. Forcing the published label through frequency_master
-- would silently retype an authority's wording.
--
-- Depends on 001/002 (practice_instance, evidence, frequency_master),
-- 122 (dbo.sp_pm_view_obligations_typed -- the obligation projection
-- this workspace reads alongside).
-- Rollback: 140_resolve_workspace_schema_rollback.sql.
-- Procedures: 141_resolve_workspace_procs.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
   OR OBJECT_ID('grac_practice.frequency_master','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('140: prerequisites missing. Run 001 and 002 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    RAISERROR('140: the GRAC_New schema is missing. Obligations are read from it.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- practice_instance_obligation
--
-- obligation_id and release_id are soft references into GRAC_New, not
-- foreign keys -- the same convention every other admin-repository id in
-- this schema follows (repository_requirement_id, repository_control_id,
-- release_id on repository_subscription). obligation_name is snapshotted
-- so a retired or renamed obligation still reads sensibly on the screen
-- and in an audit trail.
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_instance_obligation(
        practice_instance_obligation_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_practice_instance_obligation PRIMARY KEY,
        organization_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_pio_organization
                REFERENCES grac_practice.organization(organization_id),
        practice_instance_id BIGINT NOT NULL
            CONSTRAINT fk_pm_pio_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id),

        obligation_id        BIGINT NOT NULL,
        release_id           BIGINT NULL,
        obligation_name      NVARCHAR(500) NULL,
        obligation_type_code NVARCHAR(60)  NULL,

        inherited_from_repository BIT NOT NULL
            CONSTRAINT df_pm_pio_inherited DEFAULT 1,
        organization_modified     BIT NOT NULL
            CONSTRAINT df_pm_pio_modified  DEFAULT 0,

        -- Organization parameters. NULL means "as published".
        execution_frequency_id INT NULL
            CONSTRAINT fk_pm_pio_exec_freq
                REFERENCES grac_practice.frequency_master(frequency_id),
        execution_frequency    NVARCHAR(120) NULL,
        assurance_frequency_id INT NULL
            CONSTRAINT fk_pm_pio_assur_freq
                REFERENCES grac_practice.frequency_master(frequency_id),
        assurance_frequency    NVARCHAR(120) NULL,
        responsibility         NVARCHAR(300) NULL,
        approval_authority     NVARCHAR(300) NULL,
        retention_period       NVARCHAR(120) NULL,
        remarks                NVARCHAR(MAX) NULL,

        adopted_by NVARCHAR(100) NULL,
        adopted_dt DATETIME2 NULL,

        status           NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_pio_status DEFAULT N'Active',
        record_status_id INT NULL
            CONSTRAINT fk_pm_pio_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_pio_entered_by DEFAULT 'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_pio_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        -- One decision per obligation per instance. Adopting twice is an
        -- update, never a second row -- otherwise "is this adopted?" has
        -- more than one answer.
        CONSTRAINT uq_pm_practice_instance_obligation
            UNIQUE(practice_instance_id, obligation_id)
    );
END
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_pio_instance'
                      AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
    CREATE INDEX ix_pm_pio_instance
        ON grac_practice.practice_instance_obligation(practice_instance_id, status)
        INCLUDE (obligation_id, organization_modified);
GO

-- Reverse lookup: "which instances adopted this obligation" is the
-- question a release update has to ask.
IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_pio_obligation'
                      AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
    CREATE INDEX ix_pm_pio_obligation
        ON grac_practice.practice_instance_obligation(organization_id, obligation_id);
GO

-- =====================================================================
-- Link evidence rows back to the obligation that produced them.
--
-- Adopting an obligation creates its evidence rows. Without this column
-- there is no way to tell an auto-created row from one somebody added by
-- hand, so un-adopting could not clean up after itself and a re-adopt
-- would duplicate. Nullable: every existing row predates this and was
-- added by hand.
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_evidence
        ADD source_obligation_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_evidence
        ADD source_obligation_evidence_id BIGINT NULL;
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_evidence_source_obligation'
                      AND object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
    CREATE INDEX ix_pm_evidence_source_obligation
        ON grac_practice.practice_instance_evidence(practice_instance_id, source_obligation_id);
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'practice_instance_obligation created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'unique (instance, obligation)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_practice_instance_obligation')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'evidence carries source_obligation_id',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'obligation projection available (122)',
       CASE WHEN OBJECT_ID('dbo.sp_pm_view_obligations_typed','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- run 122; the workspace lists no obligations without it' END
UNION ALL SELECT 'GRAC_New obligations reachable',
       CASE WHEN OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
             AND OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Instances the new Resolve list will show, per owner. An instance with
-- no primary_owner_id appears only to organization-scoped admins.
SELECT pi.organization_id            AS OrganizationId,
       pi.primary_owner_id           AS OwnerEmployeeId,
       COALESCE(e.employee_name, N'(no owner set)') AS OwnerName,
       COUNT(*)                      AS InstanceCount
FROM   grac_practice.practice_instance pi
LEFT   JOIN grac_practice.organization_employee e
       ON e.employee_id = pi.primary_owner_id
WHERE  pi.status = N'Active'
GROUP  BY pi.organization_id, pi.primary_owner_id, e.employee_name
ORDER  BY pi.organization_id, OwnerName;

PRINT '140 Resolve workspace schema installed. Run 141 for the procedures.';
GO
