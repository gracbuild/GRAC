/*
  GRAC Part 2 - Practice Management
  Adds practice applicability fields and supporting indexes for:
  Organization Requirement -> Practice -> Practice Instance.

  Run in GRAC_NewPhase after 008_normalize_practice_status_master.sql.
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51700, 'Schema grac_practice is missing.', 1;

IF OBJECT_ID('grac_practice.practice','U') IS NULL
    THROW 51701, 'Table grac_practice.practice is missing.', 1;

IF COL_LENGTH('grac_practice.practice','applicability_status') IS NULL
    ALTER TABLE grac_practice.practice ADD applicability_status NVARCHAR(40) NOT NULL CONSTRAINT df_pm_practice_applicability_status DEFAULT 'Not Updated';

IF COL_LENGTH('grac_practice.practice','applicability_status_id') IS NULL
    ALTER TABLE grac_practice.practice ADD applicability_status_id INT NULL;

IF COL_LENGTH('grac_practice.practice','exclusion_justification') IS NULL
    ALTER TABLE grac_practice.practice ADD exclusion_justification NVARCHAR(MAX) NULL;

GO

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51700, 'Schema grac_practice is missing.', 1;

IF OBJECT_ID('grac_practice.practice','U') IS NULL
    THROW 51701, 'Table grac_practice.practice is missing.', 1;

IF EXISTS (
    SELECT 1
    FROM grac_practice.practice
    GROUP BY organization_id, organization_requirement_id, practice_code
    HAVING COUNT_BIG(1) > 1
)
BEGIN
    SELECT organization_id, organization_requirement_id, practice_code, COUNT_BIG(1) DuplicateRows
    FROM grac_practice.practice
    GROUP BY organization_id, organization_requirement_id, practice_code
    HAVING COUNT_BIG(1) > 1
    ORDER BY organization_id, organization_requirement_id, practice_code;

    THROW 51703, 'Duplicate practices exist for the new requirement-scoped key. Review and clean duplicates before applying the constraint.', 1;
END;

IF EXISTS (
    SELECT 1
    FROM sys.key_constraints
    WHERE name='uq_pm_practice'
      AND parent_object_id=OBJECT_ID('grac_practice.practice')
)
BEGIN
    ALTER TABLE grac_practice.practice DROP CONSTRAINT uq_pm_practice;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.key_constraints
    WHERE name='uq_pm_practice'
      AND parent_object_id=OBJECT_ID('grac_practice.practice')
)
BEGIN
    ALTER TABLE grac_practice.practice
    ADD CONSTRAINT uq_pm_practice UNIQUE(organization_id, organization_requirement_id, practice_code);
END;

DECLARE @NotUpdatedApplicabilityStatusId INT=(
    SELECT applicability_status_id
    FROM grac_practice.applicability_status_master
    WHERE status_code='Not Updated'
);

IF @NotUpdatedApplicabilityStatusId IS NULL
    THROW 51702, 'Applicability status master value Not Updated is missing. Run 008_normalize_practice_status_master.sql first.', 1;

UPDATE p
SET applicability_status=COALESCE(NULLIF(p.applicability_status,''),'Not Updated'),
    applicability_status_id=COALESCE(p.applicability_status_id,a.applicability_status_id,@NotUpdatedApplicabilityStatusId)
FROM grac_practice.practice p
LEFT JOIN grac_practice.applicability_status_master a
    ON a.status_code=p.applicability_status OR a.status_name=p.applicability_status
WHERE p.applicability_status_id IS NULL OR NULLIF(p.applicability_status,'') IS NULL;

IF COL_LENGTH('grac_practice.practice','applicability_status_id') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.practice ALTER COLUMN applicability_status_id INT NOT NULL;
END;

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_practice_applicability_status')
    ALTER TABLE grac_practice.practice
    ADD CONSTRAINT fk_pm_practice_applicability_status
    FOREIGN KEY(applicability_status_id) REFERENCES grac_practice.applicability_status_master(applicability_status_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_practice_requirement_applicability' AND object_id=OBJECT_ID('grac_practice.practice'))
    CREATE INDEX ix_pm_practice_requirement_applicability
    ON grac_practice.practice(organization_id,organization_requirement_id,applicability_status_id,status,entered_dt DESC)
    INCLUDE(practice_code,practice_name,practice_owner,origin_type);

SELECT
    DB_NAME() DatabaseName,
    'grac_practice.practice' TableName,
    COUNT_BIG(1) PracticeRows,
    SUM(CASE WHEN applicability_status_id=@NotUpdatedApplicabilityStatusId THEN 1 ELSE 0 END) NotUpdatedRows
FROM grac_practice.practice;
