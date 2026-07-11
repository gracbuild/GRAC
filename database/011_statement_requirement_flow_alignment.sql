SET XACT_ABORT ON;
GO

/*
 Practice Management repository alignment
 Final repository model:
   Framework Statement <-> Requirement
   Requirement -> Practice / Practice Instance
   Requirement + Release -> Obligation

 This script intentionally does not recreate Control Management repository objects.
 Run the latest Control Management schema first so GRAC_New.framework_statement_requirement_map exists.
*/

BEGIN TRANSACTION;

IF OBJECT_ID('GRAC_New.framework_statement_requirement_map','U') IS NULL
BEGIN
    THROW 51080,
        'Missing GRAC_New.framework_statement_requirement_map. Run the latest Control Management repository schema before Practice Management.',
        1;
END;

IF COL_LENGTH('grac_practice.organization_statement_applicability','owner_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_statement_applicability ADD owner_id BIGINT NULL;
END;

IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.organization_framework_statements(
        org_statement_id BIGINT IDENTITY PRIMARY KEY,
        organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
        release_id BIGINT NOT NULL,
        framework_statement_id BIGINT NOT NULL,
        applicability_status_id INT NULL REFERENCES grac_practice.applicability_status_master(applicability_status_id),
        owner_id BIGINT NULL REFERENCES grac_practice.organization_employee(employee_id),
        applicability_reason NVARCHAR(MAX) NULL,
        status_id INT NULL REFERENCES grac_practice.record_status_master(record_status_id),
        status NVARCHAR(30) NOT NULL DEFAULT 'Active',
        entered_by NVARCHAR(100) NOT NULL,
        entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_org_framework_statement UNIQUE(organization_id,release_id,framework_statement_id)
    );
END;

IF COL_LENGTH('grac_practice.organization_requirement','org_statement_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_requirement ADD org_statement_id BIGINT NULL;
END;

IF OBJECT_ID('grac_practice.uq_pm_organization_requirement','UQ') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.organization_requirement DROP CONSTRAINT uq_pm_organization_requirement;
END;

IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_control_code' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    DROP INDEX ux_pm_org_requirement_control_code ON grac_practice.organization_requirement;
END;

IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_control_status' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    DROP INDEX ix_pm_org_requirement_control_status ON grac_practice.organization_requirement;
END;

IF EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_org_status_origin' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    DROP INDEX ix_pm_org_requirement_org_status_origin ON grac_practice.organization_requirement;
END;

IF COL_LENGTH('grac_practice.organization_requirement','organization_control_id') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.organization_requirement ALTER COLUMN organization_control_id BIGINT NULL;
END;

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_framework_statement_org_release' AND object_id=OBJECT_ID('grac_practice.organization_framework_statements'))
BEGIN
    CREATE INDEX ix_pm_org_framework_statement_org_release
        ON grac_practice.organization_framework_statements(organization_id,release_id,status)
        INCLUDE(framework_statement_id,applicability_status_id,owner_id);
END;

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_statement_requirement' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    CREATE UNIQUE INDEX ux_pm_org_requirement_statement_requirement
        ON grac_practice.organization_requirement(organization_id,org_statement_id,repository_requirement_id)
        WHERE org_statement_id IS NOT NULL AND repository_requirement_id IS NOT NULL;
END;

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ux_pm_org_requirement_control_code' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    CREATE UNIQUE INDEX ux_pm_org_requirement_control_code
        ON grac_practice.organization_requirement(organization_id,organization_control_id,requirement_code)
        WHERE organization_control_id IS NOT NULL;
END;

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_org_status_origin' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    CREATE INDEX ix_pm_org_requirement_org_status_origin
        ON grac_practice.organization_requirement(organization_id,status,origin_type,entered_dt DESC)
        INCLUDE(repository_requirement_id,organization_control_id,requirement_code,requirement_name);
END;

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_control_status' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
BEGIN
    CREATE INDEX ix_pm_org_requirement_control_status
        ON grac_practice.organization_requirement(organization_control_id,status,entered_dt DESC);
END;

INSERT grac_practice.organization_framework_statements(
    organization_id,release_id,framework_statement_id,applicability_status_id,owner_id,applicability_reason,status_id,status,entered_by,entered_dt,updated_by,updated_dt)
SELECT osa.organization_id,osa.release_id,osa.framework_statement_id,osa.applicability_status_id,osa.owner_id,osa.exclusion_justification,rs.record_status_id,osa.status,osa.entered_by,osa.entered_dt,osa.updated_by,osa.updated_dt
FROM grac_practice.organization_statement_applicability osa
LEFT JOIN grac_practice.record_status_master rs ON rs.status_code=osa.status OR rs.status_name=osa.status
WHERE NOT EXISTS(
    SELECT 1
    FROM grac_practice.organization_framework_statements ofs
    WHERE ofs.organization_id=osa.organization_id
      AND ofs.release_id=osa.release_id
      AND ofs.framework_statement_id=osa.framework_statement_id
);

COMMIT TRANSACTION;
GO

SELECT
    DB_NAME() CurrentDatabase,
    OBJECT_ID('GRAC_New.framework_statement_requirement_map','U') FrameworkStatementRequirementMapObjectId,
    (SELECT COUNT_BIG(1) FROM GRAC_New.framework_statement_requirement_map WHERE status='Active') ActiveStatementRequirementMappings,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_framework_statements) OrganizationFrameworkStatements;
GO
