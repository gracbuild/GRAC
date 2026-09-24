-- =====================================================================
-- 15  UAT diagnostics -- "No risks in the register match these filters"
--
-- Run when Risk Centre's Register tab reports no rows and you believe
-- there are some.
--
-- CONTEXT. The screen's message is now trustworthy: a failed read says
-- "Could not load the register: <reason>". Seeing the FILTER message
-- instead means the request succeeded (HTTP 200) and the query genuinely
-- matched nothing -- so the fault is in the WHERE clause's inputs, not in
-- the code path.
--
-- The Register toolbar sends, by default:
--     organizationId = <the org picker's value, which lives on the
--                       CANDIDATES tab -- the Register tab has none>
--     statusCode     = 'Active'          <- pre-selected in the markup
-- everything else empty.
--
-- sp_risk_register_list then filters:
--     WHERE r.organization_id = @organization_id
--       AND (@status_code IS NULL OR r.status_code = @status_code)
--
-- So exactly two things can empty it: the organisation, or the status.
-- Section 2 and Section 3 below say which.
--
-- READ-ONLY. Nothing here writes. Safe on any environment.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 1. Is there anything in the register at all?';
PRINT '=====================================================================';

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT 'risk_register table does not exist -- migration 205 has not run.';
END
ELSE
BEGIN
    SELECT COUNT_BIG(*) AS TotalRegisterRows
      FROM grac_practice.risk_register;
END
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 2. THE ORGANISATION CHECK';
PRINT '';
PRINT ' Rows per organisation. Compare OrganizationId against the org';
PRINT ' selected in the Risk Centre picker (Candidates tab). If your rows';
PRINT ' sit under a different organisation, the Register is correct to';
PRINT ' show nothing -- you are looking at another tenant.';
PRINT '=====================================================================';

SELECT r.organization_id            AS OrganizationId,
       o.organization_name          AS OrganizationName,
       COUNT_BIG(*)                 AS RegisterRows
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.organization o
         ON o.organization_id = r.organization_id
 GROUP BY r.organization_id, o.organization_name
 ORDER BY RegisterRows DESC;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 3. THE STATUS CHECK';
PRINT '';
PRINT ' Rows per status. The toolbar pre-selects Active, so anything NOT';
PRINT ' Active is invisible until you change the Status dropdown.';
PRINT ' sp_risk_register_insert writes Active explicitly, so a register';
PRINT ' full of some other status means something changed it afterwards';
PRINT ' (sp_risk_register_set_status, or a manual UPDATE).';
PRINT '=====================================================================';

SELECT r.status_code    AS StatusCode,
       COUNT_BIG(*)     AS RegisterRows,
       MIN(r.registered_dt) AS EarliestRegistered,
       MAX(r.registered_dt) AS LatestRegistered
  FROM grac_practice.risk_register r
 GROUP BY r.status_code
 ORDER BY RegisterRows DESC;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 4. The two together -- organisation x status.';
PRINT ' Find your organisation''s row. If its Active count is 0 but another';
PRINT ' status has rows, that is your answer.';
PRINT '=====================================================================';

SELECT r.organization_id  AS OrganizationId,
       o.organization_name AS OrganizationName,
       r.status_code      AS StatusCode,
       COUNT_BIG(*)       AS RegisterRows
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.organization o
         ON o.organization_id = r.organization_id
 GROUP BY r.organization_id, o.organization_name, r.status_code
 ORDER BY r.organization_id, RegisterRows DESC;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 5. Reproduce the screen''s exact default query.';
PRINT '';
PRINT ' Set @org below to the organisation the picker is showing, then';
PRINT ' compare the two counts. WithDefaultFilter is what the screen sees.';
PRINT '=====================================================================';

DECLARE @org BIGINT = (SELECT TOP 1 organization_id
                         FROM grac_practice.risk_register
                        GROUP BY organization_id
                        ORDER BY COUNT_BIG(*) DESC);

PRINT CONCAT('Using organization_id = ', ISNULL(CAST(@org AS NVARCHAR(20)), 'NULL (register is empty)'));

SELECT @org                                        AS OrganizationIdUsed,
       (SELECT COUNT_BIG(*) FROM grac_practice.risk_register
         WHERE organization_id = @org)             AS AllStatuses,
       (SELECT COUNT_BIG(*) FROM grac_practice.risk_register
         WHERE organization_id = @org
           AND status_code = N'Active')            AS WithDefaultFilter_Active;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 6. Is migration 216 applied?';
PRINT '';
PRINT ' The Api reads AnalysisPending / ThreatName / VulnerabilityName /';
PRINT ' BusinessFunctionName from sp_risk_register_list. Those columns are';
PRINT ' only projected by 216''s version. The Api now guards these reads,';
PRINT ' so a FAIL here no longer breaks the page -- but the four fields';
PRINT ' will be blank and the Analysis-pending filter will do nothing.';
PRINT '=====================================================================';

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_list','P'));

SELECT
    CASE WHEN @def IS NULL THEN 'FAIL - procedure missing entirely'
         WHEN @def LIKE '%AnalysisPending%' THEN 'PASS - 216 applied'
         ELSE 'FAIL - 206 version still live; run 216' END      AS ListProcVersion,
    CASE WHEN COL_LENGTH('grac_practice.risk_register','analysis_pending') IS NOT NULL
         THEN 'PASS' ELSE 'FAIL - run 216' END                  AS AnalysisPendingColumn,
    CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                       WHERE object_id = OBJECT_ID('grac_practice.sp_risk_register_list')
                         AND name = '@analysis_pending')
         THEN 'PASS' ELSE 'FAIL - run 216' END                  AS AnalysisPendingParameter;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' 7. Candidates that were registered but left no register row.';
PRINT ' A non-empty result here means registration half-completed:';
PRINT ' the candidate says Registered but points at nothing.';
PRINT '=====================================================================';

SELECT c.risk_candidate_id  AS RiskCandidateId,
       c.organization_id    AS OrganizationId,
       c.candidate_title    AS CandidateTitle,
       c.status_code        AS CandidateStatus,
       c.registered_risk_id AS RegisteredRiskId
  FROM grac_practice.risk_candidate c
 WHERE c.status_code = N'Registered'
   AND (c.registered_risk_id IS NULL
        OR NOT EXISTS (SELECT 1 FROM grac_practice.risk_register r
                        WHERE r.risk_register_id = c.registered_risk_id))
 ORDER BY c.risk_candidate_id;
GO

PRINT '';
PRINT '15 complete. Sections 2, 3 and 5 identify the filter; 6 reports';
PRINT 'migration state; 7 reports half-finished registrations.';
GO
