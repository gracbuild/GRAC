-- =====================================================================
-- 340 Event type on organisation-authored obligations
--
-- WHAT AND WHY
-- ------------
-- Event Profiles' Checklists tab (this feature, see docs/event-profiles.md
-- once 344 lands) has to list every event-driven obligation, catalog and
-- organisation-authored alike, and "View Mapped Profiles" has to answer
-- "which profiles receive THIS one" for both kinds too. Both need an
-- event_type_id to key off. A catalog obligation gets one from
-- GRAC_New.obligation_assurance_spec (trigger_mode = 'EventDriven'); an
-- organisation-authored one has never had anywhere to put one at all.
--
-- 234 added practice_instance_obligation.event_type_id, but wired it into
-- exactly one door: sp_resolve_obligation_adopt, the ADOPT-a-catalog-
-- obligation-with-override path. It is read by sp_resolve_obligation_list
-- for every row already (both UNION ALL halves project EventTypeId -- the
-- organisation-defined half has done so since before 244), so the gap is
-- narrower than it first looks: this migration only has to teach the two
-- WRITE doors that create/edit an organisation-authored obligation to
-- accept the field. Nothing downstream of the column needs to change.
--
-- THE TWO WRITE DOORS
-- -------------------
--   sp_resolve_local_obligation_save (227, latest body 244) -- instance
--     door. Writes practice_instance_obligation directly. Gains
--     @event_type_id, written straight into the row it creates or edits,
--     the same way @assurance_type already is (this is NOT the "absent
--     means keep" override contract 244 gave connection_type_id /
--     connection_url -- those exist because Automated-assurance wiring
--     can be filled in at a different point in the flow than the main
--     edit form; event_type_id is a core field of the obligation itself,
--     the same category as assurance_type, and the edit form resends the
--     whole payload each time).
--
--   sp_practice_obligation_save (307) -- practice-level door. Writes
--     practice_obligation, a table that did not have anywhere to keep this
--     before now. Gains the same @event_type_id, same direct-write
--     contract, plus the ALTER TABLE that gives practice_obligation the
--     column at all.
--
-- sp_practice_obligation_fan_out (307) copies practice_obligation's fields
-- onto every practice_instance_obligation row it manages. event_type_id
-- joins that set of practice-owned fields (refreshed in 3a, carried into
-- new copies in 3b) -- the same treatment obligation_type_code already
-- gets. This does not collide with 234's per-instance override use of the
-- same column: fan-out only ever touches rows with
-- source_practice_obligation_id set, and a catalog-adopted row (234's
-- population) always has obligation_id set and source_practice_obligation_id
-- NULL, so the two write paths never address the same row.
--
-- WHY NOT sla_value / sla_unit TOO
-- ---------------------------------
-- 234 added those alongside event_type_id for the ADOPT override case.
-- Nothing downstream of this feature (the applicability decision, the
-- raise, the Checklists list, View Mapped Profiles) needs an SLA to
-- determine whether an obligation is event-driven or which profiles map
-- it -- only event_type_id does. Leaving them out keeps this migration's
-- blast radius to the one column the rest of the plan (341-344) actually
-- depends on; they remain exactly what 234 made them, an adoption-only
-- override.
--
-- WHY NO FOREIGN KEY ON practice_obligation.event_type_id
-- ---------------------------------------------------------
-- event_type_master lives in GRAC_New; SQL Server does not allow
-- cross-database foreign keys. Soft reference, same choice 234 made for
-- practice_instance_obligation.event_type_id and 127 made for
-- practice_instance_dependency.event_type_id.
--
-- BOTH SAVE PROCS ARE THEIR LATEST BODY, EXTENDED MECHANICALLY
-- --------------------------------------------------------------
-- sp_resolve_local_obligation_save re-issued from 244 (its latest applied
-- body -- 244 supersedes 242/233/227). sp_practice_obligation_save and
-- sp_practice_obligation_fan_out re-issued from 307 (still the only
-- definition; 308, which 307's own header named as a follow-up, was never
-- written -- see 307's closing PRINT). Not re-emitted from scratch, per
-- this codebase's own rule (231, 234): every line outside the marked
-- "Migration 340" additions is unchanged from that source.
--
-- SAFE TO RE-RUN. Requires 234 and 307.
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- DEPENDS ON: 234 (practice_instance_obligation.event_type_id),
--             307 (practice_obligation, sp_practice_obligation_save,
--             sp_practice_obligation_fan_out, sp_practice_obligation_list),
--             244 (sp_resolve_local_obligation_save latest body).
-- Rollback:   database/340_custom_obligation_event_type_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (340): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (340): grac_practice.practice_obligation missing (run 307 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NULL
BEGIN
    PRINT 'ABORT (340): practice_instance_obligation.event_type_id missing (run 234 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Column: practice_obligation.event_type_id
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_obligation
        ADD event_type_id BIGINT NULL;   -- soft ref GRAC_New.event_type_master
    PRINT '340: practice_obligation.event_type_id added.';
END
GO

-- =====================================================================
-- 2. sp_resolve_local_obligation_save -- 244's body plus @event_type_id
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

    -- Migration 340: reject a stale event_type_id, the same existence
    -- check sp_resolve_obligation_adopt already applies via its JSON
    -- payload (234). NULL is fine -- it means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 52706, 'sp_resolve_local_obligation_save: unknown event type.', 1;

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
             responsibility, approval_authority, assurance_type, remarks,
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
             @responsibility, @approval_authority, @assurance_type, @remarks,
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
PRINT '340: sp_resolve_local_obligation_save accepts event_type_id.';
GO

-- =====================================================================
-- 3. sp_practice_obligation_save -- 307's body plus @event_type_id
-- =====================================================================
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

    -- Migration 340: reject a stale event_type_id. NULL is fine -- it
    -- means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 57213, 'sp_practice_obligation_save: unknown event type.', 1;

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
             responsibility, approval_authority, assurance_type, remarks,
             event_type_id,
             evidence_json, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_id,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
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
PRINT '340: sp_practice_obligation_save accepts event_type_id.';
GO

-- =====================================================================
-- 4. sp_practice_obligation_fan_out -- 307's body, event_type_id joins
--    the practice-owned field set (refreshed in 3a, carried into new
--    copies in 3b). Everything else, including the OUTPUT-parameter
--    reporting shape 233 established, is unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_fan_out
    @practice_id            BIGINT        = NULL,
    @practice_obligation_id BIGINT        = NULL,
    @practice_instance_id   BIGINT        = NULL,
    @actor                  NVARCHAR(100) = N'system',
    @copies_created         INT           = 0 OUTPUT,
    @copies_updated         INT           = 0 OUTPUT,
    @copies_retired         INT           = 0 OUTPUT,
    @evidence_synced        INT           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Always initialised: an early RETURN must not leave the caller's
    -- variables holding whatever they had before. Same discipline 233
    -- applied to the evidence sync.
    SET @copies_created  = 0;
    SET @copies_updated  = 0;
    SET @copies_retired  = 0;
    SET @evidence_synced = 0;

    IF @practice_id IS NULL AND @practice_obligation_id IS NULL AND @practice_instance_id IS NULL
        THROW 57200, 'sp_practice_obligation_fan_out: name a practice, a definition or an instance.', 1;

    -- Narrow to one practice when the caller named a definition or an
    -- instance instead, so the joins below stay on one practice's rows.
    IF @practice_id IS NULL AND @practice_obligation_id IS NOT NULL
        SELECT @practice_id = practice_id
        FROM   grac_practice.practice_obligation
        WHERE  practice_obligation_id = @practice_obligation_id;

    IF @practice_id IS NULL AND @practice_instance_id IS NOT NULL
        SELECT @practice_id = practice_id
        FROM   grac_practice.practice_instance
        WHERE  practice_instance_id = @practice_instance_id;

    IF @practice_id IS NULL RETURN;    -- nothing to fan out to

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- The definitions in scope, and the instances in scope. Kept as two
    -- small sets so every statement below reads the same population.
    DECLARE @defs TABLE (
        practice_obligation_id BIGINT PRIMARY KEY,
        is_active              BIT    NOT NULL,
        evidence_json          NVARCHAR(MAX) NULL,
        event_type_id          BIGINT NULL    -- Migration 340
    );

    INSERT @defs (practice_obligation_id, is_active, evidence_json, event_type_id)
    SELECT po.practice_obligation_id,
           CASE WHEN po.status = N'Active' THEN 1 ELSE 0 END,
           po.evidence_json,
           po.event_type_id
    FROM   grac_practice.practice_obligation po
    WHERE  po.practice_id = @practice_id
      AND (@practice_obligation_id IS NULL
           OR po.practice_obligation_id = @practice_obligation_id);

    IF NOT EXISTS (SELECT 1 FROM @defs) RETURN;

    DECLARE @instances TABLE (practice_instance_id BIGINT PRIMARY KEY, organization_id BIGINT NOT NULL);

    INSERT @instances (practice_instance_id, organization_id)
    SELECT pi.practice_instance_id, pi.organization_id
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_id = @practice_id
      AND  pi.status = N'Active'
      AND (@practice_instance_id IS NULL OR pi.practice_instance_id = @practice_instance_id);

    IF NOT EXISTS (SELECT 1 FROM @instances) RETURN;

    BEGIN TRANSACTION;

    -- 3a. Refresh the copies that already exist. The practice owns the
    --     obligation's own fields, so they are overwritten -- that is
    --     what "edit at practice level updates every instance" means.
    --     Migration 340: event_type_id joins that set.
    --
    --     Instance-owned parameters are NOT touched: assurance_frequency,
    --     the 234 ADOPT-only sla_value / sla_unit override, implementation
    --     status, connection info and the adoption stamp all stay as the
    --     instance left them. A copy that had been retired comes back
    --     Active rather than being duplicated beside itself.
    UPDATE pio
       SET obligation_name        = po.obligation_name,
           obligation_description = po.obligation_description,
           obligation_type_code   = po.obligation_type_code,
           typed_detail_json      = ISNULL(po.typed_detail_json, N'[]'),
           execution_frequency_id = po.execution_frequency_id,
           execution_frequency    = po.execution_frequency,
           responsibility         = po.responsibility,
           approval_authority     = po.approval_authority,
           assurance_type         = po.assurance_type,
           remarks                = po.remarks,
           event_type_id          = po.event_type_id,
           status                 = N'Active',
           record_status_id       = @active_record_status_id,
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
    JOIN   grac_practice.practice_obligation po
           ON po.practice_obligation_id = d.practice_obligation_id
    JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
    WHERE  d.is_active = 1;

    SET @copies_updated = @@ROWCOUNT;

    -- 3b. Create the copies that are missing.
    INSERT grac_practice.practice_instance_obligation
        (organization_id, practice_instance_id, obligation_id, release_id,
         obligation_name, obligation_description, obligation_type_code,
         typed_detail_json,
         inherited_from_repository, organization_modified,
         execution_frequency_id, execution_frequency,
         responsibility, approval_authority, assurance_type, remarks,
         event_type_id,
         source_practice_obligation_id,
         adopted_by, adopted_dt, status, record_status_id, entered_by)
    SELECT i.organization_id, i.practice_instance_id, NULL, NULL,
           po.obligation_name, po.obligation_description, po.obligation_type_code,
           ISNULL(po.typed_detail_json, N'[]'),
           -- Not inherited from the repository, and organisation-defined
           -- is by definition an organisation modification -- the same
           -- two values 227 writes.
           0, 1,
           po.execution_frequency_id, po.execution_frequency,
           po.responsibility, po.approval_authority, po.assurance_type, po.remarks,
           po.event_type_id,
           po.practice_obligation_id,
           -- Adopted on creation: the requirement is that a practice-level
           -- obligation APPLIES to every instance, so there is no
           -- per-instance decision left to take. Un-adopting one is done
           -- by retiring the definition.
           @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor
    FROM   @defs d
    JOIN   grac_practice.practice_obligation po
           ON po.practice_obligation_id = d.practice_obligation_id
    CROSS  JOIN @instances i
    WHERE  d.is_active = 1
      AND  NOT EXISTS (
             SELECT 1
             FROM   grac_practice.practice_instance_obligation x
             WHERE  x.practice_instance_id          = i.practice_instance_id
               AND  x.source_practice_obligation_id = po.practice_obligation_id);

    SET @copies_created = @@ROWCOUNT;

    -- 3c. A retired definition retires its copies everywhere. Retired,
    --     never deleted -- the same treatment 227 gives a retired local
    --     obligation, and the evidence somebody produced against it stays
    --     attached to a row that still exists.
    UPDATE pio
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
    JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
    WHERE  d.is_active = 0
      AND  pio.status = N'Active';

    SET @copies_retired = @@ROWCOUNT;

    COMMIT TRANSACTION;

    -- 3d. Evidence, per copy. Outside the transaction on purpose: the
    --     sync opens one of its own, and nesting it inside this one would
    --     put a COMMIT it does not own between the obligation writes and
    --     their rollback.
    --
    --     Reused rather than reimplemented. It already knows
    --     practice_instance_evidence's NOT NULL columns, already revives
    --     a retired row of the same type instead of duplicating it, and
    --     already refuses to retire an evidence row somebody has filled
    --     in. A NULL evidence_json means "no opinion" and it changes
    --     nothing, which is what a definition with no declared evidence
    --     should do.
    IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NOT NULL
    BEGIN
        DECLARE @pio_id BIGINT, @inst_id BIGINT, @ev NVARCHAR(MAX);
        -- The sync's three OUTPUT parameters have no defaults, so all
        -- three are supplied. Added and removed are summed into one count
        -- for the caller; kept is per-call detail that means nothing
        -- aggregated across instances.
        DECLARE @ev_added INT = 0, @ev_removed INT = 0, @ev_kept INT = 0;

        DECLARE copies CURSOR LOCAL FAST_FORWARD FOR
            SELECT pio.practice_instance_obligation_id, pio.practice_instance_id, d.evidence_json
            FROM   grac_practice.practice_instance_obligation pio
            JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
            JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
            WHERE  d.is_active = 1
              AND  pio.status = N'Active'
              AND  d.evidence_json IS NOT NULL;

        OPEN copies;
        FETCH NEXT FROM copies INTO @pio_id, @inst_id, @ev;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
                 @practice_instance_id            = @inst_id,
                 @practice_instance_obligation_id = @pio_id,
                 @evidence_json                   = @ev,
                 @actor                           = @actor,
                 @evidence_added                  = @ev_added   OUTPUT,
                 @evidence_removed                = @ev_removed OUTPUT,
                 @evidence_kept                   = @ev_kept    OUTPUT;

            SET @evidence_synced = @evidence_synced + ISNULL(@ev_added, 0) + ISNULL(@ev_removed, 0);

            FETCH NEXT FROM copies INTO @pio_id, @inst_id, @ev;
        END
        CLOSE copies;
        DEALLOCATE copies;
    END
END
GO
PRINT '340: sp_practice_obligation_fan_out propagates event_type_id.';
GO

-- =====================================================================
-- 5. sp_practice_obligation_list -- 307's body plus EventTypeId, for UI
--    completeness (the practice-level authoring panel can now show and
--    badge event-driven definitions the same way the instance panel
--    already can via sp_resolve_obligation_list).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_list
    @practice_id     BIGINT,
    @organization_id BIGINT = NULL,
    @include_retired BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_id IS NULL
        THROW 57212, 'sp_practice_obligation_list: practice_id is required.', 1;

    SELECT po.practice_obligation_id AS PracticeObligationId,
           po.organization_id        AS OrganizationId,
           po.practice_id            AS PracticeId,
           po.obligation_name        AS ObligationName,
           po.obligation_description AS ObligationDescription,
           po.obligation_type_code   AS ObligationTypeCode,
           t.type_name               AS TypeName,
           po.typed_detail_json      AS TypedDetailJson,
           po.execution_frequency_id AS ExecutionFrequencyId,
           po.execution_frequency    AS ExecutionFrequency,
           po.responsibility         AS Responsibility,
           po.approval_authority     AS ApprovalAuthority,
           po.assurance_type         AS AssuranceType,
           po.event_type_id          AS EventTypeId,
           po.remarks                AS Remarks,
           po.evidence_json          AS EvidenceJson,
           po.status                 AS Status_,
           po.entered_by             AS EnteredBy,
           po.entered_dt             AS EnteredDt,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_obligation pio
              JOIN grac_practice.practice_instance pi
                   ON pi.practice_instance_id = pio.practice_instance_id
             WHERE pio.source_practice_obligation_id = po.practice_obligation_id
               AND pio.status = N'Active'
               AND pi.status  = N'Active') AS InstanceCount
    FROM   grac_practice.practice_obligation po
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.type_code = po.obligation_type_code
    WHERE  po.practice_id = @practice_id
      AND (@organization_id IS NULL OR po.organization_id = @organization_id)
      AND (@include_retired = 1 OR po.status = N'Active')
    ORDER  BY ISNULL(t.display_order, 999), po.obligation_name;
END
GO
PRINT '340: sp_practice_obligation_list projects EventTypeId.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 340 verification ===';

SELECT '340-a practice_obligation.event_type_id column' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '340-b sp_resolve_local_obligation_save accepts event_type_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')
                            AND name = '@event_type_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '340-c sp_practice_obligation_save accepts event_type_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_save','P')
                            AND name = '@event_type_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '340-d sp_practice_obligation_fan_out propagates event_type_id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P'))
                 LIKE '%event_type_id          = po.event_type_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '340-e sp_practice_obligation_list projects EventTypeId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_list','P'))
                 LIKE '%po.event_type_id          AS EventTypeId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 234's ADOPT-only override use of the same column on
-- catalog-adopted rows must be untouched -- fan-out only ever writes rows
-- with source_practice_obligation_id set, ADOPT rows never have it set.
SELECT '340-f fan_out still keyed off source_practice_obligation_id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P'))
                 LIKE '%d.practice_obligation_id = pio.source_practice_obligation_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '340-g event_type_master reachable (event types resolvable at all)',
       CASE WHEN OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'REVIEW -- Control Management 033 not applied; event_type_id will never validate as non-NULL' END;

PRINT '';
PRINT '340 complete. Organisation-authored obligations (instance and';
PRINT 'practice level) can now be declared event-driven. Next: 341 gives';
PRINT 'event_obligation_applicability somewhere to record that decision.';
GO

SET NOEXEC OFF;
GO
