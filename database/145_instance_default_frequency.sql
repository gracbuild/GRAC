-- =====================================================================
-- 145 Default an instance's frequency from its parent obligations
--
-- Configure created instances with no execution or assurance frequency:
-- the two columns the rest of the module reads for cadence were left
-- NULL, so every new instance had to be opened on the Practice Instance
-- form and filled in by hand before anything downstream could use it.
--
-- The authority already publishes a frequency for each obligation. This
-- takes it as the default, and Resolve lets the owner change it.
--
-- WHICH OBLIGATION, WHEN THERE ARE SEVERAL
-- ----------------------------------------
-- A practice usually carries more than one obligation, and they need not
-- agree. The most frequent one wins: performing a monthly check also
-- satisfies a quarterly obligation, while the reverse leaves the monthly
-- one unmet. "Most frequent" is frequency_master.display_order, which is
-- seeded in ascending period order (Daily 1 ... Annual 6).
--
-- Event Driven, Continuous and Custom are ranked last and only chosen
-- when nothing periodic matched. They describe a trigger, not a period,
-- so treating them as "more frequent than Daily" because they sort after
-- it would be nonsense, and picking one as an instance's cadence when a
-- real period exists would silently drop that period.
--
-- FREQUENCIES ARE MATCHED BY NAME
-- -------------------------------
-- The published frequency is a GRAC_New.reference_option label; the
-- practice side picks from grac_practice.frequency_master. Two catalogs,
-- two IDENTITY sequences -- copying an id across would pick whatever
-- happens to share that number. Unmatched labels default nothing rather
-- than guessing, and the report at the end lists them.
--
-- Error codes 52660-52663. Depends on 139 (Configure), 140/141 (Resolve).
-- Rollback: 145_instance_default_frequency_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_practice_instance_configure','P') IS NULL
BEGIN
    RAISERROR('145: sp_practice_instance_configure is missing. Run 139 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- vw_pm_practice_default_frequency
--
-- One row per practice: the execution and assurance frequency its
-- obligations imply. Only obligations from a release the organization
-- subscribes to count -- the same rule the Resolve obligation list uses.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_practice_default_frequency
AS
    WITH reachable AS (
        SELECT DISTINCT
               p.practice_id,
               p.organization_id,
               orm.obligation_id
        FROM   grac_practice.practice p
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = p.organization_requirement_id
        LEFT   JOIN GRAC_New.requirement repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   GRAC_New.obligation_requirement_release_map orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                        WHERE s.organization_id = p.organization_id
                          AND s.release_id = orm.release_id
                          AND s.status = N'Active')
    ),
    -- Published labels, execution and assurance, mapped to the practice
    -- catalog by name.
    labelled AS (
        SELECT r.practice_id,
               N'Execution' AS Kind,
               COALESCE(ef.option_label, o.frequency_type) AS FrequencyLabel
        FROM   reachable r
        JOIN   GRAC_New.requirement_obligation o
               ON o.obligation_id = r.obligation_id AND o.status = N'Active'
        LEFT   JOIN GRAC_New.reference_option ef
               ON ef.reference_option_id = o.execution_frequency_id
        UNION ALL
        SELECT r.practice_id,
               N'Assurance' AS Kind,
               af.option_label AS FrequencyLabel
        FROM   reachable r
        JOIN   GRAC_New.obligation_assurance_spec spec
               ON spec.obligation_id = r.obligation_id AND spec.status = N'Active'
        JOIN   GRAC_New.reference_option af
               ON af.reference_option_id = spec.assurance_frequency_id
    ),
    matched AS (
        SELECT l.practice_id,
               l.Kind,
               fm.frequency_id,
               fm.frequency_name,
               fm.display_order,
               -- Periodic first; a trigger is only a fallback.
               CASE WHEN fm.frequency_name IN (N'Event Driven', N'Continuous', N'Custom')
                    THEN 1 ELSE 0 END AS IsNonPeriodic
        FROM   labelled l
        JOIN   grac_practice.frequency_master fm
               ON fm.frequency_name = l.FrequencyLabel
              AND fm.is_active = 1
        WHERE  NULLIF(LTRIM(RTRIM(ISNULL(l.FrequencyLabel, N''))), N'') IS NOT NULL
    ),
    ranked AS (
        SELECT practice_id, Kind, frequency_id, frequency_name,
               ROW_NUMBER() OVER (PARTITION BY practice_id, Kind
                                  ORDER BY IsNonPeriodic, display_order, frequency_id) AS rn
        FROM   matched
    )
    SELECT practice_id                                                     AS PracticeId,
           MAX(CASE WHEN Kind = N'Execution' THEN frequency_id   END)      AS ExecutionFrequencyId,
           MAX(CASE WHEN Kind = N'Execution' THEN frequency_name END)      AS ExecutionFrequency,
           MAX(CASE WHEN Kind = N'Assurance' THEN frequency_id   END)      AS AssuranceFrequencyId,
           MAX(CASE WHEN Kind = N'Assurance' THEN frequency_name END)      AS AssuranceFrequency
    FROM   ranked
    WHERE  rn = 1
    GROUP  BY practice_id;
GO

-- =====================================================================
-- sp_practice_instance_configure -- re-emitted with the frequency default
--
-- Signature and result set are unchanged from 139; only the INSERT gains
-- the two frequency columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_configure
    @organization_id BIGINT,
    @practice_id     BIGINT,
    @team_ids_json   NVARCHAR(MAX),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 52503, 'sp_practice_instance_configure: organization_id and practice_id are required.', 1;

    IF @team_ids_json IS NULL OR ISJSON(@team_ids_json) <> 1
        THROW 52504, 'sp_practice_instance_configure: team_ids_json must be a JSON array of team ids.', 1;

    DECLARE @practice_name NVARCHAR(300);
    SELECT @practice_name = practice_name
    FROM   grac_practice.practice
    WHERE  practice_id = @practice_id AND organization_id = @organization_id;

    IF @practice_name IS NULL
        THROW 52505, 'sp_practice_instance_configure: practice not found for this organization.', 1;

    DECLARE @team_type_id INT = (
        SELECT TOP 1 dependency_type_id
        FROM   grac_practice.dependency_type_master
        WHERE  dependency_type_code = N'TEAM' OR dependency_type_name = N'Team'
        ORDER  BY dependency_type_id);
    IF @team_type_id IS NULL
        THROW 52506, 'sp_practice_instance_configure: Team dependency type is missing.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52507, 'sp_practice_instance_configure: record status master data is missing.', 1;

    DECLARE @impl_status_id INT, @impl_status_name NVARCHAR(120);

    SELECT TOP 1 @impl_status_id = implementation_status_id, @impl_status_name = status_name
    FROM   grac_practice.implementation_status_master
    WHERE  is_active = 1
      AND (status_code = N'Not Implemented' OR status_name = N'Not Implemented')
    ORDER  BY implementation_status_id;

    IF @impl_status_id IS NULL
        SELECT TOP 1 @impl_status_id = implementation_status_id, @impl_status_name = status_name
        FROM   grac_practice.implementation_status_master
        WHERE  is_active = 1
        ORDER  BY display_order, implementation_status_id;

    IF @impl_status_id IS NULL
        THROW 52508, 'sp_practice_instance_configure: implementation status master data is missing.', 1;

    DECLARE @resolved_status_id INT = (
        SELECT TOP 1 resolution_status_id FROM grac_practice.dependency_resolution_status_master
        WHERE status_code = N'Resolved' ORDER BY resolution_status_id);
    IF @resolved_status_id IS NULL
        THROW 52509, 'sp_practice_instance_configure: Resolved dependency status is missing.', 1;

    DECLARE @criticality_id INT, @criticality_name NVARCHAR(80);

    SELECT TOP 1 @criticality_id = criticality_id, @criticality_name = criticality_name
    FROM   grac_practice.criticality_master
    WHERE  is_active = 1
      AND (criticality_code = N'Medium' OR criticality_name = N'Medium')
    ORDER  BY criticality_id;

    IF @criticality_id IS NULL
        SELECT TOP 1 @criticality_id = criticality_id, @criticality_name = criticality_name
        FROM   grac_practice.criticality_master
        WHERE  is_active = 1
        ORDER  BY display_order, criticality_id;

    IF @criticality_id IS NULL
        THROW 52511, 'sp_practice_instance_configure: criticality master data is missing.', 1;

    -- The published cadence, taken once for the whole batch: every
    -- instance of this practice starts from the same obligations.
    DECLARE @exec_freq_id INT, @exec_freq_name NVARCHAR(120),
            @assur_freq_id INT, @assur_freq_name NVARCHAR(120);

    SELECT @exec_freq_id    = ExecutionFrequencyId,
           @exec_freq_name  = ExecutionFrequency,
           @assur_freq_id   = AssuranceFrequencyId,
           @assur_freq_name = AssuranceFrequency
    FROM   grac_practice.vw_pm_practice_default_frequency
    WHERE  PracticeId = @practice_id;

    DECLARE @work TABLE (
        TeamId              BIGINT PRIMARY KEY,
        TeamName            NVARCHAR(200) NULL,
        ManagerId           BIGINT NULL,
        ManagerName         NVARCHAR(200) NULL,
        DepartmentId        BIGINT NULL,
        DepartmentName      NVARCHAR(200) NULL,
        Outcome             NVARCHAR(40) NOT NULL,
        PracticeInstanceId  BIGINT NULL,
        InstanceCode        NVARCHAR(100) NULL,
        InstanceName        NVARCHAR(300) NULL
    );

    INSERT INTO @work (TeamId, TeamName, ManagerId, ManagerName, DepartmentId, DepartmentName, Outcome)
    SELECT DISTINCT
           j.TeamId,
           t.team_name,
           CASE WHEN mgr.employee_id IS NOT NULL THEN t.team_manager_id END,
           mgr.employee_name,
           t.parent_department_id,
           d.department_name,
           CASE
             WHEN t.team_id IS NULL THEN N'TeamNotFound'
             WHEN EXISTS (
                 SELECT 1
                 FROM   grac_practice.practice_dependency_resolution r
                 JOIN   grac_practice.practice_instance pi
                        ON pi.practice_instance_id = r.practice_instance_id
                 WHERE  pi.practice_id           = @practice_id
                   AND  r.dependency_type_id     = @team_type_id
                   AND  r.resolved_dependency_id = t.team_id
                   AND  r.is_active              = 1
                   AND  pi.status                = N'Active')
                  THEN N'AlreadyConfigured'
             ELSE N'Pending'
           END
    FROM   OPENJSON(@team_ids_json) WITH (TeamId BIGINT '$') j
    LEFT   JOIN grac_practice.organization_team t
           ON t.team_id         = j.TeamId
          AND t.organization_id = @organization_id
          AND EXISTS (SELECT 1 FROM grac_practice.record_status_master rs
                       WHERE rs.record_status_id = t.record_status_id
                         AND (rs.status_code = N'ACTIVE' OR rs.status_name = N'Active'))
    LEFT   JOIN grac_practice.organization_employee mgr
           ON mgr.employee_id     = t.team_manager_id
          AND mgr.organization_id = t.organization_id
    LEFT   JOIN grac_practice.organization_department d
           ON d.department_id = t.parent_department_id;

    IF NOT EXISTS (SELECT 1 FROM @work)
        THROW 52510, 'sp_practice_instance_configure: no teams were supplied.', 1;

    BEGIN TRAN;

    DECLARE @team_id BIGINT, @team_name NVARCHAR(200), @manager_id BIGINT,
            @manager_name NVARCHAR(200), @department_id BIGINT, @department_name NVARCHAR(200),
            @code NVARCHAR(100), @name NVARCHAR(300), @next INT, @new_id BIGINT;

    SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(instance_code, 4, 20))), 0) + 1
    FROM   grac_practice.practice_instance WITH (UPDLOCK, HOLDLOCK)
    WHERE  organization_id = @organization_id
      AND  instance_code LIKE N'PR[_]%'
      AND  TRY_CONVERT(INT, SUBSTRING(instance_code, 4, 20)) IS NOT NULL;

    DECLARE team_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT TeamId, TeamName, ManagerId, ManagerName, DepartmentId, DepartmentName
        FROM   @work WHERE Outcome = N'Pending' ORDER BY TeamName;

    OPEN team_cursor;
    FETCH NEXT FROM team_cursor
        INTO @team_id, @team_name, @manager_id, @manager_name, @department_id, @department_name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @code = N'PR_' + FORMAT(@next, '000');
        WHILE EXISTS (SELECT 1 FROM grac_practice.practice_instance
                       WHERE organization_id = @organization_id AND instance_code = @code)
        BEGIN
            SET @next = @next + 1;
            SET @code = N'PR_' + FORMAT(@next, '000');
        END

        SET @name = LEFT(@practice_name + N'-' + @team_name, 300);

        INSERT grac_practice.practice_instance
            (practice_id, organization_id, instance_code, instance_name,
             primary_owner_id, primary_owner, department_id, department,
             execution_frequency_id, assurance_frequency_id,
             frequency_id, frequency_type,
             assurance_mode, criticality, implementation_status, implementation_status_id,
             status, record_status_id, entered_by)
        VALUES
            (@practice_id, @organization_id, @code, @name,
             @manager_id, @manager_name, @department_id, @department_name,
             @exec_freq_id, @assur_freq_id,
             -- The legacy pair is kept in step with execution so the older
             -- reads that still use frequency_id do not disagree with the
             -- newer ones that use execution_frequency_id.
             @exec_freq_id, @exec_freq_name,
             N'Manual', @criticality_name, @impl_status_name, @impl_status_id,
             N'Active', @active_record_status_id, @actor);

        SET @new_id = SCOPE_IDENTITY();

        INSERT grac_practice.practice_instance_dependency
            (organization_id, practice_instance_id, dependency_type_id, dependency_type,
             dependency_name, dependency_reference_id, dependency_source_type,
             owner_name, criticality_id, criticality, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @new_id, @team_type_id, N'Team',
             @team_name, @team_id, N'Team',
             @manager_name, @criticality_id, @criticality_name, N'Active',
             @active_record_status_id, @actor);

        INSERT grac_practice.practice_dependency_resolution
            (organization_id, practice_instance_id, dependency_type_id, dependency_category,
             resolved_dependency_id, resolved_dependency_name, resolution_status_id,
             resolution_status, resolution_owner_id, resolution_dt, is_active,
             record_status_id, entered_by)
        VALUES
            (@organization_id, @new_id, @team_type_id, N'Team',
             @team_id, @team_name, @resolved_status_id,
             N'Resolved', @manager_id, SYSUTCDATETIME(), 1,
             @active_record_status_id, @actor);

        UPDATE @work
           SET Outcome            = N'Created',
               PracticeInstanceId = @new_id,
               InstanceCode       = @code,
               InstanceName       = @name
         WHERE TeamId = @team_id;

        SET @next = @next + 1;

        FETCH NEXT FROM team_cursor
            INTO @team_id, @team_name, @manager_id, @manager_name, @department_id, @department_name;
    END

    CLOSE team_cursor;
    DEALLOCATE team_cursor;

    COMMIT TRAN;

    SELECT TeamId                                      AS TeamId,
           TeamName                                    AS TeamName,
           Outcome                                     AS Outcome,
           PracticeInstanceId                          AS PracticeInstanceId,
           InstanceCode                                AS InstanceCode,
           InstanceName                                AS InstanceName,
           ManagerName                                 AS OwnerName,
           CAST(CASE WHEN ManagerId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasOwner
    FROM   @work
    ORDER  BY CASE Outcome WHEN N'Created' THEN 0 WHEN N'AlreadyConfigured' THEN 1 ELSE 2 END,
              TeamName;
END
GO

-- =====================================================================
-- sp_resolve_instance_frequency_save
--
-- Lets the owner change what Configure defaulted. Scoped to the instance
-- and, for a non-admin, to the instance they own -- the same test
-- sp_resolve_instance_detail applies, so the workspace cannot be used to
-- edit somebody else's instance by changing a number in the address bar.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_frequency_save
    @practice_instance_id   BIGINT,
    @execution_frequency_id INT    = NULL,
    @assurance_frequency_id INT    = NULL,
    @caller_employee_id     BIGINT = NULL,
    @is_admin               BIT    = 0,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52660, 'sp_resolve_instance_frequency_save: practice_instance_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                    WHERE practice_instance_id = @practice_instance_id)
        THROW 52661, 'sp_resolve_instance_frequency_save: instance not found.', 1;

    IF @is_admin = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                        WHERE practice_instance_id = @practice_instance_id
                          AND primary_owner_id     = @caller_employee_id)
        THROW 52662, 'sp_resolve_instance_frequency_save: this practice instance belongs to another owner.', 1;

    IF (@execution_frequency_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                         WHERE frequency_id = @execution_frequency_id AND is_active = 1))
       OR (@assurance_frequency_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                         WHERE frequency_id = @assurance_frequency_id AND is_active = 1))
        THROW 52663, 'sp_resolve_instance_frequency_save: that frequency does not exist.', 1;

    DECLARE @exec_name NVARCHAR(120) = (
        SELECT frequency_name FROM grac_practice.frequency_master
        WHERE frequency_id = @execution_frequency_id);

    UPDATE grac_practice.practice_instance
       SET execution_frequency_id = @execution_frequency_id,
           assurance_frequency_id = @assurance_frequency_id,
           -- Kept in step, for the same reason Configure sets it.
           frequency_id           = @execution_frequency_id,
           frequency_type         = COALESCE(@exec_name, frequency_type),
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Frequency saved.' AS Message,
           ef.frequency_name AS ExecutionFrequency,
           af.frequency_name AS AssuranceFrequency
    FROM   grac_practice.practice_instance pi
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- Backfill: instances Configure already created have no frequency.
-- Only fills what is empty; anything set by hand is left alone.
-- =====================================================================
UPDATE pi
   SET execution_frequency_id = COALESCE(pi.execution_frequency_id, df.ExecutionFrequencyId),
       assurance_frequency_id = COALESCE(pi.assurance_frequency_id, df.AssuranceFrequencyId),
       frequency_id           = COALESCE(pi.frequency_id, df.ExecutionFrequencyId),
       frequency_type         = COALESCE(pi.frequency_type, df.ExecutionFrequency),
       updated_by             = 'seed-145',
       updated_dt             = SYSUTCDATETIME()
FROM   grac_practice.practice_instance pi
JOIN   grac_practice.vw_pm_practice_default_frequency df ON df.PracticeId = pi.practice_id
WHERE  pi.status = N'Active'
  AND (pi.execution_frequency_id IS NULL OR pi.assurance_frequency_id IS NULL);
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'default frequency view created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_practice_default_frequency','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'configure sets the frequency',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_instance_configure'))
                 LIKE '%vw_pm_practice_default_frequency%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'frequency can be changed in Resolve',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_frequency_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- What each practice will default to.
SELECT df.PracticeId          AS PracticeId,
       p.practice_code        AS PracticeCode,
       df.ExecutionFrequency  AS ExecutionFrequency,
       df.AssuranceFrequency  AS AssuranceFrequency
FROM   grac_practice.vw_pm_practice_default_frequency df
JOIN   grac_practice.practice p ON p.practice_id = df.PracticeId
ORDER  BY df.PracticeId;

-- Published frequency labels with no match in frequency_master. These
-- default nothing; add the name to grac_practice.frequency_master to
-- have it picked up.
SELECT DISTINCT COALESCE(ef.option_label, o.frequency_type) AS UnmatchedFrequencyLabel
FROM   GRAC_New.requirement_obligation o
LEFT   JOIN GRAC_New.reference_option ef ON ef.reference_option_id = o.execution_frequency_id
WHERE  o.status = N'Active'
  AND  NULLIF(LTRIM(RTRIM(COALESCE(ef.option_label, o.frequency_type, N''))), N'') IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master fm
                    WHERE fm.frequency_name = COALESCE(ef.option_label, o.frequency_type)
                      AND fm.is_active = 1)
ORDER  BY UnmatchedFrequencyLabel;

-- Instances still without a frequency after the backfill: their practice
-- has no obligation frequency that matched.
SELECT pi.practice_instance_id AS PracticeInstanceId,
       pi.instance_code        AS InstanceCode,
       pi.instance_name        AS InstanceName
FROM   grac_practice.practice_instance pi
WHERE  pi.status = N'Active'
  AND  pi.execution_frequency_id IS NULL
ORDER  BY pi.practice_instance_id;

PRINT '145 Instances now default to their obligations frequency; Resolve can change it.';
GO
