-- =====================================================================
-- 222 Resolve workspace -- instance profile, retire, dependency
--     categories  (Practice Instance form slimming, stage 2)
--
-- WHY
-- ---
-- Stage 1 (docs/practice-instance-form-slimming.md) took the
-- obligation-owned inputs off the Practice Instance edit form. What is
-- still captured only there is the instance's own profile -- Practice
-- Type, Criticality, Business Function, Owner -- plus which dependency
-- categories it declares, plus retirement. Until those have somewhere
-- else to live, the screen cannot go, and migration 139 says so in as
-- many words:
--
--     "Retiring an instance stays an explicit act on the Practice
--      Instances screen."
--
-- This migration gives Resolve the four things that sentence blocks on.
--
-- WHAT IT ADDS
-- ------------
--   sp_resolve_instance_detail        re-issued: + BusinessFunctionId,
--                                     BusinessFunction, OwnerDepartmentId
--   sp_resolve_instance_profile_save  Practice Type / Criticality /
--                                     Business Function / Owner
--   sp_resolve_instance_retire        the explicit retirement act
--   sp_resolve_dependency_type_list   categories available + declared
--   sp_resolve_dependency_type_save   declare / undeclare categories
--
-- OWNER CHANGE IS ADMIN-ONLY, ON PURPOSE
-- --------------------------------------
-- Every Resolve procedure scopes a non-admin caller to instances where
-- primary_owner_id = @caller_employee_id. An owner who reassigns their
-- own instance would therefore lose access to it the moment they saved,
-- with no way back short of an administrator. So @primary_owner_id is
-- honoured only when @is_admin = 1; a non-admin who sends one is
-- refused rather than silently ignored, because silently ignoring it
-- would look like a save that worked.
--
-- NULL MEANS "NO OPINION"
-- -----------------------
-- Every profile parameter COALESCEs to the stored value. The screen
-- sends the whole profile, but a caller that sends one field must not
-- blank the other three -- the same rule sp_org_user_save follows for
-- force_password_change.
--
-- UNDECLARING A CATEGORY WITH RESOLUTIONS IS REFUSED
-- --------------------------------------------------
-- Migration 142 established that nothing is deactivated implicitly:
-- "I added one more" and "these are now the only ones" are different
-- intentions. The category picker is a full-set control, so it does
-- carry the second intention -- but a category holding resolved objects
-- is not just a tick, it is rows in practice_dependency_resolution.
-- Those are reported back as Blocked and left alone; the objects have to
-- be removed on the dependency card first.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: CREATE OR ALTER throughout; no data is written.
--
-- Error codes 52670-52689 (52660-52663 belong to 145, 52620-52628 to
-- 142, 52600-52619 to 141, 52500s to 139).
-- DEPENDS ON: 140/141 (Resolve workspace), 142 (dependency resolutions),
--             145 (sp_resolve_instance_frequency_save, the shape these
--             follow), 015 (dependency_type_master).
-- Rollback:   database/222_resolve_instance_profile_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard -- same pattern as 141 / 142 / 145.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (222): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN
    PRINT 'ABORT (222): practice_instance / dependency tables missing. Run 001, 002 and 142 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (222): dependency_type_master missing. Run 015 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_resolve_instance_detail','P') IS NULL
BEGIN
    PRINT 'ABORT (222): sp_resolve_instance_detail missing. Run 141 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_resolve_instance_frequency_save','P') IS NULL
BEGIN
    PRINT 'ABORT (222): sp_resolve_instance_frequency_save missing. Run 145 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','business_function_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','department_id') IS NULL
BEGIN
    PRINT 'ABORT (222): practice_instance is missing primary_owner_id / business_function_id / department_id. Run 002 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('222_resolve_instance_profile: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_instance_detail -- re-issued
--
--    The 141 body, unchanged, plus the three columns the profile editor
--    needs to show a current value: BusinessFunctionId (the select's
--    value -- the existing Department column is a display name and no
--    use as one), BusinessFunction, and OwnerDepartmentId.
--
--    Everything else is byte-for-byte 141. Keep the two in step if 141
--    is ever revised.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_detail
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL,
    @caller_employee_id   BIGINT = NULL,
    @is_admin             BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52602, 'sp_resolve_instance_detail: practice_instance_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                    WHERE practice_instance_id = @practice_instance_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52603, 'sp_resolve_instance_detail: instance not found for this organization.', 1;

    -- The list already hides instances the caller does not own, but the
    -- workspace is reachable by URL. Without this check, changing one
    -- number in the address bar opens a colleague's instance -- and the
    -- obligation and dependency endpoints hang off whatever opens here.
    IF @is_admin = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                        WHERE practice_instance_id = @practice_instance_id
                          AND primary_owner_id = @caller_employee_id)
        THROW 52619, 'sp_resolve_instance_detail: this practice instance belongs to another owner.', 1;

    SELECT
        pi.practice_instance_id  AS PracticeInstanceId,
        pi.organization_id       AS OrganizationId,
        o.organization_name      AS OrganizationName,
        pi.instance_code         AS InstanceCode,
        pi.instance_name         AS InstanceName,
        p.practice_id            AS PracticeId,
        p.practice_code          AS PracticeCode,
        p.practice_name          AS PracticeName,
        pi.primary_owner_id      AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        ef.frequency_name        AS ExecutionFrequency,
        af.frequency_name        AS AssuranceFrequency,
        pi.assurance_mode        AS AssuranceMode,
        pi.criticality           AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                AS Status,
        -- 222 additions.
        pi.department_id         AS OwnerDepartmentId,
        pi.business_function_id  AS BusinessFunctionId,
        bf.function_name         AS BusinessFunction
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id
    JOIN   grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.organization_business_function bf
           ON bf.business_function_id = pi.business_function_id
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- 2. sp_resolve_instance_profile_save
--
--    Practice Type, Criticality, Business Function and -- for an admin
--    only -- the Owner. Shaped on sp_resolve_instance_frequency_save
--    (145): same ownership test, same actor stamp, same
--    Success / Message result set.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_profile_save
    @practice_instance_id  BIGINT,
    @assurance_mode        NVARCHAR(40)  = NULL,   -- Practice Type
    @criticality           NVARCHAR(30)  = NULL,
    @business_function_id  BIGINT        = NULL,
    @primary_owner_id      BIGINT        = NULL,   -- admin only
    @caller_employee_id    BIGINT        = NULL,
    @is_admin              BIT           = 0,
    @actor                 NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52670, 'sp_resolve_instance_profile_save: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @current_owner_id BIGINT;
    SELECT @organization_id  = organization_id,
           @current_owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52671, 'sp_resolve_instance_profile_save: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52672, 'sp_resolve_instance_profile_save: this practice instance belongs to another owner.', 1;

    -- Refused, not ignored. A non-admin whose owner change was quietly
    -- dropped would read the "Saved." message and believe it happened.
    IF @primary_owner_id IS NOT NULL
       AND @is_admin = 0
       AND @primary_owner_id <> ISNULL(@current_owner_id, -1)
        THROW 52673, 'Only an administrator can change the owner of a practice instance.', 1;

    IF @assurance_mode IS NOT NULL AND @assurance_mode NOT IN (N'Manual', N'Automated')
        THROW 52674, 'sp_resolve_instance_profile_save: Practice Type must be Manual or Automated.', 1;

    -- criticality_master is the catalog when it is populated; the four
    -- fixed values are the fallback, because practice_instance.criticality
    -- is free text with a 'Medium' default and predates the master.
    IF @criticality IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.criticality_master
                        WHERE is_active = 1
                          AND (criticality_code = @criticality OR criticality_name = @criticality))
       AND @criticality NOT IN (N'Critical', N'High', N'Medium', N'Low')
        THROW 52675, 'sp_resolve_instance_profile_save: that criticality does not exist.', 1;

    IF @business_function_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_business_function
                        WHERE business_function_id = @business_function_id
                          AND organization_id      = @organization_id
                          AND status               = N'Active')
        THROW 52676, 'sp_resolve_instance_profile_save: that business function does not belong to this organization.', 1;

    -- An owner from another organization would pass every other check and
    -- then be invisible to the employee lookups the screens use.
    DECLARE @owner_name NVARCHAR(200), @owner_department_id BIGINT;
    IF @primary_owner_id IS NOT NULL
    BEGIN
        SELECT @owner_name          = e.employee_name,
               @owner_department_id = e.department_id
        FROM   grac_practice.organization_employee e
        WHERE  e.employee_id     = @primary_owner_id
          AND  e.organization_id = @organization_id
          AND  e.status          = N'Active';

        IF @owner_name IS NULL
            THROW 52677, 'sp_resolve_instance_profile_save: that owner is not an active employee of this organization.', 1;
    END

    -- Resolved BEFORE the UPDATE, not inside its SET list.
    --
    -- A correlated subquery there would read
    --     WHERE d.department_id = COALESCE(@owner_department_id, department_id)
    -- and organization_department has a department_id column of its own,
    -- so the unqualified name binds to the INNER scope: d.department_id =
    -- d.department_id, true for every row, and the department name becomes
    -- whichever row the engine reached first. Silent, and wrong in a way
    -- no error would ever report.
    DECLARE @owner_department_name NVARCHAR(200);
    IF @owner_department_id IS NOT NULL
        SELECT @owner_department_name = d.department_name
        FROM   grac_practice.organization_department d
        WHERE  d.department_id = @owner_department_id;

    UPDATE grac_practice.practice_instance
       SET assurance_mode       = COALESCE(@assurance_mode,       assurance_mode),
           criticality          = COALESCE(@criticality,          criticality),
           business_function_id = COALESCE(@business_function_id, business_function_id),
           primary_owner_id     = COALESCE(@primary_owner_id,     primary_owner_id),
           -- primary_owner and department are denormalised copies the list
           -- and grid read; leaving them behind is how a renamed owner
           -- shows two different names on two screens. All three stay put
           -- when the owner is not being changed, because @owner_name and
           -- @owner_department_id are only populated then.
           primary_owner        = COALESCE(@owner_name,            primary_owner),
           department_id        = COALESCE(@owner_department_id,   department_id),
           department           = COALESCE(@owner_department_name, department),
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT)        AS Success,
           N'Profile saved.'     AS Message,
           pi.assurance_mode     AS AssuranceMode,
           pi.criticality        AS Criticality,
           pi.business_function_id AS BusinessFunctionId,
           bf.function_name         AS BusinessFunction,
           pi.primary_owner_id   AS OwnerEmployeeId,
           COALESCE(e.employee_name, pi.primary_owner) AS OwnerName
    FROM   grac_practice.practice_instance pi
    LEFT   JOIN grac_practice.organization_business_function bf
           ON bf.business_function_id = pi.business_function_id
    LEFT   JOIN grac_practice.organization_employee e
           ON e.employee_id = pi.primary_owner_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- 3. sp_resolve_instance_retire
--
--    The act migration 139 reserved for the Practice Instances screen.
--    Deliberately the same two columns that screen's RETIRE path writes
--    (dbo.pm_manage_practice_repository: status = 'Inactive' plus the
--    Inactive record_status_id) -- a second definition of "retired" is
--    how the two drift.
--
--    NOT a delete. practice_instance_id is a foreign key in roughly
--    twenty tables; the row has to stay so assurance history, evidence
--    and closed tasks keep their subject.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_retire
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52680, 'sp_resolve_instance_retire: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30);
    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52681, 'sp_resolve_instance_retire: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52682, 'sp_resolve_instance_retire: this practice instance belongs to another owner.', 1;

    IF @current_status <> N'Active'
        THROW 52683, 'sp_resolve_instance_retire: this practice instance is already retired.', 1;

    DECLARE @inactive_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Inactive' OR status_name = N'Inactive'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Inactive',
           record_status_id = COALESCE(@inactive_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance retired.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- 4. sp_resolve_dependency_type_list
--
--    Every active dependency category, with a flag for the ones this
--    instance declares and a count of what is already resolved against
--    each. One call fills the picker AND tells the screen which ticks
--    cannot be cleared.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_type_list
    @practice_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52684, 'sp_resolve_dependency_type_list: practice_instance_id is required.', 1;

    SELECT dt.dependency_type_id   AS DependencyTypeId,
           dt.dependency_type_name AS DependencyCategory,
           CAST(CASE WHEN d.dependency_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsDeclared,
           ISNULL(r.ResolvedCount, 0) AS ResolvedCount
    FROM   grac_practice.dependency_type_master dt
    LEFT   JOIN (
               SELECT dependency_type_id, MIN(dependency_id) AS dependency_id
               FROM   grac_practice.practice_instance_dependency
               WHERE  practice_instance_id = @practice_instance_id
                 AND  status = N'Active'
                 AND  dependency_type_id IS NOT NULL
               GROUP  BY dependency_type_id
           ) d ON d.dependency_type_id = dt.dependency_type_id
    LEFT   JOIN (
               SELECT dependency_type_id, COUNT(*) AS ResolvedCount
               FROM   grac_practice.practice_dependency_resolution
               WHERE  practice_instance_id = @practice_instance_id
                 AND  is_active = 1
               GROUP  BY dependency_type_id
           ) r ON r.dependency_type_id = dt.dependency_type_id
    WHERE  dt.is_active = 1
    ORDER  BY dt.dependency_type_name;
END
GO

-- =====================================================================
-- 5. sp_resolve_dependency_type_save
--
--    @dependency_type_ids is the COMPLETE desired set, as a JSON array
--    of ids: [3,7,11]. The picker is a full-set control, so it carries
--    the "these are now the only ones" intention that migration 142
--    warned a partial payload does not.
--
--    A category holding active resolutions is NOT undeclared. Those are
--    rows in practice_dependency_resolution, not a tick, and losing them
--    to a stray click is the outcome 142 and 139 both guard against.
--    They come back in the second result set so the screen can say which
--    and why rather than silently disagreeing with the user.
--
--    Declared rows carry the category name as dependency_name, matching
--    what dbo.pm_manage_practice_repository writes for a declared-only
--    dependency (dependency_name is NOT NULL).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_type_save
    @practice_instance_id BIGINT,
    @dependency_type_ids  NVARCHAR(MAX) = N'[]',
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52685, 'sp_resolve_dependency_type_save: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @current_owner_id BIGINT;
    SELECT @organization_id  = organization_id,
           @current_owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52686, 'sp_resolve_dependency_type_save: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52687, 'sp_resolve_dependency_type_save: this practice instance belongs to another owner.', 1;

    IF ISJSON(ISNULL(@dependency_type_ids, N'[]')) <> 1
        THROW 52688, 'sp_resolve_dependency_type_save: dependency_type_ids must be a JSON array of ids.', 1;

    DECLARE @wanted TABLE (dependency_type_id INT PRIMARY KEY);
    INSERT @wanted (dependency_type_id)
    SELECT DISTINCT TRY_CONVERT(INT, value)
    FROM   OPENJSON(ISNULL(@dependency_type_ids, N'[]'))
    WHERE  TRY_CONVERT(INT, value) IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @wanted w
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_master dt
                                   WHERE dt.dependency_type_id = w.dependency_type_id
                                     AND dt.is_active = 1))
        THROW 52689, 'sp_resolve_dependency_type_save: one of those dependency categories does not exist.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER  BY record_status_id
    );

    DECLARE @added INT = 0, @removed INT = 0;

    -- Declaring and undeclaring are one edit of one set, so they commit
    -- together. XACT_ABORT is ON, so any error below rolls the whole
    -- thing back rather than leaving half a picker applied.
    BEGIN TRANSACTION;

    -- 5a. Declare what is wanted and not yet declared. A row that exists
    --     but was retired is reactivated rather than duplicated.
    UPDATE d
       SET d.status     = N'Active',
           d.updated_by = @actor,
           d.updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_dependency d
    JOIN   @wanted w ON w.dependency_type_id = d.dependency_type_id
    WHERE  d.practice_instance_id = @practice_instance_id
      AND  d.status <> N'Active';

    SET @added = @@ROWCOUNT;

    INSERT grac_practice.practice_instance_dependency
        (organization_id, practice_instance_id, dependency_type_id, dependency_type,
         dependency_name, criticality, status, record_status_id, entered_by, entered_dt)
    SELECT @organization_id, @practice_instance_id, dt.dependency_type_id, dt.dependency_type_code,
           dt.dependency_type_name, N'Medium', N'Active',
           COALESCE(@active_record_status_id, 1), @actor, SYSUTCDATETIME()
    FROM   @wanted w
    JOIN   grac_practice.dependency_type_master dt
           ON dt.dependency_type_id = w.dependency_type_id
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_dependency d
                        WHERE d.practice_instance_id = @practice_instance_id
                          AND d.dependency_type_id   = w.dependency_type_id);

    SET @added = @added + @@ROWCOUNT;

    -- 5b. Undeclare what is declared and no longer wanted -- unless it
    --     holds active resolutions.
    DECLARE @blocked TABLE (dependency_type_id INT PRIMARY KEY, ResolvedCount INT);
    INSERT @blocked (dependency_type_id, ResolvedCount)
    SELECT d.dependency_type_id, COUNT(r.resolution_id)
    FROM   grac_practice.practice_instance_dependency d
    JOIN   grac_practice.practice_dependency_resolution r
           ON r.practice_instance_id = d.practice_instance_id
          AND r.dependency_type_id   = d.dependency_type_id
          AND r.is_active            = 1
    WHERE  d.practice_instance_id = @practice_instance_id
      AND  d.status = N'Active'
      AND  d.dependency_type_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM @wanted w WHERE w.dependency_type_id = d.dependency_type_id)
    GROUP  BY d.dependency_type_id;

    UPDATE d
       SET d.status     = N'Inactive',
           d.updated_by = @actor,
           d.updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_dependency d
    WHERE  d.practice_instance_id = @practice_instance_id
      AND  d.status = N'Active'
      AND  d.dependency_type_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM @wanted w WHERE w.dependency_type_id = d.dependency_type_id)
      AND  NOT EXISTS (SELECT 1 FROM @blocked b WHERE b.dependency_type_id = d.dependency_type_id);

    SET @removed = @@ROWCOUNT;

    COMMIT TRANSACTION;

    SELECT CAST(1 AS BIT) AS Success,
           CASE WHEN EXISTS (SELECT 1 FROM @blocked)
                THEN N'Saved. Some categories were kept because they still have resolved objects.'
                ELSE N'Dependency categories saved.' END AS Message,
           @added   AS AddedCount,
           @removed AS RemovedCount;

    SELECT b.dependency_type_id   AS DependencyTypeId,
           dt.dependency_type_name AS DependencyCategory,
           b.ResolvedCount        AS ResolvedCount
    FROM   @blocked b
    JOIN   grac_practice.dependency_type_master dt
           ON dt.dependency_type_id = b.dependency_type_id
    ORDER  BY dt.dependency_type_name;
END
GO

-- =====================================================================
-- 6. Verification
-- =====================================================================
PRINT '=== 222 verification ===';

SELECT 'sp_resolve_instance_detail carries the 222 columns' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_detail','P'))
                 LIKE '%BusinessFunctionId%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_resolve_instance_profile_save exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_profile_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'sp_resolve_instance_retire exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'sp_resolve_dependency_type_list exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_type_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'sp_resolve_dependency_type_save exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_type_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'record_status_master has an Inactive row',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.record_status_master
                          WHERE status_code = N'Inactive' OR status_name = N'Inactive')
            THEN 'PASS' ELSE 'REVIEW -- retire will leave record_status_id unchanged' END;

PRINT '';
PRINT '222 Resolve instance profile complete.';
PRINT 'Ship PracticeManagement.Api and PracticeManagement.Web with it -- the';
PRINT 'workspace reads the new detail columns and posts to the new endpoints.';
GO

SET NOEXEC OFF;
GO
