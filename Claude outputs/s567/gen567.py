# gen567.py -- builds database/567_audit_working_papers.sql (+ rollback)
# from head567.sql / tail567.sql / rbhead567.sql and the 099 body of
# sp_org_assurance_execution_transition (re-issued with the Submit gate).
# Run from the repo root:  python3 "Claude outputs/s567/gen567.py"
import sys, os, re

DB = 'database'
HERE = os.path.dirname(os.path.abspath(__file__))

def body(fname, kind, name):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER ' + kind + r' grac_practice\.' + re.escape(name) + r'[\s(]', s)
    if not m:
        sys.exit('not found: ' + name + ' in ' + fname)
    end = s.index('\nGO\n', m.start())
    return s[m.start():end] + '\nGO\n'

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('replace count %d != %d for: %r' % (n, count, old[:90]))
    return s.replace(old, new)

trans = body('099_org_assurance_execution_procs.sql', 'PROCEDURE', 'sp_org_assurance_execution_transition')
t = rep(trans,
"""    UPDATE grac_practice.org_assurance_execution
    SET execution_status_id = @to_id,""",
"""    -- 567: an audit is submitted once its working papers are done -- every
    -- question concluded, every paper approved, the audit conclusion written.
    IF @to_code = N'Submitted'
    BEGIN
        EXEC grac_practice.sp_org_assurance_wp_question_sync @execution_id = @execution_id, @actor = @actor;
        IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution_question q
                    WHERE q.org_assurance_execution_id = @execution_id AND q.conclusion_code IS NULL)
           OR EXISTS (SELECT 1 FROM grac_practice.org_assurance_working_paper p
                       WHERE p.org_assurance_execution_id = @execution_id AND p.is_active = 1
                         AND p.review_status <> N'Approved')
            THROW 54064, 'Every question must be concluded and every working paper approved (Workpapers) before the audit is submitted.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution
                        WHERE org_assurance_execution_id = @execution_id
                          AND NULLIF(LTRIM(RTRIM(audit_conclusion)), N'') IS NOT NULL)
            THROW 54064, 'Write the audit conclusion (Workpapers) before the audit is submitted.', 1;
    END

    UPDATE grac_practice.org_assurance_execution
    SET execution_status_id = @to_id,""")

MIGRATE = """-- =====================================================================
-- 9. The 558 answers become working papers: per answered question one
--    Approved paper (the answer's result, its description as the
--    conclusion / deviations), the question concluded the same, a finding
--    the answer raised linked to the paper; the score worked out.
-- =====================================================================
DECLARE @ex BIGINT;
DECLARE c567 CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT org_assurance_execution_id FROM grac_practice.org_assurance_execution_response;
OPEN c567;
FETCH NEXT FROM c567 INTO @ex;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_org_assurance_wp_question_sync @execution_id = @ex, @actor = N'migration-567';
    FETCH NEXT FROM c567 INTO @ex;
END
CLOSE c567;
DEALLOCATE c567;

INSERT INTO grac_practice.org_assurance_working_paper
    (organization_id, org_assurance_execution_id, execution_question_id, paper_no, paper_code,
     testing_guidance, procedure_performed, test_result, deviations, conclusion, review_status,
     prepared_by_employee_id, prepared_by_name, submitted_dt, approved_by_name, approved_dt, entered_by)
SELECT r.organization_id, r.org_assurance_execution_id, q.execution_question_id, 1,
       LEFT(CONCAT(e.execution_code, N'-', ISNULL(q.question_code, CONVERT(NVARCHAR(30), q.execution_question_id)), N'-WP1'), 160),
       q.testing_guidance,
       N'Answered in My Audits before working papers (558).',
       CASE r.result_code WHEN N'Compliant' THEN N'SATISFACTORY' WHEN N'NotCompliant' THEN N'UNSATISFACTORY' ELSE N'NA' END,
       CASE WHEN r.result_code = N'NotCompliant' THEN r.description END,
       ISNULL(r.description, CASE r.result_code WHEN N'Compliant' THEN N'Compliant' WHEN N'NotCompliant' THEN N'Not compliant'
                                                ELSE N'Not applicable' END),
       N'Approved', e.owner_employee_id, e.owner_display_name,
       ISNULL(r.updated_dt, r.answered_dt), N'migration-567', ISNULL(r.updated_dt, r.answered_dt), N'migration-567'
  FROM grac_practice.org_assurance_execution_response r
  JOIN grac_practice.org_assurance_execution e
       ON e.org_assurance_execution_id = r.org_assurance_execution_id
  JOIN grac_practice.org_assurance_execution_question q
       ON q.org_assurance_execution_id = r.org_assurance_execution_id AND q.question_id = r.question_id
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_working_paper p
                    WHERE p.execution_question_id = q.execution_question_id);
PRINT '567.9: working papers from 558 answers = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE q
   SET conclusion_code = CASE r.result_code WHEN N'Compliant' THEN N'SATISFACTORY' WHEN N'NotCompliant' THEN N'UNSATISFACTORY' ELSE N'NA' END,
       concluded_by = N'migration-567', concluded_dt = ISNULL(r.updated_dt, r.answered_dt)
  FROM grac_practice.org_assurance_execution_question q
  JOIN grac_practice.org_assurance_execution_response r
       ON r.org_assurance_execution_id = q.org_assurance_execution_id AND r.question_id = q.question_id
 WHERE q.conclusion_code IS NULL;

UPDATE o
   SET observation_origin_code = N'TESTING', org_assurance_working_paper_id = p.working_paper_id
  FROM grac_practice.org_assurance_observation o
  JOIN grac_practice.org_assurance_execution_response r ON r.org_assurance_observation_id = o.org_assurance_observation_id
  JOIN grac_practice.org_assurance_execution_question q
       ON q.org_assurance_execution_id = r.org_assurance_execution_id AND q.question_id = r.question_id
  JOIN grac_practice.org_assurance_working_paper p ON p.execution_question_id = q.execution_question_id AND p.paper_no = 1
 WHERE o.org_assurance_working_paper_id IS NULL;

DECLARE c567s CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT org_assurance_execution_id FROM grac_practice.org_assurance_execution_question
     WHERE conclusion_code IS NOT NULL;
OPEN c567s;
FETCH NEXT FROM c567s INTO @ex;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_org_assurance_execution_score_refresh @execution_id = @ex;
    FETCH NEXT FROM c567s INTO @ex;
END
CLOSE c567s;
DEALLOCATE c567s;
GO
"""

head = open(os.path.join(HERE, 'head567.sql'), encoding='utf-8').read()
tail = open(os.path.join(HERE, 'tail567.sql'), encoding='utf-8').read()
out = (head
       + '-- =====================================================================\n'
       + '-- 10. sp_org_assurance_execution_transition (099 body) + the Submit gate\n'
       + '-- =====================================================================\n' + t + '\n'
       + MIGRATE + '\n' + tail)
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d: %r' % (i, out[i-40:i+10]))
open(os.path.join(DB, '567_audit_working_papers.sql'), 'w', encoding='ascii', newline='\n').write(out)

rb = open(os.path.join(HERE, 'rbhead567.sql'), encoding='utf-8').read()
rb_out = (rb + '-- sp_org_assurance_execution_transition: 099 body\n' + trans + '\n'
          + "PRINT '567 rolled back: the transition back to 099; working paper procedures and functions dropped; Workpapers menu Inactive, Observations back to 470; tables and columns kept (the working papers stay as data).';\nGO\n")
for i, ch in enumerate(rb_out):
    if ord(ch) > 127:
        sys.exit('non-ASCII in rollback at %d' % i)
open(os.path.join(DB, '567_audit_working_papers_rollback.sql'), 'w', encoding='ascii', newline='\n').write(rb_out)
print('567 written:', len(out), 'chars; rollback', len(rb_out))
