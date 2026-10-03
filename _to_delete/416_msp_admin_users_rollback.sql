-- =====================================================================
-- 416 MSP admin users -- ROLLBACK
--
-- Undoes database/416_msp_admin_users.sql for adarsh.narayan@grac.in
-- and arathi.j@grac.in in organisation 1 (MSP).
--
-- Matches on entered_by = 'seed-416' (same discipline as 220/322).
-- Rows that pre-dated 416, or that were later re-saved through the
-- Users screen, are left alone.
--
-- Organisation 1's 'Admin' role and its menu grants are NOT touched:
-- 416 never created them, and other org 1 admins depend on them.
--
-- DELETE VS DEACTIVATE: an employee row referenced elsewhere (tasks,
-- evidence, approvals ...) cannot be deleted; on FK violation 547 the
-- account is deactivated instead, which is enough to stop sign-in.
--
-- ASCII-only. Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (416 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

DECLARE @emails TABLE(email NVARCHAR(250) PRIMARY KEY);
INSERT @emails VALUES (N'adarsh.narayan@grac.in'), (N'arathi.j@grac.in');

-- 1. Home-organisation map rows written by 416.
DELETE m
FROM grac_practice.user_organization_map m
JOIN @emails x ON LOWER(m.user_email) = x.email
WHERE m.organization_id = 1 AND m.entered_by = N'seed-416';
PRINT '416 rollback: user_organization_map rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 2. Role map rows written by 416 (before the employee row, for the FK).
DELETE er
FROM grac_practice.organization_employee_role er
JOIN grac_practice.organization_employee e ON e.employee_id = er.employee_id
JOIN @emails x ON LOWER(e.email) = x.email
WHERE e.organization_id = 1 AND er.entered_by = N'seed-416';
PRINT '416 rollback: organization_employee_role rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 3. Employee rows created by 416: delete, or deactivate if referenced.
DECLARE @employee_id BIGINT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT e.employee_id
    FROM grac_practice.organization_employee e
    JOIN @emails x ON LOWER(e.email) = x.email
    WHERE e.organization_id = 1 AND e.entered_by = N'seed-416';
OPEN c;
FETCH NEXT FROM c INTO @employee_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        DELETE FROM grac_practice.organization_employee WHERE employee_id = @employee_id;
        PRINT '416 rollback: employee ' + CAST(@employee_id AS NVARCHAR(20)) + ' deleted.';
    END TRY
    BEGIN CATCH
        DECLARE @err_number INT = ERROR_NUMBER();
        IF @err_number <> 547
        BEGIN
            THROW;
        END
        UPDATE grac_practice.organization_employee
           SET status = N'Inactive', updated_by = N'seed-416-rollback', updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND status <> N'Inactive';
        PRINT '416 rollback: employee ' + CAST(@employee_id AS NVARCHAR(20)) + ' is referenced elsewhere (FK 547) -- deactivated instead.';
    END CATCH
    FETCH NEXT FROM c INTO @employee_id;
END
CLOSE c;
DEALLOCATE c;
GO

PRINT '=== 416 rollback verification (expect no rows, or Inactive rows) ===';
SELECT e.employee_id, e.organization_id, e.email, e.status AS employee_status, e.entered_by
FROM grac_practice.organization_employee e
WHERE LOWER(e.email) IN (N'adarsh.narayan@grac.in', N'arathi.j@grac.in');
GO

SET NOEXEC OFF;
GO
