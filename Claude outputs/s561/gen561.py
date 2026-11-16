import re, sys, os
ROOT = sys.argv[1]
DB = os.path.join(ROOT, 'database')

# ---------------------------------------------------------------- SQL 561
s = open(os.path.join(DB, '551_question_set_versioning.sql'), encoding='utf-8').read()
m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.sp_org_assurance_question_set_list\b.*?\nGO\n', s, re.S)
orig = m.group(0)
old = "                   AND q.is_active = 1"
assert orig.count(old) == 4, orig.count(old)
body = orig.replace(old, old + "\n                   AND ISNULL(q.status, N'Active') = N'Active' /* 561: questions in use */")

head = r"""-- =====================================================================
-- 561  Question Sets -- Testing Guidance and question Status
--      (Audit Change spec 4.2.3, P0 phase B)
--
-- REQUEST (2026-11-15, sir): phase B of docs/audit-change-p0-plan.md.
--   Each question carries: Question Code, Question, Response Type,
--   Mandatory, Weight, Testing Guidance, Expected Evidence, Status
--   (Active / Inactive). Testing Guidance is THE field for test
--   procedures -- simple instructions or detailed step-by-step procedures;
--   no separate Test Procedure master.
--
-- WHAT IS ALREADY IN PLACE (no change here)
--   * Testing Guidance = org_assurance_question.help_text (NVARCHAR(MAX),
--     077); Api field HelpText. The page only relabels it.
--   * Status = org_assurance_question.status, Active / Inactive (520),
--     saved by sp_org_assurance_question_set_questions_save (551).
--   * An Inactive question is already left out when an execution takes
--     its questions snapshot (sp_org_assurance_execution_materialize, 555:
--     ISNULL(q.status, N'Active') = N'Active').
--
-- WHAT THIS DOES
--   sp_org_assurance_question_set_list (551 body) -- Questions, Mandatory
--   and Total Weight count only Active questions (the ones an audit uses);
--   an Inactive question was counted before.
--
-- DEPENDS ON: 551, 520 (status column).
-- Rollback: 561_question_set_testing_guidance_rollback.sql (551 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_question','status') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_question_set','root_question_set_id') IS NULL
BEGIN
    PRINT 'ABORT (561): run 520 and 551 first. Nothing was changed.';
    RAISERROR('561_question_set_testing_guidance: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

"""
tail = "\nPRINT '561 sp_org_assurance_question_set_list: counts Active questions only.';\nGO\nSET NOEXEC OFF;\nGO\n"
open(os.path.join(DB, '561_question_set_testing_guidance.sql'), 'w', encoding='utf-8', newline='\n').write(head + body + tail)

rb = r"""-- =====================================================================
-- 561 ROLLBACK -- sp_org_assurance_question_set_list back to its 551 body
-- (counts every question, Active or Inactive). Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

""" + orig + "\nPRINT '561 rollback: sp_org_assurance_question_set_list back to 551.';\nGO\n"
open(os.path.join(DB, '561_question_set_testing_guidance_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
print('sql ok')

# ---------------------------------------------------------------- Web
def patch(rel, pairs):
    p = os.path.join(ROOT, rel)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    bom = raw.startswith(b'\xef\xbb\xbf')
    t = raw.decode('utf-8-sig').replace('\r\n', '\n')
    for o, n in pairs:
        c = t.count(o)
        assert c == 1, (rel, o[:90], c)
        t = t.replace(o, n)
    if crlf: t = t.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + t.encode('utf-8'))
    print('patched', rel)

Q = 'src/PracticeManagement.Web/Views/Practice/Partials/org-assurance-question-sets.cshtml'
patch(Q, [
# header comment
("""      ?new=1 opens a new set directly""",
"""      561 (2026-11-15, sir -- Audit Change spec 4.2.3): the row's
      "Description / Guidance" is now TESTING GUIDANCE -- the field for test
      procedures, simple or step-by-step (help_text, longer box) -- and the
      grid has a Status column again (Active / Inactive; a new row starts
      Active). An Inactive question stays in the set but is not taken into
      an execution; the list's Questions / Mandatory / Total Weight count
      Active questions only. The read-only view shows Status too.
      ?new=1 opens a new set directly"""),
# read table header: Status after Weight
("""                            <th style="text-align:right;">Weight</th>
""",
"""                            <th style="text-align:right;">Weight</th>
                            <th>Status</th>
"""),
# edit grid header: Status after Weight
("""                        <th style="width:84px;">Weight</th>
                        <th style="width:84px;"></th>""",
"""                        <th style="width:84px;">Weight</th>
                        <th style="width:110px;">Status</th>
                        <th style="width:84px;"></th>"""),
# read rows
("""            const sub = [r.help ? 'Guidance: ' + r.help : '', r.expected ? 'Expected evidence: ' + r.expected : '']""",
"""            const sub = [r.help ? 'Testing guidance: ' + r.help : '', r.expected ? 'Expected evidence: ' + r.expected : '']"""),
("""                 + '<td style="text-align:right;">' + wf.escape(r.weight) + '</td></tr>';
        }).join('') : '<tr><td colspan="6" class="pm-empty">No questions in this version yet.'""",
"""                 + '<td style="text-align:right;">' + wf.escape(r.weight) + '</td>'
                 + '<td>' + wf.escape(r.status || 'Active') + '</td></tr>';
        }).join('') : '<tr><td colspan="7" class="pm-empty">No questions in this version yet.'"""),
# edit grid
("""            body.innerHTML = '<tr><td colspan="7" class="pm-empty">No questions. Click "Add Row" to add one.</td></tr>';""",
"""            body.innerHTML = '<tr><td colspan="8" class="pm-empty">No questions. Click "Add Row" to add one.</td></tr>';"""),
("""                 + '<td><input class="pm-input" type="number" step="0.01" min="0" data-f="weight" value="' + wf.escape(r.weight) + '" aria-label="Weight" /></td>'
""",
"""                 + '<td><input class="pm-input" type="number" step="0.01" min="0" data-f="weight" value="' + wf.escape(r.weight) + '" aria-label="Weight" /></td>'
                 + '<td><select class="pm-input" data-f="status" aria-label="Status">'
                 +     ['Active', 'Inactive'].map(function (s) {
                           return '<option value="' + s + '"' + ((r.status || 'Active') === s ? ' selected' : '') + '>' + s + '</option>';
                       }).join('')
                 + '</select></td>'
"""),
("""title="Guidance / Expected Evidence" aria-expanded=""",
"""title="Testing Guidance / Expected Evidence" aria-expanded="""),
("""><td colspan="7">'""",
"""><td colspan="8">'"""),
("""'<label class="pm-field"><span>Description / Guidance</span><textarea class="pm-input" rows="2" maxlength="4000" data-f="help">'""",
"""'<label class="pm-field"><span>Testing Guidance</span><textarea class="pm-input" rows="4" maxlength="20000" data-f="help">'"""),
])
