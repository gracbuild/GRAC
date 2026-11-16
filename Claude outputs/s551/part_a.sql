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
