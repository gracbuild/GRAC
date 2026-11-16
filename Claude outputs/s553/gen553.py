import re, sys, os
D = sys.argv[1]
src = open(os.path.join(D, '465_role_code_persisted.sql'), encoding='utf-8').read()
def proc(name):
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + name + r'\b.*?\nGO\n', src, re.S)
    if not m: raise SystemExit('missing ' + name)
    return m.group(0)
def rep(s, a, b):
    if s.count(a) != 1: raise SystemExit('count %d: %r' % (s.count(a), a[:80]))
    return s.replace(a, b)
save0 = proc('sp_org_role_save'); list0 = proc('sp_org_role_list')

save = save0
save = rep(save, """    END
END;
GO""", """    END

    -- 553: the role's responsibilities -- '$.responsibilityIds', the
    -- Responsibilities multi-select (an array of ids, as strings or
    -- numbers). Absent from the payload = left as they are; an empty
    -- array clears them.
    IF JSON_QUERY(@p_payload, '$.responsibilityIds') IS NOT NULL
    BEGIN
        DECLARE @resp TABLE (role_responsibility_id INT NOT NULL PRIMARY KEY);
        INSERT INTO @resp (role_responsibility_id)
        SELECT DISTINCT m.role_responsibility_id
          FROM OPENJSON(@p_payload, '$.responsibilityIds') j
          JOIN grac_practice.role_responsibility_master m
               ON m.role_responsibility_id = TRY_CAST(j.[value] AS INT)
         WHERE m.is_active = 1;

        UPDATE rr
           SET is_active = 0, updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_role_responsibility rr
         WHERE rr.role_id = @out_id AND rr.is_active = 1
           AND rr.role_responsibility_id NOT IN (SELECT role_responsibility_id FROM @resp);

        INSERT INTO grac_practice.organization_role_responsibility
            (organization_id, role_id, role_responsibility_id, is_active, entered_by)
        SELECT @role_org_id, @out_id, x.role_responsibility_id, 1, @p_usr_id
          FROM @resp x
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_responsibility rr
                            WHERE rr.role_id = @out_id AND rr.role_responsibility_id = x.role_responsibility_id
                              AND rr.is_active = 1);
    END
END;
GO""")

lst = list0
lst = rep(lst, """           r.role_name RoleName, r.description Description,""", """           r.role_name RoleName, r.description Description,
           -- 553: the role's responsibilities -- ids for the form's
           -- multi-select (comma list, read by comboChecks) and names for
           -- the grid.
           rsp.ids ResponsibilityIds, rsp.names Responsibilities,""")
lst = rep(lst, """    JOIN   grac_practice.record_status_master rs ON rs.record_status_id = r.record_status_id
""", """    JOIN   grac_practice.record_status_master rs ON rs.record_status_id = r.record_status_id
    OUTER APPLY (SELECT STRING_AGG(CAST(m.role_responsibility_id AS NVARCHAR(20)), N',')
                            WITHIN GROUP (ORDER BY m.display_order) AS ids,
                        STRING_AGG(CONVERT(NVARCHAR(MAX), m.responsibility_name), N', ')
                            WITHIN GROUP (ORDER BY m.display_order) AS names
                   FROM grac_practice.organization_role_responsibility x
                   JOIN grac_practice.role_responsibility_master m
                        ON m.role_responsibility_id = x.role_responsibility_id
                  WHERE x.role_id = r.role_id AND x.is_active = 1 AND m.is_active = 1) rsp
""")

head = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'head553.sql'), encoding='utf-8').read()
tail = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tail553.sql'), encoding='utf-8').read()
open(os.path.join(D, '553_role_responsibilities.sql'), 'w', encoding='utf-8', newline='\n').write(head + save + '\n' + lst + tail)
rb = """-- =====================================================================
-- 553 ROLLBACK -- restores the 465 sp_org_role_save / sp_org_role_list and
-- drops the 553 procedures. role_responsibility_master and
-- organization_role_responsibility are KEPT (unread). Deploy the pre-553
-- Api and Web with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
""" + save0 + '\n' + list0 + """
IF OBJECT_ID('grac_practice.sp_get_role_responsibility_lookup','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_get_role_responsibility_lookup;
GO
IF OBJECT_ID('grac_practice.sp_org_responsibility_holder_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_responsibility_holder_list;
GO
PRINT '553 rolled back (procedures). Tables kept.';
GO
"""
open(os.path.join(D, '553_role_responsibilities_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['553_role_responsibilities.sql', '553_role_responsibilities_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read(); print(f, len(b), all(c < 128 for c in b))
