-- =====================================================================
-- 031 Organization Statement -> Practice mapping
-- A practice exists ONCE per organization in grac_practice.organization_requirement
-- ("organization practices"). Because the same repository practice can be mapped
-- to multiple Source Statements, statement linkage moves to a dedicated mapping
-- table: grac_practice.organization_statement_practice_mapping.
--
-- This script:
--   1. Creates the mapping table (unique OrganizationID+OrgStatementID+OrgPracticeID).
--   2. Backfills mappings from existing organization_requirement rows.
--   3. De-duplicates organization_requirement at organization level
--      (same repository practice imported once per statement), repointing
--      mappings, practices, and practice instances to the surviving row and
--      marking duplicates Inactive.
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NULL
CREATE TABLE grac_practice.organization_statement_practice_mapping(
    mapping_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_org_stmt_practice_map PRIMARY KEY,
    organization_id BIGINT NOT NULL CONSTRAINT fk_pm_ospm_organization REFERENCES grac_practice.organization(organization_id),
    org_statement_id BIGINT NOT NULL CONSTRAINT fk_pm_ospm_org_statement REFERENCES grac_practice.organization_framework_statements(org_statement_id),
    framework_statement_id BIGINT NOT NULL,
    repository_requirement_id BIGINT NULL,
    org_practice_id BIGINT NOT NULL CONSTRAINT fk_pm_ospm_org_practice REFERENCES grac_practice.organization_requirement(organization_requirement_id),
    release_id BIGINT NULL,
    status NVARCHAR(30) NOT NULL CONSTRAINT df_pm_ospm_status DEFAULT 'Active',
    record_status_id INT NULL CONSTRAINT fk_pm_ospm_record_status REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_ospm_entered_by DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_ospm_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT uq_pm_org_stmt_practice UNIQUE(organization_id,org_statement_id,org_practice_id)
);
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_ospm_org_fw_statement' AND object_id=OBJECT_ID('grac_practice.organization_statement_practice_mapping'))
 EXEC(N'CREATE INDEX ix_pm_ospm_org_fw_statement
        ON grac_practice.organization_statement_practice_mapping(organization_id,framework_statement_id,status)
        INCLUDE(org_practice_id,org_statement_id)');
GO
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_ospm_org_practice' AND object_id=OBJECT_ID('grac_practice.organization_statement_practice_mapping'))
 EXEC(N'CREATE INDEX ix_pm_ospm_org_practice
        ON grac_practice.organization_statement_practice_mapping(org_practice_id,status)');
GO

DECLARE @active_record_status_id INT=(SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='Active' OR status_name='Active' ORDER BY record_status_id);

-- 2. Backfill mappings from existing statement-scoped organization practices --
INSERT grac_practice.organization_statement_practice_mapping(
    organization_id,org_statement_id,framework_statement_id,repository_requirement_id,org_practice_id,release_id,status,record_status_id,entered_by)
SELECT q.organization_id,q.org_statement_id,ofs.framework_statement_id,q.repository_requirement_id,q.organization_requirement_id,ofs.release_id,'Active',@active_record_status_id,'seed-031'
FROM grac_practice.organization_requirement q
JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=q.org_statement_id
   AND ofs.organization_id=q.organization_id
WHERE q.org_statement_id IS NOT NULL
  AND q.status='Active'
  AND NOT EXISTS(
      SELECT 1 FROM grac_practice.organization_statement_practice_mapping m
      WHERE m.organization_id=q.organization_id
        AND m.org_statement_id=q.org_statement_id
        AND m.org_practice_id=q.organization_requirement_id);

-- 3. De-duplicate organization practices at organization level ----------------
-- Duplicate = same organization + same repository practice (by repository_requirement_id,
-- falling back to requirement_code). Keep the lowest organization_requirement_id.
IF OBJECT_ID('tempdb..#dup') IS NOT NULL DROP TABLE #dup;
IF OBJECT_ID('tempdb..#practice_merge') IS NOT NULL DROP TABLE #practice_merge;
IF OBJECT_ID('tempdb..#practice_pairs') IS NOT NULL DROP TABLE #practice_pairs;

;WITH ranked AS (
    SELECT q.organization_requirement_id,
           MIN(q.organization_requirement_id) OVER(
               PARTITION BY q.organization_id,
                            COALESCE(CONVERT(NVARCHAR(40),q.repository_requirement_id),N'code:'+q.requirement_code)
           ) keep_id
    FROM grac_practice.organization_requirement q
    WHERE q.status='Active'
)
SELECT organization_requirement_id dup_id,keep_id
INTO #dup
FROM ranked
WHERE organization_requirement_id<>keep_id;

-- 3a. Repoint mappings (drop the ones that would collide with an existing
--     mapping for the surviving practice, then repoint the rest).
DELETE m
FROM grac_practice.organization_statement_practice_mapping m
JOIN #dup d ON d.dup_id=m.org_practice_id
WHERE EXISTS(
    SELECT 1 FROM grac_practice.organization_statement_practice_mapping k
    WHERE k.organization_id=m.organization_id
      AND k.org_statement_id=m.org_statement_id
      AND k.org_practice_id=d.keep_id);

UPDATE m SET org_practice_id=d.keep_id,updated_by='seed-031',updated_dt=SYSUTCDATETIME()
FROM grac_practice.organization_statement_practice_mapping m
JOIN #dup d ON d.dup_id=m.org_practice_id;

-- 3b. Merge practices onto the surviving requirement row.
-- uq_pm_practice is UNIQUE(organization_id,organization_requirement_id,practice_code),
-- so practices cannot be blindly repointed: for every
-- (organization, surviving requirement, practice_code) group pick ONE winner
-- (an existing practice already on the survivor wins, else lowest practice_id),
-- repoint the losers' practice instances to the winner, retire the losers,
-- then repoint only the winners.
SELECT p.practice_id,
       p.organization_id,
       COALESCE(d.keep_id,p.organization_requirement_id) target_req_id,
       p.practice_code,
       ROW_NUMBER() OVER(
           PARTITION BY p.organization_id,COALESCE(d.keep_id,p.organization_requirement_id),p.practice_code
           ORDER BY CASE WHEN d.dup_id IS NULL THEN 0 ELSE 1 END,p.practice_id) rn
INTO #practice_merge
FROM grac_practice.practice p
LEFT JOIN #dup d ON d.dup_id=p.organization_requirement_id
WHERE d.dup_id IS NOT NULL
   OR EXISTS(SELECT 1 FROM #dup d2 WHERE d2.keep_id=p.organization_requirement_id);

SELECT w.practice_id winner_id,l.practice_id loser_id
INTO #practice_pairs
FROM #practice_merge l
JOIN #practice_merge w ON w.organization_id=l.organization_id
   AND w.target_req_id=l.target_req_id
   AND w.practice_code=l.practice_code
   AND w.rn=1
WHERE l.rn>1;

UPDATE pi SET practice_id=pp.winner_id,updated_by='seed-031',updated_dt=SYSUTCDATETIME()
FROM grac_practice.practice_instance pi
JOIN #practice_pairs pp ON pp.loser_id=pi.practice_id;

UPDATE p SET status='Inactive',updated_by='seed-031',updated_dt=SYSUTCDATETIME()
FROM grac_practice.practice p
JOIN #practice_pairs pp ON pp.loser_id=p.practice_id;

UPDATE p SET organization_requirement_id=m.target_req_id,updated_by='seed-031',updated_dt=SYSUTCDATETIME()
FROM grac_practice.practice p
JOIN #practice_merge m ON m.practice_id=p.practice_id AND m.rn=1
WHERE p.organization_requirement_id<>m.target_req_id;

-- Practice instances link to requirements through practice (practice_id), which
-- is already repointed above. Some environments add a direct
-- organization_requirement_id column to practice_instance; repoint it only if
-- it exists (dynamic SQL so the batch compiles either way).
IF COL_LENGTH('grac_practice.practice_instance','organization_requirement_id') IS NOT NULL
 EXEC(N'UPDATE pi SET organization_requirement_id=d.keep_id,updated_by=''seed-031'',updated_dt=SYSUTCDATETIME()
       FROM grac_practice.practice_instance pi
       JOIN #dup d ON d.dup_id=pi.organization_requirement_id;');

-- 3c. Retire duplicate organization practice rows.
UPDATE q SET status='Inactive',updated_by='seed-031',updated_dt=SYSUTCDATETIME()
FROM grac_practice.organization_requirement q
JOIN #dup d ON d.dup_id=q.organization_requirement_id;

DECLARE @dups INT=(SELECT COUNT(*) FROM #dup);
DROP TABLE #practice_pairs;
DROP TABLE #practice_merge;
DROP TABLE #dup;

SELECT CONCAT('031 complete. Mapping table ready; ',@dups,' duplicate organization practice row(s) merged.') Message;
GO
