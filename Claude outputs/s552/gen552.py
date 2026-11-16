import re, sys, os
D = sys.argv[1]

def read(f): return open(os.path.join(D, f), encoding='utf-8').read()
def proc(text, name):
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + name + r'\b.*?\nGO\n', text, re.S)
    if not m: raise SystemExit('proc not found: ' + name)
    return m.group(0)
def rep(s, a, b, n=1):
    c = s.count(a)
    if c != n: raise SystemExit('count %d (want %d): %r' % (c, n, a[:100]))
    return s.replace(a, b)

f551 = read('551_question_set_versioning.sql')
orig = {}

head = r"""-- =====================================================================
-- 552  Engagements -- a plan item audits one or more audit definitions
--
-- REQUEST (2026-11-14, sir) -- phase 2 of the audit flow redesign
--   (docs/audit-flow-redesign.md). The Audit Plan stays as it is; its
--   items are now ENGAGEMENTS. An engagement says who audits, when (from /
--   to) and WHICH audit definitions -- one or more -- and links to a live
--   View Scope (nothing frozen; the scope is frozen in the execution).
--   Decision (sir): an engagement is a parent holding one execution per
--   audit definition.
--
-- WHAT THIS DOES
--   1. org_assurance_plan_item (the engagement) + engagement_code
--      (plan code + "-E01", "-E02" ...) and engagement_name. Existing items
--      get a code and their audit's name.
--   2. NEW org_assurance_engagement_definition -- the audits of an
--      engagement (order kept). Each existing item gets one row (its
--      audit). The item's own org_assurance_definition_id / code / name
--      stay as its FIRST audit, so every existing reader keeps working.
--   3. sp_org_assurance_plan_item_save (551 body): @definitions_json
--      ([{"definitionId": 1}, ...] in order) or the old single
--      @org_assurance_definition_id; @engagement_name (default: the first
--      audit's name). Every audit must be plannable (an Active version,
--      not Retired -- 551); an audit already started on this engagement
--      may stay even if no longer plannable, but cannot be removed (53938);
--      the same audit twice is refused (53937).
--   4. sp_org_assurance_plan_item_list (551 body) + EngagementCode,
--      EngagementName, DefinitionCount, DefinitionCodes, ExecutionCount,
--      ExecutionDoneCount, CanStart; SlotStatus rolls up the engagement's
--      executions (Completed when every audit's execution is done,
--      InProgress when any is live); DefinitionIsPlannable = any audit of
--      the engagement can be planned.
--   5. NEW sp_org_assurance_engagement_definition_list -- one row per
--      audit of an engagement, with its plannable flag and its latest
--      execution.
--   6. sp_org_assurance_plan_item_start_execution (rewritten): starts one
--      execution per audit of the engagement that has none live and can
--      be executed (its Active version), all in one transaction; returns
--      one row per execution started. 53936 when none is left to start.
--   7. NEW sp_org_assurance_engagement_scope_preview -- View Scope: each
--      audit's scope is resolved with the existing resolver
--      (sp_org_assurance_scope_resolve, PREVIEW, the Active version)
--      inside a transaction that is rolled back, so NOTHING is saved; the
--      entities are returned with the audits that bring them in. Reads a
--      saved engagement (@plan_item_id) or an unsaved pick
--      (@definitions_json).
--
-- NEW REASON CODES: 53937 DUPLICATE_DEFINITION, 53938 DEFINITION_STARTED.
-- NOT CHANGED: sp_org_assurance_plan_item_delete (an engagement with any
--   execution cannot be removed), plan header procedures, executions.
-- DEPENDS ON: 546, 551.
-- Rollback: 552_audit_engagements_rollback.sql (551 procedure bodies;
--   drops the new procedures; the new table and columns are kept).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_list')) NOT LIKE '%DefinitionIsPlannable%'
   OR OBJECT_ID('grac_practice.sp_org_assurance_scope_resolve','P') IS NULL
BEGIN
    PRINT 'ABORT (552): run 551 first. Nothing was changed.';
    RAISERROR('552_audit_engagements: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Engagement code and name
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_plan_item','engagement_code') IS NULL
    ALTER TABLE grac_practice.org_assurance_plan_item ADD engagement_code NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.org_assurance_plan_item','engagement_name') IS NULL
    ALTER TABLE grac_practice.org_assurance_plan_item ADD engagement_name NVARCHAR(240) NULL;
GO

;WITH n AS (
    SELECT i.org_assurance_plan_item_id,
           p.plan_code,
           ROW_NUMBER() OVER (PARTITION BY i.org_assurance_plan_id
                              ORDER BY i.item_order, i.org_assurance_plan_item_id) AS rn
      FROM grac_practice.org_assurance_plan_item i
      JOIN grac_practice.org_assurance_plan p ON p.org_assurance_plan_id = i.org_assurance_plan_id
)
UPDATE i
   SET engagement_code = LEFT(n.plan_code, 110) + N'-E' + RIGHT(N'0' + CAST(n.rn AS NVARCHAR(10)), 2),
       engagement_name = ISNULL(i.engagement_name, i.definition_name)
  FROM grac_practice.org_assurance_plan_item i
  JOIN n ON n.org_assurance_plan_item_id = i.org_assurance_plan_item_id
 WHERE i.engagement_code IS NULL;
PRINT '552.1: engagement codes given = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. The audits of an engagement
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_engagement_definition(
        org_assurance_engagement_definition_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_oa_eng_def PRIMARY KEY,
        org_assurance_plan_item_id   BIGINT NOT NULL,
        organization_id              BIGINT NOT NULL,
        org_assurance_definition_id  BIGINT NOT NULL,
        definition_code              NVARCHAR(80)  NULL,   -- denormalized snapshot
        definition_name              NVARCHAR(240) NULL,
        display_order                INT NOT NULL CONSTRAINT df_pm_oa_eng_def_order DEFAULT 1,
        is_active                    BIT NOT NULL CONSTRAINT df_pm_oa_eng_def_active DEFAULT 1,
        entered_by                   NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_eng_def_ent_by DEFAULT 'system',
        entered_dt                   DATETIME2 NOT NULL CONSTRAINT df_pm_oa_eng_def_ent_dt DEFAULT SYSUTCDATETIME(),
        updated_by                   NVARCHAR(100) NULL,
        updated_dt                   DATETIME2 NULL,
        CONSTRAINT fk_pm_oa_eng_def_item
            FOREIGN KEY(org_assurance_plan_item_id)
            REFERENCES grac_practice.org_assurance_plan_item(org_assurance_plan_item_id),
        CONSTRAINT fk_pm_oa_eng_def_org
            FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_eng_def_definition
            FOREIGN KEY(org_assurance_definition_id)
            REFERENCES grac_practice.org_assurance_definition(org_assurance_definition_id)
    );
    CREATE UNIQUE INDEX uq_pm_oa_eng_def_active
        ON grac_practice.org_assurance_engagement_definition(org_assurance_plan_item_id, org_assurance_definition_id)
        WHERE is_active = 1;
    PRINT '552.2: org_assurance_engagement_definition created.';
END
GO

INSERT INTO grac_practice.org_assurance_engagement_definition
    (org_assurance_plan_item_id, organization_id, org_assurance_definition_id,
     definition_code, definition_name, display_order, is_active, entered_by)
SELECT i.org_assurance_plan_item_id, i.organization_id, i.org_assurance_definition_id,
       i.definition_code, i.definition_name, 1, 1, N'migration-552'
  FROM grac_practice.org_assurance_plan_item i
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_engagement_definition ed
                    WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id);
PRINT '552.2: existing items given their audit = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

"""

# ---------------- save ----------------
p = proc(f551, 'sp_org_assurance_plan_item_save'); orig['save'] = p
p = rep(p, "    @org_assurance_definition_id BIGINT,\n", "    @org_assurance_definition_id BIGINT        = NULL,   -- 552: or @definitions_json\n")
p = rep(p, """    @notes                       NVARCHAR(MAX) = NULL,
    @actor                       NVARCHAR(100) = 'system',""", """    @notes                       NVARCHAR(MAX) = NULL,
    @engagement_name             NVARCHAR(240) = NULL,   -- 552
    @definitions_json            NVARCHAR(MAX) = NULL,   -- 552: [{"definitionId": 1}, ...] in order
    @actor                       NVARCHAR(100) = 'system',""")
p = rep(p, """    IF @org_assurance_definition_id IS NULL
        THROW 53913, 'org_assurance_definition_id is required.', 1;
""", "")
p = rep(p, """    -- Verify definition ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @org_assurance_definition_id
          AND organization_id            = @organization_id
          AND is_active = 1)
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;
""", """    -- 552: the engagement's audits, in order -- @definitions_json, or the
    -- single @org_assurance_definition_id of the pre-552 callers.
    DECLARE @defs TABLE (
        definition_id   BIGINT NOT NULL PRIMARY KEY,
        display_order   INT    NOT NULL,
        definition_code NVARCHAR(80)  NULL,
        definition_name NVARCHAR(240) NULL);
    IF @definitions_json IS NOT NULL AND ISJSON(@definitions_json) = 1
    BEGIN
        IF EXISTS (SELECT TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT)
                     FROM OPENJSON(@definitions_json) j
                    WHERE TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT) IS NOT NULL
                    GROUP BY TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT)
                   HAVING COUNT(*) > 1)
            THROW 53937, 'The same audit is listed more than once in the engagement.', 1;
        INSERT INTO @defs (definition_id, display_order)
        SELECT TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT),
               ROW_NUMBER() OVER (ORDER BY CAST(j.[key] AS INT))
          FROM OPENJSON(@definitions_json) j
         WHERE TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT) IS NOT NULL;
    END
    ELSE IF @org_assurance_definition_id IS NOT NULL
        INSERT INTO @defs (definition_id, display_order) VALUES (@org_assurance_definition_id, 1);

    IF NOT EXISTS (SELECT 1 FROM @defs)
        THROW 53913, 'Pick at least one audit for the engagement.', 1;

    -- Verify definition ownership.
    IF EXISTS (
        SELECT 1 FROM @defs x
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition d
                            WHERE d.org_assurance_definition_id = x.definition_id
                              AND d.organization_id = @organization_id
                              AND d.is_active = 1))
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;
""")
p = rep(p, """    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    DECLARE @def_status NVARCHAR(60), @def_active_version BIGINT;
    SELECT @def_status         = s.status_code,
           @def_active_version = d.active_version_id,
           @definition_code    = d.definition_code,
           @definition_name    = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_active_version IS NULL OR @def_status = N'Retired'
        THROW 53933, 'Only an audit with an Active version can be added to a plan.', 1;
""", """    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    -- 552: for every audit of the engagement; one already started on this
    -- engagement may stay whatever its state now.
    UPDATE x
       SET definition_code = d.definition_code,
           definition_name = d.definition_name
      FROM @defs x
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = x.definition_id;

    DECLARE @not_plannable NVARCHAR(MAX), @msg NVARCHAR(2000);
    SELECT @not_plannable = STRING_AGG(CONVERT(NVARCHAR(MAX), x.definition_code), N', ')
      FROM @defs x
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = x.definition_id
      JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
     WHERE (d.active_version_id IS NULL OR s.status_code = N'Retired')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = x.definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled');
    IF @not_plannable IS NOT NULL
    BEGIN
        SET @msg = N'Only an audit with an Active version can be added to a plan. Not Active: ' + @not_plannable + N'.';
        THROW 53933, @msg, 1;
    END

    -- The engagement's first audit is the item's own audit (pre-552 readers).
    SELECT TOP 1 @org_assurance_definition_id = definition_id,
                 @definition_code             = definition_code,
                 @definition_name             = definition_name
      FROM @defs ORDER BY display_order;
    IF NULLIF(LTRIM(RTRIM(@engagement_name)), N'') IS NULL SET @engagement_name = @definition_name;

    -- An audit already started on this engagement cannot be taken out.
    DECLARE @started_removed NVARCHAR(MAX);
    IF @plan_item_id IS NOT NULL
        SELECT @started_removed = STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(ed.definition_code, N'?')), N', ')
          FROM grac_practice.org_assurance_engagement_definition ed
         WHERE ed.org_assurance_plan_item_id = @plan_item_id
           AND ed.is_active = 1
           AND ed.org_assurance_definition_id NOT IN (SELECT definition_id FROM @defs)
           AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled');
    IF @started_removed IS NOT NULL
    BEGIN
        SET @msg = N'These audits have been started on this engagement and cannot be removed: ' + @started_removed + N'.';
        THROW 53938, @msg, 1;
    END
""")
p = rep(p, """             assigned_branch_id, assigned_branch_name,
             notes, is_active, entered_by, entered_dt)
        VALUES""", """             assigned_branch_id, assigned_branch_name,
             notes, engagement_code, engagement_name,             -- 552
             is_active, entered_by, entered_dt)
        VALUES""")
p = rep(p, """             @assigned_branch_id, @assigned_branch_name,
             @notes, 1, @actor, SYSUTCDATETIME());""", """             @assigned_branch_id, @assigned_branch_name,
             @notes,
             -- 552: plan code + -E01, -E02 ... in the order created
             (SELECT LEFT(p.plan_code, 110) + N'-E'
                     + RIGHT(N'0' + CAST((SELECT COUNT(*) + 1 FROM grac_practice.org_assurance_plan_item x
                                           WHERE x.org_assurance_plan_id = @plan_id) AS NVARCHAR(10)), 2)
                FROM grac_practice.org_assurance_plan p WHERE p.org_assurance_plan_id = @plan_id),
             @engagement_name,
             1, @actor, SYSUTCDATETIME());""")
p = rep(p, """            notes                       = @notes,
            updated_by                  = @actor,""", """            notes                       = @notes,
            engagement_name             = @engagement_name,   -- 552
            updated_by                  = @actor,""")
p = rep(p, """        SET @plan_item_id_out = @plan_item_id;
    END

    COMMIT;""", """        SET @plan_item_id_out = @plan_item_id;
    END

    -- 552: the engagement's audits -- remove the ones taken out, re-order
    -- the kept ones, add the new ones.
    UPDATE ed
       SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_engagement_definition ed
     WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
       AND ed.is_active = 1
       AND ed.org_assurance_definition_id NOT IN (SELECT definition_id FROM @defs);

    UPDATE ed
       SET display_order = x.display_order, definition_code = x.definition_code,
           definition_name = x.definition_name, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN @defs x ON x.definition_id = ed.org_assurance_definition_id
     WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
       AND ed.is_active = 1;

    INSERT INTO grac_practice.org_assurance_engagement_definition
        (org_assurance_plan_item_id, organization_id, org_assurance_definition_id,
         definition_code, definition_name, display_order, is_active, entered_by)
    SELECT @plan_item_id_out, @organization_id, x.definition_id,
           x.definition_code, x.definition_name, x.display_order, 1, @actor
      FROM @defs x
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_engagement_definition ed
                        WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
                          AND ed.org_assurance_definition_id = x.definition_id
                          AND ed.is_active = 1);

    COMMIT;""")
save = '-- =====================================================================\n-- 3. sp_org_assurance_plan_item_save (551 body + 552)\n-- =====================================================================\n' + p + '\n'

# ---------------- list ----------------
p = proc(f551, 'sp_org_assurance_plan_item_list'); orig['list'] = p
p = rep(p, """           -- 551: the audit can be planned / executed -- it has an Active
           -- version and is not Retired (a revision may be in Draft).
           CAST(CASE WHEN d.active_version_id IS NOT NULL AND ds.status_code <> N'Retired'
                     THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
""", """           -- 551 / 552: an audit of the engagement can be planned /
           -- executed -- an Active version, not Retired.
           CAST(CASE WHEN ISNULL(eg.plannable_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
           -- 552: the engagement.
           i.engagement_code             AS EngagementCode,
           ISNULL(i.engagement_name, i.definition_name) AS EngagementName,
           ISNULL(eg.definition_count, 0) AS DefinitionCount,
           eg.definition_codes           AS DefinitionCodes,
           ISNULL(eg.live_count, 0)      AS ExecutionCount,
           ISNULL(eg.done_count, 0)      AS ExecutionDoneCount,
           CAST(CASE WHEN ISNULL(eg.startable_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS CanStart,
""")
p = rep(p, """           CASE WHEN ex.org_assurance_execution_id IS NOT NULL AND ex.status_code <> N'Cancelled'
                     THEN CASE WHEN ex.status_code IN (N'Approved', N'Closed') THEN N'Completed' ELSE N'InProgress' END
                WHEN ds.status_code = N'Retired' OR ps.status_code = N'Closed'
                     THEN N'NotExecuted'
                ELSE N'Planned' END      AS SlotStatus""", """           -- 552: rolled up over the engagement's audits.
           CASE WHEN ISNULL(eg.live_count, 0) > 0 AND eg.done_count >= eg.definition_count THEN N'Completed'
                WHEN ISNULL(eg.live_count, 0) > 0 THEN N'InProgress'
                WHEN ps.status_code = N'Closed' OR ISNULL(eg.plannable_count, 0) = 0 THEN N'NotExecuted'
                ELSE N'Planned' END      AS SlotStatus""")
p = rep(p, """    ) ex
    WHERE i.org_assurance_plan_id = @plan_id""", """    ) ex
    OUTER APPLY (
        SELECT COUNT(*) AS definition_count,
               STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(d2.definition_code, ed.definition_code)), N', ')
                   WITHIN GROUP (ORDER BY ed.display_order) AS definition_codes,
               SUM(lx.live) AS live_count,
               SUM(lx.done) AS done_count,
               SUM(CASE WHEN d2.active_version_id IS NOT NULL AND s2.status_code <> N'Retired' THEN 1 ELSE 0 END) AS plannable_count,
               SUM(CASE WHEN lx.live = 0 AND d2.active_version_id IS NOT NULL AND s2.status_code <> N'Retired' THEN 1 ELSE 0 END) AS startable_count
          FROM grac_practice.org_assurance_engagement_definition ed
          JOIN grac_practice.org_assurance_definition d2
               ON d2.org_assurance_definition_id = ed.org_assurance_definition_id
          JOIN grac_practice.org_assurance_status_master s2
               ON s2.org_assurance_status_id = d2.current_status_id
          CROSS APPLY (
              SELECT ISNULL(MAX(CASE WHEN es2.status_code <> N'Cancelled' THEN 1 ELSE 0 END), 0) AS live,
                     ISNULL(MAX(CASE WHEN es2.status_code IN (N'Approved', N'Closed') THEN 1 ELSE 0 END), 0) AS done
                FROM grac_practice.org_assurance_execution e2
                JOIN grac_practice.org_assurance_execution_status_master es2
                     ON es2.org_assurance_execution_status_id = e2.execution_status_id
               WHERE e2.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
                 AND e2.org_assurance_definition_id = ed.org_assurance_definition_id
                 AND e2.is_active = 1) lx
         WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND ed.is_active = 1) eg
    WHERE i.org_assurance_plan_id = @plan_id""")
lst = '-- =====================================================================\n-- 4. sp_org_assurance_plan_item_list (551 body + 552)\n-- =====================================================================\n' + p + '\n'

orig['start'] = proc(f551, 'sp_org_assurance_plan_item_start_execution')

rest = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'part_552.sql'), encoding='utf-8').read()

tail = """-- =====================================================================
-- Verification
-- =====================================================================
SELECT '552 engagement table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_item i
                              WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_engagement_definition ed
                                                 WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '552 save takes several audits',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_save')) LIKE '%@definitions_json%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '552 list rolls up the engagement',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_plan_item_list')) LIKE '%AS CanStart%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '552 new procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_engagement_definition_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;
PRINT '552 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
"""
open(os.path.join(D, '552_audit_engagements.sql'), 'w', encoding='utf-8', newline='\n').write(head + save + lst + rest + tail)

rb = """-- =====================================================================
-- 552 ROLLBACK -- restores the 551 bodies of sp_org_assurance_plan_item_save
-- / _list / _start_execution and drops the 552 procedures. The
-- org_assurance_engagement_definition table and the engagement_code /
-- engagement_name columns are KEPT (an engagement's second and later
-- audits stay recorded there, unread). Deploy the pre-552 Api and Web
-- with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
""" + orig['save'] + '\n' + orig['list'] + '\n' + orig['start'] + '\n'
for n in ['sp_org_assurance_engagement_definition_list', 'sp_org_assurance_engagement_scope_preview']:
    rb += "IF OBJECT_ID('grac_practice.%s','P') IS NOT NULL DROP PROCEDURE grac_practice.%s;\nGO\n" % (n, n)
rb += "PRINT '552 rolled back (procedures). Table and columns kept.';\nGO\n"
open(os.path.join(D, '552_audit_engagements_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['552_audit_engagements.sql', '552_audit_engagements_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read()
    print(f, len(b), 'ASCII' if all(c < 128 for c in b) else 'NONASCII')
