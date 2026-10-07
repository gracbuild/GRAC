-- =====================================================================
-- 437 rollback -- Notification profiles, reminders and escalation;
--                 scheduler pass
--
--   * removes the Asset Notifications menu row and its grants;
--   * restores sp_asset_attestation_generate (431 body) and
--     sp_asset_contract_renewal_start (436 body) verbatim;
--   * drops the scheduler, notification procedures and functions;
--   * drops asset_notification_outbox, asset_notification_occurrence,
--     asset_scheduler_run, asset_escalation_matrix,
--     asset_notification_stage_recipient, asset_notification_stage,
--     asset_notification_profile and the 437 catalogues (every profile,
--     occurrence and notification record is lost).
-- Renewal occurrences and attestations the scheduler created stay (they are
-- ordinary 436 / 431 records). practice_audit_trace rows stay as history.
-- Deploy the API without the 437 changes first (the worker calls
-- sp_asset_scheduler_run). Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-notifications';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-notifications';
PRINT '437 rollback: menu row removed.';
GO

-- 431 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_generate
    @organization_id BIGINT,
    @campaign_type   NVARCHAR(20)  = N'PERIODIC',
    @campaign_name   NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @due_date        DATE          = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @campaign_type = UPPER(LTRIM(RTRIM(ISNULL(@campaign_type, N''))));
    SET @campaign_name = NULLIF(LTRIM(RTRIM(@campaign_name)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54350, 'Organization not found.', 1;
    IF @campaign_type NOT IN (N'PERIODIC', N'CAMPAIGN')
        THROW 54372, 'The run must be PERIODIC or CAMPAIGN.', 1;
    IF @campaign_type = N'CAMPAIGN' AND (@campaign_name IS NULL OR @due_date IS NULL OR @due_date < @today)
        THROW 54371, 'A campaign needs a name and a due date that is not in the past.', 1;
    IF @campaign_name IS NULL SET @campaign_name = CONCAT(N'Periodic attestation run ', CONVERT(NVARCHAR(10), @today, 23));

    DECLARE @overdue INT, @campaign_id BIGINT, @generated INT = 0, @skipped INT = 0;
    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET status = N'OVERDUE', updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id AND status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND due_date < @today;
    SET @overdue = @@ROWCOUNT;
    INSERT grac_practice.asset_attestation_campaign (organization_id, campaign_type, campaign_name, asset_type_id, due_date, overdue_marked, entered_by)
    VALUES (@organization_id, @campaign_type, @campaign_name, @asset_type_id, @due_date, @overdue, @actor);
    SET @campaign_id = SCOPE_IDENTITY();

    -- Applicable assets: a profile requiring attestation; not in acquisition, not lost / stolen, not retired (D24).
    DECLARE @work TABLE (asset_id BIGINT NOT NULL, role_code NVARCHAR(20) NOT NULL, due DATE NOT NULL, occ_key NVARCHAR(200) NOT NULL);
    INSERT @work (asset_id, role_code, due, occ_key)
    SELECT a.asset_id, r.role_code,
           CASE WHEN @campaign_type = N'CAMPAIGN' THEN @due_date
                WHEN st.next_attestation_date IS NULL THEN DATEADD(DAY, p.DueWindowDays, @today)
                WHEN st.next_attestation_date < @today THEN @today ELSE st.next_attestation_date END,
           CASE WHEN @campaign_type = N'CAMPAIGN' THEN CONCAT(N'CAMPAIGN:', @campaign_id, N':', a.asset_id, N':', r.role_code)
                ELSE CONCAT(N'PERIODIC:', a.asset_id, N':', r.role_code, N':',
                            ISNULL(CONVERT(NVARCHAR(10), st.next_attestation_date, 112), N'FIRST')) END
      FROM grac_practice.organization_dependency_asset a
      CROSS APPLY grac_practice.fn_asset_attestation_profile_for(@organization_id, a.asset_id) p
      JOIN (VALUES (N'CUSTODIAN'), (N'OWNER')) r(role_code)
        ON (r.role_code = N'CUSTODIAN' AND p.Participant IN (N'CUSTODIAN', N'BOTH'))
        OR (r.role_code = N'OWNER' AND p.Participant IN (N'OWNER', N'BOTH'))
      LEFT JOIN grac_practice.asset_attestation_state st ON st.asset_id = a.asset_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @organization_id AND p.AttestationRequired = 1
       AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED')
       AND (@campaign_type = N'CAMPAIGN' OR st.next_attestation_date IS NULL
            OR st.next_attestation_date <= DATEADD(DAY, p.DueWindowDays, @today));

    DECLARE @w_asset BIGINT, @w_role NVARCHAR(20), @w_due DATE, @w_key NVARCHAR(200), @att BIGINT, @skip NVARCHAR(100),
            @type NVARCHAR(20) = CASE WHEN @campaign_type = N'CAMPAIGN' THEN N'CAMPAIGN' ELSE N'PERIODIC' END;
    DECLARE work_cur CURSOR LOCAL FAST_FORWARD FOR SELECT asset_id, role_code, due, occ_key FROM @work;
    OPEN work_cur;
    FETCH NEXT FROM work_cur INTO @w_asset, @w_role, @w_due, @w_key;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_asset_attestation_create
             @organization_id = @organization_id, @asset_id = @w_asset, @attestation_type = @type,
             @assignee_role = @w_role, @occurrence_key = @w_key, @due_date = @w_due, @campaign_id = @campaign_id,
             @actor = @actor, @out_attestation_id = @att OUTPUT, @out_skip_reason = @skip OUTPUT;
        IF @att IS NULL SET @skipped = @skipped + 1; ELSE SET @generated = @generated + 1;
        FETCH NEXT FROM work_cur INTO @w_asset, @w_role, @w_due, @w_key;
    END
    CLOSE work_cur;
    DEALLOCATE work_cur;

    UPDATE grac_practice.asset_attestation_campaign
       SET generated_count = @generated, skipped_count = @skipped
     WHERE campaign_id = @campaign_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation-campaign', @campaign_id, N'GENERATE', NULL,
            (SELECT @campaign_type AS campaignType, @campaign_name AS campaignName, @asset_type_id AS assetTypeId, @due_date AS dueDate,
                    @generated AS generated, @skipped AS skipped, @overdue AS overdueMarked FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @campaign_id AS CampaignId, @generated AS Generated, @skipped AS Skipped, @overdue AS OverdueMarked;
END
GO
PRINT '437 rollback: sp_asset_attestation_generate restored.';
GO

-- 436 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_start
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @renewal_type      NVARCHAR(20)   = N'RENEWAL',
    @notes             NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @renewal_type = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@renewal_type)), N''), N'RENEWAL'));
    SET @notes = NULLIF(LTRIM(RTRIM(@notes)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54570, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id)
        THROW 54571, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id, @actor = @actor;

    DECLARE @cstatus NVARCHAR(20), @number NVARCHAR(60), @prior BIGINT;
    SELECT @cstatus = contract_status, @number = contract_number, @prior = current_version_id
      FROM grac_practice.asset_contract WHERE contract_id = @contract_id;
    IF @cstatus = N'TERMINATED'
        THROW 54591, 'The contract is terminated; it cannot be renewed.', 1;
    IF @renewal_type NOT IN (N'RENEWAL', N'EXTENSION', N'REBID', N'REPLACEMENT', N'NON_RENEWAL')
        THROW 54577, 'Select the renewal type: renewal, extension, rebid, replacement or non-renewal.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND is_open = 1)
        THROW 54572, 'The contract already has an open renewal; finish or cancel it first.', 1;
    DECLARE @pno INT, @pend DATE, @notice DATE, @decision DATE;
    SELECT @pno = v.version_no, @pend = v.effective_end, @notice = v.notice_date, @decision = v.decision_date
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @prior AND s.status_code IN (N'APPROVED', N'ACTIVE', N'EXPIRED', N'SUPERSEDED') AND v.version_type <> N'TERMINATION';
    IF @pno IS NULL
        THROW 54573, 'The contract has no approved version to renew yet.', 1;

    -- 9.1.5: the earliest of notice date, decision date and end minus the expiring window (435).
    DECLARE @win INT = ISNULL((SELECT expiring_window_days FROM grac_practice.asset_coverage_settings WHERE organization_id = @organization_id), 30);
    DECLARE @due DATE = (SELECT MIN(x.d) FROM (VALUES (DATEADD(DAY, -@win, @pend)), (@notice), (@decision)) x(d));
    DECLARE @seq INT = 1 + (SELECT COUNT(*) FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND prior_version_id = @prior);
    DECLARE @key NVARCHAR(120) = CONCAT(N'CR-', @number, N'-V', @pno, N'-', @seq);
    DECLARE @id BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_contract_renewal
        (organization_id, contract_id, occurrence_key, prior_version_id, renewal_type, current_status_id, is_open, due_date, old_expiry,
         notes, started_by_employee_id, entered_by)
    VALUES (@organization_id, @contract_id, @key, @prior, @renewal_type,
            grac_practice.fn_get_entity_status_id(N'ContractRenewal', N'OPEN'), 1, @due, @pend, @notes, @actor_employee_id, @actor);
    SET @id = SCOPE_IDENTITY();
    EXEC grac_practice.sp_asset_contract_renewal_move @renewal_id = @id, @from_code = NULL, @to_code = N'OPEN',
         @reason_code = @renewal_type, @reason_text = @notes, @actor_employee_id = @actor_employee_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal', @id, N'CREATE', NULL,
            (SELECT @contract_id AS contractId, @key AS occurrenceKey, @prior AS priorVersionId, @renewal_type AS renewalType,
                    @due AS dueDate, @pend AS oldExpiry FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS RenewalId, N'OPEN' AS Result;
END
GO
PRINT '437 rollback: sp_asset_contract_renewal_start restored.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_mine_read_all;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_mine_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_mine_counts;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_mine;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_scheduler_runs;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_delivery;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_log;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_occurrence_snooze;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_occurrence_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_occurrence_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_escalation_matrix_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_profile_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_config_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_scheduler_run;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_sweep;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_parties;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_notification_defaults_ensure;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ntf_profile_for;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ntf_stage_date;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ntf_contract_activity;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ntf_version_severity;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_ntf_asset_severity;
PRINT '437 rollback: procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_notification_outbox;
DROP TABLE IF EXISTS grac_practice.asset_notification_occurrence;
DROP TABLE IF EXISTS grac_practice.asset_scheduler_run;
DROP TABLE IF EXISTS grac_practice.asset_escalation_matrix;
DROP TABLE IF EXISTS grac_practice.asset_notification_stage_recipient;
DROP TABLE IF EXISTS grac_practice.asset_notification_stage;
DROP TABLE IF EXISTS grac_practice.asset_notification_profile;
DROP TABLE IF EXISTS grac_practice.asset_escalation_matrix_default;
DROP TABLE IF EXISTS grac_practice.asset_notification_default_recipient;
DROP TABLE IF EXISTS grac_practice.asset_notification_default_stage;
DROP TABLE IF EXISTS grac_practice.asset_notification_recipient_type;
DROP TABLE IF EXISTS grac_practice.asset_notification_activity;
PRINT '437 rollback: tables removed.';
GO

SELECT '437 rollback complete' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_notification_outbox','U') IS NULL
             AND OBJECT_ID('grac_practice.asset_notification_profile','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_scheduler_run','P') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_renewal_start')) NOT LIKE '%@out_renewal_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_attestation_generate')) NOT LIKE '%@scheduled%'
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-notifications')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
