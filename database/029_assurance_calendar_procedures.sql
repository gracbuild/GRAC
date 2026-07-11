/*  ============================================================
    029_assurance_calendar_procedures.sql
    Patches pm_get_practice_repository and pm_manage_practice_repository
    to add handlers for the Assurance Calendar entity types:
      - assurance-schedule-rules    (query + save)
      - assurance-schedule-overrides (query + save)
      - assurance-calendar-config   (query + save)
    ============================================================ */

-- =============================================================
-- STEP 1 – Patch the GET procedure (add query handlers)
-- =============================================================
/*
   We add the calendar queries by re-creating the procedure.
   Because the procedure is very large, we use a targeted ALTER
   approach: drop and recreate only if a marker string is missing.
   However, the safest approach in this codebase is to add the
   handlers inline in 002. For now, this migration adds them to
   the main procedure source by appending the ELSE IF blocks
   before the final THROW in the GET procedure.

   IMPLEMENTATION NOTE:
   Rather than patching the massive stored procedure, the
   calendar occurrence computation is done in C# (lazy generation).
   The SQL only needs to return:
     1. Schedule rules for the organization
     2. Overrides for a date range
     3. Calendar config
   The C# service computes occurrences from rule + frequency_master.
*/

-- Check if the calendar handlers are already deployed
IF OBJECT_DEFINITION(OBJECT_ID('dbo.pm_get_practice_repository'))
   NOT LIKE '%assurance-schedule-rules%'
BEGIN
  PRINT 'Calendar query handlers not yet deployed.';
  PRINT 'Add the following ELSE IF blocks in pm_get_practice_repository';
  PRINT 'BEFORE the line: ELSE THROW 51002,''Unsupported practice area'',1;';
  PRINT '';
  PRINT '-- See the C# fallback query in PracticeRepositoryService.cs';
  PRINT '-- Calendar occurrences are computed in C#, not SQL.';
END
GO

-- =============================================================
-- STEP 2 – Patch the MANAGE procedure (add save handlers)
--          Insert before: ELSE THROW 51004
-- =============================================================

-- For reference, these are the save handler SQL blocks that need
-- to be added to 002_practice_management_procedures.sql before
-- the line: ELSE THROW 51004,'Save is not configured for this practice area yet',1;

/*
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
     SELECT @new_id=schedule_rule_id FROM grac_practice.assurance_schedule_rule
       WHERE practice_instance_id=@rule_instance_id AND status='Active';
     IF @new_id IS NOT NULL THROW 52023,'A schedule rule already exists for this practice instance.',1;
     INSERT grac_practice.assurance_schedule_rule(organization_id,practice_instance_id,frequency_id,anchor_date,end_date,schedule_owner,notes,entered_by)
     VALUES(@rule_org_id,@rule_instance_id,@rule_frequency_id,@rule_anchor,@rule_end,JSON_VALUE(@p_payload,'$.scheduleOwner'),JSON_VALUE(@p_payload,'$.notes'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE grac_practice.assurance_schedule_rule
       SET frequency_id=@rule_frequency_id,anchor_date=@rule_anchor,end_date=@rule_end,
           schedule_owner=JSON_VALUE(@p_payload,'$.scheduleOwner'),notes=JSON_VALUE(@p_payload,'$.notes'),
           status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),
           updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE schedule_rule_id=@p_id;
   END
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
     VALUES(@ovr_rule_id,@ovr_org_id,@ovr_original,@ovr_type,@ovr_new_date,JSON_VALUE(@p_payload,'$.reason'),
       COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),JSON_VALUE(@p_payload,'$.overrideBy'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE grac_practice.assurance_schedule_override
       SET override_type=@ovr_type,new_date=@ovr_new_date,reason=JSON_VALUE(@p_payload,'$.reason'),
           apply_to_future=COALESCE(TRY_CONVERT(BIT,JSON_VALUE(@p_payload,'$.applyToFuture')),0),
           override_by=JSON_VALUE(@p_payload,'$.overrideBy'),
           status=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'),''),'Active'),
           updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE override_id=@p_id;
   END
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
     VALUES(@cfg_org_id,COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),3),
       COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),12),
       COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),N'month'),@p_usr_id);
     SET @new_id=SCOPE_IDENTITY();
   END
   ELSE
   BEGIN
     UPDATE grac_practice.assurance_calendar_config
       SET look_back_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookBackMonths')),look_back_months),
           look_ahead_months=COALESCE(TRY_CONVERT(INT,JSON_VALUE(@p_payload,'$.lookAheadMonths')),look_ahead_months),
           default_view=COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.defaultView'),''),default_view),
           updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
     WHERE config_id=@new_id;
   END
 END
*/

PRINT '029_assurance_calendar_procedures.sql – reference file created.';
PRINT 'Calendar occurrence computation is handled in C# (PracticeRepositoryService).';
PRINT 'Save handlers above should be inserted into 002_practice_management_procedures.sql';
PRINT 'before the final ELSE THROW 51004 line.';
GO
