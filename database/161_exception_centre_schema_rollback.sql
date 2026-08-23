SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.exception_request_history','U') IS NOT NULL
    DROP TABLE grac_practice.exception_request_history;
GO
IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NOT NULL
    DROP TABLE grac_practice.exception_request_attachment;
GO
IF OBJECT_ID('grac_practice.exception_request','U') IS NOT NULL
    DROP TABLE grac_practice.exception_request;
GO
PRINT '161 rollback complete.';
GO
