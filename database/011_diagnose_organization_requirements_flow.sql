/*
  GRAC Part 2 - Practice Management
  Diagnostic script for Organization Controls -> Practices / Organization Requirements.

  Set @OrganizationId to the selected organization from the UI.
  Optional: set @OrganizationControlId to a specific row from organization_control.
*/

SET NOCOUNT ON;

DECLARE @OrganizationId BIGINT = 2;
DECLARE @OrganizationControlId BIGINT = NULL;

DECLARE @ApplicableStatusId INT = (
    SELECT applicability_status_id
    FROM grac_practice.applicability_status_master
    WHERE status_code = 'Applicable'
);

DECLARE @RequestedOrganizationControlId BIGINT = @OrganizationControlId;

SELECT
    DB_NAME() DatabaseName,
    SCHEMA_ID('grac_practice') PracticeSchemaId,
    OBJECT_ID('grac_practice.organization_control') OrganizationControlObjectId,
    OBJECT_ID('grac_practice.organization_requirement') OrganizationRequirementObjectId,
    OBJECT_ID('GRAC_New.control_requirement_map') RepositoryControlRequirementMapObjectId,
    OBJECT_ID('GRAC_New.requirement') RepositoryRequirementObjectId;

SELECT
    'Selected Organization' Section,
    o.organization_id,
    o.organization_code,
    o.organization_name,
    o.status
FROM grac_practice.organization o
WHERE o.organization_id = @OrganizationId;

SELECT
    'Applicable Organization Controls' Section,
    oc.organization_control_id,
    oc.organization_id,
    oc.control_code,
    oc.control_name,
    oc.origin_type,
    oc.repository_control_id,
    oc.applicability_status,
    oc.applicability_status_id,
    oc.status,
    oc.record_status_id
FROM grac_practice.organization_control oc
WHERE oc.organization_id = @OrganizationId
  AND (@OrganizationControlId IS NULL OR oc.organization_control_id = @OrganizationControlId)
  AND (
      oc.applicability_status = 'Applicable'
      OR oc.applicability_status_id = @ApplicableStatusId
  )
ORDER BY oc.control_code;

SELECT
    'Applicable Controls With Repository Requirement Mapping' Section,
    oc.organization_control_id,
    oc.control_code OrgControlCode,
    oc.repository_control_id,
    rc.control_code RepositoryControlCode,
    rc_code.control_id RepositoryControlIdByCode,
    CASE
        WHEN rc.control_id IS NOT NULL THEN 'Matched by RepositoryControlID'
        WHEN rc_code.control_id IS NOT NULL THEN 'Matched by ControlCode'
        ELSE 'No repository control match'
    END RepositoryControlMatchType,
    crm.control_requirement_map_id,
    q.requirement_id,
    q.requirement_code,
    q.requirement_name,
    crm.status MappingStatus,
    q.status RequirementStatus
FROM grac_practice.organization_control oc
LEFT JOIN GRAC_New.control rc
    ON rc.control_id = oc.repository_control_id
LEFT JOIN GRAC_New.control rc_code
    ON rc_code.control_code = oc.control_code
LEFT JOIN GRAC_New.control_requirement_map crm
    ON crm.control_id = COALESCE(rc.control_id, rc_code.control_id)
   AND crm.status = 'Active'
LEFT JOIN GRAC_New.requirement q
    ON q.requirement_id = crm.requirement_id
   AND q.status = 'Active'
WHERE oc.organization_id = @OrganizationId
  AND (@OrganizationControlId IS NULL OR oc.organization_control_id = @OrganizationControlId)
  AND (
      oc.applicability_status = 'Applicable'
      OR oc.applicability_status_id = @ApplicableStatusId
  )
ORDER BY oc.control_code, q.requirement_code;

IF @OrganizationControlId IS NULL
BEGIN
    SELECT TOP (1) @OrganizationControlId = oc.organization_control_id
    FROM grac_practice.organization_control oc
    JOIN GRAC_New.control repo_control
        ON (repo_control.control_id = oc.repository_control_id OR repo_control.control_code = oc.control_code)
       AND repo_control.status = 'Active'
    JOIN GRAC_New.control_requirement_map crm
        ON crm.control_id = repo_control.control_id
       AND crm.status = 'Active'
    JOIN GRAC_New.requirement q
        ON q.requirement_id = crm.requirement_id
       AND q.status = 'Active'
    WHERE oc.organization_id = @OrganizationId
      AND (
          oc.applicability_status = 'Applicable'
          OR oc.applicability_status_id = @ApplicableStatusId
      )
    ORDER BY oc.organization_control_id;
END;

SELECT
    'Procedure Control Context' Section,
    @RequestedOrganizationControlId RequestedOrganizationControlId,
    @OrganizationControlId EffectiveOrganizationControlId,
    CASE
        WHEN @RequestedOrganizationControlId IS NOT NULL THEN 'User supplied control context'
        WHEN @OrganizationControlId IS NOT NULL THEN 'Auto-selected first applicable control with active repository requirement mappings'
        ELSE 'No applicable organization control with active repository requirement mappings was found'
    END ContextResolution;

SELECT
    'Organization Requirements Already Imported' Section,
    q.organization_requirement_id,
    q.organization_id,
    q.organization_control_id,
    q.repository_requirement_id,
    q.requirement_code,
    q.requirement_name,
    q.applicability_status,
    q.implementation_status,
    q.status
FROM grac_practice.organization_requirement q
WHERE q.organization_id = @OrganizationId
  AND (@OrganizationControlId IS NULL OR q.organization_control_id = @OrganizationControlId)
ORDER BY q.requirement_code;

SELECT
    'Summary' Section,
    (SELECT COUNT_BIG(1)
     FROM grac_practice.organization_control oc
     WHERE oc.organization_id = @OrganizationId
       AND (@OrganizationControlId IS NULL OR oc.organization_control_id = @OrganizationControlId)
       AND (oc.applicability_status = 'Applicable' OR oc.applicability_status_id = @ApplicableStatusId)) ApplicableOrgControls,
    (SELECT COUNT_BIG(1)
     FROM grac_practice.organization_control oc
     JOIN GRAC_New.control repo_control
       ON (repo_control.control_id = oc.repository_control_id OR repo_control.control_code = oc.control_code)
      AND repo_control.status = 'Active'
     JOIN GRAC_New.control_requirement_map crm
       ON crm.control_id = repo_control.control_id
      AND crm.status = 'Active'
     JOIN GRAC_New.requirement rq
       ON rq.requirement_id = crm.requirement_id
      AND rq.status = 'Active'
     WHERE oc.organization_id = @OrganizationId
       AND (@OrganizationControlId IS NULL OR oc.organization_control_id = @OrganizationControlId)
       AND (oc.applicability_status = 'Applicable' OR oc.applicability_status_id = @ApplicableStatusId)) ActiveRepositoryMappings,
    (SELECT COUNT_BIG(1)
     FROM grac_practice.organization_requirement q
     WHERE q.organization_id = @OrganizationId
       AND (@OrganizationControlId IS NULL OR q.organization_control_id = @OrganizationControlId)) ImportedOrganizationRequirements;

DECLARE @ProcedurePayload NVARCHAR(MAX) = (
    SELECT
        @OrganizationId organizationId,
        @OrganizationControlId organizationControlId,
        1 pageNumber,
        25 pageSize
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);

SELECT
    'Procedure Payload' Section,
    @ProcedurePayload Payload;

IF @OrganizationControlId IS NULL
BEGIN
    SELECT
        'Procedure Result' Section,
        'Skipped' Status,
        'Control context is required to load requirements, and no applicable organization control with active repository requirement mappings was found.' Message;
END
ELSE
BEGIN
    EXEC dbo.pm_get_practice_repository
        @p_entity_type = 'organization-requirements',
        @p_action = 'QUERY',
        @p_id = 0,
        @p_search = N'',
        @p_status = N'',
        @p_payload = @ProcedurePayload,
        @p_usr_id = N'diagnostic';
END;
