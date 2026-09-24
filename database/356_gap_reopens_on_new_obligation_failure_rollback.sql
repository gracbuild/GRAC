-- =====================================================================
-- 356 ROLLBACK -- Gap Center auto-reopen on new Obligation failure
--
-- Puts sp_practice_gap_sync_for_instance back to exactly 245's shape
-- (no OUTPUT capture, no reopen step) and deactivates the Delegated ->
-- New / ReopenObligation transition row so the lifecycle engine refuses
-- it again if anything still calls it directly.
--
-- The transition row is DEACTIVATED, not deleted -- gaps already
-- reopened by it carry a custom_gap_history row with action_code
-- 'ReopenObligation' that references it by action_code alone (the
-- history table does not FK to gap_lifecycle_transition_master), so
-- deleting the row would not break that history either way; it is kept
-- so a re-run of 356 lands on the same row via its NOT EXISTS guard
-- instead of creating a second, ever so slightly different one.
--
-- READ THIS BEFORE RUNNING IT
--   After this rollback, an already-Analysed (Delegated) Implementation
--   gap stops reopening itself when a new Obligation fails under the
--   same Practice Instance -- exactly the pre-356 behaviour the report
--   was filed against. practice_gap / practice_gap_obligation (the Task
--   Center rollup) keep working unchanged; only the Gap Centre lifecycle
--   side of this migration is undone.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
GO

-- ---- 1. Deactivate the Delegated -> New / ReopenObligation transition
DECLARE @inactive_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');
DECLARE @s_del       INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated');

IF @inactive_rs IS NOT NULL AND @s_del IS NOT NULL
    UPDATE grac_practice.gap_lifecycle_transition_master
       SET record_status_id = @inactive_rs
     WHERE from_state_id = @s_del
       AND action_code   = N'ReopenObligation';
GO

-- ---- 2. sp_practice_gap_sync_for_instance, exactly as 245 left it ----
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_gap_sync_for_instance
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52720, 'sp_practice_gap_sync_for_instance: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52721, 'sp_practice_gap_sync_for_instance: instance not found.', 1;

    DECLARE @current TABLE (
        practice_instance_obligation_id BIGINT PRIMARY KEY,
        obligation_name                 NVARCHAR(500) NULL,
        obligation_type_code            NVARCHAR(60)  NULL,
        status_code                     NVARCHAR(60)  NOT NULL
    );

    INSERT INTO @current
        (practice_instance_obligation_id, obligation_name, obligation_type_code, status_code)
    SELECT pio.practice_instance_obligation_id,
           pio.obligation_name,
           pio.obligation_type_code,
           ims.status_code
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status               = N'Active'
      AND  ims.status_code IN (N'Not Implemented', N'Partially Implemented');

    BEGIN TRAN;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap
                    WHERE practice_instance_id = @practice_instance_id)
       AND EXISTS (SELECT 1 FROM @current)
    BEGIN
        INSERT grac_practice.practice_gap
            (organization_id, practice_instance_id, gap_status,
             opened_dt, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, N'Open',
             SYSUTCDATETIME(), @actor);
    END

    DECLARE @practice_gap_id BIGINT;
    SELECT @practice_gap_id = practice_gap_id
    FROM   grac_practice.practice_gap
    WHERE  practice_instance_id = @practice_instance_id;

    IF @practice_gap_id IS NOT NULL
    BEGIN
        UPDATE pgo
           SET status     = N'Retired',
               removed_dt = SYSUTCDATETIME(),
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_gap_obligation pgo
        WHERE  pgo.practice_gap_id = @practice_gap_id
          AND  pgo.status          = N'Active'
          AND  NOT EXISTS (SELECT 1 FROM @current c
                            WHERE c.practice_instance_obligation_id
                                = pgo.practice_instance_obligation_id);
    END

    IF @practice_gap_id IS NOT NULL
    BEGIN
        INSERT grac_practice.practice_gap_obligation
            (practice_gap_id, practice_instance_obligation_id,
             obligation_name, obligation_type_code,
             logged_status_code, status, entered_by)
        SELECT @practice_gap_id, c.practice_instance_obligation_id,
               c.obligation_name, c.obligation_type_code,
               c.status_code, N'Active', @actor
        FROM   @current c
        WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap_obligation pgo
                            WHERE pgo.practice_gap_id = @practice_gap_id
                              AND pgo.practice_instance_obligation_id
                                  = c.practice_instance_obligation_id
                              AND pgo.status = N'Active');

        DECLARE @active_count INT = (
            SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id
               AND status          = N'Active');

        IF @active_count = 0
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status = N'Closed',
                   closed_dt  = SYSUTCDATETIME(),
                   updated_by = @actor,
                   updated_dt = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id
               AND gap_status      = N'Open';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status  = N'Open',
                   reopened_dt = CASE WHEN gap_status = N'Closed'
                                      THEN SYSUTCDATETIME()
                                      ELSE reopened_dt END,
                   closed_dt   = NULL,
                   updated_by  = @actor,
                   updated_dt  = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id;
        END
    END

    COMMIT TRAN;

    SELECT @practice_instance_id  AS PracticeInstanceId,
           @practice_gap_id       AS PracticeGapId,
           (SELECT gap_status FROM grac_practice.practice_gap
             WHERE practice_gap_id = @practice_gap_id) AS GapStatus,
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id AND status = N'Active') AS ActiveObligationCount;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '356 rollback: ReopenObligation transition deactivated' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.gap_lifecycle_transition_master t
                  JOIN grac_practice.gap_lifecycle_state_master fs ON fs.lifecycle_state_id = t.from_state_id
                  JOIN grac_practice.record_status_master r        ON r.record_status_id    = t.record_status_id
                 WHERE fs.state_code = N'Delegated'
                   AND t.action_code = N'ReopenObligation'
                   AND r.status_code = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '356 rollback: sync proc no longer captures OUTPUT / calls the reopen',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P'))
                 NOT LIKE '%ReopenObligation%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '356 rollback complete.';
PRINT '     An Analysed (Delegated) gap no longer reopens itself on a new';
PRINT '     Obligation failure -- back to pre-356 behaviour.';
GO
