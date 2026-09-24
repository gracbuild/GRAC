-- =====================================================================
-- 350_task_transition_rules_reconcile.sql
--
-- WHY
--   349 restored ONE Task transition rule (<initial> -> Open, no role),
--   but this database is missing the no-role rows for the WHOLE Task
--   lifecycle -- the next hop already fails:
--
--     Illegal transition for Task #25: Open -> Assigned as <no-role>.
--     Uncommittable transaction is detected ...  (the doomed-txn cascade)
--
--   Every system / auto-created task (risk treatment, gap remediation,
--   practice-instance implementation and its Config / Operational gates)
--   is opened with NO actor role, so it needs the full set of Task
--   transition rules seeded with actor_role_code = NULL. WHO may drive a
--   task is an API authorization concern, not a state-machine one -- which
--   is exactly how 035 and 268 shape these rules.
--
--   This reconciles the COMPLETE Task transition-rule set from the
--   035 seed plus the 268 closure rules, idempotently: it inserts the
--   rows this database is missing and reactivates any that were disabled.
--   requires_reason on an existing row is left untouched (an operator who
--   deliberately tightened one keeps it). This supersedes 349 (that row is
--   included here too; re-running is a no-op).
--
-- SAFE TO RE-RUN. Additive. ASCII-only.
-- Rollback: 350_task_transition_rules_reconcile_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
BEGIN
    RAISERROR('350: entity_state_transition_rule missing -- run 035 first.', 16, 1);
END
GO

;WITH rules AS (
    SELECT * FROM (VALUES
        -- entity_type, from,                          to,                        actor_role_code,            requires_reason
        (N'Task', CAST(NULL AS NVARCHAR(60)),          N'Open',                   CAST(NULL AS NVARCHAR(60)), 0),
        (N'Task', N'Open',                             N'Assigned',               NULL,                       0),
        (N'Task', N'Assigned',                         N'InProgress',             NULL,                       0),
        (N'Task', N'InProgress',                       N'PendingReview',          NULL,                       0),
        (N'Task', N'PendingReview',                    N'Closed',                 NULL,                       0),
        (N'Task', N'InProgress',                       N'ConfigGatePassed',       NULL,                       0),
        (N'Task', N'ConfigGatePassed',                 N'AwaitingFirstExecution', NULL,                       0),
        (N'Task', N'AwaitingFirstExecution',           N'OperationalGatePassed',  NULL,                       0),
        (N'Task', N'OperationalGatePassed',            N'Closed',                 NULL,                       0),
        (N'Task', N'Open',                             N'Cancelled',              NULL,                       1),
        (N'Task', N'Assigned',                         N'Cancelled',              NULL,                       1),
        (N'Task', N'InProgress',                       N'Cancelled',              NULL,                       1),
        (N'Task', N'Assigned',                         N'Escalated',              NULL,                       1),
        (N'Task', N'InProgress',                       N'Escalated',              NULL,                       1),
        (N'Task', N'PendingReview',                    N'Escalated',              NULL,                       1),
        (N'Task', N'Closed',                           N'Open',                   N'Admin',                   1),
        -- 268 closure routes
        (N'Task', N'Open',                             N'Closed',                 NULL,                       0),
        (N'Task', N'Assigned',                         N'Closed',                 NULL,                       0),
        (N'Task', N'InProgress',                       N'Closed',                 NULL,                       0),
        (N'Task', N'Escalated',                        N'Closed',                 NULL,                       0)
    ) v(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason)
)
MERGE grac_practice.entity_state_transition_rule AS t
USING rules
   ON  t.entity_type      = rules.entity_type
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(rules.from_status_code, N'__NULL__')
   AND t.to_status_code   = rules.to_status_code
   AND ISNULL(t.actor_role_code, N'__NULL__')  = ISNULL(rules.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code,
            requires_reason, is_active, entered_by)
    VALUES (rules.entity_type, rules.from_status_code, rules.to_status_code,
            rules.actor_role_code, rules.requires_reason, 1, 'seed-350')
WHEN MATCHED AND (t.is_active = 0) THEN
    UPDATE SET is_active  = 1,
               updated_by = 'seed-350',
               updated_dt = SYSUTCDATETIME();
GO

PRINT '=== 350 verification: the no-role hops the auto/system paths need ===';
SELECT
    CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', NULL,                     N'Open',                   NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'Open',                  N'Assigned',               NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'Assigned',              N'InProgress',             NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'InProgress',            N'ConfigGatePassed',       NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'ConfigGatePassed',      N'AwaitingFirstExecution', NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'AwaitingFirstExecution',N'OperationalGatePassed',  NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'InProgress',            N'PendingReview',          NULL) = 1
      AND      grac_practice.fn_is_transition_allowed(N'Task', N'PendingReview',         N'Closed',                 NULL) = 1
         THEN 'PASS -- full no-role Task lifecycle is now legal'
         ELSE 'FAIL -- a hop is still missing' END AS Result;
GO
PRINT '350: Task transition rules reconciled. Risk/gap/instance tasks can move through their lifecycle with no actor role.';
GO
