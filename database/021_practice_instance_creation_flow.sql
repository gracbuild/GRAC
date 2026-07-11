/*
  GRAC Practice Management
  Practice Instance creation flow update.

  Purpose:
  - Owner is stored as Employee/User reference.
  - Owner department is stored as Department reference.
  - Execution Frequency and Assurance Frequency are stored separately.
  - Existing legacy frequency columns remain for backward compatibility.

  Run in GRAC_NewPhase before rerunning:
  - 002_practice_management_procedures.sql
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 52100, 'Schema grac_practice is missing.', 1;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
    THROW 52101, 'Table grac_practice.practice_instance is missing.', 1;

IF OBJECT_ID('grac_practice.frequency_master','U') IS NULL
    THROW 52102, 'Table grac_practice.frequency_master is missing.', 1;

IF COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
    ALTER TABLE grac_practice.practice_instance ADD primary_owner_id BIGINT NULL;

IF COL_LENGTH('grac_practice.practice_instance','department_id') IS NULL
    ALTER TABLE grac_practice.practice_instance ADD department_id BIGINT NULL;

IF COL_LENGTH('grac_practice.practice_instance','execution_frequency_id') IS NULL
    ALTER TABLE grac_practice.practice_instance ADD execution_frequency_id INT NULL;

IF COL_LENGTH('grac_practice.practice_instance','assurance_frequency_id') IS NULL
    ALTER TABLE grac_practice.practice_instance ADD assurance_frequency_id INT NULL;

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
BEGIN
    UPDATE pi
    SET primary_owner_id = e.employee_id,
        department_id = COALESCE(pi.department_id, e.department_id),
        department = COALESCE(d.department_name, e.department, pi.department),
        updated_by = COALESCE(pi.updated_by, N'system-migration'),
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice_instance pi
    JOIN grac_practice.organization_employee e
      ON e.organization_id = pi.organization_id
     AND UPPER(LTRIM(RTRIM(e.employee_name))) = UPPER(LTRIM(RTRIM(pi.primary_owner)))
     AND e.status = 'Active'
    LEFT JOIN grac_practice.organization_department d
      ON d.department_id = e.department_id
    WHERE pi.primary_owner_id IS NULL
      AND NULLIF(LTRIM(RTRIM(pi.primary_owner)), N'') IS NOT NULL;
END;

UPDATE grac_practice.practice_instance
SET execution_frequency_id = COALESCE(execution_frequency_id, frequency_id),
    assurance_frequency_id = COALESCE(assurance_frequency_id, frequency_id),
    updated_by = COALESCE(updated_by, N'system-migration'),
    updated_dt = SYSUTCDATETIME()
WHERE frequency_id IS NOT NULL
  AND (execution_frequency_id IS NULL OR assurance_frequency_id IS NULL);

IF OBJECT_ID('grac_practice.organization_employee','U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1
       FROM sys.foreign_keys
       WHERE name = 'fk_pm_practice_instance_owner_employee'
         AND parent_object_id = OBJECT_ID('grac_practice.practice_instance')
   )
BEGIN
    ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT fk_pm_practice_instance_owner_employee
        FOREIGN KEY(primary_owner_id) REFERENCES grac_practice.organization_employee(employee_id);
END;

IF OBJECT_ID('grac_practice.organization_department','U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1
       FROM sys.foreign_keys
       WHERE name = 'fk_pm_practice_instance_department'
         AND parent_object_id = OBJECT_ID('grac_practice.practice_instance')
   )
BEGIN
    ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT fk_pm_practice_instance_department
        FOREIGN KEY(department_id) REFERENCES grac_practice.organization_department(department_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_instance_execution_frequency'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_instance')
)
BEGIN
    ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT fk_pm_practice_instance_execution_frequency
        FOREIGN KEY(execution_frequency_id) REFERENCES grac_practice.frequency_master(frequency_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_instance_assurance_frequency'
      AND parent_object_id = OBJECT_ID('grac_practice.practice_instance')
)
BEGIN
    ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT fk_pm_practice_instance_assurance_frequency
        FOREIGN KEY(assurance_frequency_id) REFERENCES grac_practice.frequency_master(frequency_id);
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'ix_pm_practice_instance_owner_department_frequency'
      AND object_id = OBJECT_ID('grac_practice.practice_instance')
)
BEGIN
    CREATE INDEX ix_pm_practice_instance_owner_department_frequency
        ON grac_practice.practice_instance(organization_id, primary_owner_id, department_id, execution_frequency_id, assurance_frequency_id, status);
END;

SELECT
    practice_instance_id,
    organization_id,
    instance_code,
    instance_name,
    primary_owner_id,
    department_id,
    execution_frequency_id,
    assurance_frequency_id,
    status
FROM grac_practice.practice_instance
ORDER BY practice_instance_id DESC;
