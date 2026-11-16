import re, sys, os
D = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(D, '555_my_audits_freeze_scope.sql'), encoding='utf-8').read()
m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.sp_org_assurance_execution_live_scope\b.*?\nGO\n', src, re.S)
if not m: raise SystemExit('missing live_scope in 555')
old = m.group(0)

head = """-- =====================================================================
-- 556  Phase 4 -- Continuous Assurance view (audit flow redesign)
--
-- REQUEST (2026-11-14, sir) -- docs/audit-flow-redesign.md Phase 4,
-- decision 4: Continuous Assurance covers every scope item -- practice
-- instances directly; assets, departments, locations (branches), vendors,
-- applications and processes through the practice instances they are
-- resolved against in Operationalize (practice_dependency_resolution);
-- asset categories through their assets.
--
-- WHAT THE AUDITOR SEES (My Audits -> Continuous Assurance, under the row)
--   For the execution's scope (frozen, or live = the scope now, branch-
--   narrowed): each scope item -> its practice instances -> their active
--   Execution / Assurance obligations -> the obligation's implementation
--   status and the last task raised for it (number, status, due date).
--   Summary: each obligation counted ONCE (by status, by last task status);
--   detail: an obligation is shown under every item that brings it in.
--   Read-only.
--
-- WHAT THIS DOES
--   sp_org_assurance_execution_live_scope (555) re-issued with @mode:
--   SCOPE (default) -- unchanged output; ASSURANCE -- two result sets
--   (summary, detail). One procedure resolves the items, so Freeze, the
--   scope view and this view never disagree. No schema change.
--
-- DEPENDS ON: 555 (live scope), 140 / 449 (obligations, occurrence tasks).
-- Rollback: 556_continuous_assurance_view_rollback.sql (555 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope','P') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_execution','scope_frozen_at') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','obligation_type_code') IS NULL
   OR OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN
    PRINT 'ABORT (556): run 555 (and 449) first. Nothing was changed.';
    RAISERROR('556_continuous_assurance_view: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

"""
tail = """
SELECT '556 live scope has ASSURANCE mode' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope')) LIKE '%ASSURANCE%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '556 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
"""
body = open(os.path.join(HERE, 'body556.sql'), encoding='utf-8').read()
open(os.path.join(D, '556_continuous_assurance_view.sql'), 'w', encoding='utf-8', newline='\n').write(head + body + tail)
rb = """-- =====================================================================
-- 556 ROLLBACK -- restores sp_org_assurance_execution_live_scope as 555
-- issued it (no @mode). Deploy the pre-556 Api and Web with it.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
""" + old + """
PRINT '556 rolled back.';
GO
"""
open(os.path.join(D, '556_continuous_assurance_view_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['556_continuous_assurance_view.sql', '556_continuous_assurance_view_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read(); print(f, len(b), all(c < 128 for c in b))
