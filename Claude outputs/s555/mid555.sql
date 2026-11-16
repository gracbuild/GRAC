
-- =====================================================================
-- 7. sp_org_assurance_my_audits_prepare -- start the auditor's due
--    engagements (From <= today). One engagement failing (e.g. an audit
--    lost its Active version) is reported and the others still start.
--    Result: one row per engagement tried.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audits_prepare
    @employee_id BIGINT,
    @actor       NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @due TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, organization_id BIGINT NOT NULL,
                        plan_id BIGINT NOT NULL, plan_item_id BIGINT NOT NULL,
                        engagement_code NVARCHAR(80) NULL);
    INSERT INTO @due (organization_id, plan_id, plan_item_id, engagement_code)
    SELECT i.organization_id, i.org_assurance_plan_id, i.org_assurance_plan_item_id, i.engagement_code
      FROM grac_practice.org_assurance_plan_item i
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active = 1
       AND p.is_active = 1
       AND ps.status_code IN (N'Approved', N'Active')
       AND i.scheduled_from IS NOT NULL
       AND i.scheduled_from <= @today
       -- an audit of the engagement that can start and has not (the
       -- start procedure's own rule)
       AND EXISTS (
            SELECT 1
              FROM grac_practice.org_assurance_engagement_definition ed
              JOIN grac_practice.org_assurance_definition d
                   ON d.org_assurance_definition_id = ed.org_assurance_definition_id
              JOIN grac_practice.org_assurance_status_master s
                   ON s.org_assurance_status_id = d.current_status_id
             WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
               AND ed.is_active = 1
               AND d.active_version_id IS NOT NULL
               AND s.status_code <> N'Retired'
               AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                                 JOIN grac_practice.org_assurance_execution_status_master es
                                      ON es.org_assurance_execution_status_id = e.execution_status_id
                                WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
                                  AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                                  AND e.is_active = 1 AND es.status_code <> N'Cancelled'))
     ORDER BY i.scheduled_from, i.org_assurance_plan_item_id;

    DECLARE @out TABLE (plan_item_id BIGINT, engagement_code NVARCHAR(80), started BIT, message NVARCHAR(2048));
    DECLARE @n INT = 1, @max INT = ISNULL((SELECT MAX(rn) FROM @due), 0),
            @org BIGINT, @plan BIGINT, @item BIGINT, @code NVARCHAR(80), @eid BIGINT;
    WHILE @n <= @max
    BEGIN
        SELECT @org = organization_id, @plan = plan_id, @item = plan_item_id, @code = engagement_code
          FROM @due WHERE rn = @n;
        BEGIN TRY
            SET @eid = NULL;
            EXEC grac_practice.sp_org_assurance_plan_item_start_execution
                 @organization_id  = @org,
                 @plan_id          = @plan,
                 @plan_item_id     = @item,
                 @actor            = @actor,
                 @suppress_result  = 1,
                 @execution_id_out = @eid OUTPUT;
            INSERT INTO @out VALUES (@item, @code, 1, NULL);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            INSERT INTO @out VALUES (@item, @code, 0, ERROR_MESSAGE());
        END CATCH
        SET @n += 1;
    END

    SELECT plan_item_id AS PlanItemId, engagement_code AS EngagementCode,
           started AS Started, message AS Message
      FROM @out;
END
GO

-- =====================================================================
-- 8. sp_org_assurance_my_audit_list -- the auditor's audits: one row per
--    audit of each engagement assigned to them (plan Approved / Active /
--    Closed), with its latest execution and state.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audit_list
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);

    SELECT i.organization_id               AS OrganizationId,
           o.organization_name             AS OrganizationName,
           p.org_assurance_plan_id         AS PlanId,
           p.plan_code                     AS PlanCode,
           p.plan_name                     AS PlanName,
           i.org_assurance_plan_item_id    AS PlanItemId,
           i.engagement_code               AS EngagementCode,
           i.engagement_name               AS EngagementName,
           i.assigned_branch_id            AS BranchId,
           i.assigned_branch_name          AS BranchName,
           i.scheduled_from                AS ScheduledFrom,
           i.scheduled_to                  AS ScheduledTo,
           d.org_assurance_definition_id   AS DefinitionId,
           d.definition_code               AS DefinitionCode,
           d.definition_name               AS DefinitionName,
           ex.org_assurance_execution_id   AS ExecutionId,
           ex.execution_code               AS ExecutionCode,
           ex.status_code                  AS ExecutionStatusCode,
           ex.status_name                  AS ExecutionStatusName,
           ex.scope_frozen_at              AS ScopeFrozenAt,
           ex.total_entity_count           AS TotalEntityCount,
           ex.completed_entity_count       AS CompletedEntityCount,
           CASE WHEN ex.org_assurance_execution_id IS NULL
                     THEN CASE WHEN i.scheduled_from > @today THEN N'Upcoming' ELSE N'Ready' END
                WHEN ex.status_code = N'Cancelled'    THEN N'Cancelled'
                WHEN ex.scope_frozen_at IS NULL       THEN N'ScopeLive'
                WHEN ex.status_code IN (N'Planned', N'InProgress') THEN N'InProgress'
                ELSE N'Done' END           AS AuditState
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_plan_item i
           ON i.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.organization o
           ON o.organization_id = i.organization_id
      OUTER APPLY (
          SELECT TOP 1 e.org_assurance_execution_id, e.execution_code, es.status_code, es.status_name,
                       e.scope_frozen_at, e.total_entity_count, e.completed_entity_count
            FROM grac_practice.org_assurance_execution e
            JOIN grac_practice.org_assurance_execution_status_master es
                 ON es.org_assurance_execution_status_id = e.execution_status_id
           WHERE e.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
             AND e.org_assurance_definition_id = ed.org_assurance_definition_id
             AND e.is_active = 1
           ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                    e.org_assurance_execution_id DESC) ex
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active  = 1
       AND ed.is_active = 1
       AND p.is_active  = 1
       AND ps.status_code IN (N'Approved', N'Active', N'Closed')
     ORDER BY i.scheduled_from, i.engagement_code, ed.display_order, ed.org_assurance_engagement_definition_id;
END
GO

-- =====================================================================
-- 9. sp_org_assurance_execution_live_scope -- what Freeze would take now:
--    the audit's scope resolved (PREVIEW, inside a transaction that is
--    rolled back -- nothing saved) and narrowed to the engagement's
--    Branch. A frozen execution returns its frozen entities.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_live_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @frozen DATETIME2;
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @frozen = e.scope_frozen_at
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    IF @frozen IS NOT NULL
    BEGIN
        SELECT ee.dimension_code AS DimensionCode, ee.dimension_name AS DimensionName,
               ee.entity_id AS EntityId, ee.entity_code AS EntityCode, ee.entity_name AS EntityName
          FROM grac_practice.org_assurance_execution_entity ee
         WHERE ee.org_assurance_execution_id = @execution_id
           AND ee.organization_id = @organization_id
           AND ee.is_active = 1
         ORDER BY ee.dimension_code, ee.entity_name, ee.entity_code;
        RETURN;
    END

    DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                               WHERE org_assurance_plan_item_id = @item);
    DECLARE @ents TABLE (dimension_code NVARCHAR(60) NULL, dimension_name NVARCHAR(160) NULL,
                         entity_id BIGINT NULL, entity_code NVARCHAR(120) NULL, entity_name NVARCHAR(240) NULL);
    DECLARE @res BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_org_assurance_scope_resolve
         @organization_id    = @organization_id,
         @definition_id      = @def,
         @version_id         = @ver,
         @resolution_purpose = N'PREVIEW',
         @execution_id       = NULL,
         @actor              = @actor,
         @resolution_id_out  = @res OUTPUT;
    IF @branch IS NOT NULL
        EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
             @organization_id = @organization_id,
             @resolution_id   = @res,
             @location_id     = @branch;
    INSERT INTO @ents (dimension_code, dimension_name, entity_id, entity_code, entity_name)
    SELECT DISTINCT r.dimension_code, r.dimension_name, r.entity_id, r.entity_code, r.entity_name
      FROM grac_practice.org_assurance_scope_resolution_entity r
     WHERE r.org_assurance_scope_resolution_id = @res;
    ROLLBACK;   -- live: nothing the resolver wrote is kept

    SELECT dimension_code AS DimensionCode, dimension_name AS DimensionName,
           entity_id AS EntityId, entity_code AS EntityCode, entity_name AS EntityName
      FROM @ents
     ORDER BY dimension_code, entity_name, entity_code;
END
GO

-- =====================================================================
-- 10. sp_org_assurance_execution_freeze_scope -- the assigned auditor
--     freezes the live scope: resolve (EXECUTION), narrow to the Branch,
--     drop and record the exclusions (each with a reason), copy the
--     entities, Planned -> In Progress. Final (decision: no unfreeze).
--     @exclusions_json: [{"dimensionCode":"ASSET","entityId":12,"reason":"..."}]
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_freeze_scope
    @organization_id BIGINT,
    @execution_id    BIGINT,
    @employee_id     BIGINT,
    @exclusions_json NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;
    IF @employee_id IS NULL
        THROW 54036, 'Sign in as the assigned auditor to freeze the scope.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @item BIGINT, @owner BIGINT,
            @frozen DATETIME2, @status NVARCHAR(60);
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @item   = e.org_assurance_plan_item_id,
           @owner  = e.owner_employee_id,
           @frozen = e.scope_frozen_at,
           @status = s.status_code
      FROM grac_practice.org_assurance_execution e
      JOIN grac_practice.org_assurance_execution_status_master s
           ON s.org_assurance_execution_status_id = e.execution_status_id
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @frozen IS NOT NULL
        THROW 54031, 'The scope of this execution is already frozen.', 1;
    IF @owner IS NULL OR @owner <> @employee_id
        THROW 54032, 'Only the assigned auditor can freeze the scope.', 1;
    IF @status <> N'Planned'
        THROW 54033, 'The scope can be frozen only while the execution is Planned.', 1;

    DECLARE @excl TABLE (dimension_code NVARCHAR(60) NULL, entity_id BIGINT NULL, reason NVARCHAR(1000) NULL);
    IF @exclusions_json IS NOT NULL AND ISJSON(@exclusions_json) = 1
        INSERT INTO @excl (dimension_code, entity_id, reason)
        SELECT x.dimension_code, x.entity_id, MAX(x.reason)
          FROM (SELECT NULLIF(LTRIM(RTRIM(JSON_VALUE(j.[value], '$.dimensionCode'))), N'') AS dimension_code,
                       TRY_CAST(JSON_VALUE(j.[value], '$.entityId') AS BIGINT)            AS entity_id,
                       LEFT(NULLIF(LTRIM(RTRIM(JSON_VALUE(j.[value], '$.reason'))), N''), 1000) AS reason
                  FROM OPENJSON(@exclusions_json) j) x
         GROUP BY x.dimension_code, x.entity_id;
    IF EXISTS (SELECT 1 FROM @excl WHERE dimension_code IS NULL OR entity_id IS NULL OR reason IS NULL)
        THROW 54034, 'Every excluded item needs a reason.', 1;

    DECLARE @branch BIGINT = (SELECT assigned_branch_id FROM grac_practice.org_assurance_plan_item
                               WHERE org_assurance_plan_item_id = @item);
    DECLARE @res BIGINT, @total BIGINT, @summary NVARCHAR(MAX);

    BEGIN TRAN;

    EXEC grac_practice.sp_org_assurance_scope_resolve
         @organization_id    = @organization_id,
         @definition_id      = @def,
         @version_id         = @ver,
         @resolution_purpose = N'EXECUTION',
         @execution_id       = @execution_id,
         @actor              = @actor,
         @resolution_id_out  = @res OUTPUT;
    IF @branch IS NOT NULL
        EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
             @organization_id = @organization_id,
             @resolution_id   = @res,
             @location_id     = @branch;

    IF EXISTS (SELECT 1 FROM @excl x
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity r
                                   WHERE r.org_assurance_scope_resolution_id = @res
                                     AND r.dimension_code = x.dimension_code
                                     AND r.entity_id      = x.entity_id))
        THROW 54034, 'An excluded item is no longer in the scope. Reload the scope and try again.', 1;

    INSERT INTO grac_practice.org_assurance_execution_scope_exclusion
        (organization_id, org_assurance_execution_id, dimension_code, dimension_name,
         entity_id, entity_code, entity_name, reason, entered_by)
    SELECT @organization_id, @execution_id, x.dimension_code, r.dimension_name,
           x.entity_id, r.entity_code, r.entity_name, x.reason, @actor
      FROM @excl x
      CROSS APPLY (SELECT TOP 1 re.dimension_name, re.entity_code, re.entity_name
                     FROM grac_practice.org_assurance_scope_resolution_entity re
                    WHERE re.org_assurance_scope_resolution_id = @res
                      AND re.dimension_code = x.dimension_code
                      AND re.entity_id      = x.entity_id) r;

    DELETE r
      FROM grac_practice.org_assurance_scope_resolution_entity r
      JOIN @excl x ON x.dimension_code = r.dimension_code AND x.entity_id = r.entity_id
     WHERE r.org_assurance_scope_resolution_id = @res;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity
                    WHERE org_assurance_scope_resolution_id = @res)
        THROW 54035, 'Nothing is left in the scope. Keep at least one item, or cancel the execution.', 1;

    SET @summary = (SELECT dimension_code AS dimensionCode, COUNT(*) AS entityCount
                      FROM grac_practice.org_assurance_scope_resolution_entity
                     WHERE org_assurance_scope_resolution_id = @res
                     GROUP BY dimension_code
                     ORDER BY dimension_code
                       FOR JSON PATH);
    SET @total = (SELECT COUNT_BIG(*) FROM grac_practice.org_assurance_scope_resolution_entity
                   WHERE org_assurance_scope_resolution_id = @res);
    UPDATE grac_practice.org_assurance_scope_resolution
       SET total_entity_count = @total, summary_json = @summary, execution_id = @execution_id
     WHERE org_assurance_scope_resolution_id = @res;

    -- The entities, as materialize copies them.
    INSERT INTO grac_practice.org_assurance_execution_entity(
        org_assurance_execution_id, organization_id,
        dimension_code, dimension_name,
        entity_id, entity_code, entity_name,
        source_group_order, source_condition_order,
        entity_status_code, is_active, entered_by, entered_dt)
    SELECT @execution_id, @organization_id,
           r.dimension_code, r.dimension_name,
           r.entity_id, r.entity_code, r.entity_name,
           r.source_group_order, r.source_condition_order,
           N'NotStarted', 1, @actor, SYSUTCDATETIME()
      FROM grac_practice.org_assurance_scope_resolution_entity r
     WHERE r.org_assurance_scope_resolution_id = @res
       AND r.organization_id = @organization_id;

    UPDATE grac_practice.org_assurance_execution
       SET org_assurance_scope_resolution_id = @res,
           total_entity_count = (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_execution_entity
                                  WHERE org_assurance_execution_id = @execution_id AND is_active = 1),
           scope_frozen_at    = SYSUTCDATETIME(),
           scope_frozen_by    = @actor,
           updated_by         = @actor,
           updated_dt         = SYSUTCDATETIME()
     WHERE org_assurance_execution_id = @execution_id;

    -- Freezing starts the audit.
    EXEC grac_practice.sp_org_assurance_execution_transition
         @organization_id     = @organization_id,
         @execution_id        = @execution_id,
         @expected_from_codes = N'Planned',
         @to_code             = N'InProgress',
         @stamp_start         = 1,
         @stamp_end           = 0,
         @actor               = @actor;

    COMMIT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.total_entity_count         AS TotalEntityCount,
           (SELECT COUNT(*) FROM @excl)  AS ExcludedCount
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id;
END
GO

-- =====================================================================
-- 11. sp_org_assurance_execution_scope_exclusion_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_scope_exclusion_list
    @organization_id BIGINT,
    @execution_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    SELECT x.dimension_code AS DimensionCode, x.dimension_name AS DimensionName,
           x.entity_id AS EntityId, x.entity_code AS EntityCode, x.entity_name AS EntityName,
           x.reason AS Reason, x.entered_by AS EnteredBy, x.entered_dt AS EnteredDt
      FROM grac_practice.org_assurance_execution_scope_exclusion x
     WHERE x.org_assurance_execution_id = @execution_id
       AND x.organization_id = @organization_id
     ORDER BY x.dimension_code, x.entity_name;
END
GO
