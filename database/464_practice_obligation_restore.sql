-- =====================================================================
-- 464_practice_obligation_restore.sql
--
-- WHY
-- ---
-- Practice View -> a practice-level (organisation-defined) obligation card
-- carried a "Remove" button. The verb was wrong and the road was one-way:
--
--   * Nothing is deleted. sp_practice_obligation_save @retire = 1 sets
--     practice_obligation.status = N'Retired' and the fan-out's branch 3c
--     sets every practice_instance_obligation copy to N'Retired' too --
--     "Retired, never deleted", and the evidence somebody produced against
--     it stays attached to a row that still exists. So the button was only
--     ever a Retire.
--   * But there was no way back. The only path that set a retired
--     definition Active again was a full edit-and-save (the edit branch
--     writes status = N'Active'), which needs the whole payload and reads
--     as "I changed this obligation", not "I am putting it back".
--
-- WHAT
--   sp_practice_obligation_save (re-issued from 412) + @restore BIT = 0:
--   a status flip back to N'Active' followed by the SAME fan-out call
--   retire makes. The fan-out already revives retired copies (3a), creates
--   a copy on any instance added in the meantime (3b) and re-syncs the
--   declared evidence (3d) -- nothing new is written here.
--
--   Nothing else in the procedure changes, and no other procedure is
--   touched. sp_practice_obligation_list already takes
--   @include_retired BIT = 0 and returns Status_, so showing the retired
--   ones needs no database change at all.
--
-- The UI renames the button to Retire, adds a "Show retired" toggle, and
-- puts a Restore button on the retired cards. The Api tier passes the
-- new flag through (PracticeObligationSaveRequest.Restore).
--
-- Re-issued from: 412 (sp_practice_obligation_save, current body).
-- SAFE TO RE-RUN (CREATE OR ALTER). Requires 307, 340, 412.
-- Rollback: database/464_practice_obligation_restore_rollback.sql
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the COLUMNS and objects this body reads, not merely on the
-- procedure existing: this script re-issues an earlier migration's body.
IF OBJECT_ID('grac_practice.sp_practice_obligation_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P') IS NULL
   OR OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
   OR OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (464): run 307, 340 and 412 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_obligation','owner_employee_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','evidence_json') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','status') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    PRINT 'ABORT (464): practice_obligation / organization_employee columns missing -- run 340 and 412 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_practice_obligation_save (412 body + @restore)
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
-- Verification
-- =====================================================================
PRINT '=== 464 verification ===';

SELECT '464 save takes @restore' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                         WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_save','P')
                           AND name = '@restore')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '464 @restore is optional (every existing caller unaffected)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                         WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_save','P')
                           AND name = '@restore' AND has_default_value = 1)
            THEN 'PASS' ELSE 'INFO (default set in body, not catalogued)' END
UNION ALL
SELECT '464 restore branch sets status Active',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save','P'))
                 LIKE '%IF @restore = 1%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '464 retire branch still intact (nothing deleted)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save','P'))
                 LIKE '%SET status     = N''Retired''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '464 no DELETE anywhere in the procedure',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save','P'))
                 NOT LIKE '%DELETE %'
            THEN 'PASS' ELSE 'FAIL -- review' END
UNION ALL
SELECT '464 list already supports retired rows (no change needed)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                         WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_list','P')
                           AND name = '@include_retired')
            THEN 'PASS' ELSE 'FAIL' END;
GO

SET NOEXEC OFF;
GO
