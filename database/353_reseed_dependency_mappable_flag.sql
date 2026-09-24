-- =====================================================================
-- 353 Re-seed dependency_type_master.is_dependency_mappable
--
-- BACKGROUND
--   Risk Analysis -> Impact Details showed "No dependency categories
--   are configured for this organisation" while Operationalize, on the
--   same server, showed dependencies fine. The message text blames the
--   organisation, but neither screen's query is organisation-scoped at
--   all -- dependency_type_master carries no organization_id column.
--
--   The real difference: Operationalize reads categories from the
--   generic lookups endpoint (WHERE is_active = 1, no other filter).
--   Risk Analysis reads them from sp_risk_mapping_get's category result
--   set (267), which adds `AND dt.is_dependency_mappable = 1` -- a flag
--   267 introduced specifically so Risk Analysis would offer the same
--   five categories Operationalize's own JS hardcodes (Asset, Vendor,
--   Person, Team, Committee), defaulting every row to 0 and then
--   seeding those five to 1 by exact name/code match.
--
--   Confirmed by direct query on this environment
--   (_diag_267_dependency_mappable_flag.sql): all nine rows in
--   dependency_type_master -- including all five of Asset/Vendor/
--   Person/Team/Committee, whose names match 267's seed literally,
--   character for character -- currently show is_dependency_mappable=0.
--   267's seed evidently never took effect here, or was reset
--   afterward (a data refresh or restore of dependency_type_master
--   that did not carry the flag forward is the likely mechanism, since
--   the column itself exists and 267 is the only script that ever adds
--   it). Whatever the cause, the fix is the same idempotent seed 267
--   already wrote, re-applied.
--
-- THE FIX
--   Nothing new: 267's own seed UPDATE, verbatim, re-run. It was
--   explicitly written to be idempotent ("Idempotent. Safe to
--   re-run."), so this migration adds no new logic -- it just gives
--   that statement another chance to run on an environment where it
--   evidently did not stick. No procedure, table or column changes.
--
-- WHAT THIS DOES NOT DO
--   It does not touch Operationalize, which never reads this flag. It
--   does not change which five categories are offered -- that decision
--   was made by 267 (and, before it, by migration 238's fixed JS list)
--   and is not revisited here.
--
-- Re-runnable: yes (idempotent WHERE is_dependency_mappable = 0 guards).
-- Rollback:   database/353_reseed_dependency_mappable_flag_rollback.sql
--             (sets the five back to 0, mirroring 267's own rollback)
-- DEPENDS ON: 267 (dependency_type_master.is_dependency_mappable must
--             already exist).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
BEGIN
    PRINT 'ABORT (353): dependency_type_master.is_dependency_mappable missing. Run 267 first.';
    RAISERROR('353_reseed_dependency_mappable_flag: prerequisite missing.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '353: state before re-seed --';
SELECT dependency_type_id, dependency_type_code, dependency_type_name,
       is_active, is_dependency_mappable
FROM   grac_practice.dependency_type_master
ORDER BY display_order, dependency_type_name;
GO

-- Verbatim from 267. Matched by name OR code so it lands correctly
-- whichever the environment carries -- unchanged from the original.
UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 1,
       updated_by = N'reseed-353',
       updated_dt = SYSUTCDATETIME()
 WHERE is_dependency_mappable = 0
   AND (dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee')
     OR dependency_type_code IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee',
                                 N'ASSET', N'VENDOR', N'PERSON', N'TEAM', N'COMMITTEE'));
GO

-- And explicitly OFF for the four Operationalize does not offer, in
-- case a prior hand-edit or data refresh turned one on by mistake.
UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 0,
       updated_by = N'reseed-353',
       updated_dt = SYSUTCDATETIME()
 WHERE is_dependency_mappable = 1
   AND dependency_type_name IN (N'Application', N'Tool', N'Process', N'Location');
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '';
PRINT '353: state after re-seed --';
SELECT dependency_type_id, dependency_type_code, dependency_type_name,
       is_active, is_dependency_mappable
FROM   grac_practice.dependency_type_master
ORDER BY display_order, dependency_type_name;
GO

SELECT '353-a all five expected categories are now mappable' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.dependency_type_master
                   WHERE is_dependency_mappable = 1
                     AND dependency_type_name IN (N'Asset', N'Vendor', N'Person', N'Team', N'Committee')) = 5
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '353-b the four retired categories remain off',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.dependency_type_master
                   WHERE is_dependency_mappable = 1
                     AND dependency_type_name IN (N'Application', N'Tool', N'Process', N'Location')) = 0
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '353-c exactly five categories are mappable in total',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.dependency_type_master
                   WHERE is_dependency_mappable = 1) = 5
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '353 complete. Risk Analysis -> Impact Details will now show the';
PRINT 'same five categories (Asset, Vendor, Person, Team, Committee)';
PRINT 'Operationalize offers, for every organisation on this server --';
PRINT 'this flag was never organisation-specific. No code change and no';
PRINT 'rebuild are required; sp_risk_mapping_get reads the flag live.';
GO

SET NOEXEC OFF;
GO
