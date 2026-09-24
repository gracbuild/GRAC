-- =====================================================================
-- 344 The Checklists tab's two read procedures
--
-- WHAT AND WHY
-- ------------
-- Everything from 340 through 343 made a custom obligation configurable
-- and raisable exactly like a catalog one. This migration is the two new
-- procedures the Checklists tab and its "View Mapped Profiles" action
-- read directly -- the last piece of SQL before the UI (item 6 of the
-- plan) has anything to call.
--
-- sp_event_driven_checklist_list -- ONE ROW PER CHECKLIST
-- ---------------------------------------------------------
-- A "checklist" in this screen's vocabulary is an obligation+event
-- combination, not a per-scope decision -- the same grain
-- sp_event_obligation_mapping_list already collapses catalog rows to via
-- its `pick` CTE (one row per obligation identity + event type, practices
-- rolled up into a comma list via STRING_AGG). This procedure reuses that
-- exact CTE shape, minus the scope-dimension applicability join
-- mapping_list needs and this one does not: the Checklists tab lists what
-- EXISTS, not what one role/asset-category/profile decided about it.
-- Requirement 5 in the original ask keeps the Profile -> Event -> Checklist
-- architecture intact by design here -- this list is the CHECKLIST side of
-- that relationship; sp_event_checklist_mapped_profiles_list below is the
-- reverse read, not a second forward mapping.
--
-- "Practice Instance" MEANS SOMETHING DIFFERENT PER ROW, ON PURPOSE
-- -----------------------------------------------------------------------
-- Confirmed with sir (AskUserQuestion, captured in 341's header too): a
-- catalog decision and a practice-level custom decision are both
-- practice/org-wide -- there is no single instance to name, so the column
-- shows the Practice. Only the instance-only custom kind (227, no
-- practice-level parent) has a genuine single practice_instance behind
-- it, reached here by joining local_instance_obligation_id through
-- practice_instance_obligation to practice_instance for instance_code /
-- instance_name -- vw_pm_event_driven_obligation (342) does not carry
-- those two columns itself, because the view's other three readers
-- (mapping_list, coverage_list, raise) never needed instance-level
-- display fields, only this list does.
--
-- "EVENT" CLEARLY DISTINGUISHES ONBOARDING FROM OFFBOARDING
-- ---------------------------------------------------------------
-- event_type_master is a two-level tree (230's own header: "Event Domain
-- -> Event"), and a leaf's own event_name is already the specific string
-- ("Onboarding", "Offboarding", whatever the domain's children are named)
-- -- EventTypeName alone already answers the requirement. EventDomainName
-- (the parent's event_name) is projected alongside it purely for context
-- when two different domains happen to share a leaf name; the client is
-- not required to use it.
--
-- sp_event_checklist_mapped_profiles_list -- THE REVERSE LOOKUP
-- -------------------------------------------------------------------
-- "Which profiles will receive this checklist" is answered from
-- event_obligation_applicability rows where scope_dimension = 'PROFILE',
-- is_applicable = 1 and status = 'Active' -- actually saved mapping data,
-- never a hardcoded or UI-only list, matching requirement 5's explicit
-- instruction. is_applicable = 1 is deliberate: an Excluded profile
-- decision means that profile will NOT receive the checklist, and a
-- screen titled "which profiles will receive this" showing one anyway
-- would be the "unrelated profiles" requirement 4 specifically rules out.
-- The criteria-summary sub-query is copied verbatim from
-- sp_event_profile_list (330) rather than re-derived, so a profile's
-- criteria read identically on both screens.
--
-- Exactly one of obligation_id / local_practice_obligation_id /
-- local_instance_obligation_id identifies which checklist -- the same
-- three-way identity 341 established and 343 threaded through every
-- other reader.
--
-- SAFE TO RE-RUN. Requires 127, 227, 307, 329, 330, 340, 341, 342, 343.
-- ASCII-only.
--
-- DEPENDS ON: 342 (the view both procedures read), 343 (the composite-
--             identity contract both procedures follow), 330
--             (event_profile / event_profile_criteria -- the criteria
--             summary sub-query's source tables).
-- Rollback:   database/344_event_driven_checklist_and_mapped_profiles_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (344): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.vw_pm_event_driven_obligation','local_practice_obligation_id') IS NULL
BEGIN
    PRINT 'ABORT (344): vw_pm_event_driven_obligation has no local identity columns (run 342 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.event_obligation_applicability','local_practice_obligation_id') IS NULL
BEGIN
    PRINT 'ABORT (344): event_obligation_applicability has no local identity columns (run 341 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
   OR OBJECT_ID('grac_practice.event_profile_criteria','U') IS NULL
BEGIN
    PRINT 'ABORT (344): event_profile / event_profile_criteria missing (run 329/330 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_event_driven_checklist_list -- the Checklists tab
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_driven_checklist_list
    @organization_id BIGINT,
    @event_type_id   BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67470, 'sp_event_driven_checklist_list: organization_id is required.', 1;

    DECLARE @size   INT = ISNULL(NULLIF(@page_size, 0), 25);
    DECLARE @offset INT = (ISNULL(NULLIF(@page_number, 0), 1) - 1) * @size;
    DECLARE @like   NVARCHAR(220) = CASE
        WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0 THEN NULL
        ELSE N'%' + @search + N'%' END;

    -- Same CTE shape sp_event_obligation_mapping_list (343) uses to
    -- collapse a catalog obligation's multiple requirement/practice paths
    -- to one row -- reused here rather than re-derived, minus the
    -- scope-dimension applicability join this list does not need.
    ;WITH v AS (
        SELECT *
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id)
    ),
    codes AS (
        SELECT DISTINCT obligation_id, local_practice_obligation_id, local_instance_obligation_id,
               event_type_id, practice_code
        FROM   v WHERE practice_code IS NOT NULL
    ),
    code_agg AS (
        SELECT obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id,
               STRING_AGG(practice_code, N', ') WITHIN GROUP (ORDER BY practice_code) AS practice_codes
        FROM   codes GROUP BY obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id
    ),
    pick AS (
        SELECT v.*,
               ROW_NUMBER() OVER (
                   PARTITION BY v.obligation_id, v.local_practice_obligation_id, v.local_instance_obligation_id, v.event_type_id
                   ORDER BY v.practice_id, v.organization_requirement_id) AS rn
        FROM v
    )
    SELECT
        p.obligation_id                     AS ObligationId,
        p.local_practice_obligation_id      AS LocalPracticeObligationId,
        p.local_instance_obligation_id      AS LocalInstanceObligationId,
        CASE WHEN p.obligation_id                 IS NOT NULL THEN N'Catalog'
             WHEN p.local_practice_obligation_id   IS NOT NULL THEN N'PracticeLevel'
             ELSE N'InstanceOnly' END        AS ObligationKind,
        p.obligation_label                  AS ObligationName,

        -- Practice Instance column: real only for the InstanceOnly kind
        -- (see header). PracticeInstanceDisplay is the one string a grid
        -- can show without branching on ObligationKind itself.
        --
        -- Catalog rows (branch 1 of vw_pm_event_driven_obligation, 342)
        -- LEFT JOIN to grac_practice.practice -- a long-standing join in
        -- this view (present since 127, unchanged here), because an
        -- organization_requirement can be event-driven and subscribed
        -- before the org's own Practice row for it has been created.
        -- practice_name is legitimately NULL for those rows. Every other
        -- screen that reads this view only ever showed PracticeCode as an
        -- optional secondary caption, so the gap was never visible; this
        -- column is the first place PracticeInstanceDisplay is a mandatory
        -- primary cell, so it now falls all the way back to the owning
        -- Requirement (always present -- it is branch 1's FROM table) and,
        -- only if even that is somehow blank, a literal placeholder --
        -- this column must never render empty.
        pi.practice_instance_id             AS PracticeInstanceId,
        pi.instance_code                    AS PracticeInstanceCode,
        pi.instance_name                    AS PracticeInstanceName,
        p.practice_id                       AS PracticeId,
        COALESCE(ca.practice_codes, p.practice_code, p.requirement_code) AS PracticeCode,
        p.practice_name                     AS PracticeName,
        COALESCE(pi.instance_name, p.practice_name, p.requirement_name,
                 N'(Practice not yet created)')                          AS PracticeInstanceDisplay,

        p.event_type_id                     AS EventTypeId,
        p.event_type_code                   AS EventTypeCode,
        p.event_type_name                   AS EventTypeName,
        dom.event_name                      AS EventDomainName,

        COUNT(*) OVER ()                    AS TotalRows
    FROM       pick p
    LEFT JOIN  code_agg ca
           ON  ISNULL(ca.obligation_id,-1)                = ISNULL(p.obligation_id,-1)
          AND  ISNULL(ca.local_practice_obligation_id,-1) = ISNULL(p.local_practice_obligation_id,-1)
          AND  ISNULL(ca.local_instance_obligation_id,-1) = ISNULL(p.local_instance_obligation_id,-1)
          AND  ca.event_type_id = p.event_type_id
    LEFT JOIN  grac_practice.practice_instance_obligation pio
           ON  pio.practice_instance_obligation_id = p.local_instance_obligation_id
    LEFT JOIN  grac_practice.practice_instance pi
           ON  pi.practice_instance_id = pio.practice_instance_id
    LEFT JOIN  GRAC_New.event_type_master et2
           ON  et2.event_type_id = p.event_type_id
    LEFT JOIN  GRAC_New.event_type_master dom
           ON  dom.event_type_id = et2.parent_event_type_id
    WHERE      p.rn = 1
      AND      (@like IS NULL
                 OR p.obligation_label LIKE @like
                 OR COALESCE(ca.practice_codes, p.practice_code) LIKE @like
                 OR p.practice_name LIKE @like
                 OR p.requirement_name LIKE @like
                 OR p.requirement_code LIKE @like
                 OR pi.instance_name LIKE @like
                 OR pi.instance_code LIKE @like
                 OR p.event_type_name LIKE @like)
    ORDER BY   p.event_type_code,
               COALESCE(pi.instance_name, p.practice_name, p.requirement_name),
               p.obligation_label
    OFFSET @offset ROWS FETCH NEXT @size ROWS ONLY;
END;
GO
PRINT '344: sp_event_driven_checklist_list created.';
GO

-- =====================================================================
-- 2. sp_event_checklist_mapped_profiles_list -- View Mapped Profiles
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_mapped_profiles_list
    @organization_id              BIGINT,
    @event_type_id                BIGINT,
    @obligation_id                BIGINT = NULL,
    @local_practice_obligation_id BIGINT = NULL,
    @local_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @event_type_id IS NULL
        THROW 67471, 'sp_event_checklist_mapped_profiles_list: organization_id and event_type_id are required.', 1;

    IF (CASE WHEN @obligation_id                 IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN @local_practice_obligation_id   IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN @local_instance_obligation_id   IS NOT NULL THEN 1 ELSE 0 END) <> 1
        THROW 67472, 'sp_event_checklist_mapped_profiles_list: name exactly one of obligation_id, local_practice_obligation_id or local_instance_obligation_id.', 1;

    SELECT p.profile_id      AS ProfileId,
           p.profile_code    AS ProfileCode,
           p.profile_name    AS ProfileName,
           p.description     AS Description,
           p.status          AS Status,

           -- Copied verbatim from sp_event_profile_list (330) -- a
           -- profile's criteria read identically whichever screen names
           -- it.
           STUFF((
               SELECT N' | ' + d.dimension_name + N': '
                      + CASE WHEN c.match_all = 1 THEN N'All'
                             ELSE ISNULL(STUFF((
                                     SELECT N', ' + ISNULL(v.value_label,
                                                ISNULL(v.value_text, CAST(v.value_id AS NVARCHAR(20))))
                                     FROM   grac_practice.event_profile_criteria_value v
                                     WHERE  v.criteria_id = c.criteria_id
                                     ORDER BY v.criteria_value_id
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''),
                                  N'(none)')
                        END
               FROM   grac_practice.event_profile_criteria c
               JOIN   grac_practice.event_profile_dimension_master d
                      ON d.dimension_id = c.dimension_id
               WHERE  c.profile_id = p.profile_id
               ORDER BY d.display_order, d.dimension_id
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N'')
                             AS CriteriaSummary,

           a.applicability_id AS ApplicabilityId,
           a.due_days         AS DueDays,
           a.owner_role_id    AS OwnerRoleId,
           r.role_name        AS OwnerRoleName
    FROM       grac_practice.event_obligation_applicability a
    JOIN       grac_practice.event_profile p
           ON  p.profile_id      = a.profile_id
          AND  p.organization_id = a.organization_id
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = a.owner_role_id
    WHERE      a.organization_id       = @organization_id
      AND      a.event_type_id         = @event_type_id
      AND      a.scope_dimension       = N'PROFILE'
      AND      a.status                = N'Active'
      -- "Will receive" -- an Excluded decision means this profile will
      -- NOT get the checklist, so it is not "mapped to" it here.
      AND      a.is_applicable         = 1
      AND      ISNULL(a.obligation_id,-1)                = ISNULL(@obligation_id,-1)
      AND      ISNULL(a.local_practice_obligation_id,-1) = ISNULL(@local_practice_obligation_id,-1)
      AND      ISNULL(a.local_instance_obligation_id,-1) = ISNULL(@local_instance_obligation_id,-1)
    ORDER BY   p.profile_name;
END;
GO
PRINT '344: sp_event_checklist_mapped_profiles_list created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 344 verification ===';

SELECT '344-a sp_event_driven_checklist_list' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_driven_checklist_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '344-b sp_event_checklist_mapped_profiles_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_checklist_mapped_profiles_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '344-c checklist_list projects ObligationKind + Practice Instance display',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_driven_checklist_list','P'))
                 LIKE '%AS PracticeInstanceDisplay%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '344-d mapped_profiles_list validates exactly-one-identity',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_checklist_mapped_profiles_list','P'))
                 LIKE '%67472%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: a practice-level or catalog checklist (no genuine
-- instance) must fall back to the Practice for its display column, not a
-- NULL or blank cell -- checked against the procedure's own text, since a
-- stored procedure's result set cannot be queried like a table or view in
-- a static SELECT.
SELECT '344-e non-instance checklists fall back to Practice, then Requirement, for the display column',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_driven_checklist_list','P'))
                 LIKE '%COALESCE(pi.instance_name, p.practice_name, p.requirement_name,%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '344-f mapped_profiles_list excludes non-Included decisions',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_checklist_mapped_profiles_list','P'))
                 LIKE '%a.is_applicable         = 1%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '344 complete. The last SQL migration in this plan -- 340 through 344';
PRINT 'give organisation-authored obligations everywhere a catalog';
PRINT 'obligation already had: a declared event, an applicability';
PRINT 'decision, a place in the event-driven view, composite-identity-aware';
PRINT 'configuration and raising, and now their own list and reverse-lookup';
PRINT 'reads. Next: the Checklists tab UI (event-profiles.cshtml/js) and';
PRINT 'the Configure-Checklists editor''s custom-obligation section.';
GO

SET NOEXEC OFF;
GO
