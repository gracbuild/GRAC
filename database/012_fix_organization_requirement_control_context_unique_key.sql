/*
  GRAC Part 2 - Practice Management
  Fix Organization Requirement uniqueness for control-scoped requirement loading.

  Why:
  Organization Requirements are now loaded by OrganizationID + OrgControlID.
  The previous uniqueness rule (OrganizationID + RequirementCode) prevented the same
  requirement from being imported under more than one organization control.

  Run in GRAC_NewPhase.
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51600, 'Schema grac_practice is missing. Run PracticeManagement schema scripts in GRAC_NewPhase first.', 1;

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
    THROW 51601, 'Table grac_practice.organization_requirement is missing.', 1;

IF EXISTS (
    SELECT 1
    FROM grac_practice.organization_requirement
    GROUP BY organization_id, organization_control_id, requirement_code
    HAVING COUNT_BIG(1) > 1
)
BEGIN
    SELECT
        organization_id,
        organization_control_id,
        requirement_code,
        COUNT_BIG(1) DuplicateRows
    FROM grac_practice.organization_requirement
    GROUP BY organization_id, organization_control_id, requirement_code
    HAVING COUNT_BIG(1) > 1
    ORDER BY organization_id, organization_control_id, requirement_code;

    THROW 51602, 'Duplicate organization requirements exist for the new control-scoped key. Review the result set and clean duplicates before applying the constraint.', 1;
END;

IF EXISTS (
    SELECT 1
    FROM sys.key_constraints
    WHERE name = 'uq_pm_organization_requirement'
      AND parent_object_id = OBJECT_ID('grac_practice.organization_requirement')
)
BEGIN
    ALTER TABLE grac_practice.organization_requirement DROP CONSTRAINT uq_pm_organization_requirement;
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.key_constraints
    WHERE name = 'uq_pm_organization_requirement'
      AND parent_object_id = OBJECT_ID('grac_practice.organization_requirement')
)
BEGIN
    ALTER TABLE grac_practice.organization_requirement
    ADD CONSTRAINT uq_pm_organization_requirement
    UNIQUE(organization_id, organization_control_id, requirement_code);
END;

SELECT
    DB_NAME() DatabaseName,
    'grac_practice.organization_requirement' TableName,
    'uq_pm_organization_requirement' ConstraintName,
    'organization_id, organization_control_id, requirement_code' UniqueKey,
    COUNT_BIG(1) CurrentRows
FROM grac_practice.organization_requirement;
