/*
  Diagnose: "Complete Checklist" leaves the instance at In Progress.

  Set @event_instance_id below (the Open button's row) and run the whole file.
  Each step prints what the complete gate in sp_event_instance_complete
  actually evaluates, in the same order the procedure does.

  Both the pre-132 and the post-132 procedure end at status = 'Completed'
  for a pack whose single mandatory obligation is Passed. So if the row is
  still In Progress, one of the steps below is not what the UI believes.
*/
SET NOCOUNT ON;

DECLARE @event_instance_id BIGINT = 0;   -- <<<<<< SET THIS

IF @event_instance_id = 0
BEGIN
    PRINT 'Pick an instance first. Candidates:';
    SELECT TOP 20 ei.event_instance_id, ei.organization_id, ei.origin_kind,
           ei.entity_display_name AS SubjectLabel, ei.event_type_code,
           ei.status, ei.due_date, ei.updated_dt
    FROM   grac_practice.event_instance ei
    WHERE  ei.status NOT IN (N'Completed', N'Cancelled')
    ORDER BY ei.event_instance_id DESC;
    RETURN;
END

PRINT '=== 1. Which sp_event_instance_complete is deployed? ===';
-- If this does NOT mention event_instance_obligation, migration 132 has been
-- overwritten by a later re-run of 067 and must be re-applied.
SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_instance_complete'))
                 LIKE '%event_instance_obligation%'
            THEN '132 version (obligation-aware)'
            ELSE '067/pre-132 version -- RE-RUN 132' END AS CompleteProcVersion,
       OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_instance_complete')) AS Definition;

PRINT '=== 2. The instance ===';
SELECT event_instance_id, organization_id, origin_kind, event_type_code,
       entity_display_name AS SubjectLabel, checklist_id,
       status, completed_dt, updated_by, updated_dt
FROM   grac_practice.event_instance
WHERE  event_instance_id = @event_instance_id;

PRINT '=== 3. Obligation line items -- what the DB actually holds ===';
-- If item_status is still Pending here while the drawer showed Passed, the
-- save never persisted and the UI updated only its in-memory copy.
SELECT event_instance_obligation_id, item_sequence, obligation_id,
       LEFT(obligation_label, 60) AS ObligationLabel,
       is_mandatory, item_status, evidence_required, evidence_url,
       na_justification, completed_by, completed_dt, updated_dt
FROM   grac_practice.event_instance_obligation
WHERE  event_instance_id = @event_instance_id
ORDER BY item_sequence;

PRINT '=== 4. Checklist line items (expected: none for an obligation pack) ===';
SELECT ii.event_instance_item_id, ci.item_sequence, ci.is_mandatory, ii.item_status
FROM   grac_practice.event_instance_item ii
JOIN   grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
WHERE  ii.event_instance_id = @event_instance_id
ORDER BY ci.item_sequence;

PRINT '=== 5. The gate, computed exactly as the procedure does ===';
DECLARE @item_total INT =
    (SELECT COUNT(*) FROM grac_practice.event_instance_item        WHERE event_instance_id = @event_instance_id)
  + (SELECT COUNT(*) FROM grac_practice.event_instance_obligation  WHERE event_instance_id = @event_instance_id);

DECLARE @unresolved INT =
    (SELECT COUNT(*)
     FROM   grac_practice.event_instance_item ii
     JOIN   grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
     WHERE  ii.event_instance_id = @event_instance_id
       AND  ci.is_mandatory = 1
       AND  ii.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable'))
  + (SELECT COUNT(*)
     FROM   grac_practice.event_instance_obligation io
     WHERE  io.event_instance_id = @event_instance_id
       AND  io.is_mandatory = 1
       AND  io.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable'));

SELECT @item_total  AS ItemTotal,
       @unresolved  AS UnresolvedMandatory,
       CASE WHEN @item_total = 0 THEN 'THROW 67406 -- no items to complete'
            WHEN @unresolved > 0 THEN 'THROW 67407 -- mandatory items unresolved'
            ELSE 'gate passes -> would set Completed (or Failed if any mandatory item is Failed)'
       END AS WhatCompleteWillDo;

PRINT '=== 6. Audit trail -- did a Complete attempt even arrive? ===';
-- No 'Complete' row means the request never reached the procedure: look at
-- the browser network tab for the POST to
-- /practice/api/workflow/event-instances/<id>/complete and at the API log.
SELECT action, actor, new_value, entered_dt
FROM   grac_practice.event_audit
WHERE  event_instance_id = @event_instance_id
ORDER BY event_audit_id DESC;

PRINT '=== 7. Live test -- run complete here and see the real error ===';
BEGIN TRAN;
BEGIN TRY
    EXEC grac_practice.sp_event_instance_complete
         @event_instance_id = @event_instance_id,
         @actor_employee_id = NULL,
         @comments          = N'diagnostic run';

    SELECT 'complete succeeded' AS Result, status AS NewStatus
    FROM   grac_practice.event_instance WHERE event_instance_id = @event_instance_id;
END TRY
BEGIN CATCH
    SELECT 'complete FAILED' AS Result,
           ERROR_NUMBER()  AS ErrorNumber,
           ERROR_MESSAGE() AS ErrorMessage;
END CATCH
ROLLBACK TRAN;   -- nothing is kept; this is a dry run
GO

/*
  READING THE OUTPUT

  Step 1 says pre-132  -> re-run database\132_event_instance_obligation_execution.sql.
                          A later re-run of 067 overwrites the obligation-aware version.

  Step 3 shows Pending while the drawer showed Passed
                       -> the item save did not persist. Check the browser
                          network tab: the POST to
                          /practice/api/workflow/scope/instance-obligations
                          must return 200. A 404 means the API was not
                          rebuilt after migration 132's C# changes.

  Step 5 says THROW 67407 and step 3 confirms Pending
                       -> consistent: complete is correctly refusing. Set the
                          obligation result first.

  Step 5 says "gate passes" but step 7 succeeded
                       -> the procedure is fine and the request never reached
                          it. Look for a 400/404/502 on the complete POST.

  Step 6 has no 'Complete' action row
                       -> confirms the request never reached the procedure.
*/
