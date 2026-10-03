-- =====================================================================
-- 395 Repository subscription copy model -- PHASE 3 (detect, notify,
-- approve)
--
-- Sir's decisions (2026-09-28, docs/statement-subscription-copy-model-
-- design.md section 8): every repository change -- new, edited, retired --
-- waits for approval; the release owner OR an organization admin approves;
-- notifications get their own table; a retirement only flags the copy;
-- detection runs on a schedule.
--
-- WHAT THIS FILE ADDS
--   Tables
--     organization_repository_change               one row per detected
--        difference between an organization's copy and grac_new
--     organization_repository_change_notification  one row per recipient,
--        release and detection run that raised new pending changes
--   repository_copy_config.label_sql -- how each copy step names an item
--   Procedures
--     sp_repo_change_detect_step        one copy step, one organization
--                                       (Added / Changed per release,
--                                       Retired once)
--     sp_repository_change_detect       every organization; then supersede
--                                       older pending rows and notify.
--                                       Called by RepositoryChangeDetectWorker
--                                       (API) on a timer, or by SQL Agent.
--     sp_repository_change_apply        approve / reject one change
--     sp_repository_change_list         review page
--     sp_repository_change_counts       pending count per release (badge)
--     sp_repository_change_notification_list / _mark_read   Home
--   Re-issued
--     sp_repo_clone_sync            (392) -- @key_value now bypasses the
--                                   release scope, so an approved change
--                                   applies exactly that item even when it
--                                   is shared by several releases
--     sp_repository_copy_statements (392) -- optional @framework_statement_id
--                                   applies one statement (forced refresh)
--
-- APPLY RULES (sp_repository_change_apply)
--   Added / Changed -> the SAME copy routines subscribing uses, limited to
--                      the one key (one implementation of "copy").
--   Retired         -> lifecycle_status = 'Retired' on the copy row. Flag
--                      only: practices, instances, tasks, evidence are not
--                      touched (decision 4).
--   Statement / statement->practice link / requirement approved for a
--   release -> sp_repository_practice_import for that release (so a newly
--   approved statement gets its practices once its links are approved).
--   Requirement Changed -> the organization's practice
--   (organization_requirement) name / statement / objective follow it.
--   Obligation Added / Changed -> the evidence its copied EvidenceJson
--   lists is synced with it, and practice_instance_obligation.obligation_name
--   follows the new name where the organization has not modified the row.
--   Every decision is written to practice_audit_trace.
--
-- WHO MAY DECIDE (checked here, not only in the UI)
--   @is_admin = 1 (session data scope ORGANIZATION / GLOBAL, stamped by the
--   Web tier) OR the caller owns an active subscription of the change's
--   release (repository_subscription.owner_id). A change with no release
--   (an item shared by releases) needs an admin or the owner of ANY active
--   subscription of the organization.
--
-- SAFE TO RE-RUN. Requires 391-394.
-- Rollback: 395_repository_change_detect_approve_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
   OR COL_LENGTH('grac_practice.repository_copy_config','handler_proc') IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_practice_import','P') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_org_obligation_typed_detail','V') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_role','data_scope') IS NULL
   OR COL_LENGTH('grac_practice.repository_subscription','owner_id') IS NULL
BEGIN
    PRINT 'ABORT (395): run 391-394 first (and 027 / 032 for roles and data scope).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_repository_change','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.organization_repository_change(
        change_id              BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_org_repository_change PRIMARY KEY,
        organization_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_org_repository_change_org
                REFERENCES grac_practice.organization(organization_id),
        -- NULL for an item shared by releases whose change was found
        -- without a release (a retired obligation / control / requirement).
        release_id             BIGINT NULL,
        copy_code              NVARCHAR(40)  NOT NULL,
        change_action          NVARCHAR(20)  NOT NULL,   -- Added / Changed / Retired
        change_type            NVARCHAR(60)  NOT NULL,   -- copy_code + change_action
        source_key             BIGINT        NOT NULL,
        source_label           NVARCHAR(500) NULL,
        old_snapshot_json      NVARCHAR(MAX) NULL,
        new_snapshot_json      NVARCHAR(MAX) NULL,
        new_version_hash       VARBINARY(32) NULL,
        status                 NVARCHAR(20)  NOT NULL
            CONSTRAINT df_pm_org_repository_change_status DEFAULT N'Pending',
                               -- Pending / Approved / Rejected / Superseded
        detection_run_id       UNIQUEIDENTIFIER NULL,
        detected_dt            DATETIME2 NOT NULL
            CONSTRAINT df_pm_org_repository_change_detected DEFAULT SYSUTCDATETIME(),
        decided_by_employee_id BIGINT NULL,
        decided_by             NVARCHAR(100) NULL,
        decided_dt             DATETIME2 NULL,
        decision_remark        NVARCHAR(1000) NULL,
        entered_by             NVARCHAR(100) NOT NULL
    );
    CREATE INDEX ix_pm_org_repository_change_pending
        ON grac_practice.organization_repository_change(organization_id, status, release_id);
    CREATE INDEX ix_pm_org_repository_change_key
        ON grac_practice.organization_repository_change(organization_id, copy_code, source_key, change_action);
    PRINT '395: organization_repository_change created.';
END
GO

IF OBJECT_ID('grac_practice.organization_repository_change_notification','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.organization_repository_change_notification(
        notification_id       BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_org_repo_change_notification PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_org_repo_change_notification_org
                REFERENCES grac_practice.organization(organization_id),
        release_id            BIGINT NULL,
        detection_run_id      UNIQUEIDENTIFIER NOT NULL,
        recipient_employee_id BIGINT NOT NULL
            CONSTRAINT fk_pm_org_repo_change_notification_emp
                REFERENCES grac_practice.organization_employee(employee_id),
        recipient_reason      NVARCHAR(20) NOT NULL,     -- ReleaseOwner / OrgAdmin
        pending_count         INT NOT NULL,
        status                NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_org_repo_change_notification_status DEFAULT N'Unread',
                              -- Unread / Read / Cleared / Superseded
        created_dt            DATETIME2 NOT NULL
            CONSTRAINT df_pm_org_repo_change_notification_created DEFAULT SYSUTCDATETIME(),
        read_dt               DATETIME2 NULL
    );
    CREATE INDEX ix_pm_org_repo_change_notification_recipient
        ON grac_practice.organization_repository_change_notification(recipient_employee_id, organization_id, status);
    PRINT '395: organization_repository_change_notification created.';
END
GO

-- =====================================================================
-- 2. repository_copy_config.label_sql -- the item name shown for review
-- =====================================================================
-- Expression over the placeholder alias {a} (a source-view row or a copy
-- row -- same column names). Map rows name both ends from grac_new,
-- which detection is allowed to read.
IF COL_LENGTH('grac_practice.repository_copy_config','label_sql') IS NULL
    ALTER TABLE grac_practice.repository_copy_config ADD label_sql NVARCHAR(MAX) NULL;
GO
UPDATE c SET label_sql = v.label_sql, updated_by = N'migration-395', updated_dt = SYSUTCDATETIME()
FROM grac_practice.repository_copy_config c
JOIN (VALUES
    (N'StructureNode', N'CONCAT({a}.node_reference, N'' '', {a}.node_title)'),
    (N'SourceControlMap', N'CONCAT((SELECT TOP (1) x.control_code FROM grac_new.control x WHERE x.control_id = {a}.control_id), N'' in '', (SELECT TOP (1) x.node_reference FROM grac_new.source_structure_node x WHERE x.structure_node_id = {a}.structure_node_id))'),
    (N'Control', N'CONCAT({a}.control_code, N'' - '', {a}.control_name)'),
    (N'ControlRequirementMap', N'CONCAT((SELECT TOP (1) x.control_code FROM grac_new.control x WHERE x.control_id = {a}.control_id), N'' -> '', (SELECT TOP (1) x.requirement_code FROM grac_new.requirement x WHERE x.requirement_id = {a}.requirement_id))'),
    (N'Statement', N'CONCAT({a}.statement_reference, N'' - '', {a}.statement_title)'),
    (N'StatementRequirementMap', N'CONCAT((SELECT TOP (1) x.statement_reference FROM grac_new.framework_statement x WHERE x.framework_statement_id = {a}.framework_statement_id), N'' -> '', (SELECT TOP (1) x.requirement_code FROM grac_new.requirement x WHERE x.requirement_id = {a}.requirement_id))'),
    (N'Requirement', N'CONCAT({a}.requirement_code, N'' - '', {a}.requirement_name)'),
    (N'Obligation', N'COALESCE(NULLIF(LTRIM(RTRIM({a}.obligation_name)), N''''), LEFT({a}.obligation_text, 300))'),
    (N'ObligationMap', N'CONCAT((SELECT TOP (1) COALESCE(NULLIF(LTRIM(RTRIM(x.obligation_name)), N''''), LEFT(x.obligation_text, 120)) FROM grac_new.requirement_obligation x WHERE x.obligation_id = {a}.obligation_id), N'' -> '', (SELECT TOP (1) x.requirement_code FROM grac_new.requirement x WHERE x.requirement_id = {a}.requirement_id))'),
    (N'ObligationEvidence', N'CONCAT(N''Evidence '', {a}.obligation_evidence_id, N'' of '', (SELECT TOP (1) COALESCE(NULLIF(LTRIM(RTRIM(x.obligation_name)), N''''), LEFT(x.obligation_text, 120)) FROM grac_new.requirement_obligation x WHERE x.obligation_id = {a}.obligation_id))')
) AS v(copy_code, label_sql) ON v.copy_code = c.copy_code;
PRINT '395: repository_copy_config.label_sql set.';
GO

-- =====================================================================
-- 3. sp_repo_clone_sync (re-issued from 392): @key_value bypasses scope
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_clone_sync
    @copy_code       NVARCHAR(40),
    @organization_id BIGINT,
    @release_id      BIGINT,
    @refresh         BIT = 0,
    @actor           NVARCHAR(100) = N'system',
    @key_value       BIGINT = NULL,
    @inserted        INT = NULL OUTPUT,
    @updated         INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view SYSNAME, @target SYSNAME, @pk SYSNAME, @key SYSNAME, @scope NVARCHAR(MAX), @msg NVARCHAR(400);
    SELECT @view = source_view, @target = target_table, @pk = org_pk_column,
           @key = key_column, @scope = scope_sql
    FROM grac_practice.repository_copy_config
    WHERE copy_code = @copy_code AND is_generic_clone = 1 AND status = N'Active';
    IF @view IS NULL
    BEGIN
        SET @msg = N'sp_repo_clone_sync: no active generic copy_code ' + ISNULL(@copy_code, N'(null)') + N'.';
        THROW 53913, @msg, 1;
    END

    -- 395: one approved item applies by its key alone. The release scope
    -- only decides what belongs to a release when copying a whole release.
    IF @key_value IS NOT NULL SET @scope = N'1 = 1';

    DECLARE @view_q   NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@view);
    DECLARE @target_q NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@target);
    DECLARE @view_id   INT = OBJECT_ID(@view_q, 'V');
    DECLARE @target_id INT = OBJECT_ID(@target_q, 'U');
    DECLARE @key_q NVARCHAR(300) = QUOTENAME(@key);

    DECLARE @cols NVARCHAR(MAX), @src_cols NVARCHAR(MAX), @set_cols NVARCHAR(MAX);
    SELECT @cols     = STRING_AGG(CAST(QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id),
           @src_cols = STRING_AGG(CAST(N'src.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id),
           @set_cols = STRING_AGG(CAST(QUOTENAME(tc.name) + N' = src.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                       WITHIN GROUP (ORDER BY tc.column_id)
    FROM sys.columns tc
    JOIN sys.columns vc ON vc.object_id = @view_id AND vc.name = tc.name
    WHERE tc.object_id = @target_id
      AND tc.name <> @pk
      AND tc.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r);

    DECLARE @status_filter NVARCHAR(100) =
        CASE WHEN EXISTS (SELECT 1 FROM sys.columns WHERE object_id = @view_id AND name = N'status')
             THEN N' AND src.status = N''Active''' ELSE N'' END;

    DECLARE @params NVARCHAR(400) =
        N'@organization_id BIGINT, @release_id BIGINT, @actor NVARCHAR(100), @key_value BIGINT, @n INT OUTPUT';
    DECLARE @sql NVARCHAR(MAX);

    SET @updated = 0;
    IF @refresh = 1
    BEGIN
        SET @sql = N'UPDATE t SET ' + @set_cols + N',
       source_version_hash = src.content_hash,
       copied_dt = SYSUTCDATETIME(),
       copied_by = @actor
FROM ' + @target_q + N' t
JOIN ' + @view_q + N' src ON src.' + @key_q + N' = t.' + @key_q + N'
WHERE t.organization_id = @organization_id
  AND (' + @scope + N')
  AND (@key_value IS NULL OR src.' + @key_q + N' = @key_value)
  AND (t.source_version_hash IS NULL OR src.content_hash IS NULL
       OR t.source_version_hash <> src.content_hash);
SET @n = @@ROWCOUNT;';
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @actor = @actor, @key_value = @key_value, @n = @updated OUTPUT;
    END

    SET @sql = N'INSERT ' + @target_q + N'(organization_id, lifecycle_status, source_version_hash, copied_dt, copied_by, ' + @cols + N')
SELECT @organization_id, N''Active'', src.content_hash, SYSUTCDATETIME(), @actor, ' + @src_cols + N'
FROM ' + @view_q + N' src
WHERE (' + @scope + N')' + @status_filter + N'
  AND (@key_value IS NULL OR src.' + @key_q + N' = @key_value)
  AND NOT EXISTS (SELECT 1 FROM ' + @target_q + N' t
                  WHERE t.organization_id = @organization_id
                    AND t.' + @key_q + N' = src.' + @key_q + N');
SET @n = @@ROWCOUNT;';
    SET @inserted = 0;
    EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
         @actor = @actor, @key_value = @key_value, @n = @inserted OUTPUT;
END
GO

-- =====================================================================
-- 4. sp_repository_copy_statements (re-issued from 392): one statement
-- =====================================================================
-- @framework_statement_id NULL: unchanged from 392 (whole release).
-- @framework_statement_id set: that statement only, content always
-- re-copied (an approved Added or Changed item).
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_copy_statements
    @organization_id        BIGINT,
    @release_id             BIGINT,
    @refresh                BIT           = 0,
    @actor                  NVARCHAR(100) = N'system',
    @inserted               INT           = NULL OUTPUT,
    @updated                INT           = NULL OUTPUT,
    @framework_statement_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @not_updated_status_id INT = (
        SELECT TOP (1) applicability_status_id
        FROM grac_practice.applicability_status_master
        WHERE status_code = 'Not Updated' OR status_name = 'Not Updated');
    DECLARE @active_status_id INT = (
        SELECT TOP (1) record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'Active' OR status_name = 'Active');

    INSERT grac_practice.organization_framework_statements(
        organization_id, release_id, framework_statement_id,
        applicability_status_id, status_id, status, entered_by)
    SELECT @organization_id, @release_id, src.framework_statement_id,
           @not_updated_status_id, @active_status_id, N'Active', @actor
    FROM grac_practice.vw_repo_src_framework_statement src
    WHERE src.release_id = @release_id
      AND src.status = N'Active'
      AND (@framework_statement_id IS NULL OR src.framework_statement_id = @framework_statement_id)
      AND NOT EXISTS (
          SELECT 1 FROM grac_practice.organization_framework_statements x
          WHERE x.organization_id = @organization_id
            AND x.release_id = @release_id
            AND x.framework_statement_id = src.framework_statement_id);
    SET @inserted = @@ROWCOUNT;

    UPDATE ofs
    SET statement_reference   = src.statement_reference,
        statement_title       = src.statement_title,
        statement_text        = src.statement_text,
        display_order         = src.display_order,
        structure_node_id     = src.structure_node_id,
        org_structure_node_id = node.org_structure_node_id,
        source_version_hash   = src.content_hash,
        copied_dt             = SYSUTCDATETIME(),
        copied_by             = @actor
    FROM grac_practice.organization_framework_statements ofs
    JOIN grac_practice.vw_repo_src_framework_statement src
      ON src.framework_statement_id = ofs.framework_statement_id
    LEFT JOIN grac_practice.organization_statement_structure_node node
      ON node.organization_id = ofs.organization_id
     AND node.structure_node_id = src.structure_node_id
    WHERE ofs.organization_id = @organization_id
      AND ofs.release_id = @release_id
      AND ofs.source_type = N'Repository'
      AND (@framework_statement_id IS NULL OR ofs.framework_statement_id = @framework_statement_id)
      AND (ofs.copied_dt IS NULL
           OR @framework_statement_id IS NOT NULL
           OR (@refresh = 1
               AND (ofs.source_version_hash IS NULL
                    OR ofs.source_version_hash <> src.content_hash
                    OR ofs.org_structure_node_id IS NULL)));
    SET @updated = @@ROWCOUNT;
END
GO

-- =====================================================================
-- 5. sp_repo_change_detect_step -- one copy step for one organization
-- =====================================================================
--   @release_id set  : Added and Changed items of that release (scope).
--   @release_id NULL : Retired items (copy row whose source is gone or
--                      no longer Active) -- run once per organization.
-- A difference already Pending / Approved / Rejected for the same
-- (organization, step, key, action, hash) is never raised twice.
CREATE OR ALTER PROCEDURE grac_practice.sp_repo_change_detect_step
    @copy_code       NVARCHAR(40),
    @organization_id BIGINT,
    @release_id      BIGINT,
    @run_id          UNIQUEIDENTIFIER,
    @actor           NVARCHAR(100) = N'system',
    @raised          INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @raised = 0;

    DECLARE @view SYSNAME, @target SYSNAME, @pk SYSNAME, @key SYSNAME, @scope NVARCHAR(MAX),
            @label NVARCHAR(MAX), @generic BIT;
    SELECT @view = source_view, @target = target_table, @pk = org_pk_column, @key = key_column,
           @scope = scope_sql, @label = ISNULL(label_sql, N'CAST(NULL AS NVARCHAR(500))'),
           @generic = is_generic_clone
    FROM grac_practice.repository_copy_config
    WHERE copy_code = @copy_code AND status = N'Active';

    DECLARE @view_q   NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@view);
    DECLARE @target_q NVARCHAR(300) = N'grac_practice.' + QUOTENAME(@target);
    -- Steps without a source view (PracticeImport) have nothing to detect.
    IF @view IS NULL OR OBJECT_ID(@view_q, 'V') IS NULL OR OBJECT_ID(@target_q, 'U') IS NULL RETURN;

    DECLARE @key_q NVARCHAR(300) = QUOTENAME(@key);
    DECLARE @pk_q  NVARCHAR(300) = QUOTENAME(@pk);
    -- organization_framework_statements holds custom rows and one row per
    -- release; everything else is one row per (organization, key).
    DECLARE @target_filter NVARCHAR(400) =
        CASE WHEN @copy_code = N'Statement'
             THEN N' AND t.source_type = N''Repository'' AND t.copied_dt IS NOT NULL'
             ELSE N'' END;
    DECLARE @release_match NVARCHAR(200) =
        CASE WHEN @copy_code = N'Statement' THEN N' AND t.release_id = @release_id' ELSE N'' END;
    DECLARE @retired_release NVARCHAR(100) =
        CASE WHEN COL_LENGTH(@target_q, 'release_id') IS NOT NULL THEN N't.release_id' ELSE N'NULL' END;

    DECLARE @params NVARCHAR(400) =
        N'@organization_id BIGINT, @release_id BIGINT, @copy_code NVARCHAR(40), @run_id UNIQUEIDENTIFIER, @actor NVARCHAR(100), @n INT OUTPUT';
    DECLARE @sql NVARCHAR(MAX), @n INT;

    DECLARE @already NVARCHAR(MAX) = N'
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_repository_change c
                  WHERE c.organization_id = @organization_id
                    AND c.copy_code = @copy_code
                    AND c.source_key = {key}
                    AND c.change_action = N''{action}''
                    AND c.status IN (N''Pending'', N''Approved'', N''Rejected'')
                    AND ISNULL(c.new_version_hash, 0x) = ISNULL({hash}, 0x))';

    IF @release_id IS NOT NULL
    BEGIN
        -- Added: an Active source row of this release the organization has no copy of.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Added'', @copy_code + N''Added'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       NULL,
       (SELECT s2.* FROM ' + @view_q + N' s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM ' + @view_q + N' src
WHERE (' + @scope + N')
  AND src.status = N''Active''
  AND NOT EXISTS (SELECT 1 FROM ' + @target_q + N' t
                  WHERE t.organization_id = @organization_id
                    AND t.' + @key_q + N' = src.' + @key_q + @target_filter + @release_match + N')'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N'src.' + @key_q), N'{action}', N'Added'), N'{hash}', N'src.content_hash') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);

        -- Changed: a copy whose source (still Active, still in this
        -- release) now hashes differently.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, @release_id, @copy_code, N''Changed'', @copy_code + N''Changed'', src.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N'src') + N', 500),
       (SELECT t2.* FROM ' + @target_q + N' t2 WHERE t2.' + @pk_q + N' = t.' + @pk_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       (SELECT s2.* FROM ' + @view_q + N' s2 WHERE s2.' + @key_q + N' = src.' + @key_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       src.content_hash, N''Pending'', @run_id, @actor
FROM ' + @target_q + N' t
JOIN ' + @view_q + N' src ON src.' + @key_q + N' = t.' + @key_q + N'
WHERE t.organization_id = @organization_id' + @target_filter + @release_match + N'
  AND (' + @scope + N')
  AND src.status = N''Active''
  AND t.lifecycle_status = N''Active''
  AND t.source_version_hash IS NOT NULL
  AND src.content_hash IS NOT NULL
  AND t.source_version_hash <> src.content_hash'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N'src.' + @key_q), N'{action}', N'Changed'), N'{hash}', N'src.content_hash') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);
    END
    ELSE
    BEGIN
        -- Retired: a copy row whose source no longer exists as Active.
        SET @sql = N'INSERT grac_practice.organization_repository_change(
    organization_id, release_id, copy_code, change_action, change_type, source_key, source_label,
    old_snapshot_json, new_snapshot_json, new_version_hash, status, detection_run_id, entered_by)
SELECT @organization_id, ' + @retired_release + N', @copy_code, N''Retired'', @copy_code + N''Retired'', t.' + @key_q + N',
       LEFT(' + REPLACE(@label, N'{a}', N't') + N', 500),
       (SELECT t2.* FROM ' + @target_q + N' t2 WHERE t2.' + @pk_q + N' = t.' + @pk_q + N'
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
       NULL, NULL, N''Pending'', @run_id, @actor
FROM ' + @target_q + N' t
WHERE t.organization_id = @organization_id' + @target_filter + N'
  AND t.lifecycle_status = N''Active''
  AND NOT EXISTS (SELECT 1 FROM ' + @view_q + N' src
                  WHERE src.' + @key_q + N' = t.' + @key_q + N'
                    AND src.status = N''Active'')'
  + REPLACE(REPLACE(REPLACE(@already, N'{key}', N't.' + @key_q), N'{action}', N'Retired'), N'{hash}', N'CAST(NULL AS VARBINARY(32))') + N';
SET @n = @@ROWCOUNT;';
        SET @n = 0;
        EXEC sp_executesql @sql, @params, @organization_id = @organization_id, @release_id = @release_id,
             @copy_code = @copy_code, @run_id = @run_id, @actor = @actor, @n = @n OUTPUT;
        SET @raised = @raised + ISNULL(@n, 0);
    END
END
GO

-- =====================================================================
-- 6. sp_repository_change_detect -- every organization, then notify
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_detect
    @organization_id BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'change-detect',
    @raised_count    INT           = NULL OUTPUT,
    @notified_count  INT           = NULL OUTPUT,
    @suppress_result BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @raised_count = 0;
    SET @notified_count = 0;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'change-detect');

    DECLARE @run_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @org BIGINT, @rid BIGINT, @code NVARCHAR(40), @n INT;

    DECLARE @orgs TABLE(organization_id BIGINT PRIMARY KEY);
    INSERT @orgs(organization_id)
    SELECT DISTINCT s.organization_id
    FROM grac_practice.repository_subscription s
    JOIN grac_new.release r ON r.release_id = s.release_id
    WHERE s.status = 'Active'
      AND ISNULL(s.subscription_status, 'Active') = 'Active'
      AND (@organization_id IS NULL OR s.organization_id = @organization_id);

    DECLARE org_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT organization_id FROM @orgs ORDER BY organization_id;
    OPEN org_cursor;
    FETCH NEXT FROM org_cursor INTO @org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Added / Changed, per subscribed release.
        DECLARE rel_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT s.release_id
            FROM grac_practice.repository_subscription s
            JOIN grac_new.release r ON r.release_id = s.release_id
            WHERE s.organization_id = @org
              AND s.status = 'Active'
              AND ISNULL(s.subscription_status, 'Active') = 'Active';
        OPEN rel_cursor;
        FETCH NEXT FROM rel_cursor INTO @rid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT copy_code FROM grac_practice.repository_copy_config
                WHERE status = N'Active' ORDER BY copy_order;
            OPEN step_cursor;
            FETCH NEXT FROM step_cursor INTO @code;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC grac_practice.sp_repo_change_detect_step
                     @copy_code = @code, @organization_id = @org, @release_id = @rid,
                     @run_id = @run_id, @actor = @actor, @raised = @n OUTPUT;
                SET @raised_count = @raised_count + ISNULL(@n, 0);
                FETCH NEXT FROM step_cursor INTO @code;
            END
            CLOSE step_cursor;
            DEALLOCATE step_cursor;
            FETCH NEXT FROM rel_cursor INTO @rid;
        END
        CLOSE rel_cursor;
        DEALLOCATE rel_cursor;

        -- Retired, once per organization.
        DECLARE ret_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT copy_code FROM grac_practice.repository_copy_config
            WHERE status = N'Active' ORDER BY copy_order;
        OPEN ret_cursor;
        FETCH NEXT FROM ret_cursor INTO @code;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC grac_practice.sp_repo_change_detect_step
                 @copy_code = @code, @organization_id = @org, @release_id = NULL,
                 @run_id = @run_id, @actor = @actor, @raised = @n OUTPUT;
            SET @raised_count = @raised_count + ISNULL(@n, 0);
            FETCH NEXT FROM ret_cursor INTO @code;
        END
        CLOSE ret_cursor;
        DEALLOCATE ret_cursor;

        FETCH NEXT FROM org_cursor INTO @org;
    END
    CLOSE org_cursor;
    DEALLOCATE org_cursor;

    -- A newer pending difference on the same item replaces the older one.
    UPDATE older
       SET status = N'Superseded'
    FROM grac_practice.organization_repository_change older
    WHERE older.status = N'Pending'
      AND EXISTS (SELECT 1 FROM grac_practice.organization_repository_change newer
                  WHERE newer.organization_id = older.organization_id
                    AND newer.copy_code = older.copy_code
                    AND newer.source_key = older.source_key
                    AND newer.status = N'Pending'
                    AND newer.change_id > older.change_id);

    -- Notify: one row per recipient and release that this run raised
    -- pending changes for. Recipients = the release owner(s) and every
    -- organization admin (role data_scope ORGANIZATION / GLOBAL -- the rule
    -- PracticeAuthenticationService applies at sign-in).
    IF @raised_count > 0
    BEGIN
        ;WITH run_releases AS (
            SELECT DISTINCT c.organization_id, c.release_id
            FROM grac_practice.organization_repository_change c
            WHERE c.detection_run_id = @run_id AND c.status = N'Pending'
        ),
        admins AS (
            SELECT DISTINCT e.organization_id, e.employee_id
            FROM grac_practice.organization_employee e
            LEFT JOIN grac_practice.organization_role r0 ON r0.role_id = e.role_id
            WHERE e.status = 'Active'
              AND (ISNULL(r0.data_scope, N'') IN (N'ORGANIZATION', N'GLOBAL')
                   OR EXISTS (SELECT 1
                              FROM grac_practice.organization_employee_role er
                              JOIN grac_practice.organization_role r1 ON r1.role_id = er.role_id
                              WHERE er.employee_id = e.employee_id
                                AND er.status = 'Active'
                                AND r1.data_scope IN (N'ORGANIZATION', N'GLOBAL')))
        ),
        recipients AS (
            SELECT rr.organization_id, rr.release_id, s.owner_id AS employee_id, N'ReleaseOwner' AS reason, 1 AS priority
            FROM run_releases rr
            JOIN grac_practice.repository_subscription s
              ON s.organization_id = rr.organization_id
             AND s.status = 'Active'
             AND ISNULL(s.subscription_status, 'Active') = 'Active'
             AND (rr.release_id IS NULL OR s.release_id = rr.release_id)
            JOIN grac_practice.organization_employee oe
              ON oe.employee_id = s.owner_id AND oe.organization_id = rr.organization_id AND oe.status = 'Active'
            WHERE s.owner_id IS NOT NULL
            UNION ALL
            SELECT rr.organization_id, rr.release_id, a.employee_id, N'OrgAdmin', 2
            FROM run_releases rr
            JOIN admins a ON a.organization_id = rr.organization_id
        ),
        ranked AS (
            SELECT organization_id, release_id, employee_id, reason,
                   ROW_NUMBER() OVER (PARTITION BY organization_id, release_id, employee_id ORDER BY priority) AS rn
            FROM recipients
        )
        SELECT organization_id, release_id, employee_id, reason
        INTO #recipients
        FROM ranked
        WHERE rn = 1;

        -- An unread notice for the same organization / release / person is
        -- replaced by this run's, so Home shows one line with the current count.
        UPDATE n
           SET status = N'Superseded'
        FROM grac_practice.organization_repository_change_notification n
        JOIN #recipients r
          ON r.organization_id = n.organization_id
         AND ISNULL(r.release_id, -1) = ISNULL(n.release_id, -1)
         AND r.employee_id = n.recipient_employee_id
        WHERE n.status = N'Unread';

        INSERT grac_practice.organization_repository_change_notification(
            organization_id, release_id, detection_run_id, recipient_employee_id, recipient_reason, pending_count, status)
        SELECT r.organization_id, r.release_id, @run_id, r.employee_id, r.reason,
               (SELECT COUNT(*) FROM grac_practice.organization_repository_change c
                 WHERE c.organization_id = r.organization_id
                   AND ISNULL(c.release_id, -1) = ISNULL(r.release_id, -1)
                   AND c.status = N'Pending'),
               N'Unread'
        FROM #recipients r;
        SET @notified_count = @@ROWCOUNT;

        DROP TABLE #recipients;
    END

    IF ISNULL(@suppress_result, 0) = 0
        SELECT @run_id AS DetectionRunId, @raised_count AS RaisedCount, @notified_count AS NotifiedCount;
END
GO

-- =====================================================================
-- 7. sp_repository_change_apply -- approve / reject one change
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_apply
    @change_id         BIGINT,
    @decision          NVARCHAR(20),          -- Approve / Reject
    @actor_employee_id BIGINT        = NULL,
    @is_admin          BIT           = 0,
    @remark            NVARCHAR(1000) = NULL,
    @actor             NVARCHAR(100) = N'system',
    @suppress_result   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');
    SET @remark = NULLIF(LTRIM(RTRIM(@remark)), N'');
    SET @decision = LTRIM(RTRIM(ISNULL(@decision, N'')));

    DECLARE @org BIGINT, @rid BIGINT, @code NVARCHAR(40), @action NVARCHAR(20), @key BIGINT,
            @status NVARCHAR(20), @old NVARCHAR(MAX), @new NVARCHAR(MAX);
    SELECT @org = organization_id, @rid = release_id, @code = copy_code, @action = change_action,
           @key = source_key, @status = status, @old = old_snapshot_json, @new = new_snapshot_json
    FROM grac_practice.organization_repository_change
    WHERE change_id = @change_id;

    IF @org IS NULL
        THROW 53920, 'Repository change not found.', 1;
    IF @status <> N'Pending'
        THROW 53921, 'This repository change has already been decided.', 1;
    IF @decision NOT IN (N'Approve', N'Reject')
        THROW 53925, 'Decision must be Approve or Reject.', 1;
    IF ISNULL(@is_admin, 0) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                       WHERE s.organization_id = @org
                         AND s.status = 'Active'
                         AND ISNULL(s.subscription_status, 'Active') = 'Active'
                         AND s.owner_id = @actor_employee_id
                         AND (@rid IS NULL OR s.release_id = @rid))
        THROW 53922, 'Only the release owner or an organization admin can decide repository changes.', 1;
    IF @decision = N'Reject' AND @remark IS NULL
        THROW 53923, 'A remark is required to reject a repository change.', 1;

    DECLARE @target SYSNAME, @key_col SYSNAME, @generic BIT;
    SELECT @target = target_table, @key_col = key_column, @generic = is_generic_clone
    FROM grac_practice.repository_copy_config
    WHERE copy_code = @code;

    DECLARE @ins INT, @upd INT, @sql NVARCHAR(MAX), @ev BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @decision = N'Approve'
        BEGIN
            IF @action IN (N'Added', N'Changed')
            BEGIN
                IF @code = N'Statement'
                    EXEC grac_practice.sp_repository_copy_statements
                         @organization_id = @org, @release_id = @rid, @refresh = 1, @actor = @actor,
                         @inserted = @ins OUTPUT, @updated = @upd OUTPUT, @framework_statement_id = @key;
                ELSE IF @generic = 1
                    EXEC grac_practice.sp_repo_clone_sync
                         @copy_code = @code, @organization_id = @org, @release_id = @rid, @refresh = 1,
                         @actor = @actor, @key_value = @key, @inserted = @ins OUTPUT, @updated = @upd OUTPUT;

                -- Added must have produced a copy; if the source is no
                -- longer Active the item is stale -- detection will raise
                -- what is true now.
                IF @action = N'Added'
                BEGIN
                    SET @ins = 0;
                    SET @sql = N'SELECT @n = COUNT(*) FROM grac_practice.' + QUOTENAME(@target)
                             + N' t WHERE t.organization_id = @o AND t.' + QUOTENAME(@key_col) + N' = @k'
                             + CASE WHEN @code = N'Statement' THEN N' AND t.release_id = @r' ELSE N'' END + N';';
                    EXEC sp_executesql @sql, N'@o BIGINT, @k BIGINT, @r BIGINT, @n INT OUTPUT',
                         @o = @org, @k = @key, @r = @rid, @n = @ins OUTPUT;
                    IF ISNULL(@ins, 0) = 0
                        THROW 53924, 'The repository item is no longer available. It will be re-evaluated at the next detection run.', 1;
                END

                -- A requirement edit reaches the organization's practice.
                IF @code = N'Requirement' AND @action = N'Changed'
                    UPDATE q
                       SET requirement_code      = rr.requirement_code,
                           requirement_name      = rr.requirement_name,
                           requirement_statement = rr.requirement_statement,
                           objective             = rr.objective,
                           updated_by            = @actor,
                           updated_dt            = SYSUTCDATETIME()
                    FROM grac_practice.organization_requirement q
                    JOIN grac_practice.organization_repository_requirement rr
                      ON rr.organization_id = q.organization_id
                     AND rr.requirement_id  = q.repository_requirement_id
                    WHERE q.organization_id = @org
                      AND q.repository_requirement_id = @key;

                -- An obligation brings the evidence its copied EvidenceJson
                -- lists, and adopted instances follow its name unless the
                -- organization edited them.
                IF @code = N'Obligation'
                BEGIN
                    DECLARE ev_cursor CURSOR LOCAL FAST_FORWARD FOR
                        SELECT DISTINCT j.ObligationEvidenceId
                        FROM grac_practice.organization_obligation oo
                        CROSS APPLY OPENJSON(oo.evidence_json)
                             WITH (ObligationEvidenceId BIGINT '$.ObligationEvidenceId') j
                        WHERE oo.organization_id = @org AND oo.obligation_id = @key
                          AND j.ObligationEvidenceId IS NOT NULL;
                    OPEN ev_cursor;
                    FETCH NEXT FROM ev_cursor INTO @ev;
                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        EXEC grac_practice.sp_repo_clone_sync
                             @copy_code = N'ObligationEvidence', @organization_id = @org, @release_id = @rid,
                             @refresh = 1, @actor = @actor, @key_value = @ev;
                        FETCH NEXT FROM ev_cursor INTO @ev;
                    END
                    CLOSE ev_cursor;
                    DEALLOCATE ev_cursor;

                    UPDATE pio
                       SET obligation_name = LEFT(COALESCE(NULLIF(LTRIM(RTRIM(oo.obligation_name)), N''),
                                                           oo.obligation_text), 500),
                           updated_by = @actor,
                           updated_dt = SYSUTCDATETIME()
                    FROM grac_practice.practice_instance_obligation pio
                    JOIN grac_practice.organization_obligation oo
                      ON oo.organization_id = pio.organization_id
                     AND oo.obligation_id   = pio.obligation_id
                    WHERE pio.organization_id = @org
                      AND pio.obligation_id   = @key
                      AND pio.organization_modified = 0;
                END
            END
            ELSE IF @action = N'Retired'
            BEGIN
                -- Flag only (decision 4).
                SET @sql = N'UPDATE t SET lifecycle_status = N''Retired'' FROM grac_practice.' + QUOTENAME(@target)
                         + N' t WHERE t.organization_id = @o AND t.' + QUOTENAME(@key_col) + N' = @k'
                         + CASE WHEN @code = N'Statement' THEN N' AND t.source_type = N''Repository''' ELSE N'' END
                         + N';';
                EXEC sp_executesql @sql, N'@o BIGINT, @k BIGINT', @o = @org, @k = @key;
            END

            -- Statement, link or requirement approved for a release: link
            -- practices from whatever of the three is now approved.
            IF @rid IS NOT NULL AND @code IN (N'Statement', N'StatementRequirementMap', N'Requirement')
               AND @action IN (N'Added', N'Changed')
                EXEC grac_practice.sp_repository_practice_import
                     @organization_id = @org, @release_id = @rid, @refresh = 0, @actor = @actor;
        END

        UPDATE grac_practice.organization_repository_change
           SET status                 = CASE WHEN @decision = N'Approve' THEN N'Approved' ELSE N'Rejected' END,
               decided_by_employee_id = @actor_employee_id,
               decided_by             = @actor,
               decided_dt             = SYSUTCDATETIME(),
               decision_remark        = @remark
         WHERE change_id = @change_id;

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'repository-change', @change_id,
                CASE WHEN @decision = N'Approve' THEN N'APPROVE' ELSE N'REJECT' END,
                @old,
                (SELECT @code AS copyCode, @action AS changeAction, @key AS sourceKey, @org AS organizationId,
                        @rid AS releaseId, @remark AS remark, @new AS newSnapshotJson
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                'Active', @actor);

        -- Nothing pending left for this organization / release: the notice
        -- has done its job.
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_repository_change c
                       WHERE c.organization_id = @org
                         AND ISNULL(c.release_id, -1) = ISNULL(@rid, -1)
                         AND c.status = N'Pending')
            UPDATE grac_practice.organization_repository_change_notification
               SET status = N'Cleared'
             WHERE organization_id = @org
               AND ISNULL(release_id, -1) = ISNULL(@rid, -1)
               AND status IN (N'Unread', N'Read');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    IF ISNULL(@suppress_result, 0) = 0
        SELECT CAST(1 AS BIT) AS Success,
               CASE WHEN @decision = N'Approve' THEN N'Approved' ELSE N'Rejected' END AS Message,
               @change_id AS ChangeId;
END
GO

-- =====================================================================
-- 8. Read procedures
-- =====================================================================
-- 8a. Review page list. @release_id NULL = every release (and shared
-- items); @status NULL = every status.
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_list
    @organization_id BIGINT,
    @release_id      BIGINT        = NULL,
    @status          NVARCHAR(20)  = N'Pending',
    @page_number     INT           = 1,
    @page_size       INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53926, 'organizationId is required.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 50) < 1 THEN 50 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SET @status      = NULLIF(LTRIM(RTRIM(@status)), N'');

    SELECT c.change_id              AS ChangeId,
           c.organization_id        AS OrganizationId,
           c.release_id             AS ReleaseId,
           COALESCE(a.artifact_code + N' ' + r.version_no, a.artifact_name + N' ' + r.version_no,
                    r.version_no, N'Shared by releases') AS FrameworkRelease,
           c.copy_code              AS CopyCode,
           cfg.copy_order           AS CopyOrder,
           c.change_action          AS ChangeAction,
           c.change_type            AS ChangeType,
           c.source_key             AS SourceKey,
           c.source_label           AS SourceLabel,
           c.old_snapshot_json      AS OldSnapshotJson,
           c.new_snapshot_json      AS NewSnapshotJson,
           c.status                 AS Status,
           c.detected_dt            AS DetectedDate,
           c.decided_by             AS DecidedBy,
           COALESCE(de.employee_name, c.decided_by) AS DecidedByName,
           c.decided_dt             AS DecidedDate,
           c.decision_remark        AS DecisionRemark,
           COUNT(*) OVER ()         AS TotalRows
    FROM grac_practice.organization_repository_change c
    LEFT JOIN grac_practice.repository_copy_config cfg ON cfg.copy_code = c.copy_code
    LEFT JOIN grac_new.release r ON r.release_id = c.release_id
    LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
    LEFT JOIN grac_practice.organization_employee de ON de.employee_id = c.decided_by_employee_id
    WHERE c.organization_id = @organization_id
      AND (@release_id IS NULL OR c.release_id = @release_id OR c.release_id IS NULL)
      AND (@status IS NULL OR c.status = @status)
    ORDER BY CASE WHEN c.status = N'Pending' THEN 0 ELSE 1 END,
             c.release_id, cfg.copy_order, c.change_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 8b. Pending count per release (Standards & Frameworks badge).
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.release_id AS ReleaseId, COUNT(*) AS PendingCount
    FROM grac_practice.organization_repository_change c
    WHERE c.organization_id = @organization_id
      AND c.status = N'Pending'
    GROUP BY c.release_id;
END
GO

-- 8c. Home: one recipient's open notices, with the CURRENT pending count.
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_notification_list
    @recipient_employee_id BIGINT,
    @organization_id       BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT n.notification_id  AS NotificationId,
           n.organization_id  AS OrganizationId,
           n.release_id       AS ReleaseId,
           COALESCE(a.artifact_code + N' ' + r.version_no, a.artifact_name + N' ' + r.version_no,
                    r.version_no, N'Shared by releases') AS FrameworkRelease,
           n.recipient_reason AS RecipientReason,
           (SELECT COUNT(*) FROM grac_practice.organization_repository_change c
             WHERE c.organization_id = n.organization_id
               AND ISNULL(c.release_id, -1) = ISNULL(n.release_id, -1)
               AND c.status = N'Pending') AS PendingCount,
           n.status           AS Status,
           n.created_dt       AS CreatedDate
    FROM grac_practice.organization_repository_change_notification n
    LEFT JOIN grac_new.release r ON r.release_id = n.release_id
    LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
    WHERE n.recipient_employee_id = @recipient_employee_id
      AND (@organization_id IS NULL OR n.organization_id = @organization_id)
      AND n.status IN (N'Unread', N'Read')
    ORDER BY CASE WHEN n.status = N'Unread' THEN 0 ELSE 1 END, n.created_dt DESC;
END
GO

-- 8d. Opening the review page marks the caller's notices for that
-- organization read (they stay on Home until the changes are decided).
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_change_notification_mark_read
    @recipient_employee_id BIGINT,
    @organization_id       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE grac_practice.organization_repository_change_notification
       SET status = N'Read', read_dt = SYSUTCDATETIME()
     WHERE recipient_employee_id = @recipient_employee_id
       AND organization_id = @organization_id
       AND status = N'Unread';
    SELECT @@ROWCOUNT AS MarkedCount;
END
GO

-- =====================================================================
-- 9. Verification
-- =====================================================================
-- 9a. Every copy step has a label; PracticeImport has none (no source).
SELECT copy_code, copy_order, is_generic_clone, handler_proc,
       CASE WHEN label_sql IS NULL THEN N'(none)' ELSE N'set' END AS label
FROM grac_practice.repository_copy_config
ORDER BY copy_order;

-- 9b. First detection run. With nothing changed in grac_new since the
-- backfill this raises 0. (It is safe to run at any time.)
EXEC grac_practice.sp_repository_change_detect @organization_id = NULL, @actor = N'migration-395';
GO

PRINT '395 complete.';
GO
