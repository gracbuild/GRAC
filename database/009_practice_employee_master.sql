/*
  GRAC Part 2 - Practice Management
  Organization employee master for owner dropdowns.

  Run in GRAC_NewPhase database after:
  001_practice_management_schema.sql
  008_normalize_practice_status_master.sql
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51400, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_practice.organization','U') IS NULL
    THROW 51401, 'Table grac_practice.organization is missing. Run PracticeManagement schema scripts first.', 1;

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
    THROW 51402, 'Table grac_practice.record_status_master is missing. Run 008_normalize_practice_status_master.sql first.', 1;

DECLARE @ActiveRecordStatusId INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');

IF OBJECT_ID('grac_practice.organization_employee','U') IS NULL
CREATE TABLE grac_practice.organization_employee(
    employee_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_employee PRIMARY KEY,
    organization_id BIGINT NOT NULL,
    employee_code NVARCHAR(80) NOT NULL,
    employee_name NVARCHAR(200) NOT NULL,
    email NVARCHAR(250) NULL,
    designation NVARCHAR(150) NULL,
    department NVARCHAR(150) NULL,
    status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_employee_status DEFAULT 'Active',
    record_status_id INT NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_employee_entered_by DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_employee_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT fk_pm_employee_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT fk_pm_employee_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
    CONSTRAINT uq_pm_employee_org_code UNIQUE(organization_id,employee_code)
);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_employee_org_status' AND object_id=OBJECT_ID('grac_practice.organization_employee'))
    CREATE INDEX ix_pm_employee_org_status ON grac_practice.organization_employee(organization_id,record_status_id,employee_name);

;WITH existing_owners AS (
    SELECT organization_id,LTRIM(RTRIM(owner_name)) employee_name
    FROM grac_practice.organization_business_function
    WHERE NULLIF(LTRIM(RTRIM(owner_name)),'') IS NOT NULL
    UNION
    SELECT organization_id,LTRIM(RTRIM(primary_owner)) employee_name
    FROM grac_practice.organization_control
    WHERE NULLIF(LTRIM(RTRIM(primary_owner)),'') IS NOT NULL
    UNION
    SELECT organization_id,LTRIM(RTRIM(secondary_owner)) employee_name
    FROM grac_practice.organization_control
    WHERE NULLIF(LTRIM(RTRIM(secondary_owner)),'') IS NOT NULL
),
numbered_owners AS (
    SELECT organization_id,employee_name,
           ROW_NUMBER() OVER(PARTITION BY organization_id ORDER BY employee_name) row_no
    FROM existing_owners
)
INSERT grac_practice.organization_employee(
    organization_id,employee_code,employee_name,designation,department,status,record_status_id,entered_by)
SELECT n.organization_id,
       CONCAT('EMP-',RIGHT(CONCAT('00000',n.row_no),5)),
       n.employee_name,
       'Control Owner',
       'Compliance',
       'Active',
       @ActiveRecordStatusId,
       'system'
FROM numbered_owners n
WHERE NOT EXISTS(
    SELECT 1
    FROM grac_practice.organization_employee e
    WHERE e.organization_id=n.organization_id
      AND UPPER(LTRIM(RTRIM(e.employee_name)))=UPPER(n.employee_name)
);

SELECT 'grac_practice.organization_employee' [Object],
       COUNT_BIG(1) EmployeeRows,
       COUNT_BIG(DISTINCT organization_id) OrganizationsWithEmployees
FROM grac_practice.organization_employee;
