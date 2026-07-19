-- =====================================================================
-- 053 Sample Assurance + Custom tasks -- ROLLBACK
--
-- Removes every practice_task row inserted by seed-053. Uses origin_code
-- as the marker (set to N'SAMPLE-053' at insert time). Also purges the
-- audit rows those tasks generated in practice_task_audit.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN
    PRINT 'SKIP (053 rollback): practice_task missing.';
    RETURN;
END

DECLARE @ids TABLE (task_id BIGINT PRIMARY KEY);

INSERT INTO @ids (task_id)
SELECT task_id
FROM grac_practice.practice_task
WHERE origin_code = N'SAMPLE-053';

IF NOT EXISTS (SELECT 1 FROM @ids)
BEGIN
    PRINT '053 rollback: no sample rows found -- nothing to do.';
    RETURN;
END

-- Purge audit / history rows first if such tables exist.
IF OBJECT_ID('grac_practice.practice_task_audit','U') IS NOT NULL
BEGIN
    DELETE a
    FROM grac_practice.practice_task_audit a
    JOIN @ids i ON i.task_id = a.task_id;
END

IF OBJECT_ID('grac_practice.practice_task_status_history','U') IS NOT NULL
BEGIN
    DELETE h
    FROM grac_practice.practice_task_status_history h
    JOIN @ids i ON i.task_id = h.task_id;
END

DELETE t
FROM grac_practice.practice_task t
JOIN @ids i ON i.task_id = t.task_id;

PRINT '053 rollback: sample tasks removed.';
GO

SET NOEXEC OFF;
GO
