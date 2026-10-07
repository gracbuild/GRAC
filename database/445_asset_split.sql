-- =====================================================================
-- 445  Asset split: source and resulting records, allocation of current
--      relationships, source records, open items, coverage, risk and
--      practice mappings and field values, impact, validation, approval
--      (two-person for critical CIs), execution with per-object outcomes,
--      recovery (Asset & Contract Management, Phase 7 increment 4c)
--
-- REQUEST
-- -------
--   BRD v1.7 5.6.3 Split -- "create controlled records and redistribute
--   observations / relationships with approval". 19.4 split control:
--   initiation (source and proposed resulting records), preview (proposed
--   allocation of data, evidence, history and relationships), impact
--   analysis (same domains for each resulting record), validation (each
--   result meets identity and mandatory rules), approval (configured
--   approver; two-person control for critical CIs), execution (controlled
--   redistribution with per-object outcomes), recovery (controlled
--   recombine / correction event), audit (before / after IDs, allocation,
--   actor, reason, approval). Plan: docs/asset-contract-management.md
--   (Phase 7.4c, D125-D131).
--
-- WHAT THIS DOES
-- --------------
--   1. Split events reuse the 444 event tables (kind SPLIT; the source is
--      the survivor_asset_id of the event, the resulting records are members
--      with role RESULT) and add asset_split_allocation: which object goes
--      to which resulting record (field values: move or copy).
--   2. Resulting records are Draft assets registered on the Asset Register
--      form first, so each one has passed the identity and mandatory
--      rules; the source keeps its ID and whatever is not allocated.
--   3. fn_asset_split_plan: every object of the source (the 444 merge plan
--      read for the source) with its allocation and what moving it to that
--      resulting record would do now (MOVE, BLOCK, or STAY when the result
--      already holds the equivalent); fn_asset_split_blockers.
--   4. sp_asset_merge_split_move: the object moves of 444 taken out of
--      sp_asset_merge_execute_one unchanged so merge and split share them;
--      sp_asset_merge_execute_one is re-issued to call it.
--   5. sp_asset_split_save / sp_asset_split_execute / readers; the 444
--      action procedure is re-issued for both kinds (same approval rules),
--      the 444 list takes the kind, and recovery restores values a split
--      cleared on the source.
--
-- NOT DONE HERE: allocation of history rows (lifecycle, custody,
--   attestations, results, renewals, notifications stay with the source);
--   creating the resulting records inside the split; bulk splits.
--
-- ERROR NUMBERS: 52900-52914 (444) and 52915-52919
--   52915 1-5 resulting records          52916 result must be a new Draft
--   52917 allocation invalid             (52900-52914 as in 444)
--
-- ALSO EDITED: sp_asset_merge_execute_one, sp_asset_merge_action,
--   sp_asset_merge_recover, sp_asset_merge_events (444) re-issued; API
--   (AssetConfig service / controller / models), Web proxy,
--   asset-discovery.cshtml / .js (Splits tab), docs.
-- DEPENDS ON: 444.
-- Rollback: 445_asset_split_rollback.sql (restores the four 444 bodies).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_merge_split_event','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_merge_split_object','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_merge_plan') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_merge_critical') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_merge_impact') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_merge_execute_one','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_merge_action','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_merge_recover','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_merge_events','P') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NULL
BEGIN
    RAISERROR('ABORT (445): run 444 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Allocation of the source objects to the resulting records
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_split_allocation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_split_allocation (
        allocation_id   BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asplit_alloc PRIMARY KEY,
        event_id        BIGINT        NOT NULL CONSTRAINT fk_pm_asplit_alloc_event REFERENCES grac_practice.asset_merge_split_event(event_id),
        object_kind     NVARCHAR(20)  NOT NULL,
        object_id       BIGINT        NULL,
        object_key      NVARCHAR(200) NULL,
        target_asset_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_asplit_alloc_target REFERENCES grac_practice.organization_dependency_asset(asset_id),
        field_mode      NVARCHAR(4)   NULL
            CONSTRAINT ck_pm_asplit_alloc_mode CHECK (field_mode IS NULL OR field_mode IN (N'MOVE', N'COPY'))
    );
    CREATE UNIQUE INDEX ux_pm_asplit_alloc ON grac_practice.asset_split_allocation(event_id, object_kind, object_id, object_key);
    PRINT '445: asset_split_allocation created.';
END
GO

-- =====================================================================
-- 2. Object moves shared by merge and split (D126). The statements are the
--    444 ones of sp_asset_merge_execute_one, with @duplicate -> @from_asset,
--    @survivor -> @to_asset, @survivor_name -> @to_name and the plan in the
--    caller-created #msplan (object_kind, object_id, object_key,
--    object_label, outcome MOVE / END / RESOLVE / KEEP, detail).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_split_move
    @organization_id   BIGINT,
    @event_id          BIGINT,
    @from_asset        BIGINT,
    @to_asset          BIGINT,
    @note              NVARCHAR(400),
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @to_name NVARCHAR(300) = (SELECT asset_name FROM grac_practice.organization_dependency_asset WHERE asset_id = @to_asset);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- ---------------------------------------------------------- relationships
    DECLARE @rid BIGINT, @rout NVARCHAR(10);
    DECLARE rel_cur CURSOR LOCAL STATIC FOR
        SELECT object_id, outcome FROM #msplan WHERE object_kind = N'RELATIONSHIP' ORDER BY object_id;
    OPEN rel_cur;
    FETCH NEXT FROM rel_cur INTO @rid, @rout;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rout = N'MOVE'
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @from_asset, @to_asset, N'MOVED',
                   (SELECT r.source_id AS sourceId, r.target_id AS targetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   (SELECT CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @from_asset THEN @to_asset ELSE r.source_id END AS sourceId,
                           CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @from_asset THEN @to_asset ELSE r.target_id END AS targetId
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
              FROM grac_practice.asset_relationship r JOIN #msplan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
             WHERE r.relationship_id = @rid;
            UPDATE grac_practice.asset_relationship
               SET source_id = CASE WHEN source_kind = N'ASSET' AND source_id = @from_asset THEN @to_asset ELSE source_id END,
                   target_id = CASE WHEN target_kind = N'ASSET' AND target_id = @from_asset THEN @to_asset ELSE target_id END,
                   version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @rid;
            EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'MERGE_MOVE', @note = @note,
                 @actor = @actor, @actor_employee_id = @actor_employee_id;
        END
        ELSE
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @from_asset, @to_asset, N'ENDED',
                   (SELECT r.status AS status, r.effective_to AS effectiveTo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   N'{"status":"RETIRED"}', p.detail
              FROM grac_practice.asset_relationship r JOIN #msplan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
             WHERE r.relationship_id = @rid;
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', effective_to = CASE WHEN @today < effective_from THEN effective_from ELSE @today END,
                   status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @rid;
            EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'MERGE_END', @note = @note,
                 @actor = @actor, @actor_employee_id = @actor_employee_id;
        END
        FETCH NEXT FROM rel_cur INTO @rid, @rout;
    END
    CLOSE rel_cur;
    DEALLOCATE rel_cur;

    -- ---------------------------------------------------------- discovery links and per-source values
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'DISCOVERY_LINK', p.object_id, p.object_key, p.object_label, @from_asset, @to_asset, N'MOVED', p.detail
      FROM #msplan p WHERE p.object_kind = N'DISCOVERY_LINK';
    UPDATE l SET asset_id = @to_asset
      FROM grac_practice.asset_discovery_link l JOIN #msplan p ON p.object_kind = N'DISCOVERY_LINK' AND p.object_id = l.link_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'ATTRIBUTE_SOURCE', p.object_id, p.object_key, p.object_label, @from_asset, @to_asset,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM #msplan p WHERE p.object_kind = N'ATTRIBUTE_SOURCE';
    UPDATE x SET asset_id = @to_asset
      FROM grac_practice.asset_attribute_source x
      JOIN #msplan p ON p.object_kind = N'ATTRIBUTE_SOURCE' AND p.outcome = N'MOVE' AND p.object_id = x.source_id AND p.object_key = x.field_key
     WHERE x.asset_id = @from_asset;

    -- ---------------------------------------------------------- open reconciliation exceptions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, detail)
    SELECT @event_id, N'RECON_EXCEPTION', e.exception_id, p.object_label, @from_asset, @to_asset,
           CASE p.outcome WHEN N'RESOLVE' THEN N'RESOLVED' ELSE N'MOVED' END,
           (SELECT e.asset_id AS assetId, e.other_asset_id AS otherAssetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
      FROM grac_practice.asset_reconciliation_exception e JOIN #msplan p ON p.object_kind = N'RECON_EXCEPTION' AND p.object_id = e.exception_id;
    UPDATE e
       SET status = N'RESOLVED', resolution = N'MERGED', resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN #msplan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'RESOLVE'
                                                                      AND p.object_id = e.exception_id;
    UPDATE e
       SET asset_id = CASE WHEN e.asset_id = @from_asset THEN @to_asset ELSE e.asset_id END,
           other_asset_id = CASE WHEN e.other_asset_id = @from_asset THEN @to_asset ELSE e.other_asset_id END,
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN #msplan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'MOVE'
                                                                      AND p.object_id = e.exception_id;

    -- ---------------------------------------------------------- coverage, occurrences, restrictive reviews
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, p.object_kind, p.object_id, p.object_key, p.object_label, @from_asset, @to_asset,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM #msplan p WHERE p.object_kind IN (N'COVERAGE', N'OCCURRENCE', N'RESTRICTIVE_REVIEW');
    UPDATE c SET asset_id = @to_asset
      FROM grac_practice.asset_contract_coverage c JOIN #msplan p ON p.object_kind = N'COVERAGE' AND p.outcome = N'MOVE' AND p.object_id = c.coverage_id;
    UPDATE o SET asset_id = @to_asset, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o JOIN #msplan p ON p.object_kind = N'OCCURRENCE' AND p.outcome = N'MOVE' AND p.object_id = o.occurrence_id;
    UPDATE r SET asset_id = @to_asset
      FROM grac_practice.asset_restrictive_review r JOIN #msplan p ON p.object_kind = N'RESTRICTIVE_REVIEW' AND p.outcome = N'MOVE' AND p.object_id = r.review_id;

    -- ---------------------------------------------------------- risks and practice resolutions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'RISK_MAP', m.risk_dependency_map_id, p.object_label, @from_asset, @to_asset,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, m.dependency_object_name,
           CASE p.outcome WHEN N'MOVE' THEN @to_name END, p.detail
      FROM grac_practice.risk_dependency_map m JOIN #msplan p ON p.object_kind = N'RISK_MAP' AND p.object_id = m.risk_dependency_map_id;
    UPDATE m SET dependency_object_id = @to_asset, dependency_object_name = @to_name, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.risk_dependency_map m JOIN #msplan p ON p.object_kind = N'RISK_MAP' AND p.outcome = N'MOVE' AND p.object_id = m.risk_dependency_map_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'RISK_LINK', p.object_id, p.object_label, @from_asset, @to_asset, N'MOVED', p.detail
      FROM #msplan p WHERE p.object_kind = N'RISK_LINK';
    UPDATE r SET linked_asset_id = @to_asset
      FROM grac_practice.risk_register r JOIN #msplan p ON p.object_kind = N'RISK_LINK' AND p.object_id = r.risk_register_id;

    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'PRACTICE_RESOLUTION', d.resolution_id, p.object_label, @from_asset, @to_asset,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, d.resolved_dependency_name,
           CASE p.outcome WHEN N'MOVE' THEN LEFT(@to_name, 300) END, p.detail
      FROM grac_practice.practice_dependency_resolution d JOIN #msplan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.object_id = d.resolution_id;
    UPDATE d SET resolved_dependency_id = @to_asset, resolved_dependency_name = LEFT(@to_name, 300), updated_by = @actor,
                 updated_dt = SYSUTCDATETIME()
      FROM grac_practice.practice_dependency_resolution d JOIN #msplan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.outcome = N'MOVE'
                                                                     AND p.object_id = d.resolution_id;
END
GO

-- sp_asset_merge_execute_one (444) re-issued: the object moves now run in
-- sp_asset_merge_split_move (same statements); plan in #msplan.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_execute_one
    @organization_id    BIGINT,
    @event_id           BIGINT,
    @survivor           BIGINT,
    @duplicate          BIGINT,
    @field_choices_json NVARCHAR(MAX)  = NULL,
    @actor_employee_id  BIGINT         = NULL,
    @actor              NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    CREATE TABLE #msplan (object_kind NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, object_id BIGINT NULL,   -- 445
                          object_key NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL, object_label NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,   -- 445
                          outcome NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, detail NVARCHAR(600) COLLATE DATABASE_DEFAULT NULL);   -- 445
    INSERT #msplan (object_kind, object_id, object_key, object_label, outcome, detail)   -- 445
    SELECT ObjectKind, ObjectId, ObjectKey, ObjectLabel, Outcome, Detail
      FROM grac_practice.fn_asset_merge_plan(@organization_id, @survivor, @duplicate);
    IF EXISTS (SELECT 1 FROM #msplan WHERE outcome = N'BLOCK')   -- 445
       OR EXISTS (SELECT 1 FROM grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, @duplicate))
        THROW 52908, 'The merge has blockers; open it to see them.', 1;
    DECLARE @note NVARCHAR(400) = CONCAT(N'Merge #', @event_id, N': asset #', @duplicate,   -- 445
                                                                                    N' merged into #', @survivor, N'.');

    -- the object moves (relationships ... practice resolutions) are shared with split (D126)   -- 445
    EXEC grac_practice.sp_asset_merge_split_move   -- 445
         @organization_id = @organization_id, @event_id = @event_id, @from_asset = @duplicate, @to_asset = @survivor,   -- 445
         @note = @note, @actor_employee_id = @actor_employee_id, @actor = @actor;   -- 445


    -- ---------------------------------------------------------- field values (D117)
    -- Filled: the survivor has no value and no choice names another duplicate;
    -- replaced: a field choice names this duplicate.
    DECLARE @fv TABLE (field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL, label NVARCHAR(200) NULL,
                       before_text NVARCHAR(MAX) NULL, after_text NVARCHAR(MAX) NOT NULL, outcome NVARCHAR(10) NOT NULL);
    INSERT @fv (field_definition_id, field_key, label, before_text, after_text, outcome)
    SELECT f.field_definition_id, f.field_key, f.display_label, sv.value_text, dv.value_text,
           CASE WHEN sv.asset_id IS NULL THEN N'FILLED' ELSE N'REPLACED' END
      FROM grac_practice.asset_field_value dv
      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = dv.field_definition_id AND f.storage_kind = N'VALUE'
                                                 AND f.is_system_field = 0
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code AND dt.is_user_entered = 1
      LEFT JOIN grac_practice.asset_field_value sv ON sv.asset_id = @survivor AND sv.field_definition_id = dv.field_definition_id
      OUTER APPLY (SELECT TOP 1 TRY_CONVERT(BIGINT, j.[value]) AS chosen FROM OPENJSON(ISNULL(@field_choices_json, N'{}')) j
                    WHERE j.[key] COLLATE DATABASE_DEFAULT = f.field_key) ch
     WHERE dv.asset_id = @duplicate
       AND ((ch.chosen = @duplicate AND ISNULL(sv.value_text, N'') <> dv.value_text)
            OR (ch.chosen IS NULL AND sv.asset_id IS NULL));
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value)
    SELECT @event_id, N'FIELD', field_definition_id, field_key, label, @duplicate, @survivor, outcome, before_text, after_text FROM @fv;
    MERGE grac_practice.asset_field_value AS t
    USING (SELECT dv.field_definition_id, dv.value_text, dv.value_number, dv.value_date, dv.value_ref
             FROM grac_practice.asset_field_value dv JOIN @fv x ON x.field_definition_id = dv.field_definition_id
            WHERE dv.asset_id = @duplicate) AS s
       ON t.asset_id = @survivor AND t.field_definition_id = s.field_definition_id
    WHEN MATCHED THEN UPDATE SET value_text = s.value_text, value_number = s.value_number, value_date = s.value_date, value_ref = s.value_ref,
                                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
                          VALUES (@survivor, s.field_definition_id, s.value_text, s.value_number, s.value_date, s.value_ref, @actor);

    -- ---------------------------------------------------------- aliases (D118)
    DECLARE @al TABLE (alias_id BIGINT NOT NULL, alias_kind NVARCHAR(30) NOT NULL, alias_value NVARCHAR(400) NOT NULL);
    INSERT grac_practice.asset_alias (organization_id, asset_id, alias_kind, alias_value, source_asset_id, event_id, entered_by)
    OUTPUT inserted.alias_id, inserted.alias_kind, inserted.alias_value INTO @al (alias_id, alias_kind, alias_value)
    SELECT @organization_id, @survivor, k.kind, k.val, @duplicate, @event_id, @actor
      FROM (SELECT N'NAME' AS kind, CAST(a.asset_name AS NVARCHAR(400)) AS val
              FROM grac_practice.organization_dependency_asset a WHERE a.asset_id = @duplicate
            UNION ALL
            SELECT N'ASSET_ID', CAST(CONCAT(N'#', @duplicate) AS NVARCHAR(400))
            UNION ALL
            SELECT f.field_key, CAST(LEFT(v.value_text, 400) AS NVARCHAR(400))
              FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
             WHERE v.asset_id = @duplicate
               AND f.field_key IN (N'asset_tag', N'serial_number', N'finance_asset_number', N'hostname', N'mac_address', N'cloud_resource_identifier')) k
     WHERE k.val IS NOT NULL AND LTRIM(RTRIM(k.val)) <> N''
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value sv
                        JOIN grac_practice.asset_field_definition sf ON sf.field_definition_id = sv.field_definition_id
                       WHERE sv.asset_id = @survivor AND sf.field_key = k.kind AND sv.value_text = k.val)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_alias x
                        WHERE x.asset_id = @survivor AND x.alias_kind = k.kind AND x.alias_value = k.val AND x.is_active = 1);
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, after_value)
    SELECT @event_id, N'ALIAS', alias_id, alias_kind, CONCAT(alias_kind, N': ', alias_value), @duplicate, @survivor, N'ALIASED', alias_value FROM @al;

    -- ---------------------------------------------------------- the merged record (D119)
    DECLARE @from NVARCHAR(60), @from_id INT, @rs INT, @st NVARCHAR(30), @legacy NVARCHAR(30), @to_id INT, @log BIGINT;
    SELECT @from = COALESCE(cs.status_code, ls.status_code), @from_id = a.current_status_id, @rs = a.record_status_id, @st = a.status,
           @legacy = a.lifecycle_status
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @duplicate;
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value)
    VALUES (@event_id, N'ASSET_RECORD', @duplicate, CONCAT(N'Asset #', @duplicate), @duplicate, @survivor, N'ARCHIVED',
            (SELECT @from AS statusCode, @st AS status, @rs AS recordStatusId, @legacy AS lifecycleStatus FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'{"statusCode":"ARCHIVED"}');
    DECLARE @reason_text NVARCHAR(1000) = CONCAT(N'Merged into asset #', @survivor, N' (merge #', @event_id, N').');
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'Asset', @entity_id = @duplicate, @from_status_code = @from, @to_status_code = N'ARCHIVED',
         @actor_employee_id = @actor_employee_id, @actor_role_code = N'ASSET_MERGE', @reason_code = N'MERGED', @reason_text = @reason_text,
         @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
    DECLARE @inactive_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                                 WHERE status_code = N'Inactive' OR status_name = N'Inactive' ORDER BY record_status_id);
    UPDATE grac_practice.organization_dependency_asset
       SET current_status_id = @to_id, status = N'Inactive', record_status_id = ISNULL(@inactive_rs, record_status_id),
           lifecycle_status = ISNULL((SELECT legacy_lifecycle_status FROM grac_practice.asset_lifecycle_status_phase WHERE status_code = N'ARCHIVED'),
                                     lifecycle_status),
           merged_into_asset_id = @survivor, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE asset_id = @duplicate;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @duplicate, N'MERGED', (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @survivor AS mergedIntoAssetId, @event_id AS mergeEventId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor),
           (N'asset-register', @survivor, N'MERGE_SURVIVOR', NULL,
            (SELECT @duplicate AS mergedAssetId, @event_id AS mergeEventId,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object o WHERE o.event_id = @event_id AND o.from_asset_id = @duplicate) AS outcomes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
END
GO
PRINT '445: sp_asset_merge_split_move created; sp_asset_merge_execute_one re-issued.';
GO

-- =====================================================================
-- 3. Split plan and blockers (D127-D129)
-- =====================================================================
-- Every object of the source (the 444 merge plan read for the source), its
-- allocation and what moving it to that resulting record does now:
--   MOVE   it moves
--   BLOCK  the result already has the equivalent open item (activity /
--          restrictive review) -- finish one first
--   STAY   not allocated, or the result already holds the equivalent (or the
--          relationship would join the result to itself) -- it stays with
--          the source
-- plus the source field values (user-entered) with MOVE / COPY / STAY.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_split_plan (@organization_id BIGINT, @event_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT o.ObjectKind, o.ObjectId, o.ObjectKey, o.ObjectLabel, o.Domain, o.Detail,
           al.target_asset_id AS TargetAssetId, CAST(NULL AS NVARCHAR(4)) AS FieldMode,
           CAST(CASE WHEN al.target_asset_id IS NULL THEN N'STAY' WHEN tp.Outcome = N'MOVE' THEN N'MOVE'
                     WHEN tp.Outcome = N'BLOCK' THEN N'BLOCK' ELSE N'STAY' END AS NVARCHAR(10)) AS Outcome,
           CAST(CASE WHEN al.target_asset_id IS NULL OR tp.Outcome IN (N'MOVE', N'BLOCK') THEN NULL
                     WHEN tp.Outcome IS NULL THEN N'No longer on the source.'
                     ELSE N'The resulting record already holds the equivalent (or it would refer to itself).' END AS NVARCHAR(200)) AS OutcomeNote
      FROM grac_practice.asset_merge_split_event ev
     CROSS APPLY grac_practice.fn_asset_merge_plan(ev.organization_id, -1, ev.survivor_asset_id) o
      LEFT JOIN grac_practice.asset_split_allocation al
        ON al.event_id = ev.event_id AND al.object_kind = o.ObjectKind
       AND ISNULL(al.object_id, -1) = ISNULL(o.ObjectId, -1) AND ISNULL(al.object_key, N'') = ISNULL(o.ObjectKey, N'')
     OUTER APPLY (SELECT TOP 1 t.Outcome
                    FROM grac_practice.fn_asset_merge_plan(ev.organization_id, al.target_asset_id, ev.survivor_asset_id) t
                   WHERE al.target_asset_id IS NOT NULL AND t.ObjectKind = o.ObjectKind
                     AND ISNULL(t.ObjectId, -1) = ISNULL(o.ObjectId, -1) AND ISNULL(t.ObjectKey, N'') = ISNULL(o.ObjectKey, N'')) tp
     WHERE ev.event_id = @event_id AND ev.organization_id = @organization_id AND ev.event_kind = N'SPLIT'
    UNION ALL
    SELECT N'FIELD', CAST(f.field_definition_id AS BIGINT), f.field_key, CAST(f.display_label AS NVARCHAR(400)), CAST(N'Field values' AS NVARCHAR(40)),
           CAST(LEFT(v.value_text, 400) AS NVARCHAR(600)), al.target_asset_id, al.field_mode,
           CAST(CASE WHEN al.target_asset_id IS NULL THEN N'STAY' ELSE al.field_mode END AS NVARCHAR(10)),
           CAST(CASE WHEN tv.value_text IS NOT NULL AND al.target_asset_id IS NOT NULL THEN CONCAT(N'Replaces "', LEFT(tv.value_text, 150), N'".') END
                AS NVARCHAR(200))
      FROM grac_practice.asset_merge_split_event ev
      JOIN grac_practice.asset_field_value v ON v.asset_id = ev.survivor_asset_id
      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.storage_kind = N'VALUE'
                                                 AND f.is_system_field = 0
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code AND dt.is_user_entered = 1
      LEFT JOIN grac_practice.asset_split_allocation al
        ON al.event_id = ev.event_id AND al.object_kind = N'FIELD' AND al.object_id = f.field_definition_id
      LEFT JOIN grac_practice.asset_field_value tv ON tv.asset_id = al.target_asset_id AND tv.field_definition_id = f.field_definition_id
     WHERE ev.event_id = @event_id AND ev.organization_id = @organization_id AND ev.event_kind = N'SPLIT';
GO

-- What stops a split: the source not in use or merged, a pending lifecycle
-- change or open workflow case on it; a resulting record that is not a new
-- Draft of the organization; nothing allocated; an allocation that no
-- longer matches the source or is blocked.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_split_blockers (@organization_id BIGINT, @event_id BIGINT)
RETURNS TABLE
AS
RETURN
    WITH ev AS (SELECT event_id, survivor_asset_id AS source_id FROM grac_practice.asset_merge_split_event
                 WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'SPLIT'),
         res AS (SELECT m.asset_id FROM grac_practice.asset_merge_split_member m JOIN ev ON ev.event_id = m.event_id WHERE m.member_role = N'RESULT')
    SELECT CAST(N'SOURCE_NOT_IN_USE' AS NVARCHAR(30)) AS BlockerCode,
           CAST(CONCAT(a.asset_name, N' is disposed, archived or merged.') AS NVARCHAR(600)) AS Detail
      FROM ev JOIN grac_practice.organization_dependency_asset a ON a.asset_id = ev.source_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.merged_into_asset_id IS NOT NULL OR ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED')
    UNION ALL
    SELECT N'PENDING_LIFECYCLE', CAST(CONCAT(N'Lifecycle change ', c.from_status_code, N' -> ', c.to_status_code,
                                             N' of the source awaits approval; approve, reject or cancel it.') AS NVARCHAR(600))
      FROM ev JOIN grac_practice.asset_lifecycle_change c ON c.asset_id = ev.source_id AND c.change_status = N'PENDING_APPROVAL'
    UNION ALL
    SELECT N'OPEN_WORKFLOW', CAST(CONCAT(N'Workflow case #', w.case_id, N' (', w.workflow_code, N') of the source is open; complete or cancel it.') AS NVARCHAR(600))
      FROM ev JOIN grac_practice.asset_workflow_case w ON w.asset_id = ev.source_id AND w.case_status = N'OPEN'
    UNION ALL
    SELECT N'RESULT_NOT_DRAFT', CAST(CONCAT(a.asset_name, N' is not a Draft asset of this organization (register the resulting records as new Draft assets).') AS NVARCHAR(600))
      FROM res JOIN grac_practice.organization_dependency_asset a ON a.asset_id = res.asset_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id <> @organization_id OR a.merged_into_asset_id IS NOT NULL OR ISNULL(s.status_code, N'ACTIVE') <> N'DRAFT'
    UNION ALL
    SELECT N'NOTHING_ALLOCATED', CAST(N'Allocate at least one item or field value to a resulting record.' AS NVARCHAR(600))
      FROM ev WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_split_allocation al WHERE al.event_id = ev.event_id)
    UNION ALL
    SELECT N'ALLOCATION_CHANGED', CAST(CONCAT(al.object_kind, N' #', ISNULL(CAST(al.object_id AS NVARCHAR(30)), al.object_key),
                                              N' is no longer on the source; allocate again.') AS NVARCHAR(600))
      FROM ev JOIN grac_practice.asset_split_allocation al ON al.event_id = ev.event_id
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) p
                        WHERE p.ObjectKind = al.object_kind AND ISNULL(p.ObjectId, -1) = ISNULL(al.object_id, -1)
                          AND (al.object_kind = N'FIELD' OR ISNULL(p.ObjectKey, N'') = ISNULL(al.object_key, N'')))
    UNION ALL
    SELECT N'ALLOCATION_BLOCKED', CAST(CONCAT(p.ObjectLabel, N': the resulting record already has this open item; finish one first.') AS NVARCHAR(600))
      FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) p WHERE p.Outcome = N'BLOCK';
GO
PRINT '445: split plan and blockers created.';
GO

-- =====================================================================
-- 4. Split writers (D125, D128)
-- =====================================================================
-- New or changed Draft: source, resulting records (JSON array of 1-5 Draft
-- asset ids), reason, allocations (JSON array of {objectKind, objectId,
-- objectKey, targetAssetId, fieldMode} -- fieldMode MOVE | COPY for FIELD).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_split_save
    @organization_id         BIGINT,
    @event_id                BIGINT         = NULL,
    @source_asset_id         BIGINT,
    @results_json            NVARCHAR(MAX),
    @reason                  NVARCHAR(1000) = NULL,
    @allocations_json        NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 52900, 'Organization not found.', 1;
    IF @event_id IS NOT NULL
    BEGIN
        DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT;
        SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version)
          FROM grac_practice.asset_merge_split_event
         WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'SPLIT';
        IF @found = 0 THROW 52902, 'Split not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 52903, 'The split was changed by someone else; reload it and try again.', 1;
        IF @status <> N'DRAFT' THROW 52907, 'Only a draft split can be changed.', 1;
    END

    DECLARE @res TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, seq INT NOT NULL);
    IF ISJSON(ISNULL(@results_json, N'')) = 1
        INSERT @res (asset_id, seq)
        SELECT d.asset_id, ROW_NUMBER() OVER (ORDER BY MIN(d.ord))
          FROM (SELECT TRY_CONVERT(BIGINT, j.[value]) AS asset_id, CAST(j.[key] AS INT) AS ord FROM OPENJSON(@results_json) j) d
         WHERE d.asset_id IS NOT NULL
         GROUP BY d.asset_id;
    IF (SELECT COUNT(*) FROM @res) NOT BETWEEN 1 AND 5
        THROW 52915, 'Choose 1 to 5 resulting records.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @source_asset_id AND organization_id = @organization_id)
       OR EXISTS (SELECT 1 FROM @res r WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                                                          WHERE a.asset_id = r.asset_id AND a.organization_id = @organization_id))
        THROW 52901, 'Asset not found for this organization.', 1;
    IF EXISTS (SELECT 1 FROM @res WHERE asset_id = @source_asset_id)
       OR EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                    LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                   WHERE a.asset_id = @source_asset_id
                     AND (a.merged_into_asset_id IS NOT NULL OR ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED')))
        THROW 52904, 'The source must be an asset in use (not disposed, archived or merged) and not one of the resulting records.', 1;
    IF EXISTS (SELECT 1 FROM @res r
                 JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id
                 LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                WHERE a.merged_into_asset_id IS NOT NULL OR ISNULL(s.status_code, N'ACTIVE') <> N'DRAFT')
        THROW 52916, 'Each resulting record is a new Draft asset registered on the Asset Register form.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_event e
                WHERE e.organization_id = @organization_id AND e.status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED')
                  AND e.event_id <> ISNULL(@event_id, -1)
                  AND (e.survivor_asset_id = @source_asset_id OR e.survivor_asset_id IN (SELECT asset_id FROM @res)
                       OR EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_member m
                                   WHERE m.event_id = e.event_id
                                     AND (m.asset_id = @source_asset_id OR m.asset_id IN (SELECT asset_id FROM @res)))))
        THROW 52905, 'One of these assets is already in another open merge or split; finish or cancel it first.', 1;

    DECLARE @al TABLE (object_kind NVARCHAR(20) NOT NULL, object_id BIGINT NULL, object_key NVARCHAR(200) NULL,
                       target_asset_id BIGINT NULL, field_mode NVARCHAR(4) NULL);
    IF @allocations_json IS NOT NULL AND LTRIM(@allocations_json) <> N''
    BEGIN
        IF ISJSON(@allocations_json) = 0 OR LEFT(LTRIM(@allocations_json), 1) <> N'['
            THROW 52917, 'The allocations are not valid.', 1;
        INSERT @al (object_kind, object_id, object_key, target_asset_id, field_mode)
        SELECT UPPER(LTRIM(RTRIM(j.objectKind))), j.objectId, NULLIF(LTRIM(RTRIM(j.objectKey)), N''), j.targetAssetId,
               NULLIF(UPPER(LTRIM(RTRIM(j.fieldMode))), N'')
          FROM OPENJSON(@allocations_json) WITH (objectKind NVARCHAR(20), objectId BIGINT, objectKey NVARCHAR(200), targetAssetId BIGINT,
                                                 fieldMode NVARCHAR(4)) j;
        IF EXISTS (SELECT 1 FROM @al a
                    WHERE a.target_asset_id IS NULL OR a.target_asset_id NOT IN (SELECT asset_id FROM @res)
                       OR a.object_kind NOT IN (N'RELATIONSHIP', N'DISCOVERY_LINK', N'ATTRIBUTE_SOURCE', N'RECON_EXCEPTION', N'COVERAGE',
                                                N'OCCURRENCE', N'RESTRICTIVE_REVIEW', N'RISK_MAP', N'RISK_LINK', N'PRACTICE_RESOLUTION', N'FIELD')
                       OR (a.object_kind = N'FIELD' AND ISNULL(a.field_mode, N'') NOT IN (N'MOVE', N'COPY'))
                       OR (a.object_kind <> N'FIELD' AND a.field_mode IS NOT NULL)
                       OR (a.object_kind = N'FIELD' AND NOT EXISTS (
                               SELECT 1 FROM grac_practice.asset_field_value v
                                 JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                                            AND f.storage_kind = N'VALUE' AND f.is_system_field = 0
                                 JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code AND dt.is_user_entered = 1
                                WHERE v.asset_id = @source_asset_id AND v.field_definition_id = a.object_id))
                       OR (a.object_kind <> N'FIELD' AND NOT EXISTS (
                               SELECT 1 FROM grac_practice.fn_asset_merge_plan(@organization_id, -1, @source_asset_id) p
                                WHERE p.ObjectKind = a.object_kind AND ISNULL(p.ObjectId, -1) = ISNULL(a.object_id, -1)
                                  AND ISNULL(p.ObjectKey, N'') = ISNULL(a.object_key, N''))))
            THROW 52917, 'Each allocation names an item of the source (field values: a user-entered value, Move or Copy) and one of the resulting records.', 1;
        IF EXISTS (SELECT 1 FROM @al GROUP BY object_kind, object_id, object_key HAVING COUNT(*) > 1)
            THROW 52917, 'An item can be allocated to one resulting record only.', 1;
    END

    DECLARE @id BIGINT = @event_id, @result NVARCHAR(20) = CASE WHEN @event_id IS NULL THEN N'CREATED' ELSE N'SAVED' END;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        INSERT grac_practice.asset_merge_split_event
            (organization_id, event_kind, survivor_asset_id, status, reason, requested_by, requested_by_employee_id)
        VALUES (@organization_id, N'SPLIT', @source_asset_id, N'DRAFT', @reason, @actor, @actor_employee_id);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_merge_split_event SET survivor_asset_id = @source_asset_id, reason = @reason WHERE event_id = @id;
        DELETE FROM grac_practice.asset_merge_split_member WHERE event_id = @id;
        DELETE FROM grac_practice.asset_split_allocation WHERE event_id = @id;
    END
    INSERT grac_practice.asset_merge_split_member (event_id, asset_id, member_role, sequence_no)
    SELECT @id, asset_id, N'RESULT', seq FROM @res;
    INSERT grac_practice.asset_split_allocation (event_id, object_kind, object_id, object_key, target_asset_id, field_mode)
    SELECT @id, object_kind, object_id, CASE WHEN object_kind = N'FIELD' THEN NULL ELSE object_key END, target_asset_id, field_mode FROM @al;
    UPDATE e
       SET is_critical = c.IsCritical, approvals_required = CASE WHEN c.IsCritical = 1 THEN 2 ELSE 1 END
      FROM grac_practice.asset_merge_split_event e
     CROSS APPLY grac_practice.fn_asset_merge_critical(@organization_id, @id) c
     WHERE e.event_id = @id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-split', @id, CASE WHEN @event_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, NULL,
            (SELECT @source_asset_id AS sourceAssetId, JSON_QUERY(@results_json) AS results, @reason AS reason,
                    (SELECT COUNT(*) FROM @al) AS allocations FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS EventId, @result AS Result;
END
GO

-- Execution (internal; inside the EXECUTE transaction of
-- sp_asset_merge_action): per resulting record, allocated items that can
-- move are moved by sp_asset_merge_split_move, the others are recorded as
-- kept; then the allocated field values are copied (and, for Move, taken
-- off the source).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_split_execute
    @organization_id   BIGINT,
    @event_id          BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF EXISTS (SELECT 1 FROM grac_practice.fn_asset_split_blockers(@organization_id, @event_id))
        THROW 52908, 'The split has blockers; open it to see them.', 1;
    DECLARE @source BIGINT = (SELECT survivor_asset_id FROM grac_practice.asset_merge_split_event WHERE event_id = @event_id);
    CREATE TABLE #msplan (object_kind NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL, object_id BIGINT NULL,
                          object_key NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL, object_label NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,
                          outcome NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL, detail NVARCHAR(600) COLLATE DATABASE_DEFAULT NULL);
    DECLARE @target BIGINT, @note NVARCHAR(400);
    DECLARE @fv TABLE (field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL, label NVARCHAR(200) NULL,
                       before_text NVARCHAR(MAX) NULL, value_text NVARCHAR(MAX) NOT NULL, field_mode NVARCHAR(4) NOT NULL);
    DECLARE res_cur CURSOR LOCAL STATIC FOR
        SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id AND member_role = N'RESULT' ORDER BY sequence_no;
    OPEN res_cur;
    FETCH NEXT FROM res_cur INTO @target;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @note = CONCAT(N'Split #', @event_id, N': from asset #', @source, N' to #', @target, N'.');
        TRUNCATE TABLE #msplan;
        -- allocated items that stay (the result holds the equivalent): recorded as kept
        INSERT grac_practice.asset_merge_split_object
            (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
        SELECT @event_id, p.ObjectKind, p.ObjectId, p.ObjectKey, p.ObjectLabel, @source, @target, N'KEPT', p.OutcomeNote
          FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) p
         WHERE p.TargetAssetId = @target AND p.ObjectKind <> N'FIELD' AND p.Outcome = N'STAY';
        INSERT #msplan (object_kind, object_id, object_key, object_label, outcome, detail)
        SELECT p.ObjectKind, p.ObjectId, p.ObjectKey, p.ObjectLabel, N'MOVE', p.Detail
          FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) p
         WHERE p.TargetAssetId = @target AND p.ObjectKind <> N'FIELD' AND p.Outcome = N'MOVE';
        EXEC grac_practice.sp_asset_merge_split_move
             @organization_id = @organization_id, @event_id = @event_id, @from_asset = @source, @to_asset = @target,
             @note = @note, @actor_employee_id = @actor_employee_id, @actor = @actor;

        -- field values: copied to the result (filled / replaced) ...
        DELETE FROM @fv;
        INSERT @fv (field_definition_id, field_key, label, before_text, value_text, field_mode)
        SELECT f.field_definition_id, f.field_key, f.display_label, tv.value_text, sv.value_text, al.field_mode
          FROM grac_practice.asset_split_allocation al
          JOIN grac_practice.asset_field_definition f ON f.field_definition_id = al.object_id
          JOIN grac_practice.asset_field_value sv ON sv.asset_id = @source AND sv.field_definition_id = f.field_definition_id
          LEFT JOIN grac_practice.asset_field_value tv ON tv.asset_id = @target AND tv.field_definition_id = f.field_definition_id
         WHERE al.event_id = @event_id AND al.object_kind = N'FIELD' AND al.target_asset_id = @target;
        INSERT grac_practice.asset_merge_split_object
            (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
        SELECT @event_id, N'FIELD', field_definition_id, field_key, label, @source, @target,
               CASE WHEN before_text IS NULL THEN N'FILLED' ELSE N'REPLACED' END, before_text, value_text, LOWER(field_mode)
          FROM @fv WHERE ISNULL(before_text, N'') <> value_text;
        MERGE grac_practice.asset_field_value AS t
        USING (SELECT sv.field_definition_id, sv.value_text, sv.value_number, sv.value_date, sv.value_ref
                 FROM grac_practice.asset_field_value sv JOIN @fv x ON x.field_definition_id = sv.field_definition_id
                WHERE sv.asset_id = @source) AS s
           ON t.asset_id = @target AND t.field_definition_id = s.field_definition_id
        WHEN MATCHED AND t.value_text <> s.value_text THEN
            UPDATE SET value_text = s.value_text, value_number = s.value_number, value_date = s.value_date, value_ref = s.value_ref,
                       updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
                              VALUES (@target, s.field_definition_id, s.value_text, s.value_number, s.value_date, s.value_ref, @actor);
        -- ... and, for Move, taken off the source (row without an after value)
        INSERT grac_practice.asset_merge_split_object
            (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
        SELECT @event_id, N'FIELD', field_definition_id, field_key, label, @target, @source, N'REPLACED', value_text, NULL,
               N'moved to the resulting record'
          FROM @fv WHERE field_mode = N'MOVE';
        DELETE v FROM grac_practice.asset_field_value v
          JOIN @fv x ON x.field_definition_id = v.field_definition_id AND x.field_mode = N'MOVE'
         WHERE v.asset_id = @source;

        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-register', @target, N'SPLIT_RESULT', NULL,
                (SELECT @source AS sourceAssetId, @event_id AS splitEventId,
                        (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object o WHERE o.event_id = @event_id AND o.to_asset_id = @target) AS outcomes
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
        FETCH NEXT FROM res_cur INTO @target;
    END
    CLOSE res_cur;
    DEALLOCATE res_cur;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @source, N'SPLIT_SOURCE', NULL,
            (SELECT @event_id AS splitEventId,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object o WHERE o.event_id = @event_id) AS outcomes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
END
GO
PRINT '445: split save and execution created.';
GO

-- =====================================================================
-- 5. Split reader. 1. event  2. assets (source first)  3. approvals
-- 4. blockers (open)  5. plan / allocation (open)  6. outcomes  7. impact.
-- The list is sp_asset_merge_events with @event_kind = SPLIT.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_split_get
    @organization_id BIGINT,
    @event_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @source BIGINT, @status NVARCHAR(20);
    SELECT @source = survivor_asset_id, @status = status
      FROM grac_practice.asset_merge_split_event
     WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'SPLIT';
    IF @source IS NULL THROW 52902, 'Split not found for this organization.', 1;
    DECLARE @open BIT = CASE WHEN @status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED') THEN 1 ELSE 0 END;
    SELECT e.event_id AS EventId, e.status AS Status, e.survivor_asset_id AS SourceAssetId, s.asset_name AS SourceName,
           e.reason AS Reason, e.is_critical AS IsCritical, e.approvals_required AS ApprovalsRequired,
           (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval p WHERE p.event_id = e.event_id AND p.decision = N'APPROVE') AS Approvals,
           e.requested_by AS RequestedBy, e.requested_dt AS RequestedDt, e.submitted_dt AS SubmittedDt, e.decided_note AS DecidedNote,
           e.executed_by AS ExecutedBy, e.executed_dt AS ExecutedDt, e.recovered_by AS RecoveredBy, e.recovered_dt AS RecoveredDt,
           e.recovery_reason AS RecoveryReason, e.closed_dt AS ClosedDt, CONVERT(BIGINT, e.record_version) AS RecordVersion
      FROM grac_practice.asset_merge_split_event e
      JOIN grac_practice.organization_dependency_asset s ON s.asset_id = e.survivor_asset_id
     WHERE e.event_id = @event_id;
    SELECT x.asset_id AS AssetId, x.role_code AS MemberRole, x.seq AS SequenceNo, a.asset_name AS AssetName,
           ty.asset_type_name AS AssetTypeName, ISNULL(st.status_name, N'Active') AS StatusName, c.criticality_name AS CriticalityName,
           ow.employee_name AS OwnerName
      FROM (SELECT @source AS asset_id, N'SOURCE' AS role_code, 0 AS seq
            UNION ALL SELECT asset_id, member_role, sequence_no FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id) x
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.entity_status_master st ON st.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.owner_id
     ORDER BY x.seq;
    SELECT approval_id AS ApprovalId, decision AS Decision, note AS Note, approver AS Approver, decided_dt AS DecidedDt
      FROM grac_practice.asset_merge_split_approval WHERE event_id = @event_id ORDER BY approval_id;
    SELECT BlockerCode, Detail FROM grac_practice.fn_asset_split_blockers(@organization_id, @event_id) WHERE @open = 1;
    SELECT p.ObjectKind, p.ObjectId, p.ObjectKey, p.ObjectLabel, p.Domain, p.Detail, p.TargetAssetId, p.FieldMode, p.Outcome, p.OutcomeNote
      FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) p
     WHERE @open = 1
     ORDER BY p.Domain, p.ObjectKind, p.ObjectLabel;
    SELECT o.object_row_id AS ObjectRowId, o.from_asset_id AS FromAssetId, o.to_asset_id AS ToAssetId, o.object_kind AS ObjectKind,
           o.object_id AS ObjectId, o.object_label AS ObjectLabel, o.outcome AS Outcome, LEFT(o.before_value, 400) AS BeforeValue,
           LEFT(o.after_value, 400) AS AfterValue, o.detail AS Detail, o.recovered AS Recovered, o.recovery_note AS RecoveryNote
      FROM grac_practice.asset_merge_split_object o
     WHERE o.event_id = @event_id
     ORDER BY o.object_row_id;
    SELECT x.asset_id AS AssetId, i.ImpactItem, i.ItemCount, i.SortOrder
      FROM (SELECT @source AS asset_id UNION SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id) x
     CROSS APPLY grac_practice.fn_asset_merge_impact(@organization_id, x.asset_id) i
     ORDER BY x.asset_id, i.SortOrder;
END
GO
PRINT '445: split reader created.';
GO

-- =====================================================================
-- 6. 444 procedures re-issued for split (D127, D130)
--    sp_asset_merge_recover: a value a split moved off the source (row with
--      no after value) is put back when the source still has none.
--    sp_asset_merge_action: one action procedure for MERGE and SPLIT (same
--      statuses, approval and two-person rules); split blockers, plan
--      counts and execution are the split ones.
--    sp_asset_merge_events: @event_kind (default MERGE).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_recover
    @organization_id   BIGINT,
    @event_id          BIGINT,
    @note              NVARCHAR(1000),
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @row BIGINT, @kind NVARCHAR(20), @oid BIGINT, @okey NVARCHAR(200), @from_asset BIGINT, @to_asset BIGINT, @outcome NVARCHAR(12),
            @before NVARCHAR(MAX), @after NVARCHAR(MAX), @done BIT, @why NVARCHAR(400);
    DECLARE @msg NVARCHAR(400) = CONCAT(N'Merge #', @event_id, N' recovered: ', LEFT(@note, 300));
    DECLARE @prev NVARCHAR(60), @to_id INT, @log BIGINT, @rtext NVARCHAR(1000) = CONCAT(N'Merge #', @event_id, N' recovered.'),
            @bs BIGINT, @bt BIGINT;
    DECLARE obj_cur CURSOR LOCAL STATIC FOR
        SELECT object_row_id, object_kind, object_id, object_key, from_asset_id, to_asset_id, outcome, before_value, after_value
          FROM grac_practice.asset_merge_split_object
         WHERE event_id = @event_id AND recovered = 0
         ORDER BY object_row_id DESC;
    OPEN obj_cur;
    FETCH NEXT FROM obj_cur INTO @row, @kind, @oid, @okey, @from_asset, @to_asset, @outcome, @before, @after;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @done = 0, @why = NULL;
        IF @outcome = N'KEPT'
        BEGIN
            SET @done = 1;
        END
        ELSE IF @kind = N'ASSET_RECORD'
        BEGIN
            SET @prev = JSON_VALUE(@before, '$.statusCode');
            IF EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                        WHERE a.asset_id = @oid AND s.status_code = N'ARCHIVED' AND a.merged_into_asset_id = @to_asset)
               AND @prev IS NOT NULL
            BEGIN
                EXEC grac_practice.sp_pm_state_transition
                     @entity_type = N'Asset', @entity_id = @oid, @from_status_code = N'ARCHIVED', @to_status_code = @prev,
                     @actor_employee_id = @actor_employee_id, @actor_role_code = N'ASSET_MERGE', @reason_code = N'MERGE_RECOVERED',
                     @reason_text = @rtext, @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
                UPDATE grac_practice.organization_dependency_asset
                   SET current_status_id = @to_id, status = ISNULL(JSON_VALUE(@before, '$.status'), N'Active'),
                       record_status_id = ISNULL(TRY_CONVERT(INT, JSON_VALUE(@before, '$.recordStatusId')), record_status_id),
                       lifecycle_status = JSON_VALUE(@before, '$.lifecycleStatus'),
                       merged_into_asset_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE asset_id = @oid;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The merged record is no longer archived into the survivor.'; END
        END
        ELSE IF @kind = N'ALIAS'
        BEGIN
            UPDATE grac_practice.asset_alias SET is_active = 0 WHERE alias_id = @oid;
            SET @done = 1;
        END
        ELSE IF @kind = N'FIELD'
        BEGIN
            IF (@after IS NOT NULL   -- 445
                AND EXISTS (SELECT 1 FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid AND value_text = @after))   -- 445
               OR (@after IS NULL AND @before IS NOT NULL   -- 445
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid))   -- 445
            BEGIN
                IF @before IS NULL
                BEGIN
                    DELETE FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid;
                END
                ELSE IF @after IS NULL   -- 445
                BEGIN   -- 445
                    -- a split moved the value away from the source: put it back   -- 445
                    INSERT grac_practice.asset_field_value   -- 445
                        (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)   -- 445
                    SELECT @to_asset, f.field_definition_id, @before,   -- 445
                           TRY_CONVERT(DECIMAL(38, 6), CASE WHEN f.data_type_code = N'QUANTITY_UNIT'   -- 445
                                                            THEN LEFT(@before, CHARINDEX(N' ', @before + N' ') - 1) ELSE @before END),   -- 445
                           CASE WHEN f.data_type_code = N'DATE' THEN TRY_CONVERT(DATE, @before, 23) END,   -- 445
                           CASE WHEN f.lookup_source LIKE N'MASTER:%' AND f.data_type_code NOT IN (N'MULTI_SELECT', N'MULTI_USER')   -- 445
                                THEN TRY_CONVERT(BIGINT, @before) END, @actor   -- 445
                      FROM grac_practice.asset_field_definition f WHERE f.field_definition_id = @oid;   -- 445
                END   -- 445
                ELSE
                    UPDATE v
                       SET value_text = @before,
                           value_number = TRY_CONVERT(DECIMAL(38, 6), CASE WHEN f.data_type_code = N'QUANTITY_UNIT'
                                                                         THEN LEFT(@before, CHARINDEX(N' ', @before + N' ') - 1) ELSE @before END),
                           value_date = CASE WHEN f.data_type_code = N'DATE' THEN TRY_CONVERT(DATE, @before, 23) END,
                           value_ref = CASE WHEN f.lookup_source LIKE N'MASTER:%' AND f.data_type_code NOT IN (N'MULTI_SELECT', N'MULTI_USER')
                                            THEN TRY_CONVERT(BIGINT, @before) END,
                           updated_by = @actor, updated_dt = SYSUTCDATETIME()
                      FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                     WHERE v.asset_id = @to_asset AND v.field_definition_id = @oid;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The survivor value was changed after the merge.'; END
        END
        ELSE IF @kind = N'RELATIONSHIP' AND @outcome = N'MOVED'
        BEGIN
            SELECT @bs = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.sourceId')), @bt = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.targetId'));
            IF EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                        WHERE r.relationship_id = @oid AND r.source_id = TRY_CONVERT(BIGINT, JSON_VALUE(@after, '$.sourceId'))
                          AND r.target_id = TRY_CONVERT(BIGINT, JSON_VALUE(@after, '$.targetId')))
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                                 JOIN grac_practice.asset_relationship q ON q.organization_id = r.organization_id
                                  AND q.relationship_type_code = r.relationship_type_code AND q.relationship_id <> r.relationship_id
                                  AND q.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                                  AND q.source_kind = r.source_kind AND q.source_id = @bs AND q.target_kind = r.target_kind AND q.target_id = @bt
                                WHERE r.relationship_id = @oid AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED'))
            BEGIN
                UPDATE grac_practice.asset_relationship
                   SET source_id = @bs, target_id = @bt, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE relationship_id = @oid;
                EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @oid, @action_code = N'MERGE_RECOVER', @note = @msg,
                     @actor = @actor, @actor_employee_id = @actor_employee_id;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The relationship changed after the merge, or restoring it would duplicate a current one.'; END
        END
        ELSE IF @kind = N'RELATIONSHIP' AND @outcome = N'ENDED'
        BEGIN
            IF EXISTS (SELECT 1 FROM grac_practice.asset_relationship WHERE relationship_id = @oid AND status = N'RETIRED')
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                                 JOIN grac_practice.asset_relationship q ON q.organization_id = r.organization_id
                                  AND q.relationship_type_code = r.relationship_type_code AND q.relationship_id <> r.relationship_id
                                  AND q.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                                  AND q.source_kind = r.source_kind AND q.source_id = r.source_id AND q.target_kind = r.target_kind
                                  AND q.target_id = r.target_id
                                WHERE r.relationship_id = @oid)
            BEGIN
                UPDATE grac_practice.asset_relationship
                   SET status = JSON_VALUE(@before, '$.status'), effective_to = TRY_CONVERT(DATE, JSON_VALUE(@before, '$.effectiveTo')),
                       status_note = @msg, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE relationship_id = @oid;
                EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @oid, @action_code = N'MERGE_RECOVER', @note = @msg,
                     @actor = @actor, @actor_employee_id = @actor_employee_id;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The relationship is no longer retired, or restoring it would duplicate a current one.'; END
        END
        ELSE IF @kind = N'DISCOVERY_LINK'
        BEGIN
            UPDATE grac_practice.asset_discovery_link SET asset_id = @from_asset WHERE link_id = @oid AND asset_id = @to_asset;
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The source record is linked elsewhere now.'; END
        END
        ELSE IF @kind = N'ATTRIBUTE_SOURCE'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_attribute_source WHERE asset_id = @from_asset AND field_key = @okey AND source_id = @oid)
            BEGIN
                UPDATE grac_practice.asset_attribute_source SET asset_id = @from_asset
                 WHERE asset_id = @to_asset AND field_key = @okey AND source_id = @oid;
                IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The value is no longer on the survivor.'; END
            END
            ELSE BEGIN SET @why = N'The merged record already holds a value from this source.'; END
        END
        ELSE IF @kind = N'RECON_EXCEPTION' AND @outcome = N'RESOLVED'
        BEGIN
            UPDATE grac_practice.asset_reconciliation_exception
               SET status = N'OPEN', resolution = NULL, resolution_note = NULL, resolved_by = NULL, resolved_dt = NULL, updated_dt = SYSUTCDATETIME()
             WHERE exception_id = @oid AND status = N'RESOLVED' AND resolution = N'MERGED';
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The exception was handled again after the merge.'; END
        END
        ELSE IF @kind = N'RECON_EXCEPTION'
        BEGIN
            UPDATE grac_practice.asset_reconciliation_exception
               SET asset_id = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.assetId')),
                   other_asset_id = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.otherAssetId')), updated_dt = SYSUTCDATETIME()
             WHERE exception_id = @oid AND status = N'OPEN' AND (asset_id = @to_asset OR other_asset_id = @to_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The exception was resolved or changed after the merge.'; END
        END
        ELSE IF @kind = N'COVERAGE'
        BEGIN
            UPDATE c SET asset_id = @from_asset
              FROM grac_practice.asset_contract_coverage c
             WHERE c.coverage_id = @oid AND c.asset_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage c2
                                WHERE c2.version_id = c.version_id AND c2.asset_id = @from_asset AND c2.coverage_type = c.coverage_type);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The coverage line changed after the merge.'; END
        END
        ELSE IF @kind = N'OCCURRENCE'
        BEGIN
            UPDATE o SET asset_id = @from_asset, updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.asset_activity_occurrence o
             WHERE o.occurrence_id = @oid AND o.asset_id = @to_asset
               AND (o.status <> N'OPEN' OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o2
                                                        WHERE o2.asset_id = @from_asset AND o2.template_code = o.template_code AND o2.status = N'OPEN'));
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The activity changed after the merge.'; END
        END
        ELSE IF @kind = N'RESTRICTIVE_REVIEW'
        BEGIN
            UPDATE r SET asset_id = @from_asset
              FROM grac_practice.asset_restrictive_review r
             WHERE r.review_id = @oid AND r.asset_id = @to_asset
               AND (r.status NOT IN (N'OPEN', N'DECIDED') OR NOT EXISTS (
                        SELECT 1 FROM grac_practice.asset_restrictive_review r2
                         WHERE r2.asset_id = @from_asset AND r2.status IN (N'OPEN', N'DECIDED') AND r2.source_kind = r.source_kind
                           AND r2.source_code = r.source_code AND r2.trigger_code = r.trigger_code));
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The review changed after the merge.'; END
        END
        ELSE IF @kind = N'RISK_MAP'
        BEGIN
            UPDATE m SET dependency_object_id = @from_asset, dependency_object_name = @before, updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.risk_dependency_map m
             WHERE m.risk_dependency_map_id = @oid AND m.dependency_object_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map m2
                                WHERE m2.risk_register_id = m.risk_register_id AND m2.dependency_type_id = m.dependency_type_id
                                  AND m2.dependency_object_id = @from_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The risk mapping changed after the merge.'; END
        END
        ELSE IF @kind = N'RISK_LINK'
        BEGIN
            UPDATE grac_practice.risk_register SET linked_asset_id = @from_asset WHERE risk_register_id = @oid AND linked_asset_id = @to_asset;
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The risk was linked elsewhere after the merge.'; END
        END
        ELSE IF @kind = N'PRACTICE_RESOLUTION'
        BEGIN
            UPDATE d SET resolved_dependency_id = @from_asset, resolved_dependency_name = ISNULL(@before, d.resolved_dependency_name),
                         updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.practice_dependency_resolution d
             WHERE d.resolution_id = @oid AND d.resolved_dependency_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_dependency_resolution d2
                                WHERE d2.organization_id = d.organization_id AND d2.practice_instance_id = d.practice_instance_id
                                  AND d2.dependency_type_id = d.dependency_type_id AND d2.resolved_dependency_id = @from_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The practice resolution changed after the merge.'; END
        END
        UPDATE grac_practice.asset_merge_split_object SET recovered = @done, recovery_note = @why WHERE object_row_id = @row;
        FETCH NEXT FROM obj_cur INTO @row, @kind, @oid, @okey, @from_asset, @to_asset, @outcome, @before, @after;
    END
    CLOSE obj_cur;
    DEALLOCATE obj_cur;
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_action
    @organization_id         BIGINT,
    @event_id                BIGINT,
    @action                  NVARCHAR(10),
    @note                    NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @survivor BIGINT, @reason NVARCHAR(1000), @choices NVARCHAR(MAX),
            @requested_by NVARCHAR(100), @requested_emp BIGINT, @required INT, @kind NVARCHAR(10);   -- 445
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @survivor = survivor_asset_id, @reason = reason,
           @choices = field_choices_json, @requested_by = requested_by, @requested_emp = requested_by_employee_id,
           @required = approvals_required, @kind = event_kind   -- 445
      FROM grac_practice.asset_merge_split_event
     WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind IN (N'MERGE', N'SPLIT');   -- 445
    IF @found = 0 THROW 52902, 'Merge not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 52903, 'The merge was changed by someone else; reload it and try again.', 1;
    IF @action NOT IN (N'SUBMIT', N'CANCEL', N'APPROVE', N'REJECT', N'EXECUTE', N'RECOVER')
        THROW 52911, 'That action is not available for a merge.', 1;
    IF NOT ((@action = N'SUBMIT' AND @status = N'DRAFT')
         OR (@action = N'CANCEL' AND @status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED'))
         OR (@action IN (N'APPROVE', N'REJECT') AND @status = N'PENDING_APPROVAL')
         OR (@action = N'EXECUTE' AND @status = N'APPROVED')
         OR (@action = N'RECOVER' AND @status = N'EXECUTED'))
        THROW 52907, 'The merge status does not allow this action.', 1;
    IF @action IN (N'CANCEL', N'REJECT', N'RECOVER') AND @note IS NULL
        THROW 52910, 'Record the reason in the note.', 1;
    IF @action IN (N'APPROVE', N'REJECT')
       AND ((@actor_employee_id IS NOT NULL AND @actor_employee_id = @requested_emp) OR @actor = @requested_by)
        THROW 52909, 'The requester cannot approve or reject the merge; another person decides.', 1;
    IF @action = N'APPROVE'
       AND EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_approval
                    WHERE event_id = @event_id AND decision = N'APPROVE'
                      AND ((@actor_employee_id IS NOT NULL AND approver_employee_id = @actor_employee_id) OR approver = @actor))
        THROW 52909, 'You already approved this merge; a critical merge needs a second, different approver.', 1;
    IF @action IN (N'SUBMIT', N'EXECUTE')
    BEGIN
        IF @action = N'SUBMIT' AND @reason IS NULL THROW 52906, 'Record the reason for the merge first.', 1;
        DECLARE @blk NVARCHAR(1500) = (
            SELECT LEFT(STRING_AGG(CAST(CONCAT(a.asset_name, N': ', b.Detail) AS NVARCHAR(MAX)), N' | '), 1400)
              FROM grac_practice.asset_merge_split_member m
              JOIN grac_practice.organization_dependency_asset a ON a.asset_id = m.asset_id
             CROSS APPLY grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, m.asset_id) b
             WHERE m.event_id = @event_id);
        IF @kind = N'SPLIT'   -- 445
            SET @blk = (SELECT LEFT(STRING_AGG(CAST(b.Detail AS NVARCHAR(MAX)), N' | '), 1400)   -- 445
                          FROM grac_practice.fn_asset_split_blockers(@organization_id, @event_id) b);   -- 445
        IF @blk IS NOT NULL
        BEGIN
            DECLARE @blk_msg NVARCHAR(1600) = CONCAT(N'Resolve these first: ', @blk);
            THROW 52908, @blk_msg, 1;
        END
    END

    DECLARE @result NVARCHAR(20) = @status, @approvals INT;
    BEGIN TRAN;
    IF @action = N'SUBMIT'
    BEGIN
        UPDATE e
           SET status = N'PENDING_APPROVAL', submitted_dt = SYSUTCDATETIME(), is_critical = c.IsCritical,
               approvals_required = CASE WHEN c.IsCritical = 1 THEN 2 ELSE 1 END,
               preview_json = CASE WHEN @kind = N'SPLIT'   -- 445
                              THEN (SELECT x.ObjectKind AS kind, x.Outcome AS outcome, COUNT(*) AS items   -- 445
                                      FROM grac_practice.fn_asset_split_plan(@organization_id, @event_id) x   -- 445
                                     GROUP BY x.ObjectKind, x.Outcome FOR JSON PATH)   -- 445
                              ELSE (SELECT p.ObjectKind AS kind, p.Outcome AS outcome, COUNT(*) AS items   -- 445
                                 FROM grac_practice.asset_merge_split_member m
                                CROSS APPLY grac_practice.fn_asset_merge_plan(@organization_id, @survivor, m.asset_id) p
                                WHERE m.event_id = @event_id
                                GROUP BY p.ObjectKind, p.Outcome FOR JSON PATH) END   -- 445
          FROM grac_practice.asset_merge_split_event e
         CROSS APPLY grac_practice.fn_asset_merge_critical(@organization_id, @event_id) c
         WHERE e.event_id = @event_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE IF @action = N'CANCEL'
    BEGIN
        UPDATE grac_practice.asset_merge_split_event SET status = N'CANCELLED', decided_note = @note, closed_dt = SYSUTCDATETIME()
         WHERE event_id = @event_id;
        SET @result = N'CANCELLED';
    END
    ELSE IF @action IN (N'APPROVE', N'REJECT')
    BEGIN
        INSERT grac_practice.asset_merge_split_approval (event_id, decision, note, approver, approver_employee_id)
        VALUES (@event_id, @action, @note, @actor, @actor_employee_id);
        SET @approvals = (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval WHERE event_id = @event_id AND decision = N'APPROVE');
        IF @action = N'REJECT'
        BEGIN
            UPDATE grac_practice.asset_merge_split_event SET status = N'REJECTED', decided_note = @note, closed_dt = SYSUTCDATETIME()
             WHERE event_id = @event_id;
            SET @result = N'REJECTED';
        END
        ELSE IF @approvals >= @required
        BEGIN
            UPDATE grac_practice.asset_merge_split_event SET status = N'APPROVED' WHERE event_id = @event_id;
            SET @result = N'APPROVED';
        END
        ELSE
            SET @result = N'FIRST_APPROVAL';
    END
    ELSE IF @action = N'EXECUTE'
    BEGIN
        DECLARE @dup BIGINT;
        IF @kind = N'SPLIT'   -- 445
            EXEC grac_practice.sp_asset_split_execute @organization_id = @organization_id, @event_id = @event_id,   -- 445
                 @actor_employee_id = @actor_employee_id, @actor = @actor;   -- 445
        DECLARE dup_cur CURSOR LOCAL STATIC FOR
            SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id AND @kind = N'MERGE' ORDER BY sequence_no;   -- 445
        OPEN dup_cur;
        FETCH NEXT FROM dup_cur INTO @dup;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC grac_practice.sp_asset_merge_execute_one
                 @organization_id = @organization_id, @event_id = @event_id, @survivor = @survivor, @duplicate = @dup,
                 @field_choices_json = @choices, @actor_employee_id = @actor_employee_id, @actor = @actor;
            FETCH NEXT FROM dup_cur INTO @dup;
        END
        CLOSE dup_cur;
        DEALLOCATE dup_cur;
        UPDATE grac_practice.asset_merge_split_event
           SET status = N'EXECUTED', executed_by = @actor, executed_dt = SYSUTCDATETIME(), closed_dt = SYSUTCDATETIME()
         WHERE event_id = @event_id;
        SET @result = N'EXECUTED';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_merge_recover
             @organization_id = @organization_id, @event_id = @event_id, @note = @note,
             @actor_employee_id = @actor_employee_id, @actor = @actor;
        UPDATE grac_practice.asset_merge_split_event
           SET status = N'RECOVERED', recovered_by = @actor, recovered_dt = SYSUTCDATETIME(), recovery_reason = @note
         WHERE event_id = @event_id;
        SET @result = N'RECOVERED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (CASE WHEN @kind = N'SPLIT' THEN N'asset-split' ELSE N'asset-merge' END, @event_id, @action,   -- 445
            (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),   -- 445
            (SELECT @result AS result, @note AS note,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object WHERE event_id = @event_id) AS outcomes,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object WHERE event_id = @event_id AND recovered = 1) AS recovered
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @event_id AS EventId, @result AS Result;
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_events
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,   -- 445
    @event_kind      NVARCHAR(10)  = N'MERGE'   -- 445
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT e.event_id AS EventId, e.status AS Status, e.survivor_asset_id AS SurvivorAssetId, s.asset_name AS SurvivorName,
           d.names AS DuplicateNames, d.cnt AS DuplicateCount, e.is_critical AS IsCritical, e.approvals_required AS ApprovalsRequired,
           (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval p WHERE p.event_id = e.event_id AND p.decision = N'APPROVE') AS Approvals,
           e.reason AS Reason, e.requested_by AS RequestedBy, e.requested_dt AS RequestedDt, e.executed_dt AS ExecutedDt,
           e.recovered_dt AS RecoveredDt, e.closed_dt AS ClosedDt, CONVERT(BIGINT, e.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_merge_split_event e
      JOIN grac_practice.organization_dependency_asset s ON s.asset_id = e.survivor_asset_id
     CROSS APPLY (SELECT COUNT(*) AS cnt, LEFT(STRING_AGG(CAST(a.asset_name AS NVARCHAR(MAX)), N', '), 600) AS names
                    FROM grac_practice.asset_merge_split_member m
                    JOIN grac_practice.organization_dependency_asset a ON a.asset_id = m.asset_id
                   WHERE m.event_id = e.event_id) d
     WHERE e.organization_id = @organization_id AND e.event_kind = ISNULL(@event_kind, N'MERGE')   -- 445
       AND ((@status IS NULL AND e.status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED')) OR @status = N'ALL' OR e.status = @status)
       AND (@search IS NULL OR s.asset_name LIKE N'%' + @search + N'%' OR d.names LIKE N'%' + @search + N'%')
     ORDER BY e.event_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '445: 444 recovery, action and list re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '445-a allocation table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_split_allocation','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asplit_alloc') THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '445-b split objects present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_split_plan') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_split_blockers') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_merge_split_move', 'sp_asset_split_save', 'sp_asset_split_execute', 'sp_asset_split_get')) = 4
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '445-c 444 procedures re-issued (shared moves, both kinds, split recovery, kind filter)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_execute_one')) LIKE '%sp_asset_merge_split_move%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_action')) LIKE '%sp_asset_split_execute%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_recover')) LIKE '%@after IS NULL%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_events')) LIKE '%@event_kind%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '445-d split plan and blockers run',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_asset_split_plan(-1, -1)) = 0
             AND (SELECT COUNT(*) FROM grac_practice.fn_asset_split_blockers(-1, -1)) = 0
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs: asset S that really is two devices (two discovery source records,
--   relationships, a risk mapping, a serial number belonging to the second
--   device); users R (asset-discovery EDIT + asset-register ADD / EDIT), A1
--   and A2 (asset-discovery APPROVE).
--   1. Asset Register: register the second device as a new Draft asset N
--      (its own form, identity and mandatory fields).
--   2. Asset Discovery -> Splits -> New split: source S, resulting record N,
--      reason; save. The window lists every item of S: allocate the second
--      source record, one relationship and the risk mapping to N, and the
--      serial number (Move) and location fields (Copy); save again. Impact
--      shows both assets; blockers are empty.
--   3. A resulting record that is not Draft, or an open workflow case on S
--      -> Submit refused with the reason.
--   4. Submit; A1 approves (two approvers when S is Critical); R executes:
--      outcomes per object (moved / kept), the serial is on N and no longer
--      on S, the location on both; S keeps its ID, history and the
--      unallocated items. A relationship between S and N allocated to N is
--      kept (it would refer to N itself).
--   5. A1 recovers (note): the items go back to S, the serial returns to S
--      and is removed from N where unchanged; the event keeps its rows.
--   6. Merges keep working as in 444 (they now call the shared moves).
-- =====================================================================
