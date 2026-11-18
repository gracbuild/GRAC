-- =====================================================================
-- 580  Audit Intelligence -- Framework & Practice Mapping
--      (CR2 - AA Part B; Phase 2; docs/audit-intelligence.md)
--
-- REQUEST (2026-11-17, sir: "next phase"): map each Audit Universe
--   subject to the frameworks, releases, controls, requirements,
--   obligations, GRAC practices and practice instances that apply to it
--   (CR2 4.3), with suggestions from existing GRAC relationships that a
--   user confirms or rejects (4.4), keeping only GRAC's own identifiers
--   (4.5 -- nothing copied from the repository or Practice Management).
--
-- LEVELS (GRAC has no Control record -- the framework tree is Framework
-- -> Release -> Source Structure -> Source Statement, practice_statement
-- model; same reading as the Scope Builder, 534):
--   FRAMEWORK          repository artifact (with its authority), or the
--                      "Custom Releases" group      key 'A<artifact>' / 'C'
--   RELEASE            subscribed release / custom release  'R<id>' / 'S<subscription>'
--   CONTROL            a source structure node      the 534 StructureKey
--   REQUIREMENT        a source statement           org_statement_id
--   OBLIGATION         an obligation of a practice instance
--                                                    practice_instance_obligation_id
--   PRACTICE           practice_id
--   PRACTICE_INSTANCE  practice_instance_id
--   Every row also keeps the context it sits in (framework, release,
--   control, requirement, practice, instance) where that is known.
--
-- SUGGESTIONS (Refresh Suggestions; CR2 4.4 "organizational relationships,
-- practice instance applicability, requirement-to-practice mappings"):
--   subject -> its active Organization Registry records (an Organization
--   Unit adds the locations, departments and processes of that unit) ->
--   the active practice instances that DEPEND on those records in
--   Operationalize (practice_dependency_resolution: Location, Department,
--   Business Function, Process) -> their practices -> the statements those
--   practices are mapped to (fn_org_scope_statement_instance, both 534
--   routes) -> the statements' controls, releases and frameworks; and the
--   instances' active obligations. A Legal Entity subject is not expanded
--   (it would suggest everything). New suggestions are added as Suggested;
--   decided rows (Confirmed / Rejected / Inactive) are never changed by a
--   refresh; a Suggested row no longer derived is removed (it was never
--   decided). Each suggestion says why (suggestion basis).
--
-- STATUSES (CR2 4.4): Suggested -> Confirmed / Rejected; Confirmed ->
--   Rejected / Inactive; Rejected -> Confirmed; Inactive -> Confirmed.
--   A manual mapping is added Confirmed. Reject and deactivate need a
--   reason. Not on a Retired subject. Every decision is in the Universe
--   History (577).
--
-- WHAT THIS DOES
--   1. NEW org_assurance_universe_mapping.
--   2. NEW fn_org_assurance_universe_mapping_ref(@org) -- every mappable
--      record with its code, name and context (read live; a mapped record
--      that is gone shows as no longer available).
--   3. NEW procedures: universe_mapping_list, universe_mapping_options,
--      universe_mapping_suggest, universe_mapping_add, universe_mapping_action.
--   4. Menu: Audit Intelligence -> Framework & Practice Mapping (30), the
--      Audit Plans permissions copied; written back into 274.
--
-- ERRORS: 54120 subject not found; 54121 the subject is retired; 54122
--   unknown level / action; 54123 nothing selected; 54124 a record is not
--   available in this organization; 54125 not allowed in the mapping's
--   status; 54126 reason required.
-- DEPENDS ON: 534 (statement functions), 577 (Audit Universe), 578 (menu
--   group).
-- Rollback: 580_audit_universe_mapping_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_universe_subject','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_scope_statement','IF') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_scope_statement_instance','IF') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence')
BEGIN
    PRINT 'ABORT (580): run 534, 577 and 578 first. Nothing was changed.';
    RAISERROR('580_audit_universe_mapping: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The mapping
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_universe_mapping','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_universe_mapping(
        universe_mapping_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_uni_map PRIMARY KEY,
        organization_id       BIGINT         NOT NULL,
        universe_subject_id   BIGINT         NOT NULL,
        mapping_level         NVARCHAR(30)   NOT NULL,
        record_key            NVARCHAR(80)   NOT NULL,
        framework_key         NVARCHAR(40)   NULL,
        release_key           NVARCHAR(40)   NULL,
        structure_key         NVARCHAR(80)   NULL,
        org_statement_id      BIGINT         NULL,
        practice_id           BIGINT         NULL,
        practice_instance_id  BIGINT         NULL,
        practice_instance_obligation_id BIGINT NULL,
        mapping_source        NVARCHAR(10)   NOT NULL,
        mapping_status        NVARCHAR(20)   NOT NULL,
        suggestion_basis      NVARCHAR(400)  NULL,
        confirmed_employee_id BIGINT         NULL,
        confirmed_by          NVARCHAR(240)  NULL,
        confirmed_dt          DATETIME2      NULL,
        remarks               NVARCHAR(1000) NULL,
        entered_by            NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_oa_uni_map_by DEFAULT 'system',
        entered_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_oa_uni_map_dt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100)  NULL,
        updated_dt            DATETIME2      NULL,
        CONSTRAINT fk_pm_oa_uni_map_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_uni_map_subject FOREIGN KEY(universe_subject_id)
            REFERENCES grac_practice.org_assurance_universe_subject(universe_subject_id),
        CONSTRAINT ck_pm_oa_uni_map_level CHECK (mapping_level IN
            (N'FRAMEWORK', N'RELEASE', N'CONTROL', N'REQUIREMENT', N'OBLIGATION', N'PRACTICE', N'PRACTICE_INSTANCE')),
        CONSTRAINT ck_pm_oa_uni_map_source CHECK (mapping_source IN (N'AUTO', N'MANUAL')),
        CONSTRAINT ck_pm_oa_uni_map_status CHECK (mapping_status IN (N'SUGGESTED', N'CONFIRMED', N'REJECTED', N'INACTIVE')),
        CONSTRAINT uq_pm_oa_uni_map UNIQUE(universe_subject_id, mapping_level, record_key)
    );
    CREATE INDEX ix_pm_oa_uni_map_subject ON grac_practice.org_assurance_universe_mapping(organization_id, universe_subject_id, mapping_status);
    PRINT '580.1: org_assurance_universe_mapping created.';
END
GO

-- =====================================================================
-- 2. Every mappable record (live), by level and key
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_universe_mapping_ref(@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    WITH st AS (
        SELECT * FROM grac_practice.fn_org_scope_statement(@organization_id)
    )
    SELECT DISTINCT CAST(N'FRAMEWORK' AS NVARCHAR(30)) AS mapping_level, CAST(st.FrameworkKey AS NVARCHAR(80)) AS record_key,
           CAST(NULL AS NVARCHAR(200)) AS record_code, CAST(st.FrameworkName AS NVARCHAR(600)) AS record_name,
           CAST(st.FrameworkKey AS NVARCHAR(40)) AS framework_key, CAST(st.FrameworkName AS NVARCHAR(600)) AS framework_name,
           CAST(NULL AS NVARCHAR(40)) AS release_key, CAST(NULL AS NVARCHAR(600)) AS release_name,
           CAST(NULL AS NVARCHAR(80)) AS structure_key, CAST(NULL AS NVARCHAR(600)) AS structure_name,
           CAST(NULL AS BIGINT) AS org_statement_id, CAST(NULL AS BIGINT) AS practice_id,
           CAST(NULL AS BIGINT) AS practice_instance_id, CAST(NULL AS BIGINT) AS practice_instance_obligation_id,
           CAST(NULL AS NVARCHAR(600)) AS context_label
      FROM st
    UNION ALL
    SELECT DISTINCT N'RELEASE', st.ReleaseKey, NULL, st.ReleaseName,
           st.FrameworkKey, st.FrameworkName, st.ReleaseKey, st.ReleaseName, NULL, NULL,
           NULL, NULL, NULL, NULL, st.FrameworkName
      FROM st
    UNION ALL
    SELECT DISTINCT N'CONTROL', st.StructureKey, NULL, st.StructureName,
           st.FrameworkKey, st.FrameworkName, st.ReleaseKey, st.ReleaseName, st.StructureKey, st.StructureName,
           NULL, NULL, NULL, NULL, st.FrameworkName + N' / ' + st.ReleaseName
      FROM st
    UNION ALL
    SELECT N'REQUIREMENT', CAST(st.StatementId AS NVARCHAR(80)), st.StatementCode, st.StatementName,
           st.FrameworkKey, st.FrameworkName, st.ReleaseKey, st.ReleaseName, st.StructureKey, st.StructureName,
           st.StatementId, NULL, NULL, NULL, st.ReleaseName + N' / ' + st.StructureName
      FROM st
    UNION ALL
    SELECT N'PRACTICE', CAST(p.practice_id AS NVARCHAR(80)), p.practice_code, p.practice_name,
           NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, p.practice_id, NULL, NULL, NULL
      FROM grac_practice.practice p
     WHERE p.organization_id = @organization_id AND p.status = N'Active'
    UNION ALL
    SELECT N'PRACTICE_INSTANCE', CAST(pi.practice_instance_id AS NVARCHAR(80)), pi.instance_code, pi.instance_name,
           NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, pi.practice_id, pi.practice_instance_id, NULL,
           N'Practice ' + ISNULL(p.practice_code + N' - ', N'') + ISNULL(p.practice_name, N'')
      FROM grac_practice.practice_instance pi
      LEFT JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
     WHERE pi.organization_id = @organization_id AND pi.status = N'Active'
    UNION ALL
    SELECT N'OBLIGATION', CAST(o.practice_instance_obligation_id AS NVARCHAR(80)), o.obligation_type_code, o.obligation_name,
           NULL, NULL, NULL, NULL, NULL, NULL,
           NULL, pi.practice_id, o.practice_instance_id, o.practice_instance_obligation_id,
           N'Instance ' + ISNULL(pi.instance_code + N' - ', N'') + ISNULL(pi.instance_name, N'')
      FROM grac_practice.practice_instance_obligation o
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = o.practice_instance_id AND pi.status = N'Active'
     WHERE o.organization_id = @organization_id AND o.status = N'Active';
GO

-- =====================================================================
-- 3. Procedures
-- =====================================================================

-- 3a. One subject's mappings (+ counts by level and status).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_mapping_list
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @mapping_level       NVARCHAR(30)  = NULL,
    @mapping_status      NVARCHAR(20)  = NULL,
    @mapping_source      NVARCHAR(10)  = NULL,
    @search              NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_subject
                    WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id)
        THROW 54120, 'The subject was not found in this organization.', 1;

    DECLARE @ref TABLE(mapping_level NVARCHAR(30), record_key NVARCHAR(80), record_code NVARCHAR(200), record_name NVARCHAR(600),
                       framework_name NVARCHAR(600), release_name NVARCHAR(600), structure_name NVARCHAR(600), context_label NVARCHAR(600),
                       PRIMARY KEY (mapping_level, record_key));
    INSERT INTO @ref (mapping_level, record_key, record_code, record_name, framework_name, release_name, structure_name, context_label)
    SELECT r.mapping_level, r.record_key, MAX(r.record_code), MAX(r.record_name), MAX(r.framework_name), MAX(r.release_name),
           MAX(r.structure_name), MAX(r.context_label)
      FROM grac_practice.fn_org_assurance_universe_mapping_ref(@organization_id) r
      JOIN grac_practice.org_assurance_universe_mapping m
           ON m.universe_subject_id = @universe_subject_id AND m.mapping_level = r.mapping_level AND m.record_key = r.record_key
     GROUP BY r.mapping_level, r.record_key;

    SELECT m.universe_mapping_id AS UniverseMappingId, m.mapping_level AS MappingLevel, m.record_key AS RecordKey,
           r.record_code AS RecordCode, r.record_name AS RecordName, r.framework_name AS FrameworkName,
           r.release_name AS ReleaseName, r.structure_name AS ControlName, r.context_label AS ContextLabel,
           CAST(CASE WHEN r.record_key IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAvailable,
           m.mapping_source AS MappingSource, m.mapping_status AS MappingStatus, m.suggestion_basis AS SuggestionBasis,
           m.confirmed_by AS ConfirmedBy, m.confirmed_dt AS ConfirmedDt, m.remarks AS Remarks,
           ISNULL(m.updated_dt, m.entered_dt) AS ChangedDt
      FROM grac_practice.org_assurance_universe_mapping m
      LEFT JOIN @ref r ON r.mapping_level = m.mapping_level AND r.record_key = m.record_key
     WHERE m.universe_subject_id = @universe_subject_id
       AND (NULLIF(@mapping_level, N'') IS NULL OR m.mapping_level = @mapping_level)
       AND (NULLIF(@mapping_status, N'') IS NULL OR m.mapping_status = @mapping_status)
       AND (NULLIF(@mapping_source, N'') IS NULL OR m.mapping_source = @mapping_source)
       AND (NULLIF(@search, N'') IS NULL OR r.record_code LIKE N'%' + @search + N'%' OR r.record_name LIKE N'%' + @search + N'%'
            OR r.context_label LIKE N'%' + @search + N'%' OR m.suggestion_basis LIKE N'%' + @search + N'%')
     ORDER BY CASE m.mapping_level WHEN N'FRAMEWORK' THEN 1 WHEN N'RELEASE' THEN 2 WHEN N'CONTROL' THEN 3 WHEN N'REQUIREMENT' THEN 4
                                   WHEN N'OBLIGATION' THEN 5 WHEN N'PRACTICE' THEN 6 ELSE 7 END,
              CASE m.mapping_status WHEN N'SUGGESTED' THEN 0 WHEN N'CONFIRMED' THEN 1 WHEN N'REJECTED' THEN 2 ELSE 3 END,
              r.record_code, r.record_name;

    SELECT m.mapping_level AS MappingLevel, m.mapping_status AS MappingStatus, COUNT(*) AS MappingCount
      FROM grac_practice.org_assurance_universe_mapping m
     WHERE m.universe_subject_id = @universe_subject_id
     GROUP BY m.mapping_level, m.mapping_status;
END
GO

-- 3a2. The records of one level that can be mapped (Add Mapping's lists;
-- requirements use the 534 statement tree instead).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_mapping_options
    @organization_id BIGINT,
    @mapping_level   NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SET @mapping_level = UPPER(LTRIM(RTRIM(@mapping_level)));
    IF @organization_id IS NULL THROW 54120, 'organization_id is required.', 1;
    IF @mapping_level NOT IN (N'FRAMEWORK', N'RELEASE', N'CONTROL', N'REQUIREMENT', N'OBLIGATION', N'PRACTICE', N'PRACTICE_INSTANCE')
        THROW 54122, 'Unknown mapping level.', 1;
    SELECT r.record_key AS RecordKey, MIN(r.record_code) AS RecordCode, MIN(r.record_name) AS RecordName,
           MIN(r.framework_name) AS FrameworkName, MIN(r.release_name) AS ReleaseName, MIN(r.context_label) AS ContextLabel
      FROM grac_practice.fn_org_assurance_universe_mapping_ref(@organization_id) r
     WHERE r.mapping_level = @mapping_level
     GROUP BY r.record_key
     ORDER BY MIN(r.context_label), MIN(r.record_code), MIN(r.record_name);
END
GO

-- 3b. Refresh the subject's suggestions (see the header).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_mapping_suggest
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @employee_id         BIGINT        = NULL,
    @actor               NVARCHAR(100) = 'system',
    @suggested_count     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @suggested_count = 0;
    DECLARE @status NVARCHAR(30) = (SELECT status_code FROM grac_practice.org_assurance_universe_subject
                                     WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id);
    IF @status IS NULL THROW 54120, 'The subject was not found in this organization.', 1;
    IF @status = N'RETIRED' THROW 54121, 'A retired subject''s mappings are kept as they are.', 1;

    -- the subject's registry records (an Organization Unit adds its own
    -- locations, departments and processes)
    DECLARE @rec TABLE(kind NVARCHAR(30), record_id BIGINT, label NVARCHAR(400), PRIMARY KEY (kind, record_id));
    INSERT INTO @rec (kind, record_id, label)
    SELECT DISTINCT x.source_kind, x.source_record_id,
           grac_practice.fn_org_assurance_universe_kind_label(x.source_kind) + N' ' + ISNULL(r.record_code + N' - ', N'') + ISNULL(r.record_name, N'')
      FROM grac_practice.org_assurance_universe_source x
      JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
           ON r.source_kind = x.source_kind AND r.record_id = x.source_record_id
     WHERE x.universe_subject_id = @universe_subject_id AND x.is_active = 1;
    INSERT INTO @rec (kind, record_id, label)
    SELECT DISTINCT r.source_kind, r.record_id,
           grac_practice.fn_org_assurance_universe_kind_label(r.source_kind) + N' ' + ISNULL(r.record_code + N' - ', N'') + r.record_name
             + N' (in unit ' + ISNULL(u.label, N'') + N')'
      FROM @rec u
      JOIN grac_practice.fn_org_assurance_universe_registry_records(@organization_id) r
           ON r.source_kind IN (N'LOCATION', N'DEPARTMENT', N'PROCESS') AND r.division_id = u.record_id
     WHERE u.kind = N'UNIT'
       AND NOT EXISTS (SELECT 1 FROM @rec z WHERE z.kind = r.source_kind AND z.record_id = r.record_id);

    -- instances depending on those records (Operationalize)
    DECLARE @inst TABLE(practice_instance_id BIGINT PRIMARY KEY, practice_id BIGINT, basis NVARCHAR(400));
    INSERT INTO @inst (practice_instance_id, practice_id, basis)
    SELECT pi.practice_instance_id, pi.practice_id, MIN(N'Depends on ' + r.label)
      FROM @rec r
      JOIN grac_practice.dependency_type_master dt
           ON dt.dependency_type_code = CASE r.kind WHEN N'LOCATION' THEN N'Location' WHEN N'DEPARTMENT' THEN N'Department'
                                                    WHEN N'FUNCTION' THEN N'BusinessFunction' WHEN N'PROCESS' THEN N'Process' END
      JOIN grac_practice.practice_dependency_resolution d
           ON d.organization_id = @organization_id AND d.dependency_type_id = dt.dependency_type_id
          AND d.resolved_dependency_id = r.record_id AND d.is_active = 1
      JOIN grac_practice.practice_instance pi
           ON pi.practice_instance_id = d.practice_instance_id AND pi.organization_id = @organization_id AND pi.status = N'Active'
     GROUP BY pi.practice_instance_id, pi.practice_id;

    DECLARE @sug TABLE(mapping_level NVARCHAR(30), record_key NVARCHAR(80), framework_key NVARCHAR(40), release_key NVARCHAR(40),
                       structure_key NVARCHAR(80), org_statement_id BIGINT, practice_id BIGINT, practice_instance_id BIGINT,
                       practice_instance_obligation_id BIGINT, basis NVARCHAR(400), PRIMARY KEY (mapping_level, record_key));
    -- practice instances
    INSERT INTO @sug (mapping_level, record_key, practice_id, practice_instance_id, basis)
    SELECT N'PRACTICE_INSTANCE', CAST(i.practice_instance_id AS NVARCHAR(80)), i.practice_id, i.practice_instance_id, i.basis
      FROM @inst i;
    -- practices
    INSERT INTO @sug (mapping_level, record_key, practice_id, basis)
    SELECT N'PRACTICE', CAST(p.practice_id AS NVARCHAR(80)), p.practice_id,
           MIN(N'Has practice instance ' + pi.instance_code + N' (' + i.basis + N')')
      FROM @inst i
      JOIN grac_practice.practice p ON p.practice_id = i.practice_id AND p.status = N'Active'
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = i.practice_instance_id
     GROUP BY p.practice_id;
    -- obligations of those instances
    INSERT INTO @sug (mapping_level, record_key, practice_id, practice_instance_id, practice_instance_obligation_id, basis)
    SELECT N'OBLIGATION', CAST(o.practice_instance_obligation_id AS NVARCHAR(80)), i.practice_id, o.practice_instance_id,
           o.practice_instance_obligation_id, LEFT(N'Obligation of practice instance ' + pi.instance_code, 400)
      FROM @inst i
      JOIN grac_practice.practice_instance_obligation o
           ON o.practice_instance_id = i.practice_instance_id AND o.organization_id = @organization_id AND o.status = N'Active'
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = i.practice_instance_id;
    -- requirements (statements mapped to those practices)
    DECLARE @stm TABLE(StatementId BIGINT PRIMARY KEY, basis NVARCHAR(400));
    INSERT INTO @stm (StatementId, basis)
    SELECT si.StatementId, MIN(N'Mapped to practice ' + ISNULL(p.practice_code, N'') + N' (instance ' + pi.instance_code + N')')
      FROM grac_practice.fn_org_scope_statement_instance(@organization_id) si
      JOIN @inst i ON i.practice_instance_id = si.PracticeInstanceId
      JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = i.practice_instance_id
      LEFT JOIN grac_practice.practice p ON p.practice_id = i.practice_id
     GROUP BY si.StatementId;
    INSERT INTO @sug (mapping_level, record_key, framework_key, release_key, structure_key, org_statement_id, basis)
    SELECT N'REQUIREMENT', CAST(s.StatementId AS NVARCHAR(80)), MIN(s.FrameworkKey), MIN(s.ReleaseKey), MIN(s.StructureKey), s.StatementId, MIN(m.basis)
      FROM grac_practice.fn_org_scope_statement(@organization_id) s
      JOIN @stm m ON m.StatementId = s.StatementId
     GROUP BY s.StatementId;
    -- their controls, releases and frameworks
    INSERT INTO @sug (mapping_level, record_key, framework_key, release_key, structure_key, basis)
    SELECT N'CONTROL', q.structure_key, MIN(q.framework_key), MIN(q.release_key), q.structure_key,
           N'Contains suggested requirement(s): ' + CAST(COUNT(*) AS NVARCHAR(10))
      FROM @sug q WHERE q.mapping_level = N'REQUIREMENT' AND q.structure_key IS NOT NULL
     GROUP BY q.structure_key;
    INSERT INTO @sug (mapping_level, record_key, framework_key, release_key, basis)
    SELECT N'RELEASE', q.release_key, MIN(q.framework_key), q.release_key,
           N'Contains suggested requirement(s): ' + CAST(COUNT(*) AS NVARCHAR(10))
      FROM @sug q WHERE q.mapping_level = N'REQUIREMENT' AND q.release_key IS NOT NULL
     GROUP BY q.release_key;
    INSERT INTO @sug (mapping_level, record_key, framework_key, basis)
    SELECT N'FRAMEWORK', q.framework_key, q.framework_key,
           N'Contains suggested requirement(s): ' + CAST(COUNT(*) AS NVARCHAR(10))
      FROM @sug q WHERE q.mapping_level = N'REQUIREMENT' AND q.framework_key IS NOT NULL
     GROUP BY q.framework_key;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @removed INT;
    BEGIN TRAN;
    -- undecided suggestions that no longer apply
    DELETE m
      FROM grac_practice.org_assurance_universe_mapping m
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_source = N'AUTO' AND m.mapping_status = N'SUGGESTED'
       AND NOT EXISTS (SELECT 1 FROM @sug s WHERE s.mapping_level = m.mapping_level AND s.record_key = m.record_key);
    SET @removed = @@ROWCOUNT;
    -- the basis of the ones still suggested
    UPDATE m SET suggestion_basis = s.basis, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN @sug s ON s.mapping_level = m.mapping_level AND s.record_key = m.record_key
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_source = N'AUTO' AND m.mapping_status = N'SUGGESTED'
       AND ISNULL(m.suggestion_basis, N'') <> ISNULL(s.basis, N'');
    -- new ones
    INSERT INTO grac_practice.org_assurance_universe_mapping
        (organization_id, universe_subject_id, mapping_level, record_key, framework_key, release_key, structure_key,
         org_statement_id, practice_id, practice_instance_id, practice_instance_obligation_id,
         mapping_source, mapping_status, suggestion_basis, entered_by)
    SELECT @organization_id, @universe_subject_id, s.mapping_level, s.record_key, s.framework_key, s.release_key, s.structure_key,
           s.org_statement_id, s.practice_id, s.practice_instance_id, s.practice_instance_obligation_id,
           N'AUTO', N'SUGGESTED', s.basis, @actor
      FROM @sug s
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping m
                        WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = s.mapping_level
                          AND m.record_key = s.record_key);
    SET @suggested_count = @@ROWCOUNT;
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, comment, employee_id, actor_name)
    VALUES (@organization_id, @universe_subject_id, N'MAP_SUGGEST',
            N'Suggestions refreshed: ' + CAST(@suggested_count AS NVARCHAR(10)) + N' new, '
              + CAST(@removed AS NVARCHAR(10)) + N' no longer applicable removed', @employee_id, @me);
    COMMIT;
END
GO

-- 3c. Add mappings by hand (Confirmed): @keys_json [ "key", ... ] of one
-- level. An existing row of the same record is confirmed instead.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_mapping_add
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @mapping_level       NVARCHAR(30),
    @keys_json           NVARCHAR(MAX),
    @remarks             NVARCHAR(1000) = NULL,
    @employee_id         BIGINT         = NULL,
    @actor               NVARCHAR(100)  = 'system',
    @added_count         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @added_count = 0;
    SET @mapping_level = UPPER(LTRIM(RTRIM(@mapping_level)));
    SET @remarks = NULLIF(LTRIM(RTRIM(@remarks)), N'');
    DECLARE @status NVARCHAR(30) = (SELECT status_code FROM grac_practice.org_assurance_universe_subject
                                     WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id);
    IF @status IS NULL THROW 54120, 'The subject was not found in this organization.', 1;
    IF @status = N'RETIRED' THROW 54121, 'A retired subject''s mappings are kept as they are.', 1;
    IF @mapping_level NOT IN (N'FRAMEWORK', N'RELEASE', N'CONTROL', N'REQUIREMENT', N'OBLIGATION', N'PRACTICE', N'PRACTICE_INSTANCE')
        THROW 54122, 'Unknown mapping level.', 1;
    IF ISJSON(ISNULL(@keys_json, N'')) = 0 THROW 54123, 'Select at least one record.', 1;

    DECLARE @keys TABLE(record_key NVARCHAR(80) PRIMARY KEY);
    INSERT INTO @keys (record_key)
    SELECT DISTINCT LTRIM(RTRIM(j.value)) FROM OPENJSON(@keys_json) j WHERE NULLIF(LTRIM(RTRIM(j.value)), N'') IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @keys) THROW 54123, 'Select at least one record.', 1;

    DECLARE @ref TABLE(record_key NVARCHAR(80) PRIMARY KEY, framework_key NVARCHAR(40), release_key NVARCHAR(40), structure_key NVARCHAR(80),
                       org_statement_id BIGINT, practice_id BIGINT, practice_instance_id BIGINT, practice_instance_obligation_id BIGINT,
                       label NVARCHAR(800));
    INSERT INTO @ref
    SELECT r.record_key, MIN(r.framework_key), MIN(r.release_key), MIN(r.structure_key), MIN(r.org_statement_id), MIN(r.practice_id),
           MIN(r.practice_instance_id), MIN(r.practice_instance_obligation_id), MIN(ISNULL(r.record_code + N' - ', N'') + r.record_name)
      FROM grac_practice.fn_org_assurance_universe_mapping_ref(@organization_id) r
      JOIN @keys k ON k.record_key = r.record_key
     WHERE r.mapping_level = @mapping_level
     GROUP BY r.record_key;
    IF EXISTS (SELECT 1 FROM @keys k WHERE NOT EXISTS (SELECT 1 FROM @ref r WHERE r.record_key = k.record_key))
        THROW 54124, 'A selected record is not available in this organization.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, comment, employee_id, actor_name)
    SELECT @organization_id, @universe_subject_id, N'MAP_ADD',
           LEFT(N'Mapped (' + @mapping_level + N'): ' + r.label + ISNULL(N' -- ' + @remarks, N''), 4000), @employee_id, @me
      FROM @ref r
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping m
                        WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = @mapping_level
                          AND m.record_key = r.record_key AND m.mapping_status = N'CONFIRMED');
    UPDATE m
       SET mapping_status = N'CONFIRMED', confirmed_employee_id = @employee_id, confirmed_by = @me, confirmed_dt = SYSUTCDATETIME(),
           remarks = ISNULL(@remarks, m.remarks), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN @ref r ON r.record_key = m.record_key
     WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = @mapping_level AND m.mapping_status <> N'CONFIRMED';
    SET @added_count = @@ROWCOUNT;
    INSERT INTO grac_practice.org_assurance_universe_mapping
        (organization_id, universe_subject_id, mapping_level, record_key, framework_key, release_key, structure_key,
         org_statement_id, practice_id, practice_instance_id, practice_instance_obligation_id,
         mapping_source, mapping_status, confirmed_employee_id, confirmed_by, confirmed_dt, remarks, entered_by)
    SELECT @organization_id, @universe_subject_id, @mapping_level, r.record_key, r.framework_key, r.release_key, r.structure_key,
           r.org_statement_id, r.practice_id, r.practice_instance_id, r.practice_instance_obligation_id,
           N'MANUAL', N'CONFIRMED', @employee_id, @me, SYSUTCDATETIME(), @remarks, @actor
      FROM @ref r
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping m
                        WHERE m.universe_subject_id = @universe_subject_id AND m.mapping_level = @mapping_level
                          AND m.record_key = r.record_key);
    SET @added_count = @added_count + @@ROWCOUNT;
    COMMIT;
END
GO

-- 3d. Decide mappings: @mapping_ids_json [ id, ... ]
--   CONFIRM     Suggested / Rejected -> Confirmed
--   REJECT      Suggested / Confirmed -> Rejected   (reason)
--   DEACTIVATE  Confirmed -> Inactive               (reason)
--   REACTIVATE  Inactive -> Confirmed
-- Rows not in a status the action applies to are refused (54125).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_universe_mapping_action
    @organization_id     BIGINT,
    @universe_subject_id BIGINT,
    @action              NVARCHAR(20),
    @mapping_ids_json    NVARCHAR(MAX),
    @remarks             NVARCHAR(1000) = NULL,
    @employee_id         BIGINT         = NULL,
    @actor               NVARCHAR(100)  = 'system',
    @applied_count       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @applied_count = 0;
    SET @action  = UPPER(LTRIM(RTRIM(@action)));
    SET @remarks = NULLIF(LTRIM(RTRIM(@remarks)), N'');
    DECLARE @status NVARCHAR(30) = (SELECT status_code FROM grac_practice.org_assurance_universe_subject
                                     WHERE universe_subject_id = @universe_subject_id AND organization_id = @organization_id);
    IF @status IS NULL THROW 54120, 'The subject was not found in this organization.', 1;
    IF @status = N'RETIRED' THROW 54121, 'A retired subject''s mappings are kept as they are.', 1;
    IF @action NOT IN (N'CONFIRM', N'REJECT', N'DEACTIVATE', N'REACTIVATE') THROW 54122, 'Unknown mapping action.', 1;
    IF @action IN (N'REJECT', N'DEACTIVATE') AND @remarks IS NULL THROW 54126, 'Give the reason.', 1;
    IF ISJSON(ISNULL(@mapping_ids_json, N'')) = 0 THROW 54123, 'Select at least one mapping.', 1;

    DECLARE @ids TABLE(id BIGINT PRIMARY KEY);
    INSERT INTO @ids (id)
    SELECT DISTINCT TRY_CAST(j.value AS BIGINT) FROM OPENJSON(@mapping_ids_json) j WHERE TRY_CAST(j.value AS BIGINT) IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @ids) THROW 54123, 'Select at least one mapping.', 1;
    IF EXISTS (SELECT 1 FROM @ids i WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping m
                                                       WHERE m.universe_mapping_id = i.id AND m.universe_subject_id = @universe_subject_id))
        THROW 54124, 'A selected mapping is not one of this subject''s.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_universe_mapping m JOIN @ids i ON i.id = m.universe_mapping_id
                WHERE NOT ((@action = N'CONFIRM'    AND m.mapping_status IN (N'SUGGESTED', N'REJECTED'))
                        OR (@action = N'REJECT'     AND m.mapping_status IN (N'SUGGESTED', N'CONFIRMED'))
                        OR (@action = N'DEACTIVATE' AND m.mapping_status = N'CONFIRMED')
                        OR (@action = N'REACTIVATE' AND m.mapping_status = N'INACTIVE')))
        THROW 54125, 'A selected mapping is not in a status that allows this.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @to NVARCHAR(20) = CASE @action WHEN N'REJECT' THEN N'REJECTED' WHEN N'DEACTIVATE' THEN N'INACTIVE' ELSE N'CONFIRMED' END;

    DECLARE @ref TABLE(mapping_level NVARCHAR(30), record_key NVARCHAR(80), label NVARCHAR(800), PRIMARY KEY (mapping_level, record_key));
    INSERT INTO @ref (mapping_level, record_key, label)
    SELECT r.mapping_level, r.record_key, MIN(ISNULL(r.record_code + N' - ', N'') + r.record_name)
      FROM grac_practice.fn_org_assurance_universe_mapping_ref(@organization_id) r
      JOIN grac_practice.org_assurance_universe_mapping m ON m.mapping_level = r.mapping_level AND m.record_key = r.record_key
      JOIN @ids i ON i.id = m.universe_mapping_id
     GROUP BY r.mapping_level, r.record_key;

    BEGIN TRAN;
    INSERT INTO grac_practice.org_assurance_universe_history
        (organization_id, universe_subject_id, action_code, from_status, to_status, comment, employee_id, actor_name)
    SELECT @organization_id, @universe_subject_id, N'MAP_' + @action, m.mapping_status, @to,
           LEFT(N'(' + m.mapping_level + N') ' + ISNULL(r.label, N'record ' + m.record_key + N' (no longer available)')
                + ISNULL(N' -- ' + @remarks, N''), 4000), @employee_id, @me
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN @ids i ON i.id = m.universe_mapping_id
      LEFT JOIN @ref r ON r.mapping_level = m.mapping_level AND r.record_key = m.record_key;
    UPDATE m
       SET mapping_status        = @to,
           confirmed_employee_id = CASE WHEN @to = N'CONFIRMED' THEN @employee_id ELSE m.confirmed_employee_id END,
           confirmed_by          = CASE WHEN @to = N'CONFIRMED' THEN @me ELSE m.confirmed_by END,
           confirmed_dt          = CASE WHEN @to = N'CONFIRMED' THEN SYSUTCDATETIME() ELSE m.confirmed_dt END,
           remarks               = ISNULL(@remarks, m.remarks),
           updated_by            = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_universe_mapping m
      JOIN @ids i ON i.id = m.universe_mapping_id;
    SET @applied_count = @@ROWCOUNT;
    COMMIT;
END
GO

-- =====================================================================
-- 4. Menu: Audit Intelligence -> Framework & Practice Mapping (30); also
--    in 274's snapshot.
-- =====================================================================
DECLARE @intel_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-universe-mapping', N'Framework & Practice Mapping', N'Practice/org-audit-universe-mapping', 30, N'diagram-project')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @intel_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-580', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @intel_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-580');
PRINT '580.4: org-audit-universe-mapping menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-580', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key = N'org-audit-universe-mapping'
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '580.4: org-audit-universe-mapping permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_universe_mapping_ref'), (N'sp_org_assurance_universe_mapping_list'),
               (N'sp_org_assurance_universe_mapping_options'), (N'sp_org_assurance_universe_mapping_suggest'), (N'sp_org_assurance_universe_mapping_add'),
               (N'sp_org_assurance_universe_mapping_action')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('580 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.menu_master WHERE menu_key = N'org-audit-universe-mapping' AND status = N'Active') AS menu_rows;
PRINT '580 done: Audit Intelligence -- Framework & Practice Mapping (suggested, confirmed, rejected, inactive).';
GO
