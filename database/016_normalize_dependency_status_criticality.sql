/*
  GRAC Part 2 - Practice Intelligence Layer
  Normalize Practice Instance dependency Criticality and Status to master IDs.

  Run after:
    008_normalize_practice_status_master.sql
    015_normalize_dependency_type_master.sql
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRAN;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51901, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
    THROW 51902, 'Table grac_practice.practice_instance_dependency is missing.', 1;

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
    THROW 51903, 'Table grac_practice.record_status_master is missing. Run 008_normalize_practice_status_master.sql first.', 1;

IF OBJECT_ID('grac_practice.criticality_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.criticality_master(
        criticality_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_criticality_master PRIMARY KEY,
        criticality_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_criticality_code UNIQUE,
        criticality_name NVARCHAR(80) NOT NULL,
        display_order INT NOT NULL DEFAULT 0,
        is_active BIT NOT NULL DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
        entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END;

;WITH seed(criticality_code,criticality_name,display_order) AS (
    SELECT N'Critical',N'Critical',1 UNION ALL
    SELECT N'High',N'High',2 UNION ALL
    SELECT N'Medium',N'Medium',3 UNION ALL
    SELECT N'Low',N'Low',4
)
INSERT grac_practice.criticality_master(criticality_code,criticality_name,display_order,entered_by)
SELECT s.criticality_code,s.criticality_name,s.display_order,N'system'
FROM seed s
WHERE NOT EXISTS(
    SELECT 1
    FROM grac_practice.criticality_master existing
    WHERE existing.criticality_code=s.criticality_code
       OR existing.criticality_name=s.criticality_name
);

IF COL_LENGTH('grac_practice.practice_instance_dependency','criticality_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_dependency ADD criticality_id INT NULL;

IF COL_LENGTH('grac_practice.practice_instance_dependency','record_status_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_dependency ADD record_status_id INT NULL;

UPDATE d
SET criticality_id=cm.criticality_id
FROM grac_practice.practice_instance_dependency d
JOIN grac_practice.criticality_master cm
  ON cm.criticality_code=d.criticality OR cm.criticality_name=d.criticality
WHERE d.criticality_id IS NULL;

UPDATE d
SET criticality_id=cm.criticality_id,
    criticality=cm.criticality_code
FROM grac_practice.practice_instance_dependency d
CROSS JOIN grac_practice.criticality_master cm
WHERE d.criticality_id IS NULL
  AND cm.criticality_code=N'Medium';

UPDATE d
SET record_status_id=rs.record_status_id
FROM grac_practice.practice_instance_dependency d
JOIN grac_practice.record_status_master rs
  ON rs.status_code=d.status OR rs.status_name=d.status
WHERE d.record_status_id IS NULL;

UPDATE d
SET record_status_id=rs.record_status_id,
    status=rs.status_code
FROM grac_practice.practice_instance_dependency d
CROSS JOIN grac_practice.record_status_master rs
WHERE d.record_status_id IS NULL
  AND rs.status_code=N'Active';

IF EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency WHERE criticality_id IS NULL)
    THROW 51904, 'Could not backfill dependency criticality_id.', 1;

IF EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency WHERE record_status_id IS NULL)
    THROW 51905, 'Could not backfill dependency record_status_id.', 1;

ALTER TABLE grac_practice.practice_instance_dependency ALTER COLUMN criticality_id INT NOT NULL;
ALTER TABLE grac_practice.practice_instance_dependency ALTER COLUMN record_status_id INT NOT NULL;

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_dependency_criticality')
    ALTER TABLE grac_practice.practice_instance_dependency
    ADD CONSTRAINT fk_pm_dependency_criticality
    FOREIGN KEY(criticality_id) REFERENCES grac_practice.criticality_master(criticality_id);

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_dependency_record_status')
    ALTER TABLE grac_practice.practice_instance_dependency
    ADD CONSTRAINT fk_pm_dependency_record_status
    FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dependency_instance_type_status_criticality' AND object_id=OBJECT_ID('grac_practice.practice_instance_dependency'))
    CREATE INDEX ix_pm_dependency_instance_type_status_criticality
    ON grac_practice.practice_instance_dependency(practice_instance_id,dependency_type_id,record_status_id,criticality_id,entered_dt DESC)
    INCLUDE(organization_id,dependency_name,owner_name);

COMMIT;

SELECT
    N'Practice dependency normalization completed' AS Message,
    COUNT(*) AS DependencyRows
FROM grac_practice.practice_instance_dependency;
