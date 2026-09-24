-- =====================================================================
-- diag_try_one_risk.sql
--
-- Creates ONE risk and reports what happened. Nothing else.
--
-- Everything comes back as a RESULT GRID, never PRINT -- PRINT output
-- goes to SSMS's Messages tab, which is easy to miss, and the whole
-- point of this file is that the answer cannot be missed.
--
-- Expect exactly two grids:
--   Grid 1  INPUTS   what it resolved for your organisation
--   Grid 2  RESULT   'CREATED' with the new risk, or 'FAILED' with the
--                    error number and message
--
-- Paste grid 2. If it says FAILED, ErrorMessage is the real reason
-- creation has been failing.
--
-- It writes at most one risk, titled [DIAG].
-- =====================================================================
SET NOCOUNT ON;

DECLARE @organization_id BIGINT = NULL;   -- <<< SET THIS

-- ---------------------------------------------------------------------
-- No organisation? Show the list and stop.
-- ---------------------------------------------------------------------
IF @organization_id IS NULL
BEGIN
    SELECT 'SET @organization_id AT THE TOP -- pick one below' AS Instruction;
    SELECT organization_id, organization_name, status
      FROM grac_practice.organization
     ORDER BY organization_id;
    RETURN;
END

-- ---------------------------------------------------------------------
-- Resolve the inputs sp_risk_custom_create needs
-- ---------------------------------------------------------------------
DECLARE @cat NVARCHAR(60), @emp BIGINT,
        @lc NVARCHAR(60), @ic NVARCHAR(60), @rate NVARCHAR(30),
        @threat_id INT, @vuln_id INT;

-- 216 made a threat and a vulnerability part of a COMPLETE assessment:
-- sp_risk_register_insert throws 56410 / 56411 without them. Filtered on
-- status_id = 1 only, because that is exactly what sp_risk_analysis_save
-- checks (56402 / 56404) -- it does not scope them by organisation, and
-- the organization_id column only exists once 285 is applied.
-- id 0 is "Others", which obliges the caller to describe it (56403 /
-- 56405). Ordered last so a real threat wins where one exists.
SELECT TOP (1) @threat_id = threat_id
  FROM grac_practice.threat_master
 WHERE status_id = 1
 ORDER BY CASE WHEN threat_id = 0 THEN 1 ELSE 0 END, threat_id;

SELECT TOP (1) @vuln_id = vulnerability_id
  FROM grac_practice.vulnerability_master
 WHERE status_id = 1
 ORDER BY CASE WHEN vulnerability_id = 0 THEN 1 ELSE 0 END, vulnerability_id;

DECLARE @threat_desc NVARCHAR(MAX) =
        CASE WHEN @threat_id = 0 THEN N'Diagnostic threat (Others).' END;
DECLARE @vuln_desc   NVARCHAR(MAX) =
        CASE WHEN @vuln_id   = 0 THEN N'Diagnostic vulnerability (Others).' END;

SELECT TOP (1) @cat = category_code
  FROM grac_practice.risk_category_master
 WHERE organization_id = @organization_id AND status = N'Active'
 ORDER BY display_order, category_code;

SELECT TOP (1) @emp = employee_id
  FROM grac_practice.organization_employee
 WHERE organization_id = @organization_id
 ORDER BY employee_id;

-- Straight from the matrix, so the pair is guaranteed to resolve to a
-- rating (sp_risk_rating_resolve throws 56042 otherwise).
SELECT TOP (1)
       @lc = l.likelihood_code, @ic = i.impact_code, @rate = m.rating_code
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
 ORDER BY m.likelihood_value, m.impact_value;

-- ---- GRID 1: what we resolved --------------------------------------
SELECT @organization_id AS OrganizationId,
       @cat             AS CategoryCode,
       @emp             AS OwnerEmployeeId,
       @lc              AS LikelihoodCode,
       @ic              AS ImpactCode,
       @rate            AS ExpectedRating,
       @threat_id       AS ThreatId,
       @vuln_id         AS VulnerabilityId,
       CASE WHEN @cat IS NULL       THEN 'NO ACTIVE RISK CATEGORY'
            WHEN @emp IS NULL       THEN 'NO EMPLOYEE IN THIS ORG'
            WHEN @lc  IS NULL       THEN 'NO USABLE MATRIX PAIR'
            WHEN @threat_id IS NULL THEN 'NO ACTIVE THREAT (threat_master.status_id = 1)'
            WHEN @vuln_id IS NULL   THEN 'NO ACTIVE VULNERABILITY (vulnerability_master.status_id = 1)'
            ELSE 'inputs look OK' END AS InputCheck;

IF @cat IS NULL OR @emp IS NULL OR @lc IS NULL
   OR @threat_id IS NULL OR @vuln_id IS NULL
BEGIN
    SELECT 'STOPPED' AS Result,
           'One of the inputs above is missing -- see InputCheck.' AS ErrorMessage;
    RETURN;
END

-- ---------------------------------------------------------------------
-- The attempt. Plain EXEC -- never INSERT ... EXEC, which would forbid
-- this procedure's own ROLLBACK and replace the real error with
-- "Cannot use the ROLLBACK statement within an INSERT-EXEC statement".
-- ---------------------------------------------------------------------
DECLARE @title NVARCHAR(300) =
        CONCAT(N'[DIAG] ', FORMAT(SYSUTCDATETIME(), 'MMdd-HHmmss'), N' one-risk test');
DECLARE @rid BIGINT, @rnum NVARCHAR(60),
        @errno INT, @errmsg NVARCHAR(2048), @errline INT, @errproc NVARCHAR(200);

BEGIN TRY
    EXEC grac_practice.sp_risk_custom_create
         @organization_id        = @organization_id,
         @risk_title             = @title,
         @risk_statement         = N'Single-risk diagnostic.',
         @risk_category_code     = @cat,
         @likelihood_code        = @lc,
         @impact_code            = @ic,
         @risk_owner_employee_id = @emp,
         @created_by_employee_id = @emp,
         @caller_display_name    = N'diag',
         -- Required since 216. Without these, registration throws
         -- 56410 / 56411 and the risk is never created.
         @threat_id              = @threat_id,
         @threat_description     = @threat_desc,
         @vulnerability_id       = @vuln_id,
         @vulnerability_description = @vuln_desc;

    SELECT @rid = risk_register_id, @rnum = risk_number
      FROM grac_practice.risk_register
     WHERE organization_id = @organization_id AND risk_title = @title;
END TRY
BEGIN CATCH
    SELECT @errno   = ERROR_NUMBER(),
           @errmsg  = ERROR_MESSAGE(),
           @errline = ERROR_LINE(),
           @errproc = ERROR_PROCEDURE();
END CATCH

-- ---- GRID 2: the answer --------------------------------------------
SELECT CASE WHEN @errno IS NOT NULL THEN 'FAILED'
            WHEN @rid   IS NOT NULL THEN 'CREATED'
            ELSE 'NO ERROR BUT NO RISK' END AS Result,
       @rid     AS RiskRegisterId,
       @rnum    AS RiskNumber,
       @errno   AS ErrorNumber,
       @errproc AS FailedInProcedure,
       @errline AS ErrorLine,
       @errmsg  AS ErrorMessage;
