-- =====================================================================
-- 443 ROLLBACK  Discovery follow-up (candidate registration, stale review)
-- =====================================================================
-- Restores the 442 body of sp_asset_reconciliation_resolve (no REGISTER
-- action), drops the 443 readers, writers, functions and tables. Stale
-- review history and the aging rule are lost; exceptions already closed as
-- REGISTERED keep that resolution text; lifecycle changes requested from a
-- review stay (they belong to the Asset Register).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_reconciliation_resolve
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @action                  NVARCHAR(20),
    @asset_id                BIGINT         = NULL,
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
    DECLARE @found BIT = 0, @kind NVARCHAR(16), @status NVARCHAR(10), @rv BIGINT, @obs BIGINT, @source BIGINT, @key NVARCHAR(200),
            @exc_asset BIGINT, @other BIGINT, @field NVARCHAR(100), @observed NVARCHAR(400), @score INT, @payload NVARCHAR(MAX);
    SELECT @found = 1, @kind = e.exception_kind, @status = e.status, @rv = CONVERT(BIGINT, e.record_version), @obs = e.observation_id,
           @source = e.source_id, @key = e.external_key, @exc_asset = e.asset_id, @other = e.other_asset_id, @field = e.field_key,
           @observed = e.observed_value, @score = e.match_score, @payload = o.payload_json
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
     WHERE e.exception_id = @exception_id AND e.organization_id = @organization_id;
    IF @found = 0 THROW 54773, 'Reconciliation exception not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54774, 'The exception was changed by someone else; reload it and try again.', 1;
    IF @status <> N'OPEN' THROW 54775, 'This exception is already resolved.', 1;
    IF NOT ((@kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE') AND @action IN (N'LINK', N'IGNORE'))
         OR (@kind = N'DUPLICATE' AND @action IN (N'LINK', N'NOT_DUPLICATE', N'IGNORE'))
         OR (@kind = N'CONFLICT' AND @action IN (N'ACCEPT_OBSERVED', N'KEEP_CURRENT')))
        THROW 54776, 'That action is not available for this exception.', 1;
    IF @action IN (N'IGNORE', N'NOT_DUPLICATE', N'KEEP_CURRENT') AND @note IS NULL
        THROW 54778, 'Record the reason in the note.', 1;
    IF @action = N'LINK'
    BEGIN
        SET @asset_id = COALESCE(@asset_id, CASE WHEN @kind = N'SUGGESTED_MATCH' THEN @exc_asset END);
        IF @asset_id IS NULL OR (@kind = N'DUPLICATE' AND @asset_id NOT IN (@exc_asset, @other))
           OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                            LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                           WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id
                             AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DISPOSED', N'ARCHIVED'))
            THROW 54777, 'Select the register asset to link (for a duplicate, one of the two assets).', 1;
        IF @payload IS NULL
            THROW 54776, 'The observation details are past their retention; wait for the next observation of this record.', 1;
    END
    IF @action = N'ACCEPT_OBSERVED' AND @payload IS NULL AND @observed IS NULL
        THROW 54776, 'The observed value is no longer available.', 1;

    DECLARE @upd INT, @conf INT, @result NVARCHAR(20) = @action;
    BEGIN TRAN;
    IF @action = N'LINK'
    BEGIN
        EXEC grac_practice.sp_asset_discovery_apply @observation_id = @obs, @asset_id = @asset_id, @link_method = N'CONFIRMED',
             @match_score = @score, @actor = @actor, @out_updated = @upd OUTPUT, @out_conflicts = @conf OUTPUT;
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = N'LINKED', resolution_note = ISNULL(@note, CONCAT(N'Linked to asset ', @asset_id, N'.')),
               resolved_by = @actor, resolved_dt = SYSUTCDATETIME(), asset_id = @asset_id, updated_dt = SYSUTCDATETIME()
         WHERE status = N'OPEN' AND exception_kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE', N'DUPLICATE')
           AND (exception_id = @exception_id OR (@key IS NOT NULL AND source_id = @source AND external_key = @key));
        UPDATE grac_practice.asset_discovery_observation
           SET matched_asset_id = @asset_id,
               result_text = LEFT(CONCAT(result_text, N' Linked by ', @actor, N': ', @upd, N' field(s) updated, ', @conf, N' conflict(s).'), 1000)
         WHERE observation_id = @obs;
    END
    ELSE IF @action = N'ACCEPT_OBSERVED'
    BEGIN
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @exc_asset, @field_key = @field, @value = @observed, @actor = @actor;
        UPDATE grac_practice.asset_attribute_source SET applied = 1 WHERE asset_id = @exc_asset AND field_key = @field AND source_id = @source;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-register', @exc_asset, N'DISCOVERY', NULL,
                (SELECT @exception_id AS exceptionId, @field AS fieldKey, @observed AS acceptedValue FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    END
    ELSE IF @action = N'NOT_DUPLICATE'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_duplicate_decision
                        WHERE asset_id_low = CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END
                          AND asset_id_high = CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END)
            INSERT grac_practice.asset_duplicate_decision (asset_id_low, asset_id_high, note, decided_by)
            VALUES (CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END,
                    CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END, @note, @actor);
    END
    IF @action <> N'LINK'
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = @action, resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
               updated_dt = SYSUTCDATETIME()
         WHERE exception_id = @exception_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-reconciliation-exception', @exception_id, @action, N'{"status":"OPEN"}',
            (SELECT @action AS resolution, @asset_id AS assetId, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @exception_id AS ExceptionId, @result AS Result;
END
GO
PRINT '443 rollback: sp_asset_reconciliation_resolve restored (442).';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_discovery_candidate_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_stale_review_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_stale_reviews;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_stale_review_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_stale_review_open;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_stale_setting_save;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_stale_dependencies;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_stale_state;
GO
DROP TABLE IF EXISTS grac_practice.asset_stale_review;
DROP TABLE IF EXISTS grac_practice.asset_stale_setting;
GO
PRINT '443 rollback: objects dropped.';
GO

SELECT '443 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_stale_review','U') IS NULL
             AND OBJECT_ID('grac_practice.asset_stale_setting','U') IS NULL
             AND OBJECT_ID('grac_practice.fn_asset_stale_state') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_stale_review_action','P') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_reconciliation_resolve')) NOT LIKE '%N''REGISTER''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
