/*  ============================================================
    027_verify_resolution_save_fix.sql
    Verifies the @new_id initialization fix in pm_manage_practice_repository.

    ROOT CAUSE: @new_id was initialized to @p_id (0) at line 3270.
    When the duplicate-check SELECT found no rows, @new_id stayed 0
    (not NULL). The IF @new_id IS NULL check was FALSE, so the code
    skipped INSERT and went to UPDATE WHERE resolution_id=0, which
    matched nothing. No error, no row inserted.

    FIX: Added SET @new_id=NULL before the duplicate-check SELECT.

    Run this AFTER redeploying 002_practice_management_procedures.sql
    to confirm rows are now being saved.
    ============================================================ */

-- 1. Check current row count
SELECT 'BEFORE test' Phase, COUNT(*) TotalRows
FROM grac_practice.practice_dependency_resolution;

-- 2. Check that the stored procedure source contains the fix
SELECT 'Procedure contains SET @new_id=NULL fix' CheckName,
  CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.pm_manage_practice_repository'))
       LIKE '%SET @new_id=NULL;%SELECT @new_id=resolution_id%'
  THEN 'YES - Fix deployed'
  ELSE 'NO - Redeploy 002 SQL'
  END Result;

-- 3. Check status master is seeded
SELECT 'Status master seeded' CheckName,
  CASE WHEN EXISTS(SELECT 1 FROM grac_practice.dependency_resolution_status_master WHERE status_code='Resolved')
  THEN 'YES'
  ELSE 'NO - Run 025 SQL'
  END Result;
