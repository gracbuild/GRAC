-- =====================================================================
-- 131 Event Assurance -- people auto-raise, role resolution fix,
--     obligation-aware inbox counts
--
-- SYMPTOM
-- -------
-- "I added an Admin employee but nothing appeared in the Event Checklist
-- Inbox."
--
-- THREE SEPARATE CAUSES
-- ---------------------
-- 1. NOTHING RAISES THE EVENT. There is no auto-raise anywhere on the org
--    side. ControlManagement 037 installed a trigger, but on GRAC_New.cm_user
--    -- the admin user register -- not on grac_practice.organization_employee.
--    So the only way to produce an onboarding checklist was the manual
--    "Raise Event" button.
--
-- 2. THE RESOLVER LOOKED IN THE WRONG PLACE FOR THE ROLE.
--    organization_employee has its OWN role_id column (added by migration
--    002, FK fk_pm_employee_role) -- that is what the Employee form writes
--    when you pick "Admin". organization_employee_role is a separate
--    many-to-many table populated by the User Role Assignment screen.
--    128/129 read only the M:N table, so an employee created through the
--    Employee form had, as far as the resolver could see, no role at all --
--    and a subject with no role yields SubjectScopeMissing and no checklist.
--    Even a manual raise would have produced nothing.
--
-- 3. THE INBOX COUNTED THE WRONG ITEMS. sp_event_checklist_inbox_list
--    computes progress from event_instance_item only. Obligation-origin
--    instances keep their line items in event_instance_obligation, so they
--    would have shown 0 / 0.
--
-- WHY THE TRIGGER ONLY ENQUEUES
-- -----------------------------
-- ControlManagement 037 documents the constraint precisely: callers run with
-- XACT_ABORT ON, so an error raised inside a trigger dooms the outer
-- transaction whether or not it is caught. TRY/CATCH is not protection. A
-- trigger sitting in the write path of employee creation therefore must be
-- INCAPABLE of failing.
--
-- sp_event_obligation_raise can throw -- it validates the event type, the
-- subject and the event_definition. Calling it from a trigger would put a
-- compliance-configuration problem in the way of an administrator creating
-- an employee. So the trigger does one guarded INSERT into a queue and
-- nothing else: no THROW, no cast, no arithmetic, resolution by JOIN so a
-- missing row yields no rows rather than an error.
--
-- WHY IT FIRES ON THE ROLE, NOT ON THE EMPLOYEE
-- ---------------------------------------------
-- Onboarding obligations are scoped BY ROLE. An employee created without a
-- role cannot resolve to anything. Both paths are covered: the employee
-- trigger enqueues only when role_id is already set on the row, and the
-- employee_role trigger enqueues when the first role is assigned later.
-- The queue is keyed so the same employee cannot be enqueued twice while
-- one entry is still pending.
--
-- Objects:
--   * grac_practice.event_autoraise_queue        (NEW)
--   * grac_practice.tr_pm_employee_autoraise     (NEW)
--   * grac_practice.tr_pm_employee_role_autoraise(NEW)
--   * grac_practice.sp_event_autoraise_drain     (NEW)
--   * grac_practice.fn_pm_employee_role_ids      (NEW -- both role sources)
--   * sp_event_obligation_raise                  (ALTERED -- uses the fn)
--   * sp_event_instance_raise_scoped             (ALTERED -- uses the fn)
--   * sp_event_checklist_inbox_list              (ALTERED -- obligation counts)
--
-- Depends on 123, 124, 126, 127, 128, 129.
-- Rollback: 131_event_people_autoraise_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL
   OR OBJECT_ID('grac_practice.event_instance_obligation','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','role_id') IS NULL
BEGIN
    RAISERROR('131: prerequisites missing (run 127/128 and confirm organization_employee.role_id).', 16, 1);
    SET NOEXEC ON;
END
GO


-- =====================================================================
-- 1. fn_pm_employee_role_ids -- the single source of truth for "which
--    roles does this employee hold?"
--
--    Both places a role can live, unioned and de-duplicated. Every
--    resolver now calls this instead of hand-writing the join, so the two
--    sources can never diverge again.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_employee_role_ids
(
    @employee_id BIGINT
)
RETURNS TABLE
AS
RETURN
    -- Primary role from the Employee form.
    SELECT r.role_id, r.role_name
    FROM   grac_practice.organization_employee e
    JOIN   grac_practice.organization_role r ON r.role_id = e.role_id
    WHERE  e.employee_id = @employee_id
      AND  r.status = N'Active'
    UNION
    -- Additional roles from the User Role Assignment screen.
    SELECT r.role_id, r.role_name
    FROM   grac_practice.organization_employee_role er
    JOIN   grac_practice.organization_role r ON r.role_id = er.role_id
    WHERE  er.employee_id = @employee_id
      AND  er.status = N'Active'
      AND  r.status  = N'Active';
GO


-- =====================================================================
-- 2. event_autoraise_queue
--
--    Deliberately minimal: the trigger must be able to write it with a
--    single INSERT..SELECT that cannot fail. No FK to organization (the
--    employee row is being written in the same transaction), no CHECK
--    constraints, no defaults that could conflict.
-- =====================================================================
IF OBJECT_ID('grac_practice.event_autoraise_queue','U') IS NULL
CREATE TABLE grac_practice.event_autoraise_queue(
    queue_id          BIGINT        IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_event_autoraise_queue PRIMARY KEY,
    organization_id   BIGINT        NOT NULL,
    subject_entity    NVARCHAR(60)  NOT NULL,       -- EMPLOYEE / ASSET
    subject_record_id BIGINT        NOT NULL,
    event_code        NVARCHAR(60)  NOT NULL,       -- PEOPLE_ONBOARDING ...
    effective_date    DATE          NULL,
    source            NVARCHAR(60)  NULL,           -- which trigger enqueued it
    status            NVARCHAR(20)  NOT NULL
        CONSTRAINT df_pm_event_autoraise_status DEFAULT N'Pending',
    attempt_count     INT           NOT NULL
        CONSTRAINT df_pm_event_autoraise_attempts DEFAULT 0,
    last_error        NVARCHAR(MAX) NULL,
    raised_count      INT           NULL,
    enqueued_dt       DATETIME2     NOT NULL
        CONSTRAINT df_pm_event_autoraise_enq DEFAULT SYSUTCDATETIME(),
    processed_dt      DATETIME2     NULL
);
GO

-- One pending entry per subject + event. The filter is what makes the
-- trigger safe to fire repeatedly.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'uq_pm_event_autoraise_pending'
                 AND object_id = OBJECT_ID('grac_practice.event_autoraise_queue'))
    CREATE UNIQUE INDEX uq_pm_event_autoraise_pending
        ON grac_practice.event_autoraise_queue(
            organization_id, subject_entity, subject_record_id, event_code)
        WHERE status = N'Pending';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_event_autoraise_drain'
                 AND object_id = OBJECT_ID('grac_practice.event_autoraise_queue'))
    CREATE INDEX ix_pm_event_autoraise_drain
        ON grac_practice.event_autoraise_queue(status, enqueued_dt)
        INCLUDE (organization_id, subject_entity, subject_record_id, event_code, effective_date);
GO


-- =====================================================================
-- 3. Triggers. Every statement below is guarded so the body cannot raise.
-- =====================================================================
CREATE OR ALTER TRIGGER grac_practice.tr_pm_employee_autoraise
ON grac_practice.organization_employee
AFTER INSERT
NOT FOR REPLICATION
AS
BEGIN
    SET NOCOUNT ON;

    -- Only employees that already carry a role: without one the resolver
    -- has nothing to scope against. The employee_role trigger covers the
    -- case where the role arrives later.
    INSERT INTO grac_practice.event_autoraise_queue
        (organization_id, subject_entity, subject_record_id, event_code,
         effective_date, source, status)
    SELECT i.organization_id, N'EMPLOYEE', i.employee_id, N'PEOPLE_ONBOARDING',
           COALESCE(i.onboarded_dt, CAST(i.entered_dt AS DATE)),
           N'tr_pm_employee_autoraise', N'Pending'
    FROM   inserted i
    WHERE  i.role_id IS NOT NULL
      AND  i.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_autoraise_queue q
                        WHERE q.organization_id   = i.organization_id
                          AND q.subject_entity    = N'EMPLOYEE'
                          AND q.subject_record_id = i.employee_id
                          AND q.event_code        = N'PEOPLE_ONBOARDING'
                          AND q.status            = N'Pending');
END;
GO

CREATE OR ALTER TRIGGER grac_practice.tr_pm_employee_role_autoraise
ON grac_practice.organization_employee_role
AFTER INSERT
NOT FOR REPLICATION
AS
BEGIN
    SET NOCOUNT ON;

    -- Only when this is the employee's FIRST active role. A second role
    -- assignment is not a second onboarding.
    INSERT INTO grac_practice.event_autoraise_queue
        (organization_id, subject_entity, subject_record_id, event_code,
         effective_date, source, status)
    SELECT e.organization_id, N'EMPLOYEE', e.employee_id, N'PEOPLE_ONBOARDING',
           COALESCE(e.onboarded_dt, CAST(e.entered_dt AS DATE)),
           N'tr_pm_employee_role_autoraise', N'Pending'
    FROM   inserted i
    JOIN   grac_practice.organization_employee e ON e.employee_id = i.employee_id
    WHERE  i.status = N'Active'
      AND  e.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_autoraise_queue q
                        WHERE q.organization_id   = e.organization_id
                          AND q.subject_entity    = N'EMPLOYEE'
                          AND q.subject_record_id = e.employee_id
                          AND q.event_code        = N'PEOPLE_ONBOARDING'
                          AND q.status            = N'Pending')
      -- Already onboarded once -> not again. Re-onboarding a rehire goes
      -- through the manual Raise Event path, deliberately, because it needs
      -- a human to confirm the effective date.
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                        WHERE ei.organization_id   = e.organization_id
                          AND ei.subject_entity    = N'EMPLOYEE'
                          AND ei.subject_record_id = e.employee_id)
    GROUP BY e.organization_id, e.employee_id, e.onboarded_dt, e.entered_dt;
END;
GO


-- =====================================================================
-- 4. sp_event_autoraise_drain
--
--    Processes the queue. Each entry is independent: one bad row must not
--    stop the rest, so every raise runs in its own TRY/CATCH and failures
--    are recorded on the entry rather than thrown.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_autoraise_drain
    @organization_id BIGINT = NULL,     -- NULL = all organizations
    @max_rows        INT    = 200,
    @out_processed   INT    = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @out_processed = 0;

    DECLARE @qid BIGINT, @org BIGINT, @entity NVARCHAR(60), @rec BIGINT,
            @code NVARCHAR(60), @eff DATE, @raised INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@max_rows) queue_id, organization_id, subject_entity,
               subject_record_id, event_code, effective_date
        FROM   grac_practice.event_autoraise_queue
        WHERE  status = N'Pending'
          AND  (@organization_id IS NULL OR organization_id = @organization_id)
        ORDER BY enqueued_dt, queue_id;

    OPEN cur;
    FETCH NEXT FROM cur INTO @qid, @org, @entity, @rec, @code, @eff;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @raised = 0;

        BEGIN TRY
            IF @entity = N'EMPLOYEE'
                EXEC grac_practice.sp_event_raise_people_lifecycle
                     @organization_id  = @org,
                     @employee_id      = @rec,
                     @lifecycle_action = N'ONBOARD',
                     @effective_date   = @eff,
                     @event_code       = @code,
                     @trigger_source   = N'AutoRaise',
                     @out_raised_count = @raised OUTPUT;
            ELSE
                EXEC grac_practice.sp_event_raise_asset_lifecycle
                     @organization_id  = @org,
                     @asset_id         = @rec,
                     @lifecycle_action = N'COMMISSION',
                     @effective_date   = @eff,
                     @event_code       = @code,
                     @trigger_source   = N'AutoRaise',
                     @out_raised_count = @raised OUTPUT;

            UPDATE grac_practice.event_autoraise_queue
               SET status = N'Done', raised_count = @raised,
                   attempt_count = attempt_count + 1,
                   processed_dt = SYSUTCDATETIME(), last_error = NULL
             WHERE queue_id = @qid;
        END TRY
        BEGIN CATCH
            -- Kept Pending for a retry unless it has failed repeatedly; a
            -- permanent misconfiguration should stop consuming the queue.
            UPDATE grac_practice.event_autoraise_queue
               SET status = CASE WHEN attempt_count + 1 >= 3 THEN N'Failed' ELSE N'Pending' END,
                   attempt_count = attempt_count + 1,
                   last_error = ERROR_MESSAGE(),
                   processed_dt = SYSUTCDATETIME()
             WHERE queue_id = @qid;
        END CATCH

        SET @out_processed = @out_processed + 1;
        FETCH NEXT FROM cur INTO @qid, @org, @entity, @rec, @code, @eff;
    END

    CLOSE cur;
    DEALLOCATE cur;

    SELECT @out_processed AS Processed;
END;
GO


-- =====================================================================
-- 5. sp_event_obligation_raise -- role resolution via the function
--    (only the @roles population changes; the rest is 129 verbatim)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_raise
    @organization_id     BIGINT,
    @event_type_id       BIGINT        = NULL,
    @event_type_code     NVARCHAR(60)  = NULL,
    @event_definition_id BIGINT        = NULL,
    @subject_entity      NVARCHAR(60),
    @subject_record_id   BIGINT,
    @effective_date      DATE          = NULL,
    @trigger_source      NVARCHAR(60)  = N'Manual',
    @actor_employee_id   BIGINT        = NULL,
    @out_raised_count    INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @out_raised_count = 0;

    IF @organization_id IS NULL
        THROW 67330, 'sp_event_obligation_raise: organization_id is required.', 1;
    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        THROW 67331, 'sp_event_obligation_raise: subject_entity must be EMPLOYEE or ASSET.', 1;
    IF @subject_record_id IS NULL
        THROW 67332, 'sp_event_obligation_raise: subject_record_id is required.', 1;

    IF @event_type_id IS NULL AND @event_type_code IS NOT NULL
        SELECT @event_type_id = event_type_id
        FROM   GRAC_New.event_type_master
        WHERE  event_code = @event_type_code AND status = N'Active';

    IF @event_type_id IS NULL
        THROW 67333, 'sp_event_obligation_raise: event type not resolved.', 1;

    SELECT @event_type_code = event_code
    FROM   GRAC_New.event_type_master WHERE event_type_id = @event_type_id;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    DECLARE @subject_label NVARCHAR(300),
            @asset_cat     INT = NULL,
            @asset_cat_nm  NVARCHAR(160) = NULL;
    DECLARE @roles TABLE (role_id BIGINT PRIMARY KEY, role_name NVARCHAR(120));

    IF @subject_entity = N'EMPLOYEE'
    BEGIN
        SELECT @subject_label = LEFT(CONCAT(employee_name, N' (', employee_code, N')'), 300)
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @subject_record_id AND organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67334, 'sp_event_obligation_raise: employee not found in this organization.', 1;

        -- BOTH role sources (131). The Employee form writes
        -- organization_employee.role_id; User Role Assignment writes
        -- organization_employee_role.
        INSERT INTO @roles(role_id, role_name)
        SELECT role_id, MIN(role_name)
        FROM   grac_practice.fn_pm_employee_role_ids(@subject_record_id)
        GROUP BY role_id;
    END
    ELSE
    BEGIN
        SELECT @subject_label = LEFT(a.asset_name, 300),
               @asset_cat     = a.asset_category_id,
               @asset_cat_nm  = ac.asset_category_name
        FROM   grac_practice.organization_dependency_asset a
        LEFT JOIN grac_practice.dependency_asset_category_master ac
               ON ac.asset_category_id = a.asset_category_id
        WHERE  a.asset_id = @subject_record_id AND a.organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67335, 'sp_event_obligation_raise: asset not found in this organization.', 1;
    END

    DECLARE @event_def BIGINT = @event_definition_id;
    IF @event_def IS NULL
        SELECT TOP 1 @event_def = event_definition_id
        FROM   grac_practice.event_definition
        WHERE  organization_id = @organization_id AND status = N'Active'
        ORDER BY CASE WHEN event_code = @event_type_code THEN 0 ELSE 1 END, event_definition_id;

    IF (@subject_entity = N'EMPLOYEE' AND NOT EXISTS (SELECT 1 FROM @roles))
       OR (@subject_entity = N'ASSET' AND @asset_cat IS NULL)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
             CASE WHEN @subject_entity = N'EMPLOYEE'
                  THEN N'Employee has no active role, in either organization_employee.role_id or organization_employee_role.'
                  ELSE N'Asset has no category assigned.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    DECLARE @cand TABLE (
        obligation_id    BIGINT PRIMARY KEY,
        obligation_label NVARCHAR(400),
        obligation_text  NVARCHAR(MAX),
        applicability_id BIGINT,
        owner_role_id    BIGINT,
        due_days         INT,
        decision         NVARCHAR(20),
        reason_code      NVARCHAR(60)
    );

    ;WITH raw AS (
        SELECT v.obligation_id, v.obligation_label, v.obligation_text,
               a.applicability_id, a.owner_role_id, a.due_days,
               CASE WHEN a.applicability_id IS NULL THEN N'Excluded'
                    WHEN a.status <> N'Active'      THEN N'Excluded'
                    WHEN a.is_applicable = 0        THEN N'Excluded'
                    ELSE N'Included' END AS decision,
               CASE WHEN a.applicability_id IS NULL THEN N'ObligationUnmapped'
                    WHEN a.status <> N'Active'      THEN N'MappingInactive'
                    WHEN a.is_applicable = 0        THEN N'ObligationNotApplicable'
                    ELSE N'ObligationApplicable' END AS reason_code
        FROM       grac_practice.vw_pm_event_driven_obligation v
        LEFT JOIN  grac_practice.event_obligation_applicability a
               ON  a.organization_id = v.organization_id
              AND  a.obligation_id   = v.obligation_id
              AND  a.event_type_id   = v.event_type_id
              AND  (   (@subject_entity = N'EMPLOYEE'
                            AND a.scope_role_id IN (SELECT role_id FROM @roles))
                    OR (@subject_entity = N'ASSET'
                            AND a.scope_asset_category_id = @asset_cat))
        WHERE      v.organization_id = @organization_id
          AND      v.event_type_id   = @event_type_id
          AND      v.is_subscribed   = 1
    ),
    ranked AS (
        SELECT *, ROW_NUMBER() OVER (
                     PARTITION BY obligation_id
                     ORDER BY CASE WHEN decision = N'Included' THEN 0 ELSE 1 END,
                              CASE WHEN due_days IS NULL THEN 1 ELSE 0 END,
                              due_days, applicability_id) AS rn
        FROM raw
    )
    INSERT INTO @cand
        (obligation_id, obligation_label, obligation_text, applicability_id,
         owner_role_id, due_days, decision, reason_code)
    SELECT obligation_id, obligation_label, obligation_text, applicability_id,
           owner_role_id, due_days, decision, reason_code
    FROM   ranked WHERE rn = 1;

    IF NOT EXISTS (SELECT 1 FROM @cand WHERE decision = N'Included')
    BEGIN
        IF EXISTS (SELECT 1 FROM @cand)
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, obligation_id, obligation_label, applicability_id,
                 scope_role_id, scope_asset_category_id, decision, reason_code, entered_by, entered_dt)
            SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                   @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
                   (SELECT TOP 1 role_id FROM @roles ORDER BY role_id), @asset_cat,
                   N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
            FROM   @cand c;
        ELSE
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, N'Excluded', N'NoMappingForEvent',
                 N'No event-driven obligation of this event type reaches this organization.',
                 @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.event_instance
                WHERE organization_id   = @organization_id
                  AND origin_kind       = N'OBLIGATION'
                  AND event_type_id     = @event_type_id
                  AND subject_entity    = @subject_entity
                  AND subject_record_id = @subject_record_id
                  AND status NOT IN (N'Completed', N'Cancelled'))
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'AlreadyOpen',
             N'An open obligation instance already exists for this subject and event.',
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF @event_def IS NULL
        THROW 67336, 'sp_event_obligation_raise: organization has no active event_definition. Run migration 126.', 1;

    DECLARE @due_days INT = (SELECT MIN(due_days) FROM @cand WHERE decision = N'Included');
    DECLARE @owner_role BIGINT = (
        SELECT TOP 1 owner_role_id FROM @cand
         WHERE decision = N'Included' AND owner_role_id IS NOT NULL
         ORDER BY CASE WHEN due_days IS NULL THEN 1 ELSE 0 END, due_days);

    DECLARE @owner_emp BIGINT = NULL, @owner_nm NVARCHAR(240) = NULL;
    IF @owner_role IS NOT NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id = @organization_id, @role_id = @owner_role,
             @employee_id_out = @owner_emp OUTPUT, @employee_name_out = @owner_nm OUTPUT;

    DECLARE @scope_role BIGINT = (SELECT TOP 1 role_id FROM @roles ORDER BY role_id);
    DECLARE @scope_role_nm NVARCHAR(120) = (SELECT TOP 1 role_name FROM @roles ORDER BY role_id);

    BEGIN TRAN;

    INSERT INTO grac_practice.event_instance
        (organization_id, event_definition_id, entity_type_id, entity_reference,
         entity_display_name, checklist_id, trigger_source,
         owner_employee_id, due_date, status,
         origin_kind, event_type_id, event_type_code,
         subject_entity, subject_record_id,
         scope_role_id, scope_role_name,
         scope_asset_category_id, scope_asset_category_name,
         effective_date, entered_by, entered_dt)
    VALUES
        (@organization_id, @event_def, NULL, CAST(@subject_record_id AS NVARCHAR(200)),
         @subject_label, NULL, ISNULL(@trigger_source, N'Manual'),
         @owner_emp,
         CASE WHEN @due_days IS NULL THEN NULL ELSE DATEADD(DAY, @due_days, @effective_date) END,
         N'Pending',
         N'OBLIGATION', @event_type_id, @event_type_code,
         @subject_entity, @subject_record_id,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role ELSE NULL END,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role_nm ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat_nm ELSE NULL END,
         @effective_date, @actor, SYSUTCDATETIME());

    DECLARE @instance BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.event_instance_obligation
        (event_instance_id, organization_id, obligation_id, obligation_label, obligation_text,
         applicability_id, item_sequence, is_mandatory, item_status, entered_dt)
    SELECT @instance, @organization_id, c.obligation_id, c.obligation_label, c.obligation_text,
           c.applicability_id, ROW_NUMBER() OVER (ORDER BY c.obligation_id),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c WHERE c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
         subject_label, effective_date, obligation_id, obligation_label, applicability_id,
         scope_role_id, scope_asset_category_id,
         decision, reason_code, event_instance_id, entered_by, entered_dt)
    SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
           @scope_role, @asset_cat, c.decision, c.reason_code,
           CASE WHEN c.decision = N'Included' THEN @instance ELSE NULL END,
           @actor, SYSUTCDATETIME()
    FROM   @cand c;

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @instance, N'EventInstance', @instance, N'Trigger', @actor,
         CONCAT(N'origin=OBLIGATION;event_type=', @event_type_code,
                N';subject=', @subject_entity, N':', @subject_record_id,
                N';obligations=', @out_raised_count,
                N';effective_date=', CONVERT(NVARCHAR(10), @effective_date, 23)),
         SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_raised_count AS RaisedCount, @instance AS EventInstanceId;
END;
GO


-- =====================================================================
-- 6. sp_event_checklist_inbox_list -- count BOTH item stores
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_inbox_list
    @organization_id    BIGINT,
    @owner_employee_id  BIGINT       = NULL,
    @subject_entity     NVARCHAR(60) = NULL,
    @status_filter      NVARCHAR(200) = NULL,
    @overdue_only       BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67250, 'sp_event_checklist_inbox_list: organization_id is required.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT
        ei.event_instance_id                     AS EventInstanceId,
        ed.event_code                            AS EventCode,
        ed.event_name                            AS EventName,
        ei.subject_entity                        AS SubjectEntity,
        ei.subject_record_id                     AS SubjectRecordId,
        ei.entity_display_name                   AS SubjectLabel,
        ei.scope_role_id                         AS ScopeRoleId,
        ei.scope_role_name                       AS ScopeRoleName,
        ei.scope_asset_category_id               AS ScopeAssetCategoryId,
        ei.scope_asset_category_name             AS ScopeAssetCategoryName,
        c.checklist_id                           AS ChecklistId,
        -- Obligation instances have no checklist row; label them so the grid
        -- does not show a blank cell.
        COALESCE(c.checklist_name,
                 CASE WHEN ei.origin_kind = N'OBLIGATION'
                      THEN N'Obligations (' + ei.event_type_code + N')' END) AS ChecklistName,
        ei.owner_employee_id                     AS OwnerEmployeeId,
        oe.employee_name                         AS OwnerEmployeeName,
        ei.effective_date                        AS EffectiveDate,
        ei.due_date                              AS DueDate,
        ei.status                                AS InstanceStatus,
        CAST(CASE WHEN ei.due_date IS NOT NULL
                   AND ei.due_date < @today
                   AND ei.status NOT IN (N'Completed', N'Cancelled')
                  THEN 1 ELSE 0 END AS BIT)      AS IsOverdue,
        CASE WHEN ei.due_date IS NULL THEN NULL
             ELSE DATEDIFF(DAY, ei.due_date, @today) END AS DaysOverdue,
        -- Items live in event_instance_item for checklist instances and in
        -- event_instance_obligation for obligation instances. Counting only
        -- the first showed obligation packs as 0 / 0.
        (SELECT COUNT(*) FROM grac_practice.event_instance_item ii
          WHERE ii.event_instance_id = ei.event_instance_id)
        + (SELECT COUNT(*) FROM grac_practice.event_instance_obligation io
            WHERE io.event_instance_id = ei.event_instance_id)            AS ItemCount,
        (SELECT COUNT(*) FROM grac_practice.event_instance_item ii
          WHERE ii.event_instance_id = ei.event_instance_id
            AND ii.item_status IN (N'Passed', N'Failed', N'NotApplicable'))
        + (SELECT COUNT(*) FROM grac_practice.event_instance_obligation io
            WHERE io.event_instance_id = ei.event_instance_id
              AND io.item_status IN (N'Passed', N'Failed', N'NotApplicable')) AS ItemsDone
    FROM       grac_practice.event_instance ei
    JOIN       grac_practice.event_definition ed
           ON  ed.event_definition_id = ei.event_definition_id
    LEFT JOIN  grac_practice.checklist c ON c.checklist_id = ei.checklist_id
    LEFT JOIN  grac_practice.organization_employee oe ON oe.employee_id = ei.owner_employee_id
    WHERE      ei.organization_id = @organization_id
      AND      ei.subject_record_id IS NOT NULL
      AND      (@owner_employee_id IS NULL OR ei.owner_employee_id = @owner_employee_id)
      AND      (@subject_entity    IS NULL OR ei.subject_entity    = @subject_entity)
      AND      (
                 (@status_filter IS NULL AND ei.status NOT IN (N'Completed', N'Cancelled'))
              OR (@status_filter IS NOT NULL
                  AND ei.status IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@status_filter, ',')))
               )
      AND      (@overdue_only = 0
                OR (ei.due_date IS NOT NULL AND ei.due_date < @today
                    AND ei.status NOT IN (N'Completed', N'Cancelled')))
    ORDER BY   CASE WHEN ei.due_date IS NULL THEN 1 ELSE 0 END, ei.due_date, ei.event_instance_id;
END;
GO


-- =====================================================================
-- 7. Backfill -- enqueue employees that already exist with a role but have
--    never had an onboarding raised. Without this, everybody added before
--    131 stays invisible forever.
-- =====================================================================
INSERT INTO grac_practice.event_autoraise_queue
    (organization_id, subject_entity, subject_record_id, event_code,
     effective_date, source, status)
SELECT e.organization_id, N'EMPLOYEE', e.employee_id, N'PEOPLE_ONBOARDING',
       COALESCE(e.onboarded_dt, CAST(e.entered_dt AS DATE)),
       N'backfill-131', N'Pending'
FROM   grac_practice.organization_employee e
WHERE  e.status = N'Active'
  AND  EXISTS (SELECT 1 FROM grac_practice.fn_pm_employee_role_ids(e.employee_id))
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                    WHERE ei.organization_id   = e.organization_id
                      AND ei.subject_entity    = N'EMPLOYEE'
                      AND ei.subject_record_id = e.employee_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_autoraise_queue q
                    WHERE q.organization_id   = e.organization_id
                      AND q.subject_entity    = N'EMPLOYEE'
                      AND q.subject_record_id = e.employee_id
                      AND q.event_code        = N'PEOPLE_ONBOARDING'
                      AND q.status            = N'Pending');
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'fn_pm_employee_role_ids'    AS Check_, CASE WHEN OBJECT_ID('grac_practice.fn_pm_employee_role_ids','IF') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'event_autoraise_queue',      CASE WHEN OBJECT_ID('grac_practice.event_autoraise_queue','U')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'tr_pm_employee_autoraise',   CASE WHEN OBJECT_ID('grac_practice.tr_pm_employee_autoraise','TR') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'tr_pm_employee_role_autoraise', CASE WHEN OBJECT_ID('grac_practice.tr_pm_employee_role_autoraise','TR') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_autoraise_drain',   CASE WHEN OBJECT_ID('grac_practice.sp_event_autoraise_drain','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Queue after backfill (Pending entries awaiting drain) ---';
SELECT organization_id, subject_entity, subject_record_id, event_code,
       effective_date, source, status, enqueued_dt
FROM   grac_practice.event_autoraise_queue
WHERE  status = N'Pending'
ORDER BY enqueued_dt, queue_id;

PRINT '131 People auto-raise + role resolution fix deployed.';
PRINT 'NEXT: EXEC grac_practice.sp_event_autoraise_drain;  -- turns Pending entries into checklists';
GO

SET NOEXEC OFF;
GO
