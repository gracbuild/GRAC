-- =====================================================================
-- 445 ROLLBACK  Asset split
-- =====================================================================
-- Restores the 444 bodies of sp_asset_merge_execute_one,
-- sp_asset_merge_recover, sp_asset_merge_action and sp_asset_merge_events,
-- drops the split objects and the shared move procedure. Split events
-- stay in the 444 tables (kind SPLIT) but cannot be acted on; recover
-- executed splits first.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

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
    DECLARE @plan TABLE (object_kind NVARCHAR(20) NOT NULL, object_id BIGINT NULL, object_key NVARCHAR(200) NULL,
                         object_label NVARCHAR(400) NULL, outcome NVARCHAR(10) NOT NULL, detail NVARCHAR(600) NULL);
    INSERT @plan (object_kind, object_id, object_key, object_label, outcome, detail)
    SELECT ObjectKind, ObjectId, ObjectKey, ObjectLabel, Outcome, Detail
      FROM grac_practice.fn_asset_merge_plan(@organization_id, @survivor, @duplicate);
    IF EXISTS (SELECT 1 FROM @plan WHERE outcome = N'BLOCK')
       OR EXISTS (SELECT 1 FROM grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, @duplicate))
        THROW 52908, 'The merge has blockers; open it to see them.', 1;
    DECLARE @survivor_name NVARCHAR(300) = (SELECT asset_name FROM grac_practice.organization_dependency_asset WHERE asset_id = @survivor);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE), @note NVARCHAR(400) = CONCAT(N'Merge #', @event_id, N': asset #', @duplicate,
                                                                                    N' merged into #', @survivor, N'.');

    -- ---------------------------------------------------------- relationships
    DECLARE @rid BIGINT, @rout NVARCHAR(10);
    DECLARE rel_cur CURSOR LOCAL STATIC FOR
        SELECT object_id, outcome FROM @plan WHERE object_kind = N'RELATIONSHIP' ORDER BY object_id;
    OPEN rel_cur;
    FETCH NEXT FROM rel_cur INTO @rid, @rout;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rout = N'MOVE'
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @duplicate, @survivor, N'MOVED',
                   (SELECT r.source_id AS sourceId, r.target_id AS targetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   (SELECT CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @duplicate THEN @survivor ELSE r.source_id END AS sourceId,
                           CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @duplicate THEN @survivor ELSE r.target_id END AS targetId
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
              FROM grac_practice.asset_relationship r JOIN @plan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
             WHERE r.relationship_id = @rid;
            UPDATE grac_practice.asset_relationship
               SET source_id = CASE WHEN source_kind = N'ASSET' AND source_id = @duplicate THEN @survivor ELSE source_id END,
                   target_id = CASE WHEN target_kind = N'ASSET' AND target_id = @duplicate THEN @survivor ELSE target_id END,
                   version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @rid;
            EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'MERGE_MOVE', @note = @note,
                 @actor = @actor, @actor_employee_id = @actor_employee_id;
        END
        ELSE
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @duplicate, @survivor, N'ENDED',
                   (SELECT r.status AS status, r.effective_to AS effectiveTo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   N'{"status":"RETIRED"}', p.detail
              FROM grac_practice.asset_relationship r JOIN @plan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
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
    SELECT @event_id, N'DISCOVERY_LINK', p.object_id, p.object_key, p.object_label, @duplicate, @survivor, N'MOVED', p.detail
      FROM @plan p WHERE p.object_kind = N'DISCOVERY_LINK';
    UPDATE l SET asset_id = @survivor
      FROM grac_practice.asset_discovery_link l JOIN @plan p ON p.object_kind = N'DISCOVERY_LINK' AND p.object_id = l.link_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'ATTRIBUTE_SOURCE', p.object_id, p.object_key, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM @plan p WHERE p.object_kind = N'ATTRIBUTE_SOURCE';
    UPDATE x SET asset_id = @survivor
      FROM grac_practice.asset_attribute_source x
      JOIN @plan p ON p.object_kind = N'ATTRIBUTE_SOURCE' AND p.outcome = N'MOVE' AND p.object_id = x.source_id AND p.object_key = x.field_key
     WHERE x.asset_id = @duplicate;

    -- ---------------------------------------------------------- open reconciliation exceptions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, detail)
    SELECT @event_id, N'RECON_EXCEPTION', e.exception_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'RESOLVE' THEN N'RESOLVED' ELSE N'MOVED' END,
           (SELECT e.asset_id AS assetId, e.other_asset_id AS otherAssetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.object_id = e.exception_id;
    UPDATE e
       SET status = N'RESOLVED', resolution = N'MERGED', resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'RESOLVE'
                                                                      AND p.object_id = e.exception_id;
    UPDATE e
       SET asset_id = CASE WHEN e.asset_id = @duplicate THEN @survivor ELSE e.asset_id END,
           other_asset_id = CASE WHEN e.other_asset_id = @duplicate THEN @survivor ELSE e.other_asset_id END,
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'MOVE'
                                                                      AND p.object_id = e.exception_id;

    -- ---------------------------------------------------------- coverage, occurrences, restrictive reviews
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, p.object_kind, p.object_id, p.object_key, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM @plan p WHERE p.object_kind IN (N'COVERAGE', N'OCCURRENCE', N'RESTRICTIVE_REVIEW');
    UPDATE c SET asset_id = @survivor
      FROM grac_practice.asset_contract_coverage c JOIN @plan p ON p.object_kind = N'COVERAGE' AND p.outcome = N'MOVE' AND p.object_id = c.coverage_id;
    UPDATE o SET asset_id = @survivor, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o JOIN @plan p ON p.object_kind = N'OCCURRENCE' AND p.outcome = N'MOVE' AND p.object_id = o.occurrence_id;
    UPDATE r SET asset_id = @survivor
      FROM grac_practice.asset_restrictive_review r JOIN @plan p ON p.object_kind = N'RESTRICTIVE_REVIEW' AND p.outcome = N'MOVE' AND p.object_id = r.review_id;

    -- ---------------------------------------------------------- risks and practice resolutions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'RISK_MAP', m.risk_dependency_map_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, m.dependency_object_name,
           CASE p.outcome WHEN N'MOVE' THEN @survivor_name END, p.detail
      FROM grac_practice.risk_dependency_map m JOIN @plan p ON p.object_kind = N'RISK_MAP' AND p.object_id = m.risk_dependency_map_id;
    UPDATE m SET dependency_object_id = @survivor, dependency_object_name = @survivor_name, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.risk_dependency_map m JOIN @plan p ON p.object_kind = N'RISK_MAP' AND p.outcome = N'MOVE' AND p.object_id = m.risk_dependency_map_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'RISK_LINK', p.object_id, p.object_label, @duplicate, @survivor, N'MOVED', p.detail
      FROM @plan p WHERE p.object_kind = N'RISK_LINK';
    UPDATE r SET linked_asset_id = @survivor
      FROM grac_practice.risk_register r JOIN @plan p ON p.object_kind = N'RISK_LINK' AND p.object_id = r.risk_register_id;

    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'PRACTICE_RESOLUTION', d.resolution_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, d.resolved_dependency_name,
           CASE p.outcome WHEN N'MOVE' THEN LEFT(@survivor_name, 300) END, p.detail
      FROM grac_practice.practice_dependency_resolution d JOIN @plan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.object_id = d.resolution_id;
    UPDATE d SET resolved_dependency_id = @survivor, resolved_dependency_name = LEFT(@survivor_name, 300), updated_by = @actor,
                 updated_dt = SYSUTCDATETIME()
      FROM grac_practice.practice_dependency_resolution d JOIN @plan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.outcome = N'MOVE'
                                                                     AND p.object_id = d.resolution_id;

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
            IF EXISTS (SELECT 1 FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid AND value_text = @after)
            BEGIN
                IF @before IS NULL
                BEGIN
                    DELETE FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid;
                END
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
            @requested_by NVARCHAR(100), @requested_emp BIGINT, @required INT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @survivor = survivor_asset_id, @reason = reason,
           @choices = field_choices_json, @requested_by = requested_by, @requested_emp = requested_by_employee_id,
           @required = approvals_required
      FROM grac_practice.asset_merge_split_event
     WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'MERGE';
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
               preview_json = (SELECT p.ObjectKind AS kind, p.Outcome AS outcome, COUNT(*) AS items
                                 FROM grac_practice.asset_merge_split_member m
                                CROSS APPLY grac_practice.fn_asset_merge_plan(@organization_id, @survivor, m.asset_id) p
                                WHERE m.event_id = @event_id
                                GROUP BY p.ObjectKind, p.Outcome FOR JSON PATH)
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
        DECLARE dup_cur CURSOR LOCAL STATIC FOR
            SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id ORDER BY sequence_no;
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
    VALUES (N'asset-merge', @event_id, @action, (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
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
    @page_size       INT           = 25
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
     WHERE e.organization_id = @organization_id AND e.event_kind = N'MERGE'
       AND ((@status IS NULL AND e.status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED')) OR @status = N'ALL' OR e.status = @status)
       AND (@search IS NULL OR s.asset_name LIKE N'%' + @search + N'%' OR d.names LIKE N'%' + @search + N'%')
     ORDER BY e.event_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '445 rollback: 444 procedures restored.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_split_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_split_execute;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_split_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_split_move;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_split_blockers;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_split_plan;
GO
DROP TABLE IF EXISTS grac_practice.asset_split_allocation;
GO
PRINT '445 rollback: split objects dropped.';
GO

SELECT '445 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_split_allocation','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_merge_split_move','P') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_execute_one')) NOT LIKE '%sp_asset_merge_split_move%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_merge_events')) NOT LIKE '%@event_kind%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
