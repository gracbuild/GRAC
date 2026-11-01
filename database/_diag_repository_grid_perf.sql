-- =====================================================================
-- _diag_repository_grid_perf.sql  (READ-ONLY diagnostics; not a migration)
--
-- Purpose: measure where the Control Statements / Practices grid time
-- goes on a real (UAT) database, and reveal missing indexes SQL Server
-- itself recommends. Run in SSMS against the Practice Management DB.
--
-- 1. Set the three ids below to a SLOW organization + framework release
--    (and a control for the Practices probe), then run the whole script.
-- 2. Read the "Messages" tab for SET STATISTICS TIME/IO (elapsed ms +
--    logical reads per table). High logical reads on
--    organization_statement_practice_mapping => the 454 index helps.
-- 3. Section D lists SQL Server's own missing-index suggestions for this
--    database (populated after the app/these queries have run a while).
--
-- Nothing here writes data. Safe to run on UAT. ASCII only.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @organization_id        BIGINT = 9;   -- <-- set me (a slow org)
DECLARE @release_id             BIGINT = 3;   -- <-- set me (its framework release)
DECLARE @organization_control_id BIGINT = NULL; -- optional, for the Practices probe
DECLARE @p_search NVARCHAR(200) = N'';

-- ---------------------------------------------------------------------
-- A. Existing indexes on the hot tables
-- ---------------------------------------------------------------------
PRINT '=== A. Existing indexes on hot tables ===';
SELECT  t.name AS TableName,
        i.name AS IndexName,
        i.type_desc,
        STUFF((SELECT ', ' + c.name
                 FROM sys.index_columns ic
                 JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
                WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0
                ORDER BY ic.key_ordinal
                FOR XML PATH('')),1,2,'') AS KeyColumns,
        STUFF((SELECT ', ' + c.name
                 FROM sys.index_columns ic
                 JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
                WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=1
                FOR XML PATH('')),1,2,'') AS IncludedColumns
FROM sys.indexes i
JOIN sys.tables  t ON t.object_id=i.object_id
JOIN sys.schemas s ON s.schema_id=t.schema_id
WHERE s.name='grac_practice'
  AND t.name IN ('organization_statement_practice_mapping',
                 'organization_statement_structure_node',
                 'organization_framework_statements',
                 'organization_requirement',
                 'practice','practice_instance')
  AND i.type_desc <> 'HEAP'
ORDER BY t.name, i.index_id;

-- ---------------------------------------------------------------------
-- B. Row volumes for this org/release (context for the timings)
-- ---------------------------------------------------------------------
PRINT '=== B. Row volumes for this org/release ===';
SELECT
  (SELECT COUNT_BIG(1) FROM grac_practice.organization_statement_structure_node
     WHERE organization_id=@organization_id AND release_id=@release_id AND status='Active') AS ActiveNodes,
  (SELECT COUNT_BIG(1) FROM grac_practice.organization_framework_statements
     WHERE organization_id=@organization_id AND release_id=@release_id
       AND source_type=N'Repository' AND copied_dt IS NOT NULL) AS RepositoryStatements,
  (SELECT COUNT_BIG(1) FROM grac_practice.organization_statement_practice_mapping
     WHERE organization_id=@organization_id AND status='Active') AS StatementPracticeMappings;

-- ---------------------------------------------------------------------
-- C. The Control Statements query (release-statements) under STATISTICS
--    This is the same query QueryReleaseStatementsAsync runs.
-- ---------------------------------------------------------------------
PRINT '=== C. Control Statements query timing ===';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

;WITH active_nodes AS (
    SELECT n.structure_node_id SourceStructureNodeId, n.parent_node_id ParentSourceStructureNodeId,
           n.node_level SourceStructureLevel, n.node_reference SourceStructureReference,
           n.node_title SourceStructureTitle, n.description SourceStructureDescription,
           n.display_order SourceStructureDisplayOrder
    FROM grac_practice.organization_statement_structure_node n
    WHERE n.organization_id=@organization_id AND n.release_id=@release_id AND n.status='Active'
),
statement_practice_counts AS (
    SELECT m.framework_statement_id FrameworkStatementId,
           COUNT(DISTINCT m.org_practice_id) PracticeCount,
           COUNT(DISTINCT CASE WHEN COALESCE(aps.status_name,q.applicability_status)=N'Applicable' THEN m.org_practice_id END) ApplicablePracticeCount
    FROM grac_practice.organization_statement_practice_mapping m
    JOIN grac_practice.organization_requirement q ON q.organization_requirement_id=m.org_practice_id AND q.status='Active'
    LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
    WHERE m.organization_id=@organization_id AND m.status='Active'
    GROUP BY m.framework_statement_id
),
statement_implementation AS (
    SELECT m.framework_statement_id FrameworkStatementId,
           COUNT(DISTINCT pi.practice_instance_id) InstanceCount,
           COUNT(DISTINCT CASE WHEN ism.status_code=N'Implemented' THEN pi.practice_instance_id END) ImplementedInstanceCount
    FROM grac_practice.organization_statement_practice_mapping m
    JOIN grac_practice.organization_requirement q ON q.organization_requirement_id=m.org_practice_id AND q.status='Active'
    JOIN grac_practice.practice p ON p.organization_requirement_id=q.organization_requirement_id AND p.organization_id=m.organization_id AND p.status='Active'
    JOIN grac_practice.practice_instance pi ON pi.practice_id=p.practice_id AND pi.organization_id=m.organization_id AND pi.status='Active'
    LEFT JOIN grac_practice.implementation_status_master ism ON ism.implementation_status_id=pi.implementation_status_id
    WHERE m.organization_id=@organization_id AND m.status='Active'
    GROUP BY m.framework_statement_id
)
SELECT N'Node' RowType, n.SourceStructureNodeId, n.SourceStructureDisplayOrder,
       CAST(NULL AS BIGINT) FrameworkStatementId
FROM active_nodes n
UNION ALL
SELECT N'Statement', n.SourceStructureNodeId, n.SourceStructureDisplayOrder, fs.framework_statement_id
FROM grac_practice.organization_framework_statements fs
JOIN active_nodes n ON n.SourceStructureNodeId=fs.structure_node_id
LEFT JOIN grac_practice.organization_framework_statements ofs
       ON ofs.framework_statement_id=fs.framework_statement_id AND ofs.organization_id=@organization_id
      AND ofs.release_id=@release_id AND ofs.status='Active'
LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=ofs.applicability_status_id
LEFT JOIN statement_practice_counts spc ON spc.FrameworkStatementId=fs.framework_statement_id
LEFT JOIN statement_implementation si ON si.FrameworkStatementId=fs.framework_statement_id
WHERE fs.organization_id=@organization_id AND fs.release_id=@release_id
  AND fs.source_type=N'Repository' AND fs.copied_dt IS NOT NULL
  AND (@p_search=N'' OR ISNULL(fs.statement_reference,N'') LIKE N'%'+@p_search+N'%'
       OR ISNULL(fs.statement_title,N'') LIKE N'%'+@p_search+N'%')
ORDER BY n.SourceStructureDisplayOrder, RowType;

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

-- ---------------------------------------------------------------------
-- D. SQL Server's own missing-index recommendations for this database
--    (most useful after the app has been exercised for a while)
-- ---------------------------------------------------------------------
PRINT '=== D. Missing-index recommendations (grac_practice) ===';
SELECT TOP 25
       ROUND(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans),0) AS Score,
       s.user_seeks + s.user_scans AS Uses,
       d.statement AS TableName,
       d.equality_columns  AS EqualityColumns,
       d.inequality_columns AS InequalityColumns,
       d.included_columns   AS IncludedColumns
FROM sys.dm_db_missing_index_group_stats s
JOIN sys.dm_db_missing_index_groups g ON g.index_group_handle=s.group_handle
JOIN sys.dm_db_missing_index_details d ON d.index_handle=g.index_handle
WHERE d.database_id = DB_ID()
  AND d.statement LIKE '%grac_practice%'
ORDER BY Score DESC;
GO
