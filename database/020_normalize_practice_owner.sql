/*
  GRAC Practice Management
  Normalize Practice owner to organization employee master.

  Run in GRAC_NewPhase after:
  - 001_practice_management_schema.sql
  - 009_practice_employee_master.sql
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 52000, 'Schema grac_practice is missing.', 1;

IF OBJECT_ID('grac_practice.practice','U') IS NULL
    THROW 52001, 'Table grac_practice.practice is missing.', 1;

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
    THROW 52002, 'Table grac_practice.organization_employee is missing. Run 009_practice_employee_master.sql first.', 1;

IF COL_LENGTH('grac_practice.practice','practice_owner_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice ADD practice_owner_id BIGINT NULL;
END;

UPDATE p
SET practice_owner_id = e.employee_id,
    updated_by = COALESCE(p.updated_by, N'system-migration'),
    updated_dt = SYSUTCDATETIME()
FROM grac_practice.practice p
JOIN grac_practice.organization_employee e
    ON e.organization_id = p.organization_id
   AND UPPER(LTRIM(RTRIM(e.employee_name))) = UPPER(LTRIM(RTRIM(p.practice_owner)))
   AND e.status = 'Active'
WHERE p.practice_owner_id IS NULL
  AND NULLIF(LTRIM(RTRIM(p.practice_owner)), N'') IS NOT NULL;

IF NOT EXISTS(
    SELECT 1
    FROM sys.foreign_keys
    WHERE name = 'fk_pm_practice_owner_employee'
      AND parent_object_id = OBJECT_ID('grac_practice.practice')
)
BEGIN
    ALTER TABLE grac_practice.practice
    ADD CONSTRAINT fk_pm_practice_owner_employee
        FOREIGN KEY(practice_owner_id) REFERENCES grac_practice.organization_employee(employee_id);
END;

IF NOT EXISTS(
    SELECT 1
    FROM sys.indexes
    WHERE name = 'ix_pm_practice_owner'
      AND object_id = OBJECT_ID('grac_practice.practice')
)
BEGIN
    CREATE INDEX ix_pm_practice_owner
        ON grac_practice.practice(organization_id, practice_owner_id, status, entered_dt DESC);
END;

SELECT
    p.practice_id,
    p.organization_id,
    p.practice_code,
    p.practice_name,
    p.practice_owner_id,
    COALESCE(e.employee_name, p.practice_owner) AS PracticeOwner
FROM grac_practice.practice p
LEFT JOIN grac_practice.organization_employee e
    ON e.employee_id = p.practice_owner_id
ORDER BY p.practice_id DESC;
