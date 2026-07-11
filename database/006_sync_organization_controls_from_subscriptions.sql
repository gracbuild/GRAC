/*
  GRAC Part 2 - Backfill OrganizationControl from active repository subscriptions.

  Use this after deploying the OrganizationControl import design, especially when
  organizations were subscribed before the import logic was added.

  Expected database:
    - Practice schema: grac_practice
    - Repository schema: grac_new
*/
SET NOCOUNT ON;

IF OBJECT_ID('grac_practice.organization_control','U') IS NULL
 THROW 51100, 'Missing grac_practice.organization_control. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
 THROW 51101, 'Missing grac_practice.repository_subscription. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_new.source_control_map','U') IS NULL
 THROW 51102, 'Missing grac_new.source_control_map. Run ControlManagement repository scripts first.', 1;

IF OBJECT_ID('grac_new.source_structure_node','U') IS NULL
 THROW 51103, 'Missing grac_new.source_structure_node. Run ControlManagement repository scripts first.', 1;

IF OBJECT_ID('grac_new.control','U') IS NULL
 THROW 51104, 'Missing grac_new.control. Run ControlManagement repository scripts first.', 1;

DECLARE @before_count BIGINT=(SELECT COUNT_BIG(1) FROM grac_practice.organization_control);

;WITH active_subscriptions AS (
 SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
 FROM grac_practice.repository_subscription s
 JOIN grac_new.release r ON r.release_id=s.release_id
 WHERE s.status='Active'
   AND s.subscription_status='Active'
   AND s.release_id IS NOT NULL
),
repository_controls AS (
 SELECT DISTINCT
   s.organization_id,
   s.subscription_id,
   scm.control_id,
   c.control_code,
   c.control_name,
   c.description,
   c.objective,
   c.control_domain_id,
   c.control_sub_domain_id,
   COALESCE(scm.release_id,n.release_id,s.release_id) release_id,
   COALESCE(scm.artifact_id,s.artifact_id) artifact_id
 FROM active_subscriptions s
 JOIN grac_new.source_control_map scm ON COALESCE(scm.release_id,s.release_id)=s.release_id OR scm.release_id IS NULL
 JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id AND n.release_id=s.release_id
 JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
 WHERE scm.status='Active' AND n.status='Active'
)
UPDATE oc SET
 control_code=rc.control_code,
 control_name=rc.control_name,
 description=rc.description,
 objective=rc.objective,
 control_domain_id=rc.control_domain_id,
 control_sub_domain_id=rc.control_sub_domain_id,
 subscription_id=rc.subscription_id,
 artifact_id=rc.artifact_id,
 status='Active',
 origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
 is_manually_added=0,
 updated_by='sync',
 updated_dt=SYSUTCDATETIME()
FROM grac_practice.organization_control oc
JOIN repository_controls rc ON rc.organization_id=oc.organization_id AND rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id;

;WITH active_subscriptions AS (
 SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
 FROM grac_practice.repository_subscription s
 JOIN grac_new.release r ON r.release_id=s.release_id
 WHERE s.status='Active'
   AND s.subscription_status='Active'
   AND s.release_id IS NOT NULL
),
repository_controls AS (
 SELECT DISTINCT
   s.organization_id,
   s.subscription_id,
   scm.control_id,
   c.control_code,
   c.control_name,
   c.description,
   c.objective,
   c.control_domain_id,
   c.control_sub_domain_id,
   COALESCE(scm.release_id,n.release_id,s.release_id) release_id,
   COALESCE(scm.artifact_id,s.artifact_id) artifact_id
 FROM active_subscriptions s
 JOIN grac_new.source_control_map scm ON COALESCE(scm.release_id,s.release_id)=s.release_id OR scm.release_id IS NULL
 JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id AND n.release_id=s.release_id
 JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
 WHERE scm.status='Active' AND n.status='Active'
)
INSERT grac_practice.organization_control(
 organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
 is_manually_added,subscription_id,release_id,artifact_id,applicability_status,criticality,status,entered_by)
SELECT rc.organization_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
 0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated','Medium','Active','sync'
FROM repository_controls rc
WHERE NOT EXISTS(
 SELECT 1
 FROM grac_practice.organization_control oc
 WHERE oc.organization_id=rc.organization_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
);

UPDATE oc SET status='Inactive',updated_by='sync',updated_dt=SYSUTCDATETIME()
FROM grac_practice.organization_control oc
WHERE oc.is_manually_added=0
  AND oc.release_id IS NOT NULL
  AND NOT EXISTS(
    SELECT 1
    FROM grac_practice.repository_subscription s
    WHERE s.organization_id=oc.organization_id
      AND s.release_id=oc.release_id
      AND s.status='Active'
      AND s.subscription_status='Active'
  );

DECLARE @after_count BIGINT=(SELECT COUNT_BIG(1) FROM grac_practice.organization_control);

SELECT 'ActiveSubscriptions' Metric, COUNT_BIG(1) Cnt
FROM grac_practice.repository_subscription
WHERE status='Active' AND subscription_status='Active'
UNION ALL
SELECT 'ReleaseControlMappings', COUNT_BIG(1)
FROM grac_new.source_control_map
WHERE status='Active'
UNION ALL
SELECT 'OrganizationControlsBefore', @before_count
UNION ALL
SELECT 'OrganizationControlsAfter', @after_count
UNION ALL
SELECT 'OrganizationControlsInserted', @after_count-@before_count;

SELECT TOP 50
 oc.organization_id OrganizationID,
 oc.organization_control_id OrgControlID,
 oc.control_code ControlCode,
 oc.control_name ControlName,
 oc.origin_type OriginType,
 oc.release_id ReleaseID,
 oc.status Status
FROM grac_practice.organization_control oc
ORDER BY oc.updated_dt DESC,oc.entered_dt DESC,oc.organization_control_id DESC;
