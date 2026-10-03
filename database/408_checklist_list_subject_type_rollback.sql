-- =====================================================================
-- Rollback for 408_checklist_list_subject_type.sql
-- Restores sp_event_driven_checklist_list to its 344 body (verbatim).
-- =====================================================================
SET NOCOUNT ON;
GO

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
PRINT '408_checklist_list_subject_type rolled back (344 body restored).';
GO
