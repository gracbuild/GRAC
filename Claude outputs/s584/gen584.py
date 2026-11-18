# Generates database/584_audit_finding_candidates.sql and its rollback.
#   head584.sql -- header, fn_org_assurance_observation_subjects
#   gen116b.sql -- sp_custom_gap_generate_from_assurance_observation, the
#                  116b body (byte-for-byte); 584 adds the Informational rule
#   tail584.sql -- audit source, raise risk, traceability trigger, checks
# Run: python3 "Claude outputs/s584/gen584.py"
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
def rd(n): return open(os.path.join(here, n), encoding='ascii').read()
def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count: sys.exit('rep: expected %d, found %d: %r' % (count, n, old[:80]))
    return s.replace(old, new)
orig = rd('gen116b.sql')
gen = rep(orig, """    IF @obs_status <> N'Accepted'
        THROW 55013, 'Only Accepted observations can generate a gap.', 1;
""", """    IF @obs_status <> N'Accepted'
        THROW 55013, 'Only Accepted observations can generate a gap.', 1;
    -- 584 (CR2 8.4): an advisory / Informational finding is not a Gap Candidate.
    IF @sev_code = N'Informational'
        THROW 55014, 'An Informational finding does not become a Gap Candidate.', 1;
""")
out = rd('head584.sql') + gen + rd('tail584.sql')
out.encode('ascii')
rb = """-- 584 rollback  Audit Intelligence -- audit findings to Gap and Risk candidates
-- Drops the traceability trigger, the raise-risk and audit-source
-- procedures and the finding-subject function; restores
-- sp_custom_gap_generate_from_assurance_observation to its 116b body.
-- Kept: risk candidates already raised and the RISK mappings the trigger
-- made (they are ordinary data; Framework & Practice Mapping can deactivate
-- them).
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.trg_pm_risk_candidate_audit_subject_map','TR') IS NOT NULL DROP TRIGGER grac_practice.trg_pm_risk_candidate_audit_subject_map;
IF OBJECT_ID('grac_practice.sp_org_assurance_finding_raise_risk','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_finding_raise_risk;
IF OBJECT_ID('grac_practice.sp_custom_gap_audit_source','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_custom_gap_audit_source;
IF OBJECT_ID('grac_practice.fn_org_assurance_observation_subjects') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_observation_subjects;
GO
-- sp_custom_gap_generate_from_assurance_observation: the 116b body.
""" + orig + """
PRINT '584 rolled back: trigger, procedures and function dropped; the gap generator back to 116b.';
GO
"""
rb.encode('ascii')
dbdir = os.path.normpath(os.path.join(here, '..', '..', 'database'))
if not os.path.isdir(dbdir): dbdir = os.path.normpath(os.path.join(here, '..', 'database'))
for name, text in (('584_audit_finding_candidates.sql', out), ('584_audit_finding_candidates_rollback.sql', rb)):
    open(os.path.join(dbdir, name), 'w', encoding='ascii', newline='\n').write(text)
    print('written', name, len(text.splitlines()), 'lines')
