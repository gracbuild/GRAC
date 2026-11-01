/* Run Repository change detection NOW (same call the API's
   RepositoryChangeDetectWorker makes once a day).
   Compares each organization's copy of its subscribed releases with
   grac_new and records each difference as a Pending change + notification.
   Idempotent: a difference already Pending/Approved/Rejected is never
   raised twice, so running this again is safe.
   @organization_id = NULL -> every organization; set an id for one org. */
SET NOCOUNT ON;
DECLARE @organization_id BIGINT = NULL;   -- e.g. 2 for one organization
DECLARE @raised INT, @notified INT, @run_start DATETIME2 = SYSUTCDATETIME();

EXEC grac_practice.sp_repository_change_detect
     @organization_id = @organization_id,
     @actor           = N'change-detect-manual',
     @raised_count    = @raised   OUTPUT,
     @notified_count  = @notified OUTPUT,
     @suppress_result = 1;

SELECT @raised AS raised_count, @notified AS notified_count;

PRINT '--- changes raised by this run ---';
SELECT c.change_id, c.organization_id, c.release_id, c.copy_code,
       c.change_action, c.source_label, c.status, c.detected_dt
  FROM grac_practice.organization_repository_change c
 WHERE c.detected_dt >= @run_start
 ORDER BY c.organization_id, c.release_id, c.copy_code, c.change_id;

PRINT '--- all Pending changes per organization ---';
SELECT c.organization_id, c.copy_code, c.change_action, COUNT(*) AS pending
  FROM grac_practice.organization_repository_change c
 WHERE c.status = N'Pending'
   AND (@organization_id IS NULL OR c.organization_id = @organization_id)
 GROUP BY c.organization_id, c.copy_code, c.change_action
 ORDER BY c.organization_id, c.copy_code, c.change_action;
