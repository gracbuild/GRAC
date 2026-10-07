-- =====================================================================
-- 440 rollback -- CMDB relationships
--
--   * removes the Asset Relationships menu row and its grants;
--   * restores sp_asset_lifecycle_transition (435 body) verbatim -- the
--     retirement gate goes;
--   * drops the relationship procedures and functions, the history,
--     relationship and relationship-type tables.
-- practice_audit_trace rows stay as history. Deploy the API / Web without
-- the 440 changes first. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-relationships';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-relationships';
PRINT '440 rollback: menu row removed.';
GO

-- 435 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_transition
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_change_id           BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54970, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @from NVARCHAR(60), @template_id BIGINT, @owner_id BIGINT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, a.record_version), @from = COALESCE(cs.status_code, ls.status_code),
           @template_id = a.template_id, @owner_id = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54973, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    IF @from IN (N'DISPOSED', N'ARCHIVED') AND @to_status_code = N'ACTIVE'
        THROW 54975, 'A disposed or archived asset cannot return to Active (BRD 5.4.3 / 19.9). Register a replacement asset instead.', 1;

    DECLARE @rule_id INT, @req_reason BIT, @req_approval BIT, @ref_label NVARCHAR(200), @req_evidence BIT,
            @req_form BIT, @req_owner BIT;
    SELECT TOP 1 @rule_id = r.transition_rule_id, @req_reason = r.requires_reason, @req_approval = r.requires_approval,
           @ref_label = g.reference_label, @req_evidence = g.requires_evidence, @req_form = g.requires_registered_form,
           @req_owner = g.requires_owner
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule_id IS NULL
    BEGIN
        DECLARE @allowed NVARCHAR(1000) = (
            SELECT STRING_AGG(s.status_name, N', ') WITHIN GROUP (ORDER BY s.display_order)
              FROM grac_practice.entity_state_transition_rule r
              JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
              JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
             WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL AND r.from_status_code = @from);
        DECLARE @from_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                             WHERE entity_type = N'Asset' AND status_code = @from);
        DECLARE @target_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                               WHERE entity_type = N'Asset' AND status_code = @to_status_code);
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'This asset cannot move from ', ISNULL(@from_name, @from), N' to ',
            ISNULL(@target_name, @to_status_code), N'. Configured moves: ', ISNULL(@allowed, N'none'), N'.');
        THROW 54974, @msg, 1;
    END

    IF @req_form = 1 AND @template_id IS NULL
        THROW 54979, 'Open the asset and save it on its form template first, so its required fields are validated.', 1;
    IF @req_owner = 1 AND @owner_id IS NULL
        THROW 54980, 'Set the asset owner first (identity, owner and source validation).', 1;
    IF @req_reason = 1 AND @reason_text IS NULL
        THROW 54976, 'A reason is required for this change.', 1;
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N'.');
        THROW 54977, @ref_msg, 1;
    END
    IF @req_evidence = 1 AND @evidence_text IS NULL
        THROW 54978, 'Evidence is required for this change (document number, report or link).', 1;
    -- 435: required coverage configured to block activation (5.2.14, D42).
    IF @to_status_code = N'ACTIVE'
    BEGIN
        DECLARE @gaps NVARCHAR(1000) = (SELECT STRING_AGG(g.CoverageTypeLabel, N', ')
                                          FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g
                                         WHERE g.AssetId = @asset_id AND g.MissingAction = N'BLOCK_ACTIVATION');
        IF @gaps IS NOT NULL
        BEGIN
            DECLARE @gap_msg NVARCHAR(1200) = CONCAT(N'The asset cannot become Active without its required coverage: ', @gaps,
                                                     N'. Map it on an active contract (Contracts) first.');
            THROW 54560, @gap_msg, 1;
        END
    END

    DECLARE @log_id BIGINT;
    BEGIN TRAN;
    IF @req_approval = 1
    BEGIN
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'PENDING_APPROVAL',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to_status_code,
             @reason_code = N'LIFECYCLE', @reason_text = @reason_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'COMPLETED',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id, @log_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'COMPLETED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, CASE WHEN @req_approval = 1 THEN N'REQUEST' ELSE N'TRANSITION' END,
            (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @out_change_id AS changeId, @to_status_code AS toStatusCode, @out_result AS result,
                    @reason_text AS reason, @reference_text AS reference, @evidence_text AS evidence, @log_id AS transitionLogId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_change_id AS ChangeId, @out_result AS Result,
           CASE WHEN @out_result = N'COMPLETED' THEN @to_status_code ELSE @from END AS StatusCode;
END
GO
PRINT '440 rollback: sp_asset_lifecycle_transition restored.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationships;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_ci_lookup;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_config_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_ci_impact;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_sync;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_history_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_relationship_check;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_relationship_blockers;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_relationship_edges;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ci_catalog;
PRINT '440 rollback: procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_relationship_history;
DROP TABLE IF EXISTS grac_practice.asset_relationship;
DROP TABLE IF EXISTS grac_practice.asset_relationship_type;
PRINT '440 rollback: tables dropped.';
GO

SELECT '440 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_relationship','U') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) NOT LIKE '%THROW 54719%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) LIKE '%THROW 54560%'
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-relationships')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
