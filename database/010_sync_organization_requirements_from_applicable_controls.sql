/*
  GRAC Part 2 - Practice Management
  Backfill Organization Requirements for controls already marked Applicable.

  Run in GRAC_NewPhase after deploying 002_practice_management_procedures.sql.
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51500, 'Schema grac_practice is missing.', 1;

DECLARE @ActiveRecordStatusId INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
DECLARE @NotUpdatedApplicabilityStatusId INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
DECLARE @NotStartedImplementationStatusId INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');
DECLARE @ApplicableStatusId INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable');

IF @ActiveRecordStatusId IS NULL OR @NotUpdatedApplicabilityStatusId IS NULL OR @NotStartedImplementationStatusId IS NULL
    THROW 51501, 'Practice status master values are missing. Run 008_normalize_practice_status_master.sql first.', 1;

DECLARE @BeforeRows BIGINT=(SELECT COUNT_BIG(1) FROM grac_practice.organization_requirement);
DECLARE @CandidateRows BIGINT=(
    SELECT COUNT_BIG(1)
    FROM grac_practice.organization_control oc
    JOIN GRAC_New.control repo_control ON (repo_control.control_id=oc.repository_control_id OR repo_control.control_code=oc.control_code) AND repo_control.status='Active'
    JOIN GRAC_New.control_requirement_map crm ON crm.control_id=repo_control.control_id AND crm.status='Active'
    JOIN GRAC_New.requirement q ON q.requirement_id=crm.requirement_id AND q.status='Active'
    WHERE ISNULL(oc.origin_type,'Repository') IN ('Repository','Hybrid')
      AND (oc.applicability_status_id=@ApplicableStatusId OR oc.applicability_status='Applicable')
);

;WITH requirement_candidates AS (
    SELECT
        oc.organization_id,
        'Repository' origin_type,
        q.requirement_id repository_requirement_id,
        oc.organization_control_id,
        q.requirement_code,
        q.requirement_name,
        q.requirement_statement,
        q.objective,
        ROW_NUMBER() OVER(
            PARTITION BY oc.organization_id,oc.organization_control_id,q.requirement_code
            ORDER BY q.requirement_id
        ) row_no
    FROM grac_practice.organization_control oc
JOIN GRAC_New.control repo_control ON (repo_control.control_id=oc.repository_control_id OR repo_control.control_code=oc.control_code) AND repo_control.status='Active'
JOIN GRAC_New.control_requirement_map crm ON crm.control_id=repo_control.control_id AND crm.status='Active'
    JOIN GRAC_New.requirement q ON q.requirement_id=crm.requirement_id AND q.status='Active'
    WHERE ISNULL(oc.origin_type,'Repository') IN ('Repository','Hybrid')
      AND (oc.applicability_status_id=@ApplicableStatusId OR oc.applicability_status='Applicable')
)
INSERT grac_practice.organization_requirement(
    organization_id,
    origin_type,
    repository_requirement_id,
    organization_control_id,
    requirement_code,
    requirement_name,
    requirement_statement,
    objective,
    applicability_status,
    applicability_status_id,
    implementation_status,
    implementation_status_id,
    status,
    record_status_id,
    entered_by)
SELECT
    c.organization_id,
    c.origin_type,
    c.repository_requirement_id,
    c.organization_control_id,
    c.requirement_code,
    c.requirement_name,
    c.requirement_statement,
    c.objective,
    'Not Updated',
    @NotUpdatedApplicabilityStatusId,
    'Not Started',
    @NotStartedImplementationStatusId,
    'Active',
    @ActiveRecordStatusId,
    'system-sync'
FROM requirement_candidates c
WHERE c.row_no=1
  AND NOT EXISTS(
      SELECT 1
      FROM grac_practice.organization_requirement existing
      WHERE existing.organization_id=c.organization_id
        AND existing.organization_control_id=c.organization_control_id
        AND (
            existing.requirement_code=c.requirement_code
            OR existing.repository_requirement_id=c.repository_requirement_id
        )
  );

SELECT
    @BeforeRows BeforeRows,
    COUNT_BIG(1) AfterRows,
    COUNT_BIG(1)-@BeforeRows InsertedRows,
    @CandidateRows CandidateMappedRows,
    @CandidateRows-(COUNT_BIG(1)-@BeforeRows) SkippedExistingRows
FROM grac_practice.organization_requirement;
