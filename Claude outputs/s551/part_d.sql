-- =====================================================================
-- 4b. Question set versions -- new procedures
-- =====================================================================

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_version_list -- every version of the set
-- that @question_set_id belongs to, newest first.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_version_list
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT = (SELECT root_question_set_id FROM grac_practice.org_assurance_question_set
                             WHERE org_assurance_question_set_id = @question_set_id
                               AND organization_id = @organization_id);
    IF @root IS NULL THROW 53806, 'Question set not found.', 1;

    SELECT qs.org_assurance_question_set_id AS QuestionSetId,
           qs.version_number                AS VersionNumber,
           qs.version_status                AS VersionStatus,
           qs.set_name                      AS SetName,
           qs.change_note                   AS ChangeNote,
           (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_question q
             WHERE q.org_assurance_question_set_id = qs.org_assurance_question_set_id
               AND q.is_active = 1)         AS QuestionCount,
           qs.submitted_by                  AS SubmittedBy,
           qs.submitted_dt                  AS SubmittedDt,
           qs.approved_by                   AS ApprovedBy,
           qs.approved_dt                   AS ApprovedDt,
           qs.entered_by                    AS EnteredBy,
           qs.entered_dt                    AS EnteredDt
      FROM grac_practice.org_assurance_question_set qs
     WHERE qs.root_question_set_id = @root
       AND qs.organization_id = @organization_id
       AND qs.is_active = 1
     ORDER BY qs.version_number DESC;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_new_version -- copy the set's Active
-- version (header + questions) into a Draft with the next number.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_new_version
    @organization_id     BIGINT,
    @question_set_id     BIGINT,
    @actor               NVARCHAR(100) = 'system',
    @question_set_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT, @set_org BIGINT;
    SELECT @root = root_question_set_id, @set_org = organization_id
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;

    DECLARE @open_no INT, @open_status NVARCHAR(20), @msg NVARCHAR(400);
    SELECT TOP 1 @open_no = version_number, @open_status = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE root_question_set_id = @root AND is_active = 1
       AND version_status IN (N'Draft', N'UnderReview')
     ORDER BY version_number DESC;
    IF @open_no IS NOT NULL
    BEGIN
        SET @msg = CONCAT(N'Version ', @open_no, N' of this question set is already ',
                          CASE WHEN @open_status = N'Draft' THEN N'in Draft' ELSE N'Under Review' END,
                          N'. Finish or discard it first.');
        THROW 53841, @msg, 1;
    END

    DECLARE @source BIGINT = (SELECT TOP 1 org_assurance_question_set_id
                                FROM grac_practice.org_assurance_question_set
                               WHERE root_question_set_id = @root AND is_active = 1
                                 AND version_status = N'Active'
                               ORDER BY version_number DESC);
    IF @source IS NULL THROW 53842, 'The question set has no approved (Active) version to copy.', 1;

    DECLARE @next INT = (SELECT MAX(version_number) + 1 FROM grac_practice.org_assurance_question_set
                          WHERE root_question_set_id = @root);

    CREATE TABLE #qs_map (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    BEGIN TRAN;
        EXEC grac_practice.sp_org_assurance_clone_rows
             @table = N'org_assurance_question_set', @key_column = N'org_assurance_question_set_id',
             @where = N'src.org_assurance_question_set_id = @p_source',
             @overrides = N'{"version_number":"@p_number","version_status":"N''Draft''","previous_question_set_id":"@p_source","change_note":"NULL","submitted_by":"NULL","submitted_dt":"NULL","approved_by":"NULL","approved_dt":"NULL"}',
             @map_table = N'#qs_map', @p_source = @source, @p_number = @next, @p_actor = @actor;

        SET @question_set_id_out = (SELECT new_id FROM #qs_map);

        EXEC grac_practice.sp_org_assurance_clone_rows
             @table = N'org_assurance_question', @key_column = N'org_assurance_question_id',
             @where = N'src.org_assurance_question_set_id = @p_source AND src.is_active = 1',
             @overrides = N'{"org_assurance_question_set_id":"@p_set"}',
             @p_source = @source, @p_set = @question_set_id_out, @p_actor = @actor;
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_submit -- Recommend: Draft -> UnderReview.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_submit
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @change_note     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20);
    SELECT @set_org = organization_id, @vs = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'Draft' THROW 53840, 'Only a Draft version can be recommended.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question
                    WHERE org_assurance_question_set_id = @question_set_id
                      AND is_active = 1 AND ISNULL(status, N'Active') = N'Active')
        THROW 53843, 'Add at least one active question before recommending the question set.', 1;

    UPDATE grac_practice.org_assurance_question_set
       SET version_status = N'UnderReview',
           change_note    = COALESCE(NULLIF(LTRIM(RTRIM(@change_note)), N''), change_note),
           submitted_by   = @actor,
           submitted_dt   = SYSUTCDATETIME(),
           updated_by     = @actor,
           updated_dt     = SYSUTCDATETIME()
     WHERE org_assurance_question_set_id = @question_set_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_return -- UnderReview -> Draft.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_return
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @reason          NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20);
    SELECT @set_org = organization_id, @vs = version_status
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'UnderReview' THROW 53844, 'Only a version Under Review can be returned or approved.', 1;

    UPDATE grac_practice.org_assurance_question_set
       SET version_status = N'Draft',
           change_note    = CASE WHEN NULLIF(LTRIM(RTRIM(@reason)), N'') IS NULL THEN change_note
                                 ELSE LEFT(CONCAT(N'Returned: ', @reason, CASE WHEN change_note IS NULL THEN N'' ELSE N' | ' + change_note END), 1000) END,
           updated_by     = @actor,
           updated_dt     = SYSUTCDATETIME()
     WHERE org_assurance_question_set_id = @question_set_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_impact -- the audit definitions whose
-- CURRENT version uses another version of this set, and what approving
-- this version will do to each. Read-only.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_impact
    @organization_id BIGINT,
    @question_set_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @question_set_id IS NULL
        THROW 53802, 'organization_id and question_set_id are required.', 1;

    DECLARE @root BIGINT = (SELECT root_question_set_id FROM grac_practice.org_assurance_question_set
                             WHERE org_assurance_question_set_id = @question_set_id
                               AND organization_id = @organization_id);
    IF @root IS NULL THROW 53806, 'Question set not found.', 1;

    SELECT d.org_assurance_definition_id AS DefinitionId,
           d.definition_code             AS DefinitionCode,
           d.definition_name             AS DefinitionName,
           v.version_number              AS CurrentVersionNumber,
           s.status_code                 AS CurrentStatusCode,
           s.status_name                 AS CurrentStatusName,
           qs.version_number             AS LinkedSetVersion,
           CASE WHEN s.status_code IN (N'Draft', N'UnderReview')
                THEN N'UPDATE_IN_PLACE' ELSE N'NEW_VERSION' END AS ActionCode,
           CASE WHEN s.status_code IN (N'Draft', N'UnderReview')
                THEN N'Its ' + s.status_name + N' version ' + CAST(v.version_number AS NVARCHAR(10))
                     + N' moves to the new question set version.'
                ELSE N'A new Draft version ' + CAST(ISNULL(mx.max_no, 0) + 1 AS NVARCHAR(10))
                     + N' is created for review and approval; version ' + CAST(v.version_number AS NVARCHAR(10))
                     + N' stays Active until then.' END AS ActionText
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
      JOIN grac_practice.org_assurance_definition_version v
           ON v.org_assurance_definition_version_id = d.current_version_id
      JOIN grac_practice.org_assurance_definition_question_set dq
           ON dq.org_assurance_definition_version_id = d.current_version_id
          AND dq.is_active = 1
      JOIN grac_practice.org_assurance_question_set qs
           ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
      OUTER APPLY (SELECT MAX(x.version_number) AS max_no
                     FROM grac_practice.org_assurance_definition_version x
                    WHERE x.org_assurance_definition_id = d.org_assurance_definition_id) mx
     WHERE d.organization_id = @organization_id
       AND d.is_active = 1
       AND s.status_code <> N'Retired'
       AND qs.root_question_set_id = @root
       AND qs.org_assurance_question_set_id <> @question_set_id
     ORDER BY d.definition_name, d.org_assurance_definition_id;
END
GO

-- ---------------------------------------------------------------------
-- sp_org_assurance_question_set_approve -- UnderReview -> Active; the
-- previous Active version -> Superseded; then every audit definition that
-- uses an older version moves to this one (see the header). Returns what
-- was done, one row per definition.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_question_set_approve
    @organization_id BIGINT,
    @question_set_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @set_org BIGINT, @vs NVARCHAR(20), @root BIGINT, @code NVARCHAR(80), @vno INT;
    SELECT @set_org = organization_id, @vs = version_status, @root = root_question_set_id,
           @code = set_code, @vno = version_number
      FROM grac_practice.org_assurance_question_set
     WHERE org_assurance_question_set_id = @question_set_id AND is_active = 1;
    IF @set_org IS NULL THROW 53806, 'Question set not found.', 1;
    IF @set_org <> @organization_id THROW 53807, 'Question set belongs to a different organization.', 1;
    IF @vs <> N'UnderReview' THROW 53844, 'Only a version Under Review can be returned or approved.', 1;

    DECLARE @draft_status_id INT = (SELECT org_assurance_status_id FROM grac_practice.org_assurance_status_master
                                     WHERE status_code = N'Draft');
    DECLARE @note NVARCHAR(400) = CONCAT(N'Question set ', @code, N' version ', @vno, N' approved.');

    CREATE TABLE #impact (
        definition_id   BIGINT NOT NULL,
        version_id      BIGINT NOT NULL,
        status_code     NVARCHAR(60) NOT NULL,
        status_id       INT NOT NULL,
        action_code     NVARCHAR(30) NULL,
        new_version_id  BIGINT NULL,
        new_version_no  INT NULL);

    BEGIN TRAN;

        UPDATE grac_practice.org_assurance_question_set
           SET version_status = N'Superseded', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE root_question_set_id = @root AND version_status = N'Active'
           AND org_assurance_question_set_id <> @question_set_id;

        UPDATE grac_practice.org_assurance_question_set
           SET version_status = N'Active', approved_by = @actor, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE org_assurance_question_set_id = @question_set_id;

        INSERT INTO #impact (definition_id, version_id, status_code, status_id)
        SELECT DISTINCT d.org_assurance_definition_id, d.current_version_id, s.status_code, d.current_status_id
          FROM grac_practice.org_assurance_definition d
          JOIN grac_practice.org_assurance_status_master s
               ON s.org_assurance_status_id = d.current_status_id
          JOIN grac_practice.org_assurance_definition_question_set dq
               ON dq.org_assurance_definition_version_id = d.current_version_id AND dq.is_active = 1
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         WHERE d.organization_id = @organization_id AND d.is_active = 1
           AND s.status_code <> N'Retired'
           AND qs.root_question_set_id = @root
           AND qs.org_assurance_question_set_id <> @question_set_id;

        -- Draft / Under Review: move the link in place.
        UPDATE dq
           SET org_assurance_question_set_id = @question_set_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.org_assurance_definition_question_set dq
          JOIN #impact i ON i.version_id = dq.org_assurance_definition_version_id
          JOIN grac_practice.org_assurance_question_set qs
               ON qs.org_assurance_question_set_id = dq.org_assurance_question_set_id
         WHERE i.status_code IN (N'Draft', N'UnderReview')
           AND dq.is_active = 1
           AND qs.root_question_set_id = @root;

        UPDATE #impact SET action_code = N'UPDATE_IN_PLACE' WHERE status_code IN (N'Draft', N'UnderReview');

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
             action_code, from_status_id, to_status_id, reason_text, actor_display_name, entered_by)
        SELECT i.definition_id, i.version_id, @organization_id, N'QSET_UPDATE', i.status_id, i.status_id,
               @note + N' Linked to the new version.', @actor, @actor
          FROM #impact i WHERE i.action_code = N'UPDATE_IN_PLACE';

        -- Approved / Active: a new Draft version, a full copy.
        DECLARE @def BIGINT, @ver BIGINT, @sid INT, @next INT, @newv BIGINT;
        DECLARE imp CURSOR LOCAL FAST_FORWARD FOR
            SELECT definition_id, version_id, status_id FROM #impact WHERE action_code IS NULL;
        OPEN imp;
        FETCH NEXT FROM imp INTO @def, @ver, @sid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @next = (SELECT MAX(version_number) + 1 FROM grac_practice.org_assurance_definition_version
                          WHERE org_assurance_definition_id = @def);
            CREATE TABLE #ver_map (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

            EXEC grac_practice.sp_org_assurance_clone_rows
                 @table = N'org_assurance_definition_version', @key_column = N'org_assurance_definition_version_id',
                 @where = N'src.org_assurance_definition_version_id = @p_source',
                 @overrides = N'{"version_number":"@p_number","version_label":"CAST(@p_number AS NVARCHAR(20)) + N''.0''","status_id":"@p_status","submitted_by":"NULL","submitted_dt":"NULL","approved_by":"NULL","approved_dt":"NULL","activated_by":"NULL","activated_dt":"NULL","retired_by":"NULL","retired_dt":"NULL"}',
                 @map_table = N'#ver_map', @p_source = @ver, @p_number = @next, @p_status = @draft_status_id, @p_actor = @actor;
            SET @newv = (SELECT new_id FROM #ver_map);
            DROP TABLE #ver_map;

            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id, @from_version_id = @ver, @to_version_id = @newv,
                 @swap_root_set_id = @root, @swap_to_set_id = @question_set_id, @actor = @actor;

            UPDATE grac_practice.org_assurance_definition
               SET current_version_id = @newv, current_status_id = @draft_status_id,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE org_assurance_definition_id = @def;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
                 action_code, from_status_id, to_status_id, reason_text, actor_display_name, entered_by)
            VALUES (@def, @newv, @organization_id, N'CREATE', @sid, @draft_status_id,
                    @note + N' New version for review and approval.', @actor, @actor);

            UPDATE #impact SET action_code = N'NEW_VERSION', new_version_id = @newv, new_version_no = @next
             WHERE definition_id = @def;

            FETCH NEXT FROM imp INTO @def, @ver, @sid;
        END
        CLOSE imp; DEALLOCATE imp;

    COMMIT;

    SELECT i.definition_id     AS DefinitionId,
           d.definition_code   AS DefinitionCode,
           d.definition_name   AS DefinitionName,
           i.action_code       AS ActionCode,
           i.new_version_no    AS NewVersionNumber
      FROM #impact i
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = i.definition_id
     ORDER BY d.definition_name;
END
GO
