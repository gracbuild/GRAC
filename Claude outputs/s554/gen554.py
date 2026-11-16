import re, sys, os
D = sys.argv[1]
def body(fname, name):
    src = open(os.path.join(D, fname), encoding='utf-8').read()
    m = re.search(r'CREATE OR ALTER PROCEDURE grac_practice\.' + name + r'\b.*?\nGO\n', src, re.S)
    if not m: raise SystemExit('missing ' + name)
    return m.group(0)
def rep(s, a, b):
    if s.count(a) != 1: raise SystemExit('count %d: %r' % (s.count(a), a[:90]))
    return s.replace(a, b)

dv0 = body('534_audit_scope_source_statements.sql', 'sp_org_assurance_scope_dimension_values')
st0 = body('552_audit_engagements.sql', 'sp_org_assurance_plan_item_start_execution')
pv0 = body('552_audit_engagements.sql', 'sp_org_assurance_engagement_scope_preview')

# ---- dimension values: BRANCH = Locations ----
dv = rep(dv0, """    IF @dimension_code = N'PRACTICE_INSTANCE'
""", """    -- 554: Branches are the organization's Locations (Location master).
    -- BRANCH stays non-pickable, so the Scope Builder does not offer it;
    -- the Audit Plan engagement's Branch picker reads this list.
    IF @dimension_code = N'BRANCH'
        AND OBJECT_ID('grac_practice.organization_location','U') IS NOT NULL
    BEGIN
        SELECT TOP (@page_size)
               l.location_id                 AS Id,
               CAST(NULL AS NVARCHAR(120))   AS Code,
               l.location_name               AS Name
        FROM grac_practice.organization_location l
        WHERE l.organization_id = @organization_id
          AND l.status = N'Active'
          AND (@like IS NULL OR l.location_name LIKE @like)
        ORDER BY l.location_name;
        RETURN;
    END

    IF @dimension_code = N'PRACTICE_INSTANCE'
""")

# ---- start execution: the branch narrows each audit's scope ----
st = rep(st0, """            @team NVARCHAR(200);
""", """            @team NVARCHAR(200),
            @branch_id BIGINT, @branch_name NVARCHAR(200);   -- 554
""")
st = rep(st0 if False else st, """           @team          = i.assigned_team_name
""", """           @team          = i.assigned_team_name,
           @branch_id     = i.assigned_branch_id,     -- 554
           @branch_name   = i.assigned_branch_name
""")
st = rep(st, """            @def BIGINT, @ver BIGINT, @eid BIGINT;
""", """            @def BIGINT, @ver BIGINT, @eid BIGINT,
            @res BIGINT, @def_code NVARCHAR(80), @msg NVARCHAR(400);   -- 554
""")
st = rep(st, """        SET @eid = NULL;
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = NULL,
""", """        SET @eid = NULL;
        SET @res = NULL;
        -- 554: the engagement's Branch (a Location) narrows the audit's
        -- scope. The scope is resolved here (EXECUTION), narrowed, and the
        -- snapshot handed to materialize. No branch: materialize resolves
        -- it itself, as before. An audit with nothing left at the branch
        -- stops the start (nothing is created).
        IF @branch_id IS NOT NULL
        BEGIN
            EXEC grac_practice.sp_org_assurance_scope_resolve
                 @organization_id    = @organization_id,
                 @definition_id      = @def,
                 @version_id         = @ver,
                 @resolution_purpose = N'EXECUTION',
                 @execution_id       = NULL,
                 @actor              = @actor,
                 @resolution_id_out  = @res OUTPUT;
            EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                 @organization_id = @organization_id,
                 @resolution_id   = @res,
                 @location_id     = @branch_id;
            IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution_entity
                            WHERE org_assurance_scope_resolution_id = @res)
            BEGIN
                SELECT @def_code = definition_code FROM grac_practice.org_assurance_definition
                 WHERE org_assurance_definition_id = @def;
                SET @msg = CONCAT(N'Audit ', @def_code, N' has nothing in scope at branch ',
                                  ISNULL(@branch_name, N'#' + CAST(@branch_id AS NVARCHAR(20))),
                                  N'. Remove the branch or this audit from the engagement.');
                THROW 53942, @msg, 1;
            END
        END
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
             @scope_resolution_id = @res,
""")
st = rep(st, """        INSERT INTO @started (execution_id) VALUES (@eid);
""", """        -- 554: a snapshot made here points back at its execution
        -- (materialize does this only for one it resolved itself).
        IF @res IS NOT NULL
            UPDATE grac_practice.org_assurance_scope_resolution
               SET execution_id = @eid
             WHERE org_assurance_scope_resolution_id = @res;
        INSERT INTO @started (execution_id) VALUES (@eid);
""")

# ---- preview: narrowed the same way ----
pv = rep(pv0, """    @definitions_json NVARCHAR(MAX) = NULL,
    @actor            NVARCHAR(100) = 'system'
""", """    @definitions_json NVARCHAR(MAX) = NULL,
    @location_id      BIGINT        = NULL,   -- 554: the branch (unsaved pick)
    @actor            NVARCHAR(100) = 'system'
""")
pv = rep(pv, """    DECLARE @ents TABLE (""", """    -- 554: a saved engagement previews with its own branch; an unsaved
    -- pick (the dialog) with the branch it passes.
    IF NOT (@definitions_json IS NOT NULL AND ISJSON(@definitions_json) = 1)
       AND @plan_item_id IS NOT NULL AND @location_id IS NULL
        SELECT @location_id = i.assigned_branch_id
          FROM grac_practice.org_assurance_plan_item i
         WHERE i.org_assurance_plan_item_id = @plan_item_id
           AND i.organization_id = @organization_id
           AND i.is_active = 1;

    DECLARE @ents TABLE (""")
pv = rep(pv, """                 @resolution_id_out  = @res OUTPUT;
            INSERT INTO @ents""", """                 @resolution_id_out  = @res OUTPUT;
            IF @location_id IS NOT NULL                       -- 554
                EXEC grac_practice.sp_org_assurance_scope_resolution_narrow_location
                     @organization_id = @organization_id,
                     @resolution_id   = @res,
                     @location_id     = @location_id;
            INSERT INTO @ents""")

head = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'head554.sql'), encoding='utf-8').read()
tail = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tail554.sql'), encoding='utf-8').read()
out = head + "\n-- 2. Branch list (534 body + 554)\n" + dv + "\n-- 3. Start execution (552 body + 554)\n" + st + "\n-- 4. View Scope (552 body + 554)\n" + pv + tail
open(os.path.join(D, '554_engagement_branch_scope.sql'), 'w', encoding='utf-8', newline='\n').write(out)
rb = """-- =====================================================================
-- 554 ROLLBACK -- restores sp_org_assurance_scope_dimension_values (534),
-- sp_org_assurance_plan_item_start_execution and
-- sp_org_assurance_engagement_scope_preview (552); drops
-- sp_org_assurance_scope_resolution_narrow_location. Deploy the pre-554 Api
-- and Web with it (the Api passes @location_id to the preview). The Branch
-- id saved on engagements is kept. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
""" + dv0 + '\n' + st0 + '\n' + pv0 + """
IF OBJECT_ID('grac_practice.sp_org_assurance_scope_resolution_narrow_location','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_scope_resolution_narrow_location;
GO
PRINT '554 rolled back.';
GO
"""
open(os.path.join(D, '554_engagement_branch_scope_rollback.sql'), 'w', encoding='utf-8', newline='\n').write(rb)
for f in ['554_engagement_branch_scope.sql', '554_engagement_branch_scope_rollback.sql']:
    b = open(os.path.join(D, f), 'rb').read(); print(f, len(b), all(c < 128 for c in b))
