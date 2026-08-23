-- =====================================================================
-- 137 List obligations before the scope value exists
--
-- WHY
-- ---
-- The Role Master form is supposed to configure event checklists in Add
-- as well as Edit. It could not: sp_event_obligation_mapping_list refused
-- to run without a scope value (THROW 67302 / 67303), and a role being
-- added has no id yet. So Add showed a placeholder and Edit showed the
-- list -- exactly the inconsistency reported.
--
-- The refusal was wrong on its own terms. WHICH obligations reach an
-- organization for an event depends on the organization, the event and the
-- subscribed releases. The scope value decides only whether each one is
-- TICKED. So the list is perfectly well defined without it, and every row
-- simply comes back Unmapped -- which is the truth for a role that does
-- not exist yet.
--
-- Listing only. sp_event_obligation_applicability_save still demands a
-- scope value, because a decision genuinely cannot be recorded against
-- nothing. The form buffers what the user ticks while adding and writes it
-- once the record has an id.
--
-- Nothing else changes: same parameters, same result columns, same order.
--
-- Depends on 129 (the de-duplicated body this is based on).
-- Rollback: 137_obligation_list_without_scope_value_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    RAISERROR('137: run 127 and 129 first.', 16, 1);
    RETURN;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_mapping_list
    @organization_id         BIGINT,
    @event_type_id           BIGINT       = NULL,
    @event_type_code         NVARCHAR(60) = NULL,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT       = NULL,
    @scope_asset_category_id INT          = NULL,
    @include_unsubscribed    BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67300, 'sp_event_obligation_mapping_list: organization_id is required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 67301, 'sp_event_obligation_mapping_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;

    -- 137: the scope value is optional here. A NULL simply matches no
    -- applicability row, so every obligation returns as Unmapped -- which is
    -- what a record that does not exist yet actually has.

    ;WITH v AS (
        SELECT *
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  (@event_type_id   IS NULL OR event_type_id   = @event_type_id)
          AND  (@event_type_code IS NULL OR event_type_code = @event_type_code)
    ),
    agg AS (
        SELECT obligation_id, event_type_id,
               MAX(CAST(is_subscribed AS INT))             AS any_subscribed,
               COUNT(DISTINCT organization_requirement_id) AS requirement_paths,
               COUNT(DISTINCT practice_id)                 AS practice_count
        FROM   v
        GROUP BY obligation_id, event_type_id
    ),
    codes AS (
        SELECT DISTINCT obligation_id, event_type_id, practice_code
        FROM   v WHERE practice_code IS NOT NULL
    ),
    code_agg AS (
        SELECT obligation_id, event_type_id,
               STRING_AGG(practice_code, N', ') WITHIN GROUP (ORDER BY practice_code) AS practice_codes
        FROM   codes GROUP BY obligation_id, event_type_id
    ),
    pick AS (
        SELECT v.*,
               ROW_NUMBER() OVER (
                   PARTITION BY v.obligation_id, v.event_type_id
                   ORDER BY v.is_subscribed DESC,
                            CASE WHEN v.PracticeApplicability    = N'Applicable' THEN 0 ELSE 1 END,
                            CASE WHEN v.RequirementApplicability = N'Applicable' THEN 0 ELSE 1 END,
                            v.practice_id, v.organization_requirement_id) AS rn
        FROM v
    )
    SELECT
        p.obligation_id                     AS ObligationId,
        p.obligation_label                  AS ObligationLabel,
        p.obligation_text                   AS ObligationText,
        p.practice_id                       AS PracticeId,
        COALESCE(ca.practice_codes, p.practice_code) AS PracticeCode,
        p.practice_name                     AS PracticeName,
        p.requirement_code                  AS RequirementCode,
        p.requirement_name                  AS RequirementName,
        p.event_type_id                     AS EventTypeId,
        p.event_type_code                   AS EventTypeCode,
        p.event_type_name                   AS EventTypeName,
        p.subject_entity                    AS SubjectEntity,
        p.release_id                        AS ReleaseId,
        CAST(a.any_subscribed AS BIT)       AS IsSubscribed,
        p.PracticeApplicability             AS PracticeApplicability,
        p.RequirementApplicability          AS RequirementApplicability,

        ap.applicability_id                 AS ApplicabilityId,
        ap.is_applicable                    AS IsApplicable,
        ap.rationale                        AS Rationale,
        ap.owner_role_id                    AS OwnerRoleId,
        r.role_name                         AS OwnerRoleName,
        ap.due_days                         AS DueDays,
        ap.status                           AS MappingStatus,

        CASE
            WHEN ap.applicability_id IS NULL THEN N'Unmapped'
            WHEN ap.status <> N'Active'      THEN N'Inactive'
            WHEN ap.is_applicable = 0        THEN N'NotApplicable'
            ELSE N'Mapped'
        END                                 AS MappingState
    FROM       pick p
    JOIN       agg a
           ON  a.obligation_id = p.obligation_id AND a.event_type_id = p.event_type_id
    LEFT JOIN  code_agg ca
           ON  ca.obligation_id = p.obligation_id AND ca.event_type_id = p.event_type_id
    LEFT JOIN  grac_practice.event_obligation_applicability ap
           ON  ap.organization_id = @organization_id
          AND  ap.obligation_id   = p.obligation_id
          AND  ap.event_type_id   = p.event_type_id
          AND  (   (@scope_dimension = N'ORG_ROLE'       AND @scope_role_id           IS NOT NULL
                        AND ap.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND @scope_asset_category_id IS NOT NULL
                        AND ap.scope_asset_category_id = @scope_asset_category_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = ap.owner_role_id
    WHERE      p.rn = 1
      AND      (@include_unsubscribed = 1 OR a.any_subscribed = 1)
    ORDER BY   p.event_type_code, COALESCE(ca.practice_codes, p.practice_code), p.obligation_id;
END;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_event_obligation_mapping_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'lists without a scope value' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_mapping_list'))
                 NOT LIKE '%THROW 67302%'
            THEN 'PASS' ELSE 'FAIL -- still refuses a NULL scope value' END AS Result;

PRINT '137 Obligation list no longer requires a scope value.';
PRINT 'Saving a decision still does -- sp_event_obligation_applicability_save is unchanged.';
GO
