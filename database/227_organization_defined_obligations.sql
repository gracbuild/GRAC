-- =====================================================================
-- 227 Organisation-defined obligations
--
-- WHAT THIS ADDS
-- --------------
-- Alongside adopting what the authority published, an organisation can
-- now add an obligation of its own to a practice instance -- and the
-- rule fields it is asked for follow the type it picks, the same way
-- Control Management's own obligation form does.
--
-- SCOPE: ONE INSTANCE
-- -------------------
-- A locally added obligation belongs to the practice instance it was
-- added on. practice_instance_obligation is keyed that way, and a
-- practice usually has several instances (Configure creates one per
-- team, migration 139), so "add it once, it appears everywhere" would
-- need a practice-level table and a fan-out rule for instances created
-- afterwards. That is a separate piece of work; this is the smaller,
-- honest version.
--
-- HOW A LOCAL OBLIGATION IS RECOGNISED
-- ------------------------------------
-- obligation_id IS NULL. That column is a soft reference into
-- GRAC_New.requirement_obligation, and a locally added obligation has no
-- row there -- so NULL is the truthful value, not a flag bolted on
-- beside it. inherited_from_repository is set to 0 to match.
--
--   * obligation_id becomes NULLable.
--   * UNIQUE(practice_instance_id, obligation_id) is replaced by a
--     FILTERED unique index. SQL Server treats NULLs as equal in a
--     UNIQUE constraint, so leaving it in place would allow exactly ONE
--     locally added obligation per instance -- which is not a rule
--     anybody asked for, and a confusing error when the second one is
--     added. The filtered index keeps the rule where it means something:
--     the same published obligation cannot be adopted twice.
--
-- WHY THE RULE DETAIL IS JSON AND NOT SIX TABLES
-- ----------------------------------------------
-- The published side keeps its typed detail in six tables in GRAC_New,
-- one per obligation type, owned by Control Management. Mirroring those
-- six in grac_practice would mean copying a schema this module does not
-- own and cannot see change -- the same coupling that made migration 225
-- necessary.
--
-- Instead the local detail is one NVARCHAR(MAX) column holding the same
-- JSON array shape vw_pm_obligation_typed_detail emits. Nothing queries
-- that detail relationally today: the card renders it, and the renderer
-- (resolve-workspace.cshtml, migration 225) was already written to show
-- whatever keys arrive. So the local and published halves come out of
-- sp_resolve_obligation_list in the same shape and the screen cannot
-- tell them apart -- which is the point.
--
-- AND WHERE THE FIELD LIST COMES FROM
-- -----------------------------------
-- sp_resolve_obligation_type_fields reads sys.columns of the Control
-- Management table for the chosen type and returns it. The add form
-- builds its inputs from that, so it offers exactly the fields CM's own
-- form offers, and a column CM adds appears here with no PM change --
-- the same discipline migration 225 applied to the display side.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: guarded ALTERs, CREATE OR ALTER procedures.
--
-- Error codes 52690-52699 (52670-52689 belong to 222).
-- DEPENDS ON: 140 (the table), 141 (the procedures), 224/225 (the typed
--             view and the generic renderer), 226 (assurance_type).
-- Rollback:   database/227_organization_defined_obligations_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (227): practice_instance_obligation missing. Run 140 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.practice_instance_obligation','assurance_type') IS NULL
BEGIN
    PRINT 'ABORT (227): assurance_type missing. Run 226 first -- this migration re-issues sp_resolve_obligation_list, which returns it.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (227): vw_pm_obligation_typed_detail missing. Run 224 and 225 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (227): GRAC_New.obligation_type_master missing. Apply Control Management 026 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('227_organization_defined_obligations: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schema
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_obligation','obligation_description') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD obligation_description NVARCHAR(MAX) NULL;
    PRINT '227: obligation_description added.';
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','typed_detail_json') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD typed_detail_json NVARCHAR(MAX) NULL;
    PRINT '227: typed_detail_json added.';
END
GO

-- The constraint has to go before the column can be made NULLable.
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_practice_instance_obligation')
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        DROP CONSTRAINT uq_pm_practice_instance_obligation;
    PRINT '227: uq_pm_practice_instance_obligation dropped (replaced by a filtered index below).';
END
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.practice_instance_obligation')
              AND name = 'obligation_id' AND is_nullable = 0)
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ALTER COLUMN obligation_id BIGINT NULL;
    PRINT '227: obligation_id is now NULLable.';
END
GO

-- Filtered: the rule is "the same PUBLISHED obligation cannot be adopted
-- twice on one instance". It says nothing about locally added ones, and
-- an unfiltered unique index would cap them at one per instance because
-- SQL Server treats NULLs as equal here.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_pio_instance_obligation'
                  AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
BEGIN
    CREATE UNIQUE INDEX ux_pm_pio_instance_obligation
        ON grac_practice.practice_instance_obligation(practice_instance_id, obligation_id)
        WHERE obligation_id IS NOT NULL;
    PRINT '227: ux_pm_pio_instance_obligation created.';
END
GO

-- =====================================================================
-- 2. sp_resolve_obligation_type_fields
--
--    The field list for one obligation type, read from the Control
--    Management table that type's detail lives in. The add form builds
--    its inputs from this, so it asks for what CM asks for.
--
--    Type codes are matched with punctuation and case stripped, because
--    obligation_type_master.type_code is CM's vocabulary and this module
--    should not depend on its exact spelling ('EventResponse',
--    'EVENT_RESPONSE' and 'Event Response' all resolve).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_fields
    @type_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(ISNULL(@type_code, N''))), N'') IS NULL
        THROW 52690, 'sp_resolve_obligation_type_fields: type_code is required.', 1;

    DECLARE @norm NVARCHAR(60) =
        LOWER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@type_code)), N'_', N''), N'-', N''), N' ', N''));

    DECLARE @table SYSNAME = (
        SELECT TOP 1 t.table_name
        FROM (VALUES
            (N'state',         N'obligation_state_rule'),
            (N'staterule',     N'obligation_state_rule'),
            (N'execution',     N'obligation_execution_spec'),
            (N'executionspec', N'obligation_execution_spec'),
            (N'assurance',     N'obligation_assurance_spec'),
            (N'assurancespec', N'obligation_assurance_spec'),
            (N'eventresponse', N'obligation_event_response'),
            (N'event',         N'obligation_event_response'),
            (N'constraint',    N'obligation_constraint_rule'),
            (N'constraintrule',N'obligation_constraint_rule'),
            (N'retention',     N'obligation_retention_spec'),
            (N'retentionspec', N'obligation_retention_spec'),
            (N'evidence',      N'requirement_obligation_evidence')
        ) AS t(code, table_name)
        WHERE t.code = @norm);

    IF @table IS NULL
    BEGIN
        -- Not an error: a type with no detail table simply has no rule
        -- fields, and the form should show none rather than refuse.
        --
        -- The empty set still has to have the SAME SHAPE as the populated
        -- one -- INSERT ... EXEC matches by position and fails on a
        -- column-count mismatch, and the verification block below does
        -- exactly that.
        SELECT CAST(NULL AS SYSNAME)  AS TableName,
               CAST(NULL AS SYSNAME)  AS ColumnName,
               CAST(NULL AS SYSNAME)  AS DataType,
               CAST(NULL AS INT)      AS MaxLength,
               CAST(NULL AS BIT)      AS IsNullable,
               CAST(NULL AS INT)      AS Ordinal,
               CAST(NULL AS BIT)      AS IsReference
        WHERE  1 = 0;
        RETURN;
    END

    -- Housekeeping columns are the ones the form must never offer: the
    -- surrogate key, the owning id, the row's own status and audit
    -- stamps. Everything else is a field Control Management captures.
    SELECT @table                       AS TableName,
           c.name                       AS ColumnName,
           ty.name                      AS DataType,
           c.max_length                 AS MaxLength,
           c.is_nullable                AS IsNullable,
           c.column_id                  AS Ordinal,
           CAST(CASE WHEN c.name LIKE '%[_]id' THEN 1 ELSE 0 END AS BIT) AS IsReference
    FROM   sys.columns c
    JOIN   sys.tables  t  ON t.object_id = c.object_id
    JOIN   sys.schemas s  ON s.schema_id = t.schema_id
    JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
    WHERE  s.name = 'GRAC_New'
      AND  t.name = @table
      AND  c.is_computed = 0
      AND  c.name NOT IN ('obligation_id', 'status', 'record_status_id',
                          'entered_by', 'entered_dt', 'updated_by', 'updated_dt',
                          'display_order', 'is_active')
      AND  c.name <> (SELECT TOP 1 c2.name FROM sys.columns c2
                       WHERE c2.object_id = t.object_id AND c2.is_identity = 1)
    ORDER  BY c.column_id;
END
GO

-- =====================================================================
-- 2b. sp_resolve_obligation_type_list
--
--     The types the add form can offer. A dedicated procedure rather
--     than a new key on the shared lookups feed: that feed lives in
--     dbo.pm_get_practice_repository, a 1580-line dispatcher, and adding
--     one UNION branch to it would mean CREATE OR ALTER on the whole
--     thing -- the same blast radius migration 122 declined to take for
--     the same reason.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_list
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.obligation_type_id AS ObligationTypeId,
           t.type_code          AS TypeCode,
           t.type_name          AS TypeName,
           t.display_order      AS DisplayOrder
    FROM   GRAC_New.obligation_type_master t
    ORDER  BY ISNULL(t.display_order, 999), t.type_name;
END
GO

-- =====================================================================
-- 3. sp_resolve_local_obligation_save
--
--    Add, edit or retire one organisation-defined obligation.
--    @practice_instance_obligation_id = 0 adds; anything else edits the
--    row with that id, and only if it belongs to this instance AND has
--    obligation_id IS NULL -- an adopted published obligation must not
--    be editable through this door.
-- =====================================================================
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
    @approval_authority              NVARCHAR(300) = NULL,
    @assurance_type                  NVARCHAR(40)  = NULL,
    @remarks                         NVARCHAR(MAX) = NULL,
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

    -- Same ownership test every other Resolve procedure applies.
    IF @is_admin = 0 AND ISNULL(@owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52693, 'sp_resolve_local_obligation_save: this practice instance belongs to another owner.', 1;

    -- ---- retire ----
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

        SELECT CAST(1 AS BIT) AS Success, N'Obligation removed.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId;
        RETURN;
    END

    -- ---- validate ----
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

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    -- ---- add ----
    IF ISNULL(@practice_instance_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_instance_obligation
            (organization_id, practice_instance_id, obligation_id, release_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             inherited_from_repository, organization_modified,
             execution_frequency_id, execution_frequency,
             responsibility, approval_authority, assurance_type, remarks,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             -- Not inherited, and organisation-defined is by definition
             -- an organisation modification.
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
             @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

        SET @practice_instance_obligation_id = SCOPE_IDENTITY();

        SELECT CAST(1 AS BIT) AS Success, N'Obligation added.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId;
        RETURN;
    END

    -- ---- edit ----
    UPDATE grac_practice.practice_instance_obligation
       SET obligation_name        = @obligation_name,
           obligation_description = @obligation_description,
           obligation_type_code   = @obligation_type_code,
           typed_detail_json      = ISNULL(@typed_detail_json, typed_detail_json),
           execution_frequency_id = @execution_frequency_id,
           execution_frequency    = @execution_frequency,
           responsibility         = @responsibility,
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_obligation_id = @practice_instance_obligation_id
       AND practice_instance_id            = @practice_instance_id
       -- The guard that matters: this door only opens on locally added
       -- rows. An adopted published obligation is edited through
       -- sp_resolve_obligation_adopt, which derives organization_modified
       -- against what was published -- a concept a local row has no
       -- counterpart for.
       AND obligation_id IS NULL;

    IF @@ROWCOUNT = 0
        THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

    SELECT CAST(1 AS BIT) AS Success, N'Obligation saved.' AS Message,
           @practice_instance_obligation_id AS PracticeInstanceObligationId;
END
GO

-- =====================================================================
-- 4. sp_resolve_obligation_list -- re-issued
--
--    The 226 body plus a UNION ALL for the organisation-defined rows,
--    and three columns both halves now carry: RowKey (the card's
--    identity, since a local row has no obligation_id),
--    IsOrganizationDefined, and SortOrder (a UNION has to be sorted by
--    an output column, not by a source expression).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_list
    @practice_instance_id BIGINT,
    @include_unsubscribed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52604, 'sp_resolve_obligation_list: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @practice_id BIGINT;
    SELECT @organization_id = organization_id, @practice_id = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52605, 'sp_resolve_obligation_list: instance not found.', 1;

    ;WITH reachable AS (
        SELECT orm.obligation_id,
               orm.release_id,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                       WHERE s.organization_id = @organization_id
                                         AND s.release_id = orm.release_id
                                         AND s.status = N'Active')
                         THEN 1 ELSE 0 END AS BIT) AS is_subscribed
        FROM   grac_practice.practice pp
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = pp.organization_requirement_id
        LEFT   JOIN GRAC_New.requirement repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   GRAC_New.obligation_requirement_release_map orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    -- One row per obligation. Where the same obligation rides several
    -- subscribed releases, the lowest release_id is the representative --
    -- an arbitrary but stable choice, so the card does not reshuffle
    -- between loads.
    picked AS (
        SELECT obligation_id,
               MIN(release_id)      AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT * FROM (
    SELECT
        o.obligation_id                 AS ObligationId,
        CAST(0 AS BIT)                  AS IsOrganizationDefined,
        N'p' + CAST(o.obligation_id AS NVARCHAR(20)) AS RowKey,
        ISNULL(t.display_order, 999)    AS SortOrder,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        -- Same value as ObligationText. Named separately because the card
        -- shows it under a "Description" heading, and a caller reading
        -- ObligationText for the title fallback should not have to know
        -- that the two uses are the same column today.
        o.obligation_text               AS ObligationDescription,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        -- As published. Kept for the pre-taxonomy obligations that still
        -- carry only these, and as the fallback when a typed obligation
        -- has no detail rows yet.
        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        -- Typed detail (224). Whichever array matches TypeCode is what
        -- the admin module actually captured for this obligation.
        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS PublishedEvidenceJson,

        -- As adopted here. NULL until the organization adopts it.
        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        -- What adopting will create, and what already exists.
        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount
    FROM   picked pk
    JOIN   GRAC_New.requirement_obligation o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
           ON td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT roe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   GRAC_New.requirement_obligation_evidence roe
        WHERE  roe.obligation_id = pk.obligation_id
    ) ev

    -- -----------------------------------------------------------------
    -- Organisation-defined obligations (migration 227).
    --
    -- These have no row in GRAC_New at all -- obligation_id IS NULL is
    -- what says so -- so they cannot come through the CTE above, which
    -- starts from the published obligation map. They are read straight
    -- off the adoption table.
    --
    -- Column order and count must match the half above exactly; a UNION
    -- lines them up by position, not by name.
    -- -----------------------------------------------------------------
    UNION ALL
    SELECT
        CAST(NULL AS BIGINT)            AS ObligationId,
        CAST(1 AS BIT)                  AS IsOrganizationDefined,
        N'l' + CAST(pio.practice_instance_obligation_id AS NVARCHAR(20)) AS RowKey,
        -- Local ones sort after every published type, in the order they
        -- were added.
        1000 + CAST(pio.practice_instance_obligation_id % 1000 AS INT) AS SortOrder,
        pio.obligation_name             AS ObligationName,
        pio.obligation_description      AS ObligationText,
        pio.obligation_description      AS ObligationDescription,
        pio.obligation_type_code        AS TypeCode,
        lt.type_name                    AS TypeName,
        CAST(NULL AS BIGINT)            AS ReleaseId,
        CAST(NULL AS NVARCHAR(400))     AS FrameworkRelease,
        CAST(1 AS BIT)                  AS IsSubscribed,

        -- Nothing was published, so there is no published side. NULL
        -- rather than a copy of the adopted value: the card contrasts
        -- the two, and showing them as equal would be a lie.
        CAST(NULL AS NVARCHAR(200))     AS PublishedExecutionFrequency,
        CAST(NULL AS NVARCHAR(300))     AS PublishedResponsibility,
        CAST(NULL AS NVARCHAR(300))     AS PublishedApprovalAuthority,
        CAST(NULL AS NVARCHAR(200))     AS PublishedRetention,

        -- The organisation's own rule detail, put in the column its type
        -- maps to so the card renders it exactly like a published one.
        CASE WHEN pio.obligation_type_code = N'State'         THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS StateRulesJson,
        CASE WHEN pio.obligation_type_code = N'Execution'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ExecutionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Assurance'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS AssuranceSpecsJson,
        CASE WHEN pio.obligation_type_code = N'EventResponse' THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS EventResponsesJson,
        CASE WHEN pio.obligation_type_code = N'Constraint'    THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ConstraintRulesJson,
        CASE WHEN pio.obligation_type_code = N'Retention'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS RetentionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Evidence'      THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS PublishedEvidenceJson,

        pio.practice_instance_obligation_id AS AdoptionId,
        CAST(1 AS BIT)                  AS IsAdopted,
        CAST(1 AS BIT)                  AS OrganizationModified,
        pio.execution_frequency_id      AS ExecutionFrequencyId,
        pio.execution_frequency         AS ExecutionFrequency,
        pio.assurance_frequency_id      AS AssuranceFrequencyId,
        pio.assurance_frequency         AS AssuranceFrequency,
        pio.responsibility              AS Responsibility,
        pio.approval_authority          AS ApprovalAuthority,
        pio.retention_period            AS RetentionPeriod,
        pio.assurance_type              AS AdoptedAssuranceType,
        pio.remarks                     AS Remarks,
        pio.adopted_by                  AS AdoptedBy,
        pio.adopted_dt                  AS AdoptedDt,

        0                               AS PublishedEvidenceCount,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie2
          WHERE pie2.practice_instance_id = @practice_instance_id
            AND pie2.source_obligation_id IS NULL
            AND pie2.status = N'Active')  AS ResolvedEvidenceCount
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN GRAC_New.obligation_type_master lt
           ON lt.type_code = pio.obligation_type_code
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.obligation_id IS NULL
      AND  pio.status = N'Active'
    ) x
    -- After a UNION the sort has to use the output columns, not the
    -- source expressions -- hence SortOrder carried through both halves.
    ORDER  BY x.SortOrder, x.ObligationName;
END
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
PRINT '=== 227 verification ===';

SELECT 'obligation_id is NULLable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.practice_instance_obligation')
                            AND name = 'obligation_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'filtered unique index present',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_pio_instance_obligation'
                            AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation')
                            AND has_filter = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'old unique constraint gone',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_practice_instance_obligation')
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'typed_detail_json + obligation_description present',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','typed_detail_json') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_instance_obligation','obligation_description') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'type field procedure present',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'type list procedure present',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'local save procedure present',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'list returns RowKey',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P')) LIKE '%RowKey%'
            THEN 'PASS' ELSE 'FAIL' END;

-- The type codes the add form will offer, and whether each resolves to a
-- Control Management detail table. A type showing 0 fields is not
-- broken: it means CM keeps no per-type detail for it, and the form will
-- ask only for name, description and the adoption parameters.
PRINT '=== Obligation types and how many rule fields each offers ===';
DECLARE @codes TABLE (type_code NVARCHAR(60), type_name NVARCHAR(120));
INSERT @codes (type_code, type_name)
SELECT type_code, type_name FROM GRAC_New.obligation_type_master;

DECLARE @c NVARCHAR(60), @n NVARCHAR(120);
DECLARE @report TABLE (TypeCode NVARCHAR(60), TypeName NVARCHAR(120), RuleFields INT);
DECLARE type_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT type_code, type_name FROM @codes;
OPEN type_cursor;
FETCH NEXT FROM type_cursor INTO @c, @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @fields TABLE (TableName SYSNAME NULL, ColumnName SYSNAME NULL, DataType SYSNAME NULL,
                           MaxLength INT NULL, IsNullable BIT NULL, Ordinal INT NULL, IsReference BIT NULL);
    DELETE @fields;
    INSERT @fields EXEC grac_practice.sp_resolve_obligation_type_fields @type_code = @c;
    INSERT @report (TypeCode, TypeName, RuleFields) SELECT @c, @n, COUNT(*) FROM @fields;
    FETCH NEXT FROM type_cursor INTO @c, @n;
END
CLOSE type_cursor;
DEALLOCATE type_cursor;

SELECT TypeCode, TypeName, RuleFields FROM @report ORDER BY TypeCode;

PRINT '';
PRINT '227 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
