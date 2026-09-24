-- Rollback for 369_custom_statement_classification.sql
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_statement_classification','U') IS NOT NULL
    DROP TABLE grac_practice.custom_statement_classification;
GO
