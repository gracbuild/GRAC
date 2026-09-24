-- =====================================================================
-- 271 Risk acceptance approval authority — per rating level
--
-- Organization -> Risk Acceptance Approval Authority.
--
-- Who may approve the acceptance of a risk, per rating level, separately
-- for the INHERENT score and the RESIDUAL one.
--
-- ---------------------------------------------------------------------
-- THIS EXTENDS org_risk_config, IT DOES NOT REPLACE IT
-- ---------------------------------------------------------------------
-- 212 already carries org-scoped risk approval settings:
--
--     approval_required          is approval needed at all
--     approval_min_rating_code   the lowest rating that needs it
--     approver_role_id           ONE role, for everything above that
--
-- The gap is granularity: one role for every rating, and no distinction
-- between accepting a Critical inherent risk and accepting one whose
-- residual score is Low after treatment. Those are different decisions
-- and routinely different people.
--
-- So this adds a child table at the finer grain and leaves 212 intact.
--
-- FALLBACK, DELIBERATELY:
--     a configured (rating, scope) row wins;
--     where none exists, org_risk_config.approver_role_id still applies.
--
-- That is what makes this migration safe to deploy on a live system:
-- an organisation that never opens the new page behaves EXACTLY as it
-- does today. Configuring a level overrides the blanket role for that
-- level only. Nothing is migrated, nothing is switched off.
--
-- ---------------------------------------------------------------------
-- THE LEVELS ARE NOT HARD-CODED, AND THIS IS THE POINT
-- ---------------------------------------------------------------------
-- The obvious implementation seeds five rows -- Low, Moderate, High,
-- Very High, Critical -- and renders them. That would be wrong here.
--
-- rating_code is free text BY DESIGN (204's comment: "Some frameworks
-- use...") and risk_matrix_cell is PER ORGANISATION. The default matrix
-- produces FOUR ratings: Low, Medium, High, Critical. An organisation
-- that configures a five-band matrix gets five.
--
-- Hard-coding five would therefore produce two rows that this
-- organisation's matrix can never emit, and omit 'Medium', which it
-- emits constantly -- leaving every Medium risk with no authority
-- configured. sp_risk_config_save already refuses a rating on exactly
-- these grounds (56222: "not a rating this organisation's risk matrix
-- produces"), so hard-coding would also contradict a rule the codebase
-- already enforces.
--
-- The levels are therefore DERIVED: SELECT DISTINCT rating_code FROM
-- risk_matrix_cell for the organisation. Four today, five the day the
-- matrix says five, with no code change.
--
-- ---------------------------------------------------------------------
-- "SAME AS INHERENT" IS STORED, NOT RESOLVED AT SAVE TIME
-- ---------------------------------------------------------------------
-- The checkbox could be implemented by copying the inherent role into
-- the residual row. It is not, because that loses the INTENT: an
-- organisation that says "residual follows inherent" means it should
-- keep following when the inherent role changes. Copying would freeze it
-- at the value it had on the day the box was ticked, and the two would
-- silently diverge on the next edit.
--
-- So same_as_inherent is a stored flag, role_id is NULL alongside it,
-- and resolution follows the link at read time.
--
-- CONTENTS
--   1. org_risk_acceptance_authority          NEW
--   2. org_risk_acceptance_authority_history  NEW (auditability)
--   3. sp_org_risk_acceptance_authority_get   the page's read
--   4. sp_org_risk_acceptance_authority_save  the page's write
--   5. sp_risk_acceptance_authority_resolve   who approves THIS risk
--   6. Menu row under nav-organization
--
-- ERROR CODE RANGE: 56740-56759
-- Rollback: database/271_risk_acceptance_approval_authority_rollback.sql
-- Depends:  002 (organization_role, menu_master), 204 (risk_matrix_cell),
--           205 (risk_register), 212 (org_risk_config), 052 (nav-organization)
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN PRINT 'ABORT (271): organization_role missing -- run 002 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NULL
BEGIN PRINT 'ABORT (271): risk_matrix_cell missing -- run 204 first. The levels are derived from it.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.org_risk_config','U') IS NULL
BEGIN PRINT 'ABORT (271): org_risk_config missing -- run 212 first. This extends it.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (271): menu_master missing -- run 002 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('271_risk_acceptance_approval_authority: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. org_risk_acceptance_authority
--
-- One row per (organisation, rating level, scope). No row means "not
-- configured" -- which is not the same as "nobody approves it": the
-- fallback in section 5 applies. Absence is meaningful, so rows are not
-- pre-seeded for every level.
--
-- role_name is a frozen copy, the same discipline 212 uses for
-- approver_role_name: a renamed role must not silently rewrite what the
-- configuration said at the time.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_risk_acceptance_authority','U') IS NULL
CREATE TABLE grac_practice.org_risk_acceptance_authority(
    authority_id        BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_org_risk_acceptance_authority PRIMARY KEY,
    organization_id     BIGINT NOT NULL
        CONSTRAINT fk_pm_orra_organization
            REFERENCES grac_practice.organization(organization_id),

    -- Validated against risk_matrix_cell at save time rather than by a
    -- CHECK: the valid set is per-organisation and changes when the
    -- matrix does, which a table-level constraint cannot express.
    rating_code         NVARCHAR(30) NOT NULL,

    scope_code          NVARCHAR(20) NOT NULL,   -- Inherent | Residual

    role_id             BIGINT NULL
        CONSTRAINT fk_pm_orra_role
            REFERENCES grac_practice.organization_role(role_id),
    role_name           NVARCHAR(200) NULL,      -- frozen copy

    -- Residual only. When 1, role_id is NULL and resolution follows the
    -- Inherent row for the same rating -- see the header for why this is
    -- a link rather than a copy.
    same_as_inherent    BIT NOT NULL
        CONSTRAINT df_pm_orra_same_as_inherent DEFAULT 0,

    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_orra_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_orra_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT uq_pm_orra_org_rating_scope
        UNIQUE (organization_id, rating_code, scope_code),

    CONSTRAINT ck_pm_orra_scope
        CHECK (scope_code IN (N'Inherent', N'Residual')),

    -- "Same as inherent" is meaningless on the inherent row itself.
    CONSTRAINT ck_pm_orra_same_only_residual
        CHECK (same_as_inherent = 0 OR scope_code = N'Residual'),

    -- A row must say something: either it names a role, or it defers to
    -- the inherent one. A row with neither is an empty configuration
    -- masquerading as a decision, and would shadow the fallback.
    CONSTRAINT ck_pm_orra_role_or_same
        CHECK (role_id IS NOT NULL OR same_as_inherent = 1)
);
GO

-- =====================================================================
-- 2. org_risk_acceptance_authority_history
--
-- The requirement asks for auditability. 212's own sp_risk_config_save
-- writes NO history at all -- a gap this does not repeat.
--
-- Field-level, matching the shape 270 gave risk_register_history and 192
-- gave task_activity: field_code / from_value / to_value. "Who changed
-- the Critical inherent approver, from whom, to whom, and when" is then
-- a query rather than a diff of two backups.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_risk_acceptance_authority_history','U') IS NULL
CREATE TABLE grac_practice.org_risk_acceptance_authority_history(
    history_id          BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_orra_history PRIMARY KEY,
    organization_id     BIGINT NOT NULL,
    rating_code         NVARCHAR(30)  NULL,
    scope_code          NVARCHAR(20)  NULL,
    action_code         NVARCHAR(40)  NOT NULL,  -- Set | Cleared
    field_code          NVARCHAR(40)  NULL,      -- role_id | same_as_inherent
    from_value          NVARCHAR(400) NULL,
    to_value            NVARCHAR(400) NULL,
    remark              NVARCHAR(MAX) NULL,
    actor_employee_id   BIGINT        NULL,
    actor_display_name  NVARCHAR(240) NULL,
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_orra_hist_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_orra_hist_entered_dt DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_orra_history_org'
                  AND object_id = OBJECT_ID('grac_practice.org_risk_acceptance_authority_history'))
    CREATE INDEX ix_pm_orra_history_org
        ON grac_practice.org_risk_acceptance_authority_history(organization_id, entered_dt DESC);
GO

-- =====================================================================
-- 3. sp_org_risk_acceptance_authority_get
--
-- Everything the page needs, in one round trip.
--
-- Result set 1 is the GRID: one row per rating level the organisation's
-- matrix actually produces, LEFT JOINed to whatever is configured. The
-- LEFT JOIN direction is the design -- the matrix decides which rows
-- exist, the configuration only fills them in. A level with no row comes
-- back with NULLs and the fallback role, rather than being absent.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_risk_acceptance_authority_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56740, 'sp_org_risk_acceptance_authority_get: organization_id is required.', 1;

    -- The blanket role from 212, so the page can show what applies where
    -- nothing is configured instead of implying "nobody".
    DECLARE @fallback_role_id BIGINT, @fallback_role_name NVARCHAR(200),
            @approval_required BIT, @min_rating NVARCHAR(30);

    SELECT @fallback_role_id   = c.approver_role_id,
           @fallback_role_name = c.approver_role_name,
           @approval_required  = c.approval_required,
           @min_rating         = c.approval_min_rating_code
      FROM grac_practice.org_risk_config c
     WHERE c.organization_id = @organization_id;

    -- ---- 1) the grid ------------------------------------------------
    -- Ordered by the matrix's own severity, not alphabetically: a list
    -- reading Critical, High, Low, Medium is a list nobody can scan.
    ;WITH levels AS (
        SELECT m.rating_code,
               MAX(ISNULL(m.rating_name, m.rating_code)) AS rating_name,
               MAX(m.rating_score)                       AS severity
          FROM grac_practice.risk_matrix_cell m
         WHERE m.organization_id = @organization_id
         GROUP BY m.rating_code
    )
    SELECT l.rating_code                              AS RatingCode,
           l.rating_name                              AS RatingName,
           l.severity                                 AS Severity,

           inh.role_id                                AS InherentRoleId,
           inh.role_name                              AS InherentRoleName,

           res.role_id                                AS ResidualRoleId,
           res.role_name                              AS ResidualRoleName,
           ISNULL(res.same_as_inherent, 0)            AS ResidualSameAsInherent,

           -- What actually applies right now, fallback included, so the
           -- page shows the effective answer rather than only the
           -- override. This is the same resolution section 5 performs.
           COALESCE(inh.role_id, @fallback_role_id)   AS EffectiveInherentRoleId,
           COALESCE(inh.role_name, @fallback_role_name) AS EffectiveInherentRoleName,
           CASE WHEN ISNULL(res.same_as_inherent, 0) = 1
                THEN COALESCE(inh.role_id, @fallback_role_id)
                ELSE COALESCE(res.role_id, @fallback_role_id) END AS EffectiveResidualRoleId,
           CASE WHEN ISNULL(res.same_as_inherent, 0) = 1
                THEN COALESCE(inh.role_name, @fallback_role_name)
                ELSE COALESCE(res.role_name, @fallback_role_name) END AS EffectiveResidualRoleName,

           CAST(CASE WHEN inh.role_id IS NULL THEN 1 ELSE 0 END AS BIT) AS InherentUsesFallback,
           CAST(CASE WHEN ISNULL(res.same_as_inherent,0) = 0
                      AND res.role_id IS NULL THEN 1 ELSE 0 END AS BIT) AS ResidualUsesFallback
      FROM levels l
      LEFT JOIN grac_practice.org_risk_acceptance_authority inh
             ON inh.organization_id = @organization_id
            AND inh.rating_code     = l.rating_code
            AND inh.scope_code      = N'Inherent'
      LEFT JOIN grac_practice.org_risk_acceptance_authority res
             ON res.organization_id = @organization_id
            AND res.rating_code     = l.rating_code
            AND res.scope_code      = N'Residual'
     ORDER BY l.severity DESC, l.rating_code;

    -- ---- 2) the roles this organisation has -------------------------
    SELECT r.role_id AS RoleId, r.role_name AS RoleName
      FROM grac_practice.organization_role r
     WHERE r.organization_id = @organization_id
       AND r.status = N'Active'
     ORDER BY r.role_name;

    -- ---- 3) the 212 settings this page defers to --------------------
    SELECT @approval_required   AS ApprovalRequired,
           @min_rating          AS ApprovalMinRatingCode,
           @fallback_role_id    AS FallbackRoleId,
           @fallback_role_name  AS FallbackRoleName;
END;
GO

-- =====================================================================
-- 4. sp_org_risk_acceptance_authority_save
--
-- The whole grid in one call, as JSON:
--
--   [{"ratingCode":"Critical","inherentRoleId":4,
--     "residualRoleId":null,"residualSameAsInherent":true}, ...]
--
-- JSON rather than a row-per-call: the page saves a grid, and N calls
-- would mean N transactions and a half-saved configuration if one fails.
--
-- ALL OR NOTHING, and only what changed is written or audited.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_risk_acceptance_authority_save
    @organization_id     BIGINT,
    @rows_json           NVARCHAR(MAX),
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 56741, 'sp_org_risk_acceptance_authority_save: organization_id is required.', 1;
    IF @rows_json IS NULL OR LEN(LTRIM(RTRIM(@rows_json))) = 0
        THROW 56742, 'sp_org_risk_acceptance_authority_save: no rows were supplied.', 1;
    IF ISJSON(@rows_json) <> 1
        THROW 56743, 'sp_org_risk_acceptance_authority_save: rows_json is not valid JSON.', 1;

    DECLARE @in TABLE (
        rating_code       NVARCHAR(30) NOT NULL PRIMARY KEY,
        inherent_role_id  BIGINT NULL,
        residual_role_id  BIGINT NULL,
        residual_same     BIT NOT NULL
    );

    INSERT INTO @in (rating_code, inherent_role_id, residual_role_id, residual_same)
    SELECT j.ratingCode, j.inherentRoleId, j.residualRoleId, ISNULL(j.residualSameAsInherent, 0)
      FROM OPENJSON(@rows_json)
           WITH (ratingCode             NVARCHAR(30) '$.ratingCode',
                 inherentRoleId         BIGINT       '$.inherentRoleId',
                 residualRoleId         BIGINT       '$.residualRoleId',
                 residualSameAsInherent BIT          '$.residualSameAsInherent') j
     WHERE j.ratingCode IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @in)
        THROW 56744, 'sp_org_risk_acceptance_authority_save: no usable rows in rows_json.', 1;

    -- ---- validation, before anything is written ---------------------
    -- Every rating must be one this organisation's matrix produces. The
    -- same rule sp_risk_config_save enforces (56222), for the same
    -- reason: a level the matrix never emits is a row no risk can match.
    DECLARE @bad NVARCHAR(400);

    SELECT @bad = STRING_AGG(i.rating_code, N', ')
      FROM @in i
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell m
                        WHERE m.organization_id = @organization_id
                          AND m.rating_code     = i.rating_code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @m1 NVARCHAR(600) = CONCAT(
            N'sp_org_risk_acceptance_authority_save: these ratings are not produced by this organisation''s risk matrix: ',
            @bad, N'.');
        THROW 56745, @m1, 1;
    END

    -- Roles must belong to THIS organisation. Without this a config
    -- could name a role from another tenant.
    SELECT @bad = STRING_AGG(CAST(x.role_id AS NVARCHAR(20)), N', ')
      FROM (SELECT inherent_role_id AS role_id FROM @in WHERE inherent_role_id IS NOT NULL
            UNION
            SELECT residual_role_id FROM @in WHERE residual_role_id IS NOT NULL) x
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role r
                        WHERE r.role_id = x.role_id
                          AND r.organization_id = @organization_id);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @m2 NVARCHAR(600) = CONCAT(
            N'sp_org_risk_acceptance_authority_save: these roles do not belong to this organisation: ', @bad, N'.');
        THROW 56746, @m2, 1;
    END

    -- "Same as inherent" needs an inherent role to be the same AS --
    -- either configured here or already stored. Otherwise the residual
    -- row points at nothing and silently falls through to the blanket
    -- role, which is not what the checkbox says.
    SELECT @bad = STRING_AGG(i.rating_code, N', ')
      FROM @in i
     WHERE i.residual_same = 1
       AND i.inherent_role_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_acceptance_authority a
                        WHERE a.organization_id = @organization_id
                          AND a.rating_code     = i.rating_code
                          AND a.scope_code      = N'Inherent'
                          AND a.role_id IS NOT NULL);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @m3 NVARCHAR(600) = CONCAT(
            N'sp_org_risk_acceptance_authority_save: "same as inherent" needs an inherent approver for: ',
            @bad, N'. Set the inherent authority first.');
        THROW 56747, @m3, 1;
    END

    DECLARE @actor_name NVARCHAR(240) =
        (SELECT TOP 1 e.employee_name FROM grac_practice.organization_employee e
          WHERE e.employee_id = @actor_employee_id);

    BEGIN TRAN;

    BEGIN TRY
        -- Audit BEFORE the write, while the old values are still there.
        -- Only genuine differences: re-saving an unchanged grid must not
        -- fill the history with "Critical: Risk Owner -> Risk Owner".
        INSERT INTO grac_practice.org_risk_acceptance_authority_history
            (organization_id, rating_code, scope_code, action_code, field_code,
             from_value, to_value, remark, actor_employee_id, actor_display_name,
             entered_by, entered_dt)
        SELECT @organization_id, d.rating_code, d.scope_code,
               CASE WHEN d.new_value IS NULL THEN N'Cleared' ELSE N'Set' END,
               N'approver',
               d.old_value, d.new_value,
               N'Risk acceptance approval authority changed.',
               @actor_employee_id, @actor_name, @caller_display_name, SYSUTCDATETIME()
        FROM (
            -- Inherent
            SELECT i.rating_code, N'Inherent' AS scope_code,
                   old.role_name AS old_value,
                   (SELECT r.role_name FROM grac_practice.organization_role r
                     WHERE r.role_id = i.inherent_role_id) AS new_value
              FROM @in i
              LEFT JOIN grac_practice.org_risk_acceptance_authority old
                     ON old.organization_id = @organization_id
                    AND old.rating_code     = i.rating_code
                    AND old.scope_code      = N'Inherent'
            UNION ALL
            -- Residual. "same as inherent" is recorded as a value in its
            -- own right, because switching to it IS the change.
            SELECT i.rating_code, N'Residual',
                   CASE WHEN ISNULL(old.same_as_inherent,0) = 1
                        THEN N'(same as inherent)' ELSE old.role_name END,
                   CASE WHEN i.residual_same = 1 THEN N'(same as inherent)'
                        ELSE (SELECT r.role_name FROM grac_practice.organization_role r
                               WHERE r.role_id = i.residual_role_id) END
              FROM @in i
              LEFT JOIN grac_practice.org_risk_acceptance_authority old
                     ON old.organization_id = @organization_id
                    AND old.rating_code     = i.rating_code
                    AND old.scope_code      = N'Residual'
        ) d
        WHERE ISNULL(d.old_value, N'~') <> ISNULL(d.new_value, N'~');

        -- ---- Inherent ------------------------------------------------
        MERGE grac_practice.org_risk_acceptance_authority AS t
        USING (SELECT @organization_id AS organization_id, rating_code,
                      N'Inherent' AS scope_code, inherent_role_id AS role_id
                 FROM @in) AS s
           ON  t.organization_id = s.organization_id
           AND t.rating_code     = s.rating_code
           AND t.scope_code      = s.scope_code
        WHEN MATCHED AND s.role_id IS NULL THEN DELETE   -- cleared = fall back
        WHEN MATCHED AND s.role_id IS NOT NULL THEN
            UPDATE SET role_id    = s.role_id,
                       role_name  = (SELECT r.role_name FROM grac_practice.organization_role r
                                      WHERE r.role_id = s.role_id),
                       updated_by = @caller_display_name,
                       updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET AND s.role_id IS NOT NULL THEN
            INSERT (organization_id, rating_code, scope_code, role_id, role_name,
                    same_as_inherent, entered_by)
            VALUES (s.organization_id, s.rating_code, s.scope_code, s.role_id,
                    (SELECT r.role_name FROM grac_practice.organization_role r
                      WHERE r.role_id = s.role_id),
                    0, @caller_display_name);

        -- ---- Residual ------------------------------------------------
        MERGE grac_practice.org_risk_acceptance_authority AS t
        USING (SELECT @organization_id AS organization_id, rating_code,
                      N'Residual' AS scope_code,
                      CASE WHEN residual_same = 1 THEN NULL ELSE residual_role_id END AS role_id,
                      residual_same
                 FROM @in) AS s
           ON  t.organization_id = s.organization_id
           AND t.rating_code     = s.rating_code
           AND t.scope_code      = s.scope_code
        WHEN MATCHED AND s.role_id IS NULL AND s.residual_same = 0 THEN DELETE
        WHEN MATCHED THEN
            UPDATE SET role_id          = s.role_id,
                       role_name        = (SELECT r.role_name FROM grac_practice.organization_role r
                                            WHERE r.role_id = s.role_id),
                       same_as_inherent = s.residual_same,
                       updated_by       = @caller_display_name,
                       updated_dt       = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET AND (s.role_id IS NOT NULL OR s.residual_same = 1) THEN
            INSERT (organization_id, rating_code, scope_code, role_id, role_name,
                    same_as_inherent, entered_by)
            VALUES (s.organization_id, s.rating_code, s.scope_code, s.role_id,
                    (SELECT r.role_name FROM grac_practice.organization_role r
                      WHERE r.role_id = s.role_id),
                    s.residual_same, @caller_display_name);

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- The saved state, so the page re-renders from the database rather
    -- than from what it hoped it sent.
    EXEC grac_practice.sp_org_risk_acceptance_authority_get @organization_id = @organization_id;
END;
GO

-- =====================================================================
-- 5. sp_risk_acceptance_authority_resolve
--
-- "Who may approve accepting THIS risk?" -- the one place that answers
-- it, so the acceptance screen, any approval queue and any future
-- notification cannot each decide differently.
--
-- @scope_code chooses which score governs: a risk being accepted after
-- treatment is judged on its RESIDUAL rating, one accepted as-is on its
-- INHERENT rating. The caller knows which; this does not guess.
--
-- Resolution order, and the fallback is the whole point:
--     1. the configured (rating, scope) row
--     2. for Residual with same_as_inherent, the Inherent row
--     3. org_risk_config.approver_role_id  <- what applies today
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_authority_resolve
    @risk_register_id BIGINT,
    @scope_code       NVARCHAR(20) = NULL    -- NULL = decide from the risk
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56748, 'sp_risk_acceptance_authority_resolve: risk_register_id is required.', 1;

    DECLARE @org BIGINT, @inherent NVARCHAR(30), @residual NVARCHAR(30),
            @risk_number NVARCHAR(60);

    SELECT @org         = r.organization_id,
           @inherent    = r.inherent_rating_code,
           @residual    = r.residual_rating_code,
           @risk_number = r.risk_number
      FROM grac_practice.risk_register r
     WHERE r.risk_register_id = @risk_register_id;

    IF @org IS NULL
        THROW 56749, 'sp_risk_acceptance_authority_resolve: risk not found.', 1;

    -- A risk that has been residually assessed is judged on what remains
    -- after treatment; one that has not is judged on its inherent score.
    IF @scope_code IS NULL
        SET @scope_code = CASE WHEN @residual IS NOT NULL THEN N'Residual' ELSE N'Inherent' END;

    DECLARE @rating NVARCHAR(30) =
        CASE WHEN @scope_code = N'Residual' THEN COALESCE(@residual, @inherent) ELSE @inherent END;

    DECLARE @role_id BIGINT, @role_name NVARCHAR(200), @source NVARCHAR(40);

    -- 1 / 2. the configured row, following "same as inherent"
    SELECT TOP 1
           @role_id   = CASE WHEN a.same_as_inherent = 1 THEN inh.role_id   ELSE a.role_id   END,
           @role_name = CASE WHEN a.same_as_inherent = 1 THEN inh.role_name ELSE a.role_name END,
           @source    = CASE WHEN a.same_as_inherent = 1
                             THEN N'SameAsInherent' ELSE N'Configured' END
      FROM grac_practice.org_risk_acceptance_authority a
      LEFT JOIN grac_practice.org_risk_acceptance_authority inh
             ON inh.organization_id = a.organization_id
            AND inh.rating_code     = a.rating_code
            AND inh.scope_code      = N'Inherent'
     WHERE a.organization_id = @org
       AND a.rating_code     = @rating
       AND a.scope_code      = @scope_code;

    -- 3. the blanket role from 212 -- what every organisation uses today
    IF @role_id IS NULL
    BEGIN
        SELECT @role_id   = c.approver_role_id,
               @role_name = c.approver_role_name,
               @source    = N'OrgFallback'
          FROM grac_practice.org_risk_config c
         WHERE c.organization_id = @org;
    END

    SELECT @risk_register_id                       AS RiskRegisterId,
           @risk_number                            AS RiskNumber,
           @org                                    AS OrganizationId,
           @scope_code                             AS ScopeCode,
           @rating                                 AS RatingCode,
           @role_id                                AS ApproverRoleId,
           @role_name                              AS ApproverRoleName,
           ISNULL(@source, N'NotConfigured')       AS ResolvedFrom;
END;
GO

-- =====================================================================
-- 6. The menu row
--
-- A child of nav-organization, exactly as 059 placed
-- organization-administration. No new top-level group, no new module:
-- menu_url follows the Practice/Index/<key> convention and the screen
-- renders from Views/Practice/Partials/<key>.cshtml.
--
-- display_order 260 puts it after the existing children (195, 200,
-- 205 ...) rather than pushing anything down.
-- =====================================================================
DECLARE @org_parent_id BIGINT = (
    SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');

IF @org_parent_id IS NULL
    PRINT 'NOTE (271): nav-organization is missing -- run 052 first. The screen works by direct URL; only the sidebar entry is absent.';
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM grac_practice.menu_master
                WHERE menu_key = N'risk-acceptance-authority')
        UPDATE grac_practice.menu_master
           SET menu_name      = N'Risk Acceptance Approval Authority',
               menu_url       = N'Practice/Index/risk-acceptance-authority',
               parent_menu_id = @org_parent_id,
               display_order  = 260,
               icon_class     = N'user-shield',
               module_type    = N'Organization',
               status         = N'Active',
               updated_by     = 'seed-271',
               updated_dt     = SYSUTCDATETIME()
         WHERE menu_key = N'risk-acceptance-authority';
    ELSE
        INSERT INTO grac_practice.menu_master
            (menu_key, menu_name, menu_url, parent_menu_id, display_order,
             icon_class, module_type, status, entered_by, entered_dt)
        VALUES
            (N'risk-acceptance-authority', N'Risk Acceptance Approval Authority',
             N'Practice/Index/risk-acceptance-authority', @org_parent_id, 260,
             N'user-shield', N'Organization', N'Active', 'seed-271', SYSUTCDATETIME());

    PRINT '271: menu row placed under Organization.';
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '--- 271 verification ---';

SELECT '271 tables exist' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_risk_acceptance_authority','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_risk_acceptance_authority_history','U') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '271 procedures exist' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_risk_acceptance_authority_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_risk_acceptance_authority_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_acceptance_authority_resolve','P') IS NOT NULL
            THEN 'PASS' ELSE '*** FAIL' END AS Result;

SELECT '271 menu sits UNDER Organization, not at top level' AS Check_,
       CASE WHEN EXISTS (
              SELECT 1 FROM grac_practice.menu_master m
               JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
              WHERE m.menu_key = N'risk-acceptance-authority'
                AND p.menu_key = N'nav-organization'
                AND m.status = N'Active')
            THEN 'PASS' ELSE '*** CHECK -- run 052 if nav-organization is absent' END AS Result;

SELECT '271 levels are derived, not hard-coded' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_org_risk_acceptance_authority_get')
                            AND definition LIKE '%risk_matrix_cell%')
             AND NOT EXISTS (SELECT 1 FROM sys.sql_modules
                              WHERE object_id = OBJECT_ID('grac_practice.sp_org_risk_acceptance_authority_get')
                                AND definition LIKE '%Very High%')
            THEN 'PASS -- read from the organisation''s own matrix'
            ELSE '*** FAIL -- a rating vocabulary is hard-coded' END AS Result;

SELECT '271 the 212 fallback still applies' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_risk_acceptance_authority_resolve')
                            AND definition LIKE '%approver_role_id%')
            THEN 'PASS -- an unconfigured level falls back, nothing breaks on deploy'
            ELSE '*** FAIL -- organisations would lose their approver' END AS Result;

-- What this organisation will actually see. Four rows on a default
-- matrix, not five -- see the header.
SELECT '271 levels for organization 1' AS Check_,
       ISNULL(STRING_AGG(x.rating_code, N', '), N'(no matrix seeded)') AS Result
  FROM (SELECT DISTINCT rating_code FROM grac_practice.risk_matrix_cell
         WHERE organization_id = 1) x;

PRINT '271 Risk acceptance approval authority installed.';
PRINT '     Organization -> Risk Acceptance Approval Authority.';
PRINT '     Levels come from each organisation''s risk matrix.';
PRINT '     Unconfigured levels fall back to org_risk_config.approver_role_id,';
PRINT '     so nothing changes for an organisation until someone opens the page.';
GO

SET NOEXEC OFF;
GO
