-- =====================================================================
-- 215 Risk Centre — treatment task, opt-in  (BRD §22)  Phase B
--
-- WHAT §22 ACTUALLY SAYS
-- ----------------------
-- "Risk registration itself shall not automatically imply that a
-- treatment task exists. Once a risk has been registered, the
-- organisation MAY decide that treatment actions are required. Such
-- actions shall be capable of being created as tasks in Task Centre ...
-- This maintains the separation between: Risk Identification -> Risk
-- Registration -> Risk Treatment."
--
-- Two requirements pulling in opposite directions, and both must hold:
--   * registration must NOT create a task;
--   * creating a task from a registered risk must be easy.
--
-- WHY THIS IS A SEPARATE PROCEDURE AND NOT A FLAG ON REGISTER
-- -----------------------------------------------------------
-- The obvious implementation is @raise_task_candidate BIT = 0 on
-- sp_risk_candidate_register. It was rejected for two reasons.
--
--  1. It would mean re-emitting the whole register procedure a THIRD
--     time — 206 wrote it, 212 rewrote it for the approval gate, and 215
--     would rewrite it again. Three copies of one body across three
--     migrations is how a schema stops being reviewable.
--
--  2. It reads the requirement backwards. §22 puts the decision AFTER
--     registration ("once a risk has been registered, the organisation
--     may decide"). A checkbox on the registration form makes it part of
--     registration; a separate action on the registered risk makes it
--     what the BRD describes. It also works for risks registered
--     yesterday, which a checkbox never can.
--
-- So: one new procedure, callable from the Risk Register row menu, and
-- nothing in 204-207 or 212-214 is modified.
--
-- THE SOURCE-COLLISION PROBLEM, AND WHY 'RiskRegister' EXISTS
-- -----------------------------------------------------------
-- 199 already raises Task Candidates with
-- (source_type_code = 'Risk', source_record_id = risk_candidate_id).
-- If register-raised treatment tasks reused 'Risk' with a
-- risk_register_id, candidate #5 and registered risk #5 would be the
-- same key — the Related Tasks panel on either screen would show the
-- other one's work.
--
-- Widening the vocabulary by one value is the honest fix:
--
--   Risk          -> source_record_id is a risk_candidate_id  (199, unchanged)
--   RiskRegister  -> source_record_id is a risk_register_id   (new)
--
-- The CHECK constraints on practice_task (192) and task_candidate (197)
-- are widened additively. Widening a CHECK can only ever admit more
-- rows, so no existing row and no existing caller is affected.
--
-- CONTENTS
--   1. Widen the two source_type_code CHECKs
--   2. sp_risk_treatment_task_raise
--   3. sp_risk_treatment_task_list
--
-- ERROR CODE RANGE: 56380-56399
-- Rollback: database/215_risk_treatment_task_optin_rollback.sql
-- Depends:  192, 197, 198 (Task Centre v2), 205, 206
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (215): risk_register missing — run 205 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_task_candidate_create','P') IS NULL
BEGIN PRINT 'ABORT (215): sp_task_candidate_create missing — run 198 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('215_risk_treatment_task_optin: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Widen the source vocabulary by one value
--
-- Additive only. A CHECK that admits more values cannot invalidate a
-- row that already satisfied the narrower one.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_practice_task_source_type')
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
GO

ALTER TABLE grac_practice.practice_task WITH NOCHECK
    ADD CONSTRAINT ck_pm_practice_task_source_type
        CHECK (source_type_code IS NULL
            OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                    N'RiskRegister',                 -- NEW in 215
                                    N'ContinuousAssurance', N'EventAssurance',
                                    N'Custom'));
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_task_candidate_source_type')
    ALTER TABLE grac_practice.task_candidate DROP CONSTRAINT ck_pm_task_candidate_source_type;
GO

ALTER TABLE grac_practice.task_candidate WITH NOCHECK
    ADD CONSTRAINT ck_pm_task_candidate_source_type
        CHECK (source_type_code IN (N'Gap', N'Exception', N'Risk',
                                    N'RiskRegister',                 -- NEW in 215
                                    N'ContinuousAssurance', N'EventAssurance',
                                    N'Custom'));
GO

-- =====================================================================
-- 2. sp_risk_treatment_task_raise   (BRD §22)
--
-- "Such actions shall be capable of being created as tasks in Task
-- Centre, with: Task Owner, Priority, SLA, Due Date, Parent/Child Tasks
-- where applicable, Relationship to the Risk."
--
-- Every one of those is Task Centre's to own — owner ladder, SLA
-- derivation, priority governance — so this procedure supplies context
-- and DELEGATES. It does not compute a due date, and it does not create
-- a practice_task: it raises a Task CANDIDATE, which is Task Centre's
-- own gate for "does this work have an owner, an urgency and a time
-- expectation?" (197). Registering a risk does not answer those
-- questions, so pretending it does would push an unvalidated task
-- straight into somebody's queue.
--
-- ONE SOURCE, MANY TASKS (Task Centre BRD §15)
-- --------------------------------------------
-- A risk legitimately needs several treatment actions. So:
--   * the first raise passes dedupe key 'RISK_TREATMENT', making it
--     idempotent — clicking twice does not create two identical
--     candidates;
--   * @allow_additional = 1 passes a NULL dedupe key, which is 197's
--     documented path for a human deliberately adding a second, different
--     action.
--
-- Priority comes from the risk's own inherent rating. §5 of the Task
-- Centre BRD forbids re-doing upstream analysis, and urgency is upstream's
-- call — the candidate stage only confirms it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_task_raise
    @risk_register_id     BIGINT,
    @task_title           NVARCHAR(250) = NULL,
    @task_description     NVARCHAR(MAX) = NULL,
    @proposed_priority    NVARCHAR(30)  = NULL,   -- NULL = derive from the rating
    @owner_employee_id    BIGINT        = NULL,   -- NULL = Task Centre's owner ladder
    @allow_additional     BIT           = 0,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56380, 'sp_risk_treatment_task_raise: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @risk_number NVARCHAR(60), @risk_title NVARCHAR(300),
            @statement NVARCHAR(1000), @rating NVARCHAR(30), @status NVARCHAR(30),
            @owner BIGINT, @consequence NVARCHAR(MAX),
            @linked_practice_id BIGINT, @linked_control_id BIGINT;

    SELECT @org_id      = r.organization_id,
           @risk_number = r.risk_number,
           @risk_title  = r.risk_title,
           @statement   = r.risk_statement,
           @rating      = r.inherent_rating_code,
           @status      = r.status_code,
           @owner       = r.risk_owner_employee_id,
           @consequence = r.potential_consequence,
           @linked_practice_id = r.linked_practice_id,
           @linked_control_id  = r.linked_control_id
      FROM grac_practice.risk_register r
     WHERE r.risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56381, 'sp_risk_treatment_task_raise: risk not found.', 1;

    -- Treating a risk that has been closed or retired is not a decision
    -- anybody meant to make; it is almost always the wrong row.
    IF @status IN (N'Closed', N'Retired')
        THROW 56382, 'sp_risk_treatment_task_raise: this risk is closed or retired — reopen it before raising treatment work.', 1;

    -- The four-level rating vocabulary coincides with task priority.
    -- Anything else lands on Medium rather than failing the raise — the
    -- validator confirms priority anyway, which is the point of the
    -- candidate stage.
    DECLARE @priority NVARCHAR(30) =
        COALESCE(NULLIF(@proposed_priority, N''),
                 CASE WHEN @rating IN (N'Low', N'Medium', N'High', N'Critical')
                      THEN @rating ELSE N'Medium' END);
    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    DECLARE @title NVARCHAR(250) =
        COALESCE(NULLIF(LTRIM(RTRIM(@task_title)), N''),
                 LEFT(CONCAT(N'Risk treatment: ', @risk_title), 250));

    DECLARE @description NVARCHAR(MAX) =
        COALESCE(@task_description,
                 CONCAT(N'Treatment action for ', @risk_number, N'.', CHAR(13), CHAR(10),
                        N'Risk statement: ', ISNULL(@statement, N''),
                        CASE WHEN @consequence IS NULL THEN N''
                             ELSE CONCAT(CHAR(13), CHAR(10), N'Potential consequence: ', @consequence) END));

    DECLARE @source_ref NVARCHAR(200) = @risk_number;

    -- See the header: NULL dedupe key is 197's documented path for a
    -- deliberate second action on the same source.
    DECLARE @dedupe NVARCHAR(200) =
        CASE WHEN ISNULL(@allow_additional, 0) = 1 THEN NULL ELSE N'RISK_TREATMENT' END;

    -- Precomputed because T-SQL will not accept an expression as an EXEC
    -- parameter value — only a variable, a literal or NULL. The caller's
    -- choice wins; the risk's own owner is the fallback; NULL hands the
    -- question to Task Centre's owner ladder.
    DECLARE @effective_owner BIGINT = COALESCE(@owner_employee_id, @owner);

    DECLARE @candidate_id BIGINT, @created BIT;

    -- NOT wrapped in a transaction with anything else, and deliberately
    -- allowed to throw. Unlike 199's raise — which sat inside a
    -- governance decision that had to stay durable — this procedure IS
    -- the whole action. If it fails, nothing else was riding on it, and
    -- the caller should see the failure rather than a silent PRINT.
    EXEC grac_practice.sp_task_candidate_create
         @organization_id            = @org_id,
         @source_type_code           = N'RiskRegister',
         @source_record_id           = @risk_register_id,
         @candidate_title            = @title,
         @candidate_description      = @description,
         @source_reference           = @source_ref,
         @source_dedupe_key          = @dedupe,
         @task_type_code             = N'RiskDriven',
         @explicit_owner_employee_id = @effective_owner,
         @proposed_priority          = @priority,
         @linked_practice_id         = @linked_practice_id,
         @linked_control_id          = @linked_control_id,
         @actor_employee_id          = @actor_employee_id,
         @caller_display_name        = @caller_display_name,
         @task_candidate_id          = @candidate_id OUTPUT,
         @created                    = @created      OUTPUT;

    -- §20 audit: the register's own trail records that treatment was
    -- decided on, and by whom. Without this, "who decided to treat this
    -- risk?" would only be answerable from Task Centre.
    INSERT INTO grac_practice.risk_register_history
        (risk_register_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@risk_register_id, N'TreatmentRaised', @status, @status,
         CONCAT(N'Treatment task candidate ', CAST(@candidate_id AS NVARCHAR(20)),
                CASE WHEN ISNULL(@created, 0) = 1 THEN N' raised' ELSE N' already existed' END,
                N' (priority ', @priority, N').'),
         @actor_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());

    SELECT @risk_register_id  AS RiskRegisterId,
           @candidate_id      AS TaskCandidateId,
           ISNULL(@created,0) AS Created,
           @priority          AS ProposedPriority;
END;
GO

-- =====================================================================
-- 3. sp_risk_treatment_task_list   (BRD §22 "Relationship to the Risk")
--
-- Reuses sp_task_source_items (199) rather than re-querying Task Centre,
-- so the Risk Register detail shows candidates AND tasks exactly as the
-- Gap and Observation screens do — one definition of "related work"
-- across GRAC.
--
-- Both source keys are returned in one list because a stream-originated
-- risk can have treatment work from BOTH eras: 'Risk' rows raised by
-- 199's legacy Accept against the candidate, and 'RiskRegister' rows
-- raised here. Hiding either would tell the risk owner that work does
-- not exist when it does.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_task_list
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56390, 'sp_risk_treatment_task_list: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @candidate_id BIGINT;
    SELECT @org_id = organization_id, @candidate_id = risk_candidate_id
      FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL
        THROW 56391, 'sp_risk_treatment_task_list: risk not found.', 1;

    IF OBJECT_ID('grac_practice.sp_task_source_items','P') IS NULL
    BEGIN
        -- Task Centre's read layer is not installed. Return the shape,
        -- empty, so the panel renders "no related work" instead of the
        -- screen failing.
        SELECT CAST(NULL AS NVARCHAR(20))  AS ItemKind,
               CAST(NULL AS BIGINT)        AS ItemId,
               CAST(NULL AS NVARCHAR(60))  AS ItemNumber,
               CAST(NULL AS NVARCHAR(250)) AS Title,
               CAST(NULL AS NVARCHAR(30))  AS StatusCode,
               CAST(NULL AS NVARCHAR(120)) AS StatusName,
               CAST(NULL AS BIGINT)        AS OwnerEmployeeId,
               CAST(NULL AS NVARCHAR(240)) AS OwnerName,
               CAST(NULL AS NVARCHAR(30))  AS Priority,
               CAST(NULL AS DATETIME2)     AS DueAt,
               CAST(NULL AS NVARCHAR(30))  AS SlaStatusCode,
               CAST(NULL AS BIT)           AS IsChild,
               CAST(NULL AS BIGINT)        AS ParentTaskId,
               CAST(NULL AS INT)           AS ChildCount,
               CAST(NULL AS DATETIME2)     AS CompletedDt,
               CAST(NULL AS DATETIME2)     AS RaisedDt
         WHERE 1 = 0;
        RETURN;
    END

    CREATE TABLE #items(
        ItemKind NVARCHAR(20), ItemId BIGINT, ItemNumber NVARCHAR(60),
        Title NVARCHAR(250), StatusCode NVARCHAR(30), StatusName NVARCHAR(120),
        OwnerEmployeeId BIGINT, OwnerName NVARCHAR(240), Priority NVARCHAR(30),
        DueAt DATETIME2, SlaStatusCode NVARCHAR(30), IsChild BIT,
        ParentTaskId BIGINT, ChildCount INT, CompletedDt DATETIME2, RaisedDt DATETIME2
    );

    INSERT INTO #items
        EXEC grac_practice.sp_task_source_items
             @source_type_code = N'RiskRegister',
             @source_record_id = @risk_register_id,
             @organization_id  = @org_id;

    -- Legacy era: work raised against the candidate by 199's Accept.
    IF @candidate_id IS NOT NULL
        INSERT INTO #items
            EXEC grac_practice.sp_task_source_items
                 @source_type_code = N'Risk',
                 @source_record_id = @candidate_id,
                 @organization_id  = @org_id;

    SELECT * FROM #items ORDER BY ItemKind DESC, IsChild, RaisedDt;
    DROP TABLE #items;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '215 procedures present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_treatment_task_raise','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_task_list','P')   IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'RiskRegister admitted by both source CHECKs' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_practice_task_source_type'
                            AND definition LIKE '%RiskRegister%')
             AND EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_task_candidate_source_type'
                            AND definition LIKE '%RiskRegister%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'register proc still has NO automatic task raise (BRD 22)' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.sql_modules
                              WHERE object_id = OBJECT_ID('grac_practice.sp_risk_candidate_register')
                                AND definition LIKE '%sp_task_candidate_create%')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '215 Risk treatment task opt-in installed.';
PRINT 'BRD 22 holds: registration raises nothing. Call sp_risk_treatment_task_raise';
PRINT '      from the Risk Register when the organisation decides treatment is required.';
GO

SET NOEXEC OFF;
GO
