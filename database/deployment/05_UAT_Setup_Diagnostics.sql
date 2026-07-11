/*
  Practice Management UAT diagnostics
  Run this in Grac_newphase_uat using the same SQL login used by the published PracticeManagement API.
*/
SET NOCOUNT ON;

SELECT DB_NAME() AS CurrentDatabase, @@SERVERNAME AS ServerName, SUSER_SNAME() AS LoginName, USER_NAME() AS DatabaseUser;

SELECT 'grac_practice.menu_master' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.menu_master;

SELECT 'grac_practice.menu_master Active' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.menu_master
WHERE status = 'Active';

SELECT 'grac_practice.record_status_master' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.record_status_master;

SELECT 'grac_practice.applicability_status_master' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.applicability_status_master;

SELECT 'grac_practice.dependency_type_master' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.dependency_type_master;

SELECT 'grac_practice.assurance_type_master' AS ObjectName, COUNT_BIG(1) AS RecordCount
FROM grac_practice.assurance_type_master;

SELECT s.name AS SchemaName, o.type_desc AS ObjectType, COUNT_BIG(1) AS ObjectCount
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name IN ('grac_practice', 'grac_new')
GROUP BY s.name, o.type_desc
ORDER BY s.name, o.type_desc;

SELECT name AS ProcedureName, OBJECT_SCHEMA_NAME(object_id) AS SchemaName, type_desc AS ObjectType
FROM sys.objects
WHERE object_id IN (
    OBJECT_ID(N'dbo.pm_get_practice_repository'),
    OBJECT_ID(N'dbo.pm_manage_practice_repository')
);

SELECT referenced_schema_name AS ReferencedSchema,
       referenced_entity_name AS ReferencedObject,
       COUNT_BIG(1) AS ReferenceCount
FROM sys.sql_expression_dependencies
WHERE referencing_id IN (
    OBJECT_ID(N'dbo.pm_get_practice_repository'),
    OBJECT_ID(N'dbo.pm_manage_practice_repository')
)
GROUP BY referenced_schema_name, referenced_entity_name
ORDER BY referenced_schema_name, referenced_entity_name;

SELECT 'grac_practice schema' AS PermissionScope,
       HAS_PERMS_BY_NAME('grac_practice', 'SCHEMA', 'SELECT') AS CanSelect,
       HAS_PERMS_BY_NAME('grac_practice', 'SCHEMA', 'INSERT') AS CanInsert,
       HAS_PERMS_BY_NAME('grac_practice', 'SCHEMA', 'UPDATE') AS CanUpdate,
       HAS_PERMS_BY_NAME('grac_practice', 'SCHEMA', 'DELETE') AS CanDelete,
       HAS_PERMS_BY_NAME('grac_practice', 'SCHEMA', 'EXECUTE') AS CanExecute
UNION ALL
SELECT 'grac_new schema' AS PermissionScope,
       HAS_PERMS_BY_NAME('grac_new', 'SCHEMA', 'SELECT') AS CanSelect,
       HAS_PERMS_BY_NAME('grac_new', 'SCHEMA', 'INSERT') AS CanInsert,
       HAS_PERMS_BY_NAME('grac_new', 'SCHEMA', 'UPDATE') AS CanUpdate,
       HAS_PERMS_BY_NAME('grac_new', 'SCHEMA', 'DELETE') AS CanDelete,
       HAS_PERMS_BY_NAME('grac_new', 'SCHEMA', 'EXECUTE') AS CanExecute
UNION ALL
SELECT 'dbo.pm_get_practice_repository' AS PermissionScope,
       NULL AS CanSelect,
       NULL AS CanInsert,
       NULL AS CanUpdate,
       NULL AS CanDelete,
       HAS_PERMS_BY_NAME('dbo.pm_get_practice_repository', 'OBJECT', 'EXECUTE') AS CanExecute
UNION ALL
SELECT 'dbo.pm_manage_practice_repository' AS PermissionScope,
       NULL AS CanSelect,
       NULL AS CanInsert,
       NULL AS CanUpdate,
       NULL AS CanDelete,
       HAS_PERMS_BY_NAME('dbo.pm_manage_practice_repository', 'OBJECT', 'EXECUTE') AS CanExecute;

EXEC dbo.pm_get_practice_repository
    @p_entity_type = N'menu-master',
    @p_action = N'QUERY',
    @p_id = 0,
    @p_search = N'',
    @p_status = N'',
    @p_payload = N'{}',
    @p_usr_id = N'uat-diagnostic';
