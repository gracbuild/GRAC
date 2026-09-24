-- =====================================================================
-- DIAGNOSTIC -- "Exception Centre -> Actions -> Analysis works on Dev
--                but not on UAT"
--
-- READ-ONLY. No CREATE, ALTER, INSERT, UPDATE, DELETE, DROP.
-- Safe on UAT and on production.
--
-- RUN THIS ON UAT. Then, if you want the comparison, run the SAME file
-- on Dev and diff the two outputs -- every section is a flat list, so a
-- text diff shows the drift immediately.
--
-- WHAT IT CHECKS, AND WHY THESE OBJECTS
--   The Analysis page (wwwroot/js/ExceptionCentre/exception-analysis.js)
--   calls, in this order: the request detail, the exception types, the
--   employee list, the practice name, the linked tasks, the history.
--   Section 1 lists every procedure the Exception Centre and the
--   Analysis page actually invoke -- taken from
--   ExceptionCentreService.cs, not from memory -- with the migration
--   that owns each one.
--
--   The Analysis STAGE itself is migration 257. Sections 2 and 3 check
--   the two things 257 adds that nothing else does:
--     * 'SubmittedForApproval' in the status vocabulary
--     * exception_request_task, the remediation link table
--   If either is missing, 257 has not been applied to this database.
--
-- WHAT IT CANNOT TELL YOU
--   Whether the FAILURE you saw is caused by what it finds. The page's
--   message ("No exception request was specified") is raised before any
--   of these are called -- it means the id never reached the page. So
--   read section 5 too: it is the one that speaks to that message
--   directly.
-- =====================================================================
SET NOCOUNT ON;

PRINT '=== 1. Every procedure the Exception Centre / Analysis calls ===';

DECLARE @needed TABLE(
    proc_name    SYSNAME,
    owning_mig   NVARCHAR(40),
    used_by      NVARCHAR(60));

INSERT INTO @needed(proc_name, owning_mig, used_by) VALUES
    -- the list and the row menu
    (N'sp_exception_request_list',              N'161 / 192 / 260', N'Exception Centre grid'),
    (N'sp_exception_type_list',                 N'161',             N'both'),
    (N'sp_organization_practice_list',          N'161',             N'Analysis header'),
    -- the Analysis page
    (N'sp_exception_request_get',               N'161 / 260',       N'Analysis detail'),
    (N'sp_exception_request_analysis_save',     N'257',             N'Analysis save'),
    (N'sp_exception_request_submit_for_approval',N'257',            N'Analysis submit'),
    (N'sp_exception_request_task_list',         N'257',             N'Analysis tasks'),
    (N'sp_exception_request_task_link',         N'257',             N'Analysis map task'),
    (N'sp_exception_request_task_unlink',       N'257',             N'Analysis unmap'),
    (N'sp_exception_practice_task_candidates',  N'257 / 259',       N'Analysis task picker'),
    (N'sp_exception_request_history_list',      N'257',             N'Analysis history'),
    -- the approver side
    (N'sp_exception_request_approve',           N'257 (from 166)',  N'Approve'),
    (N'sp_exception_request_reject',            N'257 (from 193)',  N'Reject'),
    (N'sp_sla_override_approve',                N'192 / 193',       N'task-side requests'),
    -- evidence
    (N'sp_evidence_type_list',                  N'161',             N'attachments'),
    (N'sp_exception_request_attachment_save',   N'161',             N'attachments'),
    (N'sp_exception_request_attachment_get',    N'161',             N'attachments'),
    (N'sp_exception_request_attachment_list',   N'161',             N'attachments'),
    (N'sp_exception_request_expire_due',        N'161',             N'expiry sweep');

SELECT n.proc_name                            AS Procedure_,
       n.owning_mig                           AS OwnedByMigration,
       n.used_by                              AS UsedBy,
       CASE WHEN OBJECT_ID('grac_practice.' + n.proc_name, 'P') IS NOT NULL
            THEN 'present' ELSE '*** MISSING -- run the migration named here'
       END                                    AS State
  FROM @needed n
 ORDER BY CASE WHEN OBJECT_ID('grac_practice.' + n.proc_name, 'P') IS NULL
               THEN 0 ELSE 1 END,             -- missing ones first
          n.proc_name;

PRINT '';
PRINT '=== 2. Migration 257 marker A: the SubmittedForApproval status ===';
-- 257 section 1 widens the status vocabulary. If this is absent, the
-- Analysis stage cannot exist on this database: the menu offers Analysis
-- for Pending AND SubmittedForApproval, and submit-for-approval has
-- nowhere to move the request to.
SELECT cc.name                                AS ConstraintName,
       cc.definition                          AS Definition,
       CASE WHEN cc.definition LIKE '%SubmittedForApproval%'
            THEN 'present -- 257 applied'
            ELSE '*** MISSING SubmittedForApproval -- 257 NOT applied'
       END                                    AS Verdict
  FROM sys.check_constraints cc
 WHERE cc.parent_object_id = OBJECT_ID('grac_practice.exception_request')
   AND cc.definition LIKE '%status_code%';

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE parent_object_id = OBJECT_ID('grac_practice.exception_request')
                  AND definition LIKE '%status_code%')
    PRINT '   (no status_code CHECK found at all -- check exception_request exists)';

PRINT '';
PRINT '=== 3. Migration 257 marker B: the remediation link table ======';
SELECT CASE WHEN OBJECT_ID('grac_practice.exception_request_task','U') IS NOT NULL
            THEN 'present -- 257 applied'
            ELSE '*** MISSING exception_request_task -- 257 NOT applied'
       END                                    AS ExceptionRequestTask;

PRINT '';
PRINT '=== 4. Later exception migrations, in order ====================';
-- 258 derives the linked practice, 259 scopes the task candidates, 260
-- adds the proposed effective dates. All three re-issue procedures from
-- 257, so a database with 257 but not 260 has an Analysis page that
-- loads and a detail read that is missing columns.
SELECT '258 linked-practice derivation'  AS Migration_,
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_request_get','P') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_exception_request_get'))
                 LIKE '%linked_practice%'
            THEN 'looks applied' ELSE 'CHECK -- sp_exception_request_get has no linked_practice' END AS State
UNION ALL
SELECT '259 task-candidate scope',
       CASE WHEN OBJECT_ID('grac_practice.sp_exception_practice_task_candidates','P') IS NOT NULL
            THEN 'looks applied' ELSE '*** MISSING the candidates proc' END
UNION ALL
SELECT '260 proposed effective dates',
       CASE WHEN COL_LENGTH('grac_practice.exception_request','proposed_effective_from') IS NOT NULL
            THEN 'looks applied' ELSE '*** MISSING proposed_effective_from -- run 260' END;

PRINT '';
PRINT '=== 5. THE MESSAGE YOU ACTUALLY SAW =============================';
-- "No exception request was specified" is raised by the page BEFORE it
-- calls anything, when the id is absent from the URL. The id comes from
-- the list row: exception-centre.js writes data-exc-menu from
-- ExceptionRequestId, and the menu puts it on the URL as ?exceptionId=.
--
-- So if the grid has rows but their ids are 0 or NULL, the menu builds a
-- broken link and the page is right to refuse. This section shows what
-- the list would hand the browser.
IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
    PRINT '   exception_request table is absent -- nothing to report.';
ELSE
    EXEC sp_executesql N'
        SELECT TOP 20
               er.exception_request_id  AS ExceptionRequestId,
               er.status_code           AS StatusCode,
               er.request_title         AS RequestTitle,
               CASE WHEN er.exception_request_id IS NULL OR er.exception_request_id <= 0
                    THEN ''*** this row would build ?exceptionId=NaN''
                    ELSE ''id is fine -- the menu link for this row is valid''
               END                      AS Verdict
          FROM grac_practice.exception_request er
         ORDER BY er.exception_request_id DESC;';

PRINT '';
PRINT 'HOW TO READ THIS';
PRINT '  Section 1  any *** MISSING row names the migration to run.';
PRINT '  Sections 2/3  both must say "257 applied". If either does not,';
PRINT '                run 257_exception_analysis_stage.sql, then 258,';
PRINT '                259 and 260 in that order -- each re-issues';
PRINT '                procedures from the one before it.';
PRINT '  Section 4  fills in which of 258/259/260 is behind.';
PRINT '  Section 5  if every id there is fine and sections 1-4 are clean,';
PRINT '             the database is NOT the cause -- send me the URL the';
PRINT '             Analysis page reports and I will chase the Web tier.';
