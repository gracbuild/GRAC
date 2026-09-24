-- =====================================================================
-- tool_seed_review_pending_risks.sql   (v2)
--
-- NOT A MIGRATION. Unnumbered on purpose. Creates test risks and leaves
-- them PENDING REVIEW -- on the Review Risk tab, ready to be reviewed.
--
-- Run it again whenever you have worked through the review list and want
-- a fresh batch.
--
-- ---------------------------------------------------------------------
-- TWO THINGS FIXED SINCE v1
-- ---------------------------------------------------------------------
-- 1. THE LIKELIHOOD / IMPACT PAIR IS TAKEN FROM THE MATRIX.
--    v1 cycled the two scales independently, which pairs them
--    diagonally -- and sp_risk_rating_resolve THROWS 56042 for any pair
--    the organisation's risk matrix has no cell for. On a matrix that is
--    not fully populated, every single risk failed and the script
--    reported it in a column that was easy to miss.
--
--    v2 selects the pair FROM risk_matrix_cell, so a cell is guaranteed
--    to exist. It also spreads the batch across different rating codes,
--    which makes the Review tab's rating filter worth testing.
--
-- 2. IT VERIFIES ITSELF.
--    Section 6 calls sp_risk_review_due_list -- the procedure the Review
--    Risk page itself calls -- and prints what the page will show. If
--    those rows are there, the page has them; no need to alt-tab to find
--    out.
--
-- ---------------------------------------------------------------------
-- v3: NO INSERT ... EXEC. THIS IS WHY.
-- ---------------------------------------------------------------------
-- v2 captured each procedure's result set with INSERT ... EXEC, to stop
-- it streaming to the client. That is illegal here, and it failed every
-- risk with:
--
--     "Cannot use the ROLLBACK statement within an INSERT-EXEC statement."
--
-- SQL Server forbids a procedure called inside INSERT ... EXEC from
-- issuing ROLLBACK -- and sp_risk_custom_create, sp_risk_acceptance_save
-- and sp_risk_register_status_set ALL do, in their CATCH blocks. So the
-- first genuine failure inside the procedure hit its own ROLLBACK, that
-- raised this error instead, and the REAL reason was thrown away.
--
-- v3 therefore uses a plain EXEC and finds the new risk by its title,
-- which is made unique per run by @run_tag. The procedures' own result
-- sets do reach the client -- in SSMS you will see a few extra grids per
-- risk. That is cosmetic noise, and far better than swallowing errors.
--
-- (The proper fix for the product's own bulk procedures is
-- @suppress_result, the parameter sp_risk_analysis_save and
-- sp_risk_treatment_option_set already carry. A script does not need it.)
--
-- ---------------------------------------------------------------------
-- IT USES THE REAL PROCEDURES, NOT INSERTS
-- ---------------------------------------------------------------------
--     sp_risk_custom_create        creates the risk AND completes its
--                                  analysis in one call (BRD 4B route B)
--     sp_risk_treatment_option_set 'Tolerate'
--     sp_risk_acceptance_save      accepts it, future date + cadence
--
-- Hand-written INSERTs would produce rows the product believes cannot
-- exist -- no risk_number, no analysis version, no rating, no history.
--
-- WHY TOLERATE: it is the short route to acceptance. Treat / Transfer /
-- Terminate each need a treatment task raised AND closed AND a residual
-- analysis first.
--
-- THE ONE DIRECT WRITE: after acceptance the review date is in the
-- future (56602 refuses anything else), so the script backdates
-- next_review_date. There is no procedure for that because in
-- production the thing that makes a review due is time passing.
--
-- ---------------------------------------------------------------------
-- SAFETY
-- ---------------------------------------------------------------------
--   @commit = 0 by default -- a plain run creates NOTHING.
--   Seeded titles carry @title_prefix so they are obvious and findable.
--   These cannot be cleanly DELETEd afterwards (a registered risk owns
--   analysis and history rows) -- section 7 shows how to Retire them,
--   which is the product's own way to remove a risk.
--   Run on dev or test, not production.
-- =====================================================================
SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
DECLARE @organization_id  BIGINT  = NULL;         -- <<< REQUIRED
DECLARE @how_many         INT     = 5;
DECLARE @days_overdue     INT     = 3;            -- 0 = due today
DECLARE @owner_employee_id BIGINT = NULL;         -- NULL = pick one from the org
DECLARE @title_prefix     NVARCHAR(20) = N'[SEED]';
DECLARE @commit           BIT     = 0;            -- <<< 0 = show only. 1 = create.

DECLARE @today    DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @due_date DATE = DATEADD(DAY, -ABS(@days_overdue), @today);
DECLARE @future   DATE = DATEADD(YEAR, 1, @today);
DECLARE @actor    NVARCHAR(100) = N'seed-script';

-- ---------------------------------------------------------------------
-- 1. Organisation
-- ---------------------------------------------------------------------
PRINT '=== 1. Organisation ===';

IF @organization_id IS NULL
BEGIN
    PRINT '*** STOP: set @organization_id at the top of this script.';
    SELECT TOP (20) organization_id, organization_name, status
      FROM grac_practice.organization
     ORDER BY organization_id;
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM grac_practice.organization
                WHERE organization_id = @organization_id)
BEGIN
    PRINT '*** STOP: no organisation with that id.';
    RETURN;
END

-- The risk matrix is seeded on demand by 206 when the scoring options
-- are first read. Doing it here too means a brand-new organisation can
-- be seeded without opening the UI first.
IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell
                WHERE organization_id = @organization_id)
BEGIN
    PRINT 'No risk matrix for this organisation -- seeding the 204 defaults.';
    EXEC grac_practice.sp_risk_scoring_seed_default
         @organization_id = @organization_id, @caller_display_name = @actor;
END

-- ---------------------------------------------------------------------
-- 2. Valid likelihood / impact pairs, straight from the matrix
--
-- Joining the masters to risk_matrix_cell guarantees every pair below
-- resolves to a rating. This is the fix for 56042.
--
-- One pair per rating_code first (ordered by score, so the batch spans
-- Low..Critical rather than five copies of one rating), then whatever
-- else the matrix offers.
-- ---------------------------------------------------------------------
DECLARE @pairs TABLE (
    rn              INT IDENTITY(1,1),
    likelihood_code NVARCHAR(60),
    impact_code     NVARCHAR(60),
    rating_code     NVARCHAR(30)
);

INSERT INTO @pairs (likelihood_code, impact_code, rating_code)
SELECT p.likelihood_code, p.impact_code, p.rating_code
  FROM (
        SELECT l.likelihood_code,
               i.impact_code,
               m.rating_code,
               ROW_NUMBER() OVER (PARTITION BY m.rating_code
                                  ORDER BY m.likelihood_value, m.impact_value) AS per_rating,
               ISNULL(m.rating_score, 0) AS score
          FROM grac_practice.risk_matrix_cell m
          JOIN grac_practice.risk_likelihood_master l
            ON l.organization_id = m.organization_id
           AND l.level_value     = m.likelihood_value
           AND l.status          = N'Active'
          JOIN grac_practice.risk_impact_master i
            ON i.organization_id = m.organization_id
           AND i.level_value     = m.impact_value
           AND i.status          = N'Active'
         WHERE m.organization_id = @organization_id
       ) p
 ORDER BY p.per_rating, p.score DESC;

DECLARE @pair_count INT = (SELECT COUNT(*) FROM @pairs);

DECLARE @cat NVARCHAR(60), @emp BIGINT, @freq_id INT,
        @threat_id INT, @vuln_id INT;

-- REQUIRED SINCE 216, and the reason v1-v3 created nothing:
-- sp_risk_register_insert refuses an assessment with no threat (56410)
-- or no vulnerability (56411). A risk statement, a score and an owner
-- are not a complete assessment on their own.
--
-- Filtered on status_id = 1 only, because that is exactly what
-- sp_risk_analysis_save validates (56402 / 56404). It does not scope
-- these by organisation, and the organization_id column on these tables
-- only exists once 285 is applied -- so filtering on it would break this
-- script on any database that has not run 285.
-- id 0 is the "Others" row, and choosing it obliges the caller to supply
-- a description (56403 / 56405). Ordering it LAST picks a real threat
-- wherever one exists; the descriptions below cover the case where 0 is
-- all the master has.
SELECT TOP (1) @threat_id = threat_id
  FROM grac_practice.threat_master
 WHERE status_id = 1
 ORDER BY CASE WHEN threat_id = 0 THEN 1 ELSE 0 END, threat_id;

SELECT TOP (1) @vuln_id = vulnerability_id
  FROM grac_practice.vulnerability_master
 WHERE status_id = 1
 ORDER BY CASE WHEN vulnerability_id = 0 THEN 1 ELSE 0 END, vulnerability_id;

-- NULL unless "Others" was chosen, which is exactly when the procedure
-- demands one.
DECLARE @threat_desc NVARCHAR(MAX) =
        CASE WHEN @threat_id = 0 THEN N'Seeded test threat (Others).' END;
DECLARE @vuln_desc   NVARCHAR(MAX) =
        CASE WHEN @vuln_id   = 0 THEN N'Seeded test vulnerability (Others).' END;

SELECT TOP (1) @cat = category_code
  FROM grac_practice.risk_category_master
 WHERE organization_id = @organization_id AND status = N'Active'
 ORDER BY display_order, category_code;

SELECT @emp = COALESCE(@owner_employee_id,
                       (SELECT TOP (1) employee_id
                          FROM grac_practice.organization_employee
                         WHERE organization_id = @organization_id
                         ORDER BY employee_id));

SELECT TOP (1) @freq_id = frequency_id
  FROM grac_practice.frequency_master
 WHERE is_active = 1 AND is_custom = 0 AND frequency_value IS NOT NULL
 ORDER BY CASE WHEN frequency_code = N'Annual' THEN 0 ELSE 1 END, display_order;

PRINT '';
PRINT '=== 2. What this organisation offers ===';

SELECT @cat        AS CategoryCode,
       @emp        AS OwnerEmployeeId,
       @pair_count AS UsableMatrixPairs,
       @freq_id    AS ReviewFrequencyId,
       @threat_id  AS ThreatId,
       @vuln_id    AS VulnerabilityId,
       CASE WHEN @cat IS NULL       THEN 'NO ACTIVE RISK CATEGORY'
            WHEN @emp IS NULL       THEN 'NO EMPLOYEE IN THIS ORG'
            WHEN @pair_count = 0    THEN 'NO USABLE MATRIX PAIR'
            WHEN @threat_id IS NULL THEN 'NO ACTIVE THREAT'
            WHEN @vuln_id IS NULL   THEN 'NO ACTIVE VULNERABILITY'
            ELSE 'inputs look OK' END AS InputCheck;

IF @cat IS NULL OR @emp IS NULL OR @pair_count = 0
   OR @threat_id IS NULL OR @vuln_id IS NULL
BEGIN
    -- Repeated as a grid, not only as PRINT: PRINT lands in SSMS's
    -- Messages tab, which is easy to miss when you are looking at
    -- Results.
    SELECT 'STOPPED' AS Result,
           'This organisation is not configured enough to seed risks -- see InputCheck above.' AS Reason;
    RETURN;
END

SELECT rn AS PairNo, likelihood_code AS Likelihood,
       impact_code AS Impact, rating_code AS Rating
  FROM @pairs WHERE rn <= @how_many ORDER BY rn;

-- ---------------------------------------------------------------------
-- 3. Plan
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 3. Plan ===';
PRINT CONCAT('Create ', @how_many, ' risk(s) -> Tolerate -> accept (review date ',
             CONVERT(NVARCHAR(10), @future, 23), ') -> backdate to ',
             CONVERT(NVARCHAR(10), @due_date, 23), ' so they are PENDING REVIEW.');

IF @commit = 0
BEGIN
    PRINT '';
    PRINT '**********************************************************';
    PRINT '*  DRY RUN. NOTHING WAS CREATED.                         *';
    PRINT '*  Set  @commit = 1  near the top, then run again.       *';
    PRINT '**********************************************************';
    RETURN;
END

-- ---------------------------------------------------------------------
-- 4. Create
--
-- Every inner procedure that returns a result set is captured with
-- INSERT ... EXEC or silenced with @suppress_result, so the batch emits
-- the reports below and nothing else.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 4. Creating ===';

DECLARE @made TABLE (
    Seq INT IDENTITY(1,1), RiskRegisterId BIGINT, RiskNumber NVARCHAR(60),
    Outcome NVARCHAR(20), Reason NVARCHAR(400));

-- Makes each run's titles unique, so the lookup after the create can
-- find exactly the risk this iteration made -- and so running the script
-- twice does not produce two risks the lookup cannot tell apart.
DECLARE @run_tag NVARCHAR(20) = FORMAT(SYSUTCDATETIME(), 'MMdd-HHmmss');

DECLARE @i INT = 1, @rid BIGINT, @rnum NVARCHAR(60),
        @lc NVARCHAR(60), @ic NVARCHAR(60), @rate NVARCHAR(30),
        @title NVARCHAR(300);

PRINT CONCAT('Run tag: ', @run_tag, ' (appears in every seeded title)');

WHILE @i <= @how_many
BEGIN
    SET @rid = NULL; SET @rnum = NULL;

    -- Cycle the matrix pairs if more risks were asked for than the
    -- matrix has distinct cells.
    SELECT @lc = likelihood_code, @ic = impact_code, @rate = rating_code
      FROM @pairs WHERE rn = ((@i - 1) % @pair_count) + 1;

    SET @title = CONCAT(@title_prefix, N' ', @run_tag, N' #', @i, N' (', @rate, N')');

    BEGIN TRY
        -- Plain EXEC. NOT INSERT ... EXEC -- see the header: this
        -- procedure rolls back inside its own CATCH, which INSERT ... EXEC
        -- forbids, and that masked every real error in v2.
        EXEC grac_practice.sp_risk_custom_create
             @organization_id        = @organization_id,
             @risk_title             = @title,
             @risk_statement         = N'Seeded by tool_seed_review_pending_risks.sql to exercise the review and acceptance flow.',
             @risk_category_code     = @cat,
             @likelihood_code        = @lc,
             @impact_code            = @ic,
             @risk_owner_employee_id = @emp,
             @analyst_remarks        = N'Test data. Safe to retire.',
             @created_by_employee_id = @emp,
             @caller_display_name    = @actor,
             -- Required since 216 (56410 / 56411). Omitting these is
             -- what made every earlier version of this script fail.
             @threat_id              = @threat_id,
             @threat_description     = @threat_desc,
             @vulnerability_id       = @vuln_id,
             @vulnerability_description = @vuln_desc;

        -- The id comes back from the table, not from the result set:
        -- capturing the result set would need INSERT ... EXEC, which is
        -- what broke v2. @run_tag makes the title unique, so this finds
        -- exactly the row this iteration created.
        SELECT TOP (1) @rid = risk_register_id, @rnum = risk_number
          FROM grac_practice.risk_register
         WHERE organization_id = @organization_id
           AND risk_title      = @title
         ORDER BY risk_register_id DESC;

        IF @rid IS NULL
            THROW 50001, 'The risk was not found after sp_risk_custom_create -- it did not create one.', 1;

        EXEC grac_practice.sp_risk_treatment_option_set
             @risk_register_id      = @rid,
             @treatment_option_code = N'Tolerate',
             @remark                = N'Seeded as Tolerate so the risk reaches acceptance directly.',
             @actor_employee_id     = @emp,
             @caller_display_name   = @actor,
             @suppress_result       = 1;

        -- Plain EXEC again, and for the same reason: this procedure also
        -- rolls back inside its CATCH.
        EXEC grac_practice.sp_risk_acceptance_save
             @risk_register_id        = @rid,
             @next_review_date        = @future,
             @accepted_by_employee_id = @emp,
             @accepted_date           = NULL,
             @acceptance_note         = N'Seeded acceptance for review-flow testing.',
             @actor_employee_id       = @emp,
             @caller_display_name     = @actor,
             @review_frequency_id     = @freq_id;

        -- The one direct write. See the header.
        UPDATE grac_practice.risk_register
           SET next_review_date = @due_date,
               updated_by       = @actor,
               updated_dt       = SYSUTCDATETIME()
         WHERE risk_register_id = @rid;

        INSERT INTO @made (RiskRegisterId, RiskNumber, Outcome, Reason)
        VALUES (@rid, @rnum, N'Created', NULL);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO @made (RiskRegisterId, RiskNumber, Outcome, Reason)
        VALUES (@rid, @rnum, N'FAILED', LEFT(ERROR_MESSAGE(), 400));
    END CATCH

    SET @i = @i + 1;
END

-- ---------------------------------------------------------------------
-- 5. Per-risk outcome
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 5. Outcome (read the Reason column on any FAILED row) ===';

SELECT m.RiskNumber, m.Outcome, m.Reason,
       r.status_code          AS Status,
       r.inherent_rating_code AS Rating,
       r.next_review_date     AS NextReviewDate,
       st.workflow_stage_code AS Stage
  FROM @made m
  LEFT JOIN grac_practice.risk_register r  ON r.risk_register_id = m.RiskRegisterId
  LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st
    ON st.risk_register_id = m.RiskRegisterId
 ORDER BY m.Seq;

DECLARE @ok_count INT = (SELECT COUNT(*) FROM @made WHERE Outcome = N'Created');
PRINT CONCAT(@ok_count, ' of ', @how_many, ' created.');

-- ---------------------------------------------------------------------
-- 6. What the Review Risk page will actually show
--
-- The page's OWN procedure, with the page's own defaults. If the seeded
-- rows appear here, they appear there -- and if they do not, the answer
-- is in this result rather than in the browser.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 6. sp_risk_review_due_list -- exactly what the page queries ===';

EXEC grac_practice.sp_risk_review_due_list
     @organization_id = @organization_id,
     @page_number     = 1,
     @page_size       = 50;

PRINT '';
PRINT 'If the [SEED] rows are listed above, the Review Risk tab has them.';
PRINT 'Pick that same organisation in the tab''s Organization filter.';

-- ---------------------------------------------------------------------
-- 7. Cleanup
--
-- No DELETE offered: a registered risk owns analysis versions and
-- history rows, so deleting the parent either trips a foreign key or
-- leaves orphans. Retire them instead -- the product's own way.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 7. Seeded risks in this organisation ===';

SELECT r.risk_register_id AS RiskRegisterId, r.risk_number AS RiskNumber,
       r.risk_title AS RiskTitle, r.status_code AS Status
  FROM grac_practice.risk_register r
 WHERE r.organization_id = @organization_id
   AND r.risk_title LIKE @title_prefix + N'%'
 ORDER BY r.risk_register_id;

PRINT 'To remove one:';
PRINT '  EXEC grac_practice.sp_risk_register_status_set';
PRINT '       @risk_register_id = <id>, @status_code = N''Retired'',';
PRINT '       @remark = N''Seed data removed.'', @caller_display_name = N''cleanup'';';
