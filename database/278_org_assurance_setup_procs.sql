-- =====================================================================
-- 278 Audit setup procedures (Phase 2)
--
-- Three procedures:
--   sp_org_assurance_definition_question_set_get
--   sp_org_assurance_definition_question_set_save
--   sp_org_assurance_setup_status
--
-- The first two mirror sp_org_assurance_evidence_config_get / _save
-- (migration 080) exactly -- same ownership check, same Draft-only rule,
-- same full-replacement save from a JSON array. The third backs the
-- Completed / In Progress / Not Configured chips on the Audit Definition
-- and Audit Configuration tab strips.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/278_org_assurance_setup_procs_rollback.sql
-- DEPENDS ON: 069, 073, 076, 079, 083, 086, 092, 095, 277.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NULL
BEGIN
    PRINT 'ABORT (278): org_assurance_definition_question_set missing. Run 277 first.';
    RAISERROR('278_org_assurance_setup_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_question_set_get
--
--   Result set 1 -- header (same shape as evidence config's header, so
--                   the UI can reuse its isEditable handling).
--   Result set 2 -- the sets this version has adopted.
--   Result set 3 -- every active set in the organization, so the picker
--                   can offer what is not yet adopted without a second
--                   round trip.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_question_set_get
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    -- Header.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- Adopted sets.
    SELECT dqs.org_assurance_definition_question_set_id AS DefinitionQuestionSetId,
           dqs.org_assurance_question_set_id            AS QuestionSetId,
           qs.set_code                                  AS SetCode,
           qs.set_name                                  AS SetName,
           dqs.display_order                            AS DisplayOrder,
           dqs.is_mandatory                             AS IsMandatory,
           (SELECT COUNT(*)
              FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)                     AS QuestionCount
    FROM grac_practice.org_assurance_definition_question_set dqs
    JOIN grac_practice.org_assurance_question_set qs
         ON qs.org_assurance_question_set_id = dqs.org_assurance_question_set_id
    WHERE dqs.organization_id = @organization_id
      AND dqs.org_assurance_definition_version_id = @version_id
      AND dqs.is_active = 1
    ORDER BY dqs.display_order, dqs.org_assurance_definition_question_set_id;

    -- Every set available to adopt.
    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.set_code                      AS SetCode,
           qs.set_name                      AS SetName,
           (SELECT COUNT(*)
              FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)         AS QuestionCount
    FROM grac_practice.org_assurance_question_set qs
    WHERE qs.organization_id = @organization_id
      AND qs.is_active = 1
    ORDER BY qs.set_name;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_question_set_save
--
--   Full-replacement save for the CURRENT version, Draft only -- the
--   same contract as evidence / workflow / scoring config.
--
--   @items_json shape:
--   [ { "questionSetId": 12, "displayOrder": 1, "isMandatory": true } ]
--
--   A set that does not belong to this organization, or is inactive, is
--   rejected rather than silently skipped: a half-applied adoption list
--   is worse than a failed save.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_question_set_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @items_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @items_json IS NULL SET @items_json = N'[]';
    IF ISJSON(@items_json) = 0
        THROW 53703, 'items_json is not a valid JSON document.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Question sets can only be adopted while the current version is Draft.', 1;

    DECLARE @incoming TABLE(
        question_set_id BIGINT NOT NULL,
        display_order   INT    NULL,
        is_mandatory    BIT    NULL);

    INSERT INTO @incoming(question_set_id, display_order, is_mandatory)
    SELECT x.questionSetId, x.displayOrder, x.isMandatory
    FROM OPENJSON(@items_json)
    WITH (
        questionSetId BIGINT '$.questionSetId',
        displayOrder  INT    '$.displayOrder',
        isMandatory   BIT    '$.isMandatory'
    ) AS x
    WHERE x.questionSetId IS NOT NULL;

    -- Reject duplicates in the payload -- the unique index would catch
    -- them, but the message here is far clearer.
    IF EXISTS (SELECT 1 FROM @incoming GROUP BY question_set_id HAVING COUNT(*) > 1)
        THROW 53712, 'The same question set was listed more than once.', 1;

    -- Reject anything that is not an active set in this organization.
    IF EXISTS (
        SELECT 1
        FROM @incoming i
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_set qs
             WHERE qs.org_assurance_question_set_id = i.question_set_id
               AND qs.organization_id = @organization_id
               AND qs.is_active = 1))
        THROW 53713, 'One or more question sets do not exist in this organization.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.org_assurance_definition_question_set
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    INSERT INTO grac_practice.org_assurance_definition_question_set
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, org_assurance_question_set_id,
         display_order, is_mandatory,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @definition_id,
           @current_version_id,
           @organization_id,
           i.question_set_id,
           ISNULL(i.display_order, 0),
           ISNULL(i.is_mandatory, 1),
           1, @active_record_status_id, @actor, SYSUTCDATETIME()
    FROM @incoming i;

    COMMIT TRAN;

    SELECT CAST(1 AS BIT) AS Success,
           @definition_id      AS DefinitionId,
           @current_version_id AS VersionId,
           (SELECT COUNT(*) FROM @incoming) AS AdoptedCount;
END
GO

-- =====================================================================
-- sp_org_assurance_setup_status
--
--   One row per setup step for a definition's current version, driving
--   the tab chips. Status vocabulary:
--
--     Completed      -- the step has the rows it needs
--     InProgress     -- a header exists but its detail rows do not, so
--                       somebody started and stopped. Only Workflow and
--                       Scoring can be half-done; the rest are a single
--                       collection and are therefore binary.
--     NotConfigured  -- nothing recorded for this version
--
--   StepKey matches the AuditFlowStep keys in the Web tier
--   (org-audit-definition.cshtml / org-audit-configuration.cshtml), so
--   the shell can map a row straight onto a tab.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_setup_status
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    DECLARE @scope_groups   INT = 0,
            @question_sets  INT = 0,
            @evidence_rows  INT = 0,
            @workflow_cfg   INT = 0,
            @workflow_stage INT = 0,
            @scoring_cfg    INT = 0,
            @scoring_band   INT = 0,
            @trigger_rows   INT = 0,
            @resolutions    INT = 0;

    SELECT @scope_groups = COUNT(*)
      FROM grac_practice.org_assurance_scope_group g
     WHERE g.org_assurance_definition_version_id = @version_id
       AND g.organization_id = @organization_id
       AND g.is_active = 1;

    SELECT @question_sets = COUNT(*)
      FROM grac_practice.org_assurance_definition_question_set q
     WHERE q.org_assurance_definition_version_id = @version_id
       AND q.organization_id = @organization_id
       AND q.is_active = 1;

    SELECT @evidence_rows = COUNT(*)
      FROM grac_practice.org_assurance_evidence_config e
     WHERE e.org_assurance_definition_version_id = @version_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;

    SELECT @workflow_cfg = COUNT(*)
      FROM grac_practice.org_assurance_workflow_config w
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1;

    SELECT @workflow_stage = COUNT(*)
      FROM grac_practice.org_assurance_workflow_stage st
      JOIN grac_practice.org_assurance_workflow_config w
           ON w.org_assurance_workflow_config_id = st.org_assurance_workflow_config_id
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1
       AND st.is_active = 1;

    SELECT @scoring_cfg = COUNT(*)
      FROM grac_practice.org_assurance_scoring_config sc
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1;

    SELECT @scoring_band = COUNT(*)
      FROM grac_practice.org_assurance_scoring_band b
      JOIN grac_practice.org_assurance_scoring_config sc
           ON sc.org_assurance_scoring_config_id = b.org_assurance_scoring_config_id
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1
       AND b.is_active  = 1;

    SELECT @trigger_rows = COUNT(*)
      FROM grac_practice.org_assurance_trigger_config t
     WHERE t.org_assurance_definition_version_id = @version_id
       AND t.organization_id = @organization_id
       AND t.is_active = 1;

    SELECT @resolutions = COUNT(*)
      FROM grac_practice.org_assurance_scope_resolution r
     WHERE r.org_assurance_definition_version_id = @version_id
       AND r.organization_id = @organization_id;

    -- Header, so the caller knows which version was measured.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- One row per step. "details" is Completed by definition: the audit
    -- exists and has a version, or this procedure would have thrown.
    SELECT StepKey, StepName, ItemCount, Status
    FROM (VALUES
        (N'details',          N'Audit Details',      1,
            N'Completed'),
        (N'scope',            N'Scope Builder',      @scope_groups,
            CASE WHEN @scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'questions',        N'Question Sets',      @question_sets,
            CASE WHEN @question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'evidence',         N'Evidence',           @evidence_rows,
            CASE WHEN @evidence_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'workflow',         N'Workflow',           @workflow_stage,
            CASE WHEN @workflow_stage > 0 THEN N'Completed'
                 WHEN @workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'scoring',          N'Scoring',            @scoring_band,
            CASE WHEN @scoring_cfg  > 0 AND @scoring_band > 0 THEN N'Completed'
                 WHEN @scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'trigger',          N'Trigger',            @trigger_rows,
            CASE WHEN @trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'scope-resolution', N'Scope Resolution',   @resolutions,
            CASE WHEN @resolutions  > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepKey, StepName, ItemCount, Status);
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'question set get proc'  AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_get','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'question set save proc' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'setup status proc'      AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_setup_status','P')                 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '278 Audit setup procedures complete.';
GO
SET NOEXEC OFF;
GO
