/*
  GRAC Part 2 - Practice Management
  Correct Organization Control / Requirement applicability defaults.

  Purpose:
  - New repository-derived and manually added organization controls must start as "Not Updated".
  - New organization requirements imported after a control becomes applicable must start as "Not Updated".
  - Existing rows that were auto-created as "Applicable" can be corrected only when they appear untouched.

  Safety:
  - This script previews affected rows by default.
  - Set @ApplyChanges = 1 only after reviewing the preview counts.
*/

SET NOCOUNT ON;

DECLARE @ApplyChanges BIT = 0;
DECLARE @DefaultConstraintName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51200, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql in the GRAC_NewPhase database.', 1;

IF OBJECT_ID('grac_practice.organization_control','U') IS NULL
    THROW 51201, 'Table grac_practice.organization_control is missing.', 1;

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
    THROW 51202, 'Table grac_practice.organization_requirement is missing.', 1;

SELECT
    'organization_control_touched_applicable_kept' AS Bucket,
    COUNT_BIG(1) AS RecordCount
FROM grac_practice.organization_control
WHERE applicability_status = 'Applicable'
  AND (
        NULLIF(LTRIM(RTRIM(ISNULL(primary_owner,''))), '') IS NOT NULL
     OR NULLIF(LTRIM(RTRIM(ISNULL(secondary_owner,''))), '') IS NOT NULL
     OR NULLIF(LTRIM(RTRIM(ISNULL(exclusion_justification,''))), '') IS NOT NULL
     OR updated_dt IS NOT NULL
  );

SELECT
    'organization_control_untouched_applicable_to_reset' AS Bucket,
    COUNT_BIG(1) AS RecordCount
FROM grac_practice.organization_control
WHERE applicability_status = 'Applicable'
  AND NULLIF(LTRIM(RTRIM(ISNULL(primary_owner,''))), '') IS NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(secondary_owner,''))), '') IS NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(exclusion_justification,''))), '') IS NULL
  AND updated_dt IS NULL;

SELECT
    'organization_requirement_untouched_applicable_to_reset' AS Bucket,
    COUNT_BIG(1) AS RecordCount
FROM grac_practice.organization_requirement
WHERE applicability_status = 'Applicable'
  AND NULLIF(LTRIM(RTRIM(ISNULL(exclusion_justification,''))), '') IS NULL
  AND updated_dt IS NULL;

IF @ApplyChanges = 1
BEGIN
    BEGIN TRANSACTION;

    SELECT @DefaultConstraintName = dc.name
    FROM sys.default_constraints dc
    JOIN sys.columns c
      ON c.object_id = dc.parent_object_id
     AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID('grac_practice.organization_control')
      AND c.name = 'applicability_status';

    IF @DefaultConstraintName IS NOT NULL
    BEGIN
        SET @Sql = N'ALTER TABLE grac_practice.organization_control DROP CONSTRAINT ' + QUOTENAME(@DefaultConstraintName) + N';';
        EXEC sys.sp_executesql @Sql;
    END;

    ALTER TABLE grac_practice.organization_control
      ADD CONSTRAINT df_pm_org_control_applicability_status DEFAULT 'Not Updated' FOR applicability_status;

    SET @DefaultConstraintName = NULL;
    SELECT @DefaultConstraintName = dc.name
    FROM sys.default_constraints dc
    JOIN sys.columns c
      ON c.object_id = dc.parent_object_id
     AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = OBJECT_ID('grac_practice.organization_requirement')
      AND c.name = 'applicability_status';

    IF @DefaultConstraintName IS NOT NULL
    BEGIN
        SET @Sql = N'ALTER TABLE grac_practice.organization_requirement DROP CONSTRAINT ' + QUOTENAME(@DefaultConstraintName) + N';';
        EXEC sys.sp_executesql @Sql;
    END;

    ALTER TABLE grac_practice.organization_requirement
      ADD CONSTRAINT df_pm_org_requirement_applicability_status DEFAULT 'Not Updated' FOR applicability_status;

    UPDATE grac_practice.organization_control
       SET applicability_status = 'Not Updated',
           criticality = COALESCE(criticality, 'Medium')
     WHERE applicability_status = 'Applicable'
       AND NULLIF(LTRIM(RTRIM(ISNULL(primary_owner,''))), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(ISNULL(secondary_owner,''))), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(ISNULL(exclusion_justification,''))), '') IS NULL
       AND updated_dt IS NULL;

    UPDATE grac_practice.organization_requirement
       SET applicability_status = 'Not Updated'
     WHERE applicability_status = 'Applicable'
       AND NULLIF(LTRIM(RTRIM(ISNULL(exclusion_justification,''))), '') IS NULL
       AND updated_dt IS NULL;

    COMMIT TRANSACTION;
END;

SELECT
    'Set @ApplyChanges = 1 and rerun this script to apply the correction.' AS Message,
    @ApplyChanges AS ApplyChanges;
