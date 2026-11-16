-- =====================================================================
-- 513  Event-driven obligations are Event Response (follows Control
--      Management 086)
--
-- REQUEST (2026-11-04)
--   Assurance is Scheduled only; "every time an event occurs" is an Event
--   Response, which asks People / Asset and then the event.  Existing
--   event-driven Assurance obligations convert automatically; the
--   deadline is in days.  Control Management 086 does the catalogue.
--   This file does Practice Management's side.
--
-- WHAT CHANGES
--   1. Views over the obligation detail are refreshed, so the new Event
--      Response columns (event_type_id, sla_days) reach the
--      organization copies and the screens.  vw_pm_obligation_typed_detail
--      builds its JSON with `er.*`, which is bound when the view is
--      compiled.
--
--   2. vw_pm_event_driven_obligation (394) -- the view Configure
--      Checklists, the Checklists tab, coverage and the event raise all
--      read -- treats an obligation as event driven when its copy carries
--      an Event Response with an event, OR (until the organization
--      approves 086's repository update) an Event Driven assurance spec.
--      So checklists keep working before AND after an organization
--      approves the update.  Branches 2 and 3 (custom obligations) are
--      unchanged: they already key on event_type_id.
--
--   3. sp_resolve_local_obligation_save (412) and
--      sp_practice_obligation_save (464): the event of a custom obligation
--      is taken from its Event Response detail.  Before this no caller
--      passed @event_type_id, so a custom obligation's event was never
--      stored in the column branches 2 and 3 read -- it never reached a
--      checklist.  Any type other than Event Response stores no event.
--
--   4. Data, every change kept in migration_513_obligation_backup:
--      a. custom obligations (practice level, instance level and the
--         instance copies of a practice-level one) typed Assurance with
--         an Event Driven detail become Event Response:
--             response_action <- verification_method
--             event_type_id   <- event_type_id   (also into the column)
--             sla_days        <- sla_days
--      b. adopted catalogue obligations that 086 converted are re-typed
--         Event Response on the practice instance.
--      c. an Event Response's SLA override on an instance is put in days
--         (Hours rounded up to a day, Weeks x7, Months x30, Years x365).
--
-- NOT CHANGED
--   Organization copies of the catalogue (organization_obligation).  They
--   change only when the organization approves the update in Repository
--   Updates -- sir's rule since 395: nothing Control Management publishes
--   reaches an organization unapproved.  Change detection raises one
--   "Changed" item per converted obligation per subscribed organization
--   on its next run.  Item 2 is what keeps the event flow working until
--   then.
--
-- RUN ORDER
--   Control Management 086 -> this file -> restart the API (and the Web
--   app, for the new obligation form).
--
-- SAFE TO RE-RUN. Requires 394, 412, 464 and Control Management 086.
-- Rollback: 513_event_driven_to_event_response_rollback.sql (run it
-- BEFORE Control Management 086's rollback).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('GRAC_New.obligation_event_response','event_type_id') IS NULL
   OR COL_LENGTH('GRAC_New.obligation_event_response','sla_days') IS NULL
   OR OBJECT_ID('GRAC_New.migration_086_assurance_conversion','U') IS NULL
BEGIN
    PRINT 'ABORT (513): run Control Management 086_event_driven_to_event_response.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- The re-issued bodies read these; guard them rather than let a CREATE
-- fail half way (Msg 207 would still let the script print "applied").
IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','event_responses_json') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','assurance_specs_json') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','sla_value') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','sla_unit') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','evidence_json') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    PRINT 'ABORT (513): run 340, 394 and 412 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- The two save procedures are re-issued from 412 / 464.  Refuse rather
-- than roll a database that never had them back to an older body.
IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save')) NOT LIKE '%@owner_employee_id%'
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save')) NOT LIKE '%@restore%'
BEGIN
    PRINT 'ABORT (513): run 412 and 464 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Refresh the views over the obligation detail
-- =====================================================================
DECLARE @views TABLE(object_id INT PRIMARY KEY, lvl INT NOT NULL);

-- Named first: these two are known to need it.
INSERT @views(object_id, lvl)
SELECT o.object_id, 1
FROM   (VALUES (N'grac_practice.vw_pm_obligation_typed_detail')) n(name)
JOIN   sys.objects o ON o.object_id = OBJECT_ID(n.name) AND o.type = 'V';

INSERT @views(object_id, lvl)
SELECT o.object_id, 2
FROM   (VALUES (N'grac_practice.vw_repo_src_obligation')) n(name)
JOIN   sys.objects o ON o.object_id = OBJECT_ID(n.name) AND o.type = 'V'
WHERE  NOT EXISTS (SELECT 1 FROM @views v WHERE v.object_id = o.object_id);

-- Then anything else that reads the two detail tables, and one level
-- above that.
INSERT @views(object_id, lvl)
SELECT DISTINCT d.referencing_id, 1
FROM   sys.sql_expression_dependencies d
JOIN   sys.views w ON w.object_id = d.referencing_id
WHERE  d.referenced_id IN (OBJECT_ID('GRAC_New.obligation_event_response'),
                           OBJECT_ID('GRAC_New.obligation_assurance_spec'))
  AND  NOT EXISTS (SELECT 1 FROM @views v WHERE v.object_id = d.referencing_id);

INSERT @views(object_id, lvl)
SELECT DISTINCT d.referencing_id, 2
FROM   sys.sql_expression_dependencies d
JOIN   sys.views w ON w.object_id = d.referencing_id
WHERE  d.referenced_id IN (SELECT object_id FROM @views WHERE lvl = 1)
  AND  NOT EXISTS (SELECT 1 FROM @views v WHERE v.object_id = d.referencing_id);

DECLARE @view_name NVARCHAR(400);
DECLARE view_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N'.' + QUOTENAME(OBJECT_NAME(object_id))
    FROM   @views
    ORDER  BY lvl, object_id;
OPEN view_cur;
FETCH NEXT FROM view_cur INTO @view_name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sys.sp_refreshview @view_name;
        PRINT CONCAT('513: refreshed ', @view_name);
    END TRY
    BEGIN CATCH
        PRINT CONCAT('513 WARNING: could not refresh ', @view_name, ' -- ', ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM view_cur INTO @view_name;
END
CLOSE view_cur;
DEALLOCATE view_cur;
GO

-- =====================================================================
-- 2. vw_pm_event_driven_obligation (394 body; only the `spec` source
--    changes)
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_event_driven_obligation
AS
    SELECT DISTINCT
        req.organization_id,
        req.organization_requirement_id,
        req.requirement_code,
        req.requirement_name,
        req.applicability_status                                   AS RequirementApplicability,
        p.practice_id,
        p.practice_code,
        p.practice_name,
        p.applicability_status                                     AS PracticeApplicability,
        orm.release_id,
        o.obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))                     AS obligation_label,
        o.obligation_text,
        spec.trigger_mode,
        spec.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(CASE WHEN EXISTS (
                 SELECT 1 FROM grac_practice.repository_subscription s
                  WHERE s.organization_id     = req.organization_id
                    AND s.release_id          = orm.release_id
                    AND s.subscription_status = N'Active'
                    AND s.status              = N'Active')
             THEN 1 ELSE 0 END AS BIT)                             AS is_subscribed,
        -- Migration 341/342: which local identity this row carries. NULL
        -- on every catalog row -- a catalog obligation's identity is
        -- obligation_id, the column two lines above.
        CAST(NULL AS BIGINT)                                       AS local_practice_obligation_id,
        CAST(NULL AS BIGINT)                                       AS local_instance_obligation_id
    FROM       grac_practice.organization_requirement req
    LEFT JOIN  grac_practice.practice p
           ON  p.organization_requirement_id = req.organization_requirement_id
          AND  p.organization_id             = req.organization_id
          AND  p.status                      = N'Active'
    -- 394: the organization's approved copy; the assurance spec is the
    -- copied AssuranceSpecsJson (Active specs only, as 302 builds it).
    -- 513: and the copied EventResponsesJson -- see `spec` below.
    LEFT JOIN  grac_practice.organization_repository_requirement repo_req
           ON  repo_req.organization_id  = req.organization_id
          AND  repo_req.requirement_code = req.requirement_code
          AND  repo_req.status           = N'Active'
    JOIN       grac_practice.organization_obligation_requirement_map orm
           ON  orm.organization_id = req.organization_id
          AND  orm.requirement_id  = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
          AND  orm.status          = N'Active'
    JOIN       grac_practice.organization_obligation o
           ON  o.organization_id = req.organization_id
          AND  o.obligation_id   = orm.obligation_id
    -- 513: an obligation is event driven when its copy carries EITHER
    --   * an Event Response with an event (Control Management 086 -- the
    --     only shape Control Management writes from now on), OR
    --   * an Event Driven assurance spec: the shape before 086.  An
    --     organization keeps that copy until it approves the repository
    --     update 086 causes, and its checklists must keep working in the
    --     meantime.
    -- Either way the row reads trigger_mode = 'EventDriven', the value
    -- every reader of this view already filters on.  DISTINCT (above)
    -- collapses the two if a copy ever carried both for one event.
    CROSS APPLY (
        SELECT a.trigger_mode, a.event_type_id
        FROM   OPENJSON(o.assurance_specs_json)
               WITH (trigger_mode  NVARCHAR(60) '$.trigger_mode',
                     event_type_id BIGINT       '$.event_type_id') a
        -- trigger_mode is stored as the CODE by ControlManagement 033.
        WHERE  a.trigger_mode = N'EventDriven'
        UNION ALL
        SELECT N'EventDriven', r.event_type_id
        FROM   OPENJSON(o.event_responses_json)
               WITH (event_type_id BIGINT '$.event_type_id') r
        WHERE  r.event_type_id IS NOT NULL
    ) spec
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = spec.event_type_id
          AND  et.status        = N'Active'
    WHERE      req.status        = N'Active'

    -- =================================================================
    -- Branch 2: practice-level custom obligations (307), declared
    -- event-driven (340). One row per DEFINITION, not per fanned-out
    -- copy -- see the migration header.
    -- =================================================================
    UNION ALL
    SELECT DISTINCT
        po.organization_id,
        CAST(NULL AS BIGINT)                                       AS organization_requirement_id,
        NULL                                                       AS requirement_code,
        NULL                                                       AS requirement_name,
        NULL                                                       AS RequirementApplicability,
        pr.practice_id,
        pr.practice_code,
        pr.practice_name,
        pr.applicability_status                                    AS PracticeApplicability,
        CAST(NULL AS BIGINT)                                       AS release_id,
        CAST(NULL AS BIGINT)                                       AS obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(po.obligation_name)), N''),
                 LEFT(po.obligation_description, 300))             AS obligation_label,
        po.obligation_description                                  AS obligation_text,
        N'EventDriven'                                             AS trigger_mode,
        po.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(1 AS BIT)                                              AS is_subscribed,
        po.practice_obligation_id                                  AS local_practice_obligation_id,
        CAST(NULL AS BIGINT)                                       AS local_instance_obligation_id
    FROM       grac_practice.practice_obligation po
    JOIN       grac_practice.practice pr
           ON  pr.practice_id = po.practice_id
          AND  pr.status      = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = po.event_type_id
          AND  et.status        = N'Active'
    WHERE      po.event_type_id IS NOT NULL
      AND      po.status        = N'Active'

    -- =================================================================
    -- Branch 3: instance-only custom obligations (227) -- not cataloged,
    -- not a practice-level copy (that population is branch 2), declared
    -- event-driven (340).
    -- =================================================================
    UNION ALL
    SELECT DISTINCT
        pio.organization_id,
        CAST(NULL AS BIGINT)                                       AS organization_requirement_id,
        NULL                                                       AS requirement_code,
        NULL                                                       AS requirement_name,
        NULL                                                       AS RequirementApplicability,
        pi.practice_id,
        pr.practice_code,
        pr.practice_name,
        pr.applicability_status                                    AS PracticeApplicability,
        CAST(NULL AS BIGINT)                                       AS release_id,
        CAST(NULL AS BIGINT)                                       AS obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                 LEFT(pio.obligation_description, 300))            AS obligation_label,
        pio.obligation_description                                 AS obligation_text,
        N'EventDriven'                                             AS trigger_mode,
        pio.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(1 AS BIT)                                              AS is_subscribed,
        CAST(NULL AS BIGINT)                                       AS local_practice_obligation_id,
        pio.practice_instance_obligation_id                        AS local_instance_obligation_id
    FROM       grac_practice.practice_instance_obligation pio
    JOIN       grac_practice.practice_instance pi
           ON  pi.practice_instance_id = pio.practice_instance_id
          AND  pi.status               = N'Active'
    JOIN       grac_practice.practice pr
           ON  pr.practice_id = pi.practice_id
          AND  pr.status      = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = pio.event_type_id
          AND  et.status        = N'Active'
    WHERE      pio.obligation_id                  IS NULL
      AND      pio.source_practice_obligation_id   IS NULL
      AND      pio.event_type_id                   IS NOT NULL
      AND      pio.status                          = N'Active';
GO

-- =====================================================================
-- 3. The two custom-obligation save procedures (412 / 464 bodies; only
--    the "Migration 513" block is new)
-- =====================================================================
-- sp_resolve_local_obligation_save (412 body + 513)
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_save
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT        = 0,
    @obligation_name                 NVARCHAR(500) = NULL,
    @obligation_description          NVARCHAR(MAX) = NULL,
    @obligation_type_code            NVARCHAR(60)  = NULL,
    @typed_detail_json               NVARCHAR(MAX) = NULL,
    @execution_frequency_id          INT           = NULL,
    @execution_frequency             NVARCHAR(120) = NULL,
    @responsibility                  NVARCHAR(300) = NULL,
    -- 412: owner employee (NULL keep / 0 clear / > 0 set).
    @owner_employee_id               BIGINT        = NULL,
    @approval_authority              NVARCHAR(300) = NULL,
    @assurance_type                  NVARCHAR(40)  = NULL,
    @implementation_status_id        INT           = NULL,
    -- Migration 340: which event makes this obligation due. NULL means
    -- not event-driven, the same "absent has no opinion, NULL is a real
    -- answer" reading @assurance_type already gets.
    @event_type_id                   BIGINT        = NULL,
    -- Migration 244: Automated-only connection payload.
    @connection_type_id              INT           = NULL,
    @connection_url                  NVARCHAR(500) = NULL,
    @remarks                         NVARCHAR(MAX) = NULL,
    @evidence_json                   NVARCHAR(MAX) = NULL,
    @retire                          BIT           = 0,
    @caller_employee_id              BIGINT        = NULL,
    @is_admin                        BIT           = 0,
    @actor                           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52691, 'sp_resolve_local_obligation_save: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @owner_id BIGINT;
    SELECT @organization_id = organization_id, @owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52692, 'sp_resolve_local_obligation_save: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52693, 'sp_resolve_local_obligation_save: this practice instance belongs to another owner.', 1;

    IF @retire = 1
    BEGIN
        IF @practice_instance_obligation_id IS NULL OR @practice_instance_obligation_id = 0
            THROW 52694, 'sp_resolve_local_obligation_save: an id is required to retire an obligation.', 1;

        UPDATE grac_practice.practice_instance_obligation
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_instance_obligation_id = @practice_instance_obligation_id
           AND practice_instance_id            = @practice_instance_id
           AND obligation_id IS NULL;

        IF @@ROWCOUNT = 0
            THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

        UPDATE pie
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_instance_evidence pie
        WHERE  pie.practice_instance_id = @practice_instance_id
          AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
          AND  pie.status = N'Active'
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NULL
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NULL
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,    N''))), N'') IS NULL;

        SELECT CAST(1 AS BIT) AS Success, N'Obligation removed.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId,
               0 AS EvidenceAdded, 0 AS EvidenceRemoved, 0 AS EvidenceKept;
        RETURN;
    END

    SET @obligation_name = NULLIF(LTRIM(RTRIM(@obligation_name)), N'');
    IF @obligation_name IS NULL
        THROW 52696, 'Obligation name is required.', 1;

    SET @obligation_type_code = NULLIF(LTRIM(RTRIM(@obligation_type_code)), N'');
    IF @obligation_type_code IS NULL
        THROW 52697, 'Obligation type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                    WHERE type_code = @obligation_type_code)
        THROW 52698, 'That obligation type does not exist.', 1;

    IF @typed_detail_json IS NOT NULL AND ISJSON(@typed_detail_json) <> 1
        THROW 52699, 'The rule detail must be valid JSON.', 1;

    IF @assurance_type IS NOT NULL AND @assurance_type NOT IN (N'Manual', N'Automated')
        THROW 52674, 'Assurance type must be Manual or Automated.', 1;

    IF @evidence_json IS NOT NULL AND ISJSON(@evidence_json) <> 1
        THROW 52701, 'The evidence list must be a JSON array.', 1;

    -- Migration 244: reject a stale connection_type_id, exactly as the
    -- adopt proc does. NULL is fine.
    IF @connection_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.connection_type_master
                        WHERE connection_type_id = @connection_type_id AND is_active = 1)
        THROW 52676, 'sp_resolve_local_obligation_save: unknown connection type.', 1;

    -- Migration 513: the event of a custom obligation.  The form keeps it
    -- in the typed detail (event_type_id, the Event Response column), so
    -- it is taken from there when the caller does not pass it -- no caller
    -- ever did, which is why a custom obligation's event never reached
    -- the event-driven checklists before 513.  Only an Event Response is
    -- event driven; every other type stores no event (an Assurance is
    -- Scheduled only since Control Management 086).
    IF @obligation_type_code = N'EventResponse'
        SET @event_type_id = COALESCE(
            @event_type_id,
            TRY_CAST(JSON_VALUE(COALESCE(@typed_detail_json, (
                SELECT x.typed_detail_json FROM grac_practice.practice_instance_obligation x
                WHERE  x.practice_instance_obligation_id = @practice_instance_obligation_id)), '$[0].event_type_id') AS BIGINT));
    ELSE
        SET @event_type_id = NULL;

    -- Migration 340: reject a stale event_type_id, the same existence
    -- check sp_resolve_obligation_adopt already applies via its JSON
    -- payload (234). NULL is fine -- it means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 52706, 'sp_resolve_local_obligation_save: unknown event type.', 1;

    -- 412: the Owner is an EMPLOYEE (a Functional User of this
    -- organization), no longer a role name. @owner_employee_id:
    --   NULL = leave the stored owner as it is (older callers),
    --   0    = clear the owner,
    --   > 0  = set it; responsibility (the display name every reader
    --          already shows) is written from the employee record.
    IF @owner_employee_id > 0
    BEGIN
        DECLARE @owner_name NVARCHAR(300) = (
            SELECT e.employee_name
            FROM   grac_practice.organization_employee e
            WHERE  e.employee_id        = @owner_employee_id
              AND  e.organization_id    = @organization_id
              AND  e.status             = N'Active'
              AND  e.is_functional_user = 1);
        IF @owner_name IS NULL
            THROW 52733, 'The obligation owner must be an active Functional User of this organization.', 1;
        SET @responsibility = @owner_name;
    END
    ELSE IF @owner_employee_id = 0
        SET @responsibility = NULL;

    SET @connection_url = NULLIF(LTRIM(RTRIM(@connection_url)), N'');

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    DECLARE @ev_added INT = 0, @ev_removed INT = 0, @ev_kept INT = 0;

    IF ISNULL(@practice_instance_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_instance_obligation
            (organization_id, practice_instance_id, obligation_id, release_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             inherited_from_repository, organization_modified,
             execution_frequency_id, execution_frequency,
             responsibility, owner_employee_id, approval_authority, assurance_type, remarks,
             implementation_status_id,
             event_type_id,
             connection_type_id, connection_url,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, NULLIF(@owner_employee_id, 0), @approval_authority, @assurance_type, @remarks,
             @implementation_status_id,
             @event_type_id,
             @connection_type_id, @connection_url,
             @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

        SET @practice_instance_obligation_id = SCOPE_IDENTITY();

        EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
             @practice_instance_id            = @practice_instance_id,
             @practice_instance_obligation_id = @practice_instance_obligation_id,
             @evidence_json                   = @evidence_json,
             @actor                           = @actor,
             @evidence_added                  = @ev_added   OUTPUT,
             @evidence_removed                = @ev_removed OUTPUT,
             @evidence_kept                   = @ev_kept    OUTPUT;

        SELECT CAST(1 AS BIT) AS Success, N'Obligation added.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId,
               @ev_added AS EvidenceAdded, @ev_removed AS EvidenceRemoved, @ev_kept AS EvidenceKept;
        RETURN;
    END

    UPDATE grac_practice.practice_instance_obligation
       SET obligation_name        = @obligation_name,
           obligation_description = @obligation_description,
           obligation_type_code   = @obligation_type_code,
           typed_detail_json      = ISNULL(@typed_detail_json, typed_detail_json),
           execution_frequency_id = @execution_frequency_id,
           execution_frequency    = @execution_frequency,
           responsibility         = @responsibility,
           owner_employee_id      = CASE WHEN @owner_employee_id IS NULL THEN owner_employee_id
                                         ELSE NULLIF(@owner_employee_id, 0) END,   -- 412
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           implementation_status_id = COALESCE(@implementation_status_id, implementation_status_id),
           -- Migration 340: direct write, same contract as assurance_type
           -- above -- the edit form resends the whole payload, so absent
           -- really does mean "not event-driven any more".
           event_type_id          = @event_type_id,
           -- Migration 244: same "absent means keep" contract as the
           -- adopt proc uses for its overrides.
           connection_type_id     = COALESCE(@connection_type_id, connection_type_id),
           connection_url         = COALESCE(@connection_url,     connection_url),
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_obligation_id = @practice_instance_obligation_id
       AND practice_instance_id            = @practice_instance_id
       AND obligation_id IS NULL;

    IF @@ROWCOUNT = 0
        THROW 52700, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

    EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
         @practice_instance_id            = @practice_instance_id,
         @practice_instance_obligation_id = @practice_instance_obligation_id,
         @evidence_json                   = @evidence_json,
         @actor                           = @actor,
         @evidence_added                  = @ev_added   OUTPUT,
         @evidence_removed                = @ev_removed OUTPUT,
         @evidence_kept                   = @ev_kept    OUTPUT;

    SELECT CAST(1 AS BIT) AS Success, N'Obligation updated.' AS Message,
           @practice_instance_obligation_id AS PracticeInstanceObligationId,
           @ev_added AS EvidenceAdded, @ev_removed AS EvidenceRemoved, @ev_kept AS EvidenceKept;
END
GO

-- sp_practice_obligation_save (464 body + 513)
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_save
    @organization_id        BIGINT,
    @practice_id            BIGINT,
    @practice_obligation_id BIGINT        = 0,
    @obligation_name        NVARCHAR(500) = NULL,
    @obligation_description NVARCHAR(MAX) = NULL,
    @obligation_type_code   NVARCHAR(60)  = NULL,
    @typed_detail_json      NVARCHAR(MAX) = NULL,
    @execution_frequency_id INT           = NULL,
    @execution_frequency    NVARCHAR(120) = NULL,
    @responsibility         NVARCHAR(300) = NULL,
    -- 412: owner employee (NULL keep / 0 clear / > 0 set).
    @owner_employee_id      BIGINT        = NULL,
    @approval_authority     NVARCHAR(300) = NULL,
    @assurance_type         NVARCHAR(40)  = NULL,
    -- Migration 340: which event makes every fanned-out copy of this
    -- definition due. NULL means not event-driven. Same field, same
    -- meaning as sp_resolve_local_obligation_save's -- this is just the
    -- practice-level door onto it.
    @event_type_id          BIGINT        = NULL,
    @remarks                NVARCHAR(MAX) = NULL,
    @evidence_json          NVARCHAR(MAX) = NULL,
    @retire                 BIT           = 0,
    -- 464: the mirror of @retire. Retire never deleted anything -- the
    -- definition and every instance copy are still there carrying status
    -- 'Retired' -- so bringing one back is a status flip plus the same
    -- fan-out call. Optional and defaulted, so every existing caller is
    -- unaffected. @retire wins if both are set.
    @restore                BIT           = 0,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_id IS NULL
        THROW 57201, 'sp_practice_obligation_save: practice_id is required.', 1;

    DECLARE @practice_org_id BIGINT;
    SELECT @practice_org_id = organization_id
    FROM   grac_practice.practice
    WHERE  practice_id = @practice_id;

    IF @practice_org_id IS NULL
        THROW 57202, 'sp_practice_obligation_save: practice not found.', 1;

    -- The caller may name the organisation; if it does, it has to match.
    -- Scoped this way rather than trusting the parameter, so a practice
    -- id from another tenant cannot be written into this one.
    IF @organization_id IS NOT NULL AND @organization_id <> @practice_org_id
        THROW 57203, 'sp_practice_obligation_save: that practice belongs to another organization.', 1;

    SET @organization_id = @practice_org_id;

    -- ---- retire ----
    IF @retire = 1
    BEGIN
        IF ISNULL(@practice_obligation_id, 0) = 0
            THROW 57204, 'sp_practice_obligation_save: an id is required to retire an obligation.', 1;

        UPDATE grac_practice.practice_obligation
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_obligation_id = @practice_obligation_id
           AND practice_id           = @practice_id;

        IF @@ROWCOUNT = 0
            THROW 57205, 'sp_practice_obligation_save: no practice-level obligation with that id on this practice.', 1;

        -- Retiring the definition retires its copies everywhere, which is
        -- the fan-out's 3c branch -- so the same call does both halves.
        DECLARE @r_created INT = 0, @r_updated INT = 0, @r_retired INT = 0, @r_evidence INT = 0;
        EXEC grac_practice.sp_practice_obligation_fan_out
             @practice_id            = @practice_id,
             @practice_obligation_id = @practice_obligation_id,
             @actor                  = @actor,
             @copies_created         = @r_created  OUTPUT,
             @copies_updated         = @r_updated  OUTPUT,
             @copies_retired         = @r_retired  OUTPUT,
             @evidence_synced        = @r_evidence OUTPUT;

        SELECT CAST(1 AS BIT) AS Success,
               N'Obligation removed from the practice.' AS Message,
               @practice_obligation_id AS PracticeObligationId,
               @r_created  AS CopiesCreated,
               @r_updated  AS CopiesUpdated,
               @r_retired  AS CopiesRetired,
               @r_evidence AS EvidenceSynced;
        RETURN;
    END

    -- ---- restore ----
    --
    -- Symmetric with retire above, and deliberately as small: retire set
    -- `status` only, so restore sets `status` only. record_status_id was
    -- never touched on the way out and is not touched on the way back.
    --
    -- The fan-out does the rest and is reused, not reimplemented:
    --   * branch 3a brings every retired copy back Active (it writes
    --     status = N'Active' for an active definition and does not filter
    --     on the copy's current status), instead of duplicating it beside
    --     itself;
    --   * branch 3b creates a copy on any instance added while the
    --     definition was retired;
    --   * branch 3d re-syncs the declared evidence per copy, which revives
    --     a retired evidence row of the same type and leaves anything
    --     somebody had filled in alone.
    --
    -- Idempotent: restoring an already-Active definition writes the same
    -- status and simply refreshes the copies.
    IF @restore = 1
    BEGIN
        IF ISNULL(@practice_obligation_id, 0) = 0
            THROW 57215, 'sp_practice_obligation_save: an id is required to restore an obligation.', 1;

        UPDATE grac_practice.practice_obligation
           SET status     = N'Active',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_obligation_id = @practice_obligation_id
           AND practice_id           = @practice_id;

        IF @@ROWCOUNT = 0
            THROW 57205, 'sp_practice_obligation_save: no practice-level obligation with that id on this practice.', 1;

        DECLARE @c_created INT = 0, @c_updated INT = 0, @c_retired INT = 0, @c_evidence INT = 0;
        EXEC grac_practice.sp_practice_obligation_fan_out
             @practice_id            = @practice_id,
             @practice_obligation_id = @practice_obligation_id,
             @actor                  = @actor,
             @copies_created         = @c_created  OUTPUT,
             @copies_updated         = @c_updated  OUTPUT,
             @copies_retired         = @c_retired  OUTPUT,
             @evidence_synced        = @c_evidence OUTPUT;

        SELECT CAST(1 AS BIT) AS Success,
               N'Obligation restored on the practice.' AS Message,
               @practice_obligation_id AS PracticeObligationId,
               @c_created  AS CopiesCreated,
               @c_updated  AS CopiesUpdated,
               @c_retired  AS CopiesRetired,
               @c_evidence AS EvidenceSynced;
        RETURN;
    END

    -- ---- validate ----
    SET @obligation_name = NULLIF(LTRIM(RTRIM(@obligation_name)), N'');
    IF @obligation_name IS NULL
        THROW 57206, 'Obligation name is required.', 1;

    SET @obligation_type_code = NULLIF(LTRIM(RTRIM(@obligation_type_code)), N'');
    IF @obligation_type_code IS NULL
        THROW 57207, 'Obligation type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                    WHERE type_code = @obligation_type_code)
        THROW 57208, 'That obligation type does not exist.', 1;

    IF @typed_detail_json IS NOT NULL AND ISJSON(@typed_detail_json) <> 1
        THROW 57209, 'The rule detail must be valid JSON.', 1;

    IF @evidence_json IS NOT NULL AND ISJSON(@evidence_json) <> 1
        THROW 57210, 'The evidence list must be valid JSON.', 1;

    IF @assurance_type IS NOT NULL AND @assurance_type NOT IN (N'Manual', N'Automated')
        THROW 57211, 'Assurance type must be Manual or Automated.', 1;

    -- Migration 513: the event of a custom obligation.  The form keeps it
    -- in the typed detail (event_type_id, the Event Response column), so
    -- it is taken from there when the caller does not pass it -- no caller
    -- ever did, which is why a custom obligation's event never reached
    -- the event-driven checklists before 513.  Only an Event Response is
    -- event driven; every other type stores no event (an Assurance is
    -- Scheduled only since Control Management 086).
    IF @obligation_type_code = N'EventResponse'
        SET @event_type_id = COALESCE(
            @event_type_id,
            TRY_CAST(JSON_VALUE(COALESCE(@typed_detail_json, (
                SELECT x.typed_detail_json FROM grac_practice.practice_obligation x
                WHERE  x.practice_obligation_id = @practice_obligation_id)), '$[0].event_type_id') AS BIGINT));
    ELSE
        SET @event_type_id = NULL;

    -- Migration 340: reject a stale event_type_id. NULL is fine -- it
    -- means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 57213, 'sp_practice_obligation_save: unknown event type.', 1;

    -- 412: the Owner is an EMPLOYEE (a Functional User of this
    -- organization), no longer a role name. @owner_employee_id:
    --   NULL = leave the stored owner as it is (older callers),
    --   0    = clear the owner,
    --   > 0  = set it; responsibility (the display name every reader
    --          already shows) is written from the employee record.
    IF @owner_employee_id > 0
    BEGIN
        DECLARE @owner_name NVARCHAR(300) = (
            SELECT e.employee_name
            FROM   grac_practice.organization_employee e
            WHERE  e.employee_id        = @owner_employee_id
              AND  e.organization_id    = @organization_id
              AND  e.status             = N'Active'
              AND  e.is_functional_user = 1);
        IF @owner_name IS NULL
            THROW 57214, 'The obligation owner must be an active Functional User of this organization.', 1;
        SET @responsibility = @owner_name;
    END
    ELSE IF @owner_employee_id = 0
        SET @responsibility = NULL;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- ---- add ----
    IF ISNULL(@practice_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_obligation
            (organization_id, practice_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             execution_frequency_id, execution_frequency,
             responsibility, owner_employee_id, approval_authority, assurance_type, remarks,
             event_type_id,
             evidence_json, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_id,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             @execution_frequency_id, @execution_frequency,
             @responsibility, NULLIF(@owner_employee_id, 0), @approval_authority, @assurance_type, @remarks,
             @event_type_id,
             @evidence_json, N'Active', @active_record_status_id, @actor);

        SET @practice_obligation_id = SCOPE_IDENTITY();

        DECLARE @a_created INT = 0, @a_updated INT = 0, @a_retired INT = 0, @a_evidence INT = 0;
        EXEC grac_practice.sp_practice_obligation_fan_out
             @practice_id            = @practice_id,
             @practice_obligation_id = @practice_obligation_id,
             @actor                  = @actor,
             @copies_created         = @a_created  OUTPUT,
             @copies_updated         = @a_updated  OUTPUT,
             @copies_retired         = @a_retired  OUTPUT,
             @evidence_synced        = @a_evidence OUTPUT;

        SELECT CAST(1 AS BIT) AS Success,
               N'Obligation added to the practice.' AS Message,
               @practice_obligation_id AS PracticeObligationId,
               @a_created  AS CopiesCreated,
               @a_updated  AS CopiesUpdated,
               @a_retired  AS CopiesRetired,
               @a_evidence AS EvidenceSynced;
        RETURN;
    END

    -- ---- edit ----
    --
    -- evidence_json follows the "absent means unchanged" contract the
    -- rest of this module uses (see 232): NULL leaves the stored list
    -- alone, and an explicit empty array is how you say "no evidence".
    UPDATE grac_practice.practice_obligation
       SET obligation_name        = @obligation_name,
           obligation_description = @obligation_description,
           obligation_type_code   = @obligation_type_code,
           typed_detail_json      = ISNULL(@typed_detail_json, typed_detail_json),
           execution_frequency_id = @execution_frequency_id,
           execution_frequency    = @execution_frequency,
           responsibility         = @responsibility,
           owner_employee_id      = CASE WHEN @owner_employee_id IS NULL THEN owner_employee_id
                                         ELSE NULLIF(@owner_employee_id, 0) END,   -- 412
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           -- Migration 340: direct write, same contract as assurance_type
           -- above -- the definition's edit form resends the whole
           -- payload, so absent really does mean "not event-driven".
           event_type_id          = @event_type_id,
           evidence_json          = ISNULL(@evidence_json, evidence_json),
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_obligation_id = @practice_obligation_id
       AND practice_id            = @practice_id;

    IF @@ROWCOUNT = 0
        THROW 57205, 'sp_practice_obligation_save: no practice-level obligation with that id on this practice.', 1;

    DECLARE @e_created INT = 0, @e_updated INT = 0, @e_retired INT = 0, @e_evidence INT = 0;
    EXEC grac_practice.sp_practice_obligation_fan_out
         @practice_id            = @practice_id,
         @practice_obligation_id = @practice_obligation_id,
         @actor                  = @actor,
         @copies_created         = @e_created  OUTPUT,
         @copies_updated         = @e_updated  OUTPUT,
         @copies_retired         = @e_retired  OUTPUT,
         @evidence_synced        = @e_evidence OUTPUT;

    SELECT CAST(1 AS BIT) AS Success,
           N'Obligation saved.' AS Message,
           @practice_obligation_id AS PracticeObligationId,
           @e_created  AS CopiesCreated,
           @e_updated  AS CopiesUpdated,
           @e_retired  AS CopiesRetired,
           @e_evidence AS EvidenceSynced;
END
GO


-- =====================================================================
-- 4. Data
-- =====================================================================
IF OBJECT_ID('grac_practice.migration_513_obligation_backup','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.migration_513_obligation_backup(
        backup_id            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_mig513_backup PRIMARY KEY,
        source_table         NVARCHAR(60)  NOT NULL,   -- practice_obligation / practice_instance_obligation
        row_id               BIGINT        NOT NULL,
        obligation_type_code NVARCHAR(60)  NULL,
        typed_detail_json    NVARCHAR(MAX) NULL,
        event_type_id        BIGINT        NULL,
        sla_value            INT           NULL,
        sla_unit             NVARCHAR(20)  NULL,
        backed_up_dt         DATETIME2     NOT NULL
            CONSTRAINT df_pm_mig513_backup_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_mig513_backup_row UNIQUE (source_table, row_id)
    );
END
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- ---- 4a. custom obligations: Event Driven Assurance -> Event Response
INSERT grac_practice.migration_513_obligation_backup
       (source_table, row_id, obligation_type_code, typed_detail_json, event_type_id)
SELECT N'practice_obligation', po.practice_obligation_id,
       po.obligation_type_code, po.typed_detail_json, po.event_type_id
FROM   grac_practice.practice_obligation po
WHERE  po.obligation_type_code = N'Assurance'
  AND  ISJSON(po.typed_detail_json) = 1
  AND  JSON_VALUE(po.typed_detail_json, '$[0].trigger_mode') = N'EventDriven'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.migration_513_obligation_backup b
                   WHERE b.source_table = N'practice_obligation'
                     AND b.row_id = po.practice_obligation_id);

-- obligation_id IS NULL: an organization's own obligation, either
-- instance-only (227) or the instance copy of a practice-level one (307).
INSERT grac_practice.migration_513_obligation_backup
       (source_table, row_id, obligation_type_code, typed_detail_json, event_type_id, sla_value, sla_unit)
SELECT N'practice_instance_obligation', pio.practice_instance_obligation_id,
       pio.obligation_type_code, pio.typed_detail_json, pio.event_type_id, pio.sla_value, pio.sla_unit
FROM   grac_practice.practice_instance_obligation pio
WHERE  pio.obligation_id IS NULL
  AND  pio.obligation_type_code = N'Assurance'
  AND  ISJSON(pio.typed_detail_json) = 1
  AND  JSON_VALUE(pio.typed_detail_json, '$[0].trigger_mode') = N'EventDriven'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.migration_513_obligation_backup b
                   WHERE b.source_table = N'practice_instance_obligation'
                     AND b.row_id = pio.practice_instance_obligation_id);

-- The Event Response detail, in the column names the obligation form
-- stores (the Event Response table's own).  FOR JSON PATH makes the
-- one-element array the form reads; a NULL value is simply left out.
UPDATE po
SET    po.typed_detail_json    = (SELECT JSON_VALUE(b.typed_detail_json, '$[0].verification_method')            AS response_action,
                                         TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].event_type_id') AS BIGINT) AS event_type_id,
                                         TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].sla_days') AS INT)         AS sla_days
                                  FOR JSON PATH),
       po.event_type_id        = TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].event_type_id') AS BIGINT),
       po.obligation_type_code = N'EventResponse',
       po.updated_by           = N'migration-513',
       po.updated_dt           = SYSUTCDATETIME()
FROM   grac_practice.practice_obligation po
JOIN   grac_practice.migration_513_obligation_backup b
       ON b.source_table = N'practice_obligation' AND b.row_id = po.practice_obligation_id
WHERE  po.obligation_type_code = N'Assurance';

UPDATE pio
SET    pio.typed_detail_json    = (SELECT JSON_VALUE(b.typed_detail_json, '$[0].verification_method')            AS response_action,
                                          TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].event_type_id') AS BIGINT) AS event_type_id,
                                          TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].sla_days') AS INT)         AS sla_days
                                   FOR JSON PATH),
       pio.event_type_id        = TRY_CAST(JSON_VALUE(b.typed_detail_json, '$[0].event_type_id') AS BIGINT),
       pio.obligation_type_code = N'EventResponse',
       pio.updated_by           = N'migration-513',
       pio.updated_dt           = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.migration_513_obligation_backup b
       ON b.source_table = N'practice_instance_obligation' AND b.row_id = pio.practice_instance_obligation_id
WHERE  pio.obligation_id IS NULL
  AND  pio.obligation_type_code = N'Assurance';

-- ---- 4b / 4c. adopted catalogue obligations on an instance
INSERT grac_practice.migration_513_obligation_backup
       (source_table, row_id, obligation_type_code, typed_detail_json, event_type_id, sla_value, sla_unit)
SELECT N'practice_instance_obligation', pio.practice_instance_obligation_id,
       pio.obligation_type_code, pio.typed_detail_json, pio.event_type_id, pio.sla_value, pio.sla_unit
FROM   grac_practice.practice_instance_obligation pio
WHERE  pio.obligation_id IS NOT NULL
  AND  (   (pio.obligation_type_code = N'Assurance'
            AND pio.obligation_id IN (SELECT c.obligation_id FROM GRAC_New.migration_086_assurance_conversion c))
        OR (pio.obligation_type_code = N'EventResponse'
            AND pio.sla_value IS NOT NULL AND ISNULL(pio.sla_unit, N'') <> N'Days'))
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.migration_513_obligation_backup b
                   WHERE b.source_table = N'practice_instance_obligation'
                     AND b.row_id = pio.practice_instance_obligation_id);

UPDATE pio
SET    pio.obligation_type_code = N'EventResponse',
       pio.updated_by           = N'migration-513',
       pio.updated_dt           = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.migration_513_obligation_backup b
       ON b.source_table = N'practice_instance_obligation' AND b.row_id = pio.practice_instance_obligation_id
WHERE  pio.obligation_id IS NOT NULL
  AND  pio.obligation_type_code = N'Assurance'
  AND  pio.obligation_id IN (SELECT c.obligation_id FROM GRAC_New.migration_086_assurance_conversion c);

-- The instance's "Due within" override, in days.
UPDATE pio
SET    pio.sla_value  = CASE WHEN d.days > 3650 THEN 3650 WHEN d.days < 0 THEN 0 ELSE d.days END,
       pio.sla_unit   = N'Days',
       pio.updated_by = N'migration-513',
       pio.updated_dt = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.migration_513_obligation_backup b
       ON b.source_table = N'practice_instance_obligation' AND b.row_id = pio.practice_instance_obligation_id
CROSS APPLY (SELECT CAST(CASE ISNULL(pio.sla_unit, N'Days')
                             WHEN N'Hours'  THEN CEILING(pio.sla_value / 24.0)
                             WHEN N'Weeks'  THEN pio.sla_value * 7
                             WHEN N'Months' THEN pio.sla_value * 30
                             WHEN N'Years'  THEN pio.sla_value * 365
                             ELSE pio.sla_value
                         END AS INT) AS days) d
WHERE  pio.obligation_type_code = N'EventResponse'
  AND  pio.sla_value IS NOT NULL
  AND  ISNULL(pio.sla_unit, N'') <> N'Days';

COMMIT;
GO

-- =====================================================================
-- 5. Report
-- =====================================================================
PRINT '513 complete. Restart the API and the Web app.';
GO

-- 513-a  every change this migration made (backup rows)
SELECT N'513-a converted' AS [Check], b.source_table AS SourceTable, b.row_id AS RowId,
       b.obligation_type_code AS WasType,
       COALESCE(po.obligation_type_code, pio.obligation_type_code) AS NowType,
       COALESCE(po.event_type_id, pio.event_type_id) AS EventTypeId
FROM   grac_practice.migration_513_obligation_backup b
LEFT JOIN grac_practice.practice_obligation po
       ON b.source_table = N'practice_obligation' AND po.practice_obligation_id = b.row_id
LEFT JOIN grac_practice.practice_instance_obligation pio
       ON b.source_table = N'practice_instance_obligation' AND pio.practice_instance_obligation_id = b.row_id
ORDER BY b.source_table, b.row_id;
GO

-- 513-b  the view sees Event Response copies.  PASS once any organization
--        has approved 086's update (or a custom Event Response exists);
--        before that the legacy branch carries the same rows.
SELECT N'513-b view shape' AS [Check],
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_event_driven_obligation'))
                 LIKE '%event_responses_json%'
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO

-- 513-c  the save procedures take the event from the detail
SELECT N'513-c save procs' AS [Check],
       -- (no "[0]" in the pattern: LIKE reads brackets as a character class)
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save')) LIKE '%Migration 513%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save'))      LIKE '%Migration 513%'
            THEN N'PASS' ELSE N'FAIL' END AS Result;
GO

-- 513-d  Event Response obligations reaching each organization's
--        checklists (catalogue + custom), per event.
SELECT N'513-d event-driven obligations' AS [Check], v.organization_id AS OrganizationId,
       v.event_type_name AS Event, COUNT(*) AS Obligations
FROM   grac_practice.vw_pm_event_driven_obligation v
GROUP BY v.organization_id, v.event_type_name
ORDER BY v.organization_id, v.event_type_name;
GO

SET NOEXEC OFF;
GO
