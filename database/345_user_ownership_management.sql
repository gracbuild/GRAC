-- =====================================================================
-- 345_user_ownership_management.sql
--
-- WHY THIS EXISTS
-- ---------------
-- 1. A user could be deactivated while still recorded as the Owner of live
--    items across the app, leaving dangling ownership. This adds a
--    backend-enforced guard: an employee who still holds ANY active
--    ownership cannot be flipped to status='Inactive'.
-- 2. A new "Ownership Management" screen needs to enumerate everything a
--    user currently owns and reassign each item to another (Active,
--    Functional) user.
--
-- ONE SOURCE OF TRUTH
-- -------------------
-- grac_practice.fn_pm_user_ownership(@employee_id) is the single inline
-- table-valued function that lists every ACTIVE ownership a user holds,
-- across all owner relationships identified in the impact analysis
-- (Practice, Control, Dependencies, Assurance/Audit, Risk, Release, Task,
-- Reporting Officer, plus the name-valued owners). The deactivation guard
-- trigger, the list proc and the reassign proc all read from it, so the
-- definition of "what a user owns" lives in exactly one place.
--
-- Owner storage comes in two shapes, both handled:
--   * ID-based   : a *_owner_id / owner_employee_id BIGINT FK, sometimes
--                  with a denormalised owner-name column kept in step.
--   * NAME-based : the owner is stored as employee_name text (business
--                  function, control primary/secondary/backup, instance
--                  secondary owner, dependency owner, evidence owner).
--                  Matched (and rewritten) by name, scoped to the user's
--                  organization to avoid cross-org same-name collisions.
--
-- ENFORCEMENT
-- -----------
-- tr_pm_org_employee_ownership_deactivate_guard fires on UPDATE of
-- organization_employee and THROWs 51950 when a row transitions INTO
-- 'Inactive' while the employee still holds active ownership. A trigger
-- (not a proc edit) is used deliberately: status can reach 'Inactive'
-- through sp_org_user_save, sp_org_user_repository_manage AND the
-- pm_manage_practice_repository delete branch -- one trigger covers every
-- path and any future one, without touching the monolith.
--   Maintenance/reset scripts that legitimately need to bypass the guard
--   (e.g. 192_practice_data_reset) can set, for their connection only,
--       EXEC sys.sp_set_session_context N'pm_bypass_ownership_guard', 1;
--   The guard is skipped when that flag is 1.
--
-- REASSIGNMENT
-- ------------
-- sp_pm_user_ownership_reassign takes a JSON batch and updates every item
-- in ONE transaction. Every target owner is validated up front as Active
-- AND Functional (is_functional_user=1); a bad target aborts the whole
-- batch so no partial reassignment is left behind.
--
-- SAFE TO RE-RUN (CREATE OR ALTER + guarded menu MERGE). Requires 341
-- (is_functional_user) and the core schema (001/002/037/079/205). ASCII.
-- NOTE: migration numbers 341-344 are shared with a parallel
--   event-obligation series; this file is 345 to sit after both. If the
--   two series are ever renumbered, keep this after 341_functional_user.
-- Rollback: database/345_user_ownership_management_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    PRINT 'ABORT (345): organization_employee.is_functional_user missing. Run 341_functional_user_flag first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_pm_user_ownership -- the single ownership enumeration
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_user_ownership(@employee_id BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH me AS (
        SELECT employee_id, employee_name, organization_id
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @employee_id
    )
    -- ---------------- ID-based owners ----------------
    -- Practice owner
    SELECT CAST(N'PRACTICE_OWNER' AS NVARCHAR(40)) AS SourceCode,
           CAST(N'Practice' AS NVARCHAR(60))       AS ModuleName,
           CAST(N'Practice Owner' AS NVARCHAR(80)) AS ItemType,
           p.organization_id                        AS OrganizationId,
           p.practice_id                            AS EntityId,
           CAST(p.practice_code + N' - ' + p.practice_name AS NVARCHAR(400)) AS EntityName,
           p.practice_owner_id                      AS CurrentOwnerId,
           CAST(p.practice_owner AS NVARCHAR(240))  AS CurrentOwnerName,
           CAST(0 AS BIT)                           AS IsNameBased
    FROM   grac_practice.practice p
    JOIN   me ON me.employee_id = p.practice_owner_id
    WHERE  p.status = N'Active'

    UNION ALL
    -- Practice instance (primary) owner
    SELECT N'INSTANCE_OWNER', N'Practice', N'Instance Owner',
           pi.organization_id, pi.practice_instance_id,
           CAST(pi.instance_code + N' - ' + pi.instance_name AS NVARCHAR(400)),
           pi.primary_owner_id, CAST(pi.primary_owner AS NVARCHAR(240)), CAST(0 AS BIT)
    FROM   grac_practice.practice_instance pi
    JOIN   me ON me.employee_id = pi.primary_owner_id
    WHERE  pi.status = N'Active'

    UNION ALL
    -- Control statement owner
    SELECT N'STATEMENT_OWNER', N'Control', N'Statement Owner',
           sa.organization_id, sa.organization_statement_applicability_id,
           CAST(N'Statement #' + CAST(sa.framework_statement_id AS NVARCHAR(20)) AS NVARCHAR(400)),
           sa.owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_statement_applicability sa
    JOIN   me ON me.employee_id = sa.owner_id
    WHERE  sa.status = N'Active'

    UNION ALL
    -- Dependency application: business owner
    SELECT N'DEP_APP_BUSINESS', N'Dependencies', N'Application Business Owner',
           a.organization_id, a.application_id, CAST(a.application_name AS NVARCHAR(400)),
           a.business_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_application a
    JOIN   me ON me.employee_id = a.business_owner_id
    WHERE  a.status = N'Active'

    UNION ALL
    -- Dependency application: technical owner
    SELECT N'DEP_APP_TECH', N'Dependencies', N'Application Technical Owner',
           a.organization_id, a.application_id, CAST(a.application_name AS NVARCHAR(400)),
           a.technical_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_application a
    JOIN   me ON me.employee_id = a.technical_owner_id
    WHERE  a.status = N'Active'

    UNION ALL
    -- Dependency tool: business owner
    SELECT N'DEP_TOOL_BUSINESS', N'Dependencies', N'Tool Business Owner',
           t.organization_id, t.tool_id, CAST(t.tool_name AS NVARCHAR(400)),
           t.business_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_tool t
    JOIN   me ON me.employee_id = t.business_owner_id
    WHERE  t.status = N'Active'

    UNION ALL
    -- Dependency vendor: relationship owner
    SELECT N'DEP_VENDOR_REL', N'Dependencies', N'Vendor Relationship Owner',
           v.organization_id, v.vendor_id, CAST(v.vendor_name AS NVARCHAR(400)),
           v.relationship_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_vendor v
    JOIN   me ON me.employee_id = v.relationship_owner_id
    WHERE  v.status = N'Active'

    UNION ALL
    -- Dependency asset: owner
    SELECT N'DEP_ASSET', N'Dependencies', N'Asset Owner',
           s.organization_id, s.asset_id, CAST(s.asset_name AS NVARCHAR(400)),
           s.owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_asset s
    JOIN   me ON me.employee_id = s.owner_id
    WHERE  s.status = N'Active'

    UNION ALL
    -- Dependency process: process owner
    SELECT N'DEP_PROCESS', N'Dependencies', N'Process Owner',
           pr.organization_id, pr.process_id, CAST(pr.process_name AS NVARCHAR(400)),
           pr.process_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_dependency_process pr
    JOIN   me ON me.employee_id = pr.process_owner_id
    WHERE  pr.status = N'Active'

    UNION ALL
    -- Assurance activity owner (Audit) -- active = not soft-deleted
    SELECT N'ASSUR_ACTIVITY', N'Audit', N'Assurance Activity Owner',
           aa.organization_id, aa.assurance_activity_id, CAST(aa.activity_number AS NVARCHAR(400)),
           aa.activity_owner_id, CAST(aa.activity_owner AS NVARCHAR(240)), CAST(0 AS BIT)
    FROM   grac_practice.assurance_activity aa
    JOIN   me ON me.employee_id = aa.activity_owner_id
    WHERE  ISNULL(aa.status, N'') NOT IN (N'Closed', N'Cancelled', N'Completed')
      AND (aa.record_status_id IS NULL OR aa.record_status_id IN
           (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active'))

    UNION ALL
    -- Assurance finding owner (Audit) -- active = not closed
    SELECT N'ASSUR_FINDING', N'Audit', N'Finding Owner',
           af.organization_id, af.finding_id,
           CAST(af.finding_number + N' - ' + af.title AS NVARCHAR(400)),
           af.owner_id, CAST(af.owner_name AS NVARCHAR(240)), CAST(0 AS BIT)
    FROM   grac_practice.assurance_finding af
    JOIN   me ON me.employee_id = af.owner_id
    WHERE  ISNULL(af.finding_status, N'') <> N'Closed'

    UNION ALL
    -- Risk owner (Risk) -- active = not closed/retired
    SELECT N'RISK', N'Risk', N'Risk Owner',
           r.organization_id, r.risk_register_id, CAST(r.risk_title AS NVARCHAR(400)),
           r.risk_owner_employee_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.risk_register r
    JOIN   me ON me.employee_id = r.risk_owner_employee_id
    WHERE  r.status_code NOT IN (N'Closed', N'Retired')

    UNION ALL
    -- Dependency resolution owner
    SELECT N'DEP_RESOLUTION', N'Practice', N'Dependency Resolution Owner',
           dr.organization_id, dr.resolution_id, CAST(dr.resolved_dependency_name AS NVARCHAR(400)),
           dr.resolution_owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.practice_dependency_resolution dr
    JOIN   me ON me.employee_id = dr.resolution_owner_id
    WHERE  dr.is_active = 1

    UNION ALL
    -- Release/subscription owner
    SELECT N'RELEASE_SUB', N'Repository', N'Release Owner',
           rs.organization_id, rs.subscription_id,
           CAST(N'Release subscription #' + CAST(rs.subscription_id AS NVARCHAR(20)) AS NVARCHAR(400)),
           rs.owner_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.repository_subscription rs
    JOIN   me ON me.employee_id = rs.owner_id
    WHERE  rs.status = N'Active'

    UNION ALL
    -- Task assignee (Task) -- active = open (not closed)
    SELECT N'TASK_ASSIGNEE', N'Task', N'Assigned To',
           tk.organization_id, tk.task_id, CAST(tk.subject_title AS NVARCHAR(400)),
           tk.assigned_to_employee_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.practice_task tk
    JOIN   me ON me.employee_id = tk.assigned_to_employee_id
    WHERE  tk.closed_at IS NULL

    UNION ALL
    -- Reporting officer -- this user is another Active user's reporting officer
    SELECT N'REPORTING_OFFICER', N'User', N'Reporting Officer',
           e.organization_id, e.employee_id, CAST(e.employee_name AS NVARCHAR(400)),
           e.reporting_officer_id, NULL, CAST(0 AS BIT)
    FROM   grac_practice.organization_employee e
    JOIN   me ON me.employee_id = e.reporting_officer_id
    WHERE  e.status = N'Active'

    -- ---------------- NAME-based owners ----------------
    UNION ALL
    -- Business function owner
    SELECT N'BIZFUNC', N'Organization', N'Business Function Owner',
           bf.organization_id, bf.business_function_id, CAST(bf.function_name AS NVARCHAR(400)),
           NULL, CAST(bf.owner_name AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.organization_business_function bf
    JOIN   me ON me.organization_id = bf.organization_id AND me.employee_name = bf.owner_name
    WHERE  bf.status = N'Active' AND NULLIF(LTRIM(RTRIM(bf.owner_name)), N'') IS NOT NULL

    UNION ALL
    -- Control primary owner
    SELECT N'CONTROL_PRIMARY', N'Control', N'Primary Owner',
           oc.organization_id, oc.organization_control_id,
           CAST(oc.control_code + N' - ' + oc.control_name AS NVARCHAR(400)),
           NULL, CAST(oc.primary_owner AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.organization_control oc
    JOIN   me ON me.organization_id = oc.organization_id AND me.employee_name = oc.primary_owner
    WHERE  oc.status = N'Active' AND NULLIF(LTRIM(RTRIM(oc.primary_owner)), N'') IS NOT NULL

    UNION ALL
    -- Control secondary owner
    SELECT N'CONTROL_SECONDARY', N'Control', N'Secondary Owner',
           oc.organization_id, oc.organization_control_id,
           CAST(oc.control_code + N' - ' + oc.control_name AS NVARCHAR(400)),
           NULL, CAST(oc.secondary_owner AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.organization_control oc
    JOIN   me ON me.organization_id = oc.organization_id AND me.employee_name = oc.secondary_owner
    WHERE  oc.status = N'Active' AND NULLIF(LTRIM(RTRIM(oc.secondary_owner)), N'') IS NOT NULL

    UNION ALL
    -- Control backup owner
    SELECT N'CONTROL_BACKUP', N'Control', N'Backup Owner',
           oc.organization_id, oc.organization_control_id,
           CAST(oc.control_code + N' - ' + oc.control_name AS NVARCHAR(400)),
           NULL, CAST(oc.backup_owner AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.organization_control oc
    JOIN   me ON me.organization_id = oc.organization_id AND me.employee_name = oc.backup_owner
    WHERE  oc.status = N'Active' AND NULLIF(LTRIM(RTRIM(oc.backup_owner)), N'') IS NOT NULL

    UNION ALL
    -- Practice instance secondary owner (name)
    SELECT N'INSTANCE_SECONDARY', N'Practice', N'Instance Secondary Owner',
           pi.organization_id, pi.practice_instance_id,
           CAST(pi.instance_code + N' - ' + pi.instance_name AS NVARCHAR(400)),
           NULL, CAST(pi.secondary_owner AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.practice_instance pi
    JOIN   me ON me.organization_id = pi.organization_id AND me.employee_name = pi.secondary_owner
    WHERE  pi.status = N'Active' AND NULLIF(LTRIM(RTRIM(pi.secondary_owner)), N'') IS NOT NULL

    UNION ALL
    -- Practice instance dependency owner (name)
    SELECT N'INSTANCE_DEP', N'Practice', N'Dependency Owner',
           d.organization_id, d.dependency_id, CAST(d.dependency_name AS NVARCHAR(400)),
           NULL, CAST(d.owner_name AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.practice_instance_dependency d
    JOIN   me ON me.organization_id = d.organization_id AND me.employee_name = d.owner_name
    WHERE  d.status = N'Active' AND NULLIF(LTRIM(RTRIM(d.owner_name)), N'') IS NOT NULL

    UNION ALL
    -- Evidence configuration owner (name)
    SELECT N'EVIDENCE_CFG', N'Assurance', N'Evidence Owner',
           ec.organization_id, ec.org_assurance_evidence_config_id,
           CAST(ISNULL(ec.evidence_type_name, N'Evidence') AS NVARCHAR(400)),
           NULL, CAST(ec.evidence_owner AS NVARCHAR(240)), CAST(1 AS BIT)
    FROM   grac_practice.org_assurance_evidence_config ec
    JOIN   me ON me.organization_id = ec.organization_id AND me.employee_name = ec.evidence_owner
    WHERE  ec.record_status_id IN
           (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active')
      AND  NULLIF(LTRIM(RTRIM(ec.evidence_owner)), N'') IS NOT NULL
);
GO
PRINT '345: fn_pm_user_ownership ready.';
GO

-- =====================================================================
-- 2. sp_pm_user_ownership_list -- gateway query shim (entity user-ownership)
--    Reads employeeId from the payload (JSON) or the numeric @p_id.
--    7-parameter signature so ResolveProcedureAsync can invoke it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_user_ownership_list
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @employee_id BIGINT =
        COALESCE(
            TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.employeeId'), N'')),
            TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.userId'), N'')),
            NULLIF(@p_id, 0));

    IF @employee_id IS NULL
    BEGIN
        -- No user selected yet: return the empty shape so the grid renders.
        SELECT TOP (0)
               CAST(N'' AS NVARCHAR(40))  AS SourceCode,
               CAST(N'' AS NVARCHAR(60))  AS ModuleName,
               CAST(N'' AS NVARCHAR(80))  AS ItemType,
               CAST(0 AS BIGINT)          AS OrganizationId,
               CAST(0 AS BIGINT)          AS EntityId,
               CAST(N'' AS NVARCHAR(400)) AS EntityName,
               CAST(NULL AS BIGINT)       AS CurrentOwnerId,
               CAST(NULL AS NVARCHAR(240)) AS CurrentOwnerName,
               CAST(0 AS BIT)             AS IsNameBased,
               CAST(N'' AS NVARCHAR(120)) AS OwnershipKey;
        RETURN;
    END

    SELECT o.SourceCode,
           o.ModuleName,
           o.ItemType,
           o.OrganizationId,
           o.EntityId,
           o.EntityName,
           o.CurrentOwnerId,
           o.CurrentOwnerName,
           o.IsNameBased,
           -- Stable key the UI echoes back to reassign a single row.
           CAST(o.SourceCode + N':' + CAST(o.EntityId AS NVARCHAR(20)) AS NVARCHAR(120)) AS OwnershipKey
    FROM   grac_practice.fn_pm_user_ownership(@employee_id) o
    ORDER  BY o.ModuleName, o.ItemType, o.EntityName;
END
GO
PRINT '345: sp_pm_user_ownership_list ready.';
GO

-- =====================================================================
-- 3. sp_pm_user_ownership_reassign -- gateway manage shim
--    Payload: { "items": [ { "sourceCode": "...", "entityId": 123,
--                            "newOwnerId": 456 }, ... ] }
--    One transaction. Every target validated Active + Functional first.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_user_ownership_reassign
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Parse the batch.
    DECLARE @items TABLE (
        rn          INT IDENTITY(1,1) PRIMARY KEY,
        source_code NVARCHAR(40)  NOT NULL,
        entity_id   BIGINT        NOT NULL,
        new_owner_id BIGINT       NOT NULL,
        new_owner_name NVARCHAR(240) NULL
    );

    INSERT INTO @items(source_code, entity_id, new_owner_id)
    SELECT LTRIM(RTRIM(j.sourceCode)), j.entityId, j.newOwnerId
    FROM   OPENJSON(@p_payload, '$.items')
           WITH (sourceCode NVARCHAR(40) '$.sourceCode',
                 entityId    BIGINT      '$.entityId',
                 newOwnerId  BIGINT      '$.newOwnerId') j
    WHERE  j.sourceCode IS NOT NULL AND j.entityId IS NOT NULL AND j.newOwnerId IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @items)
        THROW 51951, N'No ownership reassignments were supplied.', 1;

    -- Validate every target owner: must exist, be Active, and Functional.
    DECLARE @bad_owner BIGINT =
        (SELECT TOP 1 i.new_owner_id
         FROM   @items i
         WHERE  NOT EXISTS (
                    SELECT 1 FROM grac_practice.organization_employee e
                    WHERE  e.employee_id = i.new_owner_id
                      AND  e.status = N'Active'
                      AND  e.is_functional_user = 1));
    IF @bad_owner IS NOT NULL
        THROW 51952, N'A selected new owner is not an active Functional User. Reassignment aborted.', 1;

    -- Fill the denormalised name for each target once.
    UPDATE i
       SET new_owner_name = e.employee_name
    FROM @items i
    JOIN grac_practice.organization_employee e ON e.employee_id = i.new_owner_id;

    BEGIN TRAN;

    -- ---- ID-based updates (owner id, and denormalised name where present) ----
    UPDATE p SET p.practice_owner_id = i.new_owner_id, p.practice_owner = i.new_owner_name,
                 p.updated_by = @p_usr_id, p.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice p
    JOIN @items i ON i.source_code = N'PRACTICE_OWNER' AND i.entity_id = p.practice_id;

    UPDATE pi SET pi.primary_owner_id = i.new_owner_id, pi.primary_owner = i.new_owner_name,
                  pi.updated_by = @p_usr_id, pi.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice_instance pi
    JOIN @items i ON i.source_code = N'INSTANCE_OWNER' AND i.entity_id = pi.practice_instance_id;

    UPDATE sa SET sa.owner_id = i.new_owner_id,
                  sa.updated_by = @p_usr_id, sa.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_statement_applicability sa
    JOIN @items i ON i.source_code = N'STATEMENT_OWNER' AND i.entity_id = sa.organization_statement_applicability_id;

    UPDATE a SET a.business_owner_id = i.new_owner_id,
                 a.updated_by = @p_usr_id, a.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_application a
    JOIN @items i ON i.source_code = N'DEP_APP_BUSINESS' AND i.entity_id = a.application_id;

    UPDATE a SET a.technical_owner_id = i.new_owner_id,
                 a.updated_by = @p_usr_id, a.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_application a
    JOIN @items i ON i.source_code = N'DEP_APP_TECH' AND i.entity_id = a.application_id;

    UPDATE t SET t.business_owner_id = i.new_owner_id,
                 t.updated_by = @p_usr_id, t.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_tool t
    JOIN @items i ON i.source_code = N'DEP_TOOL_BUSINESS' AND i.entity_id = t.tool_id;

    UPDATE v SET v.relationship_owner_id = i.new_owner_id,
                 v.updated_by = @p_usr_id, v.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_vendor v
    JOIN @items i ON i.source_code = N'DEP_VENDOR_REL' AND i.entity_id = v.vendor_id;

    UPDATE s SET s.owner_id = i.new_owner_id,
                 s.updated_by = @p_usr_id, s.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_asset s
    JOIN @items i ON i.source_code = N'DEP_ASSET' AND i.entity_id = s.asset_id;

    UPDATE pr SET pr.process_owner_id = i.new_owner_id,
                  pr.updated_by = @p_usr_id, pr.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_dependency_process pr
    JOIN @items i ON i.source_code = N'DEP_PROCESS' AND i.entity_id = pr.process_id;

    UPDATE aa SET aa.activity_owner_id = i.new_owner_id, aa.activity_owner = i.new_owner_name,
                  aa.updated_by = @p_usr_id, aa.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.assurance_activity aa
    JOIN @items i ON i.source_code = N'ASSUR_ACTIVITY' AND i.entity_id = aa.assurance_activity_id;

    UPDATE af SET af.owner_id = i.new_owner_id, af.owner_name = i.new_owner_name,
                  af.updated_by = @p_usr_id, af.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.assurance_finding af
    JOIN @items i ON i.source_code = N'ASSUR_FINDING' AND i.entity_id = af.finding_id;

    UPDATE r SET r.risk_owner_employee_id = i.new_owner_id,
                 r.updated_by = @p_usr_id, r.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.risk_register r
    JOIN @items i ON i.source_code = N'RISK' AND i.entity_id = r.risk_register_id;

    UPDATE dr SET dr.resolution_owner_id = i.new_owner_id,
                  dr.updated_by = @p_usr_id, dr.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice_dependency_resolution dr
    JOIN @items i ON i.source_code = N'DEP_RESOLUTION' AND i.entity_id = dr.resolution_id;

    UPDATE rs SET rs.owner_id = i.new_owner_id,
                  rs.updated_by = @p_usr_id, rs.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.repository_subscription rs
    JOIN @items i ON i.source_code = N'RELEASE_SUB' AND i.entity_id = rs.subscription_id;

    UPDATE tk SET tk.assigned_to_employee_id = i.new_owner_id
    FROM grac_practice.practice_task tk
    JOIN @items i ON i.source_code = N'TASK_ASSIGNEE' AND i.entity_id = tk.task_id;

    UPDATE e SET e.reporting_officer_id = i.new_owner_id,
                 e.updated_by = @p_usr_id, e.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_employee e
    JOIN @items i ON i.source_code = N'REPORTING_OFFICER' AND i.entity_id = e.employee_id;

    -- ---- NAME-based updates (rewrite the stored employee_name) ----
    UPDATE bf SET bf.owner_name = i.new_owner_name,
                  bf.updated_by = @p_usr_id, bf.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_business_function bf
    JOIN @items i ON i.source_code = N'BIZFUNC' AND i.entity_id = bf.business_function_id;

    UPDATE oc SET oc.primary_owner = i.new_owner_name,
                  oc.updated_by = @p_usr_id, oc.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_control oc
    JOIN @items i ON i.source_code = N'CONTROL_PRIMARY' AND i.entity_id = oc.organization_control_id;

    UPDATE oc SET oc.secondary_owner = i.new_owner_name,
                  oc.updated_by = @p_usr_id, oc.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_control oc
    JOIN @items i ON i.source_code = N'CONTROL_SECONDARY' AND i.entity_id = oc.organization_control_id;

    UPDATE oc SET oc.backup_owner = i.new_owner_name,
                  oc.updated_by = @p_usr_id, oc.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.organization_control oc
    JOIN @items i ON i.source_code = N'CONTROL_BACKUP' AND i.entity_id = oc.organization_control_id;

    UPDATE pi SET pi.secondary_owner = i.new_owner_name,
                  pi.updated_by = @p_usr_id, pi.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice_instance pi
    JOIN @items i ON i.source_code = N'INSTANCE_SECONDARY' AND i.entity_id = pi.practice_instance_id;

    UPDATE d SET d.owner_name = i.new_owner_name,
                 d.updated_by = @p_usr_id, d.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.practice_instance_dependency d
    JOIN @items i ON i.source_code = N'INSTANCE_DEP' AND i.entity_id = d.dependency_id;

    UPDATE ec SET ec.evidence_owner = i.new_owner_name,
                  ec.updated_by = @p_usr_id, ec.updated_dt = SYSUTCDATETIME()
    FROM grac_practice.org_assurance_evidence_config ec
    JOIN @items i ON i.source_code = N'EVIDENCE_CFG' AND i.entity_id = ec.org_assurance_evidence_config_id;

    COMMIT TRAN;

    -- Return a small status result set.
    SELECT (SELECT COUNT(*) FROM @items) AS ReassignedCount,
           N'OK' AS Status;
END
GO
PRINT '345: sp_pm_user_ownership_reassign ready.';
GO

-- =====================================================================
-- 4. Deactivation guard trigger
-- =====================================================================
CREATE OR ALTER TRIGGER grac_practice.tr_pm_org_employee_ownership_deactivate_guard
ON grac_practice.organization_employee
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Maintenance/reset escape hatch (per-connection).
    IF TRY_CONVERT(INT, SESSION_CONTEXT(N'pm_bypass_ownership_guard')) = 1
        RETURN;

    -- Only care about rows transitioning INTO Inactive.
    IF NOT EXISTS (
        SELECT 1
        FROM   inserted i
        JOIN   deleted  d ON d.employee_id = i.employee_id
        WHERE  i.status = N'Inactive' AND d.status <> N'Inactive')
        RETURN;

    IF EXISTS (
        SELECT 1
        FROM   inserted i
        JOIN   deleted  d ON d.employee_id = i.employee_id
        WHERE  i.status = N'Inactive' AND d.status <> N'Inactive'
          AND  EXISTS (SELECT 1 FROM grac_practice.fn_pm_user_ownership(i.employee_id)))
    BEGIN
        THROW 51950,
            N'OWNERSHIP_ACTIVE|This user cannot be deactivated because they are currently assigned as an owner of one or more items. Please reassign the ownership before deactivating the user.',
            1;
    END
END
GO
PRINT '345: tr_pm_org_employee_ownership_deactivate_guard ready.';
GO

-- =====================================================================
-- 5. Menu row: Ownership Management (under the Organization menu group,
--    beside User Management). Idempotent MERGE on menu_key.
-- =====================================================================
MERGE grac_practice.menu_master AS tgt
USING (SELECT N'ownership-management' AS menu_key) AS src
   ON tgt.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
       menu_name    = N'Ownership Management',
       menu_url     = N'Practice/Index/ownership-management',
       display_order= 135,
       icon_class   = N'user-gear',
       module_type  = N'Organization Administration',
       status       = N'Active',
       updated_by   = N'migration-345',
       updated_dt   = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
       (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
 VALUES(N'ownership-management', N'Ownership Management', N'Practice/Index/ownership-management',
        135, N'user-gear', N'Organization Administration', N'Active', N'migration-345');
GO
-- Parent the new row under the same nav group as User Management
-- (nav-administration), so it appears beside it under Organization.
UPDATE m
   SET parent_menu_id = p.menu_id, updated_by = N'migration-345', updated_dt = SYSUTCDATETIME()
FROM grac_practice.menu_master m
JOIN grac_practice.menu_master p ON p.menu_key = N'nav-administration'
WHERE m.menu_key = N'ownership-management';
GO
PRINT '345: ownership-management menu row ready.';
GO

-- Grant VIEW + EDIT on the new screen to every role that already has VIEW on
-- User Management (same roles that manage users manage ownership). Role-scoped
-- (organization_role_menu_permission has no organization_id); record_status_id
-- is required, so it is resolved to the Active master row. Idempotent -- the
-- UNIQUE(role_id,menu_id) constraint plus NOT EXISTS insert only what is missing.
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    DECLARE @own_menu_id   BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'ownership-management');
    DECLARE @users_menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'users');
    DECLARE @active_record_status_id INT =
        (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active' ORDER BY record_status_id);

    IF @own_menu_id IS NOT NULL AND @users_menu_id IS NOT NULL AND @active_record_status_id IS NOT NULL
    BEGIN
        INSERT INTO grac_practice.organization_role_menu_permission
              (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by)
        SELECT rmp.role_id, @own_menu_id,
               1, 1, 1, 0, 0, N'Active', @active_record_status_id, N'migration-345'
        FROM   grac_practice.organization_role_menu_permission rmp
        WHERE  rmp.menu_id = @users_menu_id
          AND  rmp.can_view = 1
          AND  NOT EXISTS (
                   SELECT 1 FROM grac_practice.organization_role_menu_permission x
                   WHERE  x.role_id = rmp.role_id AND x.menu_id = @own_menu_id);
        PRINT '345: ownership-management role permissions seeded from users grants.';
    END
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 345 verification ===';
SELECT '345 objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_user_ownership','IF') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_pm_user_ownership_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_pm_user_ownership_reassign','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.tr_pm_org_employee_ownership_deactivate_guard','TR') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '345 menu row' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'ownership-management')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
