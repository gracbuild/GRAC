/*
  Practice Management -- Scoped Event Assurance UAT diagnostics
  Covers migrations 123 / 124 / 125 / 126.

  Charter §5 forbids modifying existing files in database/deployment/;
  this new higher-numbered file is the extension.
  Charter §9: smoke-test coverage per work item.

  ---------------------------------------------------------------------
  PART A  Static checks   -- objects, columns, seed data. Read-only.
  PART B  Round-trip test -- creates a throwaway checklist, maps it to a
                             real role, raises a real onboarding event,
                             asserts the resolver behaved, then ROLLS
                             EVERYTHING BACK.

  PART B leaves NO data behind. sp_event_instance_raise_scoped opens its
  own BEGIN TRAN/COMMIT TRAN per instance, but those are nested: the inner
  COMMIT only decrements @@TRANCOUNT, so the outer ROLLBACK below undoes
  the lot. Safe to run on UAT repeatedly.

  Prerequisites for PART B (it SKIPs with a reason if unmet):
    * an active organization
    * an employee in that org with an active role assignment
  ---------------------------------------------------------------------
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT '=====================================================================';
PRINT 'PART A -- Static checks';
PRINT '=====================================================================';
GO

--------------------------------------------------------------------
-- A1. Schema objects (123)
--------------------------------------------------------------------
SELECT 'event_mapping_resolution table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'mapping.scope_dimension',        CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension')         IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'mapping.scope_role_id',          CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_role_id')           IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'mapping.scope_asset_category_id',CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','scope_asset_category_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'mapping.release_id',             CASE WHEN COL_LENGTH('grac_practice.event_checklist_mapping','release_id')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'instance.subject_record_id',     CASE WHEN COL_LENGTH('grac_practice.event_instance','subject_record_id')                IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'instance.effective_date',        CASE WHEN COL_LENGTH('grac_practice.event_instance','effective_date')                   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'instance.source_mapping_id',     CASE WHEN COL_LENGTH('grac_practice.event_instance','source_mapping_id')                IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'asset.lifecycle_status',         CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'employee.onboarded_dt',          CASE WHEN COL_LENGTH('grac_practice.organization_employee','onboarded_dt')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- The old natural key MUST be gone, otherwise one checklist cannot be
-- mapped to two roles and the whole feature is inert.
SELECT 'pre-123 natural key dropped' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.key_constraints
                             WHERE name = 'uq_pm_event_checklist_mapping_natural')
            THEN 'PASS' ELSE 'FAIL -- one checklist still cannot map to two roles' END AS Result;

SELECT 'scoped unique index present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'uq_pm_event_checklist_mapping_scoped')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'instance idempotency index present' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'uq_pm_event_instance_open_subject')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

--------------------------------------------------------------------
-- A2. Procedures (124)
--------------------------------------------------------------------
SELECT 'sp_event_instance_raise_scoped'  AS Check_, CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_event_raise_people_lifecycle', CASE WHEN OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_raise_asset_lifecycle',  CASE WHEN OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_scope_mapping_list',     CASE WHEN OBJECT_ID('grac_practice.sp_event_scope_mapping_list','P')     IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_scope_coverage_list',    CASE WHEN OBJECT_ID('grac_practice.sp_event_scope_coverage_list','P')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_checklist_inbox_list',   CASE WHEN OBJECT_ID('grac_practice.sp_event_checklist_inbox_list','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_instance_detail_get',    CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_detail_get','P')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_resolution_trace_list',  CASE WHEN OBJECT_ID('grac_practice.sp_event_resolution_trace_list','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

SELECT 'mapping_save accepts scope params' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_checklist_mapping_save')
                            AND name = '@scope_role_id')
            THEN 'PASS' ELSE 'FAIL -- 124 not applied' END AS Result;
GO

--------------------------------------------------------------------
-- A3. Menu + flags (125)
--------------------------------------------------------------------
SELECT 'scope-mapping menu under nav-workflow' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                         JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                         WHERE c.menu_key = N'workflow-scope-mapping' AND p.menu_key = N'nav-workflow')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'event-inbox menu under nav-workflow',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                         JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                         WHERE c.menu_key = N'workflow-event-inbox' AND p.menu_key = N'nav-workflow')
            THEN 'PASS' ELSE 'FAIL' END;

-- Flags default OFF by design; this reports which orgs have them ON so a
-- tester knows where the screens will actually appear.
SELECT fm.feature_code, ff.organization_id, ff.is_enabled
FROM   grac_practice.feature_flag_master fm
LEFT JOIN grac_practice.feature_flag ff ON ff.feature_flag_id = fm.feature_flag_id
WHERE  fm.feature_code IN (N'screen.workflow-scope-mapping', N'screen.workflow-event-inbox')
ORDER BY fm.feature_code, ff.organization_id;
GO

--------------------------------------------------------------------
-- A4. Baseline seed (126)
--------------------------------------------------------------------
SELECT o.organization_id,
       o.organization_name                                            AS OrganizationName,
       SUM(CASE WHEN ed.event_code = N'PEOPLE_ONBOARDING'     THEN 1 ELSE 0 END) AS PeopleOnboard,
       SUM(CASE WHEN ed.event_code = N'PEOPLE_OFFBOARDING'    THEN 1 ELSE 0 END) AS PeopleOffboard,
       SUM(CASE WHEN ed.event_code = N'ASSET_COMMISSIONING'   THEN 1 ELSE 0 END) AS AssetCommission,
       SUM(CASE WHEN ed.event_code = N'ASSET_DECOMMISSIONING' THEN 1 ELSE 0 END) AS AssetDecommission
FROM   grac_practice.organization o
LEFT JOIN grac_practice.event_definition ed
       ON ed.organization_id = o.organization_id AND ed.status = N'Active'
WHERE  o.status = N'Active'
GROUP BY o.organization_id, o.organization_name
ORDER BY o.organization_id;
GO

--------------------------------------------------------------------
-- A5. Readiness -- what still has to be configured by hand
--------------------------------------------------------------------
SELECT 'organizations with at least one active checklist' AS Check_,
       COUNT(DISTINCT organization_id) AS Count_
FROM   grac_practice.checklist WHERE status = N'Active';

SELECT 'scoped mappings configured' AS Check_, COUNT(*) AS Count_
FROM   grac_practice.event_checklist_mapping
WHERE  scope_dimension IS NOT NULL AND status = N'Active';

SELECT 'roles with NO scoped mapping (coverage gap)' AS Check_, COUNT(*) AS Count_
FROM   grac_practice.organization_role r
WHERE  r.status = N'Active'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_checklist_mapping m
                    WHERE m.scope_role_id = r.role_id AND m.status = N'Active');
GO


PRINT '';
PRINT '=====================================================================';
PRINT 'PART B -- Round-trip test (transactional, rolled back at the end)';
PRINT '=====================================================================';
GO

BEGIN TRAN uat_event_scope;

DECLARE @org        BIGINT,
        @employee   BIGINT,
        @role       BIGINT,
        @entity     BIGINT,
        @event      BIGINT,
        @checklist  BIGINT,
        @checklist2 BIGINT,
        @mapping    BIGINT,
        @mapping2   BIGINT,
        @raised     INT,
        @instance   BIGINT,
        @skip       NVARCHAR(300) = NULL;

-- ---- pick a usable fixture ----------------------------------------
SELECT TOP 1 @org = e.organization_id, @employee = e.employee_id, @role = er.role_id
FROM   grac_practice.organization_employee e
JOIN   grac_practice.organization_employee_role er ON er.employee_id = e.employee_id AND er.status = N'Active'
JOIN   grac_practice.organization_role r           ON r.role_id      = er.role_id    AND r.status  = N'Active'
ORDER BY e.employee_id;

IF @org IS NULL
    SET @skip = N'No employee with an active role assignment exists. Create one, then re-run PART B.';

IF @skip IS NULL
BEGIN
    SELECT @entity = entity_type_id FROM grac_practice.entity_type_master
     WHERE organization_id = @org AND entity_type_code = N'PEOPLE' AND status = N'Active';
    SELECT @event = event_definition_id FROM grac_practice.event_definition
     WHERE organization_id = @org AND event_code = N'PEOPLE_ONBOARDING' AND status = N'Active';

    IF @entity IS NULL OR @event IS NULL
        SET @skip = N'PEOPLE entity type or PEOPLE_ONBOARDING event missing for org '
                  + CAST(@org AS NVARCHAR(20)) + N'. Run migration 126.';
END

IF @skip IS NOT NULL
BEGIN
    SELECT 'PART B' AS Check_, 'SKIPPED' AS Result, @skip AS Detail;
END
ELSE
BEGIN
    SELECT 'Fixture' AS Check_, 'org=' + CAST(@org AS NVARCHAR(20))
           + ' employee=' + CAST(@employee AS NVARCHAR(20))
           + ' role=' + CAST(@role AS NVARCHAR(20)) AS Detail;

    -- ---- throwaway checklist with 2 items (1 mandatory) ------------
    INSERT INTO grac_practice.checklist
        (organization_id, checklist_code, checklist_name, description, version, status, entered_by)
    VALUES (@org, N'UAT_SCOPE_A', N'UAT Onboarding A', N'Created by UAT diagnostics 11.', N'1.0', N'Active', 'uat-11');
    SET @checklist = SCOPE_IDENTITY();

    INSERT INTO grac_practice.checklist_item
        (checklist_id, item_sequence, item_text, item_type, is_mandatory, evidence_required, status, entered_by)
    VALUES (@checklist, 1, N'UAT -- issue laptop',       N'Manual', 1, 0, N'Active', 'uat-11'),
           (@checklist, 2, N'UAT -- optional welcome kit', N'Manual', 0, 0, N'Active', 'uat-11');

    INSERT INTO grac_practice.checklist
        (organization_id, checklist_code, checklist_name, description, version, status, entered_by)
    VALUES (@org, N'UAT_SCOPE_B', N'UAT Onboarding B', N'Created by UAT diagnostics 11.', N'1.0', N'Active', 'uat-11');
    SET @checklist2 = SCOPE_IDENTITY();

    INSERT INTO grac_practice.checklist_item
        (checklist_id, item_sequence, item_text, item_type, is_mandatory, evidence_required, status, entered_by)
    VALUES (@checklist2, 1, N'UAT -- should NOT appear', N'Manual', 1, 0, N'Active', 'uat-11');

    -- ---- map A to the employee's role, B to a role they do NOT hold -
    EXEC grac_practice.sp_event_checklist_mapping_save
         @organization_id = @org, @entity_type_id = @entity,
         @event_definition_id = @event, @checklist_id = @checklist,
         @default_due_period_days = 3,
         @scope_dimension = N'ORG_ROLE', @scope_role_id = @role,
         @actor_employee_id = NULL, @out_mapping_id = @mapping OUTPUT;

    DECLARE @other_role BIGINT = (
        SELECT TOP 1 role_id FROM grac_practice.organization_role
         WHERE organization_id = @org AND status = N'Active' AND role_id <> @role
         ORDER BY role_id);

    IF @other_role IS NOT NULL
        EXEC grac_practice.sp_event_checklist_mapping_save
             @organization_id = @org, @entity_type_id = @entity,
             @event_definition_id = @event, @checklist_id = @checklist2,
             @scope_dimension = N'ORG_ROLE', @scope_role_id = @other_role,
             @actor_employee_id = NULL, @out_mapping_id = @mapping2 OUTPUT;

    -- ================= TEST 1 : scoped raise =======================
    EXEC grac_practice.sp_event_raise_people_lifecycle
         @organization_id = @org, @employee_id = @employee,
         @lifecycle_action = N'ONBOARD', @effective_date = '2026-01-15',
         @actor_employee_id = NULL, @out_raised_count = @raised OUTPUT;

    SELECT 'T1 raise produced exactly 1 instance' AS Check_,
           CASE WHEN @raised = 1 THEN 'PASS' ELSE 'FAIL (got ' + CAST(@raised AS NVARCHAR(10)) + ')' END AS Result;

    SELECT @instance = event_instance_id
    FROM   grac_practice.event_instance
    WHERE  organization_id = @org AND subject_entity = N'EMPLOYEE'
      AND  subject_record_id = @employee AND source_mapping_id = @mapping;

    SELECT 'T2 instance items materialised (2)' AS Check_,
           CASE WHEN (SELECT COUNT(*) FROM grac_practice.event_instance_item
                       WHERE event_instance_id = @instance) = 2
                THEN 'PASS' ELSE 'FAIL' END AS Result;

    -- SLA runs from the effective date, not from today.
    SELECT 'T3 due date = effective + 3 days' AS Check_,
           CASE WHEN (SELECT due_date FROM grac_practice.event_instance
                       WHERE event_instance_id = @instance) = '2026-01-18'
                THEN 'PASS' ELSE 'FAIL' END AS Result;

    SELECT 'T4 role snapshot captured' AS Check_,
           CASE WHEN (SELECT scope_role_id FROM grac_practice.event_instance
                       WHERE event_instance_id = @instance) = @role
                THEN 'PASS' ELSE 'FAIL' END AS Result;

    -- ================= TEST 2 : scope isolation ====================
    IF @other_role IS NOT NULL
        SELECT 'T5 other role''s checklist excluded' AS Check_,
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_mapping_resolution
                                  WHERE subject_record_id = @employee
                                    AND mapping_id = @mapping2
                                    AND decision = N'Excluded'
                                    AND reason_code = N'ScopeMismatch')
                    THEN 'PASS' ELSE 'FAIL' END AS Result;
    ELSE
        SELECT 'T5 other role''s checklist excluded' AS Check_, 'SKIPPED (org has only one role)' AS Result;

    SELECT 'T6 inclusion reason recorded' AS Check_,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_mapping_resolution
                              WHERE event_instance_id = @instance
                                AND decision = N'Included' AND reason_code = N'ScopeMatched')
                THEN 'PASS' ELSE 'FAIL' END AS Result;

    -- ================= TEST 3 : idempotency ========================
    EXEC grac_practice.sp_event_raise_people_lifecycle
         @organization_id = @org, @employee_id = @employee,
         @lifecycle_action = N'ONBOARD', @effective_date = '2026-01-15',
         @actor_employee_id = NULL, @out_raised_count = @raised OUTPUT;

    SELECT 'T7 second raise creates nothing' AS Check_,
           CASE WHEN @raised = 0 THEN 'PASS' ELSE 'FAIL (got ' + CAST(@raised AS NVARCHAR(10)) + ')' END AS Result;

    SELECT 'T8 duplicate recorded as AlreadyOpen' AS Check_,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_mapping_resolution
                              WHERE subject_record_id = @employee AND mapping_id = @mapping
                                AND reason_code = N'AlreadyOpen')
                THEN 'PASS' ELSE 'FAIL' END AS Result;

    -- ================= TEST 4 : release filter =====================
    -- There is no grac_practice.release table -- release_id is a soft
    -- reference into the admin repository (GRAC_New). So rather than
    -- looking one up, use a sentinel that provably sits outside every
    -- subscription this org holds.
    DECLARE @unsub BIGINT = ISNULL(
        (SELECT MAX(release_id) FROM grac_practice.repository_subscription), 0) + 999;

    IF @unsub IS NOT NULL
    BEGIN
        -- Written directly: sp_..._save rejects an unsubscribed release by
        -- design, so the row is planted to prove the RESOLVER also filters.
        UPDATE grac_practice.event_checklist_mapping
           SET release_id = @unsub WHERE mapping_id = @mapping;

        DELETE FROM grac_practice.event_instance_item
         WHERE event_instance_id = @instance;
        DELETE FROM grac_practice.event_mapping_resolution
         WHERE event_instance_id = @instance;
        DELETE FROM grac_practice.event_instance
         WHERE event_instance_id = @instance;

        EXEC grac_practice.sp_event_instance_raise_scoped
             @organization_id = @org, @event_definition_id = @event,
             @subject_entity = N'EMPLOYEE', @subject_record_id = @employee,
             @effective_date = '2026-02-01', @out_raised_count = @raised OUTPUT;

        SELECT 'T9 unsubscribed release excluded' AS Check_,
               CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_mapping_resolution
                                  WHERE subject_record_id = @employee AND mapping_id = @mapping
                                    AND reason_code = N'ReleaseNotSubscribed')
                    THEN 'PASS' ELSE 'FAIL' END AS Result;
    END

    -- ================= TEST 5 : read paths =========================
    PRINT '--- sp_event_checklist_inbox_list ---';
    EXEC grac_practice.sp_event_checklist_inbox_list @organization_id = @org;

    PRINT '--- sp_event_resolution_trace_list (subject) ---';
    EXEC grac_practice.sp_event_resolution_trace_list
         @organization_id = @org, @subject_entity = N'EMPLOYEE', @subject_record_id = @employee;

    PRINT '--- sp_event_scope_coverage_list (ORG_ROLE) ---';
    EXEC grac_practice.sp_event_scope_coverage_list
         @organization_id = @org, @scope_dimension = N'ORG_ROLE';
END

ROLLBACK TRAN uat_event_scope;
GO

SELECT 'PART B cleaned up' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.checklist WHERE entered_by = 'uat-11')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.event_instance WHERE entered_by = 'uat-11')
            THEN 'PASS -- no UAT rows left behind' ELSE 'FAIL -- manual cleanup needed' END AS Result;

PRINT '11 Scoped Event Assurance UAT diagnostics complete.';
GO
