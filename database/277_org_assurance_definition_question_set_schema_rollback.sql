-- =====================================================================
-- 277 Audit -> Question Set link -- ROLLBACK
--
-- Drops the link table 277 created. Question sets, questions and their
-- links (076) are NOT touched: 277 only added an edge between an audit
-- version and existing sets, so dropping it loses the adoptions and
-- nothing else.
--
-- Run 278's rollback FIRST if the procs are still present -- they
-- reference this table.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NULL
BEGIN
    PRINT '277 rollback: table already absent -- nothing to do.';
END
ELSE
BEGIN
    DECLARE @adoptions INT =
        (SELECT COUNT(*) FROM grac_practice.org_assurance_definition_question_set);
    PRINT '277 rollback: dropping table, discarding ' + CAST(@adoptions AS NVARCHAR(20)) + ' adoption row(s).';

    DROP TABLE grac_practice.org_assurance_definition_question_set;
END
GO

SELECT 'link table removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'question sets intact' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.org_assurance_question_set) AS NVARCHAR(20))
       + ' question set row(s) present' AS Result;

PRINT '277 rollback complete.';
GO
