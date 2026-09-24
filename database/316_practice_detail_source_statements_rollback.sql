-- =====================================================================
-- 316_practice_detail_source_statements_rollback.sql
--
-- Restores grac_practice.sp_practice_detail_get to its migration-303
-- shape: drops MappedSourceStatementsJson, character for character back
-- to 303's body. ADDITIVE-ONLY rollback -- no schema, no data change.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NULL
BEGIN
    PRINT 'ABORT (316 rollback): sp_practice_detail_get missing.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_detail_get
    @practice_id                BIGINT = NULL,
    @organization_id            BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
        SELECT TOP 1 @practice_id = practice_id
        FROM   grac_practice.practice
        WHERE  organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR organization_id = @organization_id)
        ORDER  BY CASE WHEN status = N'Active' THEN 0 ELSE 1 END, practice_id;

    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1
                       FROM   grac_practice.organization_requirement
                       WHERE  organization_requirement_id = @organization_requirement_id
                         AND (@organization_id IS NULL OR organization_id = @organization_id))
            THROW 52512, 'sp_practice_detail_get: requirement not found for this organization.', 1;

        SELECT
            CAST(0 AS BIGINT)                 AS PracticeId,
            q.organization_id                 AS OrganizationId,
            o.organization_name               AS OrganizationName,
            q.requirement_code                AS PracticeCode,
            q.requirement_name                AS PracticeName,
            q.requirement_statement           AS Description,
            q.origin_type                     AS OriginType,
            CAST(NULL AS NVARCHAR(200))       AS PracticeOwner,
            CAST(NULL AS BIGINT)              AS PracticeOwnerId,
            COALESCE(aps.status_name, q.applicability_status) AS ApplicabilityStatus,
            q.exclusion_justification         AS ExclusionJustification,
            COALESCE(rs.status_name, q.status) AS Status,
            q.organization_requirement_id     AS OrganizationRequirementId,
            q.requirement_code                AS RequirementCode,
            q.requirement_name                AS RequirementName,
            CAST(0 AS INT)                    AS ActiveInstanceCount,
        CASE
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.InstanceCount, 0) > 0
                 AND impl.InstanceCount = impl.ImplementedInstanceCount THEN N'Implemented'
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.ImplementedInstanceCount, 0) > 0 THEN N'Partially Implemented'
            WHEN COALESCE(aps.status_name, q.applicability_status, N'Not Updated') IN (N'Not Applicable', N'Deferred', N'Accepted Risk', N'Not Implemented', N'Retired')
                 THEN N'Not Applicable'
            ELSE N'Not Implemented'
        END                               AS PracticeImplementationStatus,

        COALESCE((
            SELECT   f.ReleaseId, f.FrameworkRelease
            FROM (
                SELECT DISTINCT
                       r.release_id AS ReleaseId,
                       COALESCE(a.artifact_code + N' ' + r.version_no,
                                a.artifact_name + N' ' + r.version_no,
                                r.version_no) AS FrameworkRelease
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs2
                       ON ofs2.org_statement_id = m.org_statement_id
                JOIN   GRAC_New.release r
                       ON r.release_id = COALESCE(m.release_id, ofs2.release_id)
                LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
                WHERE  m.org_practice_id = q.organization_requirement_id
                  AND  m.status = N'Active'
                UNION
                SELECT DISTINCT
                       r2.release_id,
                       COALESCE(a2.artifact_code + N' ' + r2.version_no,
                                a2.artifact_name + N' ' + r2.version_no,
                                r2.version_no)
                FROM   grac_practice.organization_requirement q2
                JOIN   grac_practice.organization_control oc2
                       ON oc2.organization_control_id = q2.organization_control_id
                JOIN   GRAC_New.release r2 ON r2.release_id = oc2.release_id
                LEFT   JOIN GRAC_New.artifact a2 ON a2.artifact_id = r2.artifact_id
                WHERE  q2.organization_requirement_id = q.organization_requirement_id
                  AND  NOT EXISTS (SELECT 1
                                   FROM   grac_practice.organization_statement_practice_mapping m2
                                   WHERE  m2.org_practice_id = q.organization_requirement_id
                                     AND  m2.status = N'Active')
            ) f
            ORDER BY f.FrameworkRelease
            FOR JSON PATH
        ), N'[]')                         AS MappedFrameworksJson
        FROM   grac_practice.organization_requirement q
        JOIN   grac_practice.organization o
               ON o.organization_id = q.organization_id
        OUTER APPLY (
            SELECT COUNT_BIG(1) AS InstanceCount,
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount
            FROM   grac_practice.practice_instance pi_impl
            JOIN   grac_practice.practice pp_impl ON pp_impl.practice_id = pi_impl.practice_id
            LEFT   JOIN grac_practice.implementation_status_master ism_pi
                   ON ism_pi.implementation_status_id = pi_impl.implementation_status_id
            WHERE  pp_impl.organization_requirement_id = q.organization_requirement_id
              AND  pi_impl.organization_id = q.organization_id
              AND  pi_impl.status = N'Active'
        ) impl
        LEFT   JOIN grac_practice.applicability_status_master aps
               ON aps.applicability_status_id = q.applicability_status_id
        LEFT   JOIN grac_practice.record_status_master rs
               ON rs.record_status_id = q.record_status_id
        WHERE  q.organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR q.organization_id = @organization_id);

        RETURN;
    END

    IF @practice_id IS NULL
        THROW 52500, 'sp_practice_detail_get: no practice found. Supply practice_id, or an organization_requirement_id that has a practice.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice
                    WHERE practice_id = @practice_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52501, 'sp_practice_detail_get: practice not found for this organization.', 1;

    SELECT
        p.practice_id                    AS PracticeId,
        p.organization_id                AS OrganizationId,
        o.organization_name              AS OrganizationName,
        p.practice_code                  AS PracticeCode,
        p.practice_name                  AS PracticeName,
        p.description                    AS Description,
        p.origin_type                    AS OriginType,
        p.practice_owner                 AS PracticeOwner,
        p.practice_owner_id              AS PracticeOwnerId,
        p.applicability_status           AS ApplicabilityStatus,
        p.exclusion_justification        AS ExclusionJustification,
        p.status                         AS Status,
        p.organization_requirement_id    AS OrganizationRequirementId,
        req.requirement_code             AS RequirementCode,
        req.requirement_name             AS RequirementName,
        (SELECT COUNT(*)
         FROM   grac_practice.practice_instance pi
         WHERE  pi.practice_id = p.practice_id
           AND  pi.status = N'Active')   AS ActiveInstanceCount,
        CASE
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.InstanceCount, 0) > 0
                 AND impl.InstanceCount = impl.ImplementedInstanceCount THEN N'Implemented'
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') = N'Applicable'
                 AND COALESCE(impl.ImplementedInstanceCount, 0) > 0 THEN N'Partially Implemented'
            WHEN COALESCE(req_aps.status_name, req.applicability_status, N'Not Updated') IN (N'Not Applicable', N'Deferred', N'Accepted Risk', N'Not Implemented', N'Retired')
                 THEN N'Not Applicable'
            ELSE N'Not Implemented'
        END                               AS PracticeImplementationStatus,

        COALESCE((
            SELECT   f.ReleaseId, f.FrameworkRelease
            FROM (
                SELECT DISTINCT
                       r.release_id AS ReleaseId,
                       COALESCE(a.artifact_code + N' ' + r.version_no,
                                a.artifact_name + N' ' + r.version_no,
                                r.version_no) AS FrameworkRelease
                FROM   grac_practice.organization_statement_practice_mapping m
                LEFT   JOIN grac_practice.organization_framework_statements ofs2
                       ON ofs2.org_statement_id = m.org_statement_id
                JOIN   GRAC_New.release r
                       ON r.release_id = COALESCE(m.release_id, ofs2.release_id)
                LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
                WHERE  m.org_practice_id = p.organization_requirement_id
                  AND  m.status = N'Active'
                UNION
                SELECT DISTINCT
                       r2.release_id,
                       COALESCE(a2.artifact_code + N' ' + r2.version_no,
                                a2.artifact_name + N' ' + r2.version_no,
                                r2.version_no)
                FROM   grac_practice.organization_requirement q2
                JOIN   grac_practice.organization_control oc2
                       ON oc2.organization_control_id = q2.organization_control_id
                JOIN   GRAC_New.release r2 ON r2.release_id = oc2.release_id
                LEFT   JOIN GRAC_New.artifact a2 ON a2.artifact_id = r2.artifact_id
                WHERE  q2.organization_requirement_id = p.organization_requirement_id
                  AND  NOT EXISTS (SELECT 1
                                   FROM   grac_practice.organization_statement_practice_mapping m2
                                   WHERE  m2.org_practice_id = p.organization_requirement_id
                                     AND  m2.status = N'Active')
            ) f
            ORDER BY f.FrameworkRelease
            FOR JSON PATH
        ), N'[]')                         AS MappedFrameworksJson
    FROM   grac_practice.practice p
    JOIN   grac_practice.organization o
           ON o.organization_id = p.organization_id
    LEFT   JOIN grac_practice.organization_requirement req
           ON req.organization_requirement_id = p.organization_requirement_id
    LEFT   JOIN grac_practice.applicability_status_master req_aps
           ON req_aps.applicability_status_id = req.applicability_status_id
    OUTER APPLY (
        SELECT COUNT_BIG(1) AS InstanceCount,
               COUNT_BIG(CASE WHEN ism_pi.status_code = N'Implemented' THEN 1 END) AS ImplementedInstanceCount
        FROM   grac_practice.practice_instance pi_impl
        JOIN   grac_practice.practice pp_impl ON pp_impl.practice_id = pi_impl.practice_id
        LEFT   JOIN grac_practice.implementation_status_master ism_pi
               ON ism_pi.implementation_status_id = pi_impl.implementation_status_id
        WHERE  pp_impl.organization_requirement_id = p.organization_requirement_id
          AND  pi_impl.organization_id = p.organization_id
          AND  pi_impl.status = N'Active'
    ) impl
    WHERE  p.practice_id = @practice_id;
END
GO
SELECT 'sp_practice_detail_get present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

PRINT '316 rollback complete -- sp_practice_detail_get restored to 303 shape.';
GO
