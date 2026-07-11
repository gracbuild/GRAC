/*
  GRAC Part 2 - Practice Management
  Normalize Practice Instance dependency type to a master table.

  Run in GRAC_NewPhase.
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51800, 'Schema grac_practice is missing.', 1;

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
    THROW 51801, 'Table grac_practice.practice_instance_dependency is missing.', 1;

IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.dependency_type_master(
        dependency_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_dependency_type_master PRIMARY KEY,
        dependency_type_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_dependency_type_code UNIQUE,
        dependency_type_name NVARCHAR(120) NOT NULL,
        display_order INT NOT NULL DEFAULT 0,
        is_active BIT NOT NULL DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
        entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END;

DECLARE @DependencyTypes TABLE(code NVARCHAR(60), name NVARCHAR(120), display_order INT);
INSERT @DependencyTypes(code,name,display_order)
VALUES
('Person','Person',1),
('Tool','Tool',2),
('Asset','Asset',3),
('Vendor','Vendor',4),
('Application','Application',5),
('Process','Process',6),
('Location','Location',7);

INSERT grac_practice.dependency_type_master(dependency_type_code,dependency_type_name,display_order,entered_by)
SELECT d.code,d.name,d.display_order,'system-seed'
FROM @DependencyTypes d
WHERE NOT EXISTS(
    SELECT 1
    FROM grac_practice.dependency_type_master existing
    WHERE existing.dependency_type_code=d.code
);

UPDATE existing
SET dependency_type_name=d.name,
    display_order=d.display_order,
    is_active=1,
    updated_by='system-seed',
    updated_dt=SYSUTCDATETIME()
FROM grac_practice.dependency_type_master existing
JOIN @DependencyTypes d ON d.code=existing.dependency_type_code;

IF COL_LENGTH('grac_practice.practice_instance_dependency','dependency_type_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_dependency ADD dependency_type_id INT NULL;

GO

SET NOCOUNT ON;

UPDATE d
SET dependency_type_id=dt.dependency_type_id
FROM grac_practice.practice_instance_dependency d
JOIN grac_practice.dependency_type_master dt
    ON dt.dependency_type_code=d.dependency_type
    OR dt.dependency_type_name=d.dependency_type
WHERE d.dependency_type_id IS NULL;

UPDATE d
SET dependency_type_id=dt.dependency_type_id,
    dependency_type=dt.dependency_type_code
FROM grac_practice.practice_instance_dependency d
CROSS JOIN grac_practice.dependency_type_master dt
WHERE d.dependency_type_id IS NULL
  AND dt.dependency_type_code='Process';

IF EXISTS(
    SELECT 1
    FROM grac_practice.practice_instance_dependency
    WHERE dependency_type_id IS NULL
)
    THROW 51802, 'Some dependencies could not be mapped to a dependency type.', 1;

ALTER TABLE grac_practice.practice_instance_dependency ALTER COLUMN dependency_type_id INT NOT NULL;

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_dependency_type')
    ALTER TABLE grac_practice.practice_instance_dependency
    ADD CONSTRAINT fk_pm_dependency_type
    FOREIGN KEY(dependency_type_id) REFERENCES grac_practice.dependency_type_master(dependency_type_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_dependency_type_status' AND object_id=OBJECT_ID('grac_practice.practice_instance_dependency'))
    CREATE INDEX ix_pm_dependency_type_status
    ON grac_practice.practice_instance_dependency(organization_id,practice_instance_id,dependency_type_id,status,criticality,entered_dt DESC)
    INCLUDE(dependency_name,owner_name);

SELECT
    DB_NAME() DatabaseName,
    COUNT_BIG(1) DependencyTypeRows
FROM grac_practice.dependency_type_master;
