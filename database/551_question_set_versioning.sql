-- =====================================================================
-- 551  Question Set versioning and approval
--
-- REQUEST (2026-11-14, sir) -- first phase of the audit flow redesign
--   (docs/audit-flow-redesign.md). Audit Definition and Question Set are
--   masters: set up once, approved, and changed only by versioning. When a
--   question set changes, the audit definitions that use it move to a new
--   version; the Recommend / Approve views list those definitions so the
--   approver is warned.
--
-- MODEL -- one row per version
--   org_assurance_question_set keeps one row per VERSION. The versions of a
--   set share root_question_set_id and set_code and differ by
--   version_number. Questions stay keyed on the set row (a version owns its
--   questions); definitions already link a set row
--   (org_assurance_definition_question_set), so a definition version points
--   at an exact question set version; executions already snapshot their
--   questions (545). None of those readers change.
--
--   version_status: Draft -> UnderReview (Recommend) -> Active (Approve);
--   Return sends UnderReview back to Draft; approving makes the previous
--   Active version Superseded. Only a Draft is changed (header and
--   questions). New Version copies the Active version into a Draft with the
--   next number -- one Draft / Under Review version per set at a time. Only
--   Active versions can be adopted by a definition.
--
--   On approve, every audit definition whose CURRENT version links an older
--   version of the set:
--     Draft / Under Review  -> the link moves to the new set version in place
--     Approved / Active     -> a new Draft version of the definition is
--                              created as a full copy (scope, question sets
--                              with the new set version, workflow, scoring);
--                              it needs Submit for Review and Approve again
--                              (sir, decision 1). The Active version keeps
--                              running until then.
--     Retired               -> nothing
--
-- WHAT THIS DOES
--   1. org_assurance_question_set: + root_question_set_id, version_number,
--      version_status, previous_question_set_id, change_note, submitted_by /
--      _dt, approved_by / _dt. Existing sets become version 1, Active (a set
--      whose old status was 'Draft' becomes a Draft version). The unique key
--      uq_pm_oa_qset_code (organization_id, set_code) becomes
--      (organization_id, set_code, version_number).
--   2. NEW sp_org_assurance_clone_rows -- copies rows of a grac_practice
--      table with column overrides and records old -> new ids
--      (MERGE ... OUTPUT), so child rows can be re-parented.
--   3. NEW sp_org_assurance_definition_version_copy_config -- copies a
--      definition version's scope (groups, conditions, values), question
--      set links (optionally swapping one set's family to a new version),
--      workflow (config, stages) and scoring (config, bands).
--   4. Question set procedures:
--        sp_org_assurance_question_set_save    (077) new set = Draft v1;
--                                              only a Draft is changed (53840)
--        sp_org_assurance_question_set_get     (077) + version columns
--        sp_org_assurance_question_set_list    (535) one row per set: its
--                                              latest version
--        sp_org_assurance_question_set_delete  (077) a Draft v2+ is
--                                              discarded; a whole set only
--                                              when no definition uses it
--        NEW _new_version, _submit (Recommend), _return, _approve,
--            _impact, _version_list
--   5. Questions (only a Draft version changes, 53840):
--        sp_org_assurance_question_set_questions_save (520)
--        sp_org_assurance_question_save               (520)
--        sp_org_assurance_question_delete             (077)
--   6. Definition question sets (278): the picker offers Active versions
--      only; save accepts Active versions only (53714); adopted rows carry
--      the set's version.
--   7. sp_org_assurance_definition_save (119): editing an Active definition
--      now copies the configuration into the new Draft version (it started
--      empty before -- scope and question sets were lost).
--   8. Plannable audit = has an Active version and is not Retired (it may
--      have a Draft revision in progress):
--        sp_org_assurance_plan_item_save            (546)
--        sp_org_assurance_plan_item_list            (546) + DefinitionIsPlannable
--        sp_org_assurance_plan_item_start_execution (546) -- and it runs the
--          ACTIVE version (it ran the current version, which can be a Draft)
--
-- NEW REASON CODES (53840-53849, 53714)
--   53840 VERSION_NOT_DRAFT      53841 VERSION_IN_PROGRESS
--   53842 NO_ACTIVE_VERSION      53843 NO_QUESTIONS
--   53844 NOT_UNDER_REVIEW       53846 SET_IN_USE
--   53849 CLONE_FAILED           53714 SET_VERSION_NOT_ACTIVE
--
-- DEPENDS ON: 077, 119, 277 / 278, 520, 535, 545, 546.
-- Rollback: 551_question_set_versioning_rollback.sql (procedures; the
--   version columns and rows are kept).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_questions_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_definition_question_set_save','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question','evidence_type_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_auditor_role_id') IS NULL
BEGIN
    PRINT 'ABORT (551): run 520, 535, 545 and 546 first. Nothing was changed.';
    RAISERROR('551_question_set_versioning: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Version columns
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_question_set','root_question_set_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD root_question_set_id BIGINT NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','version_number') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD version_number INT NOT NULL
        CONSTRAINT df_pm_oa_qset_version_number DEFAULT 1;
IF COL_LENGTH('grac_practice.org_assurance_question_set','version_status') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD version_status NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_oa_qset_version_status DEFAULT N'Draft';
IF COL_LENGTH('grac_practice.org_assurance_question_set','previous_question_set_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD previous_question_set_id BIGINT NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','change_note') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD change_note NVARCHAR(1000) NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','submitted_by') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD submitted_by NVARCHAR(100) NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','submitted_dt') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD submitted_dt DATETIME2 NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','approved_by') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD approved_by NVARCHAR(100) NULL;
IF COL_LENGTH('grac_practice.org_assurance_question_set','approved_dt') IS NULL
    ALTER TABLE grac_practice.org_assurance_question_set ADD approved_dt DATETIME2 NULL;
GO

-- Existing sets: version 1 of themselves. A set already in use or marked
-- Active is an Active version; one whose old status was 'Draft' and that
-- no definition uses is a Draft version.
UPDATE qs
   SET root_question_set_id = qs.org_assurance_question_set_id,
       version_status = CASE WHEN qs.status = N'Draft'
                              AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition_question_set d
                                               WHERE d.org_assurance_question_set_id = qs.org_assurance_question_set_id
                                                 AND d.is_active = 1)
                             THEN N'Draft' ELSE N'Active' END,
       approved_by = CASE WHEN qs.status = N'Draft' THEN NULL ELSE N'migration-551' END,
       approved_dt = CASE WHEN qs.status = N'Draft' THEN NULL ELSE SYSUTCDATETIME() END
  FROM grac_practice.org_assurance_question_set qs
 WHERE qs.root_question_set_id IS NULL;
PRINT '551.1: existing question sets set to version 1 = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = N'ck_pm_oa_qset_version_status'
                  AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_question_set'))
    ALTER TABLE grac_practice.org_assurance_question_set ADD CONSTRAINT ck_pm_oa_qset_version_status
        CHECK (version_status IN (N'Draft', N'UnderReview', N'Active', N'Superseded'));
GO

-- The code is shared by a set's versions: unique per version.
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = N'uq_pm_oa_qset_code'
              AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_question_set'))
   AND NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                     JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                     JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE i.name = N'uq_pm_oa_qset_code'
                      AND i.object_id = OBJECT_ID('grac_practice.org_assurance_question_set')
                      AND c.name = N'version_number')
    ALTER TABLE grac_practice.org_assurance_question_set DROP CONSTRAINT uq_pm_oa_qset_code;
GO
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
                WHERE name = N'uq_pm_oa_qset_code'
                  AND parent_object_id = OBJECT_ID('grac_practice.org_assurance_question_set'))
    ALTER TABLE grac_practice.org_assurance_question_set ADD CONSTRAINT uq_pm_oa_qset_code
        UNIQUE (organization_id, set_code, version_number);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = N'ix_pm_oa_qset_root'
                  AND object_id = OBJECT_ID('grac_practice.org_assurance_question_set'))
    CREATE INDEX ix_pm_oa_qset_root
        ON grac_practice.org_assurance_question_set(root_question_set_id, version_number)
        INCLUDE (version_status, is_active);
GO

-- =====================================================================
-- 2. sp_org_assurance_clone_rows -- copy rows with overrides, map ids
--
--   @table       grac_practice table name
--   @key_column  its identity column
--   @where       predicate on alias src (may use the @p_* values)
--   @overrides   JSON object { "column": "SQL expression" }; an expression
--                may use src.<column> and the @p_* values -- no subquery
--                (MERGE ... INSERT VALUES allows scalar expressions only;
--                bring other tables in with @source_join). entered_by /
--                entered_dt / updated_by / updated_dt default to the actor,
--                now, NULL, NULL.
--   @source_join / @source_extra
--                optional JOIN text and extra select list (", m.new_id AS
--                parent_new_id") for the source rows, read as src.<name>
--   @map_table   optional temp table (old_id BIGINT, new_id BIGINT),
--                created by the caller, that receives old -> new ids
--   No transaction of its own and no ROLLBACK: callers own the transaction.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_clone_rows
    @table       SYSNAME,
    @key_column  SYSNAME,
    @where       NVARCHAR(MAX),
    @overrides   NVARCHAR(MAX)  = NULL,
    @source_join NVARCHAR(MAX)  = NULL,
    @source_extra NVARCHAR(MAX) = NULL,
    @map_table   SYSNAME        = NULL,
    @p_source    BIGINT         = NULL,
    @p_version   BIGINT         = NULL,
    @p_set       BIGINT         = NULL,
    @p_root      BIGINT         = NULL,
    @p_number    INT            = NULL,
    @p_status    INT            = NULL,
    @p_actor     NVARCHAR(100)  = N'system',
    @rows_out    INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @obj INT = OBJECT_ID(N'grac_practice.' + QUOTENAME(@table));
    IF @obj IS NULL
        THROW 53849, 'Copy failed: table not found.', 1;
    IF @overrides IS NULL OR ISJSON(@overrides) = 0 SET @overrides = N'{}';

    DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);
    SELECT @cols = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N', ')
                       WITHIN GROUP (ORDER BY c.column_id),
           @vals = STRING_AGG(CONVERT(NVARCHAR(MAX),
                       COALESCE(o.[value],
                                CASE c.name
                                    WHEN N'entered_by' THEN N'@p_actor'
                                    WHEN N'entered_dt' THEN N'SYSUTCDATETIME()'
                                    WHEN N'updated_by' THEN N'NULL'
                                    WHEN N'updated_dt' THEN N'NULL'
                                    ELSE N'src.' + QUOTENAME(c.name)
                                END)), N', ')
                       WITHIN GROUP (ORDER BY c.column_id)
      FROM sys.columns c
      LEFT JOIN OPENJSON(@overrides) o
             ON o.[key] COLLATE DATABASE_DEFAULT = c.name COLLATE DATABASE_DEFAULT
     WHERE c.object_id = @obj
       AND c.is_identity = 0
       AND c.is_computed = 0
       AND TYPE_NAME(c.system_type_id) NOT IN (N'timestamp');

    DECLARE @sql NVARCHAR(MAX) =
          N'MERGE grac_practice.' + QUOTENAME(@table) + N' AS tgt' + NCHAR(10)
        + N'USING (SELECT src.*' + ISNULL(@source_extra, N'') + N' FROM grac_practice.' + QUOTENAME(@table) + N' AS src '
        + ISNULL(@source_join, N'') + N' WHERE ' + @where + N') AS src' + NCHAR(10)
        + N'ON 1 = 0' + NCHAR(10)
        + N'WHEN NOT MATCHED THEN INSERT (' + @cols + N')' + NCHAR(10)
        + N'VALUES (' + @vals + N')'
        + CASE WHEN @map_table IS NULL THEN N''
               ELSE NCHAR(10) + N'OUTPUT src.' + QUOTENAME(@key_column) + N', inserted.' + QUOTENAME(@key_column)
                    + N' INTO ' + @map_table + N' (old_id, new_id)' END
        + N';' + NCHAR(10) + N'SET @rows = @@ROWCOUNT;';

    EXEC sp_executesql @sql,
         N'@p_source BIGINT, @p_version BIGINT, @p_set BIGINT, @p_root BIGINT, @p_number INT, @p_status INT, @p_actor NVARCHAR(100), @rows INT OUTPUT',
         @p_source = @p_source, @p_version = @p_version, @p_set = @p_set, @p_root = @p_root,
         @p_number = @p_number, @p_status = @p_status, @p_actor = @p_actor, @rows = @rows_out OUTPUT;
END
GO

-- =====================================================================
-- 3. sp_org_assurance_definition_version_copy_config
--
--   Copies a definition version's configuration into another (new, empty)
--   version of the same definition: scope groups -> conditions -> values,
--   question set links, workflow config -> stages, scoring config -> bands.
--   @swap_root_set_id / @swap_to_set_id: a link to any version of that set
--   family is written as a link to @swap_to_set_id (question set approve).
--   No transaction of its own; callers own it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_version_copy_config
    @organization_id  BIGINT,
    @from_version_id  BIGINT,
    @to_version_id    BIGINT,
    @swap_root_set_id BIGINT        = NULL,
    @swap_to_set_id   BIGINT        = NULL,
    @actor            NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @from_version_id IS NULL OR @to_version_id IS NULL OR @from_version_id = @to_version_id
        THROW 53849, 'Copy failed: two different versions are required.', 1;

    CREATE TABLE #cfg_group (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_cond  (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_wf    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_sc    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    -- Scope
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_group', @key_column = N'scope_group_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_group', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition', @key_column = N'scope_condition_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_group m ON m.old_id = src.scope_group_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_group_id":"src.parent_new_id"}',
         @map_table = N'#cfg_cond', @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition_value', @key_column = N'scope_condition_value_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_cond m ON m.old_id = src.scope_condition_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_condition_id":"src.parent_new_id"}',
         @p_actor = @actor;

    -- Question sets (one family optionally moved to a new set version)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_question_set', @key_column = N'org_assurance_definition_question_set_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @source_join = N'LEFT JOIN grac_practice.org_assurance_question_set f ON f.org_assurance_question_set_id = src.org_assurance_question_set_id',
         @source_extra = N', f.root_question_set_id AS set_root_id',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version","org_assurance_question_set_id":"CASE WHEN @p_root IS NOT NULL AND src.set_root_id = @p_root THEN @p_set ELSE src.org_assurance_question_set_id END"}',
         @p_source = @from_version_id, @p_version = @to_version_id,
         @p_root = @swap_root_set_id, @p_set = @swap_to_set_id, @p_actor = @actor;

    -- Workflow
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_config', @key_column = N'org_assurance_workflow_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_wf', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_stage', @key_column = N'org_assurance_workflow_stage_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_wf m ON m.old_id = src.org_assurance_workflow_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_workflow_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_config', @key_column = N'org_assurance_scoring_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_sc', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_band', @key_column = N'org_assurance_scoring_band_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_sc m ON m.old_id = src.org_assurance_scoring_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_scoring_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;
END
GO

-- =====================================================================
-- 4. Question set procedures (re-issued)
-- =====================================================================

-- sp_org_assurance_question_set_save (077 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_save
    @organization_id      BIGINT,
    @question_set_id      BIGINT        = NULL,
    @set_code             NVARCHAR(80),
    @set_name             NVARCHAR(240),
    @description          NVARCHAR(MAX) = NULL,
    @owner_employee_id    BIGINT        = NULL,
    @owner_display_name   NVARCHAR(240) = NULL,
    @status               NVARCHAR(30)  = N'Active',
    @actor                NVARCHAR(100) = 'system',
    @question_set_id_out  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53801, 'organization_id is required.', 1;
    IF @set_code IS NULL OR LEN(LTRIM(RTRIM(@set_code))) = 0
        THROW 53803, 'set_code is required.', 1;
    IF @set_name IS NULL OR LEN(LTRIM(RTRIM(@set_name))) = 0
        THROW 53804, 'set_name is required.', 1;
    IF @status NOT IN (N'Active', N'Inactive', N'Draft')
        SET @status = N'Active';

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @question_set_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question_set
            WHERE organization_id = @organization_id
              AND set_code        = @set_code
              AND is_active       = 1)
        BEGIN
            ROLLBACK;
            THROW 53805, 'A question set with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_question_set
            (organization_id, set_code, set_name, description,
             owner_employee_id, owner_display_name,
             status, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @set_code, @set_name, @description,
             @owner_employee_id, @owner_display_name,
             @status, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @question_set_id_out = SCOPE_IDENTITY();

        -- 551: a new set is version 1, Draft, of itself.
        UPDATE grac_practice.org_assurance_question_set
           SET root_question_set_id = @question_set_id_out,
               version_number       = 1,
               version_status       = N'Draft'
         WHERE org_assurance_question_set_id = @question_set_id_out;
    END
    ELSE
    BEGIN
        DECLARE @def_org BIGINT, @version_status NVARCHAR(20);
        SELECT @def_org = organization_id, @version_status = version_status
        FROM grac_practice.org_assurance_question_set
        WHERE org_assurance_question_set_id = @question_set_id
          AND is_active = 1;

        IF @def_org IS NULL
        BEGIN ROLLBACK; THROW 53806, 'Question set not found.', 1; END
        IF @def_org <> @organization_id
        BEGIN ROLLBACK; THROW 53807, 'Question set belongs to a different organization.', 1; END
        -- 551: only a Draft version is changed.
        IF @version_status <> N'Draft'
        BEGIN ROLLBACK; THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1; END

        UPDATE grac_practice.org_assurance_question_set
        SET set_name           = @set_name,
            description        = @description,
            owner_employee_id  = @owner_employee_id,
            owner_display_name = @owner_display_name,
            status             = @status,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_question_set_id = @question_set_id;

        SET @question_set_id_out = @question_set_id;
    END

    COMMIT;
END
GO


-- sp_org_assurance_question_set_get (077 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_get
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.organization_id               AS OrganizationId,
           qs.set_code                      AS SetCode,
           qs.set_name                      AS SetName,
           qs.description                   AS Description,
           qs.owner_employee_id             AS OwnerEmployeeId,
           qs.owner_display_name            AS OwnerDisplayName,
           qs.status                        AS Status,
           -- 551: the version, and the set's Active / open versions.
           qs.root_question_set_id          AS RootQuestionSetId,
           qs.version_number                AS VersionNumber,
           qs.version_status                AS VersionStatus,
           qs.previous_question_set_id      AS PreviousQuestionSetId,
           qs.change_note                   AS ChangeNote,
           qs.submitted_by                  AS SubmittedBy,
           qs.submitted_dt                  AS SubmittedDt,
           qs.approved_by                   AS ApprovedBy,
           qs.approved_dt                   AS ApprovedDt,
           act.org_assurance_question_set_id AS ActiveQuestionSetId,
           act.version_number               AS ActiveVersionNumber,
           opn.org_assurance_question_set_id AS OpenQuestionSetId,
           opn.version_number               AS OpenVersionNumber,
           opn.version_status               AS OpenVersionStatus,
           qs.entered_by                    AS EnteredBy,
           qs.entered_dt                    AS EnteredDt,
           qs.updated_by                    AS UpdatedBy,
           qs.updated_dt                    AS UpdatedDt
    FROM grac_practice.org_assurance_question_set qs
    OUTER APPLY (SELECT TOP 1 a.org_assurance_question_set_id, a.version_number
                   FROM grac_practice.org_assurance_question_set a
                  WHERE a.root_question_set_id = qs.root_question_set_id AND a.is_active = 1
                    AND a.version_status = N'Active'
                  ORDER BY a.version_number DESC) act
    OUTER APPLY (SELECT TOP 1 o.org_assurance_question_set_id, o.version_number, o.version_status
                   FROM grac_practice.org_assurance_question_set o
                  WHERE o.root_question_set_id = qs.root_question_set_id AND o.is_active = 1
                    AND o.version_status IN (N'Draft', N'UnderReview')
                  ORDER BY o.version_number DESC) opn
    WHERE qs.organization_id               = @organization_id
      AND qs.org_assurance_question_set_id = @question_set_id
      AND qs.is_active = 1;
END
GO


-- sp_org_assurance_question_set_list (535 body + 551: latest version per set)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53801, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          -- 551: one row per set -- its latest version.
          AND qs.version_number = (SELECT MAX(x.version_number)
                                     FROM grac_practice.org_assurance_question_set x
                                    WHERE x.root_question_set_id = qs.root_question_set_id
                                      AND x.is_active = 1)
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT qs.org_assurance_question_set_id,
               qs.organization_id,
               qs.set_code,
               qs.set_name,
               qs.description,
               qs.owner_employee_id,
               qs.owner_display_name,
               qs.status,
               qs.entered_dt,
               qs.updated_dt,
               qs.root_question_set_id,
               qs.version_number,
               qs.version_status,
               (SELECT MAX(a.version_number) FROM grac_practice.org_assurance_question_set a
                 WHERE a.root_question_set_id = qs.root_question_set_id AND a.is_active = 1
                   AND a.version_status = N'Active') AS active_version_number,
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS question_count,
               -- 535: same rows as question_count (is_active = 1).
               (SELECT COUNT_BIG(1)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1
                   AND q.is_mandatory = 1) AS mandatory_count,
               (SELECT ISNULL(SUM(q.weight), 0)
                  FROM grac_practice.org_assurance_question q
                 WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
                   AND q.is_active = 1) AS total_weight
        FROM grac_practice.org_assurance_question_set qs
        WHERE qs.organization_id = @organization_id
          AND qs.is_active = 1
          -- 551: one row per set -- its latest version.
          AND qs.version_number = (SELECT MAX(x.version_number)
                                     FROM grac_practice.org_assurance_question_set x
                                    WHERE x.root_question_set_id = qs.root_question_set_id
                                      AND x.is_active = 1)
          AND (@search IS NULL OR @search = ''
               OR qs.set_name LIKE N'%' + @search + N'%'
               OR qs.set_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_question_set_id AS QuestionSetId,
           organization_id               AS OrganizationId,
           set_code                      AS SetCode,
           set_name                      AS SetName,
           description                   AS Description,
           owner_employee_id             AS OwnerEmployeeId,
           owner_display_name            AS OwnerDisplayName,
           status                        AS Status,
           question_count                AS QuestionCount,
           mandatory_count               AS MandatoryCount,   -- 535
           total_weight                  AS TotalWeight,      -- 535
           root_question_set_id          AS RootQuestionSetId,    -- 551
           version_number                AS VersionNumber,        -- 551
           version_status                AS VersionStatus,        -- 551
           active_version_number         AS ActiveVersionNumber,  -- 551
           entered_dt                    AS EnteredDt,
           updated_dt                    AS UpdatedDt
    FROM base
    ORDER BY set_name, org_assurance_question_set_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO


-- sp_org_assurance_question_set_delete (077, rewritten by 551)
--   A Draft version after the first (v2+) is DISCARDED: that version and
--   its questions go, the set's other versions stay. Otherwise the whole
--   set (every version) is removed -- only when no audit definition uses
--   any of its versions (53846).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_delete
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @def_org BIGINT, @root BIGINT, @vno INT, @vs NVARCHAR(20);
    SELECT @def_org = organization_id, @root = root_question_set_id,
           @vno = version_number, @vs = version_status
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @def_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @def_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @targets TABLE (id BIGINT NOT NULL PRIMARY KEY);
    IF @vs = N'Draft' AND @vno > 1
        INSERT INTO @targets (id) VALUES (@question_set_id);
    ELSE
    BEGIN
        IF EXISTS (SELECT 1
                     FROM grac_practice.org_assurance_definition_question_set dq
                     JOIN grac_practice.org_assurance_question_set qs
                          ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
                    WHERE qs.root_question_set_id = @root
                      AND dq.is_active = 1)
            THROW 53846, 'This question set is used by audit definitions and cannot be deleted.', 1;
        INSERT INTO @targets (id)
        SELECT org_assurance_question_set_id FROM grac_practice.org_assurance_question_set
         WHERE root_question_set_id = @root AND is_active = 1;
    END

    BEGIN TRAN;

    UPDATE q
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.org_assurance_question q
    JOIN @targets t ON t.id = q.org_assurance_question_set_id
    WHERE q.is_active = 1;

    UPDATE qs
    SET is_active  = 0,
        status     = N'Inactive',
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.org_assurance_question_set qs
    JOIN @targets t ON t.id = qs.org_assurance_question_set_id;

    COMMIT;
END
GO


-- =====================================================================
-- 4b. Question set versions -- new procedures
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_version_list -- every version of the set
-- that @question_set_id belongs to, newest first.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_version_list
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT = (SELECT root_question_set_id FROM grac_practice.org_assurance_question_set
                             WHERE org_assurance_question_set_id = @question_set_id
                               AND organization_id = @organization_id);
    IF @root IS NULL THROW 53806, 'Question set not found.', 1;

    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.version_number                AS VersionNumber,
           qs.version_status                AS VersionStatus,
           qs.set_name                      AS SetName,
           qs.change_note                   AS ChangeNote,
           (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)         AS QuestionCount,
           qs.submitted_by                  AS SubmittedBy,
           qs.submitted_dt                  AS SubmittedDt,
           qs.approved_by                   AS ApprovedBy,
           qs.approved_dt                   AS ApprovedDt,
           qs.entered_by                    AS EnteredBy,
           qs.entered_dt                    AS EnteredDt
      FROM grac_practice.org_assurance_question_set qs
     WHERE qs.root_question_set_id = @root
       AND qs.organization_id = @organization_id
       AND qs.is_active = 1
     ORDER BY qs.version_number DESC;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_new_version -- copy the set's Active
-- version (header + questions) into a Draft with the next number.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_new_version
    @organization_id     BIGINT,
    @question_set_id     BIGINT,
    @actor               NVARCHAR(100) = 'system',
    @question_set_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT, @set_org BIGINT;
    SELECT @root = root_question_set_id, @set_org = organization_id
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @open_no INT, @open_status NVARCHAR(20), @msg NVARCHAR(400);
    SELECT TOP 1 @open_no = version_number, @open_status = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE root_question_set_id = @root AND is_active = 1
       AND version_status IN (N'Draft', N'UnderReview')
     ORDER BY version_number DESC;
    IF @open_no IS NOT NULL
    BEGIN
        SET @msg = CONCAT(N'Version ', @open_no, N' of this question set is already ',
                          CASE WHEN @open_status = N'Draft' THEN N'in Draft' ELSE N'Under Review' END,
                          N'. Finish or discard it first.');
        THROW 53841, @msg, 1;
    END

    DECLARE @source BIGINT = (SELECT TOP 1 org_assurance_question_set_id
                                FROM grac_practice.org_assurance_question_set
                               WHERE root_question_set_id = @root AND is_active = 1
                                 AND version_status = N'Active'
                               ORDER BY version_number DESC);
    IF @source IS NULL THROW 53842, 'The question set has no approved (Active) version to copy.', 1;

    DECLARE @next INT = (SELECT MAX(version_number) + 1 FROM grac_practice.org_assurance_question_set
                          WHERE root_question_set_id = @root);

    CREATE TABLE #qs_map (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    BEGIN TRAN;
        EXEC grac_practice.sp_org_assurance_clone_rows
             @table = N'org_assurance_question_set', @key_column = N'org_assurance_question_set_id',
             @where = N'src.org_assurance_question_set_id = @p_source',
             @overrides = N'{"version_number":"@p_number","version_status":"N''Draft''","previous_question_set_id":"@p_source","change_note":"NULL","submitted_by":"NULL","submitted_dt":"NULL","approved_by":"NULL","approved_dt":"NULL"}',
             @map_table = N'#qs_map', @p_source = @source, @p_number = @next, @p_actor = @actor;

        SET @question_set_id_out = (SELECT new_id FROM #qs_map);

        EXEC grac_practice.sp_org_assurance_clone_rows
             @table = N'org_assurance_question', @key_column = N'org_assurance_question_id',
             @where = N'src.org_assurance_question_set_id = @p_source AND src.is_active = 1',
             @overrides = N'{"org_assurance_question_set_id":"@p_set"}',
             @p_source = @source, @p_set = @question_set_id_out, @p_actor = @actor;
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_submit -- Recommend: Draft -> UnderReview.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_submit
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @change_note     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20);
    SELECT @set_org = organization_id, @vs = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'Draft' THROW 53840, 'Only a Draft version can be recommended.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question
                    WHERE org_assurance_question_set_id = @question_set_id
                      AND is_active = 1 AND ISNULL(status, N'Active') = N'Active')
        THROW 53843, 'Add at least one active question before recommending the question set.', 1;

    UPDATE grac_practice.org_assurance_question_set
       SET version_status = N'UnderReview',
           change_note    = COALESCE(NULLIF(LTRIM(RTRIM(@change_note)), N''), change_note),
           submitted_by   = @actor,
           submitted_dt   = SYSUTCDATETIME(),
           updated_by     = @actor,
           updated_dt     = SYSUTCDATETIME()
     WHERE org_assurance_question_set_id = @question_set_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_return -- UnderReview -> Draft.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_return
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @reason          NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20);
    SELECT @set_org = organization_id, @vs = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'UnderReview' THROW 53844, 'Only a version Under Review can be returned or approved.', 1;

    UPDATE grac_practice.org_assurance_question_set
       SET version_status = N'Draft',
           change_note    = CASE WHEN NULLIF(LTRIM(RTRIM(@reason)), N'') IS NULL THEN change_note
                                 ELSE LEFT(CONCAT(N'Returned: ', @reason, CASE WHEN change_note IS NULL THEN N'' ELSE N' | ' + change_note END), 1000) END,
           updated_by     = @actor,
           updated_dt     = SYSUTCDATETIME()
     WHERE org_assurance_question_set_id = @question_set_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_impact -- the audit definitions whose
-- CURRENT version uses another version of this set, and what approving
-- this version will do to each. Read-only.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_impact
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT = (SELECT root_question_set_id FROM grac_practice.org_assurance_question_set
                             WHERE org_assurance_question_set_id = @question_set_id
                               AND organization_id = @organization_id);
    IF @root IS NULL THROW 53806, 'Question set not found.', 1;

    SELECT d.org_assurance_definition_id AS DefinitionId,
           d.definition_code             AS DefinitionCode,
           d.definition_name             AS DefinitionName,
           v.version_number              AS CurrentVersionNumber,
           s.status_code                 AS CurrentStatusCode,
           s.status_name                 AS CurrentStatusName,
           qs.version_number             AS LinkedSetVersion,
           CASE WHEN s.status_code IN (N'Draft', N'UnderReview')
                THEN N'UPDATE_IN_PLACE' ELSE N'NEW_VERSION' END AS ActionCode,
           CASE WHEN s.status_code IN (N'Draft', N'UnderReview')
                THEN N'Its ' + s.status_name + N' version ' + CAST(v.version_number AS NVARCHAR(10))
                     + N' moves to the new question set version.'
                ELSE N'A new Draft version ' + CAST(ISNULL(mx.max_no, 0) + 1 AS NVARCHAR(10))
                     + N' is created for review and approval; version ' + CAST(v.version_number AS NVARCHAR(10))
                     + N' stays Active until then.' END AS ActionText
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
      JOIN grac_practice.org_assurance_definition_version v
           ON v.org_assurance_definition_version_id = d.current_version_id
      JOIN grac_practice.org_assurance_definition_question_set dq
           ON dq.org_assurance_definition_version_id = d.current_version_id
          AND dq.is_active = 1
      JOIN grac_practice.org_assurance_question_set qs
           ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
      OUTER APPLY (SELECT MAX(x.version_number) AS max_no
                     FROM grac_practice.org_assurance_definition_version x
                    WHERE x.org_assurance_definition_id = d.org_assurance_definition_id) mx
     WHERE d.organization_id = @organization_id
       AND d.is_active = 1
       AND s.status_code <> N'Retired'
       AND qs.root_question_set_id = @root
       AND qs.org_assurance_question_set_id <> @question_set_id
     ORDER BY d.definition_name, d.org_assurance_definition_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_approve -- UnderReview -> Active; the
-- previous Active version -> Superseded; then every audit definition that
-- uses an older version moves to this one (see the header). Returns what
-- was done, one row per definition.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_approve
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20), @root BIGINT, @code NVARCHAR(80), @vno INT;
    SELECT @set_org = organization_id, @vs = version_status, @root = root_question_set_id,
           @code = set_code, @vno = version_number
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'UnderReview' THROW 53844, 'Only a version Under Review can be returned or approved.', 1;

    DECLARE @draft_status_id INT = (SELECT org_assurance_status_id FROM grac_practice.org_assurance_status_master
                                     WHERE status_code = N'Draft');
    DECLARE @note NVARCHAR(400) = CONCAT(N'Question set ', @code, N' version ', @vno, N' approved.');

    CREATE TABLE #impact (
        definition_id   BIGINT NOT NULL,
        version_id      BIGINT NOT NULL,
        status_code     NVARCHAR(60) NOT NULL,
        status_id       INT NOT NULL,
        action_code     NVARCHAR(30) NULL,
        new_version_id  BIGINT NULL,
        new_version_no  INT NULL);

    BEGIN TRAN;

        UPDATE grac_practice.org_assurance_question_set
           SET version_status = N'Superseded', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE root_question_set_id = @root AND version_status = N'Active'
           AND org_assurance_question_set_id <> @question_set_id;

        UPDATE grac_practice.org_assurance_question_set
           SET version_status = N'Active', approved_by = @actor, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_question_set_id = @question_set_id;

        INSERT INTO #impact (definition_id, version_id, status_code, status_id)
        SELECT DISTINCT d.org_assurance_definition_id, d.current_version_id, s.status_code, d.current_status_id
          FROM grac_practice.org_assurance_definition d
          JOIN grac_practice.org_assurance_status_master s
               ON s.org_assurance_status_id = d.current_status_id
          JOIN grac_practice.org_assurance_definition_question_set dq
               ON dq.org_assurance_definition_version_id = d.current_version_id AND dq.is_active = 1
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         WHERE d.organization_id = @organization_id AND d.is_active = 1
           AND s.status_code <> N'Retired'
           AND qs.root_question_set_id = @root
           AND qs.org_assurance_question_set_id <> @question_set_id;

        -- Draft / Under Review: move the link in place.
        UPDATE dq
           SET org_assurance_question_set_id = @question_set_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.org_assurance_definition_question_set dq
          JOIN #impact i ON i.version_id = dq.org_assurance_definition_version_id
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         WHERE i.status_code IN (N'Draft', N'UnderReview')
           AND dq.is_active = 1
           AND qs.root_question_set_id = @root;

        UPDATE #impact SET action_code = N'UPDATE_IN_PLACE' WHERE status_code IN (N'Draft', N'UnderReview');

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
             action_code, from_status_id, to_status_id, reason_text, actor_display_name, entered_by)
        SELECT i.definition_id, i.version_id, @organization_id, N'QSET_UPDATE', i.status_id, i.status_id,
               @note + N' Linked to the new version.', @actor, @actor
          FROM #impact i WHERE i.action_code = N'UPDATE_IN_PLACE';

        -- Approved / Active: a new Draft version, a full copy.
        DECLARE @def BIGINT, @ver BIGINT, @sid INT, @next INT, @newv BIGINT;
        DECLARE imp CURSOR LOCAL FAST_FORWARD FOR
            SELECT definition_id, version_id, status_id FROM #impact WHERE action_code IS NULL;
        OPEN imp;
        FETCH NEXT FROM imp INTO @def, @ver, @sid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @next = (SELECT MAX(version_number) + 1 FROM grac_practice.org_assurance_definition_version
                          WHERE org_assurance_definition_id = @def);
            CREATE TABLE #ver_map (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

            EXEC grac_practice.sp_org_assurance_clone_rows
                 @table = N'org_assurance_definition_version', @key_column = N'org_assurance_definition_version_id',
                 @where = N'src.org_assurance_definition_version_id = @p_source',
                 @overrides = N'{"version_number":"@p_number","version_label":"CAST(@p_number AS NVARCHAR(20)) + N''.0''","status_id":"@p_status","submitted_by":"NULL","submitted_dt":"NULL","approved_by":"NULL","approved_dt":"NULL","activated_by":"NULL","activated_dt":"NULL","retired_by":"NULL","retired_dt":"NULL"}',
                 @map_table = N'#ver_map', @p_source = @ver, @p_number = @next, @p_status = @draft_status_id, @p_actor = @actor;
            SET @newv = (SELECT new_id FROM #ver_map);
            DROP TABLE #ver_map;

            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id, @from_version_id = @ver, @to_version_id = @newv,
                 @swap_root_set_id = @root, @swap_to_set_id = @question_set_id, @actor = @actor;

            UPDATE grac_practice.org_assurance_definition
               SET current_version_id = @newv, current_status_id = @draft_status_id,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE org_assurance_definition_id = @def;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
                 action_code, from_status_id, to_status_id, reason_text, actor_display_name, entered_by)
            VALUES (@def, @newv, @organization_id, N'CREATE', @sid, @draft_status_id,
                    @note + N' New version for review and approval.', @actor, @actor);

            UPDATE #impact SET action_code = N'NEW_VERSION', new_version_id = @newv, new_version_no = @next
             WHERE definition_id = @def;

            FETCH NEXT FROM imp INTO @def, @ver, @sid;
        END
        CLOSE imp; DEALLOCATE imp;

    COMMIT;

    SELECT i.definition_id     AS DefinitionId,
           d.definition_code   AS DefinitionCode,
           d.definition_name   AS DefinitionName,
           i.action_code       AS ActionCode,
           i.new_version_no    AS NewVersionNumber
      FROM #impact i
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = i.definition_id
     ORDER BY d.definition_name;
END
GO


-- =====================================================================
-- 5. Questions -- only a Draft version of a set changes
-- =====================================================================

-- sp_org_assurance_question_set_questions_save (520 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_questions_save
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @questions_json  NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system',
    @saved_count     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @saved_count = 0;
    SET @actor = ISNULL(@actor, 'system');

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53801, 'organization_id and question_set_id are required.', 1;
    IF @questions_json IS NULL SET @questions_json = N'[]';
    IF ISJSON(@questions_json) <> 1 THROW 53816, 'The questions could not be read.', 1;

    DECLARE @set_org BIGINT = (SELECT organization_id FROM grac_practice.org_assurance_question_set
                               WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1);
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    -- 551: only a Draft version of a set is changed.
    IF (SELECT version_status FROM grac_practice.org_assurance_question_set
         WHERE org_assurance_question_set_id = @question_set_id) <> N'Draft'
        THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1;

    DROP TABLE IF EXISTS #g;
    SELECT CAST(j.[key] AS INT) + 1                          AS row_no,
           x.question_id,
           NULLIF(LTRIM(RTRIM(x.question_code)), N'')        AS question_code,
           NULLIF(LTRIM(RTRIM(x.question_text)), N'')        AS question_text,
           NULLIF(x.help_text, N'')                          AS help_text,
           x.question_type_id,
           NULLIF(x.question_type_code, N'')                 AS question_type_code,
           NULLIF(x.question_type_name, N'')                 AS question_type_name,
           ISNULL(x.is_mandatory, 0)                         AS is_mandatory,
           x.evidence_type_id,
           CAST(NULL AS NVARCHAR(60))                        AS evidence_type_code,
           CAST(NULL AS NVARCHAR(160))                       AS evidence_type_name,
           CAST(CASE WHEN x.evidence_type_id IS NULL THEN 0 ELSE 1 END AS BIT) AS evidence_required,
           NULLIF(x.expected_evidence, N'')                  AS expected_evidence,
           x.weight,
           ISNULL(NULLIF(LTRIM(RTRIM(x.status)), N''), N'Active') AS status,
           ISNULL(x.display_order, CAST(j.[key] AS INT) + 1)  AS display_order
    INTO   #g
    FROM   OPENJSON(@questions_json) j
    CROSS APPLY OPENJSON(j.[value]) WITH (
           question_id         BIGINT         '$.questionId',
           question_code       NVARCHAR(80)   '$.questionCode',
           question_text       NVARCHAR(MAX)  '$.questionText',
           help_text           NVARCHAR(MAX)  '$.helpText',
           question_type_id    BIGINT         '$.questionTypeId',
           question_type_code  NVARCHAR(120)  '$.questionTypeCode',
           question_type_name  NVARCHAR(200)  '$.questionTypeName',
           is_mandatory        BIT            '$.isMandatory',
           evidence_type_id    INT            '$.evidenceTypeId',
           expected_evidence   NVARCHAR(MAX)  '$.expectedEvidence',
           weight              DECIMAL(10,2)  '$.weight',
           status              NVARCHAR(20)   '$.status',
           display_order       INT            '$.displayOrder') x;

    -- Evidence type code / name from the master (the id is what is chosen).
    UPDATE g SET evidence_type_code = m.evidence_type_code, evidence_type_name = m.evidence_type_name
    FROM   #g g JOIN grac_practice.evidence_type_master m ON m.evidence_type_id = g.evidence_type_id;

    -- Saved rows keep their code (fixed after create).
    UPDATE g SET question_code = q.question_code
    FROM   #g g JOIN grac_practice.org_assurance_question q
           ON q.org_assurance_question_id = g.question_id;

    DECLARE @bad INT, @msg NVARCHAR(400);
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_question q
        WHERE q.org_assurance_question_id = #g.question_id
          AND q.org_assurance_question_set_id = @question_set_id AND q.is_active = 1) ORDER BY row_no;
    IF @bad IS NOT NULL
    BEGIN SET @msg = CONCAT(N'Row ', @bad, N': this question is not in the set any more. Reload the page.'); THROW 53812, @msg, 1; END

    SET @bad = NULL;
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Question Code is required.'); THROW 53808, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_text IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Question is required.'); THROW 53809, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE question_type_id IS NULL AND question_type_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Response Type is required.'); THROW 53813, @msg, 1; END
    SELECT TOP 1 @bad = row_no FROM #g WHERE status NOT IN (N'Active', N'Inactive') ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Status must be Active or Inactive.'); THROW 53814, @msg, 1; END

    SELECT TOP 1 @bad = row_no FROM #g WHERE evidence_type_id IS NOT NULL AND evidence_type_code IS NULL ORDER BY row_no;
    IF @bad IS NOT NULL BEGIN SET @msg = CONCAT(N'Row ', @bad, N': Evidence type not found.'); THROW 53817, @msg, 1; END

    DECLARE @dup NVARCHAR(80) = (SELECT TOP 1 question_code FROM #g GROUP BY question_code HAVING COUNT(*) > 1 ORDER BY question_code);
    IF @dup IS NOT NULL
    BEGIN SET @msg = CONCAT(N'Question Code "', @dup, N'" is used on more than one row.'); THROW 53815, @msg, 1; END

    DECLARE @rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                       WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @rs IS NULL SET @rs = 1;

    BEGIN TRAN;

    -- Removed from the grid.
    UPDATE q SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    WHERE  q.org_assurance_question_set_id = @question_set_id AND q.is_active = 1
      AND  NOT EXISTS (SELECT 1 FROM #g g WHERE g.question_id = q.org_assurance_question_id);

    -- Saved rows: update; version +1 when the content changed.
    UPDATE q
    SET    version_number = q.version_number + CASE WHEN EXISTS (
                SELECT q.question_text, q.help_text, q.question_type_id, q.question_type_code, q.is_mandatory,
                       q.weight, q.evidence_type_id, q.expected_evidence
                EXCEPT
                SELECT g.question_text, g.help_text, g.question_type_id, g.question_type_code, g.is_mandatory,
                       g.weight, g.evidence_type_id, g.expected_evidence) THEN 1 ELSE 0 END,
           question_text      = g.question_text,
           help_text          = g.help_text,
           question_type_id   = g.question_type_id,
           question_type_code = g.question_type_code,
           question_type_name = g.question_type_name,
           is_mandatory       = g.is_mandatory,
           weight             = g.weight,
           evidence_required  = g.evidence_required,
           evidence_type_id   = g.evidence_type_id,
           evidence_type_code = g.evidence_type_code,
           evidence_type_name = g.evidence_type_name,
           expected_evidence  = g.expected_evidence,
           status             = g.status,
           display_order      = g.display_order,
           updated_by         = @actor,
           updated_dt         = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    JOIN   #g g ON g.question_id = q.org_assurance_question_id;
    SET @saved_count = @@ROWCOUNT;

    -- New rows whose code the set used before: bring that question back.
    UPDATE q
    SET    is_active = 1, version_number = q.version_number + 1,
           question_text = g.question_text, help_text = g.help_text,
           question_type_id = g.question_type_id, question_type_code = g.question_type_code,
           question_type_name = g.question_type_name, is_mandatory = g.is_mandatory,
           weight = g.weight, evidence_required = g.evidence_required,
           evidence_type_id = g.evidence_type_id, evidence_type_code = g.evidence_type_code,
           evidence_type_name = g.evidence_type_name,
           expected_evidence = g.expected_evidence, status = g.status,
           display_order = g.display_order, expected_response = NULL,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.org_assurance_question q
    JOIN   #g g ON g.question_id IS NULL AND g.question_code = q.question_code
    WHERE  q.org_assurance_question_set_id = @question_set_id AND q.is_active = 0;
    SET @saved_count = @saved_count + @@ROWCOUNT;

    INSERT grac_practice.org_assurance_question
        (org_assurance_question_set_id, organization_id, question_code, question_text, help_text,
         question_type_id, question_type_code, question_type_name, is_mandatory, display_order,
         weight, expected_response, evidence_required, evidence_type_id, evidence_type_code, evidence_type_name,
         expected_evidence, status, version_number,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @question_set_id, @organization_id, g.question_code, g.question_text, g.help_text,
           g.question_type_id, g.question_type_code, g.question_type_name, g.is_mandatory, g.display_order,
           g.weight, NULL, g.evidence_required, g.evidence_type_id, g.evidence_type_code, g.evidence_type_name,
           g.expected_evidence, g.status, 1,
           1, @rs, @actor, SYSUTCDATETIME()
    FROM   #g g
    WHERE  g.question_id IS NULL
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question q
                       WHERE q.org_assurance_question_set_id = @question_set_id
                         AND q.question_code = g.question_code);
    SET @saved_count = @saved_count + @@ROWCOUNT;

    -- A new row clashing with a question still active (cannot happen
    -- after the duplicate check unless two saves raced): refuse.
    IF EXISTS (SELECT 1 FROM #g g
               WHERE g.question_id IS NULL
                 AND (SELECT COUNT(*) FROM grac_practice.org_assurance_question q
                      WHERE q.org_assurance_question_set_id = @question_set_id
                        AND q.question_code = g.question_code AND q.is_active = 1) <> 1)
    BEGIN
        ROLLBACK;
        THROW 53810, 'A question with this code already exists in the set. Reload the page.', 1;
    END

    UPDATE grac_practice.org_assurance_question_set
    SET    updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE  org_assurance_question_set_id = @question_set_id;

    COMMIT;
END
GO

-- sp_org_assurance_question_save (520 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_save
    @organization_id       BIGINT,
    @question_set_id       BIGINT,
    @question_id           BIGINT        = NULL,
    @question_code         NVARCHAR(80),
    @question_text         NVARCHAR(MAX),
    @help_text             NVARCHAR(MAX) = NULL,
    @question_type_id      BIGINT        = NULL,
    @question_type_code    NVARCHAR(120) = NULL,
    @question_type_name    NVARCHAR(200) = NULL,
    @is_mandatory          BIT           = 0,
    @display_order         INT           = 0,
    @weight                DECIMAL(10,2) = NULL,
    @expected_response     NVARCHAR(MAX) = NULL,
    @evidence_type_id      INT           = NULL,      -- 520: NULL = Not Applicable
    @evidence_type_code    NVARCHAR(60)  = NULL,
    @evidence_type_name    NVARCHAR(160) = NULL,
    @expected_evidence     NVARCHAR(MAX) = NULL,      -- 520
    @status                NVARCHAR(20)  = N'Active', -- 520
    @actor                 NVARCHAR(100) = 'system',
    @question_id_out       BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53801, 'organization_id and question_set_id are required.', 1;
    IF @question_code IS NULL OR LEN(LTRIM(RTRIM(@question_code))) = 0
        THROW 53808, 'question_code is required.', 1;
    IF @question_text IS NULL OR LEN(LTRIM(RTRIM(@question_text))) = 0
        THROW 53809, 'question_text is required.', 1;
    SET @status = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Active');
    IF @status NOT IN (N'Active', N'Inactive')
        THROW 53814, 'Status must be Active or Inactive.', 1;

    -- Evidence: a type from the master, or Not Applicable (NULL).
    IF @evidence_type_id IS NOT NULL
    BEGIN
        SELECT @evidence_type_code = evidence_type_code, @evidence_type_name = evidence_type_name
        FROM grac_practice.evidence_type_master WHERE evidence_type_id = @evidence_type_id;
        IF @evidence_type_code IS NULL THROW 53817, 'Evidence type not found.', 1;
    END
    ELSE SELECT @evidence_type_code = NULL, @evidence_type_name = NULL;
    DECLARE @evidence_required BIT = CASE WHEN @evidence_type_id IS NULL THEN 0 ELSE 1 END;

    -- Verify set ownership.
    DECLARE @set_org BIGINT;
    SELECT @set_org = organization_id
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    -- 551: only a Draft version of a set is changed.
    IF (SELECT version_status FROM grac_practice.org_assurance_question_set
         WHERE org_assurance_question_set_id = @question_set_id) <> N'Draft'
        THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    IF @question_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_question
            WHERE org_assurance_question_set_id = @question_set_id
              AND question_code = @question_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53810, 'A question with this code already exists in the set.', 1;
        END

        INSERT INTO grac_practice.org_assurance_question
            (org_assurance_question_set_id, organization_id,
             question_code, question_text, help_text,
             question_type_id, question_type_code, question_type_name,
             is_mandatory, display_order, weight, expected_response,
             evidence_required, evidence_type_id, evidence_type_code, evidence_type_name,
             expected_evidence, status, version_number,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@question_set_id, @organization_id,
             @question_code, @question_text, @help_text,
             @question_type_id, @question_type_code, @question_type_name,
             ISNULL(@is_mandatory, 0), ISNULL(@display_order, 0),
             @weight, @expected_response,
             @evidence_required, @evidence_type_id, @evidence_type_code, @evidence_type_name,
             @expected_evidence, @status, 1,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @question_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @q_org BIGINT, @q_set BIGINT;
        SELECT @q_org = organization_id,
               @q_set = org_assurance_question_set_id
        FROM grac_practice.org_assurance_question
        WHERE org_assurance_question_id = @question_id
          AND is_active = 1;

        IF @q_org IS NULL BEGIN ROLLBACK; THROW 53811, 'Question not found.', 1; END
        IF @q_org <> @organization_id BEGIN ROLLBACK; THROW 53807, 'Question belongs to a different organization.', 1; END
        IF @q_set <> @question_set_id BEGIN ROLLBACK; THROW 53812, 'Question does not belong to the specified set.', 1; END

        DECLARE @changed BIT = 0;
        IF EXISTS (
            SELECT question_text, help_text, question_type_id, question_type_code, is_mandatory,
                   weight, expected_response, evidence_type_id, expected_evidence
            FROM grac_practice.org_assurance_question WHERE org_assurance_question_id = @question_id
            EXCEPT
            SELECT @question_text, @help_text, @question_type_id, @question_type_code, ISNULL(@is_mandatory, 0),
                   @weight, @expected_response, @evidence_type_id, @expected_evidence)
            SET @changed = 1;

        UPDATE grac_practice.org_assurance_question
        SET question_text      = @question_text,
            help_text          = @help_text,
            question_type_id   = @question_type_id,
            question_type_code = @question_type_code,
            question_type_name = @question_type_name,
            is_mandatory       = ISNULL(@is_mandatory, 0),
            display_order      = ISNULL(@display_order, 0),
            weight             = @weight,
            expected_response  = @expected_response,
            evidence_required  = @evidence_required,
            evidence_type_id   = @evidence_type_id,
            evidence_type_code = @evidence_type_code,
            evidence_type_name = @evidence_type_name,
            expected_evidence  = @expected_evidence,
            status             = @status,
            version_number     = version_number + CASE WHEN @changed = 1 THEN 1 ELSE 0 END,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_question_id = @question_id;

        SET @question_id_out = @question_id;
    END

    COMMIT;
END
GO

-- sp_org_assurance_question_delete (077 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_delete
    @organization_id BIGINT,
    @question_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_id IS NULL
        THROW 53802, 'organization_id and question_id are required.', 1;

    DECLARE @q_org BIGINT;
    SELECT @q_org = organization_id
    FROM grac_practice.org_assurance_question
    WHERE org_assurance_question_id = @question_id
      AND is_active = 1;

    IF @q_org IS NULL THROW 53811, 'Question not found.', 1;
    IF @q_org <> @organization_id THROW 53807, 'Question belongs to a different organization.', 1;
    -- 551: only a Draft version of a set is changed.
    IF (SELECT qs.version_status FROM grac_practice.org_assurance_question q
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = q.org_assurance_question_set_id
         WHERE q.org_assurance_question_id = @question_id) <> N'Draft'
        THROW 53840, 'Only a Draft version of a question set can be changed. Use New Version to change an approved set.', 1;

    UPDATE grac_practice.org_assurance_question
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_question_id = @question_id;
END
GO


-- =====================================================================
-- 6. Definition question sets -- Active versions only
-- =====================================================================

-- sp_org_assurance_definition_question_set_get (278 body + 551)
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
           qs.version_number                            AS SetVersionNumber,   -- 551
           qs.version_status                            AS SetVersionStatus,   -- 551
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
           qs.version_number                AS SetVersionNumber,   -- 551
           (SELECT COUNT(*)
              FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)         AS QuestionCount
    FROM grac_practice.org_assurance_question_set qs
    WHERE qs.organization_id = @organization_id
      AND qs.is_active = 1
      AND qs.version_status = N'Active'      -- 551: approved versions only
    ORDER BY qs.set_name;
END
GO

-- sp_org_assurance_definition_question_set_save (278 body + 551)
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

    -- 551: only an approved (Active) question set version is adopted.
    IF EXISTS (
        SELECT 1
        FROM @incoming i
        JOIN grac_practice.org_assurance_question_set qs
             ON qs.org_assurance_question_set_id = i.question_set_id
        WHERE qs.version_status <> N'Active')
        THROW 53714, 'Only an approved (Active) question set version can be added to an audit.', 1;

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
-- 7. sp_org_assurance_definition_save (119 body + 551: copy the configuration)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_save
    @organization_id            BIGINT,
    @definition_id              BIGINT        = NULL,
    @definition_code            NVARCHAR(80),
    @definition_name            NVARCHAR(240),
    @owner_role_id              BIGINT        = NULL,   -- 119
    @owner_role_name            NVARCHAR(120) = NULL,   -- 119
    @owner_employee_id          BIGINT        = NULL,
    @owner_display_name         NVARCHAR(240) = NULL,
    @description                NVARCHAR(MAX) = NULL,
    @objective                  NVARCHAR(MAX) = NULL,
    @effective_date             DATE          = NULL,
    @assurance_category_id      BIGINT        = NULL,
    @assurance_category_code    NVARCHAR(120) = NULL,
    @assurance_category_name    NVARCHAR(200) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @definition_id_out          BIGINT OUTPUT,
    @definition_version_id_out  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @definition_code IS NULL OR LEN(LTRIM(RTRIM(@definition_code))) = 0
        THROW 53603, 'definition_code is required.', 1;
    IF @definition_name IS NULL OR LEN(LTRIM(RTRIM(@definition_name))) = 0
        THROW 53604, 'definition_name is required.', 1;

    -- ==========================================================
    -- 119 hybrid ownership resolver -- Owner (single owner field)
    -- ==========================================================
    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @owner_role_id,
             @employee_id_out   = @owner_employee_id  OUTPUT,
             @employee_name_out = @owner_display_name OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id   = e.role_id,
               @owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @owner_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @owner_employee_id IS NOT NULL
       AND (@owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@owner_display_name))) = 0)
        SELECT @owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @owner_employee_id;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @draft_status_id INT = (
        SELECT org_assurance_status_id
        FROM grac_practice.org_assurance_status_master
        WHERE status_code = N'Draft');

    BEGIN TRAN;

    IF @definition_id IS NULL
    BEGIN
        -- New definition
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_definition
            WHERE organization_id = @organization_id
              AND definition_code = @definition_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53605, 'A definition with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_definition
            (organization_id, definition_code, definition_name,
             owner_role_id, owner_role_name,
             owner_employee_id, owner_display_name,
             current_version_id, current_status_id, active_version_id,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @definition_code, @definition_name,
             @owner_role_id, @owner_role_name,
             @owner_employee_id, @owner_display_name,
             NULL, @draft_status_id, NULL,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.org_assurance_definition_version
            (org_assurance_definition_id, organization_id, version_number, version_label,
             description, objective, effective_date,
             assurance_category_id, assurance_category_code, assurance_category_name,
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
             @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_version_id_out = SCOPE_IDENTITY();

        UPDATE grac_practice.org_assurance_definition
        SET current_version_id = @definition_version_id_out,
            updated_by = @actor,
            updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_definition_id = @definition_id_out;

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id,
             organization_id, action_code, from_status_id, to_status_id,
             actor_display_name, entered_by)
        VALUES
            (@definition_id_out, @definition_version_id_out, @organization_id,
             N'CREATE', NULL, @draft_status_id, @actor, @actor);
    END
    ELSE
    BEGIN
        -- Existing definition -- validate org ownership + branch on version status
        DECLARE @current_version_id BIGINT,
                @current_status_code NVARCHAR(60),
                @current_status_id   INT,
                @next_version_number INT,
                @def_org             BIGINT;

        SELECT @def_org             = d.organization_id,
               @current_version_id  = d.current_version_id,
               @current_status_id   = d.current_status_id,
               @current_status_code = s.status_code
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = d.current_status_id
        WHERE d.org_assurance_definition_id = @definition_id
          AND d.is_active = 1;

        IF @def_org IS NULL
        BEGIN
            ROLLBACK;
            THROW 53606, 'Definition not found.', 1;
        END
        IF @def_org <> @organization_id
        BEGIN
            ROLLBACK;
            THROW 53607, 'Definition belongs to a different organization.', 1;
        END

        SET @definition_id_out = @definition_id;

        IF @current_status_code IN (N'UnderReview', N'Approved')
        BEGIN
            ROLLBACK;
            THROW 53608, 'Cannot edit a definition that is Under Review or Approved. Withdraw the review first or activate + create a new draft.', 1;
        END

        IF @current_status_code = N'Draft'
        BEGIN
            -- In-place update of the existing draft version.
            UPDATE grac_practice.org_assurance_definition_version
            SET description             = @description,
                objective               = @objective,
                effective_date          = @effective_date,
                assurance_category_id   = @assurance_category_id,
                assurance_category_code = @assurance_category_code,
                assurance_category_name = @assurance_category_name,
                updated_by              = @actor,
                updated_dt              = SYSUTCDATETIME()
            WHERE org_assurance_definition_version_id = @current_version_id;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            SET @definition_version_id_out = @current_version_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @current_version_id, @organization_id,
                 N'EDIT', @current_status_id, @current_status_id, @actor, @actor);
        END
        ELSE
        BEGIN
            -- Active or Retired -- create a new Draft version.
            SELECT @next_version_number = ISNULL(MAX(version_number), 0) + 1
            FROM grac_practice.org_assurance_definition_version
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_version
                (org_assurance_definition_id, organization_id, version_number,
                 version_label, description, objective, effective_date,
                 assurance_category_id, assurance_category_code, assurance_category_name,
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

            -- 551: the new Draft version carries the configuration of the
            -- version it revises (scope, question sets, workflow, scoring);
            -- it started empty before.
            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id,
                 @from_version_id = @current_version_id,
                 @to_version_id   = @definition_version_id_out,
                 @actor           = @actor;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                current_version_id = @definition_version_id_out,
                current_status_id  = @draft_status_id,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @definition_version_id_out, @organization_id,
                 N'CREATE', @current_status_id, @draft_status_id, @actor, @actor);
        END
    END

    COMMIT;
END
GO


-- =====================================================================
-- 8. Plannable audit = an Active version, not Retired (546 bodies + 551)
-- =====================================================================

-- sp_org_assurance_plan_item_save (546 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_save
    @organization_id             BIGINT,
    @plan_id                     BIGINT,
    @plan_item_id                BIGINT        = NULL,
    @org_assurance_definition_id BIGINT,
    @definition_code             NVARCHAR(80)  = NULL,
    @definition_name             NVARCHAR(240) = NULL,
    @item_order                  INT           = 0,
    @scheduled_from              DATE          = NULL,
    @scheduled_to                DATE          = NULL,
    @assigned_auditor_role_id    BIGINT        = NULL,   -- 121
    @assigned_auditor_role_name  NVARCHAR(120) = NULL,   -- 121
    @assigned_auditor_employee_id BIGINT       = NULL,
    @assigned_auditor_name       NVARCHAR(240) = NULL,
    @assigned_team_name          NVARCHAR(200) = NULL,
    @assigned_department_id      BIGINT        = NULL,
    @assigned_department_name    NVARCHAR(200) = NULL,
    @assigned_branch_id          BIGINT        = NULL,
    @assigned_branch_name        NVARCHAR(200) = NULL,
    @notes                       NVARCHAR(MAX) = NULL,
    @actor                       NVARCHAR(100) = 'system',
    @plan_item_id_out            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;
    IF @org_assurance_definition_id IS NULL
        THROW 53913, 'org_assurance_definition_id is required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id
          AND is_active = 1)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    -- Verify definition ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @org_assurance_definition_id
          AND organization_id            = @organization_id
          AND is_active = 1)
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;

    -- 546: slots change only while the plan can still be edited (Draft /
    -- Submitted -- the plan header's own rule, 121); only an Active audit
    -- is planned; a slot lies inside the plan period, from <= to. The code
    -- and name are the audit's own (the snapshot no longer trusts the
    -- caller's copy).
    DECLARE @plan_status NVARCHAR(60), @period_from DATE, @period_to DATE;
    SELECT @plan_status = s.status_code,
           @period_from = p.period_from,
           @period_to   = p.period_to
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master s
           ON s.org_assurance_plan_status_id = p.status_id
     WHERE p.org_assurance_plan_id = @plan_id;
    IF @plan_status NOT IN (N'Draft', N'Submitted')
        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;

    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    DECLARE @def_status NVARCHAR(60), @def_active_version BIGINT;
    SELECT @def_status         = s.status_code,
           @def_active_version = d.active_version_id,
           @definition_code    = d.definition_code,
           @definition_name    = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_active_version IS NULL OR @def_status = N'Retired'
        THROW 53933, 'Only an audit with an Active version can be added to a plan.', 1;

    IF @scheduled_from IS NOT NULL AND @scheduled_to IS NOT NULL AND @scheduled_to < @scheduled_from
        THROW 53934, 'Scheduled To must be on or after Scheduled From.', 1;
    IF (@period_from IS NOT NULL AND (@scheduled_from < @period_from OR @scheduled_to < @period_from))
       OR (@period_to IS NOT NULL AND (@scheduled_from > @period_to OR @scheduled_to > @period_to))
        THROW 53934, 'The scheduled dates must fall within the plan period.', 1;

    -- ==========================================================
    -- 121 hybrid ownership resolver -- Auditor
    -- ==========================================================
    IF @assigned_auditor_role_id IS NOT NULL
       AND (@assigned_auditor_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_role_name))) = 0)
        SELECT @assigned_auditor_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_auditor_role_id AND organization_id = @organization_id;

    IF @assigned_auditor_role_id IS NOT NULL AND @assigned_auditor_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @assigned_auditor_role_id,
             @employee_id_out   = @assigned_auditor_employee_id  OUTPUT,
             @employee_name_out = @assigned_auditor_name         OUTPUT;

    IF @assigned_auditor_employee_id IS NOT NULL AND @assigned_auditor_role_id IS NULL
    BEGIN
        SELECT @assigned_auditor_role_id   = e.role_id,
               @assigned_auditor_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_auditor_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_auditor_employee_id IS NOT NULL
       AND (@assigned_auditor_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_name))) = 0)
        SELECT @assigned_auditor_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_auditor_employee_id;

    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item
            (org_assurance_plan_id, organization_id,
             org_assurance_definition_id, definition_code, definition_name,
             item_order, scheduled_from, scheduled_to,
             assigned_auditor_role_id, assigned_auditor_role_name,       -- 121
             assigned_auditor_employee_id, assigned_auditor_name,
             assigned_team_name,
             assigned_department_id, assigned_department_name,
             assigned_branch_id, assigned_branch_name,
             notes, is_active, entered_by, entered_dt)
        VALUES
            (@plan_id, @organization_id,
             @org_assurance_definition_id, @definition_code, @definition_name,
             ISNULL(@item_order, 0), @scheduled_from, @scheduled_to,
             @assigned_auditor_role_id, @assigned_auditor_role_name,     -- 121
             @assigned_auditor_employee_id, @assigned_auditor_name,
             @assigned_team_name,
             @assigned_department_id, @assigned_department_name,
             @assigned_branch_id, @assigned_branch_name,
             @notes, 1, @actor, SYSUTCDATETIME());

        SET @plan_item_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @item_plan BIGINT;
        SELECT @item_plan = org_assurance_plan_id
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_plan IS NULL BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @item_plan <> @plan_id
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END

        UPDATE grac_practice.org_assurance_plan_item
        SET org_assurance_definition_id = @org_assurance_definition_id,
            definition_code             = @definition_code,
            definition_name             = @definition_name,
            item_order                  = ISNULL(@item_order, 0),
            scheduled_from              = @scheduled_from,
            scheduled_to                = @scheduled_to,
            assigned_auditor_role_id    = @assigned_auditor_role_id,       -- 121
            assigned_auditor_role_name  = @assigned_auditor_role_name,     -- 121
            assigned_auditor_employee_id = @assigned_auditor_employee_id,
            assigned_auditor_name       = @assigned_auditor_name,
            assigned_team_name          = @assigned_team_name,
            assigned_department_id      = @assigned_department_id,
            assigned_department_name    = @assigned_department_name,
            assigned_branch_id          = @assigned_branch_id,
            assigned_branch_name        = @assigned_branch_name,
            notes                       = @notes,
            updated_by                  = @actor,
            updated_dt                  = SYSUTCDATETIME()
        WHERE org_assurance_plan_item_id = @plan_item_id;

        SET @plan_item_id_out = @plan_item_id;
    END

    COMMIT;
END
GO

-- sp_org_assurance_plan_item_list (546 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_list
    @organization_id BIGINT,
    @plan_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    SELECT i.org_assurance_plan_item_id  AS PlanItemId,
           i.org_assurance_plan_id       AS PlanId,
           i.org_assurance_definition_id AS DefinitionId,
           i.definition_code             AS DefinitionCode,
           i.definition_name             AS DefinitionName,
           i.org_assurance_definition_version_id AS DefinitionVersionId,
           i.item_order                  AS ItemOrder,
           i.scheduled_from              AS ScheduledFrom,
           i.scheduled_to                AS ScheduledTo,
           i.assigned_auditor_role_id    AS AssignedAuditorRoleId,      -- 121
           i.assigned_auditor_role_name  AS AssignedAuditorRoleName,    -- 121
           i.assigned_auditor_employee_id AS AssignedAuditorEmployeeId,
           i.assigned_auditor_name       AS AssignedAuditorName,
           i.assigned_team_name          AS AssignedTeamName,
           i.assigned_department_id      AS AssignedDepartmentId,
           i.assigned_department_name    AS AssignedDepartmentName,
           i.assigned_branch_id          AS AssignedBranchId,
           i.assigned_branch_name        AS AssignedBranchName,
           i.notes                       AS Notes,
           i.entered_by                  AS EnteredBy,
           i.entered_dt                  AS EnteredDt,
           i.updated_by                  AS UpdatedBy,
           i.updated_dt                  AS UpdatedDt,
           -- 546: the audit's current status, the slot's latest execution,
           -- and the slot status derived from them:
           --   InProgress / Completed  -- a live execution (Completed once
           --                              Approved or Closed);
           --   NotExecuted             -- none, and the audit is Retired or
           --                              the plan Closed;
           --   Planned                 -- none yet (a Cancelled one counts
           --                              as none).
           ds.status_code                AS DefinitionStatusCode,
           ds.status_name                AS DefinitionStatusName,
           -- 551: the audit can be planned / executed -- it has an Active
           -- version and is not Retired (a revision may be in Draft).
           CAST(CASE WHEN d.active_version_id IS NOT NULL AND ds.status_code <> N'Retired'
                     THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
           ex.org_assurance_execution_id AS ExecutionId,
           ex.execution_code             AS ExecutionCode,
           ex.status_code                AS ExecutionStatusCode,
           ex.status_name                AS ExecutionStatusName,
           CASE WHEN ex.org_assurance_execution_id IS NOT NULL AND ex.status_code <> N'Cancelled'
                     THEN CASE WHEN ex.status_code IN (N'Approved', N'Closed') THEN N'Completed' ELSE N'InProgress' END
                WHEN ds.status_code = N'Retired' OR ps.status_code = N'Closed'
                     THEN N'NotExecuted'
                ELSE N'Planned' END      AS SlotStatus
    FROM grac_practice.org_assurance_plan_item i
    JOIN grac_practice.org_assurance_plan p
         ON p.org_assurance_plan_id = i.org_assurance_plan_id
    JOIN grac_practice.org_assurance_plan_status_master ps
         ON ps.org_assurance_plan_status_id = p.status_id
    LEFT JOIN grac_practice.org_assurance_definition d
         ON d.org_assurance_definition_id = i.org_assurance_definition_id
    LEFT JOIN grac_practice.org_assurance_status_master ds
         ON ds.org_assurance_status_id = d.current_status_id
    OUTER APPLY (
        SELECT TOP 1 e.org_assurance_execution_id, e.execution_code,
               es.status_code, es.status_name
          FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND e.organization_id = i.organization_id
           AND e.is_active = 1
         ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                  e.org_assurance_execution_id DESC
    ) ex
    WHERE i.org_assurance_plan_id = @plan_id
      AND i.organization_id       = @organization_id
      AND i.is_active = 1
    ORDER BY i.item_order, i.org_assurance_plan_item_id;
END
GO

-- sp_org_assurance_plan_item_start_execution (546 body + 551)
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT, @definition_id BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200);
    SELECT @item_plan     = i.org_assurance_plan_id,
           @definition_id = i.org_assurance_definition_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name
      FROM grac_practice.org_assurance_plan_item i
     WHERE i.org_assurance_plan_item_id = @plan_item_id
       AND i.organization_id = @organization_id
       AND i.is_active = 1;

    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan p
          JOIN grac_practice.org_assurance_plan_status_master s
               ON s.org_assurance_plan_status_id = p.status_id
         WHERE p.org_assurance_plan_id = @plan_id
           AND p.organization_id = @organization_id
           AND p.is_active = 1
           AND s.status_code IN (N'Approved', N'Active'))
        THROW 53935, 'An execution can be started only from an Approved or Active plan.', 1;

    -- 551: run the audit's ACTIVE version (its current version may be a
    -- Draft revision); no Active version, or Retired, cannot be executed.
    DECLARE @active_version_id BIGINT;
    SELECT @active_version_id = d.active_version_id
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @definition_id
       AND s.status_code <> N'Retired';
    IF @active_version_id IS NULL
        THROW 53933, 'The audit has no Active version (it may have been retired), so this slot cannot be executed.', 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = @plan_item_id
           AND e.is_active = 1
           AND es.status_code <> N'Cancelled')
        THROW 53936, 'This plan item already has an execution.', 1;

    -- The slot becomes the execution: its dates, its auditor as the
    -- owner, its team. No snapshot is passed, so the scope is resolved
    -- now (545). Materialize runs its own transaction.
    EXEC grac_practice.sp_org_assurance_execution_materialize
         @organization_id     = @organization_id,
         @definition_id       = @definition_id,
         @version_id          = @active_version_id,   -- 551
         @scope_resolution_id = NULL,
         @execution_code      = NULL,
         @execution_name      = NULL,
         @origin_type         = N'PLAN',
         @plan_id             = @plan_id,
         @plan_item_id        = @plan_item_id,
         @trigger_config_id   = NULL,
         @planned_start_dt    = @from,
         @planned_end_dt      = @to,
         @owner_role_id       = @aud_role_id,
         @owner_role_name     = @aud_role_name,
         @owner_employee_id   = @aud_emp_id,
         @owner_display_name  = @aud_name,
         @assigned_team_name  = @team,
         @notes               = NULL,
         @actor               = @actor,
         @execution_id_out    = @execution_id_out OUTPUT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id_out;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '551 version columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_question_set','version_status') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_set WHERE root_question_set_id IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '551 clone engine',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_clone_rows','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_definition_version_copy_config','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 set lifecycle procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_question_set_new_version','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_submit','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_return','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_approve','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_impact','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_question_set_version_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 Draft-only question changes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_question_set_questions_save')) LIKE '%THROW 53840%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 definition edit copies configuration',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_save')) LIKE '%version_copy_config%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '551 execution runs the Active version',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_start_execution')) LIKE '%@active_version_id%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '551 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
