# gen563.py -- builds database/563_scope_review_confirm.sql (+ rollback)
# from the earlier procedure bodies (562 discover, 556 live_scope,
# 555 freeze_scope), patched with exact-count replaces.
# Run from the repo root:  python3 "Claude outputs/s563/gen563.py"
import re, sys, os

DB = 'database'

def body(fname, proc):
    s = open(os.path.join(DB, fname), encoding='utf-8').read()
    start = s.index('CREATE OR ALTER PROCEDURE grac_practice.' + proc + '\n')
    end = s.index('\nGO\n', start)
    return s[start:end] + '\nGO\n'

def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit('replace count %d != %d for: %r' % (n, count, old[:80]))
    return s.replace(old, new)

disc562 = body('562_scope_subjects_discovery.sql', 'sp_org_assurance_scope_discover')
live556 = body('556_continuous_assurance_view.sql', 'sp_org_assurance_execution_live_scope')
frz555  = body('555_my_audits_freeze_scope.sql', 'sp_org_assurance_execution_freeze_scope')

# ---------------------------------------------------------------- live_scope
live = rep(live556,
"""    IF ISNULL(@mode, N'SCOPE') <> N'ASSURANCE'
    BEGIN""",
"""    -- 563: a caller that created #scope_review_pi (the scope discovery of
    -- an engagement) gets the items there instead of a result set.
    IF OBJECT_ID('tempdb..#scope_review_pi') IS NOT NULL AND ISNULL(@mode, N'SCOPE') <> N'ASSURANCE'
    BEGIN
        INSERT INTO #scope_review_pi (dimension_code, entity_id)
        SELECT DISTINCT dimension_code, entity_id FROM @ents WHERE entity_id IS NOT NULL;
        RETURN;
    END

    IF ISNULL(@mode, N'SCOPE') <> N'ASSURANCE'
    BEGIN""")

# ---------------------------------------------------------------- discover
disc = rep(disc562,
"""    @version_id      BIGINT = NULL      -- default: the current version
AS""",
"""    @version_id      BIGINT = NULL,     -- default: the current version
    @execution_id    BIGINT = NULL      -- 563: an engagement's scope (Step 3)
AS""")
disc = rep(disc,
"""    IF @version_id IS NULL SET @version_id = @current_version_id;""",
"""    -- 563: for an engagement, its own definition version.
    IF @execution_id IS NOT NULL
    BEGIN
        DECLARE @exec_version_id BIGINT;
        SELECT @exec_version_id = e.org_assurance_definition_version_id
          FROM grac_practice.org_assurance_execution e
         WHERE e.org_assurance_execution_id  = @execution_id
           AND e.organization_id             = @organization_id
           AND e.org_assurance_definition_id = @definition_id
           AND e.is_active = 1;
        IF @exec_version_id IS NULL
            THROW 54010, 'Execution not found or not accessible in this organization.', 1;
        SET @version_id = @exec_version_id;
    END
    IF @version_id IS NULL SET @version_id = @current_version_id;""")
disc = rep(disc,
"""    WHERE s.dimension_code = N'PRACTICE_INSTANCE';

    CREATE TABLE #inst""",
"""    WHERE s.dimension_code = N'PRACTICE_INSTANCE';

    -- 563: an engagement's review covers the instances of ITS scope -- the
    -- frozen entities, or the scope now narrowed to its Branch -- read
    -- through sp_org_assurance_execution_live_scope, so Freeze, View Scope,
    -- Continuous Assurance and this review never disagree.
    IF @execution_id IS NOT NULL
    BEGIN
        CREATE TABLE #scope_review_pi (dimension_code NVARCHAR(60) NULL, entity_id BIGINT NULL);
        EXEC grac_practice.sp_org_assurance_execution_live_scope
             @organization_id = @organization_id,
             @execution_id    = @execution_id,
             @actor           = N'system';
        DELETE p FROM #pi p
         WHERE NOT EXISTS (SELECT 1 FROM #scope_review_pi s
                            WHERE s.dimension_code = N'PRACTICE_INSTANCE'
                              AND s.entity_id      = p.practice_instance_id);
        INSERT #pi (practice_instance_id, reason)
        SELECT DISTINCT s.entity_id, N'In the engagement scope'
          FROM #scope_review_pi s
         WHERE s.dimension_code = N'PRACTICE_INSTANCE'
           AND NOT EXISTS (SELECT 1 FROM #pi p WHERE p.practice_instance_id = s.entity_id);
    END

    CREATE TABLE #inst""")
disc = rep(disc,
"""    -- Result 1: categories
    SELECT c.category_code AS CategoryCode,
           c.category_name AS CategoryName,
           c.display_order AS DisplayOrder,
           (SELECT COUNT_BIG(*) FROM #out o WHERE o.category_code = c.category_code) AS ItemCount,
           CAST(ISNULL(sc.is_included, 1) AS BIT) AS IsIncluded
    FROM #cat c
    LEFT JOIN grac_practice.org_assurance_scope_category sc
           ON sc.org_assurance_definition_version_id = @version_id
          AND sc.category_code = c.category_code
          AND sc.is_active = 1
    ORDER BY c.display_order;
""",
"""    -- Result 1: categories
    SELECT c.category_code AS CategoryCode,
           c.category_name AS CategoryName,
           c.display_order AS DisplayOrder,
           (SELECT COUNT_BIG(*) FROM #out o WHERE o.category_code = c.category_code) AS ItemCount,
           CAST(ISNULL(sc.is_included, 1) AS BIT) AS IsIncluded
    INTO #res_cat
    FROM #cat c
    LEFT JOIN grac_practice.org_assurance_scope_category sc
           ON sc.org_assurance_definition_version_id = @version_id
          AND sc.category_code = c.category_code
          AND sc.is_active = 1;

    -- 563: a caller that created #scope_review_cat / #scope_review_out
    -- (the engagement's review, its freeze) gets the results there.
    IF OBJECT_ID('tempdb..#scope_review_cat') IS NOT NULL
       AND OBJECT_ID('tempdb..#scope_review_out') IS NOT NULL
    BEGIN
        INSERT #scope_review_cat (category_code, category_name, display_order, item_count, is_included)
        SELECT CategoryCode, CategoryName, DisplayOrder, ItemCount, IsIncluded FROM #res_cat;
        INSERT #scope_review_out (category_code, record_id, record_code, record_name, status, reason)
        SELECT category_code, record_id, record_code, record_name, status, reason FROM #out;
        RETURN;
    END

    SELECT CategoryCode, CategoryName, DisplayOrder, ItemCount, IsIncluded
    FROM #res_cat
    ORDER BY DisplayOrder;
""")

# ---------------------------------------------------------------- freeze
frz = rep(frz555,
"""    @exclusions_json NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system'
AS""",
"""    @exclusions_json NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = 'system',
    @review_json     NVARCHAR(MAX) = NULL   -- 563: Step 3 Review and Confirm
AS""")
frz = rep(frz,
"""    -- Freezing starts the audit.""",
"""    -- 563: Step 3 Review and Confirm. The related records of the frozen
    -- scope (Step 2 discovery over THIS engagement's instances), with the
    -- auditor's category ticks, unticked records (each with a reason) and
    -- manual items, kept as the engagement's approved scope snapshot.
    -- Immutable: a later change is a new version (phase F).
    -- @review_json: { categories: [{ code, isIncluded }],
    --                 excluded:   [{ categoryCode, recordId, reason }],
    --                 manual:     [{ categoryCode, name, note }] }
    CREATE TABLE #scope_review_cat (category_code NVARCHAR(40) NULL, category_name NVARCHAR(80) NULL,
                                    display_order INT NULL, item_count BIGINT NULL, is_included BIT NULL);
    CREATE TABLE #scope_review_out (category_code NVARCHAR(40) NULL, record_id BIGINT NULL,
                                    record_code NVARCHAR(120) NULL, record_name NVARCHAR(400) NULL,
                                    status NVARCHAR(60) NULL, reason NVARCHAR(MAX) NULL);
    EXEC grac_practice.sp_org_assurance_scope_discover
         @organization_id = @organization_id,
         @definition_id   = @def,
         @version_id      = @ver,
         @execution_id    = @execution_id;
    INSERT #scope_review_cat (category_code, category_name, display_order, item_count, is_included)
    VALUES (N'MANUAL', N'Manual Items', 99, 0, 1);

    DECLARE @rc TABLE (category_code NVARCHAR(40) PRIMARY KEY, is_included BIT NOT NULL);
    DECLARE @rx TABLE (category_code NVARCHAR(40) NULL, record_id BIGINT NULL, reason NVARCHAR(1000) NULL);
    DECLARE @rm TABLE (category_code NVARCHAR(40) NULL, item_name NVARCHAR(400) NULL, note NVARCHAR(1000) NULL);
    IF @review_json IS NOT NULL
    BEGIN
        IF ISJSON(@review_json) <> 1
            THROW 54037, 'The scope review is not valid. Reload the scope and try again.', 1;
        INSERT @rc (category_code, is_included)
        SELECT UPPER(LTRIM(RTRIM(x.code))), MAX(CAST(ISNULL(x.isIncluded, 1) AS INT))
          FROM OPENJSON(@review_json, '$.categories')
               WITH (code NVARCHAR(40) '$.code', isIncluded BIT '$.isIncluded') x
         WHERE x.code IS NOT NULL
         GROUP BY UPPER(LTRIM(RTRIM(x.code)));
        INSERT @rx (category_code, record_id, reason)
        SELECT UPPER(LTRIM(RTRIM(x.categoryCode))), x.recordId,
               LEFT(NULLIF(LTRIM(RTRIM(x.reason)), N''), 1000)
          FROM OPENJSON(@review_json, '$.excluded')
               WITH (categoryCode NVARCHAR(40) '$.categoryCode', recordId BIGINT '$.recordId',
                     reason NVARCHAR(MAX) '$.reason') x;
        INSERT @rm (category_code, item_name, note)
        SELECT UPPER(LTRIM(RTRIM(ISNULL(x.categoryCode, N'MANUAL')))),
               LEFT(NULLIF(LTRIM(RTRIM(x.name)), N''), 400),
               LEFT(NULLIF(LTRIM(RTRIM(x.note)), N''), 1000)
          FROM OPENJSON(@review_json, '$.manual')
               WITH (categoryCode NVARCHAR(40) '$.categoryCode', name NVARCHAR(MAX) '$.name',
                     note NVARCHAR(MAX) '$.note') x;
    END

    IF EXISTS (SELECT 1 FROM (SELECT category_code FROM @rc UNION ALL SELECT category_code FROM @rx
                              UNION ALL SELECT category_code FROM @rm) u
                WHERE NOT EXISTS (SELECT 1 FROM #scope_review_cat c WHERE c.category_code = u.category_code))
        THROW 54039, 'Unknown scope category in the review.', 1;
    IF EXISTS (SELECT 1 FROM @rx WHERE category_code = N'PRACTICE_INSTANCE')
        THROW 54037, 'Exclude a practice instance in the scope list above, not in the related records.', 1;
    IF EXISTS (SELECT 1 FROM @rx WHERE record_id IS NULL OR reason IS NULL)
        THROW 54037, 'Every related record you untick needs a reason.', 1;
    IF EXISTS (SELECT 1 FROM @rx x
                WHERE NOT EXISTS (SELECT 1 FROM #scope_review_out o
                                   WHERE o.category_code = x.category_code AND o.record_id = x.record_id))
        THROW 54037, 'An unticked record is no longer related to the scope. Reload the scope and try again.', 1;
    IF EXISTS (SELECT 1 FROM @rm WHERE item_name IS NULL)
        THROW 54038, 'Every manual item needs a name.', 1;

    DECLARE @review_id BIGINT, @review_version INT;
    SET @review_version = ISNULL((SELECT MAX(version_no) FROM grac_practice.org_assurance_execution_scope_review
                                   WHERE org_assurance_execution_id = @execution_id), 0) + 1;
    INSERT INTO grac_practice.org_assurance_execution_scope_review
        (organization_id, org_assurance_execution_id, org_assurance_definition_version_id,
         version_no, review_status, approved_by, approved_employee_id, approved_dt, entered_by)
    VALUES (@organization_id, @execution_id, @ver,
            @review_version, N'Approved', @actor, @employee_id, SYSUTCDATETIME(), @actor);
    SET @review_id = SCOPE_IDENTITY();

    -- Practice Instances are the scope itself: always included.
    INSERT INTO grac_practice.org_assurance_execution_scope_review_category
        (org_assurance_execution_scope_review_id, organization_id, category_code, category_name,
         display_order, item_count, is_included)
    SELECT @review_id, @organization_id, c.category_code, c.category_name, c.display_order,
           CASE WHEN c.category_code = N'MANUAL' THEN 0 ELSE ISNULL(c.item_count, 0) END
             + (SELECT COUNT(*) FROM @rm m WHERE m.category_code = c.category_code),
           CASE WHEN c.category_code = N'PRACTICE_INSTANCE' THEN 1
                ELSE ISNULL(rc.is_included, ISNULL(c.is_included, 1)) END
      FROM #scope_review_cat c
      LEFT JOIN @rc rc ON rc.category_code = c.category_code;

    INSERT INTO grac_practice.org_assurance_execution_scope_review_item
        (org_assurance_execution_scope_review_id, organization_id, category_code,
         record_id, record_code, record_name, record_status, related_reason,
         is_kept, exclusion_reason, is_manual, manual_note)
    SELECT @review_id, @organization_id, o.category_code,
           o.record_id, o.record_code, LEFT(o.record_name, 400), o.status, o.reason,
           CASE WHEN x.record_id IS NULL THEN 1 ELSE 0 END, x.reason, 0, NULL
      FROM #scope_review_out o
      OUTER APPLY (SELECT TOP 1 rx.record_id, rx.reason FROM @rx rx
                    WHERE rx.category_code = o.category_code AND rx.record_id = o.record_id) x
    UNION ALL
    SELECT @review_id, @organization_id, m.category_code,
           NULL, NULL, m.item_name, NULL, N'Added by the auditor',
           1, NULL, 1, m.note
      FROM @rm m;

    -- Freezing starts the audit.""")
frz = rep(frz,
"""           (SELECT COUNT(*) FROM @excl)  AS ExcludedCount
      FROM grac_practice.org_assurance_execution e""",
"""           (SELECT COUNT(*) FROM @excl)  AS ExcludedCount,
           @review_id                    AS ReviewId,          -- 563
           @review_version               AS ReviewVersionNo    -- 563
      FROM grac_practice.org_assurance_execution e""")

head = open(os.path.join(os.path.dirname(__file__), 'head563.sql'), encoding='utf-8').read()
tail = open(os.path.join(os.path.dirname(__file__), 'tail563.sql'), encoding='utf-8').read()

out = (head
       + '-- =====================================================================\n'
       + '-- 2. sp_org_assurance_execution_live_scope (556 body) + #scope_review_pi\n'
       + '-- =====================================================================\n'
       + live + '\n'
       + '-- =====================================================================\n'
       + '-- 3. sp_org_assurance_scope_discover (562 body) + @execution_id\n'
       + '-- =====================================================================\n'
       + disc + '\n'
       + '-- =====================================================================\n'
       + '-- 4. sp_org_assurance_execution_freeze_scope (555 body) + @review_json\n'
       + '-- =====================================================================\n'
       + frz + '\n'
       + tail)
for i, ch in enumerate(out):
    if ord(ch) > 127:
        sys.exit('non-ASCII at %d: %r' % (i, out[i-40:i+10]))
open(os.path.join(DB, '563_scope_review_confirm.sql'), 'w', encoding='ascii', newline='\n').write(out)

rb = open(os.path.join(os.path.dirname(__file__), 'rbhead563.sql'), encoding='utf-8').read()
rb_out = (rb
          + '-- live_scope: 556 body\n' + live556 + '\n'
          + '-- discover: 562 body\n' + disc562 + '\n'
          + '-- freeze_scope: 555 body\n' + frz555 + '\n'
          + "PRINT '563 rolled back: live scope 556, discovery 562, freeze 555; review_get dropped; review tables kept.';\nGO\n")
open(os.path.join(DB, '563_scope_review_confirm_rollback.sql'), 'w', encoding='ascii', newline='\n').write(rb_out)
print('563 written:', len(out), 'chars; rollback', len(rb_out))
