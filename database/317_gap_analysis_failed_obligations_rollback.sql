-- =====================================================================
-- 317 rollback -- restore sp_custom_gap_linked_artefacts to its
-- pre-317 (174) body: Task / Exception / Risk only, no
-- FailedObligations result set.
--
-- Does NOT drop the proc (174 still depends on it existing) and does
-- NOT touch practice_gap / practice_gap_obligation / custom_gap -- 317
-- added no schema and no data, only a fourth SELECT in an existing
-- proc, so rollback is restoring that proc's prior body, verbatim.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_linked_artefacts
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55510, 'sp_custom_gap_linked_artefacts: custom_gap_id is required.', 1;

    -- Task
    SELECT TOP 1
        N'Task'                     AS ArtefactType,
        t.task_id                   AS ArtefactId,
        t.subject_title             AS Title,
        s.status_code               AS StatusCode
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.subject_entity_type = N'CustomGap'
       AND t.subject_entity_id   = @custom_gap_id
     ORDER BY t.task_id DESC;

    -- Exception
    SELECT TOP 1
        N'Exception'                AS ArtefactType,
        e.exception_request_id      AS ArtefactId,
        e.request_title             AS Title,
        e.status_code               AS StatusCode
      FROM grac_practice.exception_request e
     WHERE e.custom_gap_id = @custom_gap_id
     ORDER BY e.exception_request_id DESC;

    -- Risk
    SELECT TOP 1
        N'RiskCandidate'            AS ArtefactType,
        r.risk_candidate_id         AS ArtefactId,
        r.candidate_title           AS Title,
        r.status_code               AS StatusCode
      FROM grac_practice.risk_candidate r
     WHERE r.custom_gap_id = @custom_gap_id
     ORDER BY r.risk_candidate_id DESC;
END
GO
PRINT '317 rollback: sp_custom_gap_linked_artefacts restored to 174 body (no FailedObligations).';
GO
