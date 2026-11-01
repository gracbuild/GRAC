-- _run_repository_change_detect.sql  (RUN ANY TIME; SSMS against the Practice Management DB)
-- Runs the Repository Updates detection now -- the same procedure the API's
-- RepositoryChangeDetectWorker runs once a day -- and shows what it raised.
--
--   * Compares every organization's copy of its subscribed releases with
--     grac_new and records each difference as a Pending change on
--     Repository Updates (grac_practice.organization_repository_change),
--     plus the Home notifications for the release owner / org admins.
--   * Nothing is applied: changes still wait for approval on Repository
--     Updates.
--   * Safe to run as often as you like: a difference already Pending,
--     Approved or Rejected is never raised twice.
--
-- Set @organization_id to one organization's id to check only that one;
-- leave NULL for every organization. Requires 395.
SET NOCOUNT ON;
DECLARE @organization_id BIGINT = NULL;

IF OBJECT_ID('grac_practice.sp_repository_change_detect','P') IS NULL
BEGIN
    RAISERROR('grac_practice.sp_repository_change_detect not found -- run 395_repository_change_detect_approve.sql in this database first.', 16, 1);
    RETURN;
END

DECLARE @started  DATETIME2 = SYSUTCDATETIME();
DECLARE @raised   INT, @notified INT;

EXEC grac_practice.sp_repository_change_detect
     @organization_id = @organization_id,
     @actor           = N'manual-run',
     @raised_count    = @raised OUTPUT,
     @notified_count  = @notified OUTPUT,
     @suppress_result = 1;

-- 1. Summary of this run.
SELECT @raised AS NewPendingChanges, @notified AS NotificationsRaised,
       @started AS RunStartedUtc, SYSUTCDATETIME() AS RunFinishedUtc;

-- 2. The changes this run raised.
SELECT c.change_id, c.organization_id, o.organization_name,
       COALESCE(a.artifact_code + N' ' + r.version_no, r.version_no, N'Shared by releases') AS FrameworkRelease,
       c.copy_code, c.change_action, c.source_label, c.status, c.detected_dt
FROM grac_practice.organization_repository_change c
LEFT JOIN grac_practice.organization o ON o.organization_id = c.organization_id
LEFT JOIN grac_new.release r ON r.release_id = c.release_id
LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
WHERE c.detected_dt >= @started
  AND (@organization_id IS NULL OR c.organization_id = @organization_id)
ORDER BY c.organization_id, FrameworkRelease, c.copy_code, c.change_action, c.source_label;

-- 3. Everything now waiting on Repository Updates, per organization and release.
SELECT c.organization_id, o.organization_name,
       COALESCE(a.artifact_code + N' ' + r.version_no, r.version_no, N'Shared by releases') AS FrameworkRelease,
       COUNT(*) AS PendingChanges
FROM grac_practice.organization_repository_change c
LEFT JOIN grac_practice.organization o ON o.organization_id = c.organization_id
LEFT JOIN grac_new.release r ON r.release_id = c.release_id
LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
WHERE c.status = N'Pending'
  AND (@organization_id IS NULL OR c.organization_id = @organization_id)
GROUP BY c.organization_id, o.organization_name, COALESCE(a.artifact_code + N' ' + r.version_no, r.version_no, N'Shared by releases')
ORDER BY c.organization_id, FrameworkRelease;
