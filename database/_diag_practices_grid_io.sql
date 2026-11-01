-- _diag_practices_grid_io.sql  (READ-ONLY diagnostic; run in SSMS against the UAT DB)
-- Reproduces the EXACT Practices grid query (organization-requirements/query)
-- with SET STATISTICS IO/TIME ON so the Messages tab shows PER-TABLE logical
-- reads -- that names the table actually eating the ~122K reads, instead of
-- guessing. Extracted straight from PracticeRepositoryService.cs so it cannot
-- drift from the running query. Auto-picks the worst-case org (most
-- requirements); hard-set @organization_id / @release_id / @organization_control_id
-- to reproduce a specific page.
SET NOCOUNT ON;
-- STATISTICS PROFILE returns a PER-OPERATOR RESULT GRID (columns Rows, Executes,
-- StmtText, PhysicalOp, Argument). Copy THAT grid -- the operator with a huge
-- Executes count on a given table is the one eating the reads.
SET STATISTICS PROFILE ON; SET STATISTICS TIME ON;

DECLARE @p_id int = 0;                 -- 0 = grid mode (scope gate ACTIVE)
DECLARE @organization_id int = 3;  -- worst-case org (404 reqs), confirmed
DECLARE @organization_control_id int = NULL;
DECLARE @release_id int = NULL;
DECLARE @framework_statement_id int = NULL;
DECLARE @p_status nvarchar(100) = N'';
DECLARE @origin_type nvarchar(100) = NULL;
DECLARE @date_from datetime = NULL;
DECLARE @date_to datetime = NULL;
DECLARE @p_search nvarchar(400) = N'';
DECLARE @offset int = 0;
DECLARE @page_size int = 25;


            ;WITH requirement_statement AS (
                SELECT
                    q.organization_requirement_id OrganizationRequirementId,
                    n.structure_node_id SourceStructureNodeId,
                    n.parent_node_id ParentSourceStructureNodeId,
                    n.node_level SourceStructureLevel,
                    n.node_reference SourceStructureReference,
                    n.node_title SourceStructureTitle,
                    n.display_order SourceStructureDisplayOrder,
                    ofs.framework_statement_id FrameworkStatementId,
                    ofs.statement_reference FrameworkStatementReference,
                    ofs.statement_title FrameworkStatementTitle,
                    ofs.display_order FrameworkStatementDisplayOrder,
                    ofs.statement_text FrameworkStatementText
                -- 393: statement and structure from the organization's copy.
                FROM grac_practice.organization_requirement q
                JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=q.org_statement_id
                    AND ofs.organization_id=q.organization_id
                    AND ofs.status='Active'
                    AND ofs.copied_dt IS NOT NULL
                JOIN grac_practice.organization_statement_structure_node n ON n.organization_id=ofs.organization_id
                    AND n.structure_node_id=ofs.structure_node_id
                    AND n.status='Active'
            )
            SELECT
                q.organization_requirement_id Id,
                q.organization_id OrganizationId,
                q.origin_type OriginType,
                q.repository_requirement_id RepositoryRequirementId,
                q.org_statement_id OrgStatementId,
                COALESCE(filter_oc.organization_control_id,q.organization_control_id) OrganizationControlId,
                COALESCE(filter_oc.control_code,oc.control_code,ofs.statement_reference) ControlCode,
                COALESCE(filter_oc.control_name,oc.control_name,ofs.statement_title) ControlName,
                COALESCE(
                    CONCAT(filter_oc.control_code,N' - ',filter_oc.control_name),
                    CONCAT(oc.control_code,N' - ',oc.control_name),
                    CONCAT(ofs.statement_reference,N' - ',ofs.statement_title)
                ) MappedControl,
                COALESCE(ofs.release_id,filter_oc.release_id,oc.release_id) ReleaseId,
                COALESCE(r.artifact_id,filter_oc.artifact_id,oc.artifact_id) ArtifactId,
                q.requirement_code Code,
                q.requirement_name Name,
                q.requirement_statement Statement,
                q.objective Objective,
                rsmap.SourceStructureNodeId,
                rsmap.ParentSourceStructureNodeId,
                rsmap.SourceStructureLevel,
                rsmap.SourceStructureReference,
                rsmap.SourceStructureTitle,
                rsmap.SourceStructureDisplayOrder,
                rsmap.FrameworkStatementId,
                rsmap.FrameworkStatementReference,
                rsmap.FrameworkStatementTitle,
                rsmap.FrameworkStatementDisplayOrder,
                rsmap.FrameworkStatementText,
                COALESCE(aps.status_name,q.applicability_status) ApplicabilityStatus,
                COALESCE(aps.status_code,q.applicability_status) ApplicabilityStatusCode,
                COALESCE(ims.status_name,q.implementation_status) ImplementationStatus,
                -- Practice-level implementation roll-up, shown as the grid's
                -- "Implementation Status" column.
                --
                -- DELIBERATELY NOT named ImplementationStatus. That column is
                -- the value STORED on organization_requirement, and the
                -- Practices edit form carries it as a hidden field that posts
                -- back on save (practice.js: hidden("implementationStatus")).
                -- Overwriting it with a derived value would write the roll-up
                -- into q.implementation_status the first time anyone edited a
                -- Practice. The Source Statement page has no such conflict --
                -- a statement stores no implementation status at all -- which
                -- is why it can call its derived column ImplementationStatus.
                --
                -- Same rule and same four values as the statement column in
                -- QueryReleaseStatementsAsync, one level down: Implemented only
                -- when the Practice has instances and EVERY one of them is
                -- Implemented, so a single unfinished instance holds the whole
                -- Practice back. A Practice with no instances has nothing
                -- Implemented and falls through to Not Implemented.
                CASE
                    WHEN COALESCE(aps.status_name,q.applicability_status,N'Not Updated')=N'Applicable'
                         AND COALESCE(pic.PracticeInstanceCount,0)>0
                         AND pic.PracticeInstanceCount=pic.ImplementedInstanceCount THEN N'Implemented'
                    WHEN COALESCE(aps.status_name,q.applicability_status,N'Not Updated')=N'Applicable'
                         AND COALESCE(pic.ImplementedInstanceCount,0)>0 THEN N'Partially Implemented'
                    WHEN COALESCE(aps.status_name,q.applicability_status,N'Not Updated') IN (N'Not Applicable',N'Deferred',N'Accepted Risk',N'Not Implemented',N'Retired') THEN N'Not Applicable'
                    ELSE N'Not Implemented'
                END PracticeImplementationStatus,
                COALESCE(owner.employee_name,p.practice_owner,N'') PracticeOwner,
                -- Added so Update Applicability opens pre-filled: the requirement's
                -- own exclusion_justification is authoritative (pm_manage_practice_repository
                -- writes it to both q and its linked practice p on every save), so
                -- selecting it directly here removes the need for a second round trip.
                -- PracticeId is exposed too -- practice.js's prefill fallback (openForm,
                -- "Update Applicability prefill for Practices") reads it to fetch the
                -- linked practice row, and previously always found it blank because this
                -- query never selected it, so that fallback silently never ran.
                p.practice_id PracticeId,
                COALESCE(q.exclusion_justification,p.exclusion_justification) ExclusionJustification,
                COALESCE(pic.PracticeInstanceCount,0) PracticeInstanceCount,
                COALESCE(pic.ImplementedInstanceCount,0) ImplementedInstanceCount,
                COALESCE(rs.status_name,q.status) Status,COUNT(*) OVER () AS TotalRows
            INTO #grid_sink
            FROM grac_practice.organization_requirement q
            LEFT JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=q.org_statement_id
                AND ofs.organization_id=q.organization_id
            LEFT JOIN grac_new.release r ON r.release_id=ofs.release_id
            LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id=q.organization_control_id
            -- Migration 057 introduced grac_practice.organization_control_requirement to
            -- carry the many-to-many mapping between Controls and Practices. When two
            -- Applicable Controls share the same repository requirement, the second one
            -- reuses the existing Practice (dedup) and only a mapping row is added -- the
            -- Practice's primary organization_control_id still points at the *first*
            -- Applicable Control. filter_oc lets the drilled-in control drive the
            -- displayed ControlCode/ControlName/MappedControl/ReleaseId/ArtifactId
            -- when the caller filters by @organization_control_id and the Practice is
            -- reached through a mapping row instead of the primary column.
            LEFT JOIN grac_practice.organization_control filter_oc
                ON @organization_control_id IS NOT NULL
                AND filter_oc.organization_control_id=@organization_control_id
                AND filter_oc.organization_id=q.organization_id
                AND (
                    q.organization_control_id=@organization_control_id
                    OR EXISTS(
                        SELECT 1
                        FROM grac_practice.organization_control_requirement m
                        WHERE m.organization_requirement_id=q.organization_requirement_id
                          AND m.organization_control_id=@organization_control_id
                          AND m.status='Active')
                )
            LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=q.record_status_id
            LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
            LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id=q.implementation_status_id
            LEFT JOIN requirement_statement rsmap ON rsmap.OrganizationRequirementId=q.organization_requirement_id
            OUTER APPLY (
                SELECT TOP (1) p.practice_id,p.practice_owner_id,p.practice_owner,p.exclusion_justification
                FROM grac_practice.practice p
                WHERE p.organization_requirement_id=q.organization_requirement_id
                  AND p.organization_id=q.organization_id
                  AND p.status='Active'
                ORDER BY CASE WHEN p.practice_owner_id IS NULL AND NULLIF(p.practice_owner,N'') IS NULL THEN 1 ELSE 0 END,p.practice_id
            ) p
            OUTER APPLY (
                -- practice_instance links to the requirement through practice;
                -- it has no organization_requirement_id column of its own.
                --
                -- ImplementedInstanceCount rides along here rather than in a
                -- second apply: the implementation roll-up walks exactly the
                -- same two joins as the count, so asking twice would scan the
                -- instances twice for one row of grid.
                SELECT COUNT_BIG(1) PracticeInstanceCount,
                       COUNT_BIG(CASE WHEN ism_pi.status_code=N'Implemented' THEN 1 END) ImplementedInstanceCount
                FROM grac_practice.practice_instance pi
                JOIN grac_practice.practice pp ON pp.practice_id=pi.practice_id
                LEFT JOIN grac_practice.implementation_status_master ism_pi
                    ON ism_pi.implementation_status_id=pi.implementation_status_id
                WHERE pp.organization_requirement_id=q.organization_requirement_id
                  AND pi.organization_id=q.organization_id
                  AND pi.status='Active'
            ) pic
            LEFT JOIN grac_practice.organization_employee owner ON owner.employee_id=p.practice_owner_id
            -- Custom Practice creation (Add Custom Practice, entity_type
            -- 'organization-requirements', origin_type 'Organization') was
            -- silently missing from this grid. The row itself was always
            -- correctly inserted -- code generated, ORG-PRACTICES container
            -- control created/reused, applicability/owner all saved -- but
            -- a custom practice has no repository framework release behind
            -- it, so ofs.release_id, filter_oc.release_id and oc.release_id
            -- (the ORG-PRACTICES container's release_id) are all NULL for
            -- it. The subscription check below existed to hide a
            -- repository-linked practice whose framework release is no
            -- longer subscribed, but "s.release_id=NULL" can never be TRUE,
            -- so it was also hiding every custom practice, unconditionally,
            -- regardless of organization/status/search filters. Bypass the
            -- subscription check for rows with no release association at
            -- all (custom/organization-origin practices); repository-linked
            -- practices (which always have a release here) still require an
            -- active subscription exactly as before.
            WHERE (
                  COALESCE(ofs.release_id,filter_oc.release_id,oc.release_id) IS NULL
                  OR EXISTS(
                      SELECT 1
                      FROM grac_practice.repository_subscription s
                      WHERE s.organization_id=q.organization_id
                        AND s.release_id=COALESCE(ofs.release_id,filter_oc.release_id,oc.release_id)
                        AND s.status='Active'
                        AND ISNULL(s.subscription_status,'Active')='Active'
                  )
              )
              AND (@p_id=0 OR q.organization_requirement_id=@p_id)
              AND (@organization_id IS NULL OR q.organization_id=@organization_id)
              -- 2026-09-28: the Practices grid lists a statement-linked practice
              -- only when one of its statements is Applicable under a release
              -- with an owner (see PracticeStatementScopeSql). A single-record
              -- read (@p_id) is not filtered, so an open form still loads.
              AND (@p_id<>0 OR 
        (
            ISNULL(q.origin_type,N'')<>N'Repository'
            OR (q.org_statement_id IS NULL
                AND NOT EXISTS(
                    SELECT 1 FROM grac_practice.organization_statement_practice_mapping lm
                    WHERE lm.org_practice_id=q.organization_requirement_id
                      AND lm.organization_id=q.organization_id
                      AND lm.status='Active'))
            OR EXISTS(
                SELECT 1
                FROM grac_practice.organization_framework_statements sofs
                JOIN grac_practice.applicability_status_master saps
                    ON saps.applicability_status_id=sofs.applicability_status_id
                   AND saps.status_name=N'Applicable'
                WHERE sofs.organization_id=q.organization_id
                  AND sofs.status='Active'
                  AND (sofs.org_statement_id=q.org_statement_id
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.organization_statement_practice_mapping sm
                           WHERE sm.org_practice_id=q.organization_requirement_id
                             AND sm.organization_id=q.organization_id
                             AND sm.org_statement_id=sofs.org_statement_id
                             AND sm.status='Active'))
                  AND (NOT EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss0
                           WHERE ss0.organization_id=sofs.organization_id
                             AND ss0.release_id=sofs.release_id)
                       OR EXISTS(
                           SELECT 1 FROM grac_practice.repository_subscription ss
                           WHERE ss.organization_id=sofs.organization_id
                             AND ss.release_id=sofs.release_id
                             AND ss.status='Active'
                             AND ISNULL(ss.subscription_status,'Active')='Active'
                             AND ss.owner_id IS NOT NULL)))
        )
        )
              -- Accept the requirement if it is linked to @organization_control_id
              -- either through the legacy "primary" column on organization_requirement
              -- OR through the many-to-many organization_control_requirement mapping
              -- created by migration 057. Without the mapping lookup, a Practice that
              -- was deduped under Control 43's primary key becomes invisible when the
              -- user drills in from Control 16 that shares the same repo requirement.
              AND (@organization_control_id IS NULL
                   OR q.organization_control_id=@organization_control_id
                   OR EXISTS(
                       SELECT 1
                       FROM grac_practice.organization_control_requirement m
                       WHERE m.organization_requirement_id=q.organization_requirement_id
                         AND m.organization_control_id=@organization_control_id
                         AND m.status='Active'))
              AND (@release_id IS NULL OR COALESCE(ofs.release_id,filter_oc.release_id,oc.release_id)=@release_id)
              -- Statement-scoped view: resolve statement membership through
              -- organization_statement_practice_mapping so a practice linked to
              -- multiple applicable statements appears under each of them.
              AND (@framework_statement_id IS NULL
                   OR EXISTS(
                       SELECT 1
                       FROM grac_practice.organization_statement_practice_mapping m
                       WHERE m.org_practice_id=q.organization_requirement_id
                         AND m.organization_id=q.organization_id
                         AND m.framework_statement_id=@framework_statement_id
                         AND m.status='Active')
                   OR ofs.framework_statement_id=@framework_statement_id)
              AND (@p_status='' OR rs.status_code=@p_status OR rs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status OR ims.status_code=@p_status OR ims.status_name=@p_status)
              AND (@origin_type IS NULL OR q.origin_type=@origin_type)
              AND (@date_from IS NULL OR q.entered_dt>=@date_from)
              AND (@date_to IS NULL OR q.entered_dt<DATEADD(DAY,1,@date_to))
              AND (@p_search='' OR ISNULL(q.requirement_code,'') LIKE '%'+@p_search+'%' OR ISNULL(q.requirement_name,'') LIKE '%'+@p_search+'%' OR ISNULL(filter_oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(filter_oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(ofs.statement_reference,'') LIKE '%'+@p_search+'%' OR ISNULL(ofs.statement_title,'') LIKE '%'+@p_search+'%')
            ORDER BY COALESCE(rsmap.SourceStructureDisplayOrder,2147483647),COALESCE(rsmap.FrameworkStatementDisplayOrder,2147483647),COALESCE(ofs.statement_reference,filter_oc.control_code,oc.control_code),q.requirement_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            