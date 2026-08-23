-- =====================================================================
-- 167 Practice lookup proc -- feeds the Linked Practice combo on the
-- Exception Centre approve modal (and any other UI that needs an
-- org-scoped picker of practices). Single-purpose, cheap read.
--
-- Rollback: 167_practice_lookup_proc_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_organization_practice_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55300, 'sp_organization_practice_list: organization_id is required.', 1;

    SELECT
        p.practice_id           AS PracticeId,
        p.practice_code         AS PracticeCode,
        p.practice_name         AS PracticeName,
        p.applicability_status  AS ApplicabilityStatus,
        p.practice_owner        AS PracticeOwner
      FROM grac_practice.practice p
     WHERE p.organization_id = @organization_id
     ORDER BY p.practice_code, p.practice_name;
END
GO

PRINT '167 sp_organization_practice_list ready.';
GO
