-- =====================================================================
-- 268 ROLLBACK — remove the Task closure transitions added by 268
--
-- WHAT THIS RESTORES
-- ------------------
-- The 035 seed's original position: the only routes into Closed for a
-- Task are PendingReview -> Closed and OperationalGatePassed -> Closed.
--
-- BE CLEAR ABOUT WHAT THAT MEANS
-- ------------------------------
-- Running this REINSTATES the bug 268 fixes. After it, a task in
-- Assigned, InProgress, Open or Escalated cannot be completed or closed
-- by anyone, from any screen -- Task Center's own "Complete Task" and
-- "Close Task" included, because both land in sp_task_close. It is here
-- for completeness and for a deployment that must return to a known
-- state, not because reverting is ever the right answer to a user
-- reporting ILLEGAL_TRANSITION.
--
-- DELETE, NOT DEACTIVATE
-- ----------------------
-- is_active = 0 would leave four rows that look like policy decisions
-- somebody made ("closing from Assigned was considered and disallowed")
-- when in fact they are the residue of a rolled-back migration. 268's
-- MERGE reactivates a deactivated row anyway, so deactivating would also
-- make the rollback silently undone by a re-run.
--
-- Rows are matched on entered_by = 'seed-268' as well as the natural
-- key, so a rule an operator added by hand with the same from/to is left
-- alone -- this removes what 268 inserted, not everything that looks
-- like it.
--
-- IDEMPOTENT: re-running deletes nothing the second time.
-- Depends: 035
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NULL
BEGIN
    PRINT 'SKIP (268 rollback): entity_state_transition_rule does not exist -- nothing to undo.';
    SET NOEXEC ON;
END
GO

DECLARE @removed INT = 0;

DELETE r
  FROM grac_practice.entity_state_transition_rule r
 WHERE r.entity_type     = N'Task'
   AND r.to_status_code  = N'Closed'
   AND r.actor_role_code IS NULL
   AND r.from_status_code IN (N'Open', N'Assigned', N'InProgress', N'Escalated')
   -- Only what 268 put there. A rule an operator later edited (and so
   -- stamped with their own updated_by) is still 268's row; a rule
   -- someone INSERTED independently is not.
   AND r.entered_by = 'seed-268';

SET @removed = @@ROWCOUNT;
PRINT CONCAT('268 rollback: removed ', @removed, ' Task closure transition rule(s).');
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 268 rollback verification ---';

SELECT '268r the four edges are gone' AS Check_,
       CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', N'Open',       N'Closed', NULL) = 0
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Assigned',   N'Closed', NULL) = 0
             AND grac_practice.fn_is_transition_allowed(N'Task', N'InProgress', N'Closed', NULL) = 0
             AND grac_practice.fn_is_transition_allowed(N'Task', N'Escalated',  N'Closed', NULL) = 0
            THEN 'PASS -- back to the 035 position'
            ELSE 'NOTE -- one or more remain; a rule was added outside 268 and was left alone' END AS Result;

SELECT '268r the 035 routes survive' AS Check_,
       CASE WHEN grac_practice.fn_is_transition_allowed(N'Task', N'PendingReview', N'Closed', NULL) = 1
             AND grac_practice.fn_is_transition_allowed(N'Task', N'OperationalGatePassed', N'Closed', NULL) = 1
            THEN 'PASS' ELSE '*** FAIL -- the rollback removed too much' END AS Result;

PRINT '268 rollback complete.';
PRINT '     WARNING: Complete Task and Close Task will again fail with';
PRINT '     ILLEGAL_TRANSITION on any task in Open, Assigned, InProgress or Escalated.';
GO

SET NOEXEC OFF;
GO
