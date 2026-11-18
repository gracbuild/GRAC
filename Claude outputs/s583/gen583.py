# Generates database/583_audit_plan_recommendations.sql
#   head583.sql  -- header, column, tables, shared functions
#   ri581.sql    -- sp_org_assurance_universe_risk_intelligence, 581 body,
#                   re-issued to read the shared functions (exact-count rep)
#   tail583.sql  -- engine procedures, menu, verification
# Run: python3 "Claude outputs/s583/gen583.py" (from the repo root) or
# from this folder; writes ../../database/583_audit_plan_recommendations.sql.
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
def rd(n): return open(os.path.join(here, n), encoding='ascii').read()
def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count: sys.exit('rep: expected %d, found %d: %r' % (count, n, old[:80]))
    return s.replace(old, new)

ri = rd('ri581.sql')
ri = rep(ri, """    INSERT INTO @inst (practice_instance_id, practice_id, mapping_status)
    SELECT pi.practice_instance_id, pi.practice_id, MAX(m.mapping_status)
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN grac_practice.practice_instance pi
           ON pi.practice_instance_id = TRY_CAST(m.record_key AS BIGINT) AND pi.organization_id = @organization_id
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = N'PRACTICE_INSTANCE'
       AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED')
     GROUP BY pi.practice_instance_id, pi.practice_id;
""", """    INSERT INTO @inst (practice_instance_id, practice_id, mapping_status)   -- 583: the shared rule
    SELECT practice_instance_id, practice_id, mapping_status
      FROM grac_practice.fn_org_assurance_universe_subject_instances(@organization_id)
     WHERE universe_subject_id = @universe_subject_id;
""")
ri = rep(ri, """    INSERT INTO @gap (custom_gap_id, practice_instance_id)
    SELECT g.custom_gap_id, MIN(i.practice_instance_id)
      FROM grac_practice.custom_gap g
      JOIN @inst i
           ON (g.source_reference_type = N'PracticeInstance' AND g.source_reference_id = i.practice_instance_id)
           OR EXISTS (SELECT 1
                        FROM grac_practice.custom_gap_practice_map gm
                        JOIN grac_practice.record_status_master rs
                          ON rs.record_status_id = gm.record_status_id AND rs.status_code = N'Active'
                       WHERE gm.custom_gap_id = g.custom_gap_id AND gm.practice_instance_id = i.practice_instance_id)
     WHERE g.organization_id = @organization_id
     GROUP BY g.custom_gap_id;
""", """    INSERT INTO @gap (custom_gap_id, practice_instance_id)   -- 583: the shared rule
    SELECT custom_gap_id, practice_instance_id
      FROM grac_practice.fn_org_assurance_universe_subject_gaps(@organization_id)
     WHERE universe_subject_id = @universe_subject_id;
""")
ri = rep(ri, """    INSERT INTO @risk (risk_register_id, mapping_status, mapping_source, basis)
    SELECT rr.risk_register_id, m.mapping_status, m.mapping_source, m.suggestion_basis
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN grac_practice.risk_register rr
           ON rr.risk_register_id = TRY_CAST(m.record_key AS BIGINT) AND rr.organization_id = @organization_id
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = N'RISK'
       AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED');
""", """    INSERT INTO @risk (risk_register_id, mapping_status, mapping_source, basis)   -- 583: the shared rule
    SELECT risk_register_id, mapping_status, mapping_source, suggestion_basis
      FROM grac_practice.fn_org_assurance_universe_subject_risks(@organization_id)
     WHERE universe_subject_id = @universe_subject_id;
""")
ri = rep(ri, """      FROM grac_practice.org_assurance_observation o
      JOIN grac_practice.org_assurance_execution_entity ee
           ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
          AND ee.dimension_code = N'PRACTICE_INSTANCE'
      JOIN @inst x ON x.practice_instance_id = ee.entity_id
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
     WHERE o.organization_id = @organization_id AND o.is_active = 1
""", """      FROM grac_practice.fn_org_assurance_universe_subject_findings(@organization_id) f   -- 583: the shared rule
      JOIN grac_practice.org_assurance_observation o ON o.org_assurance_observation_id = f.org_assurance_observation_id
      JOIN grac_practice.org_assurance_execution_entity ee
           ON ee.org_assurance_execution_entity_id = f.org_assurance_execution_entity_id
      LEFT JOIN grac_practice.org_assurance_observation_status_master os
             ON os.org_assurance_observation_status_id = o.observation_status_id
     WHERE f.universe_subject_id = @universe_subject_id
""")
ri = rep(ri, """           (SELECT COUNT(*) FROM grac_practice.org_assurance_observation o
              JOIN grac_practice.org_assurance_execution_entity ee
                   ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
                  AND ee.dimension_code = N'PRACTICE_INSTANCE'
              JOIN @inst x ON x.practice_instance_id = ee.entity_id
             WHERE o.organization_id = @organization_id AND o.is_active = 1) AS Findings;
""", """           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_findings(@organization_id) f
             WHERE f.universe_subject_id = @universe_subject_id) AS Findings;
""")
ri = rep(ri, "CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_risk_intelligence",
"""-- =====================================================================
-- 4. sp_org_assurance_universe_risk_intelligence re-issued (581 body),
--    reading the shared rules of section 3. Same result sets and columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_risk_intelligence""")
out = rd('head583.sql') + '\n' + ri + '\n' + rd('tail583.sql')
out.encode('ascii')
dst = os.path.normpath(os.path.join(here, '..', '..', 'database', '583_audit_plan_recommendations.sql'))
if not os.path.isdir(os.path.dirname(dst)):
    dst = os.path.normpath(os.path.join(here, '..', 'database', '583_audit_plan_recommendations.sql'))
open(dst, 'w', encoding='ascii', newline='\n').write(out)
print('written', dst, len(out.splitlines()), 'lines')
