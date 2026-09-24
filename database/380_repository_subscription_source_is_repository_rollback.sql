-- =====================================================================
-- 380 ROLLBACK -- pm_manage_practice_repository back to 002's exact body,
-- and the backfilled rows back to Manual.
--
-- Restores the organization-setup release-subscription INSERT to write
-- 'Manual' (the pre-380 behaviour) and reverts every row this migration
-- backfilled -- recognised by the same release_id IS NOT NULL AND
-- subscription_type = 'Repository' criterion the forward migration used,
-- in reverse -- back to 'Manual'. As with every other rollback in this
-- project, this is a best-effort symmetric revert (a row some other,
-- unrelated process happened to also set to 'Repository' cannot be
-- distinguished from one this migration wrote), not a change-log replay.
--
-- Re-runnable: yes -- CREATE OR ALTER.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
BEGIN
    RAISERROR('380 rollback: grac_practice.repository_subscription missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.pm_manage_practice_repository
 @p_entity_type NVARCHAR(100), @p_action NVARCHAR(30), @p_id BIGINT=0, @p_search NVARCHAR(250)='', @p_status NVARCHAR(30)='',
 @p_payload NVARCHAR(MAX)='{}', @p_usr_id NVARCHAR(100)=''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
 SET @p_entity_type=ISNULL(@p_entity_type,'');
 SET @p_action=ISNULL(@p_action,'');
 SET @p_search=ISNULL(@p_search,'');
 SET @p_status=ISNULL(@p_status,'');
 SET @p_payload=ISNULL(NULLIF(@p_payload,''),'{}');
 SET @p_usr_id=ISNULL(@p_usr_id,'');
 DECLARE @new_id BIGINT=@p_id;
 DECLARE @result_message NVARCHAR(500)=N'Saved successfully.';
 IF NULLIF(@p_usr_id,'') IS NULL SET @p_usr_id='system';
 DECLARE @active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
 DECLARE @inactive_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Inactive');
 DECLARE @active_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
 DECLARE @disabled_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Disabled');
 DECLARE @not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
 DECLARE @not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');
 DECLARE @active_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Active');
 DECLARE @payload_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.status') OR status_name=JSON_VALUE(@p_payload,'$.status'));
 DECLARE @payload_record_status_id_from_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
 SET @payload_record_status_id=COALESCE(@payload_record_status_id_from_id,@payload_record_status_id);
 DECLARE @payload_subscription_status_id INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.subscriptionStatus') OR status_name=JSON_VALUE(@p_payload,'$.subscriptionStatus'));
 DECLARE @payload_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.applicabilityStatus') OR status_name=JSON_VALUE(@p_payload,'$.applicabilityStatus'));
 DECLARE @payload_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.implementationStatus') OR status_name=JSON_VALUE(@p_payload,'$.implementationStatus'));
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
 DECLARE @requested_organization_id BIGINT=COALESCE(
   TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),'')),
   TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organization.id'),''))
 );
 IF @requested_organization_id IS NOT NULL
    AND @is_system_admin=0
    AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@requested_organization_id)
   THROW 51052,'You do not have access to the selected organization.',1;

 IF @p_action='RETIRE'
 BEGIN
   DECLARE @retire_organization_id BIGINT=NULL;
   IF @p_entity_type='organizations' SET @retire_organization_id=@p_id;
   ELSE IF @p_entity_type='divisions' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_division WHERE division_id=@p_id;
   ELSE IF @p_entity_type='locations' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_location WHERE location_id=@p_id;
   ELSE IF @p_entity_type='departments' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_department WHERE department_id=@p_id;
   ELSE IF @p_entity_type='teams' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_team WHERE team_id=@p_id;
   ELSE IF @p_entity_type='committees' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_committee WHERE committee_id=@p_id;
   ELSE IF @p_entity_type='business-functions' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_business_function WHERE business_function_id=@p_id;
   ELSE IF @p_entity_type='roles' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_role WHERE role_id=@p_id;
   ELSE IF @p_entity_type='role-menu-permissions' SELECT @retire_organization_id=r.organization_id FROM grac_practice.organization_role_menu_permission p JOIN grac_practice.organization_role r ON r.role_id=p.role_id WHERE p.role_menu_permission_id=@p_id;
   ELSE IF @p_entity_type='users' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_employee WHERE employee_id=@p_id;
   ELSE IF @p_entity_type='dependency-applications' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_application WHERE application_id=@p_id;
   ELSE IF @p_entity_type='dependency-tools' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_tool WHERE tool_id=@p_id;
   ELSE IF @p_entity_type='dependency-vendors' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@p_id;
   ELSE IF @p_entity_type='dependency-assets' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_asset WHERE asset_id=@p_id;
   ELSE IF @p_entity_type='dependency-processes' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_dependency_process WHERE process_id=@p_id;
   ELSE IF @p_entity_type='organization-controls' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_control WHERE organization_control_id=@p_id;
   ELSE IF @p_entity_type='organization-requirements' SELECT @retire_organization_id=organization_id FROM grac_practice.organization_requirement WHERE organization_requirement_id=@p_id;
   ELSE IF @p_entity_type='repository-subscriptions' SELECT @retire_organization_id=organization_id FROM grac_practice.repository_subscription WHERE subscription_id=@p_id;
   ELSE IF @p_entity_type='practices' SELECT @retire_organization_id=organization_id FROM grac_practice.practice WHERE practice_id=@p_id;
   ELSE IF @p_entity_type='practice-instances' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance WHERE practice_instance_id=@p_id;
   ELSE IF @p_entity_type='dependencies' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance_dependency WHERE dependency_id=@p_id;
   ELSE IF @p_entity_type='practice-dependency-resolutions' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_dependency_resolution WHERE resolution_id=@p_id;
   ELSE IF @p_entity_type='evidence-configurations' SELECT @retire_organization_id=organization_id FROM grac_practice.practice_instance_evidence WHERE evidence_id=@p_id;
   IF @retire_organization_id IS NULL
     THROW 51054,'Selected record was not found or is no longer available.',1;
   IF @is_system_admin=0
      AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@retire_organization_id)
     THROW 51052,'You do not have access to the selected organization.',1;

   IF @p_entity_type='organizations' UPDATE grac_practice.organization SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_id=@p_id;
   ELSE IF @p_entity_type='divisions' UPDATE grac_practice.organization_division SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE division_id=@p_id;
   ELSE IF @p_entity_type='locations' UPDATE grac_practice.organization_location SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE location_id=@p_id;
   ELSE IF @p_entity_type='departments' UPDATE grac_practice.organization_department SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE department_id=@p_id;
   ELSE IF @p_entity_type='teams' UPDATE grac_practice.organization_team SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE team_id=@p_id;
   ELSE IF @p_entity_type='committees' UPDATE grac_practice.organization_committee SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE committee_id=@p_id;
   ELSE IF @p_entity_type='business-functions' UPDATE grac_practice.organization_business_function SET status='Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE business_function_id=@p_id;
   ELSE IF @p_entity_type='roles' UPDATE grac_practice.organization_role SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_id=@p_id;
   ELSE IF @p_entity_type='role-menu-permissions' UPDATE grac_practice.organization_role_menu_permission SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE role_menu_permission_id=@p_id;
   ELSE IF @p_entity_type='users' UPDATE grac_practice.organization_employee SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE employee_id=@p_id;
   ELSE IF @p_entity_type='dependency-applications' UPDATE grac_practice.organization_dependency_application SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE application_id=@p_id;
   ELSE IF @p_entity_type='dependency-tools' UPDATE grac_practice.organization_dependency_tool SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE tool_id=@p_id;
   ELSE IF @p_entity_type='dependency-vendors' UPDATE grac_practice.organization_dependency_vendor SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE vendor_id=@p_id;
   ELSE IF @p_entity_type='dependency-assets' UPDATE grac_practice.organization_dependency_asset SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE asset_id=@p_id;
   ELSE IF @p_entity_type='dependency-processes' UPDATE grac_practice.organization_dependency_process SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE process_id=@p_id;
   ELSE IF @p_entity_type='organization-controls' UPDATE grac_practice.organization_control SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_control_id=@p_id;
   ELSE IF @p_entity_type='organization-requirements' UPDATE grac_practice.organization_requirement SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_requirement_id=@p_id;
   ELSE IF @p_entity_type='repository-subscriptions'
   BEGIN
     UPDATE grac_practice.repository_subscription SET status='Inactive',record_status_id=@inactive_record_status_id,subscription_status='Disabled',subscription_status_id=@disabled_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE subscription_id=@p_id;
     UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     JOIN grac_practice.repository_subscription s ON s.subscription_id=@p_id AND s.organization_id=oc.organization_id AND s.release_id=oc.release_id
     WHERE oc.is_manually_added=0;
   END
   ELSE IF @p_entity_type='practices' UPDATE grac_practice.practice SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_id=@p_id;
   ELSE IF @p_entity_type='practice-instances' UPDATE grac_practice.practice_instance SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_instance_id=@p_id;
   ELSE IF @p_entity_type='dependencies' UPDATE grac_practice.practice_instance_dependency SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE dependency_id=@p_id;
   ELSE IF @p_entity_type='practice-dependency-resolutions' UPDATE grac_practice.practice_dependency_resolution SET is_active=0,record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE resolution_id=@p_id;
   ELSE IF @p_entity_type='evidence-configurations' UPDATE grac_practice.practice_instance_evidence SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE evidence_id=@p_id;
   ELSE THROW 51003,'Retirement is not configured for this practice area',1;
 END
 ELSE IF @p_entity_type='organization-setup'
 BEGIN
   DECLARE @setup_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organization.id'),''));
   DECLARE @setup_org_code NVARCHAR(50)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.organization.code'))),'');
   DECLARE @setup_org_name NVARCHAR(250)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.organization.name'))),'');
   IF @setup_org_id IS NULL SET @setup_org_id=0;
   IF @is_system_admin=0
     THROW 51053,'You do not have permission to create a new organization.',1;
   IF @setup_org_code IS NULL THROW 51010,'Organization Code is required.',1;
   IF @setup_org_name IS NULL THROW 51011,'Organization Name is required.',1;
   IF @setup_org_id=0
   BEGIN
     INSERT grac_practice.organization(organization_code,organization_name,industry,entity_type,country,status,record_status_id,entered_by)
     VALUES(@setup_org_code,@setup_org_name,JSON_VALUE(@p_payload,'$.organization.industry'),JSON_VALUE(@p_payload,'$.organization.entityType'),JSON_VALUE(@p_payload,'$.organization.country'),COALESCE(JSON_VALUE(@p_payload,'$.organization.status'),'Active'),COALESCE((SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.organization.status') OR status_name=JSON_VALUE(@p_payload,'$.organization.status')),@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     SET @new_id=@setup_org_id;
     UPDATE grac_practice.organization SET organization_code=@setup_org_code,organization_name=@setup_org_name,
       industry=JSON_VALUE(@p_payload,'$.organization.industry'),entity_type=JSON_VALUE(@p_payload,'$.organization.entityType'),country=JSON_VALUE(@p_payload,'$.organization.country'),
       status=COALESCE(JSON_VALUE(@p_payload,'$.organization.status'),status),
       record_status_id=COALESCE((SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code=JSON_VALUE(@p_payload,'$.organization.status') OR status_name=JSON_VALUE(@p_payload,'$.organization.status')),record_status_id),
       updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE organization_id=@new_id;
     IF @@ROWCOUNT=0 THROW 51012,'Selected organization was not found or is no longer available.',1;
   END

   DECLARE @attrs TABLE(metadata_key NVARCHAR(120), raw_value NVARCHAR(MAX));
   INSERT @attrs(metadata_key,raw_value)
   SELECT j.[key],
     CASE WHEN j.[type] IN (4,5) THEN j.[value] ELSE CONVERT(NVARCHAR(MAX),j.[value]) END
   FROM OPENJSON(@p_payload,'$.attributes') j
   WHERE NULLIF(j.[key],'') IS NOT NULL;

   UPDATE v SET
     value_text=CASE WHEN d.data_type NOT IN ('Json','Boolean','Number','Date') THEN a.raw_value ELSE NULL END,
     value_number=CASE WHEN d.data_type='Number' THEN TRY_CONVERT(DECIMAL(18,4),a.raw_value) ELSE NULL END,
     value_date=CASE WHEN d.data_type='Date' THEN TRY_CONVERT(DATE,a.raw_value) ELSE NULL END,
     value_bool=CASE WHEN d.data_type='Boolean' THEN CASE WHEN LOWER(a.raw_value) IN ('true','1','yes','y') THEN CAST(1 AS BIT) WHEN LOWER(a.raw_value) IN ('false','0','no','n') THEN CAST(0 AS BIT) ELSE NULL END ELSE NULL END,
     value_json=CASE WHEN d.data_type='Json' THEN a.raw_value ELSE NULL END,
     status='Active',record_status_id=@active_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_metadata_value v
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_definition_id=v.metadata_definition_id
   JOIN @attrs a ON a.metadata_key=d.metadata_key
   WHERE v.organization_id=@new_id;

   INSERT grac_practice.organization_metadata_value(organization_id,metadata_definition_id,value_text,value_number,value_date,value_bool,value_json,status,record_status_id,entered_by)
   SELECT @new_id,d.metadata_definition_id,
     CASE WHEN d.data_type NOT IN ('Json','Boolean','Number','Date') THEN a.raw_value ELSE NULL END,
     CASE WHEN d.data_type='Number' THEN TRY_CONVERT(DECIMAL(18,4),a.raw_value) ELSE NULL END,
     CASE WHEN d.data_type='Date' THEN TRY_CONVERT(DATE,a.raw_value) ELSE NULL END,
     CASE WHEN d.data_type='Boolean' THEN CASE WHEN LOWER(a.raw_value) IN ('true','1','yes','y') THEN CAST(1 AS BIT) WHEN LOWER(a.raw_value) IN ('false','0','no','n') THEN CAST(0 AS BIT) ELSE NULL END ELSE NULL END,
     CASE WHEN d.data_type='Json' THEN a.raw_value ELSE NULL END,
     'Active',@active_record_status_id,@p_usr_id
   FROM @attrs a
   JOIN grac_practice.organization_metadata_definition d ON d.metadata_key=a.metadata_key
   WHERE NOT EXISTS(SELECT 1 FROM grac_practice.organization_metadata_value v WHERE v.organization_id=@new_id AND v.metadata_definition_id=d.metadata_definition_id);

   DECLARE @selected_releases TABLE(release_id BIGINT PRIMARY KEY);
   INSERT @selected_releases(release_id)
   SELECT DISTINCT TRY_CONVERT(BIGINT,[value]) FROM OPENJSON(@p_payload,'$.releaseIds') WHERE TRY_CONVERT(BIGINT,[value]) IS NOT NULL;

   IF EXISTS(
     SELECT 1
     FROM @selected_releases x
     WHERE NOT EXISTS(SELECT 1 FROM grac_new.release r WHERE r.release_id=x.release_id)
   )
     THROW 51013,'One or more selected repository releases are not available.',1;

   UPDATE s SET status='Inactive',record_status_id=@inactive_record_status_id,subscription_status='Disabled',subscription_status_id=@disabled_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.repository_subscription s
   WHERE s.organization_id=@new_id AND s.status='Active'
     AND NOT EXISTS(SELECT 1 FROM @selected_releases r WHERE r.release_id=s.release_id);

   UPDATE s SET status='Active',record_status_id=@active_record_status_id,subscription_status='Active',subscription_status_id=@active_subscription_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.repository_subscription s
   JOIN @selected_releases r ON r.release_id=s.release_id
   WHERE s.organization_id=@new_id AND s.status<>'Active';

   INSERT grac_practice.repository_subscription(organization_id,authority_id,artifact_id,release_id,subscription_type,subscription_status,subscription_status_id,effective_dt,status,record_status_id,entered_by)
   SELECT @new_id,a.authority_id,a.artifact_id,r.release_id,'Manual','Active',@active_subscription_status_id,CONVERT(DATE,SYSUTCDATETIME()),'Active',@active_record_status_id,@p_usr_id
   FROM @selected_releases x
   JOIN grac_new.release r ON r.release_id=x.release_id
   JOIN grac_new.artifact a ON a.artifact_id=r.artifact_id
   WHERE NOT EXISTS(SELECT 1 FROM grac_practice.repository_subscription s WHERE s.organization_id=@new_id AND s.release_id=r.release_id);

   ;WITH release_controls AS (
     SELECT DISTINCT
       scm.control_id,
       COALESCE(scm.release_id,n.release_id) release_id,
       COALESCE(scm.artifact_id,r.artifact_id) artifact_id
     FROM grac_new.source_control_map scm
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
     JOIN grac_new.release r ON r.release_id=n.release_id
     JOIN @selected_releases sr ON sr.release_id=COALESCE(scm.release_id,n.release_id)
     WHERE scm.status='Active' AND n.status='Active'
   ),
   repository_controls AS (
     SELECT
       rc.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       rc.release_id,
       rc.artifact_id,
       s.subscription_id
     FROM release_controls rc
     JOIN grac_new.control c ON c.control_id=rc.control_id AND c.status='Active'
     JOIN grac_practice.repository_subscription s ON s.organization_id=@new_id AND s.release_id=rc.release_id AND s.record_status_id=@active_record_status_id AND s.subscription_status_id=@active_subscription_status_id
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
     updated_by=@p_usr_id,
     updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   JOIN repository_controls rc ON rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id
   WHERE oc.organization_id=@new_id;

   ;WITH release_controls AS (
     SELECT DISTINCT
       scm.control_id,
       COALESCE(scm.release_id,n.release_id) release_id,
       COALESCE(scm.artifact_id,r.artifact_id) artifact_id
     FROM grac_new.source_control_map scm
     JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
     JOIN grac_new.release r ON r.release_id=n.release_id
     JOIN @selected_releases sr ON sr.release_id=COALESCE(scm.release_id,n.release_id)
     WHERE scm.status='Active' AND n.status='Active'
   ),
   repository_controls AS (
     SELECT
       rc.control_id,
       c.control_code,
       c.control_name,
       c.description,
       c.objective,
       c.control_domain_id,
       c.control_sub_domain_id,
       rc.release_id,
       rc.artifact_id,
       s.subscription_id
     FROM release_controls rc
     JOIN grac_new.control c ON c.control_id=rc.control_id AND c.status='Active'
     JOIN grac_practice.repository_subscription s ON s.organization_id=@new_id AND s.release_id=rc.release_id AND s.record_status_id=@active_record_status_id AND s.subscription_status_id=@active_subscription_status_id
   )
   INSERT grac_practice.organization_control(
     organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
     is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
   SELECT @new_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
     0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,@p_usr_id
   FROM repository_controls rc
   WHERE NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_control oc
     WHERE oc.organization_id=@new_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
   );

   UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.organization_control oc
   WHERE oc.organization_id=@new_id
     AND oc.is_manually_added=0
     AND oc.release_id IS NOT NULL
     AND NOT EXISTS(SELECT 1 FROM @selected_releases sr WHERE sr.release_id=oc.release_id);

   DECLARE @recommended_releases TABLE(release_id BIGINT PRIMARY KEY, recommendation_reason NVARCHAR(1000), confidence_level NVARCHAR(30));
   INSERT @recommended_releases(release_id,recommendation_reason,confidence_level)
   SELECT DISTINCT TRY_CONVERT(BIGINT,JSON_VALUE([value],'$.releaseId')),
     LEFT(COALESCE(JSON_VALUE([value],'$.reason'),N'Recommended by applicability engine'),1000),
     COALESCE(JSON_VALUE([value],'$.confidence'),N'Medium')
   FROM OPENJSON(@p_payload,'$.recommendations')
   WHERE TRY_CONVERT(BIGINT,JSON_VALUE([value],'$.releaseId')) IS NOT NULL;

   INSERT grac_practice.subscription_recommendation_history(organization_id,authority_id,artifact_id,release_id,recommendation_reason,confidence_level,decision_status,status,entered_by)
   SELECT @new_id,a.authority_id,a.artifact_id,r.release_id,rr.recommendation_reason,rr.confidence_level,
     CASE WHEN sr.release_id IS NULL THEN N'Rejected' ELSE N'Accepted' END,N'Active',@p_usr_id
   FROM @recommended_releases rr
   JOIN grac_new.release r ON r.release_id=rr.release_id
   JOIN grac_new.artifact a ON a.artifact_id=r.artifact_id
   LEFT JOIN @selected_releases sr ON sr.release_id=rr.release_id;
 END
 ELSE IF @p_entity_type='organizations'
 BEGIN
   IF @is_system_admin=0
     THROW 51053,'You do not have permission to manage organizations.',1;
   IF @p_id=0 BEGIN
     INSERT grac_practice.organization(organization_code,organization_name,industry,entity_type,country,status,record_status_id,entered_by)
     VALUES(JSON_VALUE(@p_payload,'$.code'),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.industry'),JSON_VALUE(@p_payload,'$.entityType'),JSON_VALUE(@p_payload,'$.country'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.organization SET organization_code=JSON_VALUE(@p_payload,'$.code'),organization_name=JSON_VALUE(@p_payload,'$.name'),
     industry=JSON_VALUE(@p_payload,'$.industry'),entity_type=JSON_VALUE(@p_payload,'$.entityType'),country=JSON_VALUE(@p_payload,'$.country'),
     status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE organization_id=@p_id;
 END
 ELSE IF @p_entity_type='divisions'
 BEGIN
   DECLARE @division_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @division_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @division_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @division_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.headUserId'),''));
   IF @division_org_id IS NULL THROW 51060,'Organization is required for Division.',1;
   IF @division_code IS NULL THROW 51061,'Division Code is required.',1;
   IF @division_name IS NULL THROW 51062,'Division Name is required.',1;
   IF @division_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@division_head_id AND organization_id=@division_org_id AND status='Active')
     THROW 51063,'Selected Division Head is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_division(organization_id,division_code,division_name,head_employee_id,description,status,record_status_id,entered_by)
     VALUES(@division_org_id,@division_code,@division_name,@division_head_id,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_division SET organization_id=@division_org_id,division_code=@division_code,division_name=@division_name,
       head_employee_id=@division_head_id,description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
       record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE division_id=@p_id;
 END
 ELSE IF @p_entity_type='locations'
 BEGIN
   DECLARE @location_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @location_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @location_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.locationTypeId'),''));
   DECLARE @location_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationHeadId'),''));
   DECLARE @location_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @location_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@location_status_id),'Active');
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Mirrors the same guard in the dedicated sp_org_location_save shim
   -- (361) -- this monolith branch only runs when that shim is missing.
   DECLARE @location_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_location WHERE location_id=@p_id) END;
   IF @location_status_id<>ISNULL(@location_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@location_status_id AND status_code IN ('Active','Inactive'))
     THROW 51077,'Location status can only be set to Active or Inactive.',1;
   IF @location_org_id IS NULL THROW 51064,'Organization is required for Location.',1;
   IF @location_name IS NULL THROW 51065,'Location Name is required.',1;
   IF @location_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.location_type_master WHERE location_type_id=@location_type_id AND is_active=1)
     THROW 51066,'Location Type is required.',1;
   IF @location_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@location_head_id AND organization_id=@location_org_id AND status='Active')
     THROW 51067,'Selected Location Head is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_location(organization_id,location_name,location_type_id,location_head_id,region,remarks,status,record_status_id,entered_by)
     VALUES(@location_org_id,@location_name,@location_type_id,@location_head_id,JSON_VALUE(@p_payload,'$.region'),JSON_VALUE(@p_payload,'$.remarks'),@location_status_name,@location_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_location SET organization_id=@location_org_id,location_name=@location_name,location_type_id=@location_type_id,
       location_head_id=@location_head_id,region=JSON_VALUE(@p_payload,'$.region'),remarks=JSON_VALUE(@p_payload,'$.remarks'),
       status=@location_status_name,record_status_id=@location_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE location_id=@p_id;
 END
 ELSE IF @p_entity_type='departments'
 BEGIN
   DECLARE @department_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @department_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @department_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @department_head_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.headUserId'),''));
   IF @department_org_id IS NULL THROW 51040,'Organization is required for Department.',1;
   IF @department_code IS NULL THROW 51041,'Department Code is required.',1;
   IF @department_name IS NULL THROW 51042,'Department Name is required.',1;
   IF @department_head_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@department_head_id AND organization_id=@department_org_id AND status='Active')
     THROW 51043,'Selected Department Head is not valid for this organization.',1;
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Department has no dedicated shim, so this is the only save path.
   DECLARE @department_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_department WHERE department_id=@p_id) END;
   DECLARE @department_resolved_status_id INT=COALESCE(@payload_record_status_id,@department_current_status_id,@active_record_status_id);
   IF @department_resolved_status_id<>ISNULL(@department_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@department_resolved_status_id AND status_code IN ('Active','Inactive'))
     THROW 51078,'Department status can only be set to Active or Inactive.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_department(organization_id,department_code,department_name,head_employee_id,description,status,record_status_id,entered_by)
     VALUES(@department_org_id,@department_code,@department_name,@department_head_id,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_department SET organization_id=@department_org_id,department_code=@department_code,department_name=@department_name,
       head_employee_id=@department_head_id,description=JSON_VALUE(@p_payload,'$.description'),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
       record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE department_id=@p_id;
 END
 ELSE IF @p_entity_type='teams'
 BEGIN
   DECLARE @team_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @team_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @team_manager_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.teamManagerId'),''));
   DECLARE @team_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.parentDepartmentId'),''));
   DECLARE @team_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @team_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@team_status_id),'Active');
   -- Status restriction (2026-09-20 change request): a NEW status may only
   -- be Active or Inactive; a legacy status already on the row (Retired/
   -- Draft/Disposed/...) is left alone unless this save actually changes
   -- it. Mirrors the same guard in the dedicated sp_org_team_save shim
   -- (133) -- this monolith branch only runs when that shim is missing.
   DECLARE @team_current_status_id INT=CASE WHEN @p_id<>0 THEN (SELECT record_status_id FROM grac_practice.organization_team WHERE team_id=@p_id) END;
   IF @team_status_id<>ISNULL(@team_current_status_id,-1)
      AND NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@team_status_id AND status_code IN ('Active','Inactive'))
     THROW 51081,'Team status can only be set to Active or Inactive.',1;
   IF @team_org_id IS NULL THROW 51068,'Organization is required for Team.',1;
   IF @team_name IS NULL THROW 51069,'Team Name is required.',1;
   IF @team_manager_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@team_manager_id AND organization_id=@team_org_id AND status='Active')
     THROW 51070,'Selected Team Manager is not valid for this organization.',1;
   IF @team_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@team_department_id AND organization_id=@team_org_id AND status='Active')
     THROW 51071,'Selected Parent Department is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_team(organization_id,team_name,team_manager_id,parent_department_id,remarks,status,record_status_id,entered_by)
     VALUES(@team_org_id,@team_name,@team_manager_id,@team_department_id,JSON_VALUE(@p_payload,'$.remarks'),@team_status_name,@team_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_team SET organization_id=@team_org_id,team_name=@team_name,team_manager_id=@team_manager_id,
       parent_department_id=@team_department_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@team_status_name,record_status_id=@team_status_id,
       updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE team_id=@p_id;
 END
 ELSE IF @p_entity_type='committees'
 BEGIN
   DECLARE @committee_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @committee_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @committee_chairperson_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.chairpersonId'),''));
   DECLARE @committee_secretary_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.secretaryId'),''));
   DECLARE @committee_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.reviewFrequencyId'),''));
   DECLARE @committee_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @committee_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@committee_status_id),'Active');
   IF @committee_org_id IS NULL THROW 51072,'Organization is required for Committee.',1;
   IF @committee_name IS NULL THROW 51073,'Committee Name is required.',1;
   IF @committee_chairperson_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_chairperson_id AND organization_id=@committee_org_id AND status='Active')
     THROW 51074,'Selected Chairperson is not valid for this organization.',1;
   IF @committee_secretary_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_secretary_id AND organization_id=@committee_org_id AND status='Active')
     THROW 51075,'Selected Secretary is not valid for this organization.',1;
   IF @committee_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@committee_frequency_id AND is_active=1)
     THROW 51076,'Selected Review Frequency is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_committee(organization_id,committee_name,chairperson_id,secretary_id,review_frequency_id,remarks,status,record_status_id,entered_by)
     VALUES(@committee_org_id,@committee_name,@committee_chairperson_id,@committee_secretary_id,@committee_frequency_id,JSON_VALUE(@p_payload,'$.remarks'),@committee_status_name,@committee_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_committee SET organization_id=@committee_org_id,committee_name=@committee_name,chairperson_id=@committee_chairperson_id,
       secretary_id=@committee_secretary_id,review_frequency_id=@committee_frequency_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),
       status=@committee_status_name,record_status_id=@committee_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE committee_id=@p_id;
 END
 ELSE IF @p_entity_type='business-functions'
 BEGIN
   DECLARE @function_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @function_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @function_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   IF @function_org_id IS NULL THROW 51044,'Organization is required for Business Function.',1;
   IF @function_code IS NULL THROW 51045,'Function Code is required.',1;
   IF @function_name IS NULL THROW 51046,'Function Name is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_business_function(organization_id,function_code,function_name,owner_name,criticality,status,entered_by)
     VALUES(@function_org_id,@function_code,@function_name,JSON_VALUE(@p_payload,'$.ownerName'),COALESCE(JSON_VALUE(@p_payload,'$.criticality'),'Medium'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_business_function SET organization_id=@function_org_id,function_code=@function_code,function_name=@function_name,
       owner_name=JSON_VALUE(@p_payload,'$.ownerName'),criticality=COALESCE(JSON_VALUE(@p_payload,'$.criticality'),criticality),
       status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE business_function_id=@p_id;
 END
 ELSE IF @p_entity_type='roles'
 BEGIN
   DECLARE @role_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @role_name NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.roleName'))),'');
   IF @role_org_id IS NULL THROW 51140,'Organization is required for Role.',1;
   IF @role_name IS NULL THROW 51141,'Role Name is required.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE organization_id=@role_org_id AND LOWER(role_name)=LOWER(@role_name) AND (@p_id=0 OR role_id<>@p_id))
     THROW 51142,'Role Name already exists for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_role(organization_id,role_name,description,status,record_status_id,entered_by)
     VALUES(@role_org_id,@role_name,JSON_VALUE(@p_payload,'$.description'),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_role
     SET organization_id=@role_org_id,role_name=@role_name,description=JSON_VALUE(@p_payload,'$.description'),
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE role_id=@p_id;
 END
 ELSE IF @p_entity_type='role-menu-permissions'
 BEGIN
   DECLARE @permission_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @permission_role_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.roleId'),''));
   DECLARE @permission_menu_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.menuId'),''));
   DECLARE @permission_view BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canView'),'true')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_add BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canAdd'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_edit BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canEdit'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_delete BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canDelete'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   DECLARE @permission_approve BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.canApprove'),'false')) IN ('true','1','yes') THEN 1 ELSE 0 END;
   IF @permission_role_id IS NULL THROW 51143,'Role is required for Menu Permission.',1;
   IF @permission_menu_id IS NULL THROW 51144,'Menu is required for Menu Permission.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE role_id=@permission_role_id AND (@permission_org_id IS NULL OR organization_id=@permission_org_id) AND status='Active')
     THROW 51145,'Selected role is not valid for this organization.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.menu_master WHERE menu_id=@permission_menu_id AND status='Active')
     THROW 51146,'Selected menu is not active.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_role_menu_permission WHERE role_id=@permission_role_id AND menu_id=@permission_menu_id AND (@p_id=0 OR role_menu_permission_id<>@p_id))
     THROW 51147,'This menu is already mapped to the selected role.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
     VALUES(@permission_role_id,@permission_menu_id,@permission_view,@permission_add,@permission_edit,@permission_delete,@permission_approve,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_role_menu_permission
     SET role_id=@permission_role_id,menu_id=@permission_menu_id,can_view=@permission_view,can_add=@permission_add,can_edit=@permission_edit,can_delete=@permission_delete,can_approve=@permission_approve,
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE role_menu_permission_id=@p_id;
 END
 ELSE IF @p_entity_type='users'
 BEGIN
   DECLARE @employee_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @employee_code NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeCode'))),'');
   DECLARE @employee_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.employeeName'))),'');
   DECLARE @employee_email NVARCHAR(250)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.email'))),'');
   DECLARE @employee_password_hash NVARCHAR(500)=NULLIF(JSON_VALUE(@p_payload,'$.passwordHash'),'');
   DECLARE @employee_role_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.roleId'),''));
   DECLARE @employee_location_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationId'),''));
   DECLARE @employee_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.departmentId'),''));
   DECLARE @employee_function_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''));
   DECLARE @employee_reporting_officer_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.reportingOfficerId'),''));
   IF @employee_org_id IS NULL THROW 51047,'Organization is required for User / Employee.',1;
   IF @employee_code IS NULL THROW 51048,'Employee Code is required.',1;
   IF @employee_name IS NULL THROW 51049,'Employee Name is required.',1;
   IF @employee_email IS NULL THROW 51148,'Email ID is required for User / Employee login.',1;
   IF EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE LOWER(LTRIM(RTRIM(email)))=LOWER(@employee_email) AND (@p_id=0 OR employee_id<>@p_id))
     THROW 51149,'Employee Email ID already exists.',1;
   IF @p_id=0 AND @employee_password_hash IS NULL THROW 51152,'Password is required when creating a User / Employee.',1;
   IF @employee_role_id IS NULL THROW 51150,'Role is required for User / Employee.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.organization_role WHERE role_id=@employee_role_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51151,'Selected Role is not valid for this organization.',1;
   IF @employee_location_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_location WHERE location_id=@employee_location_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51056,'Selected Location is not valid for this organization.',1;
   IF @employee_department_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@employee_department_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51050,'Selected Department is not valid for this organization.',1;
   IF @employee_function_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_business_function WHERE business_function_id=@employee_function_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51051,'Selected Business Function is not valid for this organization.',1;
   IF @employee_reporting_officer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@employee_reporting_officer_id AND organization_id=@employee_org_id AND status='Active')
     THROW 51054,'Selected Reporting Officer is not valid for this organization.',1;
   IF @p_id<>0 AND @employee_reporting_officer_id=@p_id
     THROW 51055,'Reporting Officer cannot be the same employee.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_employee(organization_id,employee_code,employee_name,email,password_hash,role_id,designation,location_id,department,department_id,business_function_id,reporting_officer_id,status,record_status_id,entered_by)
     SELECT @employee_org_id,@employee_code,@employee_name,@employee_email,@employee_password_hash,@employee_role_id,JSON_VALUE(@p_payload,'$.designation'),@employee_location_id,d.department_name,@employee_department_id,@employee_function_id,
       @employee_reporting_officer_id,
       COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id
     FROM (SELECT CAST(NULL AS NVARCHAR(200)) department_name) empty
     OUTER APPLY (SELECT department_name FROM grac_practice.organization_department WHERE department_id=@employee_department_id) d;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE e SET organization_id=@employee_org_id,employee_code=@employee_code,employee_name=@employee_name,email=@employee_email,
       password_hash=COALESCE(@employee_password_hash,e.password_hash),role_id=@employee_role_id,
       designation=JSON_VALUE(@p_payload,'$.designation'),location_id=@employee_location_id,department=d.department_name,department_id=@employee_department_id,business_function_id=@employee_function_id,
       reporting_officer_id=@employee_reporting_officer_id,
       status=COALESCE(JSON_VALUE(@p_payload,'$.status'),e.status),record_status_id=COALESCE(@payload_record_status_id,e.record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_employee e
     OUTER APPLY (SELECT department_name FROM grac_practice.organization_department WHERE department_id=@employee_department_id) d
     WHERE e.employee_id=@p_id;

   IF @employee_email IS NOT NULL
   BEGIN
     INSERT grac_practice.user_organization_map(user_email,organization_id,access_role,is_default,status,record_status_id,entered_by)
     SELECT @employee_email,@employee_org_id,'Organization User',0,'Active',@active_record_status_id,@p_usr_id
     WHERE NOT EXISTS(SELECT 1 FROM grac_practice.user_organization_map WHERE user_email=@employee_email AND organization_id=@employee_org_id);
   END
 END
 ELSE IF @p_entity_type='dependency-vendors'
 BEGIN
   DECLARE @vendor_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @vendor_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @vendor_category_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.serviceCategoryId'),''));
   DECLARE @vendor_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.relationshipOwnerId'),''));
   DECLARE @vendor_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @vendor_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @vendor_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@vendor_status_id),'Active');
   IF @vendor_org_id IS NULL THROW 51100,'Organization is required for Vendor.',1;
   IF @vendor_name IS NULL THROW 51101,'Vendor Name is required.',1;
   IF @vendor_category_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.dependency_service_category_master WHERE service_category_id=@vendor_category_id AND is_active=1)
     THROW 51102,'Service Category is required.',1;
   IF @vendor_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@vendor_owner_id AND organization_id=@vendor_org_id AND status='Active')
     THROW 51103,'Selected Relationship Owner is not valid for this organization.',1;
   IF @vendor_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@vendor_criticality_id AND is_active=1)
     THROW 51104,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_vendor(organization_id,vendor_name,service_category_id,relationship_owner_id,contract_start_dt,contract_end_dt,renewal_dt,sla_applicable,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@vendor_org_id,@vendor_name,@vendor_category_id,@vendor_owner_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractStartDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractEndDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.renewalDate'),'')),
       CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.slaApplicable'),'false')) IN ('true','1','yes','y') THEN 1 ELSE 0 END,@vendor_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@vendor_status_name,@vendor_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_vendor SET organization_id=@vendor_org_id,vendor_name=@vendor_name,service_category_id=@vendor_category_id,
       relationship_owner_id=@vendor_owner_id,contract_start_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractStartDate'),'')),contract_end_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.contractEndDate'),'')),
       renewal_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.renewalDate'),'')),sla_applicable=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.slaApplicable'),'false')) IN ('true','1','yes','y') THEN 1 ELSE 0 END,
       criticality_id=@vendor_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@vendor_status_name,record_status_id=@vendor_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE vendor_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-applications'
 BEGIN
   DECLARE @app_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @app_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @app_business_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessOwnerId'),''));
   DECLARE @app_technical_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.technicalOwnerId'),''));
   DECLARE @app_vendor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.vendorId'),''));
   DECLARE @app_hosting_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.hostingTypeId'),''));
   DECLARE @app_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @app_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @app_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@app_status_id),'Active');
   IF @app_org_id IS NULL THROW 51110,'Organization is required for Application.',1;
   IF @app_name IS NULL THROW 51111,'Application Name is required.',1;
   IF @app_business_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@app_business_owner_id AND organization_id=@app_org_id AND status='Active')
     THROW 51112,'Selected Business Owner is not valid for this organization.',1;
   IF @app_technical_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@app_technical_owner_id AND organization_id=@app_org_id AND status='Active')
     THROW 51113,'Selected Technical Owner is not valid for this organization.',1;
   IF @app_vendor_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@app_vendor_id AND organization_id=@app_org_id AND status='Active')
     THROW 51114,'Selected Vendor is not valid for this organization.',1;
   IF @app_hosting_type_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.dependency_hosting_type_master WHERE hosting_type_id=@app_hosting_type_id AND is_active=1)
     THROW 51115,'Selected Hosting Type is not valid.',1;
   IF @app_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@app_criticality_id AND is_active=1)
     THROW 51116,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_application(organization_id,application_name,description,business_owner_id,technical_owner_id,vendor_id,version_no,hosting_type_id,support_expiry_dt,end_of_life_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@app_org_id,@app_name,JSON_VALUE(@p_payload,'$.description'),@app_business_owner_id,@app_technical_owner_id,@app_vendor_id,JSON_VALUE(@p_payload,'$.version'),@app_hosting_type_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.endOfLifeDate'),'')),@app_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@app_status_name,@app_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_application SET organization_id=@app_org_id,application_name=@app_name,description=JSON_VALUE(@p_payload,'$.description'),
       business_owner_id=@app_business_owner_id,technical_owner_id=@app_technical_owner_id,vendor_id=@app_vendor_id,version_no=JSON_VALUE(@p_payload,'$.version'),
       hosting_type_id=@app_hosting_type_id,support_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),end_of_life_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.endOfLifeDate'),'')),
       criticality_id=@app_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@app_status_name,record_status_id=@app_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE application_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-tools'
 BEGIN
   DECLARE @tool_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @tool_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @tool_business_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessOwnerId'),''));
   DECLARE @tool_vendor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.vendorId'),''));
   DECLARE @tool_license_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.licenseTypeId'),''));
   DECLARE @tool_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @tool_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @tool_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@tool_status_id),'Active');
   IF @tool_org_id IS NULL THROW 51120,'Organization is required for Tool.',1;
   IF @tool_name IS NULL THROW 51121,'Tool Name is required.',1;
   IF @tool_business_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@tool_business_owner_id AND organization_id=@tool_org_id AND status='Active')
     THROW 51122,'Selected Business Owner is not valid for this organization.',1;
   IF @tool_vendor_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_dependency_vendor WHERE vendor_id=@tool_vendor_id AND organization_id=@tool_org_id AND status='Active')
     THROW 51123,'Selected Vendor is not valid for this organization.',1;
   IF @tool_license_type_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.dependency_license_type_master WHERE license_type_id=@tool_license_type_id AND is_active=1)
     THROW 51124,'Selected License Type is not valid.',1;
   IF @tool_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@tool_criticality_id AND is_active=1)
     THROW 51125,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_tool(organization_id,tool_name,description,business_owner_id,vendor_id,license_type_id,license_expiry_dt,support_expiry_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@tool_org_id,@tool_name,JSON_VALUE(@p_payload,'$.description'),@tool_business_owner_id,@tool_vendor_id,@tool_license_type_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.licenseExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),@tool_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@tool_status_name,@tool_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_tool SET organization_id=@tool_org_id,tool_name=@tool_name,description=JSON_VALUE(@p_payload,'$.description'),
       business_owner_id=@tool_business_owner_id,vendor_id=@tool_vendor_id,license_type_id=@tool_license_type_id,
       license_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.licenseExpiryDate'),'')),support_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.supportExpiryDate'),'')),
       criticality_id=@tool_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@tool_status_name,record_status_id=@tool_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE tool_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-assets'
 BEGIN
   DECLARE @asset_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @asset_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @asset_category_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assetCategoryId'),''));
   DECLARE @asset_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.ownerId'),''));
   DECLARE @asset_location_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.locationId'),''));
   DECLARE @asset_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @asset_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @asset_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@asset_status_id),'Active');
   IF @asset_org_id IS NULL THROW 51130,'Organization is required for Asset.',1;
   IF @asset_name IS NULL THROW 51131,'Asset Name is required.',1;
   IF @asset_category_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_id=@asset_category_id AND is_active=1)
     THROW 51132,'Asset Category is required.',1;
   IF @asset_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@asset_owner_id AND organization_id=@asset_org_id AND status='Active')
     THROW 51133,'Selected Owner is not valid for this organization.',1;
   IF @asset_location_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_location WHERE location_id=@asset_location_id AND organization_id=@asset_org_id AND status='Active')
     THROW 51134,'Selected Location is not valid for this organization.',1;
   IF @asset_criticality_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@asset_criticality_id AND is_active=1)
     THROW 51135,'Selected Criticality is not valid.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_asset(organization_id,asset_name,asset_category_id,owner_id,location_id,purchase_dt,warranty_expiry_dt,amc_expiry_dt,criticality_id,remarks,status,record_status_id,entered_by)
     VALUES(@asset_org_id,@asset_name,@asset_category_id,@asset_owner_id,@asset_location_id,TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.purchaseDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.warrantyExpiryDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.amcExpiryDate'),'')),@asset_criticality_id,JSON_VALUE(@p_payload,'$.remarks'),@asset_status_name,@asset_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_asset SET organization_id=@asset_org_id,asset_name=@asset_name,asset_category_id=@asset_category_id,
       owner_id=@asset_owner_id,location_id=@asset_location_id,purchase_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.purchaseDate'),'')),
       warranty_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.warrantyExpiryDate'),'')),amc_expiry_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.amcExpiryDate'),'')),
       criticality_id=@asset_criticality_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@asset_status_name,record_status_id=@asset_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE asset_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-processes'
 BEGIN
   DECLARE @process_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @process_name NVARCHAR(220)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @process_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.processOwnerId'),''));
   DECLARE @process_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @process_status_name NVARCHAR(30)=COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id=@process_status_id),'Active');
   IF @process_org_id IS NULL THROW 51140,'Organization is required for Process.',1;
   IF @process_name IS NULL THROW 51141,'Process Name is required.',1;
   IF @process_owner_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@process_owner_id AND organization_id=@process_org_id AND status='Active')
     THROW 51142,'Selected Process Owner is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.organization_dependency_process(organization_id,process_name,process_owner_id,version_no,effective_dt,last_review_dt,next_review_dt,remarks,status,record_status_id,entered_by)
     VALUES(@process_org_id,@process_name,@process_owner_id,JSON_VALUE(@p_payload,'$.version'),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.lastReviewDate'),'')),TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.nextReviewDate'),'')),JSON_VALUE(@p_payload,'$.remarks'),@process_status_name,@process_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
     UPDATE grac_practice.organization_dependency_process SET organization_id=@process_org_id,process_name=@process_name,process_owner_id=@process_owner_id,
       version_no=JSON_VALUE(@p_payload,'$.version'),effective_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),'')),
       last_review_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.lastReviewDate'),'')),next_review_dt=TRY_CONVERT(DATE,NULLIF(JSON_VALUE(@p_payload,'$.nextReviewDate'),'')),
       remarks=JSON_VALUE(@p_payload,'$.remarks'),status=@process_status_name,record_status_id=@process_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE process_id=@p_id;
 END
 ELSE IF @p_entity_type='practice-dependency-resolutions'
 BEGIN
   DECLARE @resolution_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @resolution_organization_id BIGINT;
   DECLARE @resolution_dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @resolution_dependency_category NVARCHAR(120);
   DECLARE @resolution_dependency_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.resolvedDependencyId'),''));
   DECLARE @resolution_dependency_name NVARCHAR(300);
   DECLARE @resolution_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.resolutionOwnerId'),''));
   DECLARE @resolution_status_id INT=(SELECT resolution_status_id FROM grac_practice.dependency_resolution_status_master WHERE status_code='Resolved');
   DECLARE @resolution_cfg_source_table NVARCHAR(256);
   DECLARE @resolution_cfg_id_column SYSNAME;
   DECLARE @resolution_cfg_display_column SYSNAME;
   DECLARE @resolution_cfg_org_column SYSNAME;
   DECLARE @resolution_cfg_status_column SYSNAME;
   DECLARE @resolution_cfg_status_value NVARCHAR(80);
   DECLARE @resolution_cfg_schema SYSNAME;
   DECLARE @resolution_cfg_table SYSNAME;
   DECLARE @resolution_cfg_sql NVARCHAR(MAX);

   SELECT @resolution_organization_id=organization_id
   FROM grac_practice.practice_instance
   WHERE practice_instance_id=@resolution_practice_instance_id;
   IF @resolution_practice_instance_id IS NULL OR @resolution_organization_id IS NULL
     THROW 51200,'Practice Instance is required for Operationalization.',1;
   IF @is_system_admin=0 AND NOT EXISTS(SELECT 1 FROM @allowed_organizations WHERE organization_id=@resolution_organization_id)
     THROW 51052,'You do not have access to the selected organization.',1;
   IF @is_system_admin=0 AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.organization_employee owner_emp
       ON owner_emp.organization_id=pi.organization_id
      AND owner_emp.status='Active'
      AND (owner_emp.employee_id=pi.primary_owner_id OR owner_emp.employee_name=pi.primary_owner)
     WHERE pi.practice_instance_id=@resolution_practice_instance_id
       AND (owner_emp.email=@p_usr_id OR owner_emp.employee_code=@p_usr_id)
   )
   AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.organization_employee emp
     WHERE emp.organization_id=@resolution_organization_id
       AND emp.status='Active'
       AND (emp.email=@p_usr_id OR emp.employee_code=@p_usr_id)
   )
     THROW 51211,'You are not authorized to resolve this Practice Instance.',1;
   IF @resolution_dependency_type_id IS NULL
     THROW 51201,'Dependency Category is required.',1;
   IF @resolution_dependency_id IS NULL
     THROW 51202,'Resolved Dependency is required.',1;

   SELECT @resolution_dependency_category=dependency_type_name
   FROM grac_practice.dependency_type_master
   WHERE dependency_type_id=@resolution_dependency_type_id AND is_active=1;
   IF @resolution_dependency_category IS NULL
     THROW 51203,'Selected Dependency Category is not valid.',1;
   IF NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance_dependency d
     WHERE d.practice_instance_id=@resolution_practice_instance_id
       AND d.organization_id=@resolution_organization_id
       AND d.dependency_type_id=@resolution_dependency_type_id
       AND d.status='Active'
   )
     THROW 51204,'The selected dependency category is not configured for this Practice Instance.',1;

   SELECT TOP 1
     @resolution_cfg_source_table=source_table_name,
     @resolution_cfg_id_column=id_column_name,
     @resolution_cfg_display_column=display_column_name,
     @resolution_cfg_org_column=organization_filter_column,
     @resolution_cfg_status_column=status_filter_column,
     @resolution_cfg_status_value=status_active_value
   FROM grac_practice.dependency_type_source_config
   WHERE dependency_type_id=@resolution_dependency_type_id
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
   IF @resolution_cfg_source_table IS NULL
     THROW 51205,'Dependency Category source configuration is missing or inactive.',1;

   SET @resolution_cfg_schema=PARSENAME(@resolution_cfg_source_table,2);
   SET @resolution_cfg_table=PARSENAME(@resolution_cfg_source_table,1);
   IF @resolution_cfg_schema<>N'grac_practice' OR OBJECT_ID(@resolution_cfg_source_table) IS NULL
     THROW 51206,'Dependency Category source configuration is invalid.',1;

   SET @resolution_cfg_sql=N'
SELECT @resolvedName=CAST(' + QUOTENAME(@resolution_cfg_display_column) + N' AS NVARCHAR(300))
FROM ' + QUOTENAME(@resolution_cfg_schema) + N'.' + QUOTENAME(@resolution_cfg_table) + N'
WHERE ' + QUOTENAME(@resolution_cfg_id_column) + N'=@referenceId
  AND ' + QUOTENAME(@resolution_cfg_org_column) + N'=@organizationId
  AND ' + QUOTENAME(@resolution_cfg_status_column) + N'=@activeStatus;';
   EXEC sp_executesql @resolution_cfg_sql,
     N'@referenceId BIGINT,@organizationId BIGINT,@activeStatus NVARCHAR(80),@resolvedName NVARCHAR(300) OUTPUT',
     @referenceId=@resolution_dependency_id,
     @organizationId=@resolution_organization_id,
     @activeStatus=@resolution_cfg_status_value,
     @resolvedName=@resolution_dependency_name OUTPUT;
   IF @resolution_dependency_name IS NULL
     THROW 51207,'Selected dependency object is not active or does not belong to this organization.',1;
   IF @resolution_owner_id IS NOT NULL AND NOT EXISTS(
     SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@resolution_owner_id AND organization_id=@resolution_organization_id AND status='Active'
   )
     THROW 51208,'Selected Resolution Owner is not valid for this organization.',1;
   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=resolution_id
     FROM grac_practice.practice_dependency_resolution
     WHERE organization_id=@resolution_organization_id
       AND practice_instance_id=@resolution_practice_instance_id
       AND dependency_type_id=@resolution_dependency_type_id
       AND resolved_dependency_id=@resolution_dependency_id;

     IF @new_id IS NULL
     BEGIN
       INSERT grac_practice.practice_dependency_resolution(
         organization_id,practice_instance_id,dependency_type_id,dependency_category,resolved_dependency_id,resolved_dependency_name,
         resolution_status_id,resolution_status,resolution_owner_id,resolution_dt,remarks,is_active,record_status_id,entered_by)
       VALUES(@resolution_organization_id,@resolution_practice_instance_id,@resolution_dependency_type_id,@resolution_dependency_category,@resolution_dependency_id,@resolution_dependency_name,
         @resolution_status_id,N'Resolved',@resolution_owner_id,SYSUTCDATETIME(),JSON_VALUE(@p_payload,'$.remarks'),1,@active_record_status_id,@p_usr_id);
       SET @new_id=SCOPE_IDENTITY();
     END
     ELSE
       UPDATE grac_practice.practice_dependency_resolution
       SET resolved_dependency_name=@resolution_dependency_name,
           resolution_status_id=@resolution_status_id,
           resolution_status=N'Resolved',
           resolution_owner_id=@resolution_owner_id,
           resolution_dt=SYSUTCDATETIME(),
           remarks=JSON_VALUE(@p_payload,'$.remarks'),
           is_active=1,
           record_status_id=@active_record_status_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
       WHERE resolution_id=@new_id;
   END
   ELSE
   BEGIN
     SET @new_id=@p_id;
     UPDATE grac_practice.practice_dependency_resolution
     SET dependency_type_id=@resolution_dependency_type_id,
         dependency_category=@resolution_dependency_category,
         resolved_dependency_id=@resolution_dependency_id,
         resolved_dependency_name=@resolution_dependency_name,
         resolution_status_id=@resolution_status_id,
         resolution_status=N'Resolved',
         resolution_owner_id=@resolution_owner_id,
         resolution_dt=SYSUTCDATETIME(),
         remarks=JSON_VALUE(@p_payload,'$.remarks'),
         is_active=1,
         record_status_id=@active_record_status_id,
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
     WHERE resolution_id=@p_id
       AND organization_id=@resolution_organization_id
       AND practice_instance_id=@resolution_practice_instance_id;
     IF @@ROWCOUNT=0 THROW 51209,'Selected dependency resolution was not found.',1;
   END
 END
 ELSE IF @p_entity_type='repository-subscriptions'
 BEGIN
   IF @p_id=0 BEGIN
     INSERT grac_practice.repository_subscription(organization_id,authority_id,artifact_id,release_id,subscription_type,subscription_status,subscription_status_id,effective_dt,end_dt,status,record_status_id,entered_by)
     VALUES(JSON_VALUE(@p_payload,'$.organizationId'),NULLIF(JSON_VALUE(@p_payload,'$.authorityId'),''),NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),COALESCE(JSON_VALUE(@p_payload,'$.subscriptionType'),'Manual'),COALESCE(JSON_VALUE(@p_payload,'$.subscriptionStatus'),'Active'),COALESCE(@payload_subscription_status_id,@active_subscription_status_id),NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.repository_subscription SET organization_id=JSON_VALUE(@p_payload,'$.organizationId'),authority_id=NULLIF(JSON_VALUE(@p_payload,'$.authorityId'),''),artifact_id=NULLIF(JSON_VALUE(@p_payload,'$.artifactId'),''),release_id=NULLIF(JSON_VALUE(@p_payload,'$.releaseId'),''),subscription_type=COALESCE(JSON_VALUE(@p_payload,'$.subscriptionType'),subscription_type),subscription_status=COALESCE(JSON_VALUE(@p_payload,'$.subscriptionStatus'),subscription_status),subscription_status_id=COALESCE(@payload_subscription_status_id,subscription_status_id),effective_dt=NULLIF(JSON_VALUE(@p_payload,'$.effectiveDate'),''),end_dt=NULLIF(JSON_VALUE(@p_payload,'$.endDate'),''),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE subscription_id=@p_id;

   DECLARE @single_org_id BIGINT,@single_release_id BIGINT,@single_artifact_id BIGINT,@single_subscription_status NVARCHAR(40),@single_status NVARCHAR(30);
   SELECT @single_org_id=organization_id,@single_release_id=release_id,@single_artifact_id=artifact_id,@single_subscription_status=subscription_status,@single_status=status
   FROM grac_practice.repository_subscription WHERE subscription_id=@new_id;

   IF @single_status='Active' AND @single_subscription_status='Active' AND @single_release_id IS NOT NULL
   BEGIN
     ;WITH repository_controls AS (
       SELECT DISTINCT
         scm.control_id,
         c.control_code,
         c.control_name,
         c.description,
         c.objective,
         c.control_domain_id,
         c.control_sub_domain_id,
         COALESCE(scm.release_id,n.release_id) release_id,
         COALESCE(scm.artifact_id,r.artifact_id,@single_artifact_id) artifact_id,
         @new_id subscription_id
       FROM grac_new.source_control_map scm
       JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
       JOIN grac_new.release r ON r.release_id=n.release_id
       JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
       WHERE scm.status='Active' AND n.status='Active' AND COALESCE(scm.release_id,n.release_id)=@single_release_id
     )
     UPDATE oc SET
       control_code=rc.control_code,control_name=rc.control_name,description=rc.description,objective=rc.objective,
       control_domain_id=rc.control_domain_id,control_sub_domain_id=rc.control_sub_domain_id,
       subscription_id=rc.subscription_id,artifact_id=rc.artifact_id,status='Active',record_status_id=@active_record_status_id,
       origin_type=CASE WHEN oc.origin_type='Hybrid' THEN 'Hybrid' ELSE 'Repository' END,
       is_manually_added=0,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     JOIN repository_controls rc ON rc.control_id=oc.repository_control_id AND rc.release_id=oc.release_id
     WHERE oc.organization_id=@single_org_id;

     ;WITH repository_controls AS (
       SELECT DISTINCT
         scm.control_id,c.control_code,c.control_name,c.description,c.objective,c.control_domain_id,c.control_sub_domain_id,
         COALESCE(scm.release_id,n.release_id) release_id,COALESCE(scm.artifact_id,r.artifact_id,@single_artifact_id) artifact_id,@new_id subscription_id
       FROM grac_new.source_control_map scm
       JOIN grac_new.source_structure_node n ON n.structure_node_id=scm.structure_node_id
       JOIN grac_new.release r ON r.release_id=n.release_id
       JOIN grac_new.control c ON c.control_id=scm.control_id AND c.status='Active'
       WHERE scm.status='Active' AND n.status='Active' AND COALESCE(scm.release_id,n.release_id)=@single_release_id
     )
     INSERT grac_practice.organization_control(
       organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,control_domain_id,control_sub_domain_id,
       is_manually_added,subscription_id,release_id,artifact_id,applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
     SELECT @single_org_id,'Repository',rc.control_id,rc.control_code,rc.control_name,rc.description,rc.objective,rc.control_domain_id,rc.control_sub_domain_id,
       0,rc.subscription_id,rc.release_id,rc.artifact_id,'Not Updated',@not_updated_applicability_status_id,'Medium','Active',@active_record_status_id,@p_usr_id
     FROM repository_controls rc
     WHERE NOT EXISTS(
       SELECT 1 FROM grac_practice.organization_control oc
       WHERE oc.organization_id=@single_org_id AND oc.repository_control_id=rc.control_id AND oc.release_id=rc.release_id
     );
   END
   ELSE
   BEGIN
     UPDATE oc SET status='Inactive',record_status_id=@inactive_record_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     FROM grac_practice.organization_control oc
     WHERE oc.organization_id=@single_org_id AND oc.release_id=@single_release_id AND oc.is_manually_added=0;
   END
 END
 ELSE IF @p_entity_type='organization-controls'
  BEGIN
    DECLARE @org_control_applicability_status NVARCHAR(40)=CASE WHEN @p_id=0 THEN COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),N'Not Updated') ELSE COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),N'Applicable') END;
    DECLARE @org_control_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code=@org_control_applicability_status OR status_name=@org_control_applicability_status);
    DECLARE @org_control_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
    DECLARE @org_control_primary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.primaryOwner'))),'');
    DECLARE @org_control_secondary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.secondaryOwner'))),'');
    DECLARE @org_control_business_function_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''));
    DECLARE @org_control_criticality NVARCHAR(30)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');

    IF @org_control_applicability_status IN (N'Not Applicable',N'Deferred',N'Not Implemented',N'Retired') AND @org_control_justification IS NULL
       THROW 51024,'Justification is required when control applicability is Not Applicable, Deferred, Not Implemented, or Retired.',1;
    IF @org_control_applicability_status=N'Applicable' AND (@org_control_primary_owner IS NULL OR @org_control_business_function_id IS NULL OR @org_control_criticality IS NULL)
       THROW 51025,'Primary Owner, Business Function, and Criticality are required when control applicability is Applicable.',1;

    IF @p_id=0 BEGIN
      INSERT grac_practice.organization_control(organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,business_justification,is_manually_added,applicability_status,applicability_status_id,exclusion_justification,primary_owner,secondary_owner,backup_owner,business_function_id,criticality,status,record_status_id,entered_by)
      VALUES(JSON_VALUE(@p_payload,'$.organizationId'),'Organization',NULL,JSON_VALUE(@p_payload,'$.code'),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),JSON_VALUE(@p_payload,'$.objective'),JSON_VALUE(@p_payload,'$.businessJustification'),1,@org_control_applicability_status,COALESCE(@org_control_applicability_status_id,@not_updated_applicability_status_id),NULL,@org_control_primary_owner,@org_control_secondary_owner,JSON_VALUE(@p_payload,'$.backupOwner'),@org_control_business_function_id,@org_control_criticality,'Active',@active_record_status_id,@p_usr_id);
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE grac_practice.organization_control SET
      organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),
      origin_type=CASE WHEN is_manually_added=1 THEN 'Organization' ELSE origin_type END,
      repository_control_id=CASE WHEN is_manually_added=1 THEN NULL ELSE repository_control_id END,
      control_code=CASE WHEN is_manually_added=1 THEN COALESCE(JSON_VALUE(@p_payload,'$.code'),control_code) ELSE control_code END,
      control_name=CASE WHEN is_manually_added=1 THEN COALESCE(JSON_VALUE(@p_payload,'$.name'),control_name) ELSE control_name END,
      description=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.description') ELSE description END,
      objective=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.objective') ELSE objective END,
      business_justification=CASE WHEN is_manually_added=1 THEN JSON_VALUE(@p_payload,'$.businessJustification') ELSE business_justification END,
      applicability_status=@org_control_applicability_status,
      applicability_status_id=COALESCE(@org_control_applicability_status_id,applicability_status_id),
      exclusion_justification=CASE WHEN @org_control_applicability_status=N'Applicable' THEN NULL ELSE @org_control_justification END,
      primary_owner=@org_control_primary_owner,
      secondary_owner=@org_control_secondary_owner,
      backup_owner=JSON_VALUE(@p_payload,'$.backupOwner'),
      business_function_id=@org_control_business_function_id,
      criticality=COALESCE(@org_control_criticality,criticality),
      status='Active',
      record_status_id=@active_record_status_id,
      updated_by=@p_usr_id,
      updated_dt=SYSUTCDATETIME()
    WHERE organization_control_id=@p_id;
  END
 ELSE IF @p_entity_type='control-applicability'
 BEGIN
  DECLARE @control_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Applicable');
  DECLARE @control_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
  DECLARE @control_primary_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.primaryOwner'))),'');
  DECLARE @control_criticality NVARCHAR(30)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');
  IF @p_id=0 THROW 51020,'Select an organization control before saving applicability.',1;
  IF @control_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @control_justification IS NULL
     THROW 51021,'Justification is required when control applicability is Not Applicable, Deferred, or Accepted Risk.',1;
  IF @control_applicability_status='Applicable' AND (@control_primary_owner IS NULL OR @control_criticality IS NULL)
     THROW 51023,'Primary Owner and Criticality are required when control applicability is Applicable.',1;

  UPDATE grac_practice.organization_control SET
     applicability_status=@control_applicability_status,
     applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),
     exclusion_justification=CASE WHEN @control_applicability_status='Applicable' THEN NULL ELSE @control_justification END,
     primary_owner=@control_primary_owner,
     secondary_owner=NULLIF(JSON_VALUE(@p_payload,'$.secondaryOwner'),''),
     business_function_id=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),'')),
     criticality=COALESCE(@control_criticality,criticality),
     status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),status),
     record_status_id=COALESCE(@payload_record_status_id,record_status_id),
     updated_by=@p_usr_id,
     updated_dt=SYSUTCDATETIME()
  WHERE organization_control_id=@p_id;
  IF @@ROWCOUNT=0 THROW 51022,'Selected organization control was not found.',1;

  -- ------------------------------------------------------------------
  -- Practice import + cleanup delegated to the helpers created by
  -- migration 057 (grac_practice.sp_apply_practices_for_control /
  -- sp_unapply_practices_for_control). Those SPs:
  --   * Dedup practices by (organization_id, repository_requirement_id)
  --     across Controls -- no duplicate Practice rows when the same
  --     ISO practice is mapped to multiple applicable Controls.
  --   * Maintain the many-to-many mapping in
  --     grac_practice.organization_control_requirement so the app can
  --     see every Control that a Practice belongs to.
  --   * On Not Applicable / Deferred / Retired: soft-inactivate only
  --     THIS control's mapping rows; the Practice itself only gets
  --     soft-inactivated when no active mapping remains.
  -- The 'primary' organization_control_id column on organization_requirement
  -- stays populated for back-compat with the ~89 existing SP/view callers.
  -- ------------------------------------------------------------------
  IF @control_applicability_status='Applicable'
  BEGIN
    DECLARE @mapped_requirements INT=0;
    DECLARE @imported_requirements INT=0;
    EXEC grac_practice.sp_apply_practices_for_control
      @organization_control_id = @p_id,
      @actor                   = @p_usr_id,
      @mapped_count            = @mapped_requirements OUTPUT,
      @imported_count          = @imported_requirements OUTPUT;

    IF @mapped_requirements=0
      SET @result_message=N'Control applicability saved. No requirements are mapped to this control in the repository.';
    ELSE IF @imported_requirements=0
      SET @result_message=N'Control applicability saved. Requirements mapped to this control were already imported.';
    ELSE
      SET @result_message=CONCAT(N'Control applicability saved. ',@imported_requirements,N' practice(s) imported into Organization Practices.');
  END
  ELSE IF @control_applicability_status IN ('Not Applicable','Deferred','Retired','Accepted Risk')
  BEGIN
    DECLARE @unmapped_requirements INT=0;
    EXEC grac_practice.sp_unapply_practices_for_control
      @organization_control_id = @p_id,
      @actor                   = @p_usr_id,
      @deactivated_count       = @unmapped_requirements OUTPUT;

    IF @unmapped_requirements=0
      SET @result_message=N'Control applicability saved.';
    ELSE
      SET @result_message=CONCAT(N'Control applicability saved. ',@unmapped_requirements,N' practice mapping(s) deactivated for this control.');
  END
 END
 ELSE IF @p_entity_type='organization-requirements'
 BEGIN
   DECLARE @org_requirement_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Not Updated');
   DECLARE @org_requirement_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
   DECLARE @org_requirement_practice_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceOwnerId'),''));
   DECLARE @org_requirement_practice_owner NVARCHAR(200)=NULL;
   DECLARE @org_requirement_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @org_requirement_control_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationControlId'),''));
   -- Custom Practice Code Auto Generation (change request): true "custom
   -- practice" creation on this branch is exactly the condition already used
   -- below to auto-parent the row under the ORG-PRACTICES container -- a
   -- brand-new row (@p_id=0), no organization control chosen, origin
   -- 'Organization'. Pulled into its own flag so the code-generation block
   -- can reuse it without duplicating the condition.
   DECLARE @org_requirement_is_custom_create BIT=CASE WHEN @p_id=0 AND @org_requirement_control_id IS NULL AND COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization')='Organization' THEN 1 ELSE 0 END;
   DECLARE @org_requirement_generated_code NVARCHAR(50)=NULL;
   IF @org_requirement_org_id IS NULL THROW 51035,'Organization is required.',1;
   IF @org_requirement_is_custom_create=1
   BEGIN
     SELECT TOP (1) @org_requirement_control_id=organization_control_id
     FROM grac_practice.organization_control
     WHERE organization_id=@org_requirement_org_id
       AND origin_type='Organization'
       AND control_code='ORG-PRACTICES'
       AND status='Active'
     ORDER BY organization_control_id;

     IF @org_requirement_control_id IS NULL
     BEGIN
       INSERT grac_practice.organization_control(
         organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,is_manually_added,
         applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
       VALUES(
         @org_requirement_org_id,'Organization',NULL,'ORG-PRACTICES','Organization Defined Practices',
         'System container for manually added organization practices.','Manual practices created by the organization.',1,
         'Applicable',COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         'Medium','Active',@active_record_status_id,@p_usr_id);
       SET @org_requirement_control_id=SCOPE_IDENTITY();
     END

     -- Auto-generate the Practice Code (PR_001, PR_002, ...). Never taken
     -- from the payload for this path (requirement 6, "no manual
     -- override") -- see the requirement_code column of the INSERT below.
     -- sp_getapplock serializes this against every other custom-practice
     -- create (this branch and the practices branch both use the same
     -- resource name) so two concurrent creates cannot compute the same
     -- next number (requirement 10). @LockOwner='Transaction' auto-releases
     -- at this procedure's COMMIT/ROLLBACK (BEGIN TRAN / SET XACT_ABORT ON
     -- at the top of this procedure cover the whole body, confirmed down to
     -- the COMMIT right before the final SELECT).
     DECLARE @org_requirement_lock_result INT;
     EXEC @org_requirement_lock_result=sp_getapplock @Resource='pm_custom_practice_code_seq',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=15000;
     IF @org_requirement_lock_result<0 THROW 51210,'Unable to generate Practice Code right now. Please try again.',1;

     DECLARE @org_requirement_next_seq INT;
     SELECT @org_requirement_next_seq=ISNULL(MAX(seq),0)+1
     FROM (
       SELECT TRY_CONVERT(INT,SUBSTRING(requirement_code,4,50)) seq FROM grac_practice.organization_requirement WHERE requirement_code LIKE 'PR[_]%'
       UNION ALL
       SELECT TRY_CONVERT(INT,SUBSTRING(practice_code,4,50)) seq FROM grac_practice.practice WHERE practice_code LIKE 'PR[_]%'
     ) existing_codes
     WHERE seq IS NOT NULL;

     -- Zero-pad to 3 digits (PR_001 .. PR_999); beyond that, grow the number
     -- naturally instead of truncating it (RIGHT('000'+CAST(1000...),3)
     -- would otherwise cut a 4-digit number back down to 3 digits).
     SET @org_requirement_generated_code='PR_'+CASE WHEN @org_requirement_next_seq<1000 THEN RIGHT('000'+CAST(@org_requirement_next_seq AS VARCHAR(10)),3) ELSE CAST(@org_requirement_next_seq AS VARCHAR(10)) END;
   END
   IF @org_requirement_practice_owner_id IS NOT NULL
   BEGIN
     IF NOT EXISTS(
       SELECT 1
       FROM grac_practice.organization_employee
       WHERE employee_id=@org_requirement_practice_owner_id
         AND status='Active'
         AND (@org_requirement_org_id IS NULL OR organization_id=@org_requirement_org_id)
     )
       THROW 51033,'Selected Owner is not valid for this organization.',1;

     SELECT @org_requirement_practice_owner=employee_name
     FROM grac_practice.organization_employee
     WHERE employee_id=@org_requirement_practice_owner_id;
   END
   IF @org_requirement_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @org_requirement_justification IS NULL
     THROW 51032,'Reason / Justification is required when applicability is Not Applicable, Deferred, or Accepted Risk.',1;
   IF @org_requirement_applicability_status='Applicable' AND @org_requirement_practice_owner_id IS NULL
     THROW 51034,'Owner is required when practice is Applicable.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.organization_requirement(organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,requirement_statement,objective,applicability_status,applicability_status_id,exclusion_justification,implementation_status,implementation_status_id,status,record_status_id,entered_by)
     VALUES(@org_requirement_org_id,COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization'),NULLIF(JSON_VALUE(@p_payload,'$.repositoryRequirementId'),''),@org_requirement_control_id,COALESCE(@org_requirement_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.statement'),JSON_VALUE(@p_payload,'$.objective'),@org_requirement_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),@org_requirement_justification,COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),'Not Started'),COALESCE(@payload_implementation_status_id,@not_started_implementation_status_id),COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.organization_requirement
     SET organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),
         origin_type=COALESCE(JSON_VALUE(@p_payload,'$.originType'),origin_type),
         repository_requirement_id=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.repositoryRequirementId'),''),repository_requirement_id),
         organization_control_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationControlId'),organization_control_id),
         requirement_code=COALESCE(JSON_VALUE(@p_payload,'$.code'),requirement_code),
         requirement_name=COALESCE(JSON_VALUE(@p_payload,'$.name'),requirement_name),
         requirement_statement=COALESCE(JSON_VALUE(@p_payload,'$.statement'),requirement_statement),
         objective=COALESCE(JSON_VALUE(@p_payload,'$.objective'),objective),
         applicability_status=COALESCE(JSON_VALUE(@p_payload,'$.applicabilityStatus'),applicability_status),
         applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),
         exclusion_justification=COALESCE(@org_requirement_justification,exclusion_justification),
         implementation_status=COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),implementation_status),
         implementation_status_id=COALESCE(@payload_implementation_status_id,implementation_status_id),
         status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),
         record_status_id=COALESCE(@payload_record_status_id,record_status_id),
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
     WHERE organization_requirement_id=@p_id;

   DECLARE @saved_org_requirement_id BIGINT=CASE WHEN @p_id=0 THEN @new_id ELSE @p_id END;
   IF @saved_org_requirement_id IS NOT NULL AND @saved_org_requirement_id>0
   BEGIN
     UPDATE p
       SET practice_owner_id=@org_requirement_practice_owner_id,
           practice_owner=@org_requirement_practice_owner,
           applicability_status=@org_requirement_applicability_status,
           applicability_status_id=COALESCE(@payload_applicability_status_id,p.applicability_status_id),
           exclusion_justification=COALESCE(@org_requirement_justification,p.exclusion_justification),
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     WHERE p.organization_requirement_id=@saved_org_requirement_id;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner_id,practice_owner,
       applicability_status,applicability_status_id,exclusion_justification,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,
       @org_requirement_practice_owner_id,@org_requirement_practice_owner,
       @org_requirement_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),
       COALESCE(@org_requirement_justification,q.exclusion_justification),
       'Active',COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@saved_org_requirement_id
       AND NOT EXISTS(
         SELECT 1
         FROM grac_practice.practice p
         WHERE p.organization_id=q.organization_id
           AND p.organization_requirement_id=q.organization_requirement_id
       );

     -- Source Statement mapping (change request, 2026-09): the Add/Edit
     -- Practice form on Organization Requirements lets the user pick which
     -- subscribed-release Source Statements this practice maps to. The
     -- picker submits the FULL desired set as mappedOrgStatementIds (an
     -- array of organization_framework_statements.org_statement_id values)
     -- and this block reconciles organization_statement_practice_mapping
     -- to match it exactly -- insert/reactivate what's newly selected,
     -- deactivate what was dropped. Gated on the key actually being present
     -- in the payload (JSON_QUERY returns NULL both when the key is absent
     -- and when its value is JSON null, but returns '[]' for an empty
     -- array) so callers that don't send this field -- Update Applicability,
     -- quick edits, any other save that reuses this same branch -- leave
     -- existing mappings untouched instead of wiping them out.
     IF JSON_QUERY(@p_payload,'$.mappedOrgStatementIds') IS NOT NULL
     BEGIN
       DECLARE @mapped_statement_ids TABLE(org_statement_id BIGINT PRIMARY KEY);
       INSERT @mapped_statement_ids(org_statement_id)
       SELECT DISTINCT v.org_statement_id
       FROM (
         SELECT TRY_CONVERT(BIGINT,[value]) org_statement_id
         FROM OPENJSON(@p_payload,'$.mappedOrgStatementIds')
       ) v
       -- Only statements that actually belong to this organization can be
       -- mapped -- silently drops anything forged/stale rather than
       -- throwing, since the picker itself only ever offers this org's own
       -- subscribed-release statements.
       WHERE v.org_statement_id IS NOT NULL
         AND EXISTS(
           SELECT 1 FROM grac_practice.organization_framework_statements ofs
           WHERE ofs.org_statement_id=v.org_statement_id
             AND ofs.organization_id=@org_requirement_org_id
         );

       DECLARE @mapping_repository_requirement_id BIGINT=(SELECT repository_requirement_id FROM grac_practice.organization_requirement WHERE organization_requirement_id=@saved_org_requirement_id);

       -- Reactivate/insert every currently-selected statement.
       MERGE grac_practice.organization_statement_practice_mapping AS target
       USING (
         SELECT m.org_statement_id,ofs.organization_id,ofs.release_id,ofs.framework_statement_id
         FROM @mapped_statement_ids m
         JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=m.org_statement_id
       ) AS src
         ON target.organization_id=src.organization_id
        AND target.org_statement_id=src.org_statement_id
        AND target.org_practice_id=@saved_org_requirement_id
       WHEN MATCHED AND target.status<>'Active' THEN UPDATE SET
         status='Active',
         record_status_id=@active_record_status_id,
         framework_statement_id=src.framework_statement_id,
         release_id=src.release_id,
         updated_by=@p_usr_id,
         updated_dt=SYSUTCDATETIME()
       WHEN NOT MATCHED BY TARGET THEN INSERT(
         organization_id,org_statement_id,framework_statement_id,repository_requirement_id,org_practice_id,release_id,status,record_status_id,entered_by)
       VALUES(
         src.organization_id,src.org_statement_id,src.framework_statement_id,@mapping_repository_requirement_id,@saved_org_requirement_id,src.release_id,'Active',@active_record_status_id,@p_usr_id);

       -- Deactivate mappings for this practice that are no longer selected.
       UPDATE grac_practice.organization_statement_practice_mapping
         SET status='Inactive',
             record_status_id=@inactive_record_status_id,
             updated_by=@p_usr_id,
             updated_dt=SYSUTCDATETIME()
       WHERE org_practice_id=@saved_org_requirement_id
         AND status='Active'
         AND org_statement_id NOT IN (SELECT org_statement_id FROM @mapped_statement_ids);
     END
   END
 END
 ELSE IF @p_entity_type='practices'
 BEGIN
   DECLARE @practice_applicability_status NVARCHAR(40)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.applicabilityStatus'),''),'Not Updated');
   DECLARE @practice_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceOwnerId'),''));
   DECLARE @practice_owner NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.practiceOwner'))),'');
   DECLARE @practice_justification NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.exclusionJustification'))),'');
   DECLARE @practice_organization_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @practice_organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationRequirementId'),''));
   DECLARE @practice_origin_type NVARCHAR(30)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.originType'),''),'Organization');
   -- Custom Practice Code Auto Generation (change request): same condition
   -- already used below to auto-create the linked organization_requirement
   -- container row -- a brand-new practice (@p_id=0), not linked to an
   -- existing organization requirement, origin 'Organization'.
   DECLARE @practice_is_custom_create BIT=CASE WHEN @p_id=0 AND @practice_organization_requirement_id IS NULL AND @practice_origin_type='Organization' THEN 1 ELSE 0 END;
   DECLARE @practice_generated_code NVARCHAR(50)=NULL;
   IF @practice_organization_id IS NULL THROW 51028,'Organization is required.',1;
   IF @practice_is_custom_create=1
   BEGIN
     -- Same generation as the organization-requirements branch, sharing the
     -- same sp_getapplock resource name so a custom create on either screen
     -- serializes against the other and neither can land on the same
     -- PR_NNN code (requirement 10). See that branch for the full
     -- explanation of the lock and the padding formula.
     DECLARE @practice_lock_result INT;
     EXEC @practice_lock_result=sp_getapplock @Resource='pm_custom_practice_code_seq',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=15000;
     IF @practice_lock_result<0 THROW 51212,'Unable to generate Practice Code right now. Please try again.',1;

     DECLARE @practice_next_seq INT;
     SELECT @practice_next_seq=ISNULL(MAX(seq),0)+1
     FROM (
       SELECT TRY_CONVERT(INT,SUBSTRING(requirement_code,4,50)) seq FROM grac_practice.organization_requirement WHERE requirement_code LIKE 'PR[_]%'
       UNION ALL
       SELECT TRY_CONVERT(INT,SUBSTRING(practice_code,4,50)) seq FROM grac_practice.practice WHERE practice_code LIKE 'PR[_]%'
     ) existing_codes
     WHERE seq IS NOT NULL;

     SET @practice_generated_code='PR_'+CASE WHEN @practice_next_seq<1000 THEN RIGHT('000'+CAST(@practice_next_seq AS VARCHAR(10)),3) ELSE CAST(@practice_next_seq AS VARCHAR(10)) END;

     DECLARE @practice_container_control_id BIGINT=NULL;
     SELECT TOP (1) @practice_container_control_id=organization_control_id
     FROM grac_practice.organization_control
     WHERE organization_id=@practice_organization_id
       AND origin_type='Organization'
       AND control_code='ORG-PRACTICES'
       AND status='Active'
     ORDER BY organization_control_id;

     IF @practice_container_control_id IS NULL
     BEGIN
       INSERT grac_practice.organization_control(
         organization_id,origin_type,repository_control_id,control_code,control_name,description,objective,is_manually_added,
         applicability_status,applicability_status_id,criticality,status,record_status_id,entered_by)
       VALUES(
         @practice_organization_id,'Organization',NULL,'ORG-PRACTICES','Organization Defined Practices',
         'System container for manually added organization practices.','Manual practices created by the organization.',1,
         'Applicable',COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         'Medium','Active',@active_record_status_id,@p_usr_id);
       SET @practice_container_control_id=SCOPE_IDENTITY();
     END

     SELECT TOP (1) @practice_organization_requirement_id=organization_requirement_id
     FROM grac_practice.organization_requirement
     WHERE organization_id=@practice_organization_id
       AND organization_control_id=@practice_container_control_id
       AND requirement_code=COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code'))
       AND status='Active'
     ORDER BY organization_requirement_id;

     IF @practice_organization_requirement_id IS NULL
     BEGIN
       INSERT grac_practice.organization_requirement(
         organization_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
         requirement_statement,objective,applicability_status,applicability_status_id,exclusion_justification,
         implementation_status,implementation_status_id,status,record_status_id,entered_by)
       VALUES(
         @practice_organization_id,'Organization',NULL,@practice_container_control_id,COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),
         JSON_VALUE(@p_payload,'$.description'),NULL,'Applicable',
         COALESCE((SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),@not_updated_applicability_status_id),
         NULL,'Not Started',@not_started_implementation_status_id,'Active',@active_record_status_id,@p_usr_id);
       SET @practice_organization_requirement_id=SCOPE_IDENTITY();
     END
   END
   IF @practice_owner_id IS NOT NULL
   BEGIN
     IF NOT EXISTS(
       SELECT 1
       FROM grac_practice.organization_employee
       WHERE employee_id=@practice_owner_id
         AND status='Active'
         AND (@practice_organization_id IS NULL OR organization_id=@practice_organization_id)
     )
       THROW 51027,'Selected Owner is not valid for this organization.',1;

     SELECT @practice_owner=employee_name
     FROM grac_practice.organization_employee
     WHERE employee_id=@practice_owner_id;
   END
   IF @practice_applicability_status IN ('Not Applicable','Deferred','Accepted Risk') AND @practice_justification IS NULL
     THROW 51025,'Reason / Justification is required when practice applicability is Not Applicable, Deferred, or Accepted Risk.',1;
   IF @practice_applicability_status='Applicable' AND @practice_owner_id IS NULL
     THROW 51026,'Owner is required when practice is Applicable.',1;
   IF @p_id=0 AND @practice_organization_requirement_id IS NULL
     THROW 51029,'Organization Requirement is required for repository-linked practices.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.practice(organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner_id,practice_owner,applicability_status,applicability_status_id,exclusion_justification,status,record_status_id,entered_by)
     VALUES(@practice_organization_id,@practice_organization_requirement_id,@practice_origin_type,COALESCE(@practice_generated_code,JSON_VALUE(@p_payload,'$.code')),JSON_VALUE(@p_payload,'$.name'),JSON_VALUE(@p_payload,'$.description'),@practice_owner_id,@practice_owner,@practice_applicability_status,COALESCE(@payload_applicability_status_id,@not_updated_applicability_status_id),@practice_justification,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),COALESCE(@payload_record_status_id,@active_record_status_id),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.practice SET organization_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationId'),organization_id),organization_requirement_id=COALESCE(JSON_VALUE(@p_payload,'$.organizationRequirementId'),organization_requirement_id),origin_type=COALESCE(JSON_VALUE(@p_payload,'$.originType'),origin_type),practice_code=COALESCE(JSON_VALUE(@p_payload,'$.code'),practice_code),practice_name=COALESCE(JSON_VALUE(@p_payload,'$.name'),practice_name),description=COALESCE(JSON_VALUE(@p_payload,'$.description'),description),practice_owner_id=@practice_owner_id,practice_owner=@practice_owner,applicability_status=@practice_applicability_status,applicability_status_id=COALESCE(@payload_applicability_status_id,applicability_status_id),exclusion_justification=COALESCE(@practice_justification,exclusion_justification),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_id=@p_id;
 END
 ELSE IF @p_entity_type='practice-instances'
 BEGIN
   DECLARE @instance_practice_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceId'),''));
   DECLARE @instance_organization_requirement_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationRequirementId'),''));

   IF @instance_practice_id IS NULL AND @instance_organization_requirement_id IS NOT NULL
   BEGIN
     UPDATE p
       SET organization_requirement_id=q.organization_requirement_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
     FROM grac_practice.practice p
     JOIN grac_practice.organization_requirement q
       ON q.organization_requirement_id=@instance_organization_requirement_id
      AND q.organization_id=p.organization_id
      AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
     WHERE p.organization_requirement_id IS NULL;

     INSERT grac_practice.practice(
       organization_id,organization_requirement_id,origin_type,practice_code,practice_name,description,practice_owner,
       applicability_status,applicability_status_id,status,record_status_id,entered_by)
     SELECT q.organization_id,q.organization_requirement_id,q.origin_type,q.requirement_code,q.requirement_name,q.requirement_statement,NULL,
       'Applicable',(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Applicable'),'Active',@active_record_status_id,@p_usr_id
     FROM grac_practice.organization_requirement q
     WHERE q.organization_requirement_id=@instance_organization_requirement_id
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

     SELECT @instance_practice_id=p.practice_id
     FROM grac_practice.practice p
     WHERE p.organization_requirement_id=@instance_organization_requirement_id
       AND p.organization_id=JSON_VALUE(@p_payload,'$.organizationId');
   END;

   IF @instance_practice_id IS NULL
     THROW 51031,'Practice context is required to save a Practice Instance.',1;

   DECLARE @instance_primary_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.primaryOwnerId'),''));
   DECLARE @instance_primary_owner_name NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.primaryOwner'),'');
   DECLARE @instance_department_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.departmentId'),''));
   DECLARE @instance_department_name NVARCHAR(200)=NULLIF(JSON_VALUE(@p_payload,'$.department'),'');
   DECLARE @instance_execution_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.executionFrequencyId'),''));
   DECLARE @instance_assurance_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceFrequencyId'),''));
   DECLARE @instance_frequency_id INT=COALESCE(@instance_execution_frequency_id,TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyId'),'')));
   DECLARE @instance_frequency_type NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyType'),'');
   DECLARE @instance_frequency_value INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyValue'),''));
   DECLARE @instance_frequency_unit NVARCHAR(40)=NULLIF(JSON_VALUE(@p_payload,'$.frequencyUnit'),'');
   DECLARE @instance_frequency_is_custom BIT=0;
   IF @instance_primary_owner_id IS NOT NULL
   BEGIN
     SELECT
       @instance_primary_owner_name=e.employee_name,
       @instance_department_id=COALESCE(@instance_department_id,e.department_id),
       @instance_department_name=COALESCE(d.department_name,e.department,@instance_department_name)
     FROM grac_practice.organization_employee e
     LEFT JOIN grac_practice.organization_department d ON d.department_id=e.department_id
     WHERE e.employee_id=@instance_primary_owner_id
       AND e.organization_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId'))
       AND e.status='Active';
     IF @instance_primary_owner_name IS NULL
       THROW 51036,'Selected Instance Owner is not valid for this organization.',1;
   END
   IF @instance_department_id IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_department WHERE department_id=@instance_department_id AND organization_id=TRY_CONVERT(BIGINT,JSON_VALUE(@p_payload,'$.organizationId')) AND status='Active')
     THROW 51037,'Selected owner Department is not valid for this organization.',1;

   IF @instance_execution_frequency_id IS NULL
     THROW 51038,'Execution Frequency is required.',1;
   IF @instance_assurance_frequency_id IS NULL
     THROW 51039,'Assurance Frequency is required.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_execution_frequency_id AND is_active=1)
     THROW 51040,'Selected Execution Frequency is not valid.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_assurance_frequency_id AND is_active=1)
     THROW 51041,'Selected Assurance Frequency is not valid.',1;

   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL
     SELECT @instance_frequency_id=frequency_id
     FROM grac_practice.frequency_master
     WHERE frequency_code=@instance_frequency_type OR frequency_name=@instance_frequency_type;
   IF @instance_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@instance_frequency_id AND is_active=1)
     THROW 51034,'Selected Frequency is not valid.',1;
   SELECT @instance_frequency_type=frequency_code,
          @instance_frequency_is_custom=is_custom,
          @instance_frequency_value=CASE WHEN is_custom=1 THEN @instance_frequency_value ELSE frequency_value END,
          @instance_frequency_unit=CASE WHEN is_custom=1 THEN @instance_frequency_unit ELSE frequency_unit END
   FROM grac_practice.frequency_master
   WHERE frequency_id=@instance_frequency_id;
   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL AND @instance_frequency_type='Custom'
     SET @instance_frequency_is_custom=1;
   IF @instance_frequency_id IS NULL AND @instance_frequency_type IS NOT NULL AND @instance_frequency_type<>'Custom'
   BEGIN
     SELECT
       @instance_frequency_value=CASE @instance_frequency_type
         WHEN 'Daily' THEN 1
         WHEN 'Weekly' THEN 1
         WHEN 'Monthly' THEN 1
         WHEN 'Quarterly' THEN 3
         WHEN 'Half-Yearly' THEN 6
         WHEN 'Annual' THEN 12
         ELSE NULL
       END,
       @instance_frequency_unit=CASE @instance_frequency_type
         WHEN 'Daily' THEN 'Day'
         WHEN 'Weekly' THEN 'Week'
         WHEN 'Monthly' THEN 'Month'
         WHEN 'Quarterly' THEN 'Month'
         WHEN 'Half-Yearly' THEN 'Month'
         WHEN 'Annual' THEN 'Month'
         ELSE NULL
       END;
   END
   IF @instance_frequency_is_custom=1 AND (@instance_frequency_value IS NULL OR @instance_frequency_unit IS NULL)
     THROW 51033,'Frequency Value and Frequency Unit are required when Frequency is Custom.',1;

   -- Validate NOT NULL columns before INSERT to give clear error messages
   DECLARE @instance_organization_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @instance_code NVARCHAR(100)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.code'))),'');
   DECLARE @instance_name NVARCHAR(300)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
   DECLARE @instance_record_status_id INT=COALESCE(@payload_record_status_id,@active_record_status_id);
   DECLARE @instance_implementation_status_id INT=COALESCE(@payload_implementation_status_id,@active_implementation_status_id,@not_started_implementation_status_id);
   IF @instance_organization_id IS NULL
     THROW 51042,'Organization is required to save a Practice Instance.',1;
   IF @instance_code IS NULL
     THROW 51043,'Instance Code is required.',1;
   IF @instance_name IS NULL
     THROW 51044,'Instance Name is required.',1;
   IF @instance_record_status_id IS NULL
     THROW 51045,'Record Status master data is missing. Please run the database setup scripts.',1;
   IF @instance_implementation_status_id IS NULL
     THROW 51046,'Implementation Status master data is missing. Please run the database setup scripts.',1;

   IF @p_id=0 BEGIN
     INSERT grac_practice.practice_instance(practice_id,organization_id,instance_code,instance_name,primary_owner_id,primary_owner,secondary_owner,business_function_id,department_id,department,execution_frequency_id,assurance_frequency_id,frequency_id,frequency_type,frequency_value,frequency_unit,assurance_mode,criticality,implementation_status,implementation_status_id,status,record_status_id,entered_by)
     VALUES(@instance_practice_id,@instance_organization_id,@instance_code,@instance_name,@instance_primary_owner_id,@instance_primary_owner_name,JSON_VALUE(@p_payload,'$.secondaryOwner'),NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''),@instance_department_id,@instance_department_name,@instance_execution_frequency_id,@instance_assurance_frequency_id,@instance_frequency_id,@instance_frequency_type,@instance_frequency_value,@instance_frequency_unit,COALESCE(JSON_VALUE(@p_payload,'$.assuranceMode'),'Manual'),COALESCE(JSON_VALUE(@p_payload,'$.criticality'),'Medium'),COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),'Active'),@instance_implementation_status_id,COALESCE(JSON_VALUE(@p_payload,'$.status'),'Active'),@instance_record_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.practice_instance SET practice_id=@instance_practice_id,organization_id=@instance_organization_id,instance_code=@instance_code,instance_name=@instance_name,primary_owner_id=@instance_primary_owner_id,primary_owner=@instance_primary_owner_name,secondary_owner=JSON_VALUE(@p_payload,'$.secondaryOwner'),business_function_id=NULLIF(JSON_VALUE(@p_payload,'$.businessFunctionId'),''),department_id=@instance_department_id,department=@instance_department_name,execution_frequency_id=@instance_execution_frequency_id,assurance_frequency_id=@instance_assurance_frequency_id,frequency_id=@instance_frequency_id,frequency_type=@instance_frequency_type,frequency_value=@instance_frequency_value,frequency_unit=@instance_frequency_unit,assurance_mode=COALESCE(JSON_VALUE(@p_payload,'$.assuranceMode'),assurance_mode),criticality=COALESCE(JSON_VALUE(@p_payload,'$.criticality'),criticality),implementation_status=COALESCE(JSON_VALUE(@p_payload,'$.implementationStatus'),implementation_status),implementation_status_id=COALESCE(@payload_implementation_status_id,implementation_status_id),status=COALESCE(JSON_VALUE(@p_payload,'$.status'),status),record_status_id=COALESCE(@payload_record_status_id,record_status_id),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE practice_instance_id=@p_id;
 END
 ELSE IF @p_entity_type='dependencies'
 BEGIN
   DECLARE @dependency_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dependency_type_text NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.dependencyType'))),'');
   DECLARE @dependency_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @dependency_organization_id BIGINT;
   DECLARE @dependency_reference_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyReferenceId'),''));
   DECLARE @dependency_source_type NVARCHAR(80)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.sourceType'))),'');
   DECLARE @dependency_resolved_name NVARCHAR(300);
   DECLARE @dependency_criticality_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.criticalityId'),''));
   DECLARE @dependency_criticality_text NVARCHAR(120)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.criticality'))),'');
   DECLARE @dependency_status_id INT=COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),'')),@payload_record_status_id,@active_record_status_id);
   DECLARE @dependency_status_text NVARCHAR(120);
   DECLARE @dependency_cfg_source_table NVARCHAR(256);
   DECLARE @dependency_cfg_id_column SYSNAME;
   DECLARE @dependency_cfg_display_column SYSNAME;
   DECLARE @dependency_cfg_org_column SYSNAME;
   DECLARE @dependency_cfg_status_column SYSNAME;
   DECLARE @dependency_cfg_status_value NVARCHAR(80);
   DECLARE @dependency_cfg_schema SYSNAME;
   DECLARE @dependency_cfg_table SYSNAME;
   DECLARE @dependency_cfg_sql NVARCHAR(MAX);

   SELECT @dependency_organization_id=organization_id
   FROM grac_practice.practice_instance
   WHERE practice_instance_id=@dependency_practice_instance_id;
   IF @dependency_practice_instance_id IS NULL OR @dependency_organization_id IS NULL
     THROW 51031,'Practice Instance is required for Dependency.',1;

   IF @dependency_type_id IS NULL AND @dependency_type_text IS NOT NULL
     SELECT @dependency_type_id=dependency_type_id
     FROM grac_practice.dependency_type_master
     WHERE dependency_type_code=@dependency_type_text OR dependency_type_name=@dependency_type_text;
   IF @dependency_type_id IS NULL
     THROW 51027,'Dependency Type is required.',1;
   IF NOT EXISTS(SELECT 1 FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dependency_type_id AND is_active=1)
     THROW 51028,'Selected Dependency Type is not valid.',1;
   SELECT @dependency_type_text=dependency_type_code
   FROM grac_practice.dependency_type_master
   WHERE dependency_type_id=@dependency_type_id;

   IF @dependency_reference_id IS NULL
   BEGIN
     SELECT @dependency_resolved_name=dependency_type_name
     FROM grac_practice.dependency_type_master
     WHERE dependency_type_id=@dependency_type_id;
   END
   ELSE
   BEGIN
     SELECT TOP 1
       @dependency_source_type=COALESCE(@dependency_source_type,source_type),
       @dependency_cfg_source_table=source_table_name,
       @dependency_cfg_id_column=id_column_name,
       @dependency_cfg_display_column=display_column_name,
       @dependency_cfg_org_column=organization_filter_column,
       @dependency_cfg_status_column=status_filter_column,
       @dependency_cfg_status_value=status_active_value
     FROM grac_practice.dependency_type_source_config
     WHERE dependency_type_id=@dependency_type_id
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
     IF @dependency_cfg_source_table IS NULL
       THROW 51032,'Dependency Type source configuration is missing or inactive.',1;

     SET @dependency_cfg_schema=PARSENAME(@dependency_cfg_source_table,2);
     SET @dependency_cfg_table=PARSENAME(@dependency_cfg_source_table,1);
     IF @dependency_cfg_schema<>N'grac_practice' OR OBJECT_ID(@dependency_cfg_source_table) IS NULL
       THROW 51034,'Dependency Type source configuration is invalid.',1;
     IF COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_id_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_display_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_org_column) IS NULL
        OR COL_LENGTH(@dependency_cfg_source_table,@dependency_cfg_status_column) IS NULL
       THROW 51035,'Dependency Type source columns are invalid.',1;

     SET @dependency_cfg_sql=N'
 SELECT @resolvedName=CAST(' + QUOTENAME(@dependency_cfg_display_column) + N' AS NVARCHAR(300))
 FROM ' + QUOTENAME(@dependency_cfg_schema) + N'.' + QUOTENAME(@dependency_cfg_table) + N'
 WHERE ' + QUOTENAME(@dependency_cfg_id_column) + N'=@referenceId
   AND ' + QUOTENAME(@dependency_cfg_org_column) + N'=@organizationId
   AND ' + QUOTENAME(@dependency_cfg_status_column) + N'=@activeStatus;';
     EXEC sp_executesql @dependency_cfg_sql,
       N'@referenceId BIGINT,@organizationId BIGINT,@activeStatus NVARCHAR(80),@resolvedName NVARCHAR(300) OUTPUT',
       @referenceId=@dependency_reference_id,
       @organizationId=@dependency_organization_id,
       @activeStatus=@dependency_cfg_status_value,
       @resolvedName=@dependency_resolved_name OUTPUT;
     IF @dependency_resolved_name IS NULL
       THROW 51036,'Selected Dependency Name is not valid for this organization.',1;
   END

   IF @dependency_criticality_id IS NULL AND @dependency_criticality_text IS NOT NULL
     SELECT @dependency_criticality_id=criticality_id
     FROM grac_practice.criticality_master
     WHERE criticality_code=@dependency_criticality_text OR criticality_name=@dependency_criticality_text;
   IF @dependency_criticality_id IS NULL
     SELECT @dependency_criticality_id=criticality_id FROM grac_practice.criticality_master WHERE criticality_code='Medium';
   IF @dependency_criticality_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id=@dependency_criticality_id AND is_active=1)
     THROW 51029,'Selected Criticality is not valid.',1;
   SELECT @dependency_criticality_text=criticality_code
   FROM grac_practice.criticality_master
   WHERE criticality_id=@dependency_criticality_id;

   IF @dependency_status_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@dependency_status_id AND is_active=1)
     THROW 51030,'Selected dependency Status is not valid.',1;
   SELECT @dependency_status_text=status_code
   FROM grac_practice.record_status_master
   WHERE record_status_id=@dependency_status_id;

   IF @p_id=0 BEGIN
     SET @new_id=NULL;
     SELECT @new_id=dependency_id
     FROM grac_practice.practice_instance_dependency
     WHERE organization_id=@dependency_organization_id
       AND practice_instance_id=@dependency_practice_instance_id
       AND dependency_type_id=@dependency_type_id
       AND ISNULL(dependency_reference_id,0)=ISNULL(@dependency_reference_id,0);

     IF @new_id IS NULL
     BEGIN
       INSERT grac_practice.practice_instance_dependency(organization_id,practice_instance_id,dependency_type_id,dependency_type,dependency_name,dependency_reference,dependency_reference_id,dependency_source_type,owner_name,criticality_id,criticality,status,record_status_id,entered_by)
       VALUES(@dependency_organization_id,@dependency_practice_instance_id,@dependency_type_id,@dependency_type_text,@dependency_resolved_name,CONVERT(NVARCHAR(80),@dependency_reference_id),@dependency_reference_id,@dependency_source_type,JSON_VALUE(@p_payload,'$.ownerName'),@dependency_criticality_id,@dependency_criticality_text,@dependency_status_text,@dependency_status_id,@p_usr_id);
       SET @new_id=SCOPE_IDENTITY();
     END
     ELSE
     BEGIN
       UPDATE grac_practice.practice_instance_dependency
       SET dependency_type=@dependency_type_text,
           dependency_name=@dependency_resolved_name,
           dependency_reference=CONVERT(NVARCHAR(80),@dependency_reference_id),
           dependency_source_type=@dependency_source_type,
           owner_name=JSON_VALUE(@p_payload,'$.ownerName'),
           criticality_id=@dependency_criticality_id,
           criticality=@dependency_criticality_text,
           status=@dependency_status_text,
           record_status_id=@dependency_status_id,
           updated_by=@p_usr_id,
           updated_dt=SYSUTCDATETIME()
       WHERE dependency_id=@new_id;
     END
   END
   ELSE UPDATE d SET organization_id=pi.organization_id,practice_instance_id=pi.practice_instance_id,dependency_type_id=@dependency_type_id,dependency_type=@dependency_type_text,dependency_name=@dependency_resolved_name,dependency_reference=CONVERT(NVARCHAR(80),@dependency_reference_id),dependency_reference_id=@dependency_reference_id,dependency_source_type=@dependency_source_type,owner_name=JSON_VALUE(@p_payload,'$.ownerName'),criticality_id=@dependency_criticality_id,criticality=@dependency_criticality_text,status=@dependency_status_text,record_status_id=@dependency_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.practice_instance_dependency d
   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=@dependency_practice_instance_id
   WHERE d.dependency_id=@p_id;
 END
 ELSE IF @p_entity_type='evidence-configurations'
 BEGIN
   DECLARE @evidence_practice_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @evidence_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.evidenceTypeId'),''));
   DECLARE @assurance_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceTypeId'),''));
   DECLARE @collection_method_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.collectionMethodId'),''));
   DECLARE @collection_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.collectionFrequencyId'),''));
   DECLARE @alignment_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Organization Defined');
   DECLARE @evidence_status_id INT=COALESCE(TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.statusId'),'')),@payload_record_status_id,@active_record_status_id);
   DECLARE @evidence_status_text NVARCHAR(120);

   IF @evidence_practice_instance_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance WHERE practice_instance_id=@evidence_practice_instance_id)
     THROW 51035,'Practice Instance is required for Evidence Configuration.',1;
   /* ── Authorization: allow system admins, practice-instance owners, and
        users who belong to the same organization (evidence-configurations
        permission is already enforced by the API layer).
        This check must NOT block Add/Edit Practice Instance flows that
        chain evidence-configuration saves.  The old owner-only check
        incorrectly required the logged-in user to be the primary_owner,
        which fails when a different authorized user creates the instance.
        Updated 2026-07-06. ─────────────────────────────────────────────── */
   IF @is_system_admin=0
     AND NOT EXISTS(SELECT 1 FROM @allowed_organizations ao
       JOIN grac_practice.practice_instance pi ON pi.organization_id=ao.organization_id
       WHERE pi.practice_instance_id=@evidence_practice_instance_id)
     THROW 51041,'You are not authorized to manage evidence for this Practice Instance.',1;
   IF @evidence_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@evidence_type_id AND is_active=1)
     THROW 51036,'Selected Evidence Type is not valid.',1;
   IF @assurance_type_id IS NULL
     SELECT @assurance_type_id=assurance_type_id FROM grac_practice.assurance_type_master WHERE assurance_type_code=N'Manual' AND is_active=1;
   IF @assurance_type_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.assurance_type_master WHERE assurance_type_id=@assurance_type_id AND is_active=1)
     THROW 51042,'Selected Assurance Type is not valid.',1;
   IF @collection_method_id IS NULL
     SELECT @collection_method_id=collection_method_id FROM grac_practice.collection_method_master WHERE collection_method_code=N'Manual' AND is_active=1;
   IF @collection_method_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.collection_method_master WHERE collection_method_id=@collection_method_id AND is_active=1)
     THROW 51037,'Selected Collection Method is not valid.',1;
   IF @collection_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@collection_frequency_id AND is_active=1)
     THROW 51038,'Selected Collection Frequency is not valid.',1;
   IF @evidence_status_id IS NULL OR NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE record_status_id=@evidence_status_id AND is_active=1)
     THROW 51040,'Selected Evidence Status is not valid.',1;
   SELECT @evidence_status_text=status_code
   FROM grac_practice.record_status_master
   WHERE record_status_id=@evidence_status_id;

   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=evidence_id
     FROM grac_practice.practice_instance_evidence
     WHERE practice_instance_id=@evidence_practice_instance_id
       AND evidence_type_id=@evidence_type_id;
   END

   IF @p_id=0 AND @new_id IS NULL BEGIN
     INSERT grac_practice.practice_instance_evidence(
       organization_id,practice_instance_id,evidence_type_id,inherited_from_repository,organization_modified,is_mandatory,
       collection_method_id,collection_frequency_id,evidence_owner,assurance_type_id,retention_period,evidence_description,evidence_location,evidence_locator,alignment_status_id,status,record_status_id,entered_by)
     SELECT pi.organization_id,pi.practice_instance_id,@evidence_type_id,
       0,
       1,
       COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.mandatory')),1),
       @collection_method_id,@collection_frequency_id,JSON_VALUE(@p_payload,'$.evidenceOwner'),@assurance_type_id,JSON_VALUE(@p_payload,'$.retentionPeriod'),JSON_VALUE(@p_payload,'$.evidenceDescription'),JSON_VALUE(@p_payload,'$.evidenceLocation'),JSON_VALUE(@p_payload,'$.evidenceLocator'),@alignment_status_id,
       @evidence_status_text,@evidence_status_id,@p_usr_id
     FROM grac_practice.practice_instance pi
      WHERE pi.practice_instance_id=@evidence_practice_instance_id;
      SET @new_id=SCOPE_IDENTITY();
    END
    ELSE UPDATE e SET organization_id=pi.organization_id,practice_instance_id=pi.practice_instance_id,
      evidence_type_id=@evidence_type_id,
     inherited_from_repository=0,
     organization_modified=1,
     is_mandatory=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.mandatory')),1),
     collection_method_id=@collection_method_id,collection_frequency_id=@collection_frequency_id,
     evidence_owner=JSON_VALUE(@p_payload,'$.evidenceOwner'),
     assurance_type_id=@assurance_type_id,
     retention_period=JSON_VALUE(@p_payload,'$.retentionPeriod'),
     evidence_description=JSON_VALUE(@p_payload,'$.evidenceDescription'),
     evidence_location=JSON_VALUE(@p_payload,'$.evidenceLocation'),
     evidence_locator=JSON_VALUE(@p_payload,'$.evidenceLocator'),
     alignment_status_id=@alignment_status_id,
     status=@evidence_status_text,record_status_id=@evidence_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
    FROM grac_practice.practice_instance_evidence e
    JOIN grac_practice.practice_instance pi ON pi.practice_instance_id=@evidence_practice_instance_id
    WHERE e.evidence_id=COALESCE(NULLIF(@p_id,0),@new_id);

   DECLARE @aligned_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Aligned');
   DECLARE @enhanced_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Enhanced');
   DECLARE @not_aligned_status_id INT=(SELECT alignment_status_id FROM grac_practice.evidence_alignment_status_master WHERE alignment_status_code=N'Not Aligned');
   DECLARE @alignment_result TABLE(release_id BIGINT NOT NULL PRIMARY KEY,alignment_status_id INT NOT NULL,alignment_reason NVARCHAR(MAX) NULL);

   ;WITH frequency_rank AS (
     SELECT frequency_id,
       CASE
         WHEN LOWER(frequency_name)=N'annual' THEN 1
         WHEN LOWER(frequency_name)=N'half-yearly' THEN 2
         WHEN LOWER(frequency_name)=N'quarterly' THEN 3
         WHEN LOWER(frequency_name)=N'monthly' THEN 4
         WHEN LOWER(frequency_name)=N'weekly' THEN 5
         WHEN LOWER(frequency_name)=N'daily' THEN 6
         WHEN LOWER(frequency_name)=N'continuous' THEN 7
         ELSE 0
       END frequency_strength
     FROM grac_practice.frequency_master
   ),
   instance_context AS (
     SELECT pi.practice_instance_id,pi.organization_id,p.organization_requirement_id,req.repository_requirement_id,
       req.organization_control_id,oc.repository_control_id,oc.release_id context_release_id
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
     JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
     LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id=req.organization_control_id
     WHERE pi.practice_instance_id=@evidence_practice_instance_id
   ),
   /* ── recommended: use current obligation model (requirement_obligation + requirement_obligation_evidence) ── */
   recommended AS (
     SELECT orm.release_id,roe.evidence_type_id,MAX(ISNULL(fr.frequency_strength,0)) required_strength
     FROM instance_context ctx
     JOIN GRAC_New.obligation_requirement_release_map orm
       ON orm.requirement_id=ctx.repository_requirement_id AND orm.status='Active'
     JOIN GRAC_New.requirement_obligation o
       ON o.obligation_id=orm.obligation_id AND o.status='Active'
     JOIN GRAC_New.requirement_obligation_evidence roe
       ON roe.obligation_id=o.obligation_id AND roe.status='Active'
     LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id=roe.frequency_id
     LEFT JOIN grac_practice.frequency_master f
       ON f.frequency_code=cm_freq.option_value OR f.frequency_name=cm_freq.option_label
     LEFT JOIN frequency_rank fr ON fr.frequency_id=f.frequency_id
     WHERE ctx.repository_requirement_id IS NOT NULL
       AND (
         ctx.context_release_id IS NULL
         OR orm.release_id=ctx.context_release_id
         OR EXISTS(SELECT 1 FROM grac_practice.repository_subscription s WHERE s.organization_id=ctx.organization_id AND s.release_id=orm.release_id AND s.status='Active' AND ISNULL(s.subscription_status,'Active')='Active')
       )
     GROUP BY orm.release_id,roe.evidence_type_id
   ),
   organization_evidence AS (
     SELECT e.evidence_type_id,MAX(ISNULL(fr.frequency_strength,0)) configured_strength
     FROM grac_practice.practice_instance_evidence e
     LEFT JOIN frequency_rank fr ON fr.frequency_id=e.collection_frequency_id
     WHERE e.practice_instance_id=@evidence_practice_instance_id AND e.status='Active'
     GROUP BY e.evidence_type_id
   ),
   release_eval AS (
     SELECT r.release_id,
       COUNT(1) required_count,
       SUM(CASE WHEN oe.evidence_type_id IS NOT NULL AND oe.configured_strength>=r.required_strength THEN 1 ELSE 0 END) satisfied_count,
       SUM(CASE WHEN oe.evidence_type_id IS NOT NULL AND oe.configured_strength>r.required_strength THEN 1 ELSE 0 END) stronger_count,
       (SELECT COUNT(1) FROM organization_evidence oe2 WHERE NOT EXISTS(SELECT 1 FROM recommended r2 WHERE r2.release_id=r.release_id AND r2.evidence_type_id=oe2.evidence_type_id)) extra_count
     FROM recommended r
     LEFT JOIN organization_evidence oe ON oe.evidence_type_id=r.evidence_type_id
     GROUP BY r.release_id
   ),
   alignment_source AS (
     SELECT release_id,
       CASE
         WHEN satisfied_count<required_count THEN @not_aligned_status_id
         WHEN stronger_count>0 OR extra_count>0 THEN @enhanced_status_id
         ELSE @aligned_status_id
       END alignment_status_id,
       CASE
         WHEN satisfied_count<required_count THEN N'One or more required evidence types are missing or configured with weaker frequency.'
         WHEN stronger_count>0 OR extra_count>0 THEN N'Organization evidence satisfies the obligation and exceeds the recommendation.'
         ELSE N'Organization evidence exactly matches the obligation recommendation.'
       END alignment_reason
     FROM release_eval
   )
   INSERT @alignment_result(release_id,alignment_status_id,alignment_reason)
   SELECT release_id,alignment_status_id,alignment_reason
   FROM alignment_source;

   MERGE grac_practice.practice_instance_evidence_alignment AS target
   USING @alignment_result AS source
   ON target.practice_instance_id=@evidence_practice_instance_id AND target.framework_release_id=source.release_id
   WHEN MATCHED THEN UPDATE SET alignment_status_id=source.alignment_status_id,alignment_reason=source.alignment_reason,calculated_dt=SYSUTCDATETIME(),status=N'Active',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   WHEN NOT MATCHED THEN INSERT(practice_instance_id,framework_release_id,alignment_status_id,alignment_reason,calculated_dt,status,entered_by)
   VALUES(@evidence_practice_instance_id,source.release_id,source.alignment_status_id,source.alignment_reason,SYSUTCDATETIME(),N'Active',@p_usr_id);

   UPDATE existing
   SET status=N'Inactive',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
   FROM grac_practice.practice_instance_evidence_alignment existing
   WHERE existing.practice_instance_id=@evidence_practice_instance_id
     AND existing.status=N'Active'
     AND NOT EXISTS(SELECT 1 FROM @alignment_result ar WHERE ar.release_id=existing.framework_release_id);
 END
 ELSE IF @p_entity_type='assurance-generation'
 BEGIN
   DECLARE @assurance_gen_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @assurance_gen_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @assurance_period_from DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodFrom'));
   DECLARE @assurance_period_to DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodTo'));
   DECLARE @assurance_due_dt DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate'));
   DECLARE @assurance_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityOwnerId'),''));
   DECLARE @assurance_owner_name NVARCHAR(200)=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@assurance_owner_id);
   DECLARE @assurance_gen_type_id INT=NULL;
   DECLARE @assurance_gen_type_name NVARCHAR(80)=N'Manual';
   DECLARE @pending_activity_status_id INT=(SELECT assurance_activity_status_id FROM grac_practice.assurance_activity_status_master WHERE status_code=N'Pending');

   IF @assurance_gen_instance_id IS NULL THROW 52001,'Eligible Practice Instance is required.',1;
   IF @assurance_period_from IS NULL OR @assurance_period_to IS NULL OR @assurance_period_to<@assurance_period_from
     THROW 52002,'Valid assurance period is required.',1;

   SELECT @assurance_gen_org_id=pi.organization_id,
          @assurance_gen_type_id=at.assurance_type_id,
          @assurance_gen_type_name=COALESCE(at.assurance_type_name,pi.assurance_mode,N'Manual')
   FROM grac_practice.practice_instance pi
   LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_name=pi.assurance_mode OR at.assurance_type_code=pi.assurance_mode
   WHERE pi.practice_instance_id=@assurance_gen_instance_id;

   IF NOT EXISTS(
     SELECT 1
     FROM grac_practice.practice_instance pi
     JOIN grac_practice.practice_operationalization po ON po.practice_instance_id=pi.practice_instance_id AND po.organization_id=pi.organization_id AND po.status=N'Resolved'
     WHERE pi.practice_instance_id=@assurance_gen_instance_id
       AND pi.status=N'Active'
       AND NULLIF(pi.primary_owner,N'') IS NOT NULL
       AND (pi.department_id IS NOT NULL OR NULLIF(pi.department,N'') IS NOT NULL)
       AND EXISTS(SELECT 1 FROM grac_practice.practice_instance_evidence e WHERE e.practice_instance_id=pi.practice_instance_id AND e.status=N'Active' AND NULLIF(e.evidence_location,N'') IS NOT NULL AND NULLIF(e.evidence_locator,N'') IS NOT NULL)
       AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_instance_dependency d WHERE d.practice_instance_id=pi.practice_instance_id AND d.status=N'Active' AND NOT EXISTS(SELECT 1 FROM grac_practice.practice_dependency_resolution r WHERE r.practice_instance_id=pi.practice_instance_id AND r.dependency_type_id=d.dependency_type_id AND r.is_active=1 AND r.resolution_status=N'Resolved'))
   )
     THROW 52003,'Practice Instance is not eligible for Assurance.',1;

   INSERT grac_practice.assurance_activity(organization_id,practice_instance_id,activity_number,period_from,period_to,assurance_type_id,assurance_type,activity_owner_id,activity_owner,status_id,status,due_dt,remarks,record_status_id,entered_by)
   VALUES(@assurance_gen_org_id,@assurance_gen_instance_id,
     N'ASM-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_activity_seq),6),
     @assurance_period_from,@assurance_period_to,@assurance_gen_type_id,@assurance_gen_type_name,@assurance_owner_id,@assurance_owner_name,@pending_activity_status_id,N'Pending',COALESCE(@assurance_due_dt,@assurance_period_to),JSON_VALUE(@p_payload,'$.remarks'),@active_record_status_id,@p_usr_id);
   SET @new_id=SCOPE_IDENTITY();
   SET @result_message=N'Assurance activity generated successfully.';
 END
 ELSE IF @p_entity_type='assurance-activities'
 BEGIN
   DECLARE @activity_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @activity_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @activity_period_from DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodFrom'));
   DECLARE @activity_period_to DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.periodTo'));
   DECLARE @activity_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),N'Pending');
   DECLARE @activity_status_id INT=(SELECT assurance_activity_status_id FROM grac_practice.assurance_activity_status_master WHERE status_code=@activity_status OR status_name=@activity_status);
   DECLARE @activity_assurance_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.assuranceTypeId'),''));
   DECLARE @activity_assurance_type NVARCHAR(80)=COALESCE((SELECT assurance_type_name FROM grac_practice.assurance_type_master WHERE assurance_type_id=@activity_assurance_type_id),N'Manual');
   DECLARE @activity_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityOwnerId'),''));
   DECLARE @activity_owner NVARCHAR(200)=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@activity_owner_id);
   IF @activity_instance_id IS NULL THROW 52004,'Practice Instance is required.',1;
   SELECT @activity_org_id=COALESCE(@activity_org_id,organization_id) FROM grac_practice.practice_instance WHERE practice_instance_id=@activity_instance_id;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_activity(organization_id,practice_instance_id,activity_number,period_from,period_to,assurance_type_id,assurance_type,activity_owner_id,activity_owner,status_id,status,due_dt,remarks,record_status_id,entered_by)
     VALUES(@activity_org_id,@activity_instance_id,N'ASM-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_activity_seq),6),@activity_period_from,@activity_period_to,@activity_assurance_type_id,@activity_assurance_type,@activity_owner_id,@activity_owner,@activity_status_id,@activity_status,TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),JSON_VALUE(@p_payload,'$.remarks'),@active_record_status_id,@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_activity SET period_from=@activity_period_from,period_to=@activity_period_to,assurance_type_id=@activity_assurance_type_id,assurance_type=@activity_assurance_type,activity_owner_id=@activity_owner_id,activity_owner=@activity_owner,status_id=@activity_status_id,status=@activity_status,due_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-execution'
 BEGIN
   DECLARE @exec_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @exec_executor_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.executorId'),''));
   DECLARE @exec_result_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.resultStatus'),''),N'Pending');
   DECLARE @exec_result_status_id INT=(SELECT assurance_result_status_id FROM grac_practice.assurance_result_status_master WHERE status_code=@exec_result_status OR status_name=@exec_result_status);
   IF @exec_activity_id IS NULL THROW 52005,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_execution(assurance_activity_id,organization_id,practice_instance_id,execution_dt,executor_id,executor_name,evidence_status,dependency_status,result_status_id,result_status,execution_notes,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.executionDate')),@exec_executor_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@exec_executor_id),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.evidenceStatus'),''),N'Pending'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.dependencyStatus'),''),N'Pending'),@exec_result_status_id,@exec_result_status,JSON_VALUE(@p_payload,'$.executionNotes'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@exec_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE ex SET execution_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.executionDate')),executor_id=@exec_executor_id,executor_name=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@exec_executor_id),evidence_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.evidenceStatus'),''),N'Pending'),dependency_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.dependencyStatus'),''),N'Pending'),result_status_id=@exec_result_status_id,result_status=@exec_result_status,execution_notes=JSON_VALUE(@p_payload,'$.executionNotes'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() FROM grac_practice.assurance_execution ex WHERE ex.assurance_execution_id=@p_id;
   UPDATE grac_practice.assurance_activity SET status=N'In Progress',updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@exec_activity_id AND status=N'Pending';
 END
 ELSE IF @p_entity_type='evidence-assurance'
 BEGIN
   DECLARE @ev_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @ev_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.evidenceTypeId'),''));
   DECLARE @ev_exists BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.evidenceExists'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_accessible BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.evidenceAccessible'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_matches BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.matchesExpectedType'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_relates BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.relatesToAssurance'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @ev_result NVARCHAR(80)=CASE WHEN @ev_exists=1 AND @ev_accessible=1 AND @ev_matches=1 AND @ev_relates=1 THEN N'Pass' ELSE N'Fail' END;
   IF @ev_activity_id IS NULL THROW 52006,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_evidence_check(assurance_activity_id,organization_id,practice_instance_id,evidence_type_id,evidence_type_name,evidence_exists,evidence_accessible,matches_expected_type,relates_to_assurance,evidence_location,evidence_locator,result_status,remarks,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@ev_type_id,(SELECT evidence_type_name FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@ev_type_id),@ev_exists,@ev_accessible,@ev_matches,@ev_relates,JSON_VALUE(@p_payload,'$.evidenceLocation'),JSON_VALUE(@p_payload,'$.evidenceLocator'),@ev_result,JSON_VALUE(@p_payload,'$.remarks'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@ev_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_evidence_check SET evidence_type_id=@ev_type_id,evidence_type_name=(SELECT evidence_type_name FROM GRAC_New.evidence_type_master WHERE evidence_type_id=@ev_type_id),evidence_exists=@ev_exists,evidence_accessible=@ev_accessible,matches_expected_type=@ev_matches,relates_to_assurance=@ev_relates,evidence_location=JSON_VALUE(@p_payload,'$.evidenceLocation'),evidence_locator=JSON_VALUE(@p_payload,'$.evidenceLocator'),result_status=@ev_result,remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE evidence_check_id=@p_id;
 END
 ELSE IF @p_entity_type='dependency-assurance'
 BEGIN
   DECLARE @dep_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @dep_type_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.dependencyTypeId'),''));
   DECLARE @dep_available BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.dependencyAvailable'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @dep_current BIT=CASE WHEN LOWER(COALESCE(JSON_VALUE(@p_payload,'$.dependencyCurrent'),'')) IN ('yes','true','1') THEN 1 ELSE 0 END;
   DECLARE @dep_result NVARCHAR(80)=CASE WHEN @dep_available=1 AND @dep_current=1 THEN N'Pass' ELSE N'Fail' END;
   IF @dep_activity_id IS NULL THROW 52007,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_dependency_check(assurance_activity_id,organization_id,practice_instance_id,dependency_type_id,dependency_type_name,resolved_dependency_name,dependency_available,dependency_current,result_status,remarks,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@dep_type_id,(SELECT dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dep_type_id),JSON_VALUE(@p_payload,'$.resolvedDependencyName'),@dep_available,@dep_current,@dep_result,JSON_VALUE(@p_payload,'$.remarks'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@dep_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_dependency_check SET dependency_type_id=@dep_type_id,dependency_type_name=(SELECT dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dep_type_id),resolved_dependency_name=JSON_VALUE(@p_payload,'$.resolvedDependencyName'),dependency_available=@dep_available,dependency_current=@dep_current,result_status=@dep_result,remarks=JSON_VALUE(@p_payload,'$.remarks'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE dependency_check_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-results'
 BEGIN
   DECLARE @res_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @res_status NVARCHAR(80)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.resultStatus'),''),N'Pending');
   DECLARE @res_status_id INT=(SELECT assurance_result_status_id FROM grac_practice.assurance_result_status_master WHERE status_code=@res_status OR status_name=@res_status);
   DECLARE @res_completed_by_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.completedById'),''));
   IF @res_activity_id IS NULL THROW 52008,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_result(assurance_activity_id,organization_id,practice_instance_id,result_status_id,result_status,operating_effectiveness,completed_dt,completed_by_id,completed_by,result_summary,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,@res_status_id,@res_status,COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.operatingEffectiveness'),''),N'Not Assessed'),TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.completedDate')),@res_completed_by_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@res_completed_by_id),JSON_VALUE(@p_payload,'$.resultSummary'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@res_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_result SET result_status_id=@res_status_id,result_status=@res_status,operating_effectiveness=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.operatingEffectiveness'),''),N'Not Assessed'),completed_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.completedDate')),completed_by_id=@res_completed_by_id,completed_by=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@res_completed_by_id),result_summary=JSON_VALUE(@p_payload,'$.resultSummary'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_result_id=@p_id;
   IF @res_status IN (N'Pass',N'Pass With Observation',N'Fail',N'Unable To Verify')
     UPDATE grac_practice.assurance_activity SET status=CASE WHEN @res_status=N'Unable To Verify' THEN N'Unable To Verify' ELSE N'Completed' END,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE assurance_activity_id=@res_activity_id;
 END
 ELSE IF @p_entity_type='assurance-findings'
 BEGIN
   DECLARE @find_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @find_owner_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.ownerId'),''));
   IF @find_activity_id IS NULL THROW 52009,'Assurance Activity is required.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_finding(assurance_activity_id,organization_id,practice_instance_id,finding_number,title,description,severity,owner_id,owner_name,due_dt,finding_status,entered_by)
     SELECT aa.assurance_activity_id,aa.organization_id,aa.practice_instance_id,N'ASF-' + RIGHT(N'000000' + CONVERT(NVARCHAR(20),NEXT VALUE FOR dbo.pm_assurance_finding_seq),6),JSON_VALUE(@p_payload,'$.title'),JSON_VALUE(@p_payload,'$.description'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),N'Medium'),@find_owner_id,(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@find_owner_id),TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.findingStatus'),''),N'Open'),@p_usr_id
     FROM grac_practice.assurance_activity aa WHERE aa.assurance_activity_id=@find_activity_id;
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_finding SET title=JSON_VALUE(@p_payload,'$.title'),description=JSON_VALUE(@p_payload,'$.description'),severity=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),severity),owner_id=@find_owner_id,owner_name=(SELECT employee_name FROM grac_practice.organization_employee WHERE employee_id=@find_owner_id),due_dt=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.dueDate')),finding_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.findingStatus'),''),finding_status),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE finding_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-signals'
 BEGIN
   DECLARE @sig_activity_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.activityId'),''));
   DECLARE @sig_org_id BIGINT=NULL,@sig_instance_id BIGINT=NULL;
   SELECT @sig_org_id=organization_id,@sig_instance_id=practice_instance_id FROM grac_practice.assurance_activity WHERE assurance_activity_id=@sig_activity_id;
   SET @sig_org_id=COALESCE(@sig_org_id,TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),'')));
   IF @sig_org_id IS NULL THROW 52010,'Organization or Assurance Activity is required for signal.',1;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_signal(assurance_activity_id,organization_id,practice_instance_id,signal_type,severity,signal_status,message,entered_by)
     VALUES(@sig_activity_id,@sig_org_id,@sig_instance_id,JSON_VALUE(@p_payload,'$.signalType'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),N'Medium'),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.signalStatus'),''),N'Open'),JSON_VALUE(@p_payload,'$.message'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_signal SET signal_type=JSON_VALUE(@p_payload,'$.signalType'),severity=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.severity'),''),severity),signal_status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.signalStatus'),''),signal_status),message=JSON_VALUE(@p_payload,'$.message'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE signal_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-schedule-rules'
 BEGIN
   DECLARE @rule_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @rule_instance_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.practiceInstanceId'),''));
   DECLARE @rule_frequency_id INT=TRY_CONVERT(INT,NULLIF(JSON_VALUE(@p_payload,'$.frequencyId'),''));
   DECLARE @rule_anchor DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.anchorDate'));
   DECLARE @rule_end DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.endDate'));
   IF @rule_org_id IS NULL OR @rule_instance_id IS NULL THROW 52020,'Organization and Practice Instance are required.',1;
   IF @rule_frequency_id IS NULL THROW 52021,'Frequency is required for schedule rule.',1;
   IF @rule_anchor IS NULL THROW 52022,'Anchor date is required for schedule rule.',1;
   IF @p_id=0
   BEGIN
     SET @new_id=NULL;
     SELECT @new_id=schedule_rule_id FROM grac_practice.assurance_schedule_rule WHERE practice_instance_id=@rule_instance_id AND status='Active';
     IF @new_id IS NOT NULL THROW 52023,'A schedule rule already exists for this practice instance.',1;
     INSERT grac_practice.assurance_schedule_rule(organization_id,practice_instance_id,frequency_id,anchor_date,end_date,schedule_owner,notes,entered_by)
     VALUES(@rule_org_id,@rule_instance_id,@rule_frequency_id,@rule_anchor,@rule_end,JSON_VALUE(@p_payload,'$.scheduleOwner'),JSON_VALUE(@p_payload,'$.notes'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_schedule_rule SET frequency_id=@rule_frequency_id,anchor_date=@rule_anchor,end_date=@rule_end,schedule_owner=JSON_VALUE(@p_payload,'$.scheduleOwner'),notes=JSON_VALUE(@p_payload,'$.notes'),status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE schedule_rule_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-schedule-overrides'
 BEGIN
   DECLARE @ovr_rule_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.scheduleRuleId'),''));
   DECLARE @ovr_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   DECLARE @ovr_original DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.originalDate'));
   DECLARE @ovr_type NVARCHAR(30)=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.overrideType'),''),N'Moved');
   DECLARE @ovr_new_date DATE=TRY_CONVERT(DATE,JSON_VALUE(@p_payload,'$.newDate'));
   IF @ovr_rule_id IS NULL THROW 52030,'Schedule rule is required.',1;
   IF @ovr_original IS NULL THROW 52031,'Original date is required.',1;
   IF @ovr_org_id IS NULL SELECT @ovr_org_id=organization_id FROM grac_practice.assurance_schedule_rule WHERE schedule_rule_id=@ovr_rule_id;
   IF @p_id=0
   BEGIN
     INSERT grac_practice.assurance_schedule_override(schedule_rule_id,organization_id,original_date,override_type,new_date,reason,apply_to_future,override_by,entered_by)
     VALUES(@ovr_rule_id,@ovr_org_id,@ovr_original,@ovr_type,@ovr_new_date,JSON_VALUE(@p_payload,'$.reason'),COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),JSON_VALUE(@p_payload,'$.overrideBy'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_schedule_override SET override_type=@ovr_type,new_date=@ovr_new_date,reason=JSON_VALUE(@p_payload,'$.reason'),apply_to_future=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),override_by=JSON_VALUE(@p_payload,'$.overrideBy'),status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE override_id=@p_id;
 END
 ELSE IF @p_entity_type='assurance-calendar-config'
 BEGIN
   DECLARE @cfg_org_id BIGINT=TRY_CONVERT(BIGINT,NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
   IF @cfg_org_id IS NULL THROW 52040,'Organization is required for calendar config.',1;
   SET @new_id=NULL;
   SELECT @new_id=config_id FROM grac_practice.assurance_calendar_config WHERE organization_id=@cfg_org_id;
   IF @new_id IS NULL
   BEGIN
     INSERT grac_practice.assurance_calendar_config(organization_id,look_back_months,look_ahead_months,default_view,entered_by)
     VALUES(@cfg_org_id,COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),3),COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),12),COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),N'month'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE UPDATE grac_practice.assurance_calendar_config SET look_back_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),look_back_months),look_ahead_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),look_ahead_months),default_view=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),default_view),updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME() WHERE config_id=@new_id;
 END
 ELSE THROW 51004,'Save is not configured for this practice area yet',1;

 INSERT grac_practice.practice_audit_trace(entity_type,entity_id,action_type,after_json,status,entered_by)
 VALUES(@p_entity_type,@new_id,@p_action,@p_payload,'Active',@p_usr_id);
 COMMIT;
 SELECT CAST(1 AS BIT) Success,@result_message Message,@new_id Id;
END
GO

PRINT '380 rollback: pm_manage_practice_repository restored to its pre-380 body.';
GO

UPDATE grac_practice.repository_subscription
   SET subscription_type = N'Manual',
       updated_by        = N'seed-380-rollback',
       updated_dt         = SYSUTCDATETIME()
 WHERE release_id IS NOT NULL
   AND subscription_type = N'Repository';

PRINT '380 rollback: reverted ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' repository_subscription row(s) from Repository back to Manual.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '380 rollback-a proc compiled' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.pm_manage_practice_repository','P')) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '380 rollback-b Repository literal removed from the org-setup INSERT',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.pm_manage_practice_repository','P')) LIKE '%r.release_id,''Manual''%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '380 rollback complete.';
GO
SET NOEXEC OFF;
GO
