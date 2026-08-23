-- =====================================================================
-- 140 Resolve workspace schema -- ROLLBACK
--
-- Drops practice_instance_obligation and the two evidence columns.
--
-- READ BEFORE RUNNING
-- -------------------
-- practice_instance_obligation holds real organization decisions -- which
-- published obligations an instance took on, and with what parameters.
-- Dropping the table destroys them; there is nowhere else they are kept.
-- Capture them first if the instances are live:
--
--     SELECT * FROM grac_practice.practice_instance_obligation;
--
-- Evidence rows created by adopting an obligation are NOT deleted. They
-- are ordinary practice_instance_evidence rows and may already carry an
-- owner, a location and a locator somebody filled in. Only the two
-- columns saying where they came from are removed, so after this rollback
-- an auto-created evidence row is indistinguishable from a hand-added
-- one -- which is the state the table was in before 140.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Procedures first: they reference the table.
IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_obligation_adopt;
GO
IF OBJECT_ID('grac_practice.sp_resolve_obligation_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_obligation_list;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_evidence_source_obligation'
              AND object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
    DROP INDEX ix_pm_evidence_source_obligation
        ON grac_practice.practice_instance_evidence;
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_instance_evidence
        DROP COLUMN source_obligation_evidence_id;
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_instance_evidence
        DROP COLUMN source_obligation_id;
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NOT NULL
    DROP TABLE grac_practice.practice_instance_obligation;
GO

SELECT 'practice_instance_obligation dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'evidence source columns dropped',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NULL
             AND COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Evidence rows that were created by adopting an obligation and are now
-- indistinguishable from hand-added ones.
SELECT COUNT(*) AS EvidenceRowsRemaining
FROM   grac_practice.practice_instance_evidence
WHERE  status = N'Active';

PRINT '140 rolled back. Adoption decisions are gone; evidence rows were left in place.';
GO
