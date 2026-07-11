/*
  GRAC Part 2 - Practice Management
  Verify Practice action-menu status inputs.

  Set @PracticeId to the row where the 3-dot menu is being reviewed.
  Run in GRAC_NewPhase.
*/

SET NOCOUNT ON;

DECLARE @PracticeId BIGINT = NULL; -- TODO: set selected practice_id

IF @PracticeId IS NULL
BEGIN
    SELECT TOP (50)
        p.practice_id PracticeId,
        p.organization_id OrganizationId,
        p.organization_requirement_id OrganizationRequirementId,
        p.practice_code PracticeCode,
        p.practice_name PracticeName,
        p.applicability_status_id ApplicabilityStatusId,
        aps.status_code ApplicabilityStatusCode,
        COALESCE(aps.status_name,p.applicability_status) ApplicabilityStatusName,
        p.status RecordStatus
    FROM grac_practice.practice p
    LEFT JOIN grac_practice.applicability_status_master aps
        ON aps.applicability_status_id=p.applicability_status_id
    ORDER BY p.practice_id DESC;

    SELECT 'Set @PracticeId to one of the PracticeId values above and rerun for a focused check.' Message;
    RETURN;
END;

SELECT
    p.practice_id PracticeId,
    p.organization_id OrganizationId,
    p.organization_requirement_id OrganizationRequirementId,
    p.practice_code PracticeCode,
    p.practice_name PracticeName,
    p.applicability_status_id ApplicabilityStatusId,
    aps.status_code ApplicabilityStatusCode,
    COALESCE(aps.status_name,p.applicability_status) ApplicabilityStatusName,
    CASE
        WHEN aps.status_code='Not Updated' OR p.applicability_status='Not Updated' THEN 'Expected menu: Mark Applicability, View'
        WHEN aps.status_code='Applicable' OR p.applicability_status='Applicable' THEN 'Expected menu: Practice Instances, View'
        WHEN aps.status_code IN ('Not Applicable','Deferred','Accepted Risk') OR p.applicability_status IN ('Not Applicable','Deferred','Accepted Risk') THEN 'Expected menu: Update Applicability, View'
        ELSE 'Unexpected applicability status. Review master/status data.'
    END ExpectedActionMenu,
    p.status RecordStatus
FROM grac_practice.practice p
LEFT JOIN grac_practice.applicability_status_master aps
    ON aps.applicability_status_id=p.applicability_status_id
WHERE p.practice_id=@PracticeId;
