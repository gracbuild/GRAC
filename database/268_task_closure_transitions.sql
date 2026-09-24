-- =====================================================================
-- 268 Task state machine — the missing routes to Closed
--
-- THE BUG
-- -------
--     Illegal transition for Task #11: Assigned -> Closed as <no-role>.
--     [ILLEGAL_TRANSITION]
--
-- Raised by sp_pm_state_transition (035) when
-- fn_is_transition_allowed returns 0.
--
-- THE ROLE IS A RED HERRING
-- -------------------------
-- "<no-role>" is the message reporting the actor, not the reason for the
-- refusal. fn_is_transition_allowed matches a rule whose
-- actor_role_code IS NULL against ANY actor, NULL included:
--
--     AND ( r.actor_role_code IS NULL
--        OR (@actor_role_code IS NOT NULL AND r.actor_role_code = @actor_role_code) )
--
-- Every working Task rule in the 035 seed has actor_role_code = NULL. So
-- passing a role would not have helped. The edge simply is not there.
--
-- WHAT 035 ACTUALLY SEEDS
-- -----------------------
-- Exactly two routes into Closed for a Task:
--
--     PendingReview          -> Closed
--     OperationalGatePassed  -> Closed
--
-- and none at all from Open, Assigned, InProgress or Escalated. 035 is
-- the ONLY migration that has ever seeded Task transition rules -- no
-- later file adds to them -- so a task sitting in Assigned has been
-- impossible to close or complete, for every actor, on every screen,
-- since the state machine was introduced.
--
-- THIS IS NOT A RISK CENTRE BUG
-- -----------------------------
-- Task Center's own "Complete Task" and "Close Task" fail identically on
-- an Assigned task, because both land in sp_task_close:
--
--     sp_task_complete (200)  -> EXEC sp_task_close (@reason_code =
--                                N'TASK_COMPLETED')
--     sp_task_close    (037)  -> sp_pm_state_transition(... N'Closed')
--
-- "Completed" is a label on an activity row and on the API response; the
-- underlying status transition is -> Closed either way. Risk Treatment
-- only surfaced it sooner, because sp_task_open creates a treatment task
-- WITH an assignee, so it starts life in Assigned -- the one status the
-- operator never has to pass through by hand, and therefore the one
-- nobody had tried to close from.
--
-- WHY THE SEED IS WRONG RATHER THAN THE CALLER
-- --------------------------------------------
-- Two independent pieces of evidence:
--
-- 1. sp_task_close (037) carries its own status guard, and it guards
--    ONE type:
--
--        IF @task_type_code = N'Implementation'
--           AND @from_status_code NOT IN (N'OperationalGatePassed', N'PendingReview')
--
--    That guard is redundant if the state machine already restricted
--    Closed to those two statuses for everything. Its existence says the
--    author expected close to be legal from ordinary working statuses
--    for every OTHER task type, and wrote a procedure-level guard
--    precisely because Implementation is the exception.
--
-- 2. Task Centre v2 (194 / 200) introduced sp_task_complete as the
--    governed completion path -- the BRD §12 mandatory-child gate lives
--    in it -- and that procedure needs "-> Closed" from wherever the
--    task happens to be. The 035 seed predates v2 and was never extended
--    to match. The lifecycle grew; its rule table did not.
--
-- The alternative "fix" -- having the UI walk a task Assigned ->
-- InProgress -> PendingReview -> Closed before completing it -- is
-- rejected. It would write an audit trail of states the work never
-- passed through, to satisfy a rule table rather than a business rule.
-- Fabricating history to get past a guard is worse than the guard.
--
-- WHAT THIS ADDS
-- --------------
--     Open        -> Closed      close before anyone picked it up
--     Assigned    -> Closed      THE REPORTED FAILURE
--     InProgress  -> Closed      or it fails again one step later
--     Escalated   -> Closed      an escalated task must still resolve
--
-- Nothing is removed, nothing is loosened for Implementation tasks --
-- sp_task_close's own two-gate guard is untouched and still refuses
-- them, which is why widening the state machine does not widen THAT
-- rule.
--
-- requires_reason = 0, matching the two Closed rules 035 already seeds.
-- Deliberate: the framework refuses a transition whose rule demands a
-- reason when the caller passes none, and TaskCloseRequest defaults
-- every reason field to NULL. Setting 1 here would trade this bug for a
-- new one on the API's own default path. The UI collects a reason on
-- both Close and Complete regardless; that is where it belongs while the
-- default caller can still omit it.
--
-- IDEMPOTENT: MERGE on the natural key, which is also the table's UNIQUE
-- constraint (entity_type, from_status_code, to_status_code,
-- actor_role_code). Re-running changes nothing.
--
-- Rollback: database/268_task_closure_transitions_rollback.sql
-- Depends:  035 (entity_state_transition_rule + the Task status seed)
-- Docs:     docs/task-centre-v2.md, docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
BEGIN PRINT 'ABORT (268): entity_state_transition_rule missing -- run 035 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
BEGIN PRINT 'ABORT (268): entity_status_master missing -- run 035 first.'; SET @ok = 0; END

-- The rules below name statuses by code. A code that does not exist in
-- entity_status_master would insert a rule that can never match, which
-- fails silently at the worst possible moment -- so it is checked here
-- rather than discovered later.
IF OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
BEGIN
    DECLARE @missing NVARCHAR(400) = NULL;

    SELECT @missing = STRING_AGG(want.code, N', ')
    FROM (VALUES (N'Open'), (N'Assigned'), (N'InProgress'),
                 (N'Escalated'), (N'Closed')) want(code)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.entity_status_master s
         WHERE s.entity_type = N'Task' AND s.status_code = want.code);

    IF @missing IS NOT NULL
    BEGIN
        PRINT CONCAT('ABORT (268): Task status codes missing from entity_status_master: ', @missing);
        PRINT '            Run 035_state_machine_framework.sql first.';
        SET @ok = 0;
    END
END

IF @ok = 0
BEGIN
    RAISERROR('268_task_closure_transitions: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- The missing edges
--
-- actor_role_code NULL on every row: these are lifecycle facts, not
-- privileges. WHO may close a task is a permission question and is
-- answered by the API's authorisation, not by the state machine -- which
-- is the same shape every other working Task rule in 035 has.
-- =====================================================================
;WITH rules AS (
    SELECT * FROM (VALUES
        -- entity_type, from,          to,        actor_role_code, requires_reason, description
        (N'Task', N'Open',       N'Closed', CAST(NULL AS NVARCHAR(60)), 0,
            N'Close a task nobody picked up (Custom "Close / Inactivate").'),
        (N'Task', N'Assigned',   N'Closed', NULL, 0,
            N'Complete or close an assigned task. sp_task_open with an assignee lands here, so this is the normal completion route for risk treatment and every other pre-assigned task.'),
        (N'Task', N'InProgress', N'Closed', NULL, 0,
            N'Complete or close work already under way, without a review step.'),
        (N'Task', N'Escalated',  N'Closed', NULL, 0,
            N'Resolve an escalated task. Without this an escalation is a dead end: 035 seeds three routes INTO Escalated and none out of it except Cancelled.')
    ) v(entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, description)
)
MERGE grac_practice.entity_state_transition_rule AS t
USING rules
   ON  t.entity_type      = rules.entity_type
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(rules.from_status_code, N'__NULL__')
   AND t.to_status_code   = rules.to_status_code
   AND ISNULL(t.actor_role_code, N'__NULL__')  = ISNULL(rules.actor_role_code, N'__NULL__')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code,
            requires_reason, description, is_active, entered_by)
    VALUES (rules.entity_type, rules.from_status_code, rules.to_status_code,
            rules.actor_role_code, rules.requires_reason, rules.description, 1, 'seed-268')
-- Reactivates a rule someone disabled, and refreshes the description,
-- but does NOT touch requires_reason on an existing row: an operator who
-- deliberately tightened one should not have it silently loosened by a
-- re-run.
WHEN MATCHED AND (t.is_active = 0 OR ISNULL(t.description, N'') <> rules.description) THEN
    UPDATE SET is_active   = 1,
               description = rules.description,
               updated_by  = 'seed-268',
               updated_dt  = SYSUTCDATETIME();
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 268 verification ---';

SELECT '268 routes into Closed for a Task' AS Check_,
       STRING_AGG(CONCAT(ISNULL(from_status_code, N'(new)'),
                         CASE WHEN is_active = 1 THEN N'' ELSE N' [INACTIVE]' END), N', ')
           WITHIN GROUP (ORDER BY from_status_code) AS Result
FROM grac_practice.entity_state_transition_rule
WHERE entity_type = N'Task' AND to_status_code = N'Closed';

SELECT '268 the reported failure is now legal' AS Check_,
       CASE WHEN grac_practice.fn_is_transition_allowed(
                    N'Task', N'Assigned', N'Closed', NULL) = 1
            THEN 'PASS -- Assigned -> Closed allowed with no role'
            ELSE '*** FAIL -- still refused' END AS Result;

SELECT '268 all four new edges' AS Check_,
       CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', N'Open',       N'Closed', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Assigned',   N'Closed', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'InProgress', N'Closed', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Escalated',  N'Closed', NULL) = 1
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '268 035 rules untouched' AS Check_,
       CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', N'PendingReview', N'Closed', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Open', N'Assigned', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Assigned', N'InProgress', NULL) = 1
            THEN 'PASS' ELSE '*** FAIL -- 268 disturbed an existing rule' END AS Result;

-- Nothing here loosens the Implementation two-gate rule: that guard is
-- inside sp_task_close, not in the rule table, so widening the state
-- machine cannot reach it. Stated as a check so a future reader does not
-- have to take it on trust.
SELECT '268 Implementation two-gate guard still in sp_task_close' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules m
                          WHERE m.object_id = OBJECT_ID('grac_practice.sp_task_close')
                            AND m.definition LIKE '%OperationalGatePassed%')
            THEN 'PASS -- untouched' ELSE '*** CHECK -- sp_task_close changed' END AS Result;

PRINT '268 Task closure transitions installed.';
PRINT '     Open / Assigned / InProgress / Escalated -> Closed are now legal.';
PRINT '     Complete Task and Close Task work from the status a task is actually in.';
GO

SET NOEXEC OFF;
GO
