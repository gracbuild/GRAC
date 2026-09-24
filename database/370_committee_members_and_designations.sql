-- =====================================================================
-- 370 Committee Members + Committee Designation Master
--
-- WHAT THIS ADDS
-- ---------------
-- A Committee previously carried only two named roles baked directly
-- onto the row -- chairperson_id and secretary_id. This migration adds
-- a proper Committee <-> Employee membership list, where each member
-- carries a Designation (Chairperson, Member, Secretary, Coordinator,
-- or an organization's own custom designation) for that Committee.
-- The same employee can hold different designations on different
-- Committees, so the designation is stored on the mapping row, not on
-- the employee or on a global assignment.
--
-- Follows the project's own most recent precedent for exactly this
-- shape of change -- migration 362 (Team Member Selection): a
-- dedicated mapping table, a dedicated read-only lookup shim for the
-- picker, a dedicated read-only shim for the currently-selected list
-- (Edit pre-check / View display), and the save logic split out of the
-- monolith into its own procedure wrapped in a 7-parameter gateway shim
-- (migration 134's sp_org_team_repository_manage pattern) rather than
-- editing dbo.pm_manage_practice_repository (002) in place.
--
-- WHY A NEW MASTER TABLE INSTEAD OF A STATIC LIST
-- -------------------------------------------------
-- Designations have to be reusable across Committees (BRD requirement)
-- while also letting each organization add its own custom designation
-- without leaking it to other organizations. Same shape as
-- frequency_master's is_custom flag (single global list, no per-org
-- rows) PLUS organization_role's per-organization scoping (027) --
-- this table combines both: organization_id NULL means a system/
-- common designation visible to every organization; organization_id
-- set means a custom designation visible only to that organization.
-- Two filtered unique indexes enforce "no duplicate name within its
-- own scope" (system names unique among themselves; an organization's
-- custom names unique among that organization's own rows) -- the same
-- WHERE-filtered-unique-index technique already used by
-- ux_pm_org_role_code (027) and ux_pm_employee_email (002).
--
-- WHY THE SAVE LOGIC IS SPLIT OUT RATHER THAN EDITING 002 IN PLACE
-- --------------------------------------------------------------------
-- dbo.pm_manage_practice_repository's 'committees' branch (002) has no
-- concept of a member list and was never re-emitted by a later
-- migration (unlike dbo.pm_get_practice_repository, re-emitted whole
-- by 300) -- so per the project's migration-history-is-frozen
-- convention, 002 is still the live definition of that whole
-- procedure, and it is a single multi-thousand-line CREATE OR ALTER
-- covering ~40 entity types. Splitting 'committees' save out into its
-- own sp_org_committee_save + sp_org_committee_repository_manage,
-- exactly the way 133/134 already did for 'users' and 'teams', keeps
-- the new member-list logic in one small, readable place instead of
-- growing the monolith further. dbo.pm_manage_practice_repository's
-- 'committees' branch is left completely untouched -- RETIRE (and any
-- other non-SAVE action) still falls through to it unchanged, exactly
-- as 134 already does for users/teams. dbo.pm_get_practice_repository's
-- 'committees' LIST branch (300) is also left untouched: the Committees
-- grid does not need member data, and changing it would risk breaking
-- the grid for a database that has not yet run this migration. Members
-- are read back via the same separate-shim pattern 362 established for
-- Team Members (sp_get_team_member_list).
--
-- DUPLICATE-MAPPING PREVENTION
-- ------------------------------
-- uq_pm_committee_member(committee_id, employee_id) makes a duplicate
-- mapping impossible at the schema level, independent of how the save
-- procedure assembles its INSERTs (same guard as 362's
-- uq_pm_team_member).
--
-- Objects:
--   * grac_practice.committee_designation_master        NEW (reusable master)
--   * grac_practice.organization_committee_member        NEW (mapping table)
--   * grac_practice.sp_org_committee_save                NEW (clean save contract)
--   * grac_practice.sp_org_committee_repository_manage    NEW (7-param gateway shim)
--   * grac_practice.sp_get_committee_member_list          NEW (read-only lookup shim)
--   * grac_practice.sp_get_committee_designation_lookup   NEW (read-only lookup shim)
--   * grac_practice.sp_org_committee_designation_manage   NEW (Add Designation shim)
--
-- Depends on 002 (organization_committee, organization_employee,
-- organization, record_status_master, practice_audit_trace).
-- Rollback: database/370_committee_members_and_designations_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_committee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('370: prerequisites missing. Run 002 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. committee_designation_master -- reusable Committee Designation list
-- =====================================================================
IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NULL
CREATE TABLE grac_practice.committee_designation_master(
 designation_id    INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_committee_designation_master PRIMARY KEY,
 designation_name  NVARCHAR(150) NOT NULL,
 organization_id   BIGINT NULL,
 is_system         BIT NOT NULL CONSTRAINT df_pm_committee_designation_is_system DEFAULT 0,
 is_active         BIT NOT NULL CONSTRAINT df_pm_committee_designation_is_active DEFAULT 1,
 entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_pm_committee_designation_entered_by DEFAULT 'system',
 entered_dt        DATETIME2 NOT NULL CONSTRAINT df_pm_committee_designation_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by        NVARCHAR(100) NULL,
 updated_dt        DATETIME2 NULL,
 CONSTRAINT fk_pm_committee_designation_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id)
);
GO

-- One organization cannot register the same custom designation name twice.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_committee_designation_org')
    CREATE UNIQUE INDEX ux_pm_committee_designation_org
        ON grac_practice.committee_designation_master(organization_id, designation_name)
        WHERE organization_id IS NOT NULL;
GO

-- System/common designation names (organization_id NULL) are unique among
-- themselves -- a second filtered index, since a plain UNIQUE constraint
-- treats every NULL organization_id as distinct and would not catch this.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_committee_designation_system')
    CREATE UNIQUE INDEX ux_pm_committee_designation_system
        ON grac_practice.committee_designation_master(designation_name)
        WHERE organization_id IS NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_committee_designation_org_active')
    CREATE INDEX ix_pm_committee_designation_org_active
        ON grac_practice.committee_designation_master(organization_id, is_active);
GO

-- Seed the system/common designations (BRD example list). NOT EXISTS guard
-- keyed on name so this is safe to re-run.
IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NOT NULL
BEGIN
    ;WITH seed(designation_name, display_seed) AS (
        SELECT N'Chairperson / Committee Head', 1 UNION ALL
        SELECT N'Member', 2 UNION ALL
        SELECT N'Secretary', 3 UNION ALL
        SELECT N'Coordinator', 4
    )
    INSERT grac_practice.committee_designation_master
        (designation_name, organization_id, is_system, is_active, entered_by)
    SELECT s.designation_name, NULL, 1, 1, N'system'
    FROM   seed s
    WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.committee_designation_master existing
        WHERE existing.organization_id IS NULL AND existing.designation_name = s.designation_name
    );
END
GO

-- =====================================================================
-- 2. organization_committee_member -- Committee <-> Employee mapping,
--    one Designation per mapping (same employee can hold a different
--    designation on a different Committee).
-- =====================================================================
IF OBJECT_ID('grac_practice.organization_committee_member','U') IS NULL
CREATE TABLE grac_practice.organization_committee_member(
 committee_member_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_organization_committee_member PRIMARY KEY,
 committee_id         BIGINT NOT NULL,
 employee_id          BIGINT NOT NULL,
 designation_id       INT NOT NULL,
 organization_id      BIGINT NOT NULL,
 status               NVARCHAR(30) NOT NULL CONSTRAINT df_pm_committee_member_status DEFAULT 'Active',
 record_status_id     INT NOT NULL,
 entered_by           NVARCHAR(100) NOT NULL CONSTRAINT df_pm_committee_member_entered_by DEFAULT 'system',
 entered_dt           DATETIME2 NOT NULL CONSTRAINT df_pm_committee_member_entered_dt DEFAULT SYSUTCDATETIME(),
 updated_by           NVARCHAR(100) NULL,
 updated_dt           DATETIME2 NULL,
 CONSTRAINT fk_pm_committee_member_committee FOREIGN KEY(committee_id) REFERENCES grac_practice.organization_committee(committee_id),
 CONSTRAINT fk_pm_committee_member_employee FOREIGN KEY(employee_id) REFERENCES grac_practice.organization_employee(employee_id),
 CONSTRAINT fk_pm_committee_member_designation FOREIGN KEY(designation_id) REFERENCES grac_practice.committee_designation_master(designation_id),
 CONSTRAINT fk_pm_committee_member_organization FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
 CONSTRAINT fk_pm_committee_member_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id),
 -- A Committee cannot map the same employee twice (BRD: "Do not create
 -- duplicate member mappings for the same Committee").
 CONSTRAINT uq_pm_committee_member UNIQUE(committee_id, employee_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_committee_member_committee_id' AND object_id = OBJECT_ID('grac_practice.organization_committee_member'))
    CREATE INDEX ix_pm_committee_member_committee_id ON grac_practice.organization_committee_member(committee_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_committee_member_employee_id' AND object_id = OBJECT_ID('grac_practice.organization_committee_member'))
    CREATE INDEX ix_pm_committee_member_employee_id ON grac_practice.organization_committee_member(employee_id);
GO

-- =====================================================================
-- 3. sp_org_committee_save -- clean-signature save, ported from the
--    'committees' branch of dbo.pm_manage_practice_repository (002,
--    lines ~3780-3807) UNCHANGED for the existing fields, plus the new
--    Committee Members block. Mirrors sp_org_team_save's shape (133).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_committee_save
    @p_payload NVARCHAR(MAX),
    @p_id      BIGINT = 0,
    @p_usr_id  NVARCHAR(100) = 'system',
    @out_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @active_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = 'Active');
    DECLARE @payload_record_status_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = JSON_VALUE(@p_payload,'$.status') OR status_name = JSON_VALUE(@p_payload,'$.status'));
    DECLARE @payload_record_status_id_from_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.statusId'),''));
    SET @payload_record_status_id = COALESCE(@payload_record_status_id_from_id, @payload_record_status_id);

    -- ---- original committees validation, unchanged from 002 ----
    DECLARE @committee_org_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @committee_name NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.name'))),'');
    DECLARE @committee_chairperson_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.chairpersonId'),''));
    DECLARE @committee_secretary_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.secretaryId'),''));
    DECLARE @committee_frequency_id INT = TRY_CONVERT(INT, NULLIF(JSON_VALUE(@p_payload,'$.reviewFrequencyId'),''));
    DECLARE @committee_status_id INT = COALESCE(@payload_record_status_id, @active_record_status_id);
    DECLARE @committee_status_name NVARCHAR(30) =
        COALESCE((SELECT status_name FROM grac_practice.record_status_master WHERE record_status_id = @committee_status_id),'Active');

    IF @committee_org_id IS NULL THROW 51072,'Organization is required for Committee.',1;
    IF @committee_name IS NULL THROW 51073,'Committee Name is required.',1;
    IF @committee_chairperson_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_chairperson_id AND organization_id=@committee_org_id AND status='Active')
        THROW 51074,'Selected Committee Head is not valid for this organization.',1;
    IF @committee_secretary_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.organization_employee WHERE employee_id=@committee_secretary_id AND organization_id=@committee_org_id AND status='Active')
        THROW 51075,'Selected Secretary is not valid for this organization.',1;
    IF @committee_frequency_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM grac_practice.frequency_master WHERE frequency_id=@committee_frequency_id AND is_active=1)
        THROW 51076,'Selected Review Frequency is not valid.',1;

    -- ---- Committee Members (change request 2026-09-22) ----
    -- @p_payload.members is a JSON array of { "employeeId": n, "designationId": n },
    -- e.g. [{"employeeId":3,"designationId":1},{"employeeId":7,"designationId":2}].
    -- Missing entirely means "leave existing members untouched"; an explicit
    -- empty array [] means "clear all members" -- the UI always posts the
    -- full current member list, not a diff. Same convention as 362's
    -- memberIds, extended with the per-member designation.
    DECLARE @members_json NVARCHAR(MAX) = NULL;
    IF OBJECT_ID('grac_practice.organization_committee_member','U') IS NOT NULL
    BEGIN
        SET @members_json = JSON_QUERY(@p_payload, '$.members');
        IF @members_json IS NOT NULL AND ISJSON(@members_json) <> 1
            THROW 51083, 'Committee Members selection is not a valid list.', 1;
    END

    -- Stage only rows that are actually valid for this Committee's
    -- organization: the employee must be Active and belong to this
    -- organization; the designation must be Active and either a system
    -- designation (organization_id NULL) or this organization's own
    -- custom designation. Anything else (a stale pick for an employee/
    -- designation deactivated after the form loaded, or from another
    -- organization) is silently dropped rather than failing the whole
    -- Committee save -- same "degrade, don't fail" rule 133 uses for
    -- Team Members. ROW_NUMBER + a max-1-per-employee filter is the
    -- second, application-level duplicate guard on top of
    -- uq_pm_committee_member -- if a caller somehow posts the same
    -- employee twice, the first designation wins.
    DECLARE @valid_members TABLE (employee_id BIGINT PRIMARY KEY, designation_id INT NOT NULL);
    IF @members_json IS NOT NULL
        INSERT @valid_members (employee_id, designation_id)
        SELECT employee_id, designation_id
        FROM (
            -- Schema-less OPENJSON (no WITH clause) here deliberately --
            -- a WITH-typed OPENJSON only projects the columns named in
            -- WITH, so it has no [key] column to order by. The default
            -- shape (key/value/type) keeps [key] as the array's ordinal
            -- position, which is all ROW_NUMBER needs below to pick a
            -- winner when a caller posts the same employee twice.
            SELECT e.employee_id, d.designation_id,
                   ROW_NUMBER() OVER (PARTITION BY e.employee_id ORDER BY j.[key]) AS rn
            FROM   OPENJSON(@members_json) j
            JOIN   grac_practice.organization_employee e
                   ON e.employee_id = TRY_CONVERT(BIGINT, JSON_VALUE(j.value, '$.employeeId'))
                  AND e.organization_id = @committee_org_id AND e.status = N'Active'
            JOIN   grac_practice.committee_designation_master d
                   ON d.designation_id = TRY_CONVERT(INT, JSON_VALUE(j.value, '$.designationId'))
                  AND d.is_active = 1
                  AND (d.organization_id IS NULL OR d.organization_id = @committee_org_id)
        ) staged
        WHERE staged.rn = 1;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.organization_committee(organization_id,committee_name,chairperson_id,secretary_id,review_frequency_id,remarks,status,record_status_id,entered_by)
        VALUES(@committee_org_id,@committee_name,@committee_chairperson_id,@committee_secretary_id,@committee_frequency_id,JSON_VALUE(@p_payload,'$.remarks'),@committee_status_name,@committee_status_id,@p_usr_id);
        SET @out_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.organization_committee SET organization_id=@committee_org_id,committee_name=@committee_name,chairperson_id=@committee_chairperson_id,
          secretary_id=@committee_secretary_id,review_frequency_id=@committee_frequency_id,remarks=JSON_VALUE(@p_payload,'$.remarks'),
          status=@committee_status_name,record_status_id=@committee_status_id,updated_by=@p_usr_id,updated_dt=SYSUTCDATETIME()
        WHERE committee_id=@p_id;
        SET @out_id = @p_id;
    END

    -- Replace the member set with whatever was just validated above --
    -- same clean replace-per-save as 133's Team Members block.
    IF @members_json IS NOT NULL
    BEGIN
        DELETE FROM grac_practice.organization_committee_member WHERE committee_id = @out_id;
        INSERT grac_practice.organization_committee_member
            (committee_id, employee_id, designation_id, organization_id, status, record_status_id, entered_by)
        SELECT @out_id, v.employee_id, v.designation_id, @committee_org_id, N'Active', @active_record_status_id, @p_usr_id
        FROM   @valid_members v;
    END
END;
GO

-- =====================================================================
-- 4. sp_org_committee_repository_manage -- 7-parameter monolith-contract
--    gateway shim. Intercepts SAVE only; everything else (RETIRE, and
--    any future generic action) passes straight through to the
--    untouched 'committees' branch of dbo.pm_manage_practice_repository
--    (002). Same shape as 134's sp_org_team_repository_manage.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_committee_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(@p_action, '');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = @p_entity_type, @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    BEGIN TRAN;

    DECLARE @new_id BIGINT = @p_id;
    EXEC grac_practice.sp_org_committee_save
         @p_payload = @p_payload, @p_id = @p_id, @p_usr_id = @p_usr_id,
         @out_id = @new_id OUTPUT;

    -- Same audit row the monolith writes for every save, so the trace
    -- stays continuous across the boundary (134's own reasoning).
    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO

-- =====================================================================
-- 5. sp_get_committee_member_list -- read-only feed for the currently-
--    selected members of ONE committee, used to pre-populate the member
--    list on Edit and render the read-only member grid on View. @p_id
--    is the committee_id, same convention as sp_get_team_member_list
--    (362). Deliberately separate from the Committees grid query
--    (dbo.pm_get_practice_repository's 'committees' branch, 300) so an
--    unapplied 370 just means an empty member list, not a broken grid.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_committee_member_list
    @p_entity_type NVARCHAR(100) = N'',
    @p_action      NVARCHAR(40)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_practice.organization_committee_member','U') IS NULL
        RETURN;

    SELECT cm.committee_id            AS CommitteeId,
           cm.employee_id             AS EmployeeId,
           CAST(cm.employee_id AS NVARCHAR(40)) AS Value,
           e.employee_code            AS EmployeeCode,
           e.employee_name            AS EmployeeName,
           e.employee_code + N' - ' + e.employee_name AS Label,
           cm.designation_id          AS DesignationId,
           d.designation_name         AS DesignationName
    FROM   grac_practice.organization_committee_member cm
    JOIN   grac_practice.organization_employee e ON e.employee_id = cm.employee_id
    JOIN   grac_practice.committee_designation_master d ON d.designation_id = cm.designation_id
    WHERE  (@p_id = 0 OR cm.committee_id = @p_id)
    ORDER  BY e.employee_name;
END
GO

-- =====================================================================
-- 6. sp_get_committee_designation_lookup -- read-only feed for the
--    Designation picker: every active designation, system and every
--    organization's custom ones alike. Deliberately NOT filtered to one
--    organization here -- same "no scoping duplicated here" choice
--    342's sp_get_owners_lookup documents and 362's
--    sp_get_team_department_employee_tree repeats: the UI's
--    lookupItemsFor() already filters every org-scoped lookup down to
--    the organization currently open on the form (committee-designations
--    is added to that whitelist in practice.js), so filtering here too
--    would just be the same rule enforced twice. This also means the
--    lookup is fetched once per page load, not re-fetched every time the
--    Committee form's Organization field changes.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_committee_designation_lookup
    @p_entity_type NVARCHAR(100) = N'',
    @p_action      NVARCHAR(40)  = N'',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NULL
        RETURN;

    SELECT d.designation_id                       AS DesignationId,
           CAST(d.designation_id AS NVARCHAR(40))  AS Value,
           d.designation_name                      AS Label,
           d.designation_name                      AS DesignationName,
           d.organization_id                       AS OrganizationId,
           d.is_system                             AS IsSystem
    FROM   grac_practice.committee_designation_master d
    WHERE  d.is_active = 1
    ORDER  BY d.is_system DESC, d.designation_name;
END
GO

-- =====================================================================
-- 7. sp_org_committee_designation_manage -- "Add Designation" quick-
--    create, reached from the Committee Member row while adding a
--    member. Self-contained (no monolith fallback -- this entity type
--    never existed in dbo.pm_manage_practice_repository, unlike
--    users/teams/committees, so there is nothing to delegate RETIRE to).
--    Always creates an organization-owned custom designation
--    (is_system=0); organizations cannot create or retire system
--    designations through this shim.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_committee_designation_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(NULLIF(@p_action, ''), N'SAVE');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    IF OBJECT_ID('grac_practice.committee_designation_master','U') IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) Success, N'Committee Designation Master is not available.' Message, CAST(0 AS BIGINT) Id;
        RETURN;
    END

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @designation_name NVARCHAR(150) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload,'$.designationName'))),'');

    IF @p_action = N'RETIRE'
    BEGIN
        -- Deactivate an organization's own custom designation only --
        -- system designations (organization_id NULL) can never be
        -- retired through this shim.
        UPDATE grac_practice.committee_designation_master
           SET is_active = 0, updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
         WHERE designation_id = @p_id AND organization_id IS NOT NULL;
        SELECT CAST(1 AS BIT) Success, N'Designation deactivated.' Message, @p_id Id;
        RETURN;
    END

    IF @organization_id IS NULL THROW 51090, 'Organization is required to add a Committee Designation.', 1;
    IF @designation_name IS NULL THROW 51091, 'Designation Name is required.', 1;

    -- Reuse an existing designation (system, or already registered by
    -- this organization) rather than creating a second row with the
    -- same name -- case-insensitive match, same spirit as
    -- frequency_master's seed's own de-dupe check.
    DECLARE @existing_id INT = (
        SELECT TOP 1 designation_id FROM grac_practice.committee_designation_master
        WHERE is_active = 1
          AND (organization_id IS NULL OR organization_id = @organization_id)
          AND designation_name = @designation_name
    );
    IF @existing_id IS NOT NULL
    BEGIN
        SELECT CAST(1 AS BIT) Success, N'Designation already exists; selecting it.' Message, @existing_id Id;
        RETURN;
    END

    INSERT grac_practice.committee_designation_master
        (designation_name, organization_id, is_system, is_active, entered_by)
    VALUES (@designation_name, @organization_id, 0, 1, @p_usr_id);

    DECLARE @new_id INT = SCOPE_IDENTITY();
    SELECT CAST(1 AS BIT) Success, N'Designation added.' Message, @new_id Id;
END;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'committee_designation_master table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.committee_designation_master','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'ux_pm_committee_designation_org unique index',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_committee_designation_org') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'ux_pm_committee_designation_system unique index',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_committee_designation_system') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'system designations seeded (expect >= 4)',
       CAST((SELECT COUNT(*) FROM grac_practice.committee_designation_master WHERE organization_id IS NULL AND is_system = 1) AS NVARCHAR(20))
UNION ALL SELECT 'organization_committee_member table',
       CASE WHEN OBJECT_ID('grac_practice.organization_committee_member','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'uq_pm_committee_member unique constraint',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_pm_committee_member') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_committee_save',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_committee_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_committee_repository_manage',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_committee_repository_manage','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_get_committee_member_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_committee_member_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_get_committee_designation_lookup',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_committee_designation_lookup','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_committee_designation_manage',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_committee_designation_manage','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- All 7-parameter gateway/shim procedures must accept the monolith's
-- seven parameters, same check 134 runs on its own shims.
SELECT p.name AS ProcedureName, COUNT(*) AS ParameterCount,
       CASE WHEN COUNT(*) = 7 THEN 'PASS' ELSE 'FAIL -- must be 7' END AS Result
FROM   sys.procedures p
JOIN   sys.parameters pa ON pa.object_id = p.object_id
WHERE  p.name IN ('sp_org_committee_repository_manage','sp_get_committee_member_list',
                  'sp_get_committee_designation_lookup','sp_org_committee_designation_manage')
GROUP BY p.name
ORDER BY p.name;

PRINT '370 Committee Members + Committee Designation Master: schema + 5 procedures ready.';
PRINT 'NEXT: map "committees" (isManage) to sp_org_committee_repository_manage, and';
PRINT '      "committee-members" / "committee-designations" (isQuery) to their lookup';
PRINT '      shims, in PracticeRepositoryService.ResolveProcedureAsync; add';
PRINT '      "committee-designations" (isManage) to sp_org_committee_designation_manage;';
PRINT '      whitelist committee-members / committee-designations in';
PRINT '      PracticeRepositoryController; map committee-designations -> committees in';
PRINT '      PermissionAreaMap; grant committee-members:VIEW / committee-designations:VIEW';
PRINT '      in LoginController.SupportingReads; then wire the Committee Members section';
PRINT '      into wwwroot/js/practice.js.';
GO

SET NOEXEC OFF;
GO
