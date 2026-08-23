-- =====================================================================
-- 076 Organization Assurance Question schema rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_question_link','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_question_link;
GO
IF OBJECT_ID('grac_practice.org_assurance_question','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_question;
GO
IF OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_question_set;
GO

PRINT '076 rollback complete.';
GO
