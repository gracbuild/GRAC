SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.risk_candidate_history','U') IS NOT NULL
    DROP TABLE grac_practice.risk_candidate_history;
GO
IF OBJECT_ID('grac_practice.risk_candidate_attachment','U') IS NOT NULL
    DROP TABLE grac_practice.risk_candidate_attachment;
GO
IF OBJECT_ID('grac_practice.risk_candidate','U') IS NOT NULL
    DROP TABLE grac_practice.risk_candidate;
GO
PRINT '169 rollback complete.';
GO
