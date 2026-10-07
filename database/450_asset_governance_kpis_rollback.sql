-- =====================================================================
-- 450 ROLLBACK  Asset governance KPIs
-- =====================================================================
-- Restores sp_asset_scheduler_run (448 body); drops the 450 procedures,
-- functions and tables (settings, relationship requirements and every
-- snapshot are lost) and the Asset Governance menu row and its grants.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_scheduler_run
    @organization_id BIGINT        = NULL,
    @trigger_code    NVARCHAR(12)  = N'SCHEDULED',
    @actor           NVARCHAR(100) = N'scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @trigger_code = CASE WHEN UPPER(ISNULL(@trigger_code, N'')) = N'MANUAL' THEN N'MANUAL' ELSE N'SCHEDULED' END;
    IF @organization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.asset_scheduler', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS RunId, N'SKIPPED' AS Result, 0 AS Organizations, 0 AS RenewalsStarted,
               0 AS AttestationsGenerated, 0 AS OccurrencesOpened, 0 AS OccurrencesClosed, 0 AS NotificationsQueued,
               0 AS ErrorCount, N'Another scheduler run is in progress.' AS ErrorText, 0 AS TasksCreated;
        RETURN;
    END

    DECLARE @run BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    BEGIN TRY
    INSERT grac_practice.asset_scheduler_run (organization_id, trigger_code, entered_by) VALUES (@organization_id, @trigger_code, @actor);
    SET @run = SCOPE_IDENTITY();

    DECLARE @orgs INT = 0, @ren INT = 0, @att INT = 0, @opened INT = 0, @closed INT = 0, @queued INT = 0, @errors INT = 0,
            @err NVARCHAR(MAX) = NULL,
            @o INT, @c INT, @q INT, @e INT, @et NVARCHAR(MAX), @gen INT, @rid BIGINT,
            @tasks INT = 0, @t INT, @ao INT, @ac INT;                                      -- 438
    DECLARE @vu INT;                                                                       -- 446
    DECLARE @co INT, @cr INT, @cx INT;                                                     -- 447
    DECLARE @po INT, @pc INT, @px INT;                                                     -- 448

    DECLARE @org_list TABLE (organization_id BIGINT NOT NULL PRIMARY KEY);
    INSERT @org_list (organization_id)
    SELECT o.organization_id
      FROM grac_practice.organization o
     WHERE (@organization_id IS NOT NULL AND o.organization_id = @organization_id)
        OR (@organization_id IS NULL
            AND (EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a WHERE a.organization_id = o.organization_id)
                 OR EXISTS (SELECT 1 FROM grac_practice.asset_contract c WHERE c.organization_id = o.organization_id)));

    DECLARE @org BIGINT, @contract BIGINT;
    DECLARE org_cur CURSOR LOCAL STATIC FOR SELECT organization_id FROM @org_list ORDER BY organization_id;
    OPEN org_cur;
    FETCH NEXT FROM org_cur INTO @org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @orgs = @orgs + 1;

        BEGIN TRY
            EXEC grac_practice.sp_asset_notification_defaults_ensure @organization_id = @org, @actor = @actor;
            EXEC grac_practice.sp_asset_contract_sync @organization_id = @org, @actor = @actor;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (defaults / contract dates): ', ERROR_MESSAGE()), 8000);
        END CATCH

        IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation_profile WHERE organization_id = @org AND is_active = 1)
        BEGIN
        BEGIN TRY
            SET @gen = 0;
            EXEC grac_practice.sp_asset_attestation_generate @organization_id = @org, @campaign_type = N'PERIODIC', @actor = @actor,
                 @scheduled = 1, @suppress_result = 1, @out_generated = @gen OUTPUT;
            SET @att = @att + ISNULL(@gen, 0);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (periodic attestation): ', ERROR_MESSAGE()), 8000);
        END CATCH
        END

        -- d. Renewal occurrences whose reminder window has opened.
        DECLARE ren_cur CURSOR LOCAL STATIC FOR
            SELECT c.contract_id
              FROM grac_practice.asset_contract c
              JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
             CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
             OUTER APPLY (SELECT ProfileId FROM grac_practice.fn_asset_ntf_profile_for(
                              c.organization_id, grac_practice.fn_asset_ntf_contract_activity(c.contract_type),
                              grac_practice.fn_asset_ntf_version_severity(cv.version_id), @today)) p
             OUTER APPLY (SELECT MAX(s.offset_days) AS lead_days FROM grac_practice.asset_notification_stage s
                           WHERE s.profile_id = p.ProfileId AND s.is_active = 1 AND s.stage_kind = N'REMINDER') w
             WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
               AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
               AND DATEADD(DAY, -ISNULL(w.lead_days, 0), t.d) <= @today
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                                WHERE r.contract_id = c.contract_id
                                  AND (r.is_open = 1 OR (r.prior_version_id = cv.version_id AND ISNULL(r.outcome, N'') <> N'CANCELLED')));
        OPEN ren_cur;
        FETCH NEXT FROM ren_cur INTO @contract;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @rid = NULL;
                EXEC grac_practice.sp_asset_contract_renewal_start @organization_id = @org, @contract_id = @contract,
                     @renewal_type = N'RENEWAL', @notes = N'Started by the scheduler: the renewal reminder window opened.',
                     @actor_employee_id = NULL, @actor = @actor, @suppress_result = 1, @out_renewal_id = @rid OUTPUT;
                IF @rid IS NOT NULL SET @ren = @ren + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @errors = @errors + 1;
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                       N'Contract ', @contract, N' (renewal start): ', ERROR_MESSAGE()), 8000);
            END CATCH
            FETCH NEXT FROM ren_cur INTO @contract;
        END
        CLOSE ren_cur;
        DEALLOCATE ren_cur;

        -- 446: Asset Value for ratings changed outside the asset form (5.1.18.5.7, D137).
        BEGIN TRY                                                                          -- 446
            SELECT @vu = 0, @e = 0, @et = NULL;                                            -- 446
            EXEC grac_practice.sp_asset_valuation_sync @organization_id = @org, @actor = @actor,   -- 446
                 @updated = @vu OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;     -- 446
            SET @errors = @errors + ISNULL(@e, 0);                                         -- 446
            IF @et IS NOT NULL                                                             -- 446
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);   -- 446
        END TRY                                                                            -- 446
        BEGIN CATCH                                                                        -- 446
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 446
            SET @errors = @errors + 1;                                                     -- 446
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 446
                                   N'Organization ', @org, N' (asset value): ', ERROR_MESSAGE()), 8000);   -- 446
        END CATCH                                                                          -- 446

        -- 447: consistency findings follow ratings, valuations and expired acceptances (19.7).
        BEGIN TRY                                                                          -- 447
            EXEC grac_practice.sp_asset_consistency_evaluate @organization_id = @org, @actor = @actor,   -- 447
                 @out_opened = @co OUTPUT, @out_resolved = @cr OUTPUT, @out_reopened = @cx OUTPUT;   -- 447
        END TRY                                                                            -- 447
        BEGIN CATCH                                                                        -- 447
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 447
            SET @errors = @errors + 1;                                                     -- 447
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 447
                                   N'Organization ', @org, N' (consistency rules): ', ERROR_MESSAGE()), 8000);   -- 447
        END CATCH                                                                          -- 447

        -- 448: privacy and retention reviews, exception expiry (before the sweep, so they notify).
        BEGIN TRY                                                                          -- 448
            EXEC grac_practice.sp_asset_privacy_sync @organization_id = @org, @actor = @actor,   -- 448
                 @out_opened = @po OUTPUT, @out_closed = @pc OUTPUT, @out_expired = @px OUTPUT;   -- 448
        END TRY                                                                            -- 448
        BEGIN CATCH                                                                        -- 448
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 448
            SET @errors = @errors + 1;                                                     -- 448
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 448
                                   N'Organization ', @org, N' (privacy): ', ERROR_MESSAGE()), 8000);   -- 448
        END CATCH                                                                          -- 448

        -- 438: recurring asset activities (before the sweep, so new occurrences notify).
        BEGIN TRY
            SELECT @t = 0, @ao = 0, @ac = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_activity_run @organization_id = @org, @actor = @actor,
                 @tasks = @t OUTPUT, @opened = @ao OUTPUT, @completed = @ac OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @tasks = @tasks + ISNULL(@t, 0), @errors = @errors + ISNULL(@e, 0);
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (activities): ', ERROR_MESSAGE()), 8000);
        END CATCH

        BEGIN TRY
            SELECT @o = 0, @c = 0, @q = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_notification_sweep @organization_id = @org, @actor = @actor,
                 @opened = @o OUTPUT, @closed = @c OUTPUT, @queued = @q OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @opened = @opened + @o, @closed = @closed + @c, @queued = @queued + @q, @errors = @errors + @e;
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (notifications): ', ERROR_MESSAGE()), 8000);
        END CATCH

        FETCH NEXT FROM org_cur INTO @org;
    END
    CLOSE org_cur;
    DEALLOCATE org_cur;

    UPDATE grac_practice.asset_scheduler_run
       SET finished_dt = SYSUTCDATETIME(), result = CASE WHEN @errors > 0 THEN N'COMPLETED_WITH_ERRORS' ELSE N'COMPLETED' END,
           organizations = @orgs, renewals_started = @ren, attestations_generated = @att, occurrences_opened = @opened,
           occurrences_closed = @closed, notifications_queued = @queued, error_count = @errors, error_text = @err,
           tasks_created = @tasks                                                          -- 438
     WHERE run_id = @run;
    END TRY
    BEGIN CATCH
        -- Never leave the lock behind on a pooled connection.
        IF XACT_STATE() <> 0 ROLLBACK;
        IF CURSOR_STATUS('local', 'org_cur') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'org_cur') >= 0 CLOSE org_cur;
            DEALLOCATE org_cur;
        END
        EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';
        IF @run IS NOT NULL
            UPDATE grac_practice.asset_scheduler_run
               SET finished_dt = SYSUTCDATETIME(), result = N'FAILED', error_count = @errors + 1,
                   error_text = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, ERROR_MESSAGE()), 8000)
             WHERE run_id = @run;
        THROW;
    END CATCH
    EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';

    SELECT run_id AS RunId, result AS Result, organizations AS Organizations, renewals_started AS RenewalsStarted,
           attestations_generated AS AttestationsGenerated, occurrences_opened AS OccurrencesOpened,
           occurrences_closed AS OccurrencesClosed, notifications_queued AS NotificationsQueued,
           error_count AS ErrorCount, error_text AS ErrorText, tasks_created AS TasksCreated   -- 438
      FROM grac_practice.asset_scheduler_run WHERE run_id = @run;
END
GO
GO
PRINT '450 rollback: 448 scheduler body restored.';
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_relationship_rule_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_org_setting_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_setting_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_settings;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_snapshots;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_items;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_governance_snapshot_take;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_governance_items;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_governance_assets;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_governance_effective;
GO
DROP TABLE IF EXISTS grac_practice.asset_governance_snapshot_item;
DROP TABLE IF EXISTS grac_practice.asset_governance_snapshot_kpi;
DROP TABLE IF EXISTS grac_practice.asset_governance_snapshot;
DROP TABLE IF EXISTS grac_practice.asset_governance_relationship_rule;
DROP TABLE IF EXISTS grac_practice.asset_governance_org_setting;
DROP TABLE IF EXISTS grac_practice.asset_governance_setting;
DROP TABLE IF EXISTS grac_practice.asset_governance_kpi;
GO
DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-governance';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-governance';
GO
PRINT '450 rollback: governance objects and menu dropped.';
GO
SELECT '450 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_governance_kpi','U') IS NULL
             AND OBJECT_ID('grac_practice.fn_asset_governance_items') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) NOT LIKE '%sp_asset_governance_snapshot_take%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_privacy_sync%'
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-governance')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
