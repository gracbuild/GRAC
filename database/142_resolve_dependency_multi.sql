-- =====================================================================
-- 142 Resolve -- many objects per dependency category
--
-- WHAT CHANGES
-- ------------
-- sp_resolve_dependency_save took one object at a time, and the screen
-- offered no way to remove one. A category could hold several objects --
-- uq_pm_practice_dependency_resolution keys on
-- (organization_id, practice_instance_id, dependency_type_id,
--  resolved_dependency_id), so a different object was always a new row --
-- but with a single-value picker and no remove button, adding a second
-- one read as replacing the first. A practice that depends on three
-- applications depends on three applications; nothing about the model
-- said otherwise, only the screen did.
--
-- So:
--   * sp_resolve_dependency_save now takes a JSON array of objects and
--     writes them all in one transaction
--   * sp_resolve_dependency_remove deactivates one resolution
--
-- The single-object signature is replaced rather than kept alongside:
-- two ways to write the same row is how they drift apart.
--
-- NOTHING IS DEACTIVATED IMPLICITLY. Saving objects A and B does not
-- retire C. Removal is an explicit act, because "I added one more" and
-- "these are now the only ones" are different intentions and the screen
-- cannot tell them apart from a list of ticks.
--
-- Also closes a hole in the resolution owner: it is picked from the
-- shared lookups feed, which is not scoped to one organization, so the
-- procedure now checks the chosen employee actually belongs to the
-- instance's organization.
--
-- Error codes 52620-52628. Depends on 141.
-- Rollback: 142_resolve_dependency_multi_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
BEGIN
    RAISERROR('142: dependency tables missing. Run 001/002 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_dependency_save
--
--   @objects_json : [{ "id": 12, "name": "Core Banking" }, ...]
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_save
    @practice_instance_id BIGINT,
    @dependency_type_id   INT,
    @objects_json         NVARCHAR(MAX),
    @resolution_owner_id  BIGINT        = NULL,
    @remarks              NVARCHAR(MAX) = NULL,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @dependency_type_id IS NULL
        THROW 52620, 'sp_resolve_dependency_save: practice instance and dependency category are required.', 1;
    IF @objects_json IS NULL OR ISJSON(@objects_json) <> 1
        THROW 52621, 'sp_resolve_dependency_save: objects must be a JSON array.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;
    IF @organization_id IS NULL
        THROW 52622, 'sp_resolve_dependency_save: instance not found.', 1;

    -- Only a category the instance declares can be resolved, so the
    -- workspace cannot invent dependencies the practice never asked for.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_dependency d
                    WHERE d.practice_instance_id = @practice_instance_id
                      AND d.dependency_type_id   = @dependency_type_id
                      AND d.status = N'Active')
        THROW 52623, 'sp_resolve_dependency_save: this instance does not declare that dependency category.', 1;

    DECLARE @objects TABLE (
        ObjectId   BIGINT PRIMARY KEY,
        ObjectName NVARCHAR(300) NULL
    );

    -- DISTINCT on the id: the picker is a multi-select, and a repeated id
    -- would be a primary key violation here rather than the harmless
    -- duplicate tick the user made.
    INSERT INTO @objects (ObjectId, ObjectName)
    SELECT j.ObjectId, MAX(NULLIF(LTRIM(RTRIM(j.ObjectName)), N''))
    FROM   OPENJSON(@objects_json) WITH (
               ObjectId   BIGINT        '$.id',
               ObjectName NVARCHAR(300) '$.name') j
    WHERE  j.ObjectId IS NOT NULL
    GROUP  BY j.ObjectId;

    IF NOT EXISTS (SELECT 1 FROM @objects)
        THROW 52624, 'sp_resolve_dependency_save: no objects were supplied.', 1;

    IF EXISTS (SELECT 1 FROM @objects WHERE ObjectName IS NULL)
        THROW 52625, 'sp_resolve_dependency_save: every object needs a name.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    DECLARE @resolved_status_id INT = (
        SELECT TOP 1 resolution_status_id FROM grac_practice.dependency_resolution_status_master
        WHERE status_code = N'Resolved' ORDER BY resolution_status_id);
    IF @resolved_status_id IS NULL
        THROW 52626, 'sp_resolve_dependency_save: Resolved dependency status is missing.', 1;

    -- The owner picker is filled from the shared lookups feed, which
    -- returns every employee of every organization the caller may see --
    -- and for a system admin, every employee there is. The screen narrows
    -- that list, but a narrowed dropdown is a convenience, not a control:
    -- resolution_owner_id has a foreign key to organization_employee and
    -- no organization check of its own, so a hand-made request could
    -- otherwise name somebody from another organization as this
    -- instance's owner.
    IF @resolution_owner_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                        WHERE e.employee_id     = @resolution_owner_id
                          AND e.organization_id = @organization_id
                          AND e.status          = N'Active')
        THROW 52628, 'sp_resolve_dependency_save: the resolution owner must be an active employee of this organization.', 1;

    DECLARE @category NVARCHAR(120) = (
        SELECT TOP 1 COALESCE(dt.dependency_type_name, d.dependency_type)
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.dependency_type_master dt
               ON dt.dependency_type_id = d.dependency_type_id
        WHERE  d.practice_instance_id = @practice_instance_id
          AND  d.dependency_type_id   = @dependency_type_id);

    BEGIN TRAN;

    -- Keyed on all four columns of uq_pm_practice_dependency_resolution,
    -- so a different object is an INSERT and the same object again is an
    -- UPDATE. Re-activates a previously removed one rather than colliding
    -- with the unique constraint.
    MERGE grac_practice.practice_dependency_resolution AS target
    USING (SELECT @organization_id      AS organization_id,
                  @practice_instance_id AS practice_instance_id,
                  @dependency_type_id   AS dependency_type_id,
                  o.ObjectId            AS resolved_dependency_id,
                  o.ObjectName          AS resolved_dependency_name
           FROM   @objects o) AS src
       ON target.organization_id        = src.organization_id
      AND target.practice_instance_id   = src.practice_instance_id
      AND target.dependency_type_id     = src.dependency_type_id
      AND target.resolved_dependency_id = src.resolved_dependency_id
    WHEN MATCHED THEN UPDATE SET
        resolved_dependency_name = src.resolved_dependency_name,
        resolution_status_id     = @resolved_status_id,
        resolution_status        = N'Resolved',
        resolution_owner_id      = COALESCE(@resolution_owner_id, target.resolution_owner_id),
        resolution_dt            = SYSUTCDATETIME(),
        remarks                  = COALESCE(@remarks, target.remarks),
        is_active                = 1,
        record_status_id         = @active_record_status_id,
        updated_by               = @actor,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, practice_instance_id, dependency_type_id, dependency_category,
         resolved_dependency_id, resolved_dependency_name, resolution_status_id,
         resolution_status, resolution_owner_id, resolution_dt, remarks,
         is_active, record_status_id, entered_by)
    VALUES
        (src.organization_id, src.practice_instance_id, src.dependency_type_id,
         ISNULL(@category, N'Dependency'),
         src.resolved_dependency_id, src.resolved_dependency_name, @resolved_status_id,
         N'Resolved', @resolution_owner_id, SYSUTCDATETIME(), @remarks,
         1, @active_record_status_id, @actor);

    COMMIT TRAN;

    SELECT CAST(1 AS BIT) AS Success,
           CAST((SELECT COUNT(*) FROM @objects) AS INT) AS SavedCount,
           (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution
             WHERE practice_instance_id = @practice_instance_id
               AND dependency_type_id   = @dependency_type_id
               AND is_active = 1) AS CategoryResolvedCount,
           N'Resolved.' AS Message;
END
GO

-- =====================================================================
-- sp_resolve_dependency_remove
--
-- Deactivates, never deletes: which object this instance was resolved
-- against, and when it stopped being, is an audit answer. The unique
-- constraint still holds the row, so re-adding the same object updates
-- it back to active rather than failing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_remove
    @practice_instance_id BIGINT,
    @resolution_id        BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL OR @resolution_id IS NULL
        THROW 52627, 'sp_resolve_dependency_remove: practice instance and resolution are required.', 1;

    -- Scoped to the instance the caller already opened, so a resolution id
    -- from elsewhere cannot be removed by guessing the number.
    UPDATE grac_practice.practice_dependency_resolution
       SET is_active  = 0,
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
     WHERE resolution_id        = @resolution_id
       AND practice_instance_id = @practice_instance_id
       AND is_active = 1;

    SELECT CAST(CASE WHEN @@ROWCOUNT > 0 THEN 1 ELSE 0 END AS BIT) AS Success,
           CASE WHEN @@ROWCOUNT > 0
                THEN N'Removed.'
                ELSE N'That resolution was not found on this instance, or was already removed.'
           END AS Message;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_resolve_dependency_save takes an array' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p
                          WHERE p.object_id = OBJECT_ID('grac_practice.sp_resolve_dependency_save')
                            AND p.name = '@objects_json')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'single-object parameter gone',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters p
                              WHERE p.object_id = OBJECT_ID('grac_practice.sp_resolve_dependency_save')
                                AND p.name = '@resolved_dependency_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_resolve_dependency_remove present',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_remove','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'unique key still allows many per category',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_practice_dependency_resolution')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'resolution owner is organization-checked',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_dependency_save'))
                 LIKE '%52628%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Resolutions already pointing at an owner from another organization.
-- These predate the check and are not corrected by it -- clear or
-- reassign them if any appear.
SELECT r.resolution_id        AS ResolutionId,
       r.practice_instance_id AS PracticeInstanceId,
       r.dependency_category  AS DependencyCategory,
       r.resolution_owner_id  AS ResolutionOwnerId,
       e.employee_name        AS OwnerName,
       e.organization_id      AS OwnerOrganizationId,
       r.organization_id      AS InstanceOrganizationId
FROM   grac_practice.practice_dependency_resolution r
JOIN   grac_practice.organization_employee e
       ON e.employee_id = r.resolution_owner_id
WHERE  r.is_active = 1
  AND  e.organization_id <> r.organization_id;

-- How many objects each instance has resolved per category today. More
-- than one in a row is exactly what this migration is for.
SELECT r.practice_instance_id AS PracticeInstanceId,
       r.dependency_category  AS DependencyCategory,
       COUNT(*)               AS ResolvedObjects
FROM   grac_practice.practice_dependency_resolution r
WHERE  r.is_active = 1
GROUP  BY r.practice_instance_id, r.dependency_category
ORDER  BY r.practice_instance_id, r.dependency_category;

PRINT '142 Dependency resolution now accepts many objects per category.';
GO
