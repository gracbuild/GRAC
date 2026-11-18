# gen581.py -- builds database/581_audit_risk_intelligence.sql
# Run from the PracticeManagement folder:
#   python3 "Claude outputs/s581/gen581.py"
# Re-issues procedure bodies from 574 and 580 with exact-count replacements
# (a body that no longer matches stops the build instead of being guessed).
import os, re, sys

ROOT = os.getcwd()
DB   = os.path.join(ROOT, 'database')
HERE = os.path.join(ROOT, 'Claude outputs', 's581')

def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()

def body(text, kind, name):
    m = re.search(r'CREATE OR ALTER ' + kind + r' grac_practice\.' + re.escape(name) + r'\b.*?\nGO\n', text, re.S)
    if not m:
        sys.exit('not found: ' + name)
    return m.group(0)

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('expected %d x %r, found %d' % (count, old[:80], n))
    return s.replace(old, new)

s574 = read(os.path.join(DB, '574_risk_methodology_matrix.sql'))
s580 = read(os.path.join(DB, '580_audit_universe_mapping.sql'))

# ---------------------------------------------------------------------
# 2. fn_risk_register_methodology_status + the summary re-issued
# ---------------------------------------------------------------------
proc = body(s574, 'PROCEDURE', 'sp_risk_methodology_register_summary')
start = proc.index('    DECLARE @mv_id BIGINT')
end   = proc.index('      ) prev;\n') + len('      ) prev;\n')
first = proc[start:end]

stmt = first[first.index(';WITH r AS ('):]
stmt = rep(stmt, ';WITH r AS (',
    "WITH mv AS (\n"
    "        SELECT TOP (1) methodology_version_id AS mv_id, appetite_enabled AS appetite_on,\n"
    "               trend_enabled AS trend_on, target_rating_enabled AS target_on\n"
    "          FROM grac_practice.risk_methodology_version\n"
    "         WHERE organization_id = @organization_id AND status = N'Published'\n"
    "         ORDER BY methodology_version_id DESC\n"
    "    ),\n"
    "    r AS (")
for var, col in (('@mv_id', 'mv.mv_id'), ('@appetite_on', 'mv.appetite_on'),
                 ('@trend_on', 'mv.trend_on'), ('@target_on', 'mv.target_on')):
    if stmt.count(var) == 0:
        sys.exit('574 body changed: ' + var)
    stmt = stmt.replace(var, col)
stmt = rep(stmt, '      FROM cur c\n', '      FROM cur c\n      LEFT JOIN mv ON 1 = 1\n')
stmt = rep(stmt, '      ) prev;\n', '      ) prev;\n')

fn = ("-- =====================================================================\n"
      "-- 2. The methodology status of every risk (appetite, trend, target),\n"
      "--    taken out of sp_risk_methodology_register_summary (574 body) so\n"
      "--    the Risk Centre and Audit Intelligence read one rule.\n"
      "-- =====================================================================\n"
      "CREATE OR ALTER FUNCTION grac_practice.fn_risk_register_methodology_status(@organization_id BIGINT)\n"
      "RETURNS TABLE\nAS\nRETURN\n    " + stmt.rstrip() + "\nGO\n\n")

proc_new = proc[:start] + ("    -- 581: the first set is fn_risk_register_methodology_status (the same\n"
                           "    -- columns and values the 574 body computed here).\n"
                           "    SELECT * FROM grac_practice.fn_risk_register_methodology_status(@organization_id);\n") + proc[end:]
proc_new = "-- Re-issued by 581 from the 574 body: first result set from the function.\n" + proc_new + "\n"

# ---------------------------------------------------------------------
# 3. The 580 mapping objects with level RISK
# ---------------------------------------------------------------------
LEVELS_OLD = "IF @mapping_level NOT IN (N'FRAMEWORK', N'RELEASE', N'CONTROL', N'REQUIREMENT', N'OBLIGATION', N'PRACTICE', N'PRACTICE_INSTANCE')"
LEVELS_NEW = "IF @mapping_level NOT IN (N'FRAMEWORK', N'RELEASE', N'CONTROL', N'REQUIREMENT', N'OBLIGATION', N'PRACTICE', N'PRACTICE_INSTANCE', N'RISK')"

ref = body(s580, 'FUNCTION', 'fn_org_assurance_universe_mapping_ref')
ref = rep(ref, "     WHERE o.organization_id = @organization_id AND o.status = N'Active';\nGO\n",
    "     WHERE o.organization_id = @organization_id AND o.status = N'Active'\n"
    "    UNION ALL\n"
    "    -- 581: enterprise risks of the register (not Closed as Duplicate / Rejected)\n"
    "    SELECT N'RISK', CAST(rr.risk_register_id AS NVARCHAR(80)), rr.risk_number, rr.risk_title,\n"
    "           NULL, NULL, NULL, NULL, NULL, NULL,\n"
    "           NULL, NULL, NULL, NULL,\n"
    "           ISNULL(rr.risk_category_name + N' / ', N'') + rr.status_code\n"
    "      FROM grac_practice.risk_register rr\n"
    "     WHERE rr.organization_id = @organization_id\n"
    "       AND rr.status_code NOT IN (N'ClosedAsDuplicate', N'Rejected');\nGO\n")

lst = body(s580, 'PROCEDURE', 'sp_org_assurance_universe_mapping_list')
lst = rep(lst, "WHEN N'OBLIGATION' THEN 5 WHEN N'PRACTICE' THEN 6 ELSE 7 END,",
               "WHEN N'OBLIGATION' THEN 5 WHEN N'PRACTICE' THEN 6\n                                   WHEN N'PRACTICE_INSTANCE' THEN 7 ELSE 8 END,")

opt = body(s580, 'PROCEDURE', 'sp_org_assurance_universe_mapping_options')
opt = rep(opt, LEVELS_OLD, LEVELS_NEW)

add = body(s580, 'PROCEDURE', 'sp_org_assurance_universe_mapping_add')
add = rep(add, LEVELS_OLD, LEVELS_NEW)

sug = body(s580, 'PROCEDURE', 'sp_org_assurance_universe_mapping_suggest')
sug = rep(sug, "\n    DECLARE @me NVARCHAR(240)", read(os.path.join(HERE, 'risk_suggest581.sql')).rstrip('\n') + "\n\n    DECLARE @me NVARCHAR(240)")

reissued = ("-- =====================================================================\n"
            "-- 3. The 580 mapping objects, re-issued with level RISK\n"
            "-- =====================================================================\n")
for b in (ref, lst, opt, add, sug):
    reissued += "-- Re-issued by 581 from the 580 body (level RISK).\n" + b + "\n"

out = (read(os.path.join(HERE, 'head581.sql')) + "\n" + fn
       + "-- =====================================================================\n"
         "-- 2b. sp_risk_methodology_register_summary re-issued (574 body)\n"
         "-- =====================================================================\n"
       + proc_new + reissued + read(os.path.join(HERE, 'tail581.sql')))
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d' % i)
with open(os.path.join(DB, '581_audit_risk_intelligence.sql'), 'w', encoding='utf-8', newline='\n') as f:
    f.write(out)
print('written database/581_audit_risk_intelligence.sql', len(out.splitlines()), 'lines')
