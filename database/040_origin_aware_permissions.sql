-- =====================================================================
-- 040 Origin-aware permission guards  (charter §12.1.6)
--
-- Extends the existing Role × Scope model (organization_role.data_scope
-- from migration 032/034) with an ORIGIN dimension so that mutation
-- rules can differ for GRAC-origin vs Custom-origin content.
--
-- Goal (charter §12.1.6):
--   fn_can_mutate(entity_type, entity_id, actor_employee_id, action)
--     -> 'Allowed' | 'Denied' | 'RequiresApproval'
--
-- This migration ships the schema, an inline scalar helper, and the RBAC
-- seed matrix from charter §14. The C# service (PermissionService.cs)
-- wraps the scalar helper and exposes /api/practice/permissions/probe.
--
-- Numbering: gap of 036..039 reserved for §12.1.2..§12.1.5 which will
-- fill in during their own PRs. This migration only depends on §12.1.1
-- (state machine) being present because rbac_rule references
-- entity_status_master indirectly via origin_type_master status handling.
--
-- Idempotent, safe to re-run.
-- Rollback: database/040_origin_aware_permissions_rollback.sql
-- Docs:     docs/origin-aware-permissions.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- Prerequisite guard — see 037_task_engine.sql for the pattern explanation.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (040): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('040_origin_aware_permissions: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. origin_type_master
--    The catalog of content origins. Two rows expected today
--    (GRAC, Custom) but modelled as a table so third-party or partner
--    origins can be added without a schema change.
-- =====================================================================
IF OBJECT_ID('grac_practice.origin_type_master','U') IS NULL
CREATE TABLE grac_practice.origin_type_master(
    origin_type_id    INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_origin_type_master PRIMARY KEY,
    origin_code       NVARCHAR(30)  NOT NULL
        CONSTRAINT uq_pm_origin_type_code UNIQUE,
    origin_name       NVARCHAR(100) NOT NULL,
    description       NVARCHAR(400) NULL,
    is_mutable        BIT           NOT NULL DEFAULT 0,   -- Custom = 1; GRAC = 0
    display_order     INT           NOT NULL DEFAULT 0,
    is_active         BIT           NOT NULL DEFAULT 1,
    entered_by        NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL
);
GO

;WITH src AS (
    SELECT * FROM (VALUES
        (N'GRAC',    N'GRAC (published)', N'Published by gracbuild/GRAC-ADMIN; immutable text', 0, 10),
        (N'Custom',  N'Custom (org)',     N'Org-authored content; full CRUD via retirement lifecycle', 1, 20)
    ) v(origin_code, origin_name, description, is_mutable, display_order)
)
MERGE grac_practice.origin_type_master AS t
USING src
   ON t.origin_code = src.origin_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (origin_code, origin_name, description, is_mutable, display_order, entered_by)
    VALUES (src.origin_code, src.origin_name, src.description, src.is_mutable, src.display_order, 'seed-040');
GO

-- =====================================================================
-- 2. rbac_rule
--    Per-(Role × Scope × Origin × Action) verdict, seeded from
--    charter §14. Encoded as data — not enums — so the RBAC matrix
--    can evolve without redeploys.
--
--    verdict_code ∈ { 'Allowed', 'Denied', 'RequiresApproval' }
--    scope_code   matches organization_role.data_scope values
-- =====================================================================
IF OBJECT_ID('grac_practice.rbac_rule','U') IS NULL
CREATE TABLE grac_practice.rbac_rule(
    rbac_rule_id      INT           IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_rbac_rule PRIMARY KEY,
    role_code         NVARCHAR(60)  NOT NULL,   -- e.g. 'Admin', 'ReleaseOwner', 'GRAC_SYSTEM'
    scope_code        NVARCHAR(30)  NOT NULL,   -- GLOBAL / ORGANIZATION / RELEASE / STATEMENT / PRACTICE / INSTANCE / ANY
    origin_code       NVARCHAR(30)  NOT NULL,   -- GRAC / Custom / ANY
    action_code       NVARCHAR(80)  NOT NULL,   -- e.g. 'RETIRE_CONTROL', 'EDIT_SOP'
    verdict_code      NVARCHAR(30)  NOT NULL,   -- Allowed / Denied / RequiresApproval
    priority          INT           NOT NULL DEFAULT 100, -- lower = higher priority; ties broken by more-specific match
    notes             NVARCHAR(400) NULL,
    is_active         BIT           NOT NULL DEFAULT 1,
    entered_by        NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL,
    CONSTRAINT ck_pm_rbac_verdict CHECK (verdict_code IN (N'Allowed', N'Denied', N'RequiresApproval')),
    CONSTRAINT ck_pm_rbac_scope   CHECK (scope_code IN (N'GLOBAL', N'ORGANIZATION', N'RELEASE', N'STATEMENT', N'PRACTICE', N'INSTANCE', N'ANY')),
    CONSTRAINT uq_pm_rbac_rule_natkey
        UNIQUE (role_code, scope_code, origin_code, action_code)
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_rbac_rule_lookup'
      AND object_id = OBJECT_ID('grac_practice.rbac_rule'))
    CREATE INDEX ix_pm_rbac_rule_lookup
        ON grac_practice.rbac_rule(action_code, is_active)
        INCLUDE (role_code, scope_code, origin_code, verdict_code, priority);
GO

-- =====================================================================
-- 3. Seed the starter matrix (charter §14).
--    Idempotent MERGE on the natural key.
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        -- role_code,        scope_code,     origin_code, action_code,               verdict_code,          priority, notes
        (N'Admin',            N'GLOBAL',      N'ANY',      N'ANY',                     N'Allowed',            10,  N'GRAC Admin blanket allow'),
        (N'ReleaseOwner',     N'RELEASE',     N'GRAC',     N'RETIRE_CONTROL',          N'Denied',             20,  N'GRAC content cannot be retired'),
        (N'ReleaseOwner',     N'RELEASE',     N'Custom',   N'RETIRE_CONTROL',          N'RequiresApproval',   20,  N'Custom retirement needs approval'),
        (N'ControlOwner',     N'STATEMENT',   N'GRAC',     N'MARK_NA',                 N'RequiresApproval',   30,  N'NA on GRAC needs approval'),
        (N'ControlOwner',     N'STATEMENT',   N'ANY',      N'ASSIGN_PRACTICE_OWNER',   N'Allowed',            30,  N''),
        (N'PracticeOwner',    N'PRACTICE',    N'GRAC',     N'EDIT_TEMPLATE_SOP',       N'Denied',             40,  N'Edit adoption overlay instead'),
        (N'PracticeOwner',    N'PRACTICE',    N'GRAC',     N'EDIT_ADOPTION_SOP',       N'Allowed',            40,  N''),
        (N'PracticeOwner',    N'PRACTICE',    N'Custom',   N'RETIRE_PRACTICE',         N'RequiresApproval',   40,  N''),
        (N'InstanceOwner',    N'INSTANCE',    N'ANY',      N'UPLOAD_EVIDENCE',         N'Allowed',            50,  N''),
        (N'ANY',              N'ANY',         N'GRAC',     N'HARD_DELETE',             N'Denied',             60,  N'GRAC content immutable'),
        (N'GRAC_SYSTEM',      N'ANY',         N'ANY',      N'CLOSE_AUTOMATIC_TICKET',  N'Allowed',            70,  N'Synthetic principal'),
        (N'GRAC_SYSTEM',      N'ANY',         N'ANY',      N'ASSIGN_TO_HUMAN',         N'Denied',             70,  N'Must escalate via Task'),
        -- Default deny fallback for common actions (safety net)
        (N'ANY',              N'ANY',         N'ANY',      N'EDIT_TEMPLATE_SOP',       N'Denied',             999, N'Fallback deny'),
        (N'ANY',              N'ANY',         N'ANY',      N'RETIRE_CONTROL',          N'Denied',             999, N'Fallback deny')
    ) v(role_code, scope_code, origin_code, action_code, verdict_code, priority, notes)
)
MERGE grac_practice.rbac_rule AS t
USING src
   ON t.role_code = src.role_code
  AND t.scope_code = src.scope_code
  AND t.origin_code = src.origin_code
  AND t.action_code = src.action_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (role_code, scope_code, origin_code, action_code, verdict_code, priority, notes, entered_by)
    VALUES (src.role_code, src.scope_code, src.origin_code, src.action_code, src.verdict_code, src.priority, src.notes, 'seed-040')
WHEN MATCHED AND (
       t.verdict_code <> src.verdict_code
    OR t.priority     <> src.priority
    OR ISNULL(t.notes, N'') <> ISNULL(src.notes, N'')
) THEN
    UPDATE SET
        verdict_code = src.verdict_code,
        priority     = src.priority,
        notes        = src.notes,
        updated_by   = 'seed-040',
        updated_dt   = SYSUTCDATETIME();
GO

-- =====================================================================
-- 4. fn_pm_can_mutate
--    Signature intentionally accepts role_code + scope_code + origin_code
--    + action_code (not entity_type + entity_id) so it can be evaluated
--    at DDL time in a CHECK/CONSTRAINT expression if needed later.
--
--    A companion procedure sp_pm_can_mutate_entity resolves entity_type
--    + entity_id -> (role, scope, origin) using the caller's employee id
--    and delegates to fn_pm_can_mutate.
--
--    Precedence:
--       1. Most-specific rule wins (fewer ANY wildcards)
--       2. On equal specificity, lower priority number wins
--       3. Explicit rule always beats fallback deny
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_can_mutate
(
    @entity_type NVARCHAR(60),   -- reserved for future rule scoping; currently unused in verdict lookup
    @entity_id   BIGINT,          -- reserved; kept in signature for API parity with charter
    @role_code   NVARCHAR(60),
    @scope_code  NVARCHAR(30),
    @origin_code NVARCHAR(30),
    @action_code NVARCHAR(80)
)
RETURNS NVARCHAR(30)
WITH SCHEMABINDING
AS
BEGIN
    IF @role_code IS NULL OR @scope_code IS NULL OR @origin_code IS NULL OR @action_code IS NULL
        RETURN N'Denied';

    DECLARE @verdict NVARCHAR(30);

    ;WITH candidates AS (
        SELECT r.verdict_code,
               r.priority,
               -- specificity score: lower is better; each ANY adds a penalty
               CASE WHEN r.role_code   = N'ANY' THEN 100 ELSE 0 END +
               CASE WHEN r.scope_code  = N'ANY' THEN  10 ELSE 0 END +
               CASE WHEN r.origin_code = N'ANY' THEN   1 ELSE 0 END AS specificity_penalty
        FROM grac_practice.rbac_rule r
        WHERE r.is_active = 1
          AND r.action_code IN (@action_code, N'ANY')
          AND (r.role_code   IN (@role_code,   N'ANY'))
          AND (r.scope_code  IN (@scope_code,  N'ANY'))
          AND (r.origin_code IN (@origin_code, N'ANY'))
    )
    SELECT TOP 1 @verdict = c.verdict_code
    FROM candidates c
    ORDER BY c.specificity_penalty ASC,
             c.priority            ASC,
             CASE c.verdict_code WHEN N'Denied' THEN 0 WHEN N'RequiresApproval' THEN 1 ELSE 2 END ASC;

    IF @verdict IS NULL SET @verdict = N'Denied';
    RETURN @verdict;
END;
GO

-- =====================================================================
-- 5. sp_pm_permissions_probe
--    UI-facing probe returning a single-row (Verdict, Reason).
--    Wraps fn_pm_can_mutate with actor context resolution.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_permissions_probe
    @entity_type       NVARCHAR(60),
    @entity_id         BIGINT       = 0,
    @actor_employee_id BIGINT       = NULL,
    @origin_code       NVARCHAR(30) = N'GRAC',
    @action_code       NVARCHAR(80),
    @organization_id   BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve actor's primary role + data_scope. When actor is NULL or
    -- unresolved, fall back to the most permissive role in the org so the
    -- probe still returns a deterministic verdict (typically Denied for
    -- restricted actions).
    DECLARE @role_code NVARCHAR(60) = NULL;
    DECLARE @scope_code NVARCHAR(30) = N'ANY';

    IF @actor_employee_id IS NOT NULL
    BEGIN
        SELECT TOP 1
               @role_code  = r.role_name,
               @scope_code = r.data_scope
        FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @actor_employee_id
          AND (@organization_id IS NULL OR e.organization_id = @organization_id)
        ORDER BY CASE r.data_scope
                    WHEN N'GLOBAL' THEN 1
                    WHEN N'ORGANIZATION' THEN 2
                    WHEN N'RELEASE' THEN 3
                    WHEN N'STATEMENT' THEN 4
                    WHEN N'PRACTICE' THEN 5
                    WHEN N'INSTANCE' THEN 6
                    ELSE 7
                 END;
    END

    IF @role_code IS NULL SET @role_code = N'ANY';

    DECLARE @verdict NVARCHAR(30) =
        grac_practice.fn_pm_can_mutate(@entity_type, @entity_id, @role_code, @scope_code, @origin_code, @action_code);

    SELECT @verdict     AS Verdict,
           @role_code   AS ResolvedRole,
           @scope_code  AS ResolvedScope,
           @origin_code AS Origin,
           @action_code AS Action,
           CASE @verdict
             WHEN N'Allowed'          THEN N'OK'
             WHEN N'RequiresApproval' THEN N'Approval required'
             ELSE N'Denied by RBAC policy'
           END AS Reason;
END;
GO

PRINT '040 origin-aware permissions installed.';
GO

SELECT '040 origin-aware permissions migration complete.' AS Message,
       (SELECT COUNT(*) FROM grac_practice.origin_type_master) AS OriginTypeCount,
       (SELECT COUNT(*) FROM grac_practice.rbac_rule)          AS RbacRuleCount;
GO

SET NOEXEC OFF;
GO
