-- ============================================================================
-- ISO Controls Import to GRAC v1.0
-- Phase 5 -- Import ISO controls into an Organization (initial applicability
--            = "Not Updated"). Mirrors the applicability logic used by
--            grac_practice.sp_sync_organization_controls_from_subscriptions.
--            NO organization_requirement (Practices) are created here --
--            Practices materialize when the user Marks Applicability on a
--            Control.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @release_id      BIGINT = /* <FILL_IN> */ NULL;
DECLARE @organization_id BIGINT = /* <FILL_IN> */ NULL;
DECLARE @actor           NVARCHAR(100) = 'iso-import-v1.0';

IF @release_id IS NULL OR @organization_id IS NULL
BEGIN
    RAISERROR('Set @release_id and @organization_id.', 16, 1);
    RETURN;
END

-- Resolve the enum ids the app uses.
DECLARE @active_record_status_id INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
DECLARE @not_updated_applicability_status_id INT = (
    SELECT TOP 1 applicability_status_id FROM grac_practice.applicability_status_master
    WHERE status_code = 'NOT_UPDATED' OR status_name = 'Not Updated' ORDER BY applicability_status_id);
DECLARE @active_subscription_status_id INT = (
    SELECT TOP 1 subscription_status_id FROM grac_practice.subscription_status_master
    WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY subscription_status_id);

IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

-- Locate the caller's active subscription to this release. Required so the
-- inserted organization_control rows have a valid subscription_id + artifact_id.
DECLARE @subscription_id BIGINT;
DECLARE @artifact_id     BIGINT;
SELECT TOP 1 @subscription_id = s.subscription_id,
             @artifact_id     = COALESCE(s.artifact_id, r.artifact_id)
FROM grac_practice.repository_subscription s
JOIN grac_new.release r ON r.release_id = s.release_id
WHERE s.organization_id      = @organization_id
  AND s.release_id           = @release_id
  AND s.record_status_id     = @active_record_status_id
  AND s.subscription_status_id = @active_subscription_status_id;

IF @subscription_id IS NULL
BEGIN
    RAISERROR('Organization has no active subscription to this release. Subscribe first via Repository Subscriptions.', 16, 1);
    RETURN;
END

BEGIN TRAN;

-- Insert one organization_control per repository control for this release.
-- applicability_status = 'Not Updated' (the "no decision made yet" default).
-- Skips controls already present so the script is safe to re-run.
INSERT INTO grac_practice.organization_control (
    organization_id, origin_type, repository_control_id,
    control_code, control_name, description, objective,
    control_domain_id, control_sub_domain_id,
    is_manually_added, subscription_id, release_id, artifact_id,
    applicability_status, applicability_status_id,
    criticality, status, record_status_id, entered_by
)
SELECT
    @organization_id, N'Repository', c.control_id,
    c.control_code, c.control_name, c.description, c.objective,
    c.control_domain_id, c.control_sub_domain_id,
    0, @subscription_id, @release_id, @artifact_id,
    N'Not Updated', @not_updated_applicability_status_id,
    N'Medium', N'Active', @active_record_status_id, @actor
FROM grac_new.source_control_map scm
JOIN grac_new.source_structure_node n
     ON n.structure_node_id = scm.structure_node_id
    AND n.release_id = @release_id
JOIN grac_new.control c ON c.control_id = scm.control_id AND c.status = N'Active'
WHERE scm.status = N'Active'
  AND NOT EXISTS (
      SELECT 1 FROM grac_practice.organization_control oc
      WHERE oc.organization_id       = @organization_id
        AND oc.release_id            = @release_id
        AND oc.repository_control_id = c.control_id
  );

COMMIT;

SELECT 'Phase 5 organization controls imported' AS Result,
       COUNT(*) AS ControlsForOrg
FROM grac_practice.organization_control oc
WHERE oc.organization_id = @organization_id AND oc.release_id = @release_id;
GO
