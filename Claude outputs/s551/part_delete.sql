-- sp_org_assurance_question_set_delete (077, rewritten by 551)
--   A Draft version after the first (v2+) is DISCARDED: that version and
--   its questions go, the set's other versions stay. Otherwise the whole
--   set (every version) is removed -- only when no audit definition uses
--   any of its versions (53846).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_delete
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @def_org BIGINT, @root BIGINT, @vno INT, @vs NVARCHAR(20);
    SELECT @def_org = organization_id, @root = root_question_set_id,
           @vno = version_number, @vs = version_status
    FROM grac_practice.org_assurance_question_set
    WHERE org_assurance_question_set_id = @question_set_id
      AND is_active = 1;

    IF @def_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @def_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @targets TABLE (id BIGINT NOT NULL PRIMARY KEY);
    IF @vs = N'Draft' AND @vno > 1
        INSERT INTO @targets (id) VALUES (@question_set_id);
    ELSE
    BEGIN
        IF EXISTS (SELECT 1
                     FROM grac_practice.org_assurance_definition_question_set dq
                     JOIN grac_practice.org_assurance_question_set qs
                          ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
                    WHERE qs.root_question_set_id = @root
                      AND dq.is_active = 1)
            THROW 53846, 'This question set is used by audit definitions and cannot be deleted.', 1;
        INSERT INTO @targets (id)
        SELECT org_assurance_question_set_id FROM grac_practice.org_assurance_question_set
         WHERE root_question_set_id = @root AND is_active = 1;
    END

    BEGIN TRAN;

    UPDATE q
    SET is_active  = 0,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.org_assurance_question q
    JOIN @targets t ON t.id = q.org_assurance_question_set_id
    WHERE q.is_active = 1;

    UPDATE qs
    SET is_active  = 0,
        status     = N'Inactive',
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.org_assurance_question_set qs
    JOIN @targets t ON t.id = qs.org_assurance_question_set_id;

    COMMIT;
END
GO
