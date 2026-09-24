-- =====================================================================
-- 300_generic_grid_total_rows.sql
--
-- PURPOSE
--   Re-emit dbo.pm_get_practice_repository with
--   COUNT(*) OVER () AS TotalRows appended to every paged branch, so the
--   generic grid (Views/Practice/Manage.cshtml + wwwroot/js/practice.js)
--   can adopt pm-grid and page like every other list in the module.
--
-- ---------------------------------------------------------------------
-- WHY -- TWO FAULTS, ONE PROCEDURE
-- ---------------------------------------------------------------------
-- 1. NO TOTAL. Thirty-seven branches of this procedure page with
--    OFFSET/FETCH and not one of them returns a count. Every newer
--    procedure in the schema does -- 147, 151, 162, 170, 193, 206, 290 --
--    which is why Risk Centre, Exception Centre, Operationalize and the
--    workflow partials can all draw "26-50 of 93" while the generic grid
--    can only say "Page 2". Worse, with no total the grid has to guess
--    whether a next page exists:
--
--        nextPage.disabled = state.records.length < state.pageSize;
--
--    which is wrong on the exact boundary where the last page is full.
--    50 rows at 25 per page leaves Next enabled on page 2, and clicking
--    it lands the user on an empty grid. This is the guess that
--    docs/grid-and-pagination-standard.md exists to remove, and the
--    generic grid is the last screen family still making it.
--
-- 2. DRIFT. Practice/Index/organization-controls was observed returning
--    all 93 rows for a pageSize=25 request. The 002 baseline pages that
--    branch correctly, so the deployed copy of this procedure predates
--    the baseline. Re-emitting the whole procedure re-lands the paging
--    as well as adding the total: after this migration the deployed
--    definition is known, not assumed.
--
-- ---------------------------------------------------------------------
-- WHY THE WHOLE PROCEDURE
-- ---------------------------------------------------------------------
-- CREATE OR ALTER replaces a procedure whole; there is no way to patch
-- thirty-seven projections in place. The body below is 002's, character
-- for character, with exactly one edit repeated per paged branch:
--
--        ...,rs.status_name Status,COUNT(*) OVER () AS TotalRows
--        FROM ...
--
-- The column goes LAST in the projection -- the shape every other paged
-- procedure uses, so PracticeRepositoryService reads it with the same
-- reader loop it already has and pm-grid consumes it with no special
-- case. Nothing else changed: no filter, no join, no ORDER BY, no
-- OFFSET/FETCH, no parameter, no clamp. @page_size still defaults to 25
-- and is still capped at 200.
--
-- The window is evaluated over the filtered set BEFORE OFFSET/FETCH
-- trims it, so it reports the whole result, not the page. In the three
-- grouped branches (practice-health / audit-intelligence /
-- risk-intelligence, and assurance-trends) it counts groups, which is
-- the number of rows the grid receives -- which is what a pager needs.
--
-- ---------------------------------------------------------------------
-- IMPACT ON CALLERS
-- ---------------------------------------------------------------------
-- Additive. Every consumer reads columns by name:
--   * PracticeRepositoryService.ReadTablesAsync builds a dictionary per
--     row, so an extra key is carried and ignored.
--   * practice.js renders screen.Columns only, and reads form fields
--     through valueOf(record, name).
-- No screen shows a TotalRows column unless its Columns array names one,
-- and none does.
--
-- menu-master is NOT in this procedure's paged set -- it is served by
-- QueryMenuMasterAsync in C# and is untouched here. The five C# fallback
-- queries that shadow branches of this procedure are updated in the same
-- change so both paths report the same total.
--
-- 002_practice_management_procedures.sql remains the baseline and is not
-- edited; a pointer comment there names this file as the current
-- definition, so the next person to change a branch changes it here.
--
-- NO SCHEMA CHANGE. NO DATA CHANGE. One procedure, replaced.
-- Rollback: 300_generic_grid_total_rows_rollback.sql
-- =====================================================================

CREATE OR ALTER PROCEDURE dbo.pm_get_practice_repository
 @p_entity_type NVARCHAR(100), @p_action NVARCHAR(30)='', @p_id BIGINT=0, @p_search NVARCHAR(250)='', @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}', @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON;
 SET @p_entity_type=ISNULL(@p_entity_type,'');
 SET @p_action=ISNULL(@p_action,'');
 SET @p_search=ISNULL(@p_search,'');
 SET @p_status=ISNULL(@p_status,'');
 SET @p_payload=ISNULL(NULLIF(@p_payload,''),'{}');
 SET @p_usr_id=ISNULL(@p_usr_id,'');
 DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId'));
 DECLARE @organization_control_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationControlId'));
 DECLARE @organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationRequirementId'));
 DECLARE @practice_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.practiceId'));
 DECLARE @practice_instance_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.practiceInstanceId'));
 DECLARE @assurance_activity_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.assuranceActivityId'));
 DECLARE @page_number INT=ISNULL(NULLIF(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
 DECLARE @page_size INT=ISNULL(NULLIF(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.pageSize')),0),25);
 DECLARE @owner NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.owner'),'');
 DECLARE @criticality NVARCHAR(30)=NULLIF(JSON_VALUE(@p_payload,'$.criticality'),'');
 DECLARE @origin_type NVARCHAR(30)=NULLIF(JSON_VALUE(@p_payload,'$.originType'),'');
 DECLARE @date_from DATETIME2=TRY_CONVERT(DATETIME2,JSON_VALUE(@p_payload,'$.dateFrom'));
 DECLARE @date_to DATETIME2=TRY_CONVERT(DATETIME2,JSON_VALUE(@p_payload,'$.dateTo'));
 IF @page_number<1 SET @page_number=1;
 IF @page_size<1 SET @page_size=25;
 IF @page_size>200 SET @page_size=200;
 DECLARE @offset INT=(@page_number-1)*@page_size;
 DECLARE @active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
 DECLARE @inactive_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Inactive');
 DECLARE @filter_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=@p_status OR status_name=@p_status);
 DECLARE @active_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
 DECLARE @filter_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=@p_status OR status_name=@p_status);
 DECLARE @is_system_admin BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$._security.isSystemAdmin'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
 DECLARE @allowed_organizations TABLE(organization_id BIGINT PRIMARY KEY);
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT organization_id
 FROM grac_practice.user_organization_map
 WHERE user_email=@p_usr_id
   AND status='Active'
   AND record_status_id=@active_record_status_id;
 INSERT @allowed_organizations(organization_id)
 SELECT DISTINCT e.organization_id
 FROM grac_practice.organization_employee e
 WHERE e.status='Active'
   AND (e.email=@p_usr_id OR e.employee_code=@p_usr_id)
   AND NOT EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id);
 IF @organization_id IS NOT NULL
    AND @is_system_admin=0
    AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@organization_id)
   THROW 51052,'You do not have access to the selected organization.',1;
 IF @organization_id IS NULL
    AND @is_system_admin=0
    AND @p_entity_type='dashboard-summary'
   SELECT TOP (1) @organization_id=organization_id FROM @allowed_organizations ORDER BY organization_id;
 IF @organization_id IS NULL
    AND @is_system_admin=0
    AND @p_entity_type NOT IN ('lookups','audit-trace')
   SET @organization_id=-1;
 DECLARE @not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
 DECLARE @not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');
 DECLARE @payload_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.status') OR status_name=JSON_VALUE(@p_payload,'$.status'));
 DECLARE @payload_record_status_id_from_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
 SET @payload_record_status_id=COALESCE(@payload_record_status_id_from_id,@payload_record_status_id);
 DECLARE @payload_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.subscriptionStatus') OR status_name=JSON_VALUE(@p_payload,'$.subscriptionStatus'));
 DECLARE @payload_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.applicabilityStatus') OR status_name=JSON_VALUE(@p_payload,'$.applicabilityStatus'));
 DECLARE @payload_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.implementationStatus') OR status_name=JSON_VALUE(@p_payload,'$.implementationStatus'));

 IF @p_entity_type IN ('organization-controls','control-applicability')
 BEGIN
   ;WITH active_subscriptions AS (
     SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
     FROM grac_practice.repository_subscription s
     JOIN grac_new.release r ON r.release_id=s.release_id
     WHERE s.record_status_id=@active_record_status_id
       AND s.subscription_status_id=@active_subscription_status_id
       AND s.release_id IS NOT NULL
       AND (@organization_id IS NULL OR s.organization_id=@organization_id)
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
     record_status_id=@active_record_status_id,
     origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
     is_manually_added=0,
     updated_by=COALESCE(NULLIF(@p_usr_id,''),'system'),
     updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   JOIN repository_controls rc ON rc.organization_id=oc.organization_id AND rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id;

   ;WITH active_subscriptions AS (
     SELECT s.subscription_id,s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
     FROM grac_practice.repository_subscription s
     JOIN grac_new.release r ON r.release_id=s.release_id
     WHERE s.record_status_id=@active_record_status_id
       AND s.subscription_status_id=@active_subscription_status_id
       AND s.release_id IS NOT NULL
       AND (@organization_id IS NULL OR s.organization_id=@organization_id)
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
     is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
   SELECT rc.organization_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
     0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
   FROM repository_controls rc
   WHERE NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_control oc
     WHERE oc.organization_id=rc.organization_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
   );
 END

 IF @p_entity_type='lookups'
 BEGIN
   SELECT 'organizations' LookupKey,CAST(o.organization_id AS NVARCHAR(40)) [Value],o.organization_code+' - '+o.organization_name Label,CAST(NULL AS BIGINT) OrganizationId
   FROM grac_practice.organization o
   WHERE o.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=o.organization_id))
   UNION ALL SELECT 'divisions',CAST(d.division_id AS NVARCHAR(40)),d.division_code+' - '+d.division_name,d.organization_id FROM grac_practice.organization_division d WHERE d.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=d.organization_id))
   UNION ALL SELECT 'location-types',CAST(location_type_id AS NVARCHAR(40)),location_type_name,CAST(NULL AS BIGINT) FROM grac_practice.location_type_master WHERE is_active=1
   UNION ALL SELECT 'locations',CAST(l.location_id AS NVARCHAR(40)),l.location_name,l.organization_id FROM grac_practice.organization_location l WHERE l.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=l.organization_id))
   UNION ALL SELECT 'business-functions',CAST(bf.business_function_id AS NVARCHAR(40)),bf.function_code+' - '+bf.function_name,bf.organization_id FROM grac_practice.organization_business_function bf WHERE bf.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=bf.organization_id))
   UNION ALL SELECT 'departments',CAST(d.department_id AS NVARCHAR(40)),d.department_code+' - '+d.department_name,d.organization_id FROM grac_practice.organization_department d WHERE d.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=d.organization_id))
   UNION ALL SELECT 'teams',CAST(t.team_id AS NVARCHAR(40)),t.team_name,t.organization_id FROM grac_practice.organization_team t WHERE t.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=t.organization_id))
   UNION ALL SELECT 'committees',CAST(c.committee_id AS NVARCHAR(40)),c.committee_name,c.organization_id FROM grac_practice.organization_committee c WHERE c.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=c.organization_id))
    UNION ALL SELECT 'employees',e.employee_name,e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'employees-id',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users',e.employee_name,e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users-id',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'users-detail',CAST(e.employee_id AS NVARCHAR(40)),e.employee_code+' - '+e.employee_name,e.organization_id FROM grac_practice.organization_employee e WHERE e.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=e.organization_id))
    UNION ALL SELECT 'roles',CAST(r.role_id AS NVARCHAR(40)),r.role_name,r.organization_id FROM grac_practice.organization_role r WHERE r.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=r.organization_id))
    UNION ALL SELECT 'menus',CAST(m.menu_id AS NVARCHAR(40)),m.menu_name,NULL FROM grac_practice.menu_master m WHERE m.status='Active'
   UNION ALL SELECT 'practices',CAST(p.practice_id AS NVARCHAR(40)),p.practice_code+' - '+p.practice_name,p.organization_id FROM grac_practice.practice p WHERE p.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=p.organization_id))
   UNION ALL SELECT 'practice-instances',CAST(pi.practice_instance_id AS NVARCHAR(40)),pi.instance_code+' - '+pi.instance_name,pi.organization_id FROM grac_practice.practice_instance pi WHERE pi.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=pi.organization_id))
   UNION ALL SELECT 'status-active',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.record_status_master WHERE is_active=1 AND status_code IN ('Active','Inactive')
   UNION ALL SELECT 'record-status',CAST(record_status_id AS NVARCHAR(40)),status_name,CAST(NULL AS BIGINT) FROM grac_practice.record_status_master WHERE is_active=1
   UNION ALL SELECT 'applicability-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.applicability_status_master WHERE is_active=1
   UNION ALL SELECT 'subscription-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.subscription_status_master WHERE is_active=1
   UNION ALL SELECT 'implementation-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.implementation_status_master WHERE is_active=1
   UNION ALL
   SELECT 'frequency-master',CAST(frequency_id AS NVARCHAR(40)),frequency_name,CAST(NULL AS BIGINT)
   FROM (
     SELECT frequency_id,frequency_name,ROW_NUMBER() OVER(
       PARTITION BY LOWER(LTRIM(RTRIM(COALESCE(NULLIF(frequency_code,N''),frequency_name))))
       ORDER BY display_order,frequency_id
     ) row_no
     FROM grac_practice.frequency_master
     WHERE is_active=1
   ) frequency_lookup
   WHERE row_no=1
   UNION ALL SELECT 'dependency-types',CAST(dependency_type_id AS NVARCHAR(40)),dependency_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_type_master WHERE is_active=1
   UNION ALL SELECT 'evidence-types',CAST(evidence_type_id AS NVARCHAR(40)),evidence_type_name,CAST(NULL AS BIGINT) FROM GRAC_New.evidence_type_master WHERE is_active=1
   UNION ALL SELECT 'collection-methods',CAST(collection_method_id AS NVARCHAR(40)),collection_method_name,CAST(NULL AS BIGINT) FROM grac_practice.collection_method_master WHERE is_active=1
   UNION ALL SELECT 'assurance-types',CAST(assurance_type_id AS NVARCHAR(40)),assurance_type_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_type_master WHERE is_active=1
   UNION ALL SELECT 'assurance-activity-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_activity_status_master WHERE is_active=1
   UNION ALL SELECT 'assurance-result-status',status_code,status_name,CAST(NULL AS BIGINT) FROM grac_practice.assurance_result_status_master WHERE is_active=1
   UNION ALL SELECT 'assurance-check-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Pending',N'Pending'),(N'Pass',N'Pass'),(N'Fail',N'Fail'),(N'Unable To Verify',N'Unable To Verify')) v(value,label)
   UNION ALL SELECT 'assurance-effectiveness',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Not Assessed',N'Not Assessed'),(N'Effective',N'Effective'),(N'Partially Effective',N'Partially Effective'),(N'Ineffective',N'Ineffective')) v(value,label)
   UNION ALL SELECT 'finding-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Open',N'Open'),(N'In Progress',N'In Progress'),(N'Resolved',N'Resolved'),(N'Closed',N'Closed')) v(value,label)
   UNION ALL SELECT 'signal-status',value,label,CAST(NULL AS BIGINT) FROM (VALUES(N'Open',N'Open'),(N'Acknowledged',N'Acknowledged'),(N'Closed',N'Closed')) v(value,label)
   UNION ALL SELECT 'assurance-eligible-instances',CAST(pi.practice_instance_id AS NVARCHAR(40)),pi.instance_code+N' - '+pi.instance_name,pi.organization_id
   FROM grac_practice.practice_instance pi
   JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
   WHERE pi.status=N'Active'
     AND NULLIF(pi.primary_owner,N'') IS NOT NULL
     AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
     AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
     AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=pi.organization_id))
   UNION ALL SELECT 'assurance-activities',CAST(aa.assurance_activity_id AS NVARCHAR(40)),aa.activity_number+N' - '+pi.instance_name,aa.organization_id
   FROM grac_practice.assurance_activity aa
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=aa.organization_id))
   UNION ALL SELECT 'evidence-alignment-status',CAST(alignment_status_id AS NVARCHAR(40)),alignment_status_name,CAST(NULL AS BIGINT) FROM grac_practice.evidence_alignment_status_master WHERE is_active=1
   UNION ALL SELECT 'criticality-master',CAST(criticality_id AS NVARCHAR(40)),criticality_name,CAST(NULL AS BIGINT) FROM grac_practice.criticality_master WHERE is_active=1
   UNION ALL SELECT 'hosting-types',CAST(hosting_type_id AS NVARCHAR(40)),hosting_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_hosting_type_master WHERE is_active=1
   UNION ALL SELECT 'license-types',CAST(license_type_id AS NVARCHAR(40)),license_type_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_license_type_master WHERE is_active=1
   UNION ALL SELECT 'service-categories',CAST(service_category_id AS NVARCHAR(40)),service_category_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_service_category_master WHERE is_active=1
   UNION ALL SELECT 'asset-categories',CAST(asset_category_id AS NVARCHAR(40)),asset_category_name,CAST(NULL AS BIGINT) FROM grac_practice.dependency_asset_category_master WHERE is_active=1
   UNION ALL SELECT 'dependency-vendors',CAST(v.vendor_id AS NVARCHAR(40)),v.vendor_name,v.organization_id FROM grac_practice.organization_dependency_vendor v WHERE v.status='Active' AND (@is_system_admin=1 OR EXISTS(SELECT 1 FROM @allowed_organizations a WHERE a.organization_id=v.organization_id))
   UNION ALL SELECT option_group,option_value,option_label,CAST(NULL AS BIGINT) FROM grac_practice.reference_option WHERE status='Active'
   UNION ALL SELECT 'industries',option_value,option_label,CAST(NULL AS BIGINT) FROM grac_new.reference_option WHERE option_group='industries' AND status='Active'
   UNION ALL SELECT 'countries',option_value,option_label,CAST(NULL AS BIGINT) FROM grac_new.reference_option WHERE option_group='jurisdictions' AND status='Active';
 END
 ELSE IF @p_entity_type='organization-setup'
 BEGIN
   SELECT organization_id Id,organization_code Code,organization_name Name,industry Industry,entity_type EntityType,country Country,status Status
   FROM grac_practice.organization
   WHERE organization_id=@organization_id;

   SELECT d.metadata_key MetadataKey,d.metadata_name MetadataName,d.data_type DataType,d.lookup_group LookupGroup,
     v.value_text ValueText,v.value_number ValueNumber,v.value_date ValueDate,v.value_bool ValueBool,v.value_json ValueJson
   FROM grac_practice.organization_metadata_definition d
   LEFT JOIN grac_practice.organization_metadata_value v ON v.metadata_definition_id=d.metadata_definition_id AND v.organization_id=@organization_id AND v.status='Active'
   WHERE d.status='Active'
   ORDER BY d.metadata_definition_id;

   SELECT au.authority_id AuthorityId,au.authority_code AuthorityCode,au.authority_name AuthorityName,
     a.artifact_id ArtifactId,a.artifact_code ArtifactCode,a.artifact_name ArtifactName,
     r.release_id ReleaseId,r.version_no ReleaseVersion,r.status ReleaseStatus,
     CASE WHEN s.subscription_id IS NOT NULL AND s.status='Active' AND s.subscription_status='Active' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END IsSubscribed
   FROM grac_new.authority au
   JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
   JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
   LEFT JOIN grac_practice.repository_subscription s ON s.organization_id=@organization_id AND s.release_id=r.release_id AND s.status='Active'
   WHERE au.status='Active'
   ORDER BY au.authority_code,a.artifact_code,r.version_no;
 END
 ELSE IF @p_entity_type='dashboard-summary'
 BEGIN
   IF @organization_id IS NULL AND @is_system_admin=1
     SELECT TOP (1) @organization_id=organization_id FROM grac_practice.organization WHERE status='Active' ORDER BY organization_id;

   SELECT
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active') TotalOrganizationControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')) NotUpdatedControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Applicable') ApplicableControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Not Applicable') NotApplicableControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Deferred') DeferredControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Accepted Risk') AcceptedRiskControls,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active') TotalPractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Applicable') ApplicablePractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')) NotUpdatedPractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice WHERE organization_id=@organization_id AND status='Active' AND applicability_status='Not Applicable') NotApplicablePractices,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active') TotalPracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active') ActivePracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active' AND criticality='Critical') CriticalPracticeInstances,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance WHERE organization_id=@organization_id AND status='Active' AND (primary_owner_id IS NULL AND NULLIF(LTRIM(RTRIM(primary_owner)),'') IS NULL)) InstancesWithoutOwner,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status='Active')) InstancesWithoutDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')) InstancesWithoutEvidenceConfiguration,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='TOOL' OR UPPER(dt.dependency_type_name)='TOOL' OR UPPER(d.dependency_type)='TOOL')) ToolDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='VENDOR' OR UPPER(dt.dependency_type_name)='VENDOR' OR UPPER(d.dependency_type)='VENDOR')) VendorDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='APPLICATION' OR UPPER(dt.dependency_type_name)='APPLICATION' OR UPPER(d.dependency_type)='APPLICATION')) ApplicationDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code)='ASSET' OR UPPER(dt.dependency_type_name)='ASSET' OR UPPER(d.dependency_type)='ASSET')) AssetDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id WHERE d.organization_id=@organization_id AND d.status='Active' AND (UPPER(dt.dependency_type_code) IN ('PERSON','PEOPLE','USER') OR UPPER(dt.dependency_type_name) IN ('PERSON','PEOPLE','USER') OR UPPER(d.dependency_type) IN ('PERSON','PEOPLE','USER'))) PersonDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status='Active')=1) SinglePointDependencies,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e WHERE e.organization_id=@organization_id AND e.status='Active') EvidenceConfiguredCount,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi WHERE pi.organization_id=@organization_id AND pi.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')) EvidenceNotConfiguredCount,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Aligned') AlignedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Enhanced') EnhancedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_evidence e JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id WHERE e.organization_id=@organization_id AND e.status='Active' AND s.alignment_status_code='Not Aligned') NotAlignedEvidence,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status='Pending') PendingResolveItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status='Resolved') ResolvedItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=@organization_id AND r.is_active=1 AND r.resolution_status IN ('Partially Resolved','Partial')) PartiallyResolvedItems,
    (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance_dependency d WHERE d.organization_id=@organization_id AND d.status='Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.organization_id=d.organization_id AND r.practice_instance_id=d.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status='Resolved')) OpenDependencyMappingItems;

   SELECT N'Controls still Not Updated' Title,
          COUNT_BIG(1) ItemCount,
          N'High' Severity,
          N'Organization controls need applicability decisions.' Detail,
          N'Practice/Index/organization-controls' Route
   FROM grac_practice.organization_control
   WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')
   UNION ALL
   SELECT N'Practices still Not Updated',COUNT_BIG(1),N'High',N'Practices need applicability decisions.',N'Practice/Index/organization-requirements'
   FROM grac_practice.practice
   WHERE organization_id=@organization_id AND status='Active' AND applicability_status IN ('Not Updated','Pending','')
   UNION ALL
   SELECT N'Applicable practices without instances',COUNT_BIG(1),N'High',N'Applicable practices require at least one practice instance.',N'Practice/Index/practice-instances'
   FROM grac_practice.practice p
   WHERE p.organization_id=@organization_id AND p.status='Active' AND p.applicability_status='Applicable'
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance pi WHERE pi.practice_id=p.practice_id AND pi.status='Active')
   UNION ALL
   SELECT N'Critical instances without evidence',COUNT_BIG(1),N'High',N'Critical practice instances need evidence configuration.',N'Practice/Index/evidence-configurations'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active' AND pi.criticality='Critical'
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')
   UNION ALL
   SELECT N'Instances with expired dependency',COUNT_BIG(DISTINCT pi.practice_instance_id),N'Medium',N'License, support, or vendor dates have expired.',N'Practice/Index/resolve'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active'
     AND EXISTS(
       SELECT 1
       FROM grac_practice.practice_dependency_resolution r
       LEFT JOIN grac_practice.organization_dependency_tool t ON t.tool_id=r.resolved_dependency_id AND r.dependency_category IN ('Tool','Tools')
       LEFT JOIN grac_practice.organization_dependency_application a ON a.application_id=r.resolved_dependency_id AND r.dependency_category IN ('Application','Applications')
       LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=r.resolved_dependency_id AND r.dependency_category IN ('Vendor','Vendors')
       WHERE r.practice_instance_id=pi.practice_instance_id
         AND r.organization_id=@organization_id
         AND r.is_active=1
         AND (
           t.license_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR t.support_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR a.support_expiry_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR a.end_of_life_dt<CONVERT(DATE,SYSUTCDATETIME())
           OR v.contract_end_dt<CONVERT(DATE,SYSUTCDATETIME())
         )
     )
   UNION ALL
   SELECT N'Evidence not aligned with obligations',COUNT_BIG(1),N'Medium',N'Evidence alignment is missing or marked Not Aligned.',N'Practice/Index/evidence-configurations'
   FROM grac_practice.practice_instance pi
   WHERE pi.organization_id=@organization_id AND pi.status='Active'
     AND (
       EXISTS(
         SELECT 1
         FROM grac_practice.practice_instance_evidence e
         JOIN grac_practice.evidence_alignment_status_master s ON s.alignment_status_id=e.alignment_status_id
         WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active' AND s.alignment_status_code='Not Aligned'
       )
       OR NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active')
     )
   ORDER BY ItemCount DESC, Severity;
 END
 ELSE IF @p_entity_type='applicability-recommendations'
 BEGIN
   DECLARE @industry NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.industry'),'');
   DECLARE @entity_type NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.entityType'),'');
   DECLARE @country NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.organization.country'),'');
   DECLARE @deposit_status NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.deposit_taking_status'),'');
   DECLARE @scale_class NVARCHAR(120)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.asset_size_scale'),'');
   DECLARE @registration_type NVARCHAR(160)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.regulatory_registration_type'),'');
   DECLARE @payment_aggregator NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.payment_aggregator_status'),'');
   DECLARE @investment_advisor NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.investment_advisor_status'),'');
   DECLARE @cloud_adoption NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.attributes.cloud_adoption'),'');
   DECLARE @stores_cardholder_data NVARCHAR(20)=LOWER(COALESCE(JSON_VALUE(@p_payload,'$.attributes.stores_cardholder_data'),'false'));

   DECLARE @values TABLE(attribute_key NVARCHAR(120), attribute_value NVARCHAR(200));
   INSERT @values(attribute_key,attribute_value)
   SELECT 'industry',@industry WHERE @industry IS NOT NULL
   UNION ALL SELECT 'entity_type',@entity_type WHERE @entity_type IS NOT NULL
   UNION ALL SELECT 'country',@country WHERE @country IS NOT NULL
   UNION ALL SELECT 'deposit_taking_status',@deposit_status WHERE @deposit_status IS NOT NULL
   UNION ALL SELECT 'asset_size_scale',@scale_class WHERE @scale_class IS NOT NULL
   UNION ALL SELECT 'regulatory_registration_type',@registration_type WHERE @registration_type IS NOT NULL
   UNION ALL SELECT 'payment_aggregator_status',@payment_aggregator WHERE @payment_aggregator IS NOT NULL
   UNION ALL SELECT 'investment_advisor_status',@investment_advisor WHERE @investment_advisor IS NOT NULL
   UNION ALL SELECT 'cloud_adoption',@cloud_adoption WHERE @cloud_adoption IS NOT NULL
   UNION ALL SELECT 'stores_cardholder_data',@stores_cardholder_data WHERE @stores_cardholder_data IN ('true','1','yes');

   INSERT @values(attribute_key,attribute_value)
   SELECT 'geographic_presence',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.geographic_presence')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;
   INSERT @values(attribute_key,attribute_value)
   SELECT 'business_operations',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.business_functions')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;
   INSERT @values(attribute_key,attribute_value)
   SELECT 'technology_landscape',TRY_CONVERT(NVARCHAR(200),[value]) FROM OPENJSON(@p_payload,'$.attributes.technology_landscape')
   WHERE NULLIF(TRY_CONVERT(NVARCHAR(200),[value]),'') IS NOT NULL;

   ;WITH candidates AS (
     SELECT au.authority_id,au.authority_code,au.authority_name,a.artifact_id,a.artifact_code,a.artifact_name,r.release_id,r.version_no,
       CAST(0 AS INT) BaseScore,CAST(N'' AS NVARCHAR(MAX)) BaseReason
     FROM grac_new.authority au
     JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
     JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
     WHERE au.status='Active'
   ),
   metadata_score AS (
     SELECT c.release_id,
       SUM(score) Score,
       STRING_AGG(reason,'; ') Reason
     FROM candidates c
     CROSS APPLY (
       SELECT 35 score,CONCAT(N'Industry match: ',@industry) reason
       WHERE @industry IS NOT NULL AND EXISTS(
         SELECT 1 FROM grac_new.artifact_industry_map m JOIN grac_new.reference_option o ON o.reference_option_id=m.reference_option_id
         WHERE m.artifact_id=c.artifact_id AND m.status='Active' AND o.option_group='industries' AND o.status='Active'
           AND (o.option_value=@industry OR o.option_value IN ('All Industries','Banking and Financial Services'))
       )
       UNION ALL
       SELECT 35,CONCAT(N'Jurisdiction match: ',COALESCE(@country,(SELECT TOP 1 attribute_value FROM @values WHERE attribute_key='geographic_presence')))
       WHERE EXISTS(
         SELECT 1 FROM grac_new.artifact_jurisdiction_map m JOIN grac_new.reference_option o ON o.reference_option_id=m.reference_option_id
         WHERE m.artifact_id=c.artifact_id AND m.status='Active' AND o.option_group='jurisdictions' AND o.status='Active'
           AND (o.option_value=@country OR o.option_value IN (SELECT attribute_value FROM @values WHERE attribute_key='geographic_presence') OR o.option_value IN ('Global','International'))
       )
       UNION ALL
       SELECT 20,CONCAT(N'Applicability rule matched: ',ar.rule_name)
       FROM grac_new.applicability_rule ar
       WHERE ar.status='Active' AND ar.outcome='Applicable' AND (ar.release_id=c.release_id OR ar.artifact_id=c.artifact_id)
         AND EXISTS(
           SELECT 1 FROM @values v
           WHERE ar.rule_expression_json LIKE '%'+v.attribute_key+'%' AND ar.rule_expression_json LIKE '%'+v.attribute_value+'%'
         )
       UNION ALL
       SELECT 20,N'Payment/card data driver matched'
       WHERE @stores_cardholder_data IN ('true','1','yes') AND (c.artifact_code LIKE '%PCI%' OR c.artifact_name LIKE '%PCI%' OR c.artifact_name LIKE '%Card%')
       UNION ALL
       SELECT 15,N'Cloud adoption driver matched'
       WHERE @cloud_adoption IS NOT NULL AND (c.artifact_name LIKE '%Cloud%' OR c.artifact_name LIKE '%Cyber%' OR c.artifact_name LIKE '%IT%')
     ) s
     GROUP BY c.release_id
   )
   SELECT c.authority_id AuthorityId,c.authority_code AuthorityCode,c.authority_name AuthorityName,
     c.artifact_id ArtifactId,c.artifact_code ArtifactCode,c.artifact_name ArtifactName,
     c.release_id ReleaseId,c.version_no ReleaseVersion,
     COALESCE(ms.Reason,N'Review recommended based on organization profile and repository metadata.') RecommendationReason,
     CASE WHEN COALESCE(ms.Score,0)>=70 THEN N'High' WHEN COALESCE(ms.Score,0)>=35 THEN N'Medium' ELSE N'Low' END ConfidenceLevel,
     CAST(CASE WHEN COALESCE(ms.Score,0)>=35 THEN 1 ELSE 0 END AS BIT) IsRecommended
   FROM candidates c
   JOIN metadata_score ms ON ms.release_id=c.release_id
   WHERE COALESCE(ms.Score,0)>=35
   ORDER BY ms.Score DESC,c.authority_code,c.artifact_code,c.version_no;
 END
 ELSE IF @p_entity_type='organizations'
   SELECT organization_id Id,organization_code Code,organization_name Name,industry Industry,entity_type EntityType,country Country,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization o
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=o.record_status_id
   WHERE (@p_id=0 OR o.organization_id=@p_id) AND (@p_status='' OR o.record_status_id=@filter_record_status_id)
     AND (@date_from IS NULL OR o.entered_dt>=@date_from) AND (@date_to IS NULL OR o.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR organization_code LIKE '%'+@p_search+'%' OR organization_name LIKE '%'+@p_search+'%')
   ORDER BY organization_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='divisions'
   SELECT d.division_id Id,d.organization_id OrganizationId,d.division_code Code,d.division_name Name,
     d.head_employee_id HeadUserId,COALESCE(e.employee_name,'') HeadUser,d.description Description,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_division d
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=d.head_employee_id
   WHERE (@p_id=0 OR d.division_id=@p_id) AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR d.division_code LIKE '%'+@p_search+'%' OR d.division_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY d.division_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='locations'
   SELECT l.location_id Id,l.organization_id OrganizationId,l.location_name Name,
     l.location_type_id LocationTypeId,lt.location_type_name LocationType,
     l.location_head_id LocationHeadId,COALESCE(e.employee_name,'') LocationHead,
     l.region Region,l.remarks Remarks,l.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_location l
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=l.record_status_id
   JOIN grac_practice.location_type_master lt ON lt.location_type_id=l.location_type_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=l.location_head_id
   WHERE (@p_id=0 OR l.location_id=@p_id) AND (@organization_id IS NULL OR l.organization_id=@organization_id)
     AND (@p_status='' OR l.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR l.location_name LIKE '%'+@p_search+'%' OR lt.location_type_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(l.region,'') LIKE '%'+@p_search+'%')
   ORDER BY l.location_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='departments'
   SELECT d.department_id Id,d.organization_id OrganizationId,d.department_code Code,d.department_name Name,
     d.head_employee_id HeadUserId,COALESCE(e.employee_name,'') HeadUser,d.description Description,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_department d
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   LEFT JOIN grac_practice.organization_employee e ON e.employee_id=d.head_employee_id
   WHERE (@p_id=0 OR d.department_id=@p_id) AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR d.department_code LIKE '%'+@p_search+'%' OR d.department_name LIKE '%'+@p_search+'%' OR ISNULL(e.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY d.department_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='teams'
   SELECT t.team_id Id,t.organization_id OrganizationId,t.team_name Name,
     t.team_manager_id TeamManagerId,COALESCE(m.employee_name,'') TeamManager,
     t.parent_department_id ParentDepartmentId,COALESCE(d.department_name,'') ParentDepartment,
     t.remarks Remarks,t.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_team t
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=t.record_status_id
   LEFT JOIN grac_practice.organization_employee m ON m.employee_id=t.team_manager_id
   LEFT JOIN grac_practice.organization_department d ON d.department_id=t.parent_department_id
   WHERE (@p_id=0 OR t.team_id=@p_id) AND (@organization_id IS NULL OR t.organization_id=@organization_id)
     AND (@p_status='' OR t.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR t.team_name LIKE '%'+@p_search+'%' OR ISNULL(m.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(d.department_name,'') LIKE '%'+@p_search+'%')
   ORDER BY t.team_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='committees'
   SELECT c.committee_id Id,c.organization_id OrganizationId,c.committee_name Name,
     c.chairperson_id ChairpersonId,COALESCE(ch.employee_name,'') Chairperson,
     c.secretary_id SecretaryId,COALESCE(sec.employee_name,'') Secretary,
     c.review_frequency_id ReviewFrequencyId,COALESCE(f.frequency_name,'') ReviewFrequency,
     c.remarks Remarks,c.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_committee c
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=c.record_status_id
   LEFT JOIN grac_practice.organization_employee ch ON ch.employee_id=c.chairperson_id
   LEFT JOIN grac_practice.organization_employee sec ON sec.employee_id=c.secretary_id
   LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=c.review_frequency_id
   WHERE (@p_id=0 OR c.committee_id=@p_id) AND (@organization_id IS NULL OR c.organization_id=@organization_id)
     AND (@p_status='' OR c.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR c.committee_name LIKE '%'+@p_search+'%' OR ISNULL(ch.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(sec.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(f.frequency_name,'') LIKE '%'+@p_search+'%')
   ORDER BY c.committee_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='business-functions'
   SELECT business_function_id Id,organization_id OrganizationId,function_code Code,function_name Name,owner_name OwnerName,criticality Criticality,status Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_business_function
   WHERE (@p_id=0 OR business_function_id=@p_id) AND (@organization_id IS NULL OR organization_id=@organization_id)
     AND (@p_status='' OR status=@p_status)
     AND (@p_search='' OR function_code LIKE '%'+@p_search+'%' OR function_name LIKE '%'+@p_search+'%' OR ISNULL(owner_name,'') LIKE '%'+@p_search+'%')
   ORDER BY function_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='users'
   SELECT e.employee_id Id,e.organization_id OrganizationId,e.employee_code EmployeeCode,e.employee_name EmployeeName,
     e.email Email,e.designation Designation,e.location_id LocationId,loc.location_name Location,
     e.department Department,e.department_id DepartmentId,d.department_name DepartmentName,
     e.business_function_id BusinessFunctionId,bf.function_name BusinessFunction,
     e.reporting_officer_id ReportingOfficerId,COALESCE(ro.employee_name,'') ReportingOfficer,
     e.role_id RoleId,COALESCE(role.role_name,'') RoleName,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_employee e
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=e.record_status_id
   LEFT JOIN grac_practice.organization_location loc ON loc.location_id=e.location_id
   LEFT JOIN grac_practice.organization_department d ON d.department_id=e.department_id
   LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=e.business_function_id
   LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id=e.reporting_officer_id
   LEFT JOIN grac_practice.organization_role role ON role.role_id=e.role_id
   WHERE (@p_id=0 OR e.employee_id=@p_id) AND (@organization_id IS NULL OR e.organization_id=@organization_id)
     AND (@p_status='' OR e.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR e.employee_code LIKE '%'+@p_search+'%' OR e.employee_name LIKE '%'+@p_search+'%' OR ISNULL(e.email,'') LIKE '%'+@p_search+'%')
   ORDER BY e.employee_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='roles'
   SELECT r.role_id Id,r.organization_id OrganizationId,o.organization_name Organization,
     r.role_name RoleName,r.description Description,r.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_role r
   JOIN grac_practice.organization o ON o.organization_id=r.organization_id
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=r.record_status_id
   WHERE (@p_id=0 OR r.role_id=@p_id) AND (@organization_id IS NULL OR r.organization_id=@organization_id)
     AND (@p_status='' OR r.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR r.role_name LIKE '%'+@p_search+'%' OR ISNULL(r.description,'') LIKE '%'+@p_search+'%')
   ORDER BY r.role_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='role-menu-permissions'
   SELECT p.role_menu_permission_id Id,r.organization_id OrganizationId,o.organization_name Organization,
     p.role_id RoleId,r.role_name RoleName,p.menu_id MenuId,m.menu_name MenuName,m.menu_key MenuKey,
     p.can_view CanView,p.can_add CanAdd,p.can_edit CanEdit,p.can_delete CanDelete,p.can_approve CanApprove,
     p.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_role_menu_permission p
   JOIN grac_practice.organization_role r ON r.role_id=p.role_id
   JOIN grac_practice.organization o ON o.organization_id=r.organization_id
   JOIN grac_practice.menu_master m ON m.menu_id=p.menu_id
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   WHERE (@p_id=0 OR p.role_menu_permission_id=@p_id) AND (@organization_id IS NULL OR r.organization_id=@organization_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR r.role_name LIKE '%'+@p_search+'%' OR m.menu_name LIKE '%'+@p_search+'%')
   ORDER BY r.role_name,m.display_order,m.menu_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-vendors'
   SELECT v.vendor_id Id,v.organization_id OrganizationId,v.vendor_name Name,
     v.service_category_id ServiceCategoryId,sc.service_category_name ServiceCategory,
     v.relationship_owner_id RelationshipOwnerId,COALESCE(ro.employee_name,'') RelationshipOwner,
     v.contract_start_dt ContractStartDate,v.contract_end_dt ContractEndDate,v.renewal_dt RenewalDate,
     v.sla_applicable SlaApplicable,v.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     v.remarks Remarks,v.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_dependency_vendor v
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=v.record_status_id
   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id=v.service_category_id
   LEFT JOIN grac_practice.organization_employee ro ON ro.employee_id=v.relationship_owner_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=v.criticality_id
   WHERE (@p_id=0 OR v.vendor_id=@p_id) AND (@organization_id IS NULL OR v.organization_id=@organization_id)
     AND (@p_status='' OR v.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR v.vendor_name LIKE '%'+@p_search+'%' OR sc.service_category_name LIKE '%'+@p_search+'%' OR ISNULL(ro.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY v.vendor_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-applications'
   SELECT a.application_id Id,a.organization_id OrganizationId,a.application_name Name,a.description Description,
     a.business_owner_id BusinessOwnerId,COALESCE(bo.employee_name,'') BusinessOwner,
     a.technical_owner_id TechnicalOwnerId,COALESCE(te.employee_name,'') TechnicalOwner,
     a.vendor_id VendorId,COALESCE(v.vendor_name,'') Vendor,a.version_no Version,
     a.hosting_type_id HostingTypeId,COALESCE(ht.hosting_type_name,'') HostingType,
     a.support_expiry_dt SupportExpiryDate,a.end_of_life_dt EndOfLifeDate,
     a.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     a.remarks Remarks,a.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_dependency_application a
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=a.record_status_id
   LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id=a.business_owner_id
   LEFT JOIN grac_practice.organization_employee te ON te.employee_id=a.technical_owner_id
   LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=a.vendor_id
   LEFT JOIN grac_practice.dependency_hosting_type_master ht ON ht.hosting_type_id=a.hosting_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=a.criticality_id
   WHERE (@p_id=0 OR a.application_id=@p_id) AND (@organization_id IS NULL OR a.organization_id=@organization_id)
     AND (@p_status='' OR a.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR a.application_name LIKE '%'+@p_search+'%' OR ISNULL(v.vendor_name,'') LIKE '%'+@p_search+'%' OR ISNULL(bo.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(te.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY a.application_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-tools'
   SELECT t.tool_id Id,t.organization_id OrganizationId,t.tool_name Name,t.description Description,
     t.business_owner_id BusinessOwnerId,COALESCE(bo.employee_name,'') BusinessOwner,
     t.vendor_id VendorId,COALESCE(v.vendor_name,'') Vendor,
     t.license_type_id LicenseTypeId,COALESCE(lt.license_type_name,'') LicenseType,
     t.license_expiry_dt LicenseExpiryDate,t.support_expiry_dt SupportExpiryDate,
     t.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     t.remarks Remarks,t.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_dependency_tool t
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=t.record_status_id
   LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id=t.business_owner_id
   LEFT JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id=t.vendor_id
   LEFT JOIN grac_practice.dependency_license_type_master lt ON lt.license_type_id=t.license_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=t.criticality_id
   WHERE (@p_id=0 OR t.tool_id=@p_id) AND (@organization_id IS NULL OR t.organization_id=@organization_id)
     AND (@p_status='' OR t.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR t.tool_name LIKE '%'+@p_search+'%' OR ISNULL(v.vendor_name,'') LIKE '%'+@p_search+'%' OR ISNULL(bo.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY t.tool_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-assets'
   SELECT a.asset_id Id,a.organization_id OrganizationId,a.asset_name Name,
     a.asset_category_id AssetCategoryId,ac.asset_category_name AssetCategory,
     a.owner_id OwnerId,COALESCE(o.employee_name,'') Owner,
     a.location_id LocationId,COALESCE(l.location_name,'') Location,
     a.purchase_dt PurchaseDate,a.warranty_expiry_dt WarrantyExpiryDate,a.amc_expiry_dt AmcExpiryDate,
     a.criticality_id CriticalityId,COALESCE(cm.criticality_name,'') Criticality,
     a.remarks Remarks,a.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_dependency_asset a
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=a.record_status_id
   JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id=a.asset_category_id
   LEFT JOIN grac_practice.organization_employee o ON o.employee_id=a.owner_id
   LEFT JOIN grac_practice.organization_location l ON l.location_id=a.location_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=a.criticality_id
   WHERE (@p_id=0 OR a.asset_id=@p_id) AND (@organization_id IS NULL OR a.organization_id=@organization_id)
     AND (@p_status='' OR a.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR a.asset_name LIKE '%'+@p_search+'%' OR ac.asset_category_name LIKE '%'+@p_search+'%' OR ISNULL(o.employee_name,'') LIKE '%'+@p_search+'%' OR ISNULL(l.location_name,'') LIKE '%'+@p_search+'%')
   ORDER BY a.asset_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-processes'
   SELECT p.process_id Id,p.organization_id OrganizationId,p.process_name Name,
     p.process_owner_id ProcessOwnerId,COALESCE(o.employee_name,'') ProcessOwner,
     p.version_no Version,p.effective_dt EffectiveDate,p.last_review_dt LastReviewDate,p.next_review_dt NextReviewDate,
     p.remarks Remarks,p.record_status_id StatusId,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_dependency_process p
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   LEFT JOIN grac_practice.organization_employee o ON o.employee_id=p.process_owner_id
   WHERE (@p_id=0 OR p.process_id=@p_id) AND (@organization_id IS NULL OR p.organization_id=@organization_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id)
     AND (@p_search='' OR p.process_name LIKE '%'+@p_search+'%' OR ISNULL(o.employee_name,'') LIKE '%'+@p_search+'%')
   ORDER BY p.process_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-metadata'
   SELECT v.metadata_value_id Id,v.organization_id OrganizationId,d.metadata_key MetadataKey,d.metadata_name MetadataName,d.data_type DataType,
     v.value_text ValueText,v.value_number ValueNumber,v.value_date ValueDate,v.value_bool ValueBool,v.value_json ValueJson,v.status Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_metadata_value v
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_definition_id=v.metadata_definition_id
   WHERE (@p_id=0 OR v.metadata_value_id=@p_id) AND (@organization_id IS NULL OR v.organization_id=@organization_id)
     AND (@p_status='' OR v.status=@p_status)
     AND (@date_from IS NULL OR v.entered_dt>=@date_from) AND (@date_to IS NULL OR v.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY d.metadata_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='repository-subscriptions'
   SELECT subscription_id Id,organization_id OrganizationId,authority_id AuthorityId,artifact_id ArtifactId,release_id ReleaseId,
     subscription_type SubscriptionType,ss.status_name SubscriptionStatus,effective_dt EffectiveDate,end_dt EndDate,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.repository_subscription s
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=s.record_status_id
   JOIN grac_practice.subscription_status_master ss ON ss.subscription_status_id=s.subscription_status_id
   WHERE (@p_id=0 OR s.subscription_id=@p_id) AND (@organization_id IS NULL OR s.organization_id=@organization_id)
     AND (@p_status='' OR s.record_status_id=@filter_record_status_id OR s.subscription_status_id=@filter_subscription_status_id)
     AND (@date_from IS NULL OR s.entered_dt>=@date_from) AND (@date_to IS NULL OR s.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY s.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-controls'
 BEGIN
   ;WITH practice_counts AS (
     SELECT req.organization_id OrganizationId,req.organization_control_id OrganizationControlId,COUNT_BIG(1) ApplicablePracticeCount
     FROM grac_practice.organization_requirement req
     LEFT JOIN grac_practice.applicability_status_master req_aps ON req_aps.applicability_status_id=req.applicability_status_id
     WHERE ISNULL(req.status,'Active')='Active'
       AND (req_aps.status_code='Applicable' OR req_aps.status_name='Applicable' OR req.applicability_status='Applicable')
     GROUP BY req.organization_id,req.organization_control_id
   ),
   base AS (
     SELECT oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
       oc.control_code Code,oc.control_name Name,oc.description Description,oc.business_justification BusinessJustification,
       oc.objective Objective,oc.control_domain_id DomainId,oc.control_sub_domain_id SubDomainId,oc.is_manually_added IsManuallyAdded,
        oc.subscription_id SubscriptionId,oc.release_id ReleaseId,oc.artifact_id ArtifactId,
        COALESCE(a.artifact_code + N' / ' + r.version_no, CASE WHEN oc.origin_type='Organization' THEN N'Organization Defined' END) SourceFrameworkRelease,
        aps.status_name ApplicabilityStatus,oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.backup_owner BackupOwner,
        oc.business_function_id BusinessFunctionId,oc.criticality Criticality,rs.status_name Status,oc.entered_dt EnteredDate,
        COALESCE(pc.ApplicablePracticeCount,0) ApplicablePracticeCount,
        CASE WHEN oc.repository_control_id IS NOT NULL THEN N'R:' + CONVERT(NVARCHAR(40),oc.repository_control_id) ELSE N'M:' + CONVERT(NVARCHAR(40),oc.organization_control_id) END ControlGroupKey
     FROM grac_practice.organization_control oc
     JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
     JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
     LEFT JOIN practice_counts pc ON pc.OrganizationId=oc.organization_id AND pc.OrganizationControlId=oc.organization_control_id
     LEFT JOIN grac_new.release r ON r.release_id=oc.release_id
     LEFT JOIN grac_new.artifact a ON a.artifact_id=COALESCE(oc.artifact_id,r.artifact_id)
     WHERE (@organization_id IS NULL OR oc.organization_id=@organization_id)
       AND (@p_status='' OR oc.record_status_id=@filter_record_status_id OR oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
       AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
       AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
       AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
       AND (@date_from IS NULL OR oc.entered_dt>=@date_from) AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
   ),
   source_values AS (
     SELECT DISTINCT OrganizationId,ControlGroupKey,SourceFrameworkRelease
     FROM base
     WHERE SourceFrameworkRelease IS NOT NULL AND SourceFrameworkRelease<>N''
   ),
   source_agg AS (
     SELECT OrganizationId,ControlGroupKey,STRING_AGG(SourceFrameworkRelease,N', ') WITHIN GROUP (ORDER BY SourceFrameworkRelease) SourceFrameworkRelease
     FROM source_values
     GROUP BY OrganizationId,ControlGroupKey
   ),
   group_flags AS (
     SELECT OrganizationId,ControlGroupKey,MAX(CASE WHEN Id=@p_id THEN 1 ELSE 0 END) HasRequestedId
     FROM base
     GROUP BY OrganizationId,ControlGroupKey
   ),
   ranked AS (
     SELECT base.*,ROW_NUMBER() OVER(PARTITION BY base.OrganizationId,base.ControlGroupKey ORDER BY CASE WHEN base.Id=@p_id THEN 0 ELSE 1 END,base.Id) RowNumber
     FROM base
   )
   SELECT ranked.Id,ranked.OrganizationId,ranked.OriginType,ranked.RepositoryControlId,
      ranked.Code,ranked.Name,ranked.Description,ranked.BusinessJustification,ranked.Objective,
      ranked.DomainId,ranked.SubDomainId,ranked.IsManuallyAdded,ranked.SubscriptionId,ranked.ReleaseId,ranked.ArtifactId,
      COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease) SourceFrameworkRelease,
      ranked.ApplicabilityStatus,ranked.PrimaryOwner,ranked.SecondaryOwner,ranked.BackupOwner,
      ranked.ApplicablePracticeCount,ranked.BusinessFunctionId,ranked.Criticality,ranked.Status,COUNT(*) OVER () AS TotalRows
   FROM ranked
   JOIN group_flags ON group_flags.OrganizationId=ranked.OrganizationId AND group_flags.ControlGroupKey=ranked.ControlGroupKey
   LEFT JOIN source_agg ON source_agg.OrganizationId=ranked.OrganizationId AND source_agg.ControlGroupKey=ranked.ControlGroupKey
   WHERE ranked.RowNumber=1
     AND (@p_id=0 OR group_flags.HasRequestedId=1)
     AND (@p_search='' OR ranked.Code LIKE '%'+@p_search+'%' OR ranked.Name LIKE '%'+@p_search+'%' OR ranked.OriginType LIKE '%'+@p_search+'%' OR COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease,N'') LIKE '%'+@p_search+'%')
   ORDER BY ranked.Code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='control-applicability'
   SELECT oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
     oc.control_code Code,oc.control_name Name,oc.description Description,oc.objective Objective,
     oc.is_manually_added IsManuallyAdded,aps.status_name ApplicabilityStatus,oc.exclusion_justification ExclusionJustification,
     oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.business_function_id BusinessFunctionId,bf.function_name BusinessFunction,
     oc.criticality Criticality,rs.status_name Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_control oc
   JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
   JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
   LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=oc.business_function_id
   WHERE (@p_id=0 OR oc.organization_control_id=@p_id) AND (@organization_id IS NULL OR oc.organization_id=@organization_id)
     AND (@p_status='' OR oc.record_status_id=@filter_record_status_id OR oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
     AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
     AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
     AND (@date_from IS NULL OR oc.entered_dt>=@date_from) AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR ISNULL(oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.origin_type,'') LIKE '%'+@p_search+'%' OR ISNULL(bf.function_name,'') LIKE '%'+@p_search+'%')
   ORDER BY oc.control_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='organization-requirements'
 BEGIN
   IF @organization_control_id IS NULL
      THROW 51024,'Control context is required to load requirements.',1;

   ;WITH requirement_candidates AS (
     SELECT
       oc.organization_id,
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
     JOIN grac_new.control repo_control ON (repo_control.control_id=oc.repository_control_id OR repo_control.control_code=oc.control_code) AND repo_control.status='Active'
     JOIN grac_new.control_requirement_map crm ON crm.control_id=repo_control.control_id AND crm.status='Active'
     JOIN grac_new.requirement q ON q.requirement_id=crm.requirement_id AND q.status='Active'
     WHERE ISNULL(oc.origin_type,'Repository') IN ('Repository','Hybrid')
       AND oc.record_status_id=@active_record_status_id
       AND (
         oc.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable')
       OR oc.applicability_status='Applicable'
       )
       AND (@organization_id IS NULL OR oc.organization_id=@organization_id)
       AND oc.organization_control_id=@organization_control_id
   )
   INSERT grac_practice.organization_requirement(
     organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
     requirement_statement,objective,applicability_status,applicability_status_id,implementation_status,implementation_status_id,status,record_status_id,entered_by)
   SELECT c.organization_id,'Repository',c.repository_requirement_id,c.organization_control_id,c.requirement_code,c.requirement_name,
     c.requirement_statement,c.objective,'Not Updated',@not_updated_applicability_status_id,'Not Started',@not_started_implementation_status_id,'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
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

   SELECT q.organization_requirement_id Id,q.organization_id OrganizationId,q.origin_type OriginType,q.repository_requirement_id RepositoryRequirementId,
     q.organization_control_id OrganizationControlId,q.requirement_code Code,q.requirement_name Name,q.requirement_statement Statement,
     q.objective Objective,practice.practice_id PracticeId,practice.practice_owner_id PracticeOwnerId,COALESCE(emp.employee_name,practice.practice_owner) PracticeOwner,
     COALESCE(aps.status_name,q.applicability_status) ApplicabilityStatus,COALESCE(ims.status_name,q.implementation_status) ImplementationStatus,COALESCE(rs.status_name,q.status) Status,
     (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi_count JOIN grac_practice.practice p_count ON p_count.practice_id=pi_count.practice_id WHERE p_count.organization_requirement_id=q.organization_requirement_id AND pi_count.status='Active') PracticeInstanceCount,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.organization_requirement q
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=q.record_status_id
   LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
   LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id=q.implementation_status_id
   OUTER APPLY (
     SELECT TOP (1) p.practice_id,p.practice_owner_id,p.practice_owner
     FROM grac_practice.practice p
     WHERE p.organization_id=q.organization_id
       AND p.organization_requirement_id=q.organization_requirement_id
       AND p.status='Active'
     ORDER BY p.practice_id
   ) practice
   LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=practice.practice_owner_id
   WHERE (@p_id=0 OR q.organization_requirement_id=@p_id) AND (@organization_id IS NULL OR q.organization_id=@organization_id)
     -- Accept the Practice if it is linked to @organization_control_id either
     -- through the legacy "primary" column on organization_requirement OR
     -- through the many-to-many organization_control_requirement mapping added
     -- by migration 057 (dedup of shared repository requirements).
     AND (q.organization_control_id=@organization_control_id
          OR EXISTS(
              SELECT 1
              FROM grac_practice.organization_control_requirement m
              WHERE m.organization_requirement_id=q.organization_requirement_id
                AND m.organization_control_id=@organization_control_id
                AND m.status='Active'))
     AND (@p_status='' OR q.record_status_id=@filter_record_status_id OR q.status=@p_status OR q.applicability_status=@p_status OR q.implementation_status=@p_status OR q.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status)) AND (@origin_type IS NULL OR q.origin_type=@origin_type)
     AND (@date_from IS NULL OR q.entered_dt>=@date_from) AND (@date_to IS NULL OR q.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR requirement_code LIKE '%'+@p_search+'%' OR requirement_name LIKE '%'+@p_search+'%')
   ORDER BY requirement_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='practices'
 BEGIN
   IF @organization_requirement_id IS NOT NULL
   BEGIN
     UPDATE p
       SET organization_requirement_id=q.organization_requirement_id,
           updated_by=COALESCE(NULLIF(@p_usr_id,''),'system'),
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     JOIN grac_practice.organization_requirement q
       ON q.organization_requirement_id=@organization_requirement_id
      AND q.organization_id=p.organization_id
      AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
     WHERE p.organization_requirement_id IS NULL;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Not Updated',@not_updated_applicability_status_id,'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@organization_requirement_id
       AND (@organization_id IS NULL OR q.organization_id=@organization_id)
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );
   END;

   SELECT p.practice_id Id,p.organization_id OrganizationId,p.organization_requirement_id OrganizationRequirementId,p.origin_type OriginType,
     p.practice_code Code,p.practice_name Name,p.description Description,p.practice_owner_id PracticeOwnerId,COALESCE(emp.employee_name,p.practice_owner) PracticeOwner,
     p.applicability_status_id ApplicabilityStatusId,COALESCE(aps.status_code,p.applicability_status) ApplicabilityStatusCode,
     COALESCE(aps.status_name,p.applicability_status) ApplicabilityStatus,p.exclusion_justification ExclusionJustification,COALESCE(rs.status_name,p.status) Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice p
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=p.record_status_id
   LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=p.applicability_status_id
   LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=p.practice_owner_id
   WHERE (@p_id=0 OR p.practice_id=@p_id) AND (@organization_id IS NULL OR p.organization_id=@organization_id)
     AND (@organization_requirement_id IS NULL OR p.organization_requirement_id=@organization_requirement_id)
     AND (@p_status='' OR p.record_status_id=@filter_record_status_id OR p.status=@p_status OR p.applicability_status=@p_status OR p.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@p_status OR status_name=@p_status))
     AND (@origin_type IS NULL OR p.origin_type=@origin_type)
     AND (@owner IS NULL OR COALESCE(emp.employee_name,p.practice_owner) LIKE '%'+@owner+'%')
     AND (@date_from IS NULL OR p.entered_dt>=@date_from) AND (@date_to IS NULL OR p.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR p.practice_code LIKE '%'+@p_search+'%' OR p.practice_name LIKE '%'+@p_search+'%')
   ORDER BY p.practice_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='practice-instances'
 BEGIN
   IF @organization_requirement_id IS NOT NULL
   BEGIN
     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Applicable',(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),'Active',@active_record_status_id,COALESCE(NULLIF(@p_usr_id,''),'system')
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@organization_requirement_id
       AND (@organization_id IS NULL OR q.organization_id=@organization_id)
       AND (
         q.applicability_status_id=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable')
         OR q.applicability_status='Applicable'
       )
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );
   END;

    SELECT pi.practice_instance_id Id,pi.practice_id PracticeId,COALESCE(p.organization_requirement_id,@organization_requirement_id) OrganizationRequirementId,
      pi.organization_id OrganizationId,pi.instance_code Code,pi.instance_name Name,
      pi.primary_owner_id PrimaryOwnerId,COALESCE(emp.employee_name,pi.primary_owner) PrimaryOwner,pi.secondary_owner SecondaryOwner,
      pi.business_function_id BusinessFunctionId,pi.department_id DepartmentId,COALESCE(dept.department_name,pi.department) Department,
      pi.execution_frequency_id ExecutionFrequencyId,execf.frequency_name ExecutionFrequency,
      pi.assurance_frequency_id AssuranceFrequencyId,assurf.frequency_name AssuranceFrequency,
      COALESCE(pi.execution_frequency_id,pi.frequency_id) FrequencyId,COALESCE(execf.frequency_code,f.frequency_code,pi.frequency_type) FrequencyType,
      COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_value END,pi.frequency_value) FrequencyValue,
      COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_unit END,pi.frequency_unit) FrequencyUnit,pi.assurance_mode AssuranceMode,
      pi.criticality Criticality,pi.implementation_status ImplementationStatus,pi.status Status,
      COALESCE(po.status,N'Pending') ResolveStatus,COALESCE(last_result.result_status,N'Not Assured') AssuranceStatus,COUNT(*) OVER () AS TotalRows
    FROM grac_practice.practice_instance pi
    JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
    LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
    LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
    LEFT JOIN grac_practice.frequency_master assurf ON assurf.frequency_id=pi.assurance_frequency_id
    LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=pi.primary_owner_id
    LEFT JOIN grac_practice.organization_department dept ON dept.department_id=pi.department_id
    LEFT JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id
    OUTER APPLY (SELECT TOP (1) ar.result_status FROM grac_practice.assurance_activity aa LEFT JOIN grac_practice.assurance_result ar ON ar.assurance_activity_id=aa.assurance_activity_id WHERE aa.practice_instance_id=pi.practice_instance_id ORDER BY COALESCE(ar.updated_dt,ar.entered_dt,aa.updated_dt,aa.entered_dt) DESC) last_result
   WHERE (@p_id=0 OR pi.practice_instance_id=@p_id) AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
     AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
     AND (
       @organization_requirement_id IS NULL
       OR p.organization_requirement_id=@organization_requirement_id
       OR EXISTS (
         SELECT 1
         FROM grac_practice.organization_requirement q
         WHERE q.organization_requirement_id=@organization_requirement_id
           AND q.organization_id=pi.organization_id
           AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
       )
     )
     AND (@p_status='' OR pi.status=@p_status)
     AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR pi.criticality=@criticality)
     AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
     AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
   ORDER BY pi.instance_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='dependency-options'
 BEGIN
   DECLARE @dep_opt_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dep_opt_source_type NVARCHAR(80);
   DECLARE @dep_opt_source_table NVARCHAR(256);
   DECLARE @dep_opt_id_column SYSNAME;
   DECLARE @dep_opt_display_column SYSNAME;
   DECLARE @dep_opt_org_column SYSNAME;
   DECLARE @dep_opt_status_column SYSNAME;
   DECLARE @dep_opt_status_value NVARCHAR(80);
   DECLARE @dep_opt_sort_column SYSNAME;
   DECLARE @dep_opt_multi BIT;
   DECLARE @dep_opt_schema SYSNAME;
   DECLARE @dep_opt_table SYSNAME;
   DECLARE @dep_opt_object_id INT;
   DECLARE @dep_opt_sql NVARCHAR(MAX);

   IF @dep_opt_dependency_type_id IS NULL
     THROW 51062,'Dependency Type is required to load dependency options.',1;
   IF @organization_id IS NULL
     THROW 51063,'Organization context is required to load dependency options.',1;

   SELECT TOP 1
     @dep_opt_source_type=source_type,
     @dep_opt_source_table=source_table_name,
     @dep_opt_id_column=id_column_name,
     @dep_opt_display_column=display_column_name,
     @dep_opt_org_column=organization_filter_column,
     @dep_opt_status_column=status_filter_column,
     @dep_opt_status_value=status_active_value,
     @dep_opt_sort_column=COALESCE(NULLIF(sort_column,''),display_column_name),
     @dep_opt_multi=is_multi_select_allowed
   FROM grac_practice.dependency_type_source_config
   WHERE dependency_type_id=@dep_opt_dependency_type_id
     AND status='Active'
     AND source_table_name IN (
       N'grac_practice.organization_dependency_tool',
       N'grac_practice.organization_dependency_vendor',
       N'grac_practice.organization_dependency_application',
       N'grac_practice.organization_dependency_asset',
       N'grac_practice.organization_dependency_process',
       N'grac_practice.organization_location',
       N'grac_practice.organization_employee',
       N'grac_practice.organization_team',
       N'grac_practice.organization_committee'
     );

   IF @dep_opt_source_table IS NULL
     THROW 51064,'Dependency Type source configuration is missing or inactive.',1;

   SET @dep_opt_schema=PARSENAME(@dep_opt_source_table,2);
   SET @dep_opt_table=PARSENAME(@dep_opt_source_table,1);
   SET @dep_opt_object_id=OBJECT_ID(@dep_opt_source_table);
   IF @dep_opt_schema<>N'grac_practice' OR @dep_opt_object_id IS NULL
     THROW 51065,'Dependency Type source configuration is invalid.',1;
   IF COL_LENGTH(@dep_opt_source_table,@dep_opt_id_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_display_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_org_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_status_column) IS NULL
      OR COL_LENGTH(@dep_opt_source_table,@dep_opt_sort_column) IS NULL
     THROW 51066,'Dependency Type source columns are invalid.',1;

   SET @dep_opt_sql=N'
SELECT
 CAST(' + QUOTENAME(@dep_opt_id_column) + N' AS NVARCHAR(40)) [Value],
 CAST(' + QUOTENAME(@dep_opt_display_column) + N' AS NVARCHAR(300)) [Label],
 @dependencyTypeId DependencyTypeId,
 @sourceType SourceType,
 @isMultiSelectAllowed IsMultiSelectAllowed
FROM ' + QUOTENAME(@dep_opt_schema) + N'.' + QUOTENAME(@dep_opt_table) + N'
WHERE ' + QUOTENAME(@dep_opt_org_column) + N'=@organizationId
  AND ' + QUOTENAME(@dep_opt_status_column) + N'=@activeStatus
  AND (@searchText=N'''' OR CAST(' + QUOTENAME(@dep_opt_display_column) + N' AS NVARCHAR(300)) LIKE N''%''+@searchText+N''%'')
ORDER BY ' + QUOTENAME(@dep_opt_sort_column) + N'
OFFSET 0 ROWS FETCH NEXT @take ROWS ONLY;';

   EXEC sp_executesql @dep_opt_sql,
     N'@organizationId BIGINT,@activeStatus NVARCHAR(80),@searchText NVARCHAR(200),@take INT,@dependencyTypeId INT,@sourceType NVARCHAR(80),@isMultiSelectAllowed BIT',
     @organizationId=@organization_id,
     @activeStatus=@dep_opt_status_value,
     @searchText=@p_search,
     @take=@page_size,
     @dependencyTypeId=@dep_opt_dependency_type_id,
     @sourceType=@dep_opt_source_type,
     @isMultiSelectAllowed=@dep_opt_multi;
 END
 ELSE IF @p_entity_type='practice-operationalization'
 BEGIN
   DECLARE @resolve_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @resolve_register_type NVARCHAR(80)=NULLIF(JSON_VALUE(@p_payload,'$.registerType'),'');
   ;WITH configured_categories AS (
     SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id,
       COALESCE(dt.dependency_type_name,d.dependency_type) DependencyCategory
     FROM grac_practice.practice_instance_dependency d
     LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
     WHERE d.status='Active'
       AND d.dependency_type_id IS NOT NULL
     GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id,COALESCE(dt.dependency_type_name,d.dependency_type)
   ),
    category_agg AS (
      SELECT c.organization_id,c.practice_instance_id,
        COUNT(1) TotalDependencyCategories,
        STUFF((
          SELECT N', ' + c2.DependencyCategory
          FROM configured_categories c2
          WHERE c2.organization_id=c.organization_id
            AND c2.practice_instance_id=c.practice_instance_id
          ORDER BY c2.DependencyCategory
          FOR XML PATH(''),TYPE
        ).value('.','NVARCHAR(MAX)'),1,2,N'') DependencyCategories
      FROM configured_categories c
      GROUP BY c.organization_id,c.practice_instance_id
   ),
    resolved_categories AS (
      SELECT r.organization_id,r.practice_instance_id,r.dependency_type_id
      FROM grac_practice.practice_dependency_resolution r
      WHERE r.is_active=1
        AND r.resolution_status=N'Resolved'
      GROUP BY r.organization_id,r.practice_instance_id,r.dependency_type_id
    ),
    resolution_agg AS (
      SELECT organization_id,practice_instance_id,
        COUNT(1) ResolvedDependenciesCount
      FROM resolved_categories
      GROUP BY organization_id,practice_instance_id
    ),
   evidence_values AS (
     SELECT e.organization_id,e.practice_instance_id,
       COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceTypeName
     FROM grac_practice.practice_instance_evidence e
     LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
     WHERE e.status='Active'
     GROUP BY e.organization_id,e.practice_instance_id,COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id))
   ),
   evidence_agg AS (
     SELECT ev1.organization_id,ev1.practice_instance_id,
       STUFF((
         SELECT N', ' + ev2.EvidenceTypeName
         FROM evidence_values ev2
         WHERE ev2.organization_id=ev1.organization_id
           AND ev2.practice_instance_id=ev1.practice_instance_id
         ORDER BY ev2.EvidenceTypeName
         FOR XML PATH(''),TYPE
       ).value('.','NVARCHAR(MAX)'),1,2,N'') EvidenceTypes
     FROM evidence_values ev1
     GROUP BY ev1.organization_id,ev1.practice_instance_id
   ),
   base AS (
     SELECT pi.practice_instance_id Id,pi.practice_instance_id PracticeInstanceId,pi.organization_id OrganizationId,
       pi.instance_code Code,pi.instance_name Name,
       COALESCE(bf.function_name,pi.department,N'') OwningDepartment,
        pi.primary_owner PrimaryOwner,
        COALESCE(execf.frequency_name,f.frequency_name,pi.frequency_type,N'') Frequency,
       COALESCE(ev.EvidenceTypes,N'') EvidenceTypes,
       COALESCE(cat.DependencyCategories,N'') DependencyCategories,
       CASE WHEN @resolve_register_type='Evidence' THEN N'Evidence Register'
            WHEN @resolve_dependency_type_id IS NOT NULL THEN COALESCE((SELECT TOP 1 dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@resolve_dependency_type_id),N'Dependency Register') + N' Register'
            ELSE COALESCE(cat.DependencyCategories,N'') END Register,
       CASE WHEN @resolve_register_type='Evidence' THEN COALESCE(ev.EvidenceTypes,N'')
            ELSE COALESCE((SELECT STUFF((SELECT N', ' + r2.resolved_dependency_name
              FROM grac_practice.practice_dependency_resolution r2
              WHERE r2.organization_id=pi.organization_id AND r2.practice_instance_id=pi.practice_instance_id
                AND r2.is_active=1 AND (@resolve_dependency_type_id IS NULL OR r2.dependency_type_id=@resolve_dependency_type_id)
              ORDER BY r2.resolved_dependency_name FOR XML PATH(''),TYPE).value('.','NVARCHAR(MAX)'),1,2,N'')),N'') END ResolvedDependencyName,
       CASE WHEN @resolve_register_type='Evidence' THEN CASE WHEN EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e2 WHERE e2.practice_instance_id=pi.practice_instance_id AND e2.status='Active') THEN N'Resolved' ELSE N'Pending' END
            WHEN @resolve_dependency_type_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r3 WHERE r3.organization_id=pi.organization_id AND r3.practice_instance_id=pi.practice_instance_id AND r3.dependency_type_id=@resolve_dependency_type_id AND r3.is_active=1 AND r3.resolution_status='Resolved') THEN N'Resolved'
            WHEN @resolve_dependency_type_id IS NULL AND COALESCE(res.ResolvedDependenciesCount,0)>0 THEN N'Resolved'
            ELSE N'Pending' END ResolutionStatus,
       COALESCE((SELECT TOP 1 e3.employee_name FROM grac_practice.practice_dependency_resolution r4 LEFT JOIN grac_practice.organization_employee e3 ON e3.employee_id=r4.resolution_owner_id WHERE r4.organization_id=pi.organization_id AND r4.practice_instance_id=pi.practice_instance_id AND (@resolve_dependency_type_id IS NULL OR r4.dependency_type_id=@resolve_dependency_type_id) AND r4.is_active=1 ORDER BY r4.updated_dt DESC,r4.entered_dt DESC),N'') ResolutionOwner,
       COALESCE((SELECT MAX(COALESCE(r5.updated_dt,r5.entered_dt)) FROM grac_practice.practice_dependency_resolution r5 WHERE r5.organization_id=pi.organization_id AND r5.practice_instance_id=pi.practice_instance_id AND (@resolve_dependency_type_id IS NULL OR r5.dependency_type_id=@resolve_dependency_type_id) AND r5.is_active=1),pi.updated_dt,pi.entered_dt) LastUpdated,
       (SELECT TOP 1 e6.evidence_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceId,
       (SELECT TOP 1 e6.evidence_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceTypeId,
       (SELECT TOP 1 e6.assurance_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeId,
       (SELECT TOP 1 at6.assurance_type_name FROM grac_practice.practice_instance_evidence e6 LEFT JOIN grac_practice.assurance_type_master at6 ON at6.assurance_type_id=e6.assurance_type_id WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeName,
       (SELECT TOP 1 e6.collection_method_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) CollectionMethodId,
       (SELECT TOP 1 e6.retention_period FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) RetentionPeriod,
       (SELECT TOP 1 e6.evidence_description FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceDescription,
       (SELECT TOP 1 e6.evidence_location FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocation,
       (SELECT TOP 1 e6.evidence_locator FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocator,
       COALESCE(res.ResolvedDependenciesCount,0) ResolvedDependenciesCount,
       CASE
         WHEN COALESCE(cat.TotalDependencyCategories,0)-COALESCE(res.ResolvedDependenciesCount,0) < 0 THEN 0
         ELSE COALESCE(cat.TotalDependencyCategories,0)-COALESCE(res.ResolvedDependenciesCount,0)
       END PendingDependenciesCount,
        CASE
          WHEN pi.status IN ('Inactive','Retired') OR prs.status_code IN ('Inactive','Retired') THEN N'Retired'
          WHEN COALESCE(cat.TotalDependencyCategories,0)=0 THEN N'Dependency Categories Pending'
          WHEN COALESCE(res.ResolvedDependenciesCount,0)>=COALESCE(cat.TotalDependencyCategories,0) THEN N'Operationalized'
          WHEN COALESCE(res.ResolvedDependenciesCount,0)>0 THEN N'Partially Operationalized'
          ELSE N'Configured'
        END OperationalizationStatus,
        COALESCE(prs.status_name,pi.status) Status,
        pi.entered_dt EnteredDate
      FROM grac_practice.practice_instance pi
      LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
      LEFT JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
      LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=req.applicability_status_id
      LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
      LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
      LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
      LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
      LEFT JOIN category_agg cat ON cat.organization_id=pi.organization_id AND cat.practice_instance_id=pi.practice_instance_id
     LEFT JOIN resolution_agg res ON res.organization_id=pi.organization_id AND res.practice_instance_id=pi.practice_instance_id
     LEFT JOIN evidence_agg ev ON ev.organization_id=pi.organization_id AND ev.practice_instance_id=pi.practice_instance_id
      WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
        AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
        AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
        AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
        AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
       AND (@criticality IS NULL OR pi.criticality=@criticality)
       AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
       AND EXISTS(
         SELECT 1
         FROM grac_practice.organization_employee owner_emp
         WHERE owner_emp.status='Active'
           AND owner_emp.organization_id=pi.organization_id
           AND (owner_emp.employee_id=pi.primary_owner_id OR owner_emp.employee_name=pi.primary_owner)
           AND (owner_emp.email=@p_usr_id OR owner_emp.employee_code=@p_usr_id)
       )
       AND (
         (@resolve_register_type='Evidence' AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status='Active'))
         OR
         (COALESCE(@resolve_register_type,N'')<>N'Evidence' AND (@resolve_dependency_type_id IS NULL OR EXISTS(
            SELECT 1 FROM grac_practice.practice_instance_dependency dfilter
            WHERE dfilter.practice_instance_id=pi.practice_instance_id
              AND dfilter.organization_id=pi.organization_id
              AND dfilter.dependency_type_id=@resolve_dependency_type_id
              AND dfilter.status='Active'
         )))
       )
       AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE '%'+@p_search+'%')
   )
    SELECT Id,PracticeInstanceId,OrganizationId,Code,Name,OwningDepartment,PrimaryOwner,Frequency,EvidenceTypes,DependencyCategories,
      Register,ResolvedDependencyName,ResolutionStatus,ResolutionOwner,LastUpdated,EvidenceId,EvidenceTypeId,AssuranceTypeId,AssuranceTypeName,CollectionMethodId,RetentionPeriod,EvidenceDescription,EvidenceLocation,EvidenceLocator,
      ResolvedDependenciesCount,PendingDependenciesCount,OperationalizationStatus,Status,COUNT(*) OVER () AS TotalRows
    FROM base
    ORDER BY Name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

    SELECT
      @organization_id SelectedOrganizationId,
      CONVERT(BIGINT,NULL) LoggedInOrganizationId,
      (SELECT COUNT(1)
       FROM grac_practice.practice_instance pi
       LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=pi.record_status_id
       WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
         AND (pi.status='Active' OR rs.status_code='Active' OR pi.record_status_id IS NULL)) ApplicablePracticeInstanceCount,
      (SELECT COUNT(1)
       FROM (
         SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id
         FROM grac_practice.practice_instance_dependency d
         LEFT JOIN grac_practice.record_status_master drs ON drs.record_status_id=d.record_status_id
         WHERE d.dependency_type_id IS NOT NULL
           AND (d.status='Active' OR drs.status_code='Active' OR d.record_status_id IS NULL)
           AND (@organization_id IS NULL OR d.organization_id=@organization_id)
         GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id
       ) dependency_categories) ConfiguredDependencyCategoryCount,
      (SELECT COUNT(1)
       FROM grac_practice.practice_operationalization po
       WHERE (@organization_id IS NULL OR po.organization_id=@organization_id)) OperationalizationRecordCount,
      (SELECT COUNT(1)
       FROM grac_practice.practice_instance pi
       LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
       LEFT JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
       LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=req.applicability_status_id
       LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
       LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
       WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
         AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
         AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
         AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
         AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
         AND (@criticality IS NULL OR pi.criticality=@criticality)
         AND (@date_from IS NULL OR pi.entered_dt>=@date_from) AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
         AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE '%'+@p_search+'%')) FinalReturnedCount;

    IF @p_id<>0
   BEGIN
     ;WITH configured_categories AS (
       SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id,
         COALESCE(dt.dependency_type_name,d.dependency_type) DependencyCategory
       FROM grac_practice.practice_instance_dependency d
       LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
       WHERE d.status='Active'
         AND d.practice_instance_id=@p_id
         AND d.dependency_type_id IS NOT NULL
       GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id,COALESCE(dt.dependency_type_name,d.dependency_type)
     )
     SELECT c.practice_instance_id PracticeInstanceId,c.dependency_type_id DependencyTypeId,c.DependencyCategory,
       r.resolution_id ResolutionId,r.resolved_dependency_id ResolvedDependencyId,r.resolved_dependency_name ResolvedDependencyName,
       COALESCE(drs.status_name,N'Pending') ResolutionStatus,r.resolution_owner_id ResolutionOwnerId,COALESCE(e.employee_name,N'') ResolutionOwner,
       r.resolution_dt ResolutionDate,r.remarks Remarks,
       CASE WHEN r.resolution_id IS NULL THEN N'Pending' ELSE N'Resolved' END CategoryStatus
     FROM configured_categories c
     LEFT JOIN grac_practice.practice_dependency_resolution r
       ON r.organization_id=c.organization_id
      AND r.practice_instance_id=c.practice_instance_id
      AND r.dependency_type_id=c.dependency_type_id
      AND r.is_active=1
     LEFT JOIN grac_practice.dependency_resolution_status_master drs ON drs.resolution_status_id=r.resolution_status_id
     LEFT JOIN grac_practice.organization_employee e ON e.employee_id=r.resolution_owner_id
     ORDER BY c.DependencyCategory,r.resolved_dependency_name;
   END
 END
 ELSE IF @p_entity_type='dependencies'
   SELECT d.dependency_id Id,d.practice_instance_id PracticeInstanceId,d.dependency_type_id DependencyTypeId,
     COALESCE(dt.dependency_type_name,d.dependency_type) DependencyType,d.dependency_name Name,
     d.dependency_reference_id DependencyReferenceId,d.dependency_source_type DependencySourceType,
     dependency_reference Reference,owner_name OwnerName,d.criticality_id CriticalityId,
     COALESCE(cm.criticality_name,d.criticality) Criticality,d.record_status_id StatusId,COALESCE(rs.status_name,d.status) Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice_instance_dependency d
   LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
   LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id=d.criticality_id
   LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=d.record_status_id
   WHERE (@p_id=0 OR d.dependency_id=@p_id) AND (@practice_instance_id IS NULL OR d.practice_instance_id=@practice_instance_id)
     AND (@organization_id IS NULL OR d.organization_id=@organization_id)
     AND (@p_status='' OR d.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
     AND (@owner IS NULL OR d.owner_name LIKE '%'+@owner+'%')
     AND (@criticality IS NULL OR d.criticality=@criticality OR cm.criticality_code=@criticality OR cm.criticality_name=@criticality)
     AND (@date_from IS NULL OR d.entered_dt>=@date_from) AND (@date_to IS NULL OR d.entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY COALESCE(dt.display_order,999),d.dependency_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='evidence-configurations'
 BEGIN
  SELECT e.evidence_id Id,e.practice_instance_id PracticeInstanceId,e.evidence_type_id EvidenceTypeId,
    COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceType,e.is_mandatory Mandatory,
    e.collection_method_id CollectionMethodId,cm.collection_method_name CollectionMethod,
    e.collection_frequency_id CollectionFrequencyId,f.frequency_name CollectionFrequency,
    e.evidence_owner EvidenceOwner,e.assurance_type_id AssuranceTypeId,at.assurance_type_name AssuranceTypeName,
    e.retention_period RetentionPeriod,e.record_status_id StatusId,COALESCE(rs.status_name,e.status) Status,et.display_order DisplayOrder,COUNT(*) OVER () AS TotalRows
  FROM grac_practice.practice_instance_evidence e
  LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
  LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id=e.collection_method_id
  LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_id=e.assurance_type_id
  LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=e.collection_frequency_id
  LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=e.record_status_id
   WHERE (@p_id=0 OR e.evidence_id=@p_id) AND (@practice_instance_id IS NULL OR e.practice_instance_id=@practice_instance_id)
     AND (@organization_id IS NULL OR e.organization_id=@organization_id)
     AND (@p_status='' OR e.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
     AND (@owner IS NULL OR e.evidence_owner LIKE '%'+@owner+'%')
    AND (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%' OR e.evidence_owner LIKE '%'+@p_search+'%' OR cm.collection_method_name LIKE '%'+@p_search+'%' OR f.frequency_name LIKE '%'+@p_search+'%')
  ORDER BY COALESCE(et.display_order,999),COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='evidence-obligations'
 BEGIN
   /* ── View Obligations  (updated 2026-07-06) ──────────────────────────
      Uses the current obligation model:
        GRAC_New.obligation_requirement_release_map  (mapping)
        GRAC_New.requirement_obligation              (obligation master)
        GRAC_New.requirement_obligation_evidence      (evidence per obligation)
      Legacy tables obligation / obligation_evidence_type are no longer used.
   ──────────────────────────────────────────────────────────────────────── */
   ;WITH context_requirement AS (
     SELECT DISTINCT
       req.organization_requirement_id,
       req.organization_id,
       COALESCE(req.repository_requirement_id,repo_req.requirement_id) repository_requirement_id,
       req.org_statement_id,
       req.organization_control_id,
       oc.repository_control_id,
       COALESCE(ofs.release_id,oc.release_id) context_release_id
     FROM grac_practice.organization_requirement req
     LEFT JOIN grac_practice.organization_framework_statements ofs
       ON ofs.org_statement_id=req.org_statement_id AND ofs.organization_id=req.organization_id
     LEFT JOIN grac_practice.organization_control oc
       ON oc.organization_control_id=req.organization_control_id AND oc.organization_id=req.organization_id
     LEFT JOIN GRAC_New.requirement repo_req
       ON repo_req.requirement_code=req.requirement_code AND repo_req.status='Active'
     WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id=@organization_requirement_id)
        OR (@practice_id IS NOT NULL AND EXISTS(
          SELECT 1 FROM grac_practice.practice p
          WHERE p.practice_id=@practice_id AND p.organization_requirement_id=req.organization_requirement_id))
        OR (@practice_instance_id IS NOT NULL AND EXISTS(
          SELECT 1 FROM grac_practice.practice_instance pi
          JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
          WHERE pi.practice_instance_id=@practice_instance_id AND p.organization_requirement_id=req.organization_requirement_id))
   ),
   /* Deduplicate: context_requirement may produce multiple rows with the same
      repository_requirement_id (via different org_statement / org_control paths).
      The CROSS JOIN below would multiply evidence rows without this step. */
   distinct_requirements AS (
     SELECT DISTINCT repository_requirement_id, organization_id
     FROM context_requirement
     WHERE repository_requirement_id IS NOT NULL
   ),
   /* Step 1: Get DISTINCT obligation_ids mapped to any requirement+release.
      No CROSS JOIN with releases — avoids multiplying evidence rows. */
   distinct_obligations AS (
     SELECT DISTINCT orm.obligation_id
     FROM distinct_requirements dr
     JOIN GRAC_New.obligation_requirement_release_map orm
       ON orm.requirement_id=dr.repository_requirement_id AND orm.status='Active'
   )
   /* Step 2: For each obligation, get evidence ONLY by obligation_id.
      Release info via OUTER APPLY (one representative release, no multiplication). */
   SELECT
     rel.release_id FrameworkReleaseId,
     rel.FrameworkRelease,
     o.obligation_id ObligationId,
     COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)),N''),LEFT(o.obligation_text,300)) ObligationName,
     COALESCE(exec_freq.option_label,o.frequency_type) ExecutionFrequency,
     o.retention_requirement ObligationRetention,
     o.approval_authority ApprovalAuthority,
     o.responsibility Responsibility,
     roe.obligation_evidence_id EvidenceId,
     roe.evidence_type_id EvidenceTypeId,
     et.evidence_type_name EvidenceType,
     f.frequency_id FrequencyId,
     COALESCE(f.frequency_name,cm_freq.option_label) Frequency,
     roe.retention_requirement RetentionRequirement,
     roe.remarks Remarks,COUNT(*) OVER () AS TotalRows
   FROM distinct_obligations dob
   JOIN GRAC_New.requirement_obligation o
     ON o.obligation_id=dob.obligation_id AND o.status='Active'
   JOIN GRAC_New.requirement_obligation_evidence roe
     ON roe.obligation_id=o.obligation_id AND roe.status='Active'
   JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=roe.evidence_type_id
   LEFT JOIN GRAC_New.reference_option exec_freq ON exec_freq.reference_option_id=o.execution_frequency_id
   LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id=roe.frequency_id
   OUTER APPLY (
     SELECT TOP 1 f2.frequency_id,f2.frequency_name
     FROM grac_practice.frequency_master f2
     WHERE f2.frequency_code=cm_freq.option_value OR f2.frequency_name=cm_freq.option_label
   ) f
   /* One representative release per obligation (no row multiplication) */
   OUTER APPLY (
     SELECT TOP 1 r.release_id,
       COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease
     FROM distinct_requirements dr2
     JOIN GRAC_New.obligation_requirement_release_map orm2
       ON orm2.requirement_id=dr2.repository_requirement_id AND orm2.obligation_id=dob.obligation_id AND orm2.status='Active'
     JOIN GRAC_New.release r ON r.release_id=orm2.release_id
     LEFT JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
   ) rel
   WHERE (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%'
          OR ISNULL(rel.FrameworkRelease,'') LIKE '%'+@p_search+'%'
          OR ISNULL(o.obligation_name,'') LIKE '%'+@p_search+'%')
   ORDER BY rel.FrameworkRelease,et.display_order,et.evidence_type_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='evidence-alignments'
   SELECT ea.evidence_alignment_id Id,ea.practice_instance_id PracticeInstanceId,ea.framework_release_id FrameworkReleaseId,
     COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease,
     eas.alignment_status_name AlignmentStatus,ea.alignment_reason AlignmentReason,ea.calculated_dt CalculatedDate
   FROM grac_practice.practice_instance_evidence_alignment ea
   JOIN grac_practice.evidence_alignment_status_master eas ON eas.alignment_status_id=ea.alignment_status_id
   LEFT JOIN GRAC_New.release r ON r.release_id=ea.framework_release_id
   LEFT JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
   WHERE (@practice_instance_id IS NULL OR ea.practice_instance_id=@practice_instance_id)
     AND ea.status='Active'
   ORDER BY FrameworkRelease;
 ELSE IF @p_entity_type='repository-subscription-tree'
   SELECT au.authority_id AuthorityId,au.authority_code AuthorityCode,au.authority_name AuthorityName,
     a.artifact_id ArtifactId,a.artifact_code ArtifactCode,a.artifact_name ArtifactName,
     r.release_id ReleaseId,r.version_no ReleaseVersion,r.status ReleaseStatus,
     CASE WHEN s.subscription_id IS NOT NULL AND s.status='Active' AND s.subscription_status='Active' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END IsSubscribed
   FROM grac_new.authority au
   JOIN grac_new.artifact a ON a.authority_id=au.authority_id AND a.status='Active'
   JOIN grac_new.release r ON r.artifact_id=a.artifact_id AND r.status IN ('Draft','Active')
   LEFT JOIN grac_practice.repository_subscription s ON s.organization_id=@organization_id AND s.release_id=r.release_id AND s.status='Active'
    WHERE au.status='Active'
    ORDER BY au.authority_code,a.artifact_code,r.version_no;
 ELSE IF @p_entity_type='menu-master'
   SELECT menu_id Id,menu_key MenuKey,menu_name MenuName,menu_url MenuUrl,parent_menu_id ParentMenuId,
     display_order DisplayOrder,icon_class IconClass,module_type ModuleType,status Status
   FROM grac_practice.menu_master
   WHERE status='Active'
   ORDER BY display_order,menu_name;
 ELSE IF @p_entity_type='assurance-dashboard'
 BEGIN
   ;WITH eligible AS (
     SELECT pi.organization_id,pi.practice_instance_id
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
     WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
       AND pi.status=N'Active'
       AND NULLIF(pi.primary_owner,N'') IS NOT NULL
       AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
       AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
       AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   )
   SELECT N'Eligible Practice Instances' Metric,COUNT_BIG(1) Value,N'Info' Severity,N'Resolved practice instances ready for assurance.' Message FROM eligible
   UNION ALL SELECT N'Pending Activities',COUNT_BIG(1),N'High',N'Assurance activities awaiting execution.' FROM grac_practice.assurance_activity WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND status=N'Pending'
   UNION ALL SELECT N'Overdue Activities',COUNT_BIG(1),N'High',N'Assurance activities past due date.' FROM grac_practice.assurance_activity WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND status NOT IN (N'Completed') AND due_dt<CONVERT(DATE,SYSUTCDATETIME())
   UNION ALL SELECT N'Open Findings',COUNT_BIG(1),N'High',N'Findings requiring closure.' FROM grac_practice.assurance_finding WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND finding_status NOT IN (N'Closed',N'Resolved')
   UNION ALL SELECT N'Open Signals',COUNT_BIG(1),N'Medium',N'Active assurance intelligence signals.' FROM grac_practice.assurance_signal WHERE (@organization_id IS NULL OR organization_id=@organization_id) AND signal_status<>N'Closed';
 END
 ELSE IF @p_entity_type='assurance-generation'
 BEGIN
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     pi.assurance_frequency_id AssuranceFrequencyId,COALESCE(freq.frequency_name,pi.frequency_type,N'Not Set') AssuranceFrequency,
     at.assurance_type_name AssuranceType,pi.criticality Criticality,
     CASE WHEN aa.assurance_activity_id IS NULL THEN N'Eligible' ELSE N'Already Generated' END EligibilityStatus,
     COALESCE(MAX(aa.period_to),CONVERT(DATE,pi.entered_dt)) LastAssurancePeriodTo,
     DATEADD(DAY,30,COALESCE(MAX(aa.period_to),CONVERT(DATE,pi.entered_dt))) NextDueDate,
     CASE WHEN aa.assurance_activity_id IS NULL THEN N'Ready' ELSE N'Skip' END ActionStatus,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice_instance pi
   JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
   LEFT JOIN grac_practice.frequency_master freq ON freq.frequency_id=pi.assurance_frequency_id
   LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_name=pi.assurance_mode OR at.assurance_type_code=pi.assurance_mode
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id AND aa.organization_id=pi.organization_id AND aa.status<>N'Completed'
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
     AND pi.status=N'Active'
     AND (@p_id=0 OR pi.practice_instance_id=@p_id)
     AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
     AND NULLIF(pi.primary_owner,N'') IS NOT NULL
     AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
     AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
     AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name,pi.assurance_frequency_id,freq.frequency_name,pi.frequency_type,at.assurance_type_name,pi.criticality,aa.assurance_activity_id,pi.entered_dt
   ORDER BY NextDueDate OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 END
 ELSE IF @p_entity_type='assurance-activities'
   SELECT aa.assurance_activity_id Id,aa.organization_id OrganizationId,aa.practice_instance_id PracticeInstanceId,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,aa.period_from PeriodFrom,aa.period_to PeriodTo,
     aa.assurance_type AssuranceType,aa.activity_owner ActivityOwner,aa.created_dt CreatedDate,aa.due_dt DueDate,aa.status Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_activity aa
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id)
     AND (@p_id=0 OR aa.assurance_activity_id=@p_id)
     AND (@p_status='' OR aa.status=@p_status)
     AND (@p_search='' OR aa.activity_number LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
   ORDER BY aa.due_dt DESC,aa.assurance_activity_id DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-execution'
   SELECT ex.assurance_execution_id Id,aa.assurance_activity_id ActivityId,aa.organization_id OrganizationId,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ex.execution_dt ExecutionDate,ex.executor_name Executor,
     ex.evidence_status EvidenceStatus,ex.dependency_status DependencyStatus,ex.result_status ResultStatus,aa.status Status,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_execution ex
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ex.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ex.assurance_execution_id=@p_id)
   ORDER BY ex.execution_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='evidence-assurance'
   SELECT ec.evidence_check_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ec.evidence_type_name EvidenceType,
     CASE WHEN ec.evidence_exists=1 THEN N'Yes' ELSE N'No' END EvidenceExists,
     CASE WHEN ec.evidence_accessible=1 THEN N'Yes' ELSE N'No' END EvidenceAccessible,
     CASE WHEN ec.matches_expected_type=1 THEN N'Yes' ELSE N'No' END MatchesExpectedType,
     CASE WHEN ec.relates_to_assurance=1 THEN N'Yes' ELSE N'No' END RelatesToAssurance,
     ec.result_status ResultStatus,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_evidence_check ec
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ec.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ec.evidence_check_id=@p_id)
   ORDER BY ec.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='dependency-assurance'
   SELECT dc.dependency_check_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,dc.dependency_type_name DependencyType,dc.resolved_dependency_name ResolvedDependency,
     CASE WHEN dc.dependency_available=1 THEN N'Yes' ELSE N'No' END DependencyAvailable,
     CASE WHEN dc.dependency_current=1 THEN N'Yes' ELSE N'No' END DependencyCurrent,
     dc.result_status ResultStatus,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_dependency_check dc
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=dc.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR dc.dependency_check_id=@p_id)
   ORDER BY dc.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-results'
   SELECT ar.assurance_result_id Id,aa.assurance_activity_id ActivityId,aa.activity_number ActivityNumber,aa.organization_id OrganizationId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,ar.result_status ResultStatus,ar.operating_effectiveness OperatingEffectiveness,
     ar.completed_dt CompletedDate,ar.completed_by CompletedBy,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_result ar
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=ar.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=aa.practice_instance_id
   WHERE (@organization_id IS NULL OR aa.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR aa.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR ar.assurance_result_id=@p_id)
   ORDER BY ar.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-findings'
   SELECT f.finding_id Id,f.organization_id OrganizationId,f.assurance_activity_id ActivityId,f.finding_number FindingNumber,aa.activity_number ActivityNumber,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,f.severity Severity,f.finding_status FindingStatus,f.owner_name Owner,f.due_dt DueDate,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_finding f
   JOIN grac_practice.assurance_activity aa ON aa.assurance_activity_id=f.assurance_activity_id
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=f.practice_instance_id
   WHERE (@organization_id IS NULL OR f.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR f.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR f.finding_id=@p_id)
   ORDER BY f.entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-signals'
   SELECT s.signal_id Id,s.organization_id OrganizationId,s.assurance_activity_id ActivityId,s.signal_type SignalType,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,s.severity Severity,s.signal_status SignalStatus,s.detected_dt DetectedDate,s.message Message,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.assurance_signal s
   LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=s.practice_instance_id
   WHERE (@organization_id IS NULL OR s.organization_id=@organization_id) AND (@assurance_activity_id IS NULL OR s.assurance_activity_id=@assurance_activity_id) AND (@p_id=0 OR s.signal_id=@p_id)
   ORDER BY s.detected_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-trends'
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     N'Activity Completion' TrendType,
     SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END) CurrentValue,
     COUNT_BIG(aa.assurance_activity_id) PreviousValue,
     CASE WHEN COUNT_BIG(aa.assurance_activity_id)=0 THEN N'No Data' WHEN SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END)=COUNT_BIG(aa.assurance_activity_id) THEN N'Improving' ELSE N'Watch' END TrendDirection,
     CASE WHEN SUM(CASE WHEN aa.status=N'Completed' THEN 1 ELSE 0 END)=COUNT_BIG(aa.assurance_activity_id) THEN N'Low' ELSE N'Medium' END Severity,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id) AND pi.status=N'Active'
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name
   ORDER BY PracticeInstance OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type IN ('practice-health','audit-intelligence','risk-intelligence')
   SELECT pi.practice_instance_id Id,pi.organization_id OrganizationId,pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     CASE WHEN @p_entity_type='practice-health' THEN CAST(100-COUNT(DISTINCT f.finding_id)*15 AS NVARCHAR(40)) ELSE COALESCE(MAX(ar.result_status),N'Not Assured') END HealthScore,
     CASE WHEN COUNT(DISTINCT f.finding_id)=0 THEN N'Healthy' WHEN COUNT(DISTINCT f.finding_id)<3 THEN N'Watch' ELSE N'At Risk' END HealthStatus,
     pi.criticality Criticality,MAX(aa.period_to) LastAssuredDate,COUNT(DISTINCT f.finding_id) OpenFindings,
     COALESCE(MAX(ar.result_status),N'Not Assured') LastAssuranceResult,
     CASE WHEN EXISTS(SELECT 1 FROM grac_practice.assurance_evidence_check ec WHERE ec.practice_instance_id=pi.practice_instance_id AND ec.result_status=N'Fail') THEN N'Failed' WHEN EXISTS(SELECT 1 FROM grac_practice.assurance_evidence_check ec WHERE ec.practice_instance_id=pi.practice_instance_id AND ec.result_status=N'Pass') THEN N'Passed' ELSE N'Not Checked' END EvidenceStatus,
     CASE WHEN @p_entity_type='audit-intelligence' THEN N'Practice Instance Operation' ELSE N'Assurance / Operational Risk' END AuditableArea,
     CASE WHEN @p_entity_type='risk-intelligence' AND COUNT(DISTINCT f.finding_id)>0 THEN N'Open finding risk' ELSE N'No active risk signal' END RiskSignal,
     CASE WHEN pi.criticality IN (N'Critical',N'High') OR COUNT(DISTINCT f.finding_id)>0 THEN N'High' ELSE N'Medium' END AuditPriority,
     CASE WHEN pi.criticality IN (N'Critical',N'High') OR COUNT(DISTINCT f.finding_id)>0 THEN N'High' ELSE N'Medium' END RiskPriority,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_activity aa ON aa.practice_instance_id=pi.practice_instance_id
   LEFT JOIN grac_practice.assurance_result ar ON ar.assurance_activity_id=aa.assurance_activity_id
   LEFT JOIN grac_practice.assurance_finding f ON f.practice_instance_id=pi.practice_instance_id AND f.finding_status NOT IN (N'Closed',N'Resolved')
   WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id) AND pi.status=N'Active'
   GROUP BY pi.practice_instance_id,pi.organization_id,pi.instance_code,pi.instance_name,pi.criticality
   ORDER BY OpenFindings DESC,PracticeInstance OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type IN ('applicability-discovery','applicability-results','repository-import','requirement-applicability',
   'assurance-attributes','vendor-attributes','risk-attributes','audit-attributes','task-attributes','resilience-attributes','future-triggers')
   SELECT CAST(NULL AS BIGINT) Id,CAST('Configured in upcoming phase' AS NVARCHAR(200)) Message WHERE 1=0;
 ELSE IF @p_entity_type='audit-trace'
   SELECT audit_trace_id Id,entity_type EntityType,entity_id EntityId,action_type ActionType,status Status,entered_by EnteredBy,entered_dt EnteredDt,COUNT(*) OVER () AS TotalRows
   FROM grac_practice.practice_audit_trace
   WHERE (@p_status='' OR status=@p_status)
     AND (@date_from IS NULL OR entered_dt>=@date_from) AND (@date_to IS NULL OR entered_dt<DATEADD(DAY,1,@date_to))
   ORDER BY entered_dt DESC OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
 ELSE IF @p_entity_type='assurance-schedule-rules'
   SELECT r.schedule_rule_id Id,r.organization_id OrganizationId,r.practice_instance_id PracticeInstanceId,
     pi.instance_code+N' - '+pi.instance_name PracticeInstance,
     r.frequency_id FrequencyId,fm.frequency_name FrequencyName,fm.frequency_value FrequencyValue,fm.frequency_unit FrequencyUnit,
     r.anchor_date AnchorDate,r.end_date EndDate,r.schedule_owner ScheduleOwner,r.notes Notes,r.is_active IsActive,r.status Status
   FROM grac_practice.assurance_schedule_rule r
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=r.practice_instance_id
   JOIN grac_practice.frequency_master fm ON fm.frequency_id=r.frequency_id
   WHERE (@organization_id IS NULL OR r.organization_id=@organization_id) AND r.status=N'Active'
     AND (@p_id=0 OR r.schedule_rule_id=@p_id)
   ORDER BY pi.instance_name;
 ELSE IF @p_entity_type='assurance-schedule-overrides'
   SELECT o.override_id Id,o.schedule_rule_id ScheduleRuleId,o.organization_id OrganizationId,
     o.original_date OriginalDate,o.override_type OverrideType,o.new_date NewDate,
     o.reason Reason,o.apply_to_future ApplyToFuture,o.override_by OverrideBy,o.status Status,o.entered_dt EnteredDt
   FROM grac_practice.assurance_schedule_override o
   WHERE (@organization_id IS NULL OR o.organization_id=@organization_id) AND o.status=N'Active'
     AND (@p_id=0 OR o.override_id=@p_id)
   ORDER BY o.original_date;
 ELSE IF @p_entity_type='assurance-calendar-config'
   SELECT c.config_id Id,c.organization_id OrganizationId,c.look_back_months LookBackMonths,
     c.look_ahead_months LookAheadMonths,c.default_view DefaultView,c.status Status
   FROM grac_practice.assurance_calendar_config c
   WHERE (@organization_id IS NULL OR c.organization_id=@organization_id);
 ELSE THROW 51002,'Unsupported practice area',1;
END
GO
