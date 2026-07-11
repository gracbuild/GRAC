using System.Data;
using System.Data.Common;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IPracticeRepositoryService
{
    Task<PracticeRepositoryResult> QueryAsync(PracticeRepositoryQuery request, CancellationToken cancellationToken);
    Task<PracticeRepositoryResult> ManageAsync(PracticeRepositoryCommand request, CancellationToken cancellationToken);
    Task<PracticeRepositoryResult> DiagnosticsAsync(int organizationId, CancellationToken cancellationToken);
}

public sealed class PracticeRepositoryService(IConfiguration configuration, ILogger<PracticeRepositoryService> logger) : IPracticeRepositoryService
{
    private static readonly object DiagnosticLock = new();
    private static object? LastSqlDiagnostic;
    public Task<PracticeRepositoryResult> QueryAsync(PracticeRepositoryQuery request, CancellationToken cancellationToken) =>
        ExecuteAsync("dbo.pm_get_practice_repository", request.EntityType, "QUERY", request.Id, request.Search ?? "",
            request.Status ?? "", request.Data.ValueKind == System.Text.Json.JsonValueKind.Undefined ? "{}" : request.Data.GetRawText(), request.EnteredBy, cancellationToken);

    public Task<PracticeRepositoryResult> ManageAsync(PracticeRepositoryCommand request, CancellationToken cancellationToken) =>
        ExecuteAsync("dbo.pm_manage_practice_repository", request.EntityType, request.Action, request.Id, "",
            "", request.Data.ValueKind == System.Text.Json.JsonValueKind.Undefined ? "{}" : request.Data.GetRawText(), request.EnteredBy, cancellationToken);

    public async Task<PracticeRepositoryResult> DiagnosticsAsync(int organizationId, CancellationToken cancellationToken)
    {
        try
        {
            var provider = configuration["Database:Provider"] ?? "Microsoft.Data.SqlClient";
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
                return new(false, "Configure ConnectionStrings:PracticeManagement before using practice endpoints.");

            var factory = provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase)
                ? Microsoft.Data.SqlClient.SqlClientFactory.Instance
                : DbProviderFactories.GetFactory(provider);

            await using var connection = factory.CreateConnection() ?? throw new InvalidOperationException("Unable to create database connection.");
            connection.ConnectionString = ConfigureConnectionString(provider, connectionString);
            await connection.OpenAsync(cancellationToken);

            var diagnostic = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            await using (var command = connection.CreateCommand())
            {
                command.CommandText = """
                    SELECT DB_NAME() DatabaseName,
                           @@SERVERNAME ServerName,
                           OBJECT_ID(N'grac_practice.organization_control') OrganizationControlObjectId,
                           OBJECT_ID(N'dbo.pm_get_practice_repository') RepositoryProcedureObjectId,
                           (SELECT COUNT_BIG(1) FROM grac_practice.organization) OrganizationRows,
                           (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id) OrganizationControlRows,
                           (SELECT COUNT_BIG(1) FROM grac_practice.organization_control WHERE organization_id=@organization_id AND status='Active') ActiveOrganizationControlRows;
                    """;
                Add(command, "@organization_id", organizationId);
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                if (await reader.ReadAsync(cancellationToken))
                {
                    for (var i = 0; i < reader.FieldCount; i++)
                        diagnostic[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                }
            }

            await using (var command = connection.CreateCommand())
            {
                command.CommandText = "dbo.pm_get_practice_repository";
                command.CommandType = CommandType.StoredProcedure;
                Add(command, "@p_entity_type", "organization-controls");
                Add(command, "@p_action", "QUERY");
                Add(command, "@p_id", 0);
                Add(command, "@p_search", "");
                Add(command, "@p_status", "");
                Add(command, "@p_payload", $$"""{"organizationId":{{organizationId}},"pageNumber":1,"pageSize":25}""");
                Add(command, "@p_usr_id", "diagnostic");
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                var rows = 0;
                while (await reader.ReadAsync(cancellationToken)) rows++;
                diagnostic["ProcedureOrganizationControlRows"] = rows;
            }

            return new(true, "Success", new[] { diagnostic });
        }
        catch (Exception ex)
        {
            var correlationId = Guid.NewGuid().ToString("N");
            logger.LogError(ex, "PracticeManagement diagnostic failed {CorrelationId}", correlationId);
            return new(false, $"The practice diagnostic could not be completed. Reference: {correlationId}");
        }
    }

    private async Task<PracticeRepositoryResult> ExecuteAsync(string procedure, string entityType, string action, int? id,
        string search, string status, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        try
        {
            var requestedEntityType = entityType;
            if (entityType.Equals("resolve", StringComparison.OrdinalIgnoreCase)) entityType = "practice-operationalization";
            var provider = configuration["Database:Provider"] ?? "Microsoft.Data.SqlClient";
            var connectionString = GetConnectionString();
            if (string.IsNullOrWhiteSpace(connectionString))
                return new(false, "Configure ConnectionStrings:PracticeManagement before using practice endpoints.");

            var factory = provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase)
                ? Microsoft.Data.SqlClient.SqlClientFactory.Instance
                : DbProviderFactories.GetFactory(provider);

            await using var connection = factory.CreateConnection() ?? throw new InvalidOperationException("Unable to create database connection.");
            connection.ConnectionString = ConfigureConnectionString(provider, connectionString);
            await connection.OpenAsync(cancellationToken);

            var requestedOrganizationId = JsonInt(payload, "organizationId");
            if (requestedOrganizationId.HasValue
                && !JsonSecurityIsSystemAdmin(payload)
                && !await HasOrganizationAccessAsync(connection, JsonSecuritySubject(payload), requestedOrganizationId.Value, cancellationToken))
            {
                logger.LogWarning("PracticeManagement API blocked organization access. EntityType={EntityType} Subject={Subject} OrganizationId={OrganizationId}",
                    entityType, JsonSecuritySubject(payload), requestedOrganizationId.Value);
                return new(false, "You do not have access to the selected organization.");
            }

            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("menu-master", StringComparison.OrdinalIgnoreCase))
            {
                var directTables = await QueryMenuMasterAsync(connection, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                logger.LogInformation("PracticeManagement menu-master query returned {MenuCount} active rows from grac_practice.menu_master.",
                    directTables.FirstOrDefault()?.Count ?? 0);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("subscribed-frameworks", StringComparison.OrdinalIgnoreCase))
            {
                await SyncOrganizationFrameworkStatementsAsync(connection, payload, enteredBy, cancellationToken);
                var directTables = await QuerySubscribedFrameworksAsync(connection, payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("release-statements", StringComparison.OrdinalIgnoreCase))
            {
                await SyncOrganizationFrameworkStatementsAsync(connection, payload, enteredBy, cancellationToken);
                var directTables = await QueryReleaseStatementsAsync(connection, search ?? "", payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_manage_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("statement-applicability", StringComparison.OrdinalIgnoreCase))
            {
                await SaveStatementApplicabilityAsync(connection, payload, enteredBy, cancellationToken);
                return new(true, "Saved successfully.");
            }
            if (procedure.Equals("dbo.pm_manage_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("custom-release", StringComparison.OrdinalIgnoreCase))
            {
                await SaveCustomReleaseAsync(connection, payload, enteredBy, cancellationToken);
                return new(true, "Saved successfully.");
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("custom-release-statements", StringComparison.OrdinalIgnoreCase))
            {
                var directTables = await QueryCustomReleaseStatementsAsync(connection, search ?? "", payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_manage_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("custom-statement", StringComparison.OrdinalIgnoreCase))
            {
                await SaveCustomStatementAsync(connection, payload, enteredBy, cancellationToken);
                return new(true, "Saved successfully.");
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase))
            {
                var directTables = await QueryCustomReleaseSourceStructureAsync(connection, payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_manage_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase))
            {
                await SaveCustomReleaseSourceStructureAsync(connection, payload, enteredBy, cancellationToken);
                return new(true, "Saved successfully.");
            }

            var canUseOrganizationFallback = CanUseOrganizationFallback(payload);
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("dependency-options", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback)
            {
                var directTables = await QueryDependencyOptionsFallbackAsync(connection, search ?? "", payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                logger.LogInformation("PracticeManagement dependency object query returned {RowCount} rows. DependencyTypeId={DependencyTypeId} OrganizationId={OrganizationId} SourceTable={SourceTable}",
                    directTables.FirstOrDefault()?.Count ?? 0,
                    JsonInt(payload, "dependencyTypeId"),
                    JsonInt(payload, "organizationId"),
                    directTables.Skip(1).FirstOrDefault()?.FirstOrDefault()?.GetValueOrDefault("SourceTableName"));
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("organization-requirements", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback)
            {
                var directTables = await QueryOrganizationRequirementFallbackAsync(connection, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && TryGetWorkbenchDependencyCode(entityType, out var workbenchDependencyCode)
                && canUseOrganizationFallback)
            {
                logger.LogInformation("PracticeManagement workbench query starting. EntityType={EntityType} DependencyCode={DependencyCode} OrganizationId={OrganizationId} Subject={Subject}",
                    entityType, workbenchDependencyCode, JsonInt(payload, "organizationId"), JsonSecuritySubject(payload));
                List<List<Dictionary<string, object?>>> directTables;
                try
                {
                    directTables = await QueryDependencyWorkbenchAsync(connection, workbenchDependencyCode, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                }
                catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 207 or 208)
                {
                    logger.LogWarning(ex, "PracticeManagement workbench full query is not aligned with the current database; using compatibility query. EntityType={EntityType} DependencyCode={DependencyCode} OrganizationId={OrganizationId}",
                        entityType, workbenchDependencyCode, JsonInt(payload, "organizationId"));
                    directTables = await QueryDependencyWorkbenchCompatibilityAsync(connection, workbenchDependencyCode, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                }
                CaptureSqlDiagnostic(procedure, entityType, action, id, search, status, payload, directTables);
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && requestedEntityType.Equals("resolve", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback)
            {
                var directTables = await QueryResolveFallbackAsync(connection, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, requestedEntityType, action, id, search, status, payload, directTables);
                logger.LogInformation("PracticeManagement resolve query returned {RowCount} owner-scoped rows. OrganizationId={OrganizationId} Subject={Subject}",
                    directTables.FirstOrDefault()?.Count ?? 0, JsonInt(payload, "organizationId"), JsonSecuritySubject(payload));
                return new(true, "Success", directTables);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && requestedEntityType.Equals("assurance-calendar-events", StringComparison.OrdinalIgnoreCase))
            {
                var directTables = await QueryCalendarEventsAsync(connection, payload, cancellationToken);
                CaptureSqlDiagnostic(procedure, requestedEntityType, action, id, search, status, payload, directTables);
                logger.LogInformation("PracticeManagement calendar events query returned {EventCount} computed events, {RuleCount} rules, {OrgCount} orgs. OrganizationId={OrganizationId}",
                    directTables.ElementAtOrDefault(0)?.Count ?? 0, directTables.ElementAtOrDefault(1)?.Count ?? 0, directTables.ElementAtOrDefault(3)?.Count ?? 0, JsonInt(payload, "organizationId"));
                return new(true, "Success", directTables);
            }
            await using var command = connection.CreateCommand();
            command.CommandText = procedure;
            command.CommandType = CommandType.StoredProcedure;
            Add(command, "@p_entity_type", entityType ?? "");
            Add(command, "@p_action", action ?? "");
            Add(command, "@p_id", id ?? 0);
            Add(command, "@p_search", search ?? "");
            Add(command, "@p_status", status ?? "");
            Add(command, "@p_payload", string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            Add(command, "@p_usr_id", enteredBy ?? "");

            List<List<Dictionary<string, object?>>> tables;
            tables = await ReadTablesAsync(command, cancellationToken);
            if (procedure.Equals("dbo.pm_manage_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("organization-setup", StringComparison.OrdinalIgnoreCase))
            {
                await SyncOrganizationFrameworkStatementsAsync(connection, payload, enteredBy, cancellationToken);
            }
            if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && (entityType.Equals("control-applicability", StringComparison.OrdinalIgnoreCase)
                    || entityType.Equals("organization-controls", StringComparison.OrdinalIgnoreCase))
                && canUseOrganizationFallback
                && (tables.FirstOrDefault()?.Count ?? 0) == 0)
            {
                var fallbackTables = await QueryOrganizationControlFallbackAsync(connection, entityType, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                if ((fallbackTables.FirstOrDefault()?.Count ?? 0) > 0) tables = fallbackTables;
            }
            else if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("organization-requirements", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback
                && (tables.FirstOrDefault()?.Count ?? 0) == 0)
            {
                var fallbackTables = await QueryOrganizationRequirementFallbackAsync(connection, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                if ((fallbackTables.FirstOrDefault()?.Count ?? 0) > 0) tables = fallbackTables;
            }
            else if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("practice-instances", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback
                && (tables.FirstOrDefault()?.Count ?? 0) == 0)
            {
                var fallbackTables = await QueryPracticeInstanceFallbackAsync(connection, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                if ((fallbackTables.FirstOrDefault()?.Count ?? 0) > 0) tables = fallbackTables;
            }
            
            else if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("evidence-configurations", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback
                && (tables.FirstOrDefault()?.Count ?? 0) == 0)
            {
                var fallbackTables = await QueryEvidenceConfigurationFallbackAsync(connection, id ?? 0, search ?? "", status ?? "", payload, cancellationToken);
                if ((fallbackTables.FirstOrDefault()?.Count ?? 0) > 0) tables = fallbackTables;
            }
            else if (procedure.Equals("dbo.pm_get_practice_repository", StringComparison.OrdinalIgnoreCase)
                && entityType.Equals("evidence-obligations", StringComparison.OrdinalIgnoreCase)
                && canUseOrganizationFallback
                && (tables.FirstOrDefault()?.Count ?? 0) == 0)
            {
                var fallbackTables = await QueryEvidenceObligationsFallbackAsync(connection, search ?? "", payload, cancellationToken);
                if ((fallbackTables.FirstOrDefault()?.Count ?? 0) > 0) tables = fallbackTables;
            }

            if (configuration.GetValue("PracticeDiagnostics:CaptureSqlResult", true))
            {
                var diagnostic = new
                {
                    capturedAtUtc = DateTimeOffset.UtcNow,
                    procedure,
                    entityType,
                    action,
                    id = id ?? 0,
                    search = search ?? "",
                    status = status ?? "",
                    payload,
                    tableCount = tables.Count,
                    firstRowCount = tables.FirstOrDefault()?.Count ?? 0
                };
                lock (DiagnosticLock) LastSqlDiagnostic = diagnostic;
                logger.LogInformation("PracticeManagement SQL result {Procedure} {EntityType} Payload={Payload} TableCount={TableCount} FirstRowCount={FirstRowCount}",
                    procedure, entityType, payload, tables.Count, tables.FirstOrDefault()?.Count ?? 0);
            }

            return new(true, "Success", tables);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 2601 or 2627)
        {
            logger.LogWarning(ex, "Rejected duplicate PracticeManagement data for {EntityType} {Action}", entityType, action);
            return new(false, "A record with the same unique value already exists.");
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 51010 and <= 51099)
        {
            logger.LogWarning(ex, "Rejected invalid PracticeManagement data for {EntityType} {Action}", entityType, action);
            return new(false, ex.Message);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 207 or 208 or 515 or 547 or 245 or 8114)
        {
            var correlationId = Guid.NewGuid().ToString("N");
            logger.LogError(ex, "PracticeManagement SQL validation failed {CorrelationId} for {EntityType} {Action}. SqlNumber={SqlNumber}",
                correlationId, entityType, action, ex.Number);
            return new(false, ex.Number switch
            {
                207 or 208 => $"PracticeManagement database scripts are not aligned with the current database. Reference: {correlationId}",
                515 => $"A required database value is missing. Reference: {correlationId}",
                547 => $"The selected related record is not valid or is no longer available. Reference: {correlationId}",
                245 or 8114 => $"One or more submitted values have an invalid format. Reference: {correlationId}",
                _ => $"The practice operation could not be completed. Reference: {correlationId}"
            });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex)
        {
            var correlationId = Guid.NewGuid().ToString("N");
            if (TryGetWorkbenchDependencyCode(entityType, out var failedWorkbenchCode))
            {
                var workbenchDiagnostic = new
                {
                    capturedAtUtc = DateTimeOffset.UtcNow,
                    procedure,
                    entityType,
                    action,
                    id = id ?? 0,
                    search = search ?? "",
                    status = status ?? "",
                    dependencyCategory = failedWorkbenchCode,
                    organizationId = JsonInt(payload, "organizationId"),
                    loggedInUser = JsonSecuritySubject(payload),
                    sqlNumber = ex.Number,
                    sqlMessage = ex.Message
                };
                lock (DiagnosticLock) LastSqlDiagnostic = workbenchDiagnostic;
                logger.LogError(ex, "PracticeManagement workbench SQL failed {CorrelationId}. EntityType={EntityType} DependencyCode={DependencyCode} OrganizationId={OrganizationId} Subject={Subject} SqlNumber={SqlNumber} SqlMessage={SqlMessage}",
                    correlationId, entityType, failedWorkbenchCode, JsonInt(payload, "organizationId"), JsonSecuritySubject(payload), ex.Number, ex.Message);
                return new(false, $"The workbench list query failed. SQL error {ex.Number}. Reference: {correlationId}");
            }

            logger.LogError(ex, "PracticeManagement SQL operation failed {CorrelationId} for {EntityType} {Action}. SqlNumber={SqlNumber} SqlMessage={SqlMessage}",
                correlationId, entityType, action, ex.Number, ex.Message);
            return new(false, $"The practice database operation failed. SQL error {ex.Number}. Reference: {correlationId}");
        }
        catch (Exception ex)
        {
            var correlationId = Guid.NewGuid().ToString("N");
            logger.LogError(ex, "PracticeManagement database operation failed {CorrelationId} for {EntityType} {Action}",
                correlationId, entityType, action);
            return new(false, $"The practice operation could not be completed. Reference: {correlationId}");
        }
    }

    private static async Task<List<List<Dictionary<string, object?>>>> ReadTablesAsync(DbCommand command, CancellationToken cancellationToken)
    {
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var tables = new List<List<Dictionary<string, object?>>>();
        do
        {
            var rows = new List<Dictionary<string, object?>>();
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < reader.FieldCount; i++)
                    row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                rows.Add(row);
            }
            tables.Add(rows);
        } while (await reader.NextResultAsync(cancellationToken));

        return tables;
    }

    private void CaptureSqlDiagnostic(string procedure, string entityType, string action, int? id, string? search,
        string? status, string payload, List<List<Dictionary<string, object?>>> tables)
    {
        if (!configuration.GetValue("PracticeDiagnostics:CaptureSqlResult", true)) return;
        var diagnostic = new
        {
            capturedAtUtc = DateTimeOffset.UtcNow,
            procedure,
            entityType,
            action,
            id = id ?? 0,
            search = search ?? "",
            status = status ?? "",
            payload,
            tableCount = tables.Count,
            firstRowCount = tables.FirstOrDefault()?.Count ?? 0
        };
        lock (DiagnosticLock) LastSqlDiagnostic = diagnostic;
        logger.LogInformation("PracticeManagement SQL result {Procedure} {EntityType} Payload={Payload} TableCount={TableCount} FirstRowCount={FirstRowCount}",
            procedure, entityType, payload, tables.Count, tables.FirstOrDefault()?.Count ?? 0);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryMenuMasterAsync(
        DbConnection connection, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT menu_id Id,
                   menu_key MenuKey,
                   menu_name MenuName,
                   menu_url MenuUrl,
                   parent_menu_id ParentMenuId,
                   display_order DisplayOrder,
                   icon_class IconClass,
                   module_type ModuleType,
                   status Status
            FROM grac_practice.menu_master
            WHERE status='Active'
            ORDER BY display_order,menu_name;
            """;
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task SyncOrganizationFrameworkStatementsAsync(DbConnection connection, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @organization_id BIGINT=COALESCE(
                TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organizationId')),
                TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.id')),
                TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organization.id')),
                (SELECT TOP (1) organization_id FROM grac_practice.organization WHERE organization_code=JSON_VALUE(@payload,'$.organization.code'))
            );

            IF @organization_id IS NULL RETURN;

            DECLARE @not_updated_status_id INT=(
                SELECT TOP (1) applicability_status_id
                FROM grac_practice.applicability_status_master
                WHERE status_code='Not Updated' OR status_name='Not Updated'
            );
            DECLARE @active_status_id INT=(
                SELECT TOP (1) record_status_id
                FROM grac_practice.record_status_master
                WHERE status_code='Active' OR status_name='Active'
            );

            ;WITH requested_releases AS (
                -- Scope the sync to the requested release(s) when provided so this
                -- write-check does not scan every subscription on each page load.
                SELECT TRY_CONVERT(BIGINT,[value]) release_id
                FROM OPENJSON(@payload,'$.releaseIds')
                WHERE TRY_CONVERT(BIGINT,[value]) IS NOT NULL
                UNION
                SELECT TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.releaseId'))
                WHERE TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.releaseId')) IS NOT NULL
            ),
            active_subscriptions AS (
                SELECT DISTINCT s.organization_id,s.release_id
                FROM grac_practice.repository_subscription s
                WHERE s.organization_id=@organization_id
                  AND s.release_id IS NOT NULL
                  AND s.status='Active'
                  AND ISNULL(s.subscription_status,'Active')='Active'
                  AND (
                      NOT EXISTS(SELECT 1 FROM requested_releases)
                      OR EXISTS(SELECT 1 FROM requested_releases rr WHERE rr.release_id=s.release_id)
                  )
            )
            INSERT grac_practice.organization_framework_statements(
                organization_id,release_id,framework_statement_id,applicability_status_id,status_id,status,entered_by)
            SELECT sub.organization_id,sub.release_id,fs.framework_statement_id,@not_updated_status_id,@active_status_id,N'Active',@user_id
            FROM active_subscriptions sub
            JOIN grac_new.framework_statement fs ON fs.release_id=sub.release_id AND fs.status='Active'
            WHERE NOT EXISTS(
                SELECT 1
                FROM grac_practice.organization_framework_statements existing
                WHERE existing.organization_id=sub.organization_id
                  AND existing.release_id=sub.release_id
                  AND existing.framework_statement_id=fs.framework_statement_id
            );
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@payload", string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
        Add(command, "@user_id", string.IsNullOrWhiteSpace(enteredBy) ? "system" : enteredBy);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QuerySubscribedFrameworksAsync(
        DbConnection connection, string payload, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            ;WITH subscribed AS (
                SELECT DISTINCT s.organization_id,s.release_id,COALESCE(s.artifact_id,r.artifact_id) artifact_id
                FROM grac_practice.repository_subscription s
                JOIN grac_new.release r ON r.release_id=s.release_id
                WHERE s.status='Active'
                  AND ISNULL(s.subscription_status,'Active')='Active'
                  AND s.release_id IS NOT NULL
                  AND (@organization_id IS NULL OR s.organization_id=@organization_id)
            ),
            -- Statement-level counts. Repository statements (grac_new.framework_statement,
            -- Active, attached to an Active node of the same release) drive the count;
            -- organization applicability is a LEFT JOIN enrichment only. A repository
            -- statement is counted even when the organization has not created its
            -- applicability row yet (it simply counts as 'Not Updated'). These joins
            -- MUST stay identical to the release-statements drill-down query so the
            -- summary count always equals the drill-down statement count.
            organization_statement_counts AS (
                SELECT
                    sub.organization_id,
                    sub.release_id,
                    COUNT(DISTINCT fs.framework_statement_id) TotalStatementsCount,
                    COUNT(DISTINCT CASE WHEN aps.status_name=N'Applicable' THEN fs.framework_statement_id END) ApplicableStatementsCount,
                    COUNT(DISTINCT CASE WHEN COALESCE(aps.status_name,N'Not Updated')=N'Not Updated' THEN fs.framework_statement_id END) NotUpdatedStatementsCount,
                    COUNT(DISTINCT CASE WHEN aps.status_name IN (N'Not Applicable',N'Deferred',N'Accepted Risk',N'Not Implemented',N'Retired') THEN fs.framework_statement_id END) NotApplicableStatementsCount
                FROM subscribed sub
                JOIN grac_new.framework_statement fs ON fs.release_id=sub.release_id
                    AND fs.status='Active'
                JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id
                    AND n.release_id=sub.release_id
                    AND n.status='Active'
                LEFT JOIN grac_practice.organization_framework_statements ofs ON ofs.organization_id=sub.organization_id
                    AND ofs.release_id=sub.release_id
                    AND ofs.framework_statement_id=fs.framework_statement_id
                    AND ofs.status='Active'
                LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=ofs.applicability_status_id
                GROUP BY sub.organization_id,sub.release_id
            )
            SELECT
                r.release_id ReleaseId,
                a.artifact_id ArtifactId,
                auth.authority_code AuthorityCode,
                auth.authority_name Authority,
                a.artifact_code ArtifactCode,
                a.artifact_name ArtifactName,
                r.version_no ReleaseVersion,
                COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease,
                COALESCE(osc.TotalStatementsCount,0) TotalStatementsCount,
                COALESCE(osc.ApplicableStatementsCount,0) ApplicableStatementsCount,
                COALESCE(osc.NotUpdatedStatementsCount,0) NotUpdatedStatementsCount,
                COALESCE(osc.NotApplicableStatementsCount,0) NotApplicableStatementsCount
            FROM subscribed sub
            JOIN grac_new.release r ON r.release_id=sub.release_id
            LEFT JOIN grac_new.artifact a ON a.artifact_id=COALESCE(sub.artifact_id,r.artifact_id)
            LEFT JOIN grac_new.authority auth ON auth.authority_id=a.authority_id
            LEFT JOIN organization_statement_counts osc ON osc.organization_id=sub.organization_id AND osc.release_id=sub.release_id

            ORDER BY Authority,ArtifactName,ReleaseVersion;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@organization_id", JsonInt(payload, "organizationId"));
        var tables = await ReadTablesAsync(command, cancellationToken);

        // Append custom releases (organization-specific) in a separate query so that
        // if the custom_release_name column has not been deployed yet, the main
        // subscribed-frameworks query still works.
        try
        {
            await using var customCmd = connection.CreateCommand();
            customCmd.CommandText = """
                SELECT
                    -1 * s.subscription_id ReleaseId,
                    CAST(NULL AS BIGINT) ArtifactId,
                    N'ORG' AuthorityCode,
                    N'Organization' Authority,
                    N'CUSTOM' ArtifactCode,
                    N'Custom' ArtifactName,
                    s.custom_release_name ReleaseVersion,
                    N'Organization / ' + s.custom_release_name FrameworkRelease,
                    0 TotalStatementsCount,
                    0 ApplicableStatementsCount,
                    0 NotUpdatedStatementsCount,
                    0 NotApplicableStatementsCount
                FROM grac_practice.repository_subscription s
                WHERE s.subscription_type=N'Custom'
                  AND s.status=N'Active'
                  AND ISNULL(s.subscription_status,N'Active')=N'Active'
                  AND s.custom_release_name IS NOT NULL
                  AND (@organization_id IS NULL OR s.organization_id=@organization_id)
                ORDER BY ReleaseVersion;
                """;
            customCmd.CommandType = CommandType.Text;
            Add(customCmd, "@organization_id", JsonInt(payload, "organizationId"));
            var customTables = await ReadTablesAsync(customCmd, cancellationToken);
            if (customTables.Count > 0 && customTables[0].Count > 0 && tables.Count > 0)
                tables[0].AddRange(customTables[0]);
        }
        catch
        {
            // custom_release_name column not yet deployed — skip custom releases gracefully
        }

        return tables;
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryReleaseStatementsAsync(
        DbConnection connection, string search, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var releaseId = JsonInt(payload, "releaseId");
        if (organizationId is null || releaseId is null)
            return [new List<Dictionary<string, object?>>()];

        await using var command = connection.CreateCommand();
        command.CommandText = """
            IF NOT EXISTS(
                SELECT 1
                FROM grac_practice.repository_subscription s
                WHERE s.organization_id=@organization_id
                  AND s.release_id=@release_id
                  AND s.status='Active'
                  AND ISNULL(s.subscription_status,'Active')='Active'
            )
                THROW 51042, 'The selected framework release is not subscribed for this organization.', 1;

            ;WITH active_nodes AS (
                SELECT n.structure_node_id SourceStructureNodeId,
                       n.parent_node_id ParentSourceStructureNodeId,
                       n.node_level SourceStructureLevel,
                       n.node_reference SourceStructureReference,
                       n.node_title SourceStructureTitle,
                       n.description SourceStructureDescription,
                       n.display_order SourceStructureDisplayOrder
                FROM grac_new.source_structure_node n
                WHERE n.release_id=@release_id
                  AND n.status='Active'
            ),
            statement_practice_counts AS (
                -- Practices are linked to statements through
                -- organization_statement_practice_mapping (a practice exists once per
                -- organization but can be mapped to many applicable statements).
                SELECT m.framework_statement_id FrameworkStatementId,
                       COUNT(DISTINCT m.org_practice_id) PracticeCount,
                       COUNT(DISTINCT CASE WHEN COALESCE(aps.status_name,q.applicability_status)=N'Applicable' THEN m.org_practice_id END) ApplicablePracticeCount
                FROM grac_practice.organization_statement_practice_mapping m
                JOIN grac_practice.organization_requirement q ON q.organization_requirement_id=m.org_practice_id
                    AND q.status='Active'
                LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
                WHERE m.organization_id=@organization_id
                  AND m.status='Active'
                GROUP BY m.framework_statement_id
            )
            SELECT N'Node' RowType,
                   n.SourceStructureNodeId,
                   n.ParentSourceStructureNodeId,
                   n.SourceStructureLevel,
                   n.SourceStructureReference,
                   n.SourceStructureTitle,
                   n.SourceStructureDescription,
                   n.SourceStructureDisplayOrder,
                   CAST(NULL AS BIGINT) FrameworkStatementId,
                   CAST(NULL AS BIGINT) OrgStatementId,
                   CAST(NULL AS NVARCHAR(160)) StatementReference,
                   CAST(NULL AS NVARCHAR(500)) StatementTitle,
                   CAST(NULL AS NVARCHAR(MAX)) StatementText,
                   CAST(NULL AS INT) StatementDisplayOrder,
                   CAST(NULL AS NVARCHAR(40)) ApplicabilityStatus,
                   CAST(NULL AS BIGINT) OwnerId,
                   CAST(NULL AS NVARCHAR(300)) OwnerName,
                   CAST(0 AS BIGINT) ApplicablePracticeCount,
                   CAST(0 AS BIGINT) PracticeCount,
                   CAST(NULL AS NVARCHAR(MAX)) ExclusionJustification
            FROM active_nodes n
            UNION ALL
            SELECT N'Statement' RowType,
                   n.SourceStructureNodeId,
                   n.ParentSourceStructureNodeId,
                   n.SourceStructureLevel,
                   n.SourceStructureReference,
                   n.SourceStructureTitle,
                   n.SourceStructureDescription,
                   n.SourceStructureDisplayOrder,
                   fs.framework_statement_id FrameworkStatementId,
                   ofs.org_statement_id OrgStatementId,
                   fs.statement_reference StatementReference,
                   fs.statement_title StatementTitle,
                   fs.statement_text StatementText,
                   fs.display_order StatementDisplayOrder,
                   COALESCE(aps.status_name,N'Not Updated') ApplicabilityStatus,
                   ofs.owner_id OwnerId,
                   owner.employee_name OwnerName,
                   COALESCE(spc.ApplicablePracticeCount,0) ApplicablePracticeCount,
                   COALESCE(spc.PracticeCount,0) PracticeCount,
                   ofs.applicability_reason ExclusionJustification
            -- Repository statements drive this query. Organization applicability is a
            -- LEFT JOIN enrichment: a repository statement must never disappear just
            -- because the organization has not created its applicability row yet.
            FROM grac_new.framework_statement fs
            JOIN active_nodes n ON n.SourceStructureNodeId=fs.structure_node_id
            LEFT JOIN grac_practice.organization_framework_statements ofs
                ON ofs.framework_statement_id=fs.framework_statement_id
               AND ofs.organization_id=@organization_id
               AND ofs.release_id=@release_id
               AND ofs.status='Active'
            LEFT JOIN grac_practice.organization_employee owner ON owner.employee_id=ofs.owner_id
            LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=ofs.applicability_status_id
            LEFT JOIN statement_practice_counts spc ON spc.FrameworkStatementId=fs.framework_statement_id
            WHERE fs.release_id=@release_id
              AND fs.status='Active'
              AND (@p_search=''
                   OR ISNULL(fs.statement_reference,N'') LIKE N'%'+@p_search+N'%'
                   OR ISNULL(fs.statement_title,N'') LIKE N'%'+@p_search+N'%'
                   OR ISNULL(fs.statement_text,N'') LIKE N'%'+@p_search+N'%')
            ORDER BY SourceStructureDisplayOrder,SourceStructureReference,RowType,StatementDisplayOrder,StatementReference;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@organization_id", organizationId);
        Add(command, "@release_id", releaseId);
        Add(command, "@p_search", search ?? "");
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task SaveCustomReleaseAsync(
        DbConnection connection, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organizationId'));
            DECLARE @custom_release_name NVARCHAR(200)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.customReleaseName'))),N'');
            DECLARE @effective_dt DATE=TRY_CONVERT(DATE,JSON_VALUE(@payload,'$.effectiveDate'));
            DECLARE @end_dt DATE=TRY_CONVERT(DATE,JSON_VALUE(@payload,'$.endDate'));
            DECLARE @custom_release_notes NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.releaseNotes'))),N'');
            DECLARE @subscription_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.subscriptionId'));

            IF @organization_id IS NULL
                THROW 51060,'Organization is required.',1;
            IF @custom_release_name IS NULL
                THROW 51061,'Release name is required.',1;

            -- Validate org access
            DECLARE @allowed NVARCHAR(MAX)=JSON_QUERY(@payload,'$.allowedOrganizationIds');
            IF @allowed IS NOT NULL AND @allowed<>N'' AND @allowed<>N'[]'
            BEGIN
                IF NOT EXISTS(
                    SELECT 1 FROM OPENJSON(@allowed) WHERE TRY_CONVERT(BIGINT,[value])=@organization_id
                )
                    THROW 51062,'You do not have access to this organization.',1;
            END

            DECLARE @active_record_status_id INT=(SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
            DECLARE @active_subscription_status_id INT=(SELECT TOP (1) subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');

            IF @subscription_id IS NOT NULL AND @subscription_id > 0
            BEGIN
                -- Update existing custom release
                IF NOT EXISTS(
                    SELECT 1 FROM grac_practice.repository_subscription
                    WHERE subscription_id=@subscription_id
                      AND organization_id=@organization_id
                      AND subscription_type=N'Custom'
                      AND status=N'Active'
                )
                    THROW 51063,'Custom release not found or access denied.',1;

                UPDATE grac_practice.repository_subscription
                SET custom_release_name=@custom_release_name,
                    effective_dt=@effective_dt,
                    end_dt=@end_dt,
                    custom_release_notes=@custom_release_notes,
                    updated_by=@user_id,
                    updated_dt=SYSUTCDATETIME()
                WHERE subscription_id=@subscription_id;
            END
            ELSE
            BEGIN
                -- Check for duplicate name within same org custom releases
                IF EXISTS(
                    SELECT 1 FROM grac_practice.repository_subscription
                    WHERE organization_id=@organization_id
                      AND subscription_type=N'Custom'
                      AND custom_release_name=@custom_release_name
                      AND status=N'Active'
                )
                    THROW 51064,'A custom release with this name already exists for this organization.',1;

                INSERT grac_practice.repository_subscription(
                    organization_id,authority_id,artifact_id,release_id,
                    subscription_type,subscription_status,
                    effective_dt,end_dt,status,
                    custom_release_name,custom_release_notes,
                    record_status_id,subscription_status_id,
                    entered_by,entered_dt)
                VALUES(
                    @organization_id,NULL,NULL,NULL,
                    N'Custom',N'Active',
                    @effective_dt,@end_dt,N'Active',
                    @custom_release_name,@custom_release_notes,
                    COALESCE(@active_record_status_id,1),COALESCE(@active_subscription_status_id,1),
                    @user_id,SYSUTCDATETIME());
            END
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@payload", payload);
        Add(command, "@user_id", enteredBy);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryCustomReleaseStatementsAsync(
        DbConnection connection, string search, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var subscriptionId = JsonInt(payload, "subscriptionId");
        if (organizationId is null || subscriptionId is null)
            return [new List<Dictionary<string, object?>>()];

        await using var command = connection.CreateCommand();
        command.CommandText = """
            -- Validate custom release belongs to this organization
            IF NOT EXISTS(
                SELECT 1 FROM grac_practice.repository_subscription
                WHERE subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND subscription_type=N'Custom'
                  AND status=N'Active'
            )
                THROW 51042, 'The selected custom release is not found for this organization.', 1;

            ;WITH hierarchy AS (
                SELECT cs.custom_statement_id,
                       cs.parent_statement_id,
                       cs.node_level,
                       cs.display_order,
                       CAST(COALESCE(cs.statement_reference, cs.statement_title) AS NVARCHAR(MAX)) HierarchyPath
                FROM grac_practice.custom_release_statement cs
                WHERE cs.subscription_id=@subscription_id
                  AND cs.organization_id=@organization_id
                  AND cs.status=N'Active'
                  AND cs.parent_statement_id IS NULL
                UNION ALL
                SELECT cs.custom_statement_id,
                       cs.parent_statement_id,
                       cs.node_level,
                       cs.display_order,
                       CAST(h.HierarchyPath + N' / ' + COALESCE(cs.statement_reference, cs.statement_title) AS NVARCHAR(MAX))
                FROM grac_practice.custom_release_statement cs
                JOIN hierarchy h ON h.custom_statement_id=cs.parent_statement_id
                WHERE cs.subscription_id=@subscription_id
                  AND cs.organization_id=@organization_id
                  AND cs.status=N'Active'
            )
            SELECT
                cs.custom_statement_id CustomStatementId,
                cs.subscription_id SubscriptionId,
                cs.organization_id OrganizationId,
                cs.parent_statement_id ParentStatementId,
                cs.node_level NodeLevel,
                cs.display_order DisplayOrder,
                cs.statement_reference StatementReference,
                cs.statement_title StatementTitle,
                cs.statement_text StatementText,
                cs.keywords Keywords,
                cs.classification Classification,
                cs.practice_mapping PracticeMapping,
                COALESCE(aps.status_name,N'Not Updated') ApplicabilityStatus,
                h.HierarchyPath Hierarchy,
                0 PracticeCount,
                cs.structure_node_id StructureNodeId,
                ssn.node_reference StructureNodeReference,
                ssn.node_title StructureNodeTitle
            FROM grac_practice.custom_release_statement cs
            JOIN hierarchy h ON h.custom_statement_id=cs.custom_statement_id
            LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=cs.applicability_status_id
            LEFT JOIN grac_practice.custom_release_source_structure ssn ON ssn.structure_node_id=cs.structure_node_id AND ssn.status=N'Active'
            WHERE cs.subscription_id=@subscription_id
              AND cs.organization_id=@organization_id
              AND cs.status=N'Active'
              AND (@p_search=N''
                   OR ISNULL(cs.statement_reference,N'') LIKE N'%'+@p_search+N'%'
                   OR ISNULL(cs.statement_title,N'') LIKE N'%'+@p_search+N'%'
                   OR ISNULL(cs.statement_text,N'') LIKE N'%'+@p_search+N'%'
                   OR ISNULL(h.HierarchyPath,N'') LIKE N'%'+@p_search+N'%')
            ORDER BY h.HierarchyPath, cs.display_order, cs.statement_reference;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@organization_id", organizationId);
        Add(command, "@subscription_id", subscriptionId);
        Add(command, "@p_search", search ?? "");
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task SaveCustomStatementAsync(
        DbConnection connection, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organizationId'));
            DECLARE @subscription_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.subscriptionId'));
            DECLARE @custom_statement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.customStatementId'));
            DECLARE @parent_statement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.parentStatementId'));
            DECLARE @statement_reference NVARCHAR(160)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.statementReference'))),N'');
            DECLARE @statement_title NVARCHAR(500)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.statementTitle'))),N'');
            DECLARE @statement_text NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.statementText'))),N'');
            DECLARE @keywords NVARCHAR(500)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.keywords'))),N'');
            DECLARE @classification NVARCHAR(100)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.classification'))),N'');
            DECLARE @practice_mapping NVARCHAR(500)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.practiceMapping'))),N'');
            DECLARE @structure_node_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.structureNodeId'));
            DECLARE @action NVARCHAR(20)=COALESCE(NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.statementAction'))),N''),N'ADD');

            IF @organization_id IS NULL
                THROW 51070,'Organization is required.',1;
            IF @subscription_id IS NULL
                THROW 51071,'Custom release is required.',1;
            IF @statement_title IS NULL
                THROW 51072,'Statement title is required.',1;

            -- Validate structure node belongs to this release if specified
            IF @structure_node_id IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM grac_practice.custom_release_source_structure
                WHERE structure_node_id=@structure_node_id
                  AND subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND status=N'Active'
            )
                THROW 51076,'Source structure node not found or does not belong to this release.',1;

            -- Validate org access
            DECLARE @allowed NVARCHAR(MAX)=JSON_QUERY(@payload,'$.allowedOrganizationIds');
            IF @allowed IS NOT NULL AND @allowed<>N'' AND @allowed<>N'[]'
            BEGIN
                IF NOT EXISTS(
                    SELECT 1 FROM OPENJSON(@allowed) WHERE TRY_CONVERT(BIGINT,[value])=@organization_id
                )
                    THROW 51073,'You do not have access to this organization.',1;
            END

            -- Validate custom release belongs to org
            IF NOT EXISTS(
                SELECT 1 FROM grac_practice.repository_subscription
                WHERE subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND subscription_type=N'Custom'
                  AND status=N'Active'
            )
                THROW 51074,'Custom release not found or access denied.',1;

            IF @action=N'INACTIVATE' AND @custom_statement_id IS NOT NULL
            BEGIN
                UPDATE grac_practice.custom_release_statement
                SET status=N'Inactive', updated_by=@user_id, updated_dt=SYSUTCDATETIME()
                WHERE custom_statement_id=@custom_statement_id
                  AND organization_id=@organization_id
                  AND subscription_id=@subscription_id;
            END
            ELSE IF @custom_statement_id IS NOT NULL AND @custom_statement_id > 0
            BEGIN
                -- Update existing
                UPDATE grac_practice.custom_release_statement
                SET statement_reference=@statement_reference,
                    statement_title=@statement_title,
                    statement_text=@statement_text,
                    keywords=@keywords,
                    classification=@classification,
                    practice_mapping=@practice_mapping,
                    parent_statement_id=@parent_statement_id,
                    structure_node_id=@structure_node_id,
                    updated_by=@user_id,
                    updated_dt=SYSUTCDATETIME()
                WHERE custom_statement_id=@custom_statement_id
                  AND organization_id=@organization_id
                  AND subscription_id=@subscription_id
                  AND status=N'Active';
            END
            ELSE
            BEGIN
                -- Determine display_order
                DECLARE @next_order INT=(
                    SELECT COALESCE(MAX(display_order),0)+1
                    FROM grac_practice.custom_release_statement
                    WHERE subscription_id=@subscription_id
                      AND organization_id=@organization_id
                      AND COALESCE(parent_statement_id,0)=COALESCE(@parent_statement_id,0)
                      AND status=N'Active'
                );
                DECLARE @level INT=1;
                IF @parent_statement_id IS NOT NULL
                    SET @level=(SELECT COALESCE(node_level,1)+1 FROM grac_practice.custom_release_statement WHERE custom_statement_id=@parent_statement_id);

                INSERT grac_practice.custom_release_statement(
                    subscription_id,organization_id,parent_statement_id,
                    node_level,display_order,
                    statement_reference,statement_title,statement_text,
                    keywords,classification,practice_mapping,
                    structure_node_id,
                    status,entered_by,entered_dt)
                VALUES(
                    @subscription_id,@organization_id,@parent_statement_id,
                    @level,@next_order,
                    @statement_reference,@statement_title,@statement_text,
                    @keywords,@classification,@practice_mapping,
                    @structure_node_id,
                    N'Active',@user_id,SYSUTCDATETIME());
            END
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@payload", payload);
        Add(command, "@user_id", enteredBy);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    // --- Custom Release Source Structure ---
    private static async Task<List<List<Dictionary<string, object?>>>> QueryCustomReleaseSourceStructureAsync(
        DbConnection connection, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var subscriptionId = JsonInt(payload, "subscriptionId");
        if (organizationId is null || subscriptionId is null)
            return [new List<Dictionary<string, object?>>()];

        await using var command = connection.CreateCommand();
        command.CommandText = """
            IF NOT EXISTS(
                SELECT 1 FROM grac_practice.repository_subscription
                WHERE subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND subscription_type=N'Custom'
                  AND status=N'Active'
            )
                THROW 51080, 'The selected custom release is not found for this organization.', 1;

            ;WITH hierarchy AS (
                SELECT n.structure_node_id,
                       n.parent_node_id,
                       n.node_level,
                       n.display_order,
                       CAST(COALESCE(n.node_reference, n.node_title) AS NVARCHAR(MAX)) HierarchyPath
                FROM grac_practice.custom_release_source_structure n
                WHERE n.subscription_id=@subscription_id
                  AND n.organization_id=@organization_id
                  AND n.status=N'Active'
                  AND n.parent_node_id IS NULL
                UNION ALL
                SELECT n.structure_node_id,
                       n.parent_node_id,
                       n.node_level,
                       n.display_order,
                       CAST(h.HierarchyPath + N' / ' + COALESCE(n.node_reference, n.node_title) AS NVARCHAR(MAX))
                FROM grac_practice.custom_release_source_structure n
                JOIN hierarchy h ON h.structure_node_id=n.parent_node_id
                WHERE n.subscription_id=@subscription_id
                  AND n.organization_id=@organization_id
                  AND n.status=N'Active'
            )
            SELECT n.structure_node_id StructureNodeId,
                   n.subscription_id SubscriptionId,
                   n.organization_id OrganizationId,
                   n.parent_node_id ParentNodeId,
                   n.node_level NodeLevel,
                   n.display_order DisplayOrder,
                   n.node_reference NodeReference,
                   n.node_title NodeTitle,
                   n.description Description,
                   n.status Status,
                   h.HierarchyPath Hierarchy,
                   (SELECT COUNT(1) FROM grac_practice.custom_release_statement cs
                    WHERE cs.structure_node_id=n.structure_node_id AND cs.status=N'Active') StatementCount
            FROM grac_practice.custom_release_source_structure n
            JOIN hierarchy h ON h.structure_node_id=n.structure_node_id
            WHERE n.subscription_id=@subscription_id
              AND n.organization_id=@organization_id
              AND n.status=N'Active'
            ORDER BY h.HierarchyPath, n.display_order, n.node_reference;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@organization_id", organizationId);
        Add(command, "@subscription_id", subscriptionId);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task SaveCustomReleaseSourceStructureAsync(
        DbConnection connection, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organizationId'));
            DECLARE @subscription_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.subscriptionId'));
            DECLARE @structure_node_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.structureNodeId'));
            DECLARE @parent_node_id BIGINT=NULLIF(TRY_CONVERT(BIGINT,NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.parentNodeId'))),N'')),0);
            DECLARE @node_reference NVARCHAR(160)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.nodeReference'))),N'');
            DECLARE @node_title NVARCHAR(500)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.nodeTitle'))),N'');
            DECLARE @description NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.description'))),N'');
            DECLARE @action NVARCHAR(20)=COALESCE(NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.nodeAction'))),N''),N'ADD');

            IF @organization_id IS NULL
                THROW 51080,'Organization is required.',1;
            IF @subscription_id IS NULL
                THROW 51081,'Custom release is required.',1;
            IF @node_title IS NULL
                THROW 51082,'Node title is required.',1;

            -- Validate org access
            DECLARE @allowed NVARCHAR(MAX)=JSON_QUERY(@payload,'$.allowedOrganizationIds');
            IF @allowed IS NOT NULL AND @allowed<>N'' AND @allowed<>N'[]'
            BEGIN
                IF NOT EXISTS(
                    SELECT 1 FROM OPENJSON(@allowed) WHERE TRY_CONVERT(BIGINT,[value])=@organization_id
                )
                    THROW 51083,'You do not have access to this organization.',1;
            END

            -- Validate custom release belongs to org
            IF NOT EXISTS(
                SELECT 1 FROM grac_practice.repository_subscription
                WHERE subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND subscription_type=N'Custom'
                  AND status=N'Active'
            )
                THROW 51084,'Custom release not found or access denied.',1;

            -- Validate parent node belongs to same release if specified
            IF @parent_node_id IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM grac_practice.custom_release_source_structure
                WHERE structure_node_id=@parent_node_id
                  AND subscription_id=@subscription_id
                  AND organization_id=@organization_id
                  AND status=N'Active'
            )
                THROW 51085,'Parent node not found or does not belong to this release.',1;

            IF @action=N'INACTIVATE' AND @structure_node_id IS NOT NULL
            BEGIN
                -- Inactivate node and all children recursively
                ;WITH descendants AS (
                    SELECT structure_node_id FROM grac_practice.custom_release_source_structure
                    WHERE structure_node_id=@structure_node_id AND organization_id=@organization_id AND subscription_id=@subscription_id
                    UNION ALL
                    SELECT c.structure_node_id FROM grac_practice.custom_release_source_structure c
                    JOIN descendants d ON d.structure_node_id=c.parent_node_id
                    WHERE c.organization_id=@organization_id AND c.subscription_id=@subscription_id AND c.status=N'Active'
                )
                UPDATE grac_practice.custom_release_source_structure
                SET status=N'Inactive', updated_by=@user_id, updated_dt=SYSUTCDATETIME()
                WHERE structure_node_id IN (SELECT structure_node_id FROM descendants);

                -- Unlink statements from inactivated nodes
                UPDATE grac_practice.custom_release_statement
                SET structure_node_id=NULL, updated_by=@user_id, updated_dt=SYSUTCDATETIME()
                WHERE structure_node_id IN (SELECT structure_node_id FROM descendants)
                  AND organization_id=@organization_id
                  AND subscription_id=@subscription_id
                  AND status=N'Active';
            END
            ELSE IF @structure_node_id IS NOT NULL AND @structure_node_id > 0
            BEGIN
                -- Update existing node
                UPDATE grac_practice.custom_release_source_structure
                SET node_reference=@node_reference,
                    node_title=@node_title,
                    description=@description,
                    parent_node_id=@parent_node_id,
                    updated_by=@user_id,
                    updated_dt=SYSUTCDATETIME()
                WHERE structure_node_id=@structure_node_id
                  AND organization_id=@organization_id
                  AND subscription_id=@subscription_id
                  AND status=N'Active';
            END
            ELSE
            BEGIN
                -- Determine display_order
                DECLARE @next_order INT=(
                    SELECT COALESCE(MAX(display_order),0)+1
                    FROM grac_practice.custom_release_source_structure
                    WHERE subscription_id=@subscription_id
                      AND organization_id=@organization_id
                      AND COALESCE(parent_node_id,0)=COALESCE(@parent_node_id,0)
                      AND status=N'Active'
                );
                DECLARE @level INT=1;
                IF @parent_node_id IS NOT NULL
                    SET @level=(SELECT COALESCE(node_level,1)+1 FROM grac_practice.custom_release_source_structure WHERE structure_node_id=@parent_node_id);

                INSERT grac_practice.custom_release_source_structure(
                    subscription_id,organization_id,parent_node_id,
                    node_level,display_order,
                    node_reference,node_title,description,
                    status,entered_by,entered_dt)
                VALUES(
                    @subscription_id,@organization_id,@parent_node_id,
                    @level,@next_order,
                    @node_reference,@node_title,@description,
                    N'Active',@user_id,SYSUTCDATETIME());
            END
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@payload", payload);
        Add(command, "@user_id", enteredBy);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task SaveStatementApplicabilityAsync(
        DbConnection connection, string payload, string enteredBy, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @organization_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.organizationId'));
            DECLARE @release_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.releaseId'));
            DECLARE @framework_statement_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.frameworkStatementId'));
            DECLARE @status_name NVARCHAR(40)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.applicabilityStatus'))),N'');
            DECLARE @owner_id BIGINT=TRY_CONVERT(BIGINT,JSON_VALUE(@payload,'$.ownerId'));
            DECLARE @reason NVARCHAR(MAX)=NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload,'$.exclusionJustification'))),N'');
            DECLARE @status_id INT=(SELECT TOP (1) applicability_status_id FROM grac_practice.applicability_status_master WHERE status_name=@status_name OR status_code=@status_name);

            IF @organization_id IS NULL OR @release_id IS NULL OR @framework_statement_id IS NULL
                THROW 51043,'Organization, release and statement are required.',1;
            IF @status_name NOT IN (N'Not Updated',N'Applicable',N'Not Applicable',N'Retired')
                THROW 51044,'A valid statement applicability status is required.',1;
            IF @status_name IN (N'Applicable',N'Not Applicable') AND @owner_id IS NULL
                THROW 51047,'Owner is mandatory for statement applicability.',1;
            IF @status_name=N'Not Applicable' AND @reason IS NULL
                THROW 51045,'Reason is mandatory when statement is Not Applicable.',1;
            IF @owner_id IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM grac_practice.organization_employee e WHERE e.employee_id=@owner_id AND e.organization_id=@organization_id AND e.status='Active'
            )
                THROW 51048,'The selected owner is not valid for this organization.',1;
            IF NOT EXISTS(
                SELECT 1 FROM grac_practice.repository_subscription s
                WHERE s.organization_id=@organization_id AND s.release_id=@release_id AND s.status='Active' AND ISNULL(s.subscription_status,'Active')='Active'
            )
                THROW 51042,'The selected framework release is not subscribed for this organization.',1;
            IF NOT EXISTS(
                SELECT 1 FROM grac_new.framework_statement fs
                WHERE fs.framework_statement_id=@framework_statement_id AND fs.release_id=@release_id AND fs.status='Active'
            )
                THROW 51046,'The selected statement is not valid for this release.',1;

            DECLARE @active_record_status_id INT=(SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
            DECLARE @org_statement_id BIGINT;

            MERGE grac_practice.organization_framework_statements AS target
            USING (SELECT @organization_id organization_id,@release_id release_id,@framework_statement_id framework_statement_id) AS src
               ON target.organization_id=src.organization_id
              AND target.release_id=src.release_id
              AND target.framework_statement_id=src.framework_statement_id
            WHEN MATCHED THEN UPDATE SET
                applicability_status_id=@status_id,
                owner_id=@owner_id,
                applicability_reason=CASE WHEN @status_name=N'Not Applicable' THEN @reason ELSE NULL END,
                status_id=@active_record_status_id,
                status=N'Active',
                updated_by=@user_id,
                updated_dt=SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT(
                organization_id,release_id,framework_statement_id,applicability_status_id,owner_id,applicability_reason,status_id,status,entered_by)
            VALUES(
                @organization_id,@release_id,@framework_statement_id,@status_id,@owner_id,CASE WHEN @status_name=N'Not Applicable' THEN @reason ELSE NULL END,@active_record_status_id,N'Active',@user_id);

            SELECT @org_statement_id=org_statement_id
            FROM grac_practice.organization_framework_statements
            WHERE organization_id=@organization_id
              AND release_id=@release_id
              AND framework_statement_id=@framework_statement_id;

            IF @status_name=N'Applicable'
            BEGIN
                DECLARE @not_updated_status_id INT=(SELECT TOP (1) applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
                DECLARE @not_started_status_id INT=(SELECT TOP (1) implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');

                -- Step 1: import mapped repository practices ONCE per organization.
                -- Dedup is organization-level (repository_requirement_id / requirement_code),
                -- NOT per statement: if the practice was already imported for this
                -- organization (by any statement), its existing row is reused.
                ;WITH mapped_practices AS (
                    SELECT DISTINCT q.requirement_id repository_requirement_id,
                           q.requirement_code,
                           q.requirement_name,
                           q.requirement_statement,
                           q.objective
                    FROM grac_new.framework_statement_requirement_map fsrm
                    JOIN grac_new.requirement q ON q.requirement_id=fsrm.requirement_id AND q.status='Active'
                    WHERE fsrm.framework_statement_id=@framework_statement_id
                      AND fsrm.status='Active'
                )
                INSERT grac_practice.organization_requirement(
                    organization_id,org_statement_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
                    requirement_statement,objective,applicability_status,applicability_status_id,implementation_status,implementation_status_id,status,record_status_id,entered_by)
                SELECT @organization_id,@org_statement_id,'Repository',mp.repository_requirement_id,NULL,mp.requirement_code,mp.requirement_name,
                       mp.requirement_statement,mp.objective,'Not Updated',@not_updated_status_id,'Not Started',@not_started_status_id,'Active',@active_record_status_id,@user_id
                FROM mapped_practices mp
                WHERE NOT EXISTS(
                    SELECT 1 FROM grac_practice.organization_requirement existing
                    WHERE existing.organization_id=@organization_id
                      AND existing.status='Active'
                      AND (existing.repository_requirement_id=mp.repository_requirement_id OR existing.requirement_code=mp.requirement_code)
                );

                -- Step 2: link this statement to each (new or reused) organization
                -- practice through the mapping table. Unique constraint
                -- (organization_id,org_statement_id,org_practice_id) + NOT EXISTS
                -- guard prevent duplicate mappings.
                INSERT grac_practice.organization_statement_practice_mapping(
                    organization_id,org_statement_id,framework_statement_id,repository_requirement_id,org_practice_id,release_id,status,record_status_id,entered_by)
                SELECT @organization_id,@org_statement_id,@framework_statement_id,rq.requirement_id,op.organization_requirement_id,@release_id,'Active',@active_record_status_id,@user_id
                FROM grac_new.framework_statement_requirement_map fsrm
                JOIN grac_new.requirement rq ON rq.requirement_id=fsrm.requirement_id AND rq.status='Active'
                JOIN grac_practice.organization_requirement op ON op.organization_id=@organization_id
                    AND op.status='Active'
                    AND (op.repository_requirement_id=rq.requirement_id
                         OR (op.repository_requirement_id IS NULL AND op.requirement_code=rq.requirement_code))
                WHERE fsrm.framework_statement_id=@framework_statement_id
                  AND fsrm.status='Active'
                  AND NOT EXISTS(
                      SELECT 1 FROM grac_practice.organization_statement_practice_mapping m
                      WHERE m.organization_id=@organization_id
                        AND m.org_statement_id=@org_statement_id
                        AND m.org_practice_id=op.organization_requirement_id
                  );
            END
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@payload", string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
        Add(command, "@user_id", string.IsNullOrWhiteSpace(enteredBy) ? "system" : enteredBy);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryOrganizationControlFallbackAsync(
        DbConnection connection, string entityType, int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        if (entityType.Equals("organization-controls", StringComparison.OrdinalIgnoreCase))
        {
            command.CommandText = """
                ;WITH base AS (
                    SELECT
                      oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
                      oc.control_code Code,oc.control_name Name,oc.description Description,oc.business_justification BusinessJustification,
                      oc.objective Objective,oc.control_domain_id DomainId,oc.control_sub_domain_id SubDomainId,oc.is_manually_added IsManuallyAdded,
                      oc.subscription_id SubscriptionId,oc.release_id ReleaseId,oc.artifact_id ArtifactId,
                      COALESCE(a.artifact_code + N' / ' + r.version_no, CASE WHEN oc.origin_type='Organization' THEN N'Organization Defined' END) SourceFrameworkRelease,
                      aps.status_name ApplicabilityStatus,oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.backup_owner BackupOwner,
                      oc.business_function_id BusinessFunctionId,oc.criticality Criticality,rs.status_name Status,oc.entered_dt EnteredDate,
                      CASE WHEN oc.repository_control_id IS NOT NULL THEN N'R:' + CONVERT(NVARCHAR(40),oc.repository_control_id) ELSE N'M:' + CONVERT(NVARCHAR(40),oc.organization_control_id) END ControlGroupKey
                    FROM grac_practice.organization_control oc
                    JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
                    JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
                    LEFT JOIN grac_new.release r ON r.release_id=oc.release_id
                    LEFT JOIN grac_new.artifact a ON a.artifact_id=COALESCE(oc.artifact_id,r.artifact_id)
                    WHERE (@organization_id IS NULL OR oc.organization_id=@organization_id)
                      AND (@p_status='' OR rs.status_code=@p_status OR rs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
                      AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
                      AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
                      AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
                      AND (@date_from IS NULL OR oc.entered_dt>=@date_from)
                      AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
                ),
                source_values AS (
                    SELECT DISTINCT OrganizationId,ControlGroupKey,SourceFrameworkRelease
                    FROM base
                    WHERE SourceFrameworkRelease IS NOT NULL AND SourceFrameworkRelease<>N''
                ),
                source_agg AS (
                    SELECT OrganizationId,ControlGroupKey,STRING_AGG(SourceFrameworkRelease,N', ') WITHIN GROUP (ORDER BY SourceFrameworkRelease) SourceFrameworkRelease
                    FROM source_values
                    GROUP BY OrganizationId,ControlGroupKey
                ),
                group_flags AS (
                    SELECT OrganizationId,ControlGroupKey,MAX(CASE WHEN Id=@p_id THEN 1 ELSE 0 END) HasRequestedId
                    FROM base
                    GROUP BY OrganizationId,ControlGroupKey
                ),
                ranked AS (
                    SELECT base.*,ROW_NUMBER() OVER(PARTITION BY base.OrganizationId,base.ControlGroupKey ORDER BY CASE WHEN base.Id=@p_id THEN 0 ELSE 1 END,base.Id) RowNumber
                    FROM base
                )
                SELECT ranked.Id,ranked.OrganizationId,ranked.OriginType,ranked.RepositoryControlId,
                  ranked.Code,ranked.Name,ranked.Description,ranked.BusinessJustification,ranked.Objective,
                  ranked.DomainId,ranked.SubDomainId,ranked.IsManuallyAdded,ranked.SubscriptionId,ranked.ReleaseId,ranked.ArtifactId,
                  COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease) SourceFrameworkRelease,
                  ranked.ApplicabilityStatus,ranked.PrimaryOwner,ranked.SecondaryOwner,ranked.BackupOwner,
                  ranked.BusinessFunctionId,ranked.Criticality,ranked.Status
                FROM ranked
                JOIN group_flags ON group_flags.OrganizationId=ranked.OrganizationId AND group_flags.ControlGroupKey=ranked.ControlGroupKey
                LEFT JOIN source_agg ON source_agg.OrganizationId=ranked.OrganizationId AND source_agg.ControlGroupKey=ranked.ControlGroupKey
                WHERE ranked.RowNumber=1
                  AND (@p_id=0 OR group_flags.HasRequestedId=1)
                  AND (@p_search='' OR ISNULL(ranked.Code,'') LIKE '%'+@p_search+'%' OR ISNULL(ranked.Name,'') LIKE '%'+@p_search+'%' OR ISNULL(ranked.OriginType,'') LIKE '%'+@p_search+'%' OR ISNULL(COALESCE(source_agg.SourceFrameworkRelease,ranked.SourceFrameworkRelease),'') LIKE '%'+@p_search+'%')
                ORDER BY ranked.Code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
                """;
            command.CommandType = CommandType.Text;
            Add(command, "@p_id", id);
            Add(command, "@organization_id", JsonInt(payload, "organizationId"));
            Add(command, "@p_status", status ?? "");
            Add(command, "@origin_type", JsonText(payload, "originType"));
            Add(command, "@owner", JsonText(payload, "owner"));
            Add(command, "@criticality", JsonText(payload, "criticality"));
            Add(command, "@date_from", JsonDate(payload, "dateFrom"));
            Add(command, "@date_to", JsonDate(payload, "dateTo"));
            Add(command, "@p_search", search ?? "");
            var groupedPageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
            var groupedPageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
            Add(command, "@offset", (groupedPageNumber - 1) * groupedPageSize);
            Add(command, "@page_size", groupedPageSize);
            return await ReadTablesAsync(command, cancellationToken);
        }
        var selectColumns = entityType.Equals("organization-controls", StringComparison.OrdinalIgnoreCase)
            ? """
              oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
              oc.control_code Code,oc.control_name Name,oc.description Description,oc.business_justification BusinessJustification,
              oc.objective Objective,oc.control_domain_id DomainId,oc.control_sub_domain_id SubDomainId,oc.is_manually_added IsManuallyAdded,
              oc.subscription_id SubscriptionId,oc.release_id ReleaseId,oc.artifact_id ArtifactId,
              COALESCE(a.artifact_code + N' / ' + r.version_no, CASE WHEN oc.origin_type='Organization' THEN N'Organization Defined' END) SourceFrameworkRelease,
              aps.status_name ApplicabilityStatus,oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.backup_owner BackupOwner,
              oc.business_function_id BusinessFunctionId,oc.criticality Criticality,rs.status_name Status
              """
            : """
              oc.organization_control_id Id,oc.organization_id OrganizationId,oc.origin_type OriginType,oc.repository_control_id RepositoryControlId,
              oc.control_code Code,oc.control_name Name,oc.description Description,oc.objective Objective,
              oc.is_manually_added IsManuallyAdded,aps.status_name ApplicabilityStatus,oc.exclusion_justification ExclusionJustification,
              oc.primary_owner PrimaryOwner,oc.secondary_owner SecondaryOwner,oc.business_function_id BusinessFunctionId,bf.function_name BusinessFunction,
              oc.criticality Criticality,rs.status_name Status
              """;
        command.CommandText = $"""
            SELECT {selectColumns}
            FROM grac_practice.organization_control oc
            JOIN grac_practice.record_status_master rs ON rs.record_status_id=oc.record_status_id
            JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=oc.applicability_status_id
            LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=oc.business_function_id
            LEFT JOIN grac_new.release r ON r.release_id=oc.release_id
            LEFT JOIN grac_new.artifact a ON a.artifact_id=COALESCE(oc.artifact_id,r.artifact_id)
            WHERE (@p_id=0 OR oc.organization_control_id=@p_id)
              AND (@organization_id IS NULL OR oc.organization_id=@organization_id)
              AND (@p_status='' OR rs.status_code=@p_status OR rs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
              AND (@origin_type IS NULL OR ISNULL(oc.origin_type,'')=@origin_type)
              AND (@owner IS NULL OR ISNULL(oc.primary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.secondary_owner,'') LIKE '%'+@owner+'%' OR ISNULL(oc.backup_owner,'') LIKE '%'+@owner+'%')
              AND (@criticality IS NULL OR ISNULL(oc.criticality,'')=@criticality)
              AND (@date_from IS NULL OR oc.entered_dt>=@date_from)
              AND (@date_to IS NULL OR oc.entered_dt<DATEADD(DAY,1,@date_to))
              AND (@p_search='' OR ISNULL(oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.origin_type,'') LIKE '%'+@p_search+'%' OR ISNULL(bf.function_name,'') LIKE '%'+@p_search+'%' OR ISNULL(a.artifact_code,'') LIKE '%'+@p_search+'%' OR ISNULL(r.version_no,'') LIKE '%'+@p_search+'%')
            ORDER BY oc.control_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", JsonInt(payload, "organizationId"));
        Add(command, "@p_status", status ?? "");
        Add(command, "@origin_type", JsonText(payload, "originType"));
        Add(command, "@owner", JsonText(payload, "owner"));
        Add(command, "@criticality", JsonText(payload, "criticality"));
        Add(command, "@date_from", JsonDate(payload, "dateFrom"));
        Add(command, "@date_to", JsonDate(payload, "dateTo"));
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryOrganizationRequirementFallbackAsync(
        DbConnection connection, int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var organizationControlId = JsonInt(payload, "organizationControlId");
        var releaseId = JsonInt(payload, "releaseId");
        var frameworkStatementId = JsonInt(payload, "frameworkStatementId");

        if (organizationId is not null && releaseId is not null)
        {
            await SyncOrganizationFrameworkStatementsAsync(connection, payload, "system-fallback", cancellationToken);

            await using var importCommand = connection.CreateCommand();
            importCommand.CommandText = """
                DECLARE @active_record_status_id INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
                DECLARE @not_updated_applicability_status_id INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
                DECLARE @not_started_implementation_status_id INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');

                IF NOT EXISTS(
                    SELECT 1
                    FROM grac_practice.repository_subscription s
                    WHERE s.organization_id=@organization_id
                      AND s.release_id=@release_id
                      AND s.status='Active'
                      AND ISNULL(s.subscription_status,'Active')='Active'
                )
                    THROW 51042, 'The selected framework release is not subscribed for this organization.', 1;

                -- Statement -> practice candidates for this organization/release.
                ;WITH statement_practices AS (
                    SELECT
                        ofs.org_statement_id,
                        ofs.framework_statement_id,
                        ofs.release_id,
                        q.requirement_id repository_requirement_id,
                        q.requirement_code,
                        q.requirement_name,
                        q.requirement_statement,
                        q.objective
                    FROM grac_practice.organization_framework_statements ofs
                    JOIN grac_new.framework_statement fs ON fs.framework_statement_id=ofs.framework_statement_id AND fs.release_id=ofs.release_id AND fs.status='Active'
                    JOIN grac_new.framework_statement_requirement_map fsrm ON fsrm.framework_statement_id=fs.framework_statement_id AND fsrm.status='Active'
                    JOIN grac_new.requirement q ON q.requirement_id=fsrm.requirement_id AND q.status='Active'
                    WHERE ofs.organization_id=@organization_id
                      AND ofs.release_id=@release_id
                      AND ofs.status='Active'
                      AND (@framework_statement_id IS NULL OR fs.framework_statement_id=@framework_statement_id)
                ),
                distinct_practices AS (
                    SELECT repository_requirement_id,requirement_code,requirement_name,requirement_statement,objective,
                           org_statement_id first_org_statement_id,
                           ROW_NUMBER() OVER(PARTITION BY repository_requirement_id ORDER BY org_statement_id) row_no
                    FROM statement_practices
                    GROUP BY repository_requirement_id,requirement_code,requirement_name,requirement_statement,objective,org_statement_id
                )
                -- One organization practice per repository practice (organization-level dedup).
                INSERT grac_practice.organization_requirement(
                    organization_id,org_statement_id,origin_type,repository_requirement_id,organization_control_id,requirement_code,requirement_name,
                    requirement_statement,objective,applicability_status,applicability_status_id,implementation_status,implementation_status_id,status,record_status_id,entered_by)
                SELECT @organization_id,c.first_org_statement_id,'Repository',c.repository_requirement_id,NULL,c.requirement_code,c.requirement_name,
                    c.requirement_statement,c.objective,'Not Updated',@not_updated_applicability_status_id,'Not Started',@not_started_implementation_status_id,'Active',@active_record_status_id,'system-fallback'
                FROM distinct_practices c
                WHERE c.row_no=1
                  AND NOT EXISTS(
                      SELECT 1
                      FROM grac_practice.organization_requirement existing
                      WHERE existing.organization_id=@organization_id
                        AND existing.status='Active'
                        AND (
                            existing.requirement_code=c.requirement_code
                            OR existing.repository_requirement_id=c.repository_requirement_id
                        )
                  );

                -- Link every statement to its (new or reused) organization practice.
                ;WITH statement_practices AS (
                    SELECT
                        ofs.org_statement_id,
                        ofs.framework_statement_id,
                        ofs.release_id,
                        q.requirement_id repository_requirement_id,
                        q.requirement_code
                    FROM grac_practice.organization_framework_statements ofs
                    JOIN grac_new.framework_statement fs ON fs.framework_statement_id=ofs.framework_statement_id AND fs.release_id=ofs.release_id AND fs.status='Active'
                    JOIN grac_new.framework_statement_requirement_map fsrm ON fsrm.framework_statement_id=fs.framework_statement_id AND fsrm.status='Active'
                    JOIN grac_new.requirement q ON q.requirement_id=fsrm.requirement_id AND q.status='Active'
                    WHERE ofs.organization_id=@organization_id
                      AND ofs.release_id=@release_id
                      AND ofs.status='Active'
                      AND (@framework_statement_id IS NULL OR fs.framework_statement_id=@framework_statement_id)
                )
                INSERT grac_practice.organization_statement_practice_mapping(
                    organization_id,org_statement_id,framework_statement_id,repository_requirement_id,org_practice_id,release_id,status,record_status_id,entered_by)
                SELECT DISTINCT @organization_id,sp.org_statement_id,sp.framework_statement_id,sp.repository_requirement_id,op.organization_requirement_id,sp.release_id,'Active',@active_record_status_id,'system-fallback'
                FROM statement_practices sp
                JOIN grac_practice.organization_requirement op ON op.organization_id=@organization_id
                    AND op.status='Active'
                    AND (op.repository_requirement_id=sp.repository_requirement_id
                         OR (op.repository_requirement_id IS NULL AND op.requirement_code=sp.requirement_code))
                WHERE NOT EXISTS(
                    SELECT 1 FROM grac_practice.organization_statement_practice_mapping m
                    WHERE m.organization_id=@organization_id
                      AND m.org_statement_id=sp.org_statement_id
                      AND m.org_practice_id=op.organization_requirement_id
                );
                """;
            importCommand.CommandType = CommandType.Text;
            Add(importCommand, "@organization_id", organizationId);
            Add(importCommand, "@release_id", releaseId);
            Add(importCommand, "@framework_statement_id", frameworkStatementId);
            await importCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await using var command = connection.CreateCommand();
        command.CommandText = """
            ;WITH requirement_statement AS (
                SELECT
                    q.organization_requirement_id OrganizationRequirementId,
                    n.structure_node_id SourceStructureNodeId,
                    n.parent_node_id ParentSourceStructureNodeId,
                    n.node_level SourceStructureLevel,
                    n.node_reference SourceStructureReference,
                    n.node_title SourceStructureTitle,
                    n.display_order SourceStructureDisplayOrder,
                    fs.framework_statement_id FrameworkStatementId,
                    fs.statement_reference FrameworkStatementReference,
                    fs.statement_title FrameworkStatementTitle,
                    fs.display_order FrameworkStatementDisplayOrder,
                    fs.statement_text FrameworkStatementText
                FROM grac_practice.organization_requirement q
                JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=q.org_statement_id
                    AND ofs.organization_id=q.organization_id
                    AND ofs.status='Active'
                JOIN grac_new.framework_statement fs ON fs.framework_statement_id=ofs.framework_statement_id
                    AND fs.release_id=ofs.release_id
                    AND fs.status='Active'
                JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id AND n.status='Active'
            )
            SELECT
                q.organization_requirement_id Id,
                q.organization_id OrganizationId,
                q.origin_type OriginType,
                q.repository_requirement_id RepositoryRequirementId,
                q.org_statement_id OrgStatementId,
                q.organization_control_id OrganizationControlId,
                COALESCE(oc.control_code,fs.statement_reference) ControlCode,
                COALESCE(oc.control_name,fs.statement_title) ControlName,
                COALESCE(CONCAT(oc.control_code,N' - ',oc.control_name),CONCAT(fs.statement_reference,N' - ',fs.statement_title)) MappedControl,
                COALESCE(ofs.release_id,oc.release_id) ReleaseId,
                COALESCE(r.artifact_id,oc.artifact_id) ArtifactId,
                q.requirement_code Code,
                q.requirement_name Name,
                q.requirement_statement Statement,
                q.objective Objective,
                rsmap.SourceStructureNodeId,
                rsmap.ParentSourceStructureNodeId,
                rsmap.SourceStructureLevel,
                rsmap.SourceStructureReference,
                rsmap.SourceStructureTitle,
                rsmap.SourceStructureDisplayOrder,
                rsmap.FrameworkStatementId,
                rsmap.FrameworkStatementReference,
                rsmap.FrameworkStatementTitle,
                rsmap.FrameworkStatementDisplayOrder,
                rsmap.FrameworkStatementText,
                COALESCE(aps.status_name,q.applicability_status) ApplicabilityStatus,
                COALESCE(aps.status_code,q.applicability_status) ApplicabilityStatusCode,
                COALESCE(ims.status_name,q.implementation_status) ImplementationStatus,
                COALESCE(owner.employee_name,p.practice_owner,N'') PracticeOwner,
                COALESCE(pic.PracticeInstanceCount,0) PracticeInstanceCount,
                COALESCE(rs.status_name,q.status) Status
            FROM grac_practice.organization_requirement q
            LEFT JOIN grac_practice.organization_framework_statements ofs ON ofs.org_statement_id=q.org_statement_id
                AND ofs.organization_id=q.organization_id
            LEFT JOIN grac_new.framework_statement fs ON fs.framework_statement_id=ofs.framework_statement_id
                AND fs.release_id=ofs.release_id
            LEFT JOIN grac_new.release r ON r.release_id=ofs.release_id
            LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id=q.organization_control_id
            LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=q.record_status_id
            LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=q.applicability_status_id
            LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id=q.implementation_status_id
            LEFT JOIN requirement_statement rsmap ON rsmap.OrganizationRequirementId=q.organization_requirement_id
            OUTER APPLY (
                SELECT TOP (1) p.practice_owner_id,p.practice_owner
                FROM grac_practice.practice p
                WHERE p.organization_requirement_id=q.organization_requirement_id
                  AND p.organization_id=q.organization_id
                  AND p.status='Active'
                ORDER BY CASE WHEN p.practice_owner_id IS NULL AND NULLIF(p.practice_owner,N'') IS NULL THEN 1 ELSE 0 END,p.practice_id
            ) p
            OUTER APPLY (
                -- practice_instance links to the requirement through practice;
                -- it has no organization_requirement_id column of its own.
                SELECT COUNT_BIG(1) PracticeInstanceCount
                FROM grac_practice.practice_instance pi
                JOIN grac_practice.practice pp ON pp.practice_id=pi.practice_id
                WHERE pp.organization_requirement_id=q.organization_requirement_id
                  AND pi.organization_id=q.organization_id
                  AND pi.status='Active'
            ) pic
            LEFT JOIN grac_practice.organization_employee owner ON owner.employee_id=p.practice_owner_id
            WHERE EXISTS(
                  SELECT 1
                  FROM grac_practice.repository_subscription s
                  WHERE s.organization_id=q.organization_id
                    AND s.release_id=COALESCE(ofs.release_id,oc.release_id)
                    AND s.status='Active'
                    AND ISNULL(s.subscription_status,'Active')='Active'
              )
              AND (@p_id=0 OR q.organization_requirement_id=@p_id)
              AND (@organization_id IS NULL OR q.organization_id=@organization_id)
              AND (@organization_control_id IS NULL OR q.organization_control_id=@organization_control_id)
              AND (@release_id IS NULL OR COALESCE(ofs.release_id,oc.release_id)=@release_id)
              -- Statement-scoped view: resolve statement membership through
              -- organization_statement_practice_mapping so a practice linked to
              -- multiple applicable statements appears under each of them.
              AND (@framework_statement_id IS NULL
                   OR EXISTS(
                       SELECT 1
                       FROM grac_practice.organization_statement_practice_mapping m
                       WHERE m.org_practice_id=q.organization_requirement_id
                         AND m.organization_id=q.organization_id
                         AND m.framework_statement_id=@framework_statement_id
                         AND m.status='Active')
                   OR ofs.framework_statement_id=@framework_statement_id)
              AND (@p_status='' OR rs.status_code=@p_status OR rs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status OR ims.status_code=@p_status OR ims.status_name=@p_status)
              AND (@origin_type IS NULL OR q.origin_type=@origin_type)
              AND (@date_from IS NULL OR q.entered_dt>=@date_from)
              AND (@date_to IS NULL OR q.entered_dt<DATEADD(DAY,1,@date_to))
              AND (@p_search='' OR ISNULL(q.requirement_code,'') LIKE '%'+@p_search+'%' OR ISNULL(q.requirement_name,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_code,'') LIKE '%'+@p_search+'%' OR ISNULL(oc.control_name,'') LIKE '%'+@p_search+'%' OR ISNULL(fs.statement_reference,'') LIKE '%'+@p_search+'%' OR ISNULL(fs.statement_title,'') LIKE '%'+@p_search+'%')
            ORDER BY COALESCE(rsmap.SourceStructureDisplayOrder,2147483647),COALESCE(rsmap.FrameworkStatementDisplayOrder,2147483647),COALESCE(fs.statement_reference,oc.control_code),q.requirement_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", organizationId);
        Add(command, "@organization_control_id", organizationControlId);
        Add(command, "@release_id", releaseId);
        Add(command, "@framework_statement_id", frameworkStatementId);
        Add(command, "@p_status", status ?? "");
        Add(command, "@origin_type", JsonText(payload, "originType"));
        Add(command, "@date_from", JsonDate(payload, "dateFrom"));
        Add(command, "@date_to", JsonDate(payload, "dateTo"));
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryPracticeInstanceFallbackAsync(DbConnection connection,
        int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var organizationRequirementId = JsonInt(payload, "organizationRequirementId");
        var practiceId = JsonInt(payload, "practiceId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT
                pi.practice_instance_id Id,
                pi.practice_id PracticeId,
                COALESCE(p.organization_requirement_id,@organization_requirement_id) OrganizationRequirementId,
                pi.organization_id OrganizationId,
                pi.instance_code Code,
                pi.instance_name Name,
                pi.primary_owner_id PrimaryOwnerId,
                COALESCE(emp.employee_name,pi.primary_owner) PrimaryOwner,
                pi.secondary_owner SecondaryOwner,
                pi.business_function_id BusinessFunctionId,
                pi.department_id DepartmentId,
                COALESCE(dept.department_name,pi.department) Department,
                pi.execution_frequency_id ExecutionFrequencyId,
                execf.frequency_name ExecutionFrequency,
                pi.assurance_frequency_id AssuranceFrequencyId,
                assurf.frequency_name AssuranceFrequency,
                COALESCE(pi.execution_frequency_id,pi.frequency_id) FrequencyId,
                COALESCE(execf.frequency_code,f.frequency_code,pi.frequency_type) FrequencyType,
                COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_value END,pi.frequency_value) FrequencyValue,
                COALESCE(CASE WHEN f.is_custom=0 THEN f.frequency_unit END,pi.frequency_unit) FrequencyUnit,
                pi.assurance_mode AssuranceMode,
                pi.criticality Criticality,
                pi.implementation_status ImplementationStatus,
                COALESCE(rs.status_name,pi.status) Status
            FROM grac_practice.practice_instance pi
            LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
            LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
            LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
            LEFT JOIN grac_practice.frequency_master assurf ON assurf.frequency_id=pi.assurance_frequency_id
            LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=pi.record_status_id
            LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=pi.primary_owner_id
            LEFT JOIN grac_practice.organization_department dept ON dept.department_id=pi.department_id
            WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
              AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
              AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
              AND (
                    @organization_requirement_id IS NULL
                    OR p.organization_requirement_id=@organization_requirement_id
                    OR EXISTS (
                        SELECT 1
                        FROM grac_practice.organization_requirement q
                        WHERE q.organization_requirement_id=@organization_requirement_id
                          AND q.organization_id=pi.organization_id
                          AND (q.requirement_code=p.practice_code OR q.requirement_name=p.practice_name)
                    )
                  )
              AND (@p_status='' OR pi.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
              AND (@owner IS NULL OR pi.primary_owner LIKE '%'+@owner+'%' OR pi.secondary_owner LIKE '%'+@owner+'%')
              AND (@criticality IS NULL OR pi.criticality=@criticality)
              AND (@date_from IS NULL OR pi.entered_dt>=@date_from)
              AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
              AND (@p_search='' OR pi.instance_code LIKE '%'+@p_search+'%' OR pi.instance_name LIKE '%'+@p_search+'%')
            ORDER BY pi.instance_code OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", organizationId);
        Add(command, "@organization_requirement_id", organizationRequirementId);
        Add(command, "@practice_id", practiceId);
        Add(command, "@p_status", status ?? "");
        Add(command, "@owner", JsonText(payload, "owner"));
        Add(command, "@criticality", JsonText(payload, "criticality"));
        Add(command, "@date_from", JsonDate(payload, "dateFrom"));
        Add(command, "@date_to", JsonDate(payload, "dateTo"));
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryPracticeOperationalizationFallbackAsync(DbConnection connection,
        int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var practiceId = JsonInt(payload, "practiceId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT
                pi.practice_instance_id Id,
                pi.practice_instance_id PracticeInstanceId,
                pi.organization_id OrganizationId,
                pi.instance_code Code,
                pi.instance_name Name,
                ISNULL(bf.function_name,ISNULL(pi.department,N'')) OwningDepartment,
                pi.primary_owner PrimaryOwner,
                ISNULL(execf.frequency_name,ISNULL(f.frequency_name,ISNULL(pi.frequency_type,N''))) Frequency,
                N'' EvidenceTypes,
                N'' DependencyCategories,
                0 ResolvedDependenciesCount,
                0 PendingDependenciesCount,
                CASE
                    WHEN pi.status IN ('Inactive','Retired') OR prs.status_code IN ('Inactive','Retired') THEN N'Retired'
                    WHEN EXISTS (
                        SELECT 1
                        FROM grac_practice.practice_instance_dependency d
                        WHERE d.practice_instance_id=pi.practice_instance_id
                          AND d.organization_id=pi.organization_id
                          AND d.dependency_type_id IS NOT NULL
                          AND d.status='Active'
                    ) THEN N'Configured'
                    ELSE N'Dependency Categories Pending'
                END OperationalizationStatus,
                ISNULL(prs.status_name,pi.status) Status
            FROM grac_practice.practice_instance pi
            LEFT JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
            LEFT JOIN grac_practice.organization_requirement req ON req.organization_requirement_id=p.organization_requirement_id
            LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=req.applicability_status_id
            LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
            LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
            LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
            LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
            WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
              AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
              AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
              AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status OR aps.status_code=@p_status OR aps.status_name=@p_status)
              AND (@owner IS NULL OR ISNULL(pi.primary_owner,N'') LIKE N'%'+@owner+N'%' OR ISNULL(pi.secondary_owner,N'') LIKE N'%'+@owner+N'%')
              AND (@criticality IS NULL OR ISNULL(pi.criticality,N'')=@criticality)
              AND (@p_search='' OR ISNULL(pi.instance_code,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(pi.instance_name,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(bf.function_name,ISNULL(pi.department,N'')) LIKE N'%'+@p_search+N'%')
            ORDER BY pi.instance_name OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

            SELECT
                @organization_id SelectedOrganizationId,
                NULL LoggedInOrganizationId,
                (SELECT COUNT(1)
                 FROM grac_practice.practice_instance pi
                 LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=pi.record_status_id
                 WHERE (@organization_id IS NULL OR pi.organization_id=@organization_id)
                   AND (pi.status='Active' OR rs.status_code='Active' OR pi.record_status_id IS NULL)) ApplicablePracticeInstanceCount,
                (SELECT COUNT(1)
                 FROM grac_practice.practice_instance_dependency d
                 WHERE d.dependency_type_id IS NOT NULL
                   AND d.status='Active'
                   AND (@organization_id IS NULL OR d.organization_id=@organization_id)) ConfiguredDependencyCategoryCount,
                (SELECT COUNT(1)
                 FROM grac_practice.practice_operationalization po
                 WHERE (@organization_id IS NULL OR po.organization_id=@organization_id)) OperationalizationRecordCount,
                (SELECT COUNT(1)
                 FROM grac_practice.practice_instance pi
                 LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
                 WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
                   AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
                   AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
                   AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status)) FinalReturnedCount;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", organizationId);
        Add(command, "@practice_id", practiceId);
        Add(command, "@p_status", status ?? "");
        Add(command, "@owner", JsonText(payload, "owner"));
        Add(command, "@criticality", JsonText(payload, "criticality"));
        Add(command, "@date_from", JsonDate(payload, "dateFrom"));
        Add(command, "@date_to", JsonDate(payload, "dateTo"));
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryDependencyOptionsFallbackAsync(DbConnection connection,
        string search, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var dependencyTypeId = JsonInt(payload, "dependencyTypeId");
        if (!organizationId.HasValue) throw new InvalidOperationException("Organization context is required to load dependency objects.");
        if (!dependencyTypeId.HasValue) throw new InvalidOperationException("Dependency Type is required to load dependency objects.");

        await using var configCommand = connection.CreateCommand();
        configCommand.CommandText = """
            SELECT TOP 1
                source_type SourceType,
                source_table_name SourceTableName,
                id_column_name IdColumnName,
                display_column_name DisplayColumnName,
                organization_filter_column OrganizationFilterColumn,
                status_filter_column StatusFilterColumn,
                COALESCE(NULLIF(status_active_value,N''),N'Active') StatusActiveValue,
                COALESCE(NULLIF(sort_column,N''),display_column_name) SortColumnName,
                is_multi_select_allowed IsMultiSelectAllowed
            FROM grac_practice.dependency_type_source_config
            WHERE dependency_type_id=@dependency_type_id
              AND status=N'Active'
              AND source_table_name IN (
                N'grac_practice.organization_dependency_tool',
                N'grac_practice.organization_dependency_vendor',
                N'grac_practice.organization_dependency_application',
                N'grac_practice.organization_dependency_asset',
                N'grac_practice.organization_dependency_process',
                N'grac_practice.organization_location',
                N'grac_practice.organization_employee',
                N'grac_practice.organization_team',
                N'grac_practice.organization_committee'
              );
            """;
        configCommand.CommandType = CommandType.Text;
        Add(configCommand, "@dependency_type_id", dependencyTypeId.Value);
        var configTables = await ReadTablesAsync(configCommand, cancellationToken);
        var config = configTables.FirstOrDefault()?.FirstOrDefault();
        if (config is null)
        {
            return
            [
                [],
                [new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
                {
                    ["DependencyTypeId"] = dependencyTypeId.Value,
                    ["OrganizationId"] = organizationId.Value,
                    ["SourceTableName"] = "",
                    ["RecordsReturned"] = 0,
                    ["DebugMessage"] = "Dependency Type source configuration is missing or inactive."
                }]
            ];
        }

        var sourceTable = Convert.ToString(config["SourceTableName"]) ?? "";
        var idColumn = Convert.ToString(config["IdColumnName"]) ?? "";
        var displayColumn = Convert.ToString(config["DisplayColumnName"]) ?? "";
        var organizationColumn = Convert.ToString(config["OrganizationFilterColumn"]) ?? "";
        var statusColumn = Convert.ToString(config["StatusFilterColumn"]) ?? "";
        var sortColumn = Convert.ToString(config["SortColumnName"]) ?? "";
        var sourceType = Convert.ToString(config["SourceType"]) ?? "";
        var activeStatus = Convert.ToString(config["StatusActiveValue"]) ?? "Active";
        var isMultiSelectAllowed = ToBool(config["IsMultiSelectAllowed"], true);

        var allowedTables = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "grac_practice.organization_dependency_tool",
            "grac_practice.organization_dependency_vendor",
            "grac_practice.organization_dependency_application",
            "grac_practice.organization_dependency_asset",
            "grac_practice.organization_dependency_process",
            "grac_practice.organization_location",
            "grac_practice.organization_employee",
            "grac_practice.organization_team",
            "grac_practice.organization_committee"
        };
        if (!allowedTables.Contains(sourceTable)
            || !IsSafeSqlName(idColumn)
            || !IsSafeSqlName(displayColumn)
            || !IsSafeSqlName(organizationColumn)
            || !IsSafeSqlName(statusColumn)
            || !IsSafeSqlName(sortColumn))
        {
            throw new InvalidOperationException("Dependency Type source configuration is invalid.");
        }

        await using var validationCommand = connection.CreateCommand();
        validationCommand.CommandText = """
            SELECT
                CASE WHEN OBJECT_ID(@source_table) IS NOT NULL THEN 1 ELSE 0 END ObjectExists,
                CASE WHEN COL_LENGTH(@source_table,@id_column) IS NOT NULL THEN 1 ELSE 0 END IdColumnExists,
                CASE WHEN COL_LENGTH(@source_table,@display_column) IS NOT NULL THEN 1 ELSE 0 END DisplayColumnExists,
                CASE WHEN COL_LENGTH(@source_table,@organization_column) IS NOT NULL THEN 1 ELSE 0 END OrganizationColumnExists,
                CASE WHEN COL_LENGTH(@source_table,@status_column) IS NOT NULL THEN 1 ELSE 0 END StatusColumnExists,
                CASE WHEN COL_LENGTH(@source_table,@sort_column) IS NOT NULL THEN 1 ELSE 0 END SortColumnExists;
            """;
        validationCommand.CommandType = CommandType.Text;
        Add(validationCommand, "@source_table", sourceTable);
        Add(validationCommand, "@id_column", idColumn);
        Add(validationCommand, "@display_column", displayColumn);
        Add(validationCommand, "@organization_column", organizationColumn);
        Add(validationCommand, "@status_column", statusColumn);
        Add(validationCommand, "@sort_column", sortColumn);
        var validation = (await ReadTablesAsync(validationCommand, cancellationToken)).FirstOrDefault()?.FirstOrDefault();
        if (validation is null
            || Convert.ToInt32(validation["ObjectExists"]) == 0
            || Convert.ToInt32(validation["IdColumnExists"]) == 0
            || Convert.ToInt32(validation["DisplayColumnExists"]) == 0
            || Convert.ToInt32(validation["OrganizationColumnExists"]) == 0
            || Convert.ToInt32(validation["StatusColumnExists"]) == 0
            || Convert.ToInt32(validation["SortColumnExists"]) == 0)
        {
            throw new InvalidOperationException("Dependency Type source columns are invalid.");
        }

        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 200, 1, 500);
        var tableParts = sourceTable.Split('.', 2);
        await using var command = connection.CreateCommand();
        command.CommandText = $"""
            SELECT
                CAST({QuoteName(idColumn)} AS NVARCHAR(40)) [Value],
                CAST({QuoteName(displayColumn)} AS NVARCHAR(300)) [Label],
                @dependency_type_id DependencyTypeId,
                @source_type SourceType,
                @source_table SourceTableName,
                @is_multi_select_allowed IsMultiSelectAllowed
            FROM {QuoteName(tableParts[0])}.{QuoteName(tableParts[1])}
            WHERE {QuoteName(organizationColumn)}=@organization_id
              AND (
                    CAST({QuoteName(statusColumn)} AS NVARCHAR(80))=@active_status
                    OR (@active_status=N'Active' AND CAST({QuoteName(statusColumn)} AS NVARCHAR(80)) IN (N'1',N'True',N'true'))
                  )
              AND (@search_text=N'' OR CAST({QuoteName(displayColumn)} AS NVARCHAR(300)) LIKE N'%'+@search_text+N'%')
            ORDER BY {QuoteName(sortColumn)}
            OFFSET 0 ROWS FETCH NEXT @page_size ROWS ONLY;

            SELECT
                @dependency_type_id DependencyTypeId,
                @organization_id OrganizationId,
                @source_type SourceType,
                @source_table SourceTableName,
                @id_column IdColumnName,
                @display_column DisplayColumnName,
                @organization_column OrganizationFilterColumn,
                @status_column StatusFilterColumn,
                @active_status StatusActiveValue,
                @page_size PageSize;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@dependency_type_id", dependencyTypeId.Value);
        Add(command, "@organization_id", organizationId.Value);
        Add(command, "@source_type", sourceType);
        Add(command, "@source_table", sourceTable);
        Add(command, "@id_column", idColumn);
        Add(command, "@display_column", displayColumn);
        Add(command, "@organization_column", organizationColumn);
        Add(command, "@status_column", statusColumn);
        Add(command, "@active_status", activeStatus);
        Add(command, "@is_multi_select_allowed", isMultiSelectAllowed ? 1 : 0);
        Add(command, "@search_text", search ?? "");
        Add(command, "@page_size", pageSize);
        var tables = await ReadTablesAsync(command, cancellationToken);
        if (tables.Count > 1 && tables[1].Count > 0) tables[1][0]["RecordsReturned"] = tables.FirstOrDefault()?.Count ?? 0;
        return tables;
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryResolveFallbackAsync(DbConnection connection,
        int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var practiceId = JsonInt(payload, "practiceId");
        var dependencyTypeId = JsonInt(payload, "dependencyTypeId");
        var registerType = JsonText(payload, "registerType");
        var subject = JsonSecuritySubject(payload);
        var isSystemAdmin = JsonSecurityIsSystemAdmin(payload);

        await using var command = connection.CreateCommand();
        command.CommandText = """
            ;WITH dependency_values AS (
                SELECT d.organization_id,d.practice_instance_id,d.dependency_type_id,dt.dependency_type_name
                FROM grac_practice.practice_instance_dependency d
                LEFT JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
                WHERE d.status='Active'
                  AND d.dependency_type_id IS NOT NULL
                  AND (@dependency_type_id IS NULL OR d.dependency_type_id=@dependency_type_id)
                GROUP BY d.organization_id,d.practice_instance_id,d.dependency_type_id,dt.dependency_type_name
            ),
            dependency_agg AS (
                SELECT dv.organization_id,dv.practice_instance_id,
                    STUFF((
                        SELECT N', ' + COALESCE(dv2.dependency_type_name,N'Dependency')
                        FROM dependency_values dv2
                        WHERE dv2.organization_id=dv.organization_id
                          AND dv2.practice_instance_id=dv.practice_instance_id
                        ORDER BY dv2.dependency_type_name
                        FOR XML PATH(''),TYPE
                    ).value('.','NVARCHAR(MAX)'),1,2,N'') DependencyCategories,
                    COUNT(1) TotalDependencyCategories
                FROM dependency_values dv
                GROUP BY dv.organization_id,dv.practice_instance_id
            ),
            evidence_values AS (
                SELECT e.organization_id,e.practice_instance_id,
                    COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceTypeName
                FROM grac_practice.practice_instance_evidence e
                LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
                WHERE e.status='Active'
                GROUP BY e.organization_id,e.practice_instance_id,COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id))
            ),
            evidence_agg AS (
                SELECT ev.organization_id,ev.practice_instance_id,
                    STUFF((
                        SELECT N', ' + ev2.EvidenceTypeName
                        FROM evidence_values ev2
                        WHERE ev2.organization_id=ev.organization_id
                          AND ev2.practice_instance_id=ev.practice_instance_id
                        ORDER BY ev2.EvidenceTypeName
                        FOR XML PATH(''),TYPE
                    ).value('.','NVARCHAR(MAX)'),1,2,N'') EvidenceTypes
                FROM evidence_values ev
                GROUP BY ev.organization_id,ev.practice_instance_id
            ),
            resolution_agg AS (
                SELECT r.organization_id,r.practice_instance_id,
                    STUFF((
                        SELECT N', ' + r2.resolved_dependency_name
                        FROM grac_practice.practice_dependency_resolution r2
                        WHERE r2.organization_id=r.organization_id
                          AND r2.practice_instance_id=r.practice_instance_id
                          AND r2.is_active=1
                          AND (@dependency_type_id IS NULL OR r2.dependency_type_id=@dependency_type_id)
                        ORDER BY r2.resolved_dependency_name
                        FOR XML PATH(''),TYPE
                    ).value('.','NVARCHAR(MAX)'),1,2,N'') ResolvedDependencyName,
                    MAX(ISNULL(r.updated_dt,r.entered_dt)) LastUpdated,
                    COUNT(1) ResolvedDependenciesCount
                FROM grac_practice.practice_dependency_resolution r
                WHERE r.is_active=1
                  AND (@dependency_type_id IS NULL OR r.dependency_type_id=@dependency_type_id)
                GROUP BY r.organization_id,r.practice_instance_id
            )
            SELECT
                pi.practice_instance_id Id,
                pi.practice_instance_id PracticeInstanceId,
                pi.organization_id OrganizationId,
                pi.instance_code Code,
                pi.instance_name Name,
                COALESCE(bf.function_name,pi.department,N'') OwningDepartment,
                COALESCE(owner_emp.employee_name,pi.primary_owner,N'') PrimaryOwner,
                COALESCE(execf.frequency_name,f.frequency_name,pi.frequency_type,N'') Frequency,
                COALESCE(ev.EvidenceTypes,N'') EvidenceTypes,
                COALESCE(da.DependencyCategories,N'') DependencyCategories,
                CASE
                    WHEN @register_type=N'Evidence' THEN N'Evidence Register'
                    WHEN @dependency_type_id IS NOT NULL THEN COALESCE((SELECT TOP 1 dependency_type_name FROM grac_practice.dependency_type_master WHERE dependency_type_id=@dependency_type_id),N'Dependency') + N' Register'
                    ELSE COALESCE(NULLIF(da.DependencyCategories,N''),N'Dependency Register')
                END Register,
                CASE WHEN @register_type=N'Evidence' THEN COALESCE(ev.EvidenceTypes,N'') ELSE COALESCE(ra.ResolvedDependencyName,N'') END ResolvedDependencyName,
                CASE
                    WHEN @register_type=N'Evidence' AND ev.practice_instance_id IS NOT NULL THEN N'Resolved'
                    WHEN @register_type=N'Evidence' THEN N'Pending'
                    WHEN COALESCE(ra.ResolvedDependenciesCount,0)>0 THEN N'Resolved'
                    ELSE N'Pending'
                END ResolutionStatus,
                N'' ResolutionOwner,
                COALESCE(ra.LastUpdated,pi.updated_dt,pi.entered_dt) LastUpdated,
                (SELECT TOP 1 e6.evidence_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceId,
                (SELECT TOP 1 e6.evidence_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceTypeId,
                (SELECT TOP 1 e6.assurance_type_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeId,
                (SELECT TOP 1 at6.assurance_type_name FROM grac_practice.practice_instance_evidence e6 LEFT JOIN grac_practice.assurance_type_master at6 ON at6.assurance_type_id=e6.assurance_type_id WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) AssuranceTypeName,
                (SELECT TOP 1 e6.collection_method_id FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) CollectionMethodId,
                (SELECT TOP 1 e6.retention_period FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) RetentionPeriod,
                (SELECT TOP 1 e6.evidence_description FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceDescription,
                (SELECT TOP 1 e6.evidence_location FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocation,
                (SELECT TOP 1 e6.evidence_locator FROM grac_practice.practice_instance_evidence e6 WHERE e6.practice_instance_id=pi.practice_instance_id AND e6.status='Active' ORDER BY e6.updated_dt DESC,e6.entered_dt DESC) EvidenceLocator,
                COALESCE(ra.ResolvedDependenciesCount,0) ResolvedDependenciesCount,
                CASE
                    WHEN COALESCE(da.TotalDependencyCategories,0)-COALESCE(ra.ResolvedDependenciesCount,0)<0 THEN 0
                    ELSE COALESCE(da.TotalDependencyCategories,0)-COALESCE(ra.ResolvedDependenciesCount,0)
                END PendingDependenciesCount,
                CASE
                    WHEN pi.status IN (N'Inactive',N'Retired') OR prs.status_code IN (N'Inactive',N'Retired') THEN N'Retired'
                    WHEN @register_type=N'Evidence' AND ev.practice_instance_id IS NOT NULL THEN N'Operationalized'
                    WHEN @register_type=N'Evidence' THEN N'Configured'
                    WHEN COALESCE(da.TotalDependencyCategories,0)=0 THEN N'Dependency Categories Pending'
                    WHEN COALESCE(ra.ResolvedDependenciesCount,0)>=COALESCE(da.TotalDependencyCategories,0) THEN N'Operationalized'
                    WHEN COALESCE(ra.ResolvedDependenciesCount,0)>0 THEN N'Partially Operationalized'
                    ELSE N'Configured'
                END OperationalizationStatus,
                COALESCE(prs.status_name,pi.status) Status
            FROM grac_practice.practice_instance pi
            LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id=pi.record_status_id
            LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
            LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
            LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
            LEFT JOIN grac_practice.organization_employee owner_emp ON owner_emp.employee_id=pi.primary_owner_id
            LEFT JOIN dependency_agg da ON da.organization_id=pi.organization_id AND da.practice_instance_id=pi.practice_instance_id
            LEFT JOIN evidence_agg ev ON ev.organization_id=pi.organization_id AND ev.practice_instance_id=pi.practice_instance_id
            LEFT JOIN resolution_agg ra ON ra.organization_id=pi.organization_id AND ra.practice_instance_id=pi.practice_instance_id
            WHERE (@p_id=0 OR pi.practice_instance_id=@p_id)
              AND (@organization_id IS NULL OR pi.organization_id=@organization_id)
              AND (@practice_id IS NULL OR pi.practice_id=@practice_id)
              AND (@p_status='' OR pi.status=@p_status OR prs.status_code=@p_status OR prs.status_name=@p_status)
              AND (@owner IS NULL OR ISNULL(pi.primary_owner,N'') LIKE N'%'+@owner+N'%' OR ISNULL(pi.secondary_owner,N'') LIKE N'%'+@owner+N'%' OR ISNULL(owner_emp.employee_name,N'') LIKE N'%'+@owner+N'%')
              AND (@criticality IS NULL OR ISNULL(pi.criticality,N'')=@criticality)
              AND (@date_from IS NULL OR pi.entered_dt>=@date_from)
              AND (@date_to IS NULL OR pi.entered_dt<DATEADD(DAY,1,@date_to))
              AND (
                    @is_system_admin=1
                    OR LOWER(ISNULL(owner_emp.email,N''))=LOWER(@subject)
                    OR LOWER(ISNULL(owner_emp.employee_code,N''))=LOWER(@subject)
                    OR LOWER(ISNULL(owner_emp.employee_name,N''))=LOWER(@subject)
                    OR LOWER(ISNULL(pi.primary_owner,N''))=LOWER(@subject)
                  )
              AND (
                    (@register_type=N'Evidence' AND ev.practice_instance_id IS NOT NULL)
                    OR
                    (COALESCE(@register_type,N'')<>N'Evidence' AND (@dependency_type_id IS NULL OR da.practice_instance_id IS NOT NULL))
                  )
              AND (@p_search='' OR ISNULL(pi.instance_code,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(pi.instance_name,N'') LIKE N'%'+@p_search+N'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE N'%'+@p_search+N'%')
            ORDER BY pi.instance_name
            OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

            SELECT
                d.practice_instance_id PracticeInstanceId,
                d.dependency_type_id DependencyTypeId,
                dt.dependency_type_name DependencyCategory,
                COALESCE(r.resolved_dependency_name,N'') ResolvedDependencyName,
                r.resolution_id ResolutionId,
                r.resolved_dependency_id ResolvedDependencyId,
                COALESCE(owner_emp2.employee_name,N'') ResolutionOwner,
                r.resolution_owner_id ResolutionOwnerId,
                CASE WHEN r.resolution_id IS NOT NULL THEN N'Resolved' ELSE N'Pending' END ResolutionStatus,
                CASE WHEN r.resolution_id IS NOT NULL THEN N'Resolved' ELSE N'Pending' END CategoryStatus,
                COALESCE(r.remarks,N'') Remarks,
                dt.dependency_type_name Register
            FROM grac_practice.practice_instance_dependency d
            INNER JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id=d.dependency_type_id
            LEFT JOIN grac_practice.practice_dependency_resolution r
                ON r.practice_instance_id=d.practice_instance_id
                AND r.dependency_type_id=d.dependency_type_id
                AND r.is_active=1
            LEFT JOIN grac_practice.organization_employee owner_emp2
                ON owner_emp2.employee_id=r.resolution_owner_id
            WHERE d.status=N'Active'
              AND d.dependency_type_id IS NOT NULL
              AND (@p_id=0 OR d.practice_instance_id=@p_id)
              AND (@organization_id IS NULL OR d.organization_id=@organization_id)
              AND (@dependency_type_id IS NULL OR d.dependency_type_id=@dependency_type_id)
            GROUP BY d.practice_instance_id,d.dependency_type_id,dt.dependency_type_name,
                r.resolution_id,r.resolved_dependency_id,r.resolved_dependency_name,
                r.resolution_owner_id,owner_emp2.employee_name,r.remarks
            ORDER BY dt.dependency_type_name,r.resolved_dependency_name;

            SELECT
                @organization_id SelectedOrganizationId,
                @subject LoggedInUser,
                @is_system_admin IsSystemAdmin,
                CAST(1 AS BIT) IsAuthorized,
                N'Owner-scoped resolve fallback query used.' DebugMessage;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", organizationId);
        Add(command, "@practice_id", practiceId);
        Add(command, "@dependency_type_id", dependencyTypeId);
        Add(command, "@register_type", registerType);
        Add(command, "@subject", subject ?? "");
        Add(command, "@is_system_admin", isSystemAdmin ? 1 : 0);
        Add(command, "@p_status", status ?? "");
        Add(command, "@owner", JsonText(payload, "owner"));
        Add(command, "@criticality", JsonText(payload, "criticality"));
        Add(command, "@date_from", JsonDate(payload, "dateFrom"));
        Add(command, "@date_to", JsonDate(payload, "dateTo"));
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryDependencyWorkbenchAsync(DbConnection connection,
        string dependencyTypeCode, int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var subject = JsonSecuritySubject(payload);
        var isSystemAdmin = JsonSecurityIsSystemAdmin(payload);
        var payloadDependencyTypeId = JsonInt(payload, "dependencyTypeId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @dependency_type_id INT=@payload_dependency_type_id;
            IF @dependency_type_id IS NULL AND @dependency_type_code<>N'ALL'
            BEGIN
                SELECT @dependency_type_id=dependency_type_id
                FROM grac_practice.dependency_type_master
                WHERE dependency_type_code=@dependency_type_code
                   OR dependency_type_name=@dependency_type_code;
            END;

            IF @dependency_type_id IS NULL AND @dependency_type_code<>N'ALL'
            BEGIN
                SELECT CAST(NULL AS BIGINT) Id,CAST(NULL AS BIGINT) PracticeInstanceId,CAST(NULL AS BIGINT) OrganizationId,
                    CAST(NULL AS NVARCHAR(300)) Name,CAST(NULL AS NVARCHAR(300)) OwningDepartment,CAST(NULL AS NVARCHAR(300)) PrimaryOwner,
                    CAST(NULL AS NVARCHAR(120)) Frequency,CAST(NULL AS INT) DependencyTypeId,CAST(NULL AS NVARCHAR(120)) DependencyCategory,
                    CAST(NULL AS BIGINT) ResolvedDependencyId,CAST(NULL AS NVARCHAR(300)) ResolvedDependencyName,
                    N'Pending' ResolutionStatus,CAST(NULL AS NVARCHAR(300)) ResolutionOwner,CAST(NULL AS DATETIME2) LastUpdated
                WHERE 1=0;
                RETURN;
            END;

            SELECT
                d.dependency_id Id,
                pi.practice_instance_id PracticeInstanceId,
                pi.organization_id OrganizationId,
                pi.instance_name Name,
                ISNULL(bf.function_name,ISNULL(pi.department,N'')) OwningDepartment,
                pi.primary_owner PrimaryOwner,
                ISNULL(execf.frequency_name,ISNULL(f.frequency_name,ISNULL(pi.frequency_type,N''))) Frequency,
                d.dependency_type_id DependencyTypeId,
                dt.dependency_type_name DependencyCategory,
                res.resolved_dependency_id ResolvedDependencyId,
                COALESCE(res_all.resolved_dependency_names,res.resolved_dependency_name) ResolvedDependencyName,
                CASE WHEN res_all.resolved_dependency_names IS NULL THEN N'Pending' ELSE COALESCE(drs.status_name,N'Resolved') END ResolutionStatus,
                ISNULL(emp.employee_name,N'') ResolutionOwner,
                COALESCE(res_all.last_updated,res.updated_dt) LastUpdated
            FROM grac_practice.practice_instance_dependency d
            JOIN grac_practice.practice_instance pi
              ON pi.practice_instance_id=d.practice_instance_id
             AND pi.organization_id=d.organization_id
            JOIN grac_practice.dependency_type_master dt
              ON dt.dependency_type_id=d.dependency_type_id
            LEFT JOIN grac_practice.organization_business_function bf ON bf.business_function_id=pi.business_function_id
            LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id
            LEFT JOIN grac_practice.frequency_master execf ON execf.frequency_id=pi.execution_frequency_id
            OUTER APPLY (
                SELECT TOP 1 r.*
                FROM grac_practice.practice_dependency_resolution r
                WHERE r.organization_id=d.organization_id
                  AND r.practice_instance_id=d.practice_instance_id
                  AND r.dependency_type_id=d.dependency_type_id
                  AND r.is_active=1
                ORDER BY ISNULL(r.updated_dt,r.entered_dt) DESC,r.resolution_id DESC
            ) res
            OUTER APPLY (
                SELECT
                    STUFF((
                        SELECT N', ' + r2.resolved_dependency_name
                        FROM grac_practice.practice_dependency_resolution r2
                        WHERE r2.organization_id=d.organization_id
                          AND r2.practice_instance_id=d.practice_instance_id
                          AND r2.dependency_type_id=d.dependency_type_id
                          AND r2.is_active=1
                        ORDER BY r2.resolved_dependency_name
                        FOR XML PATH(''),TYPE
                    ).value('.','NVARCHAR(MAX)'),1,2,N'') resolved_dependency_names,
                    MAX(ISNULL(r3.updated_dt,r3.entered_dt)) last_updated
                FROM grac_practice.practice_dependency_resolution r3
                WHERE r3.organization_id=d.organization_id
                  AND r3.practice_instance_id=d.practice_instance_id
                  AND r3.dependency_type_id=d.dependency_type_id
                  AND r3.is_active=1
            ) res_all
            LEFT JOIN grac_practice.dependency_resolution_status_master drs ON drs.resolution_status_id=res.resolution_status_id
            LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id=res.resolution_owner_id
            WHERE (@dependency_type_id IS NULL OR d.dependency_type_id=@dependency_type_id)
              AND d.status='Active'
              AND (@organization_id IS NULL OR d.organization_id=@organization_id)
              AND (@p_id=0 OR d.dependency_id=@p_id OR pi.practice_instance_id=@p_id)
              AND (@p_status='' OR ISNULL(drs.status_name,N'Pending')=@p_status OR ISNULL(drs.status_code,N'Pending')=@p_status)
              AND (@p_search='' OR ISNULL(pi.instance_name,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(pi.instance_code,N'') LIKE N'%'+@p_search+N'%' OR COALESCE(bf.function_name,pi.department,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(res.resolved_dependency_name,N'') LIKE N'%'+@p_search+N'%')
              AND (
                    @is_system_admin=1
                    OR EXISTS (
                        SELECT 1
                        FROM grac_practice.dependency_custodian_mapping cm
                        JOIN grac_practice.organization_employee ce ON ce.employee_id=cm.custodian_user_id
                        WHERE cm.organization_id=d.organization_id
                          AND cm.dependency_type_id=d.dependency_type_id
                          AND cm.status='Active'
                          AND ce.status='Active'
                          AND ce.email=@subject
                    )
                  )
            ORDER BY pi.instance_name
            OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

            SELECT
                @organization_id SelectedOrganizationId,
                @dependency_type_id DependencyTypeId,
                @dependency_type_code DependencyTypeCode,
                @subject LoggedInUser,
                @is_system_admin IsSystemAdmin,
                CASE
                    WHEN @is_system_admin=1 THEN CAST(1 AS BIT)
                    WHEN EXISTS (
                        SELECT 1
                        FROM grac_practice.dependency_custodian_mapping cm
                        JOIN grac_practice.organization_employee ce ON ce.employee_id=cm.custodian_user_id
                        WHERE (@organization_id IS NULL OR cm.organization_id=@organization_id)
                          AND (@dependency_type_id IS NULL OR cm.dependency_type_id=@dependency_type_id)
                          AND cm.status='Active'
                          AND ce.status='Active'
                          AND ce.email=@subject
                    ) THEN CAST(1 AS BIT)
                    ELSE CAST(0 AS BIT)
                END IsAuthorized;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@dependency_type_code", dependencyTypeCode);
        Add(command, "@payload_dependency_type_id", payloadDependencyTypeId);
        Add(command, "@organization_id", organizationId);
        Add(command, "@subject", subject ?? "");
        Add(command, "@is_system_admin", isSystemAdmin ? 1 : 0);
        Add(command, "@p_id", id);
        Add(command, "@p_status", status ?? "");
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryDependencyWorkbenchCompatibilityAsync(DbConnection connection,
        string dependencyTypeCode, int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var subject = JsonSecuritySubject(payload);
        var isSystemAdmin = JsonSecurityIsSystemAdmin(payload);
        var payloadDependencyTypeId = JsonInt(payload, "dependencyTypeId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            DECLARE @dependency_type_id INT=@payload_dependency_type_id;
            IF @dependency_type_id IS NULL AND @dependency_type_code<>N'ALL'
            BEGIN
                SELECT @dependency_type_id=dependency_type_id
                FROM grac_practice.dependency_type_master
                WHERE dependency_type_code=@dependency_type_code
                   OR dependency_type_name=@dependency_type_code;
            END;

            IF @dependency_type_id IS NULL AND @dependency_type_code<>N'ALL'
            BEGIN
                SELECT CAST(NULL AS BIGINT) Id,CAST(NULL AS BIGINT) PracticeInstanceId,CAST(NULL AS BIGINT) OrganizationId,
                    CAST(NULL AS NVARCHAR(300)) Name,CAST(NULL AS NVARCHAR(300)) OwningDepartment,CAST(NULL AS NVARCHAR(300)) PrimaryOwner,
                    CAST(NULL AS NVARCHAR(120)) Frequency,CAST(NULL AS INT) DependencyTypeId,CAST(NULL AS NVARCHAR(120)) DependencyCategory,
                    CAST(NULL AS BIGINT) ResolvedDependencyId,CAST(NULL AS NVARCHAR(300)) ResolvedDependencyName,
                    N'Pending' ResolutionStatus,CAST(NULL AS NVARCHAR(300)) ResolutionOwner,CAST(NULL AS DATETIME2) LastUpdated
                WHERE 1=0;
                SELECT @organization_id SelectedOrganizationId,@dependency_type_id DependencyTypeId,@dependency_type_code DependencyTypeCode,
                    @subject LoggedInUser,@is_system_admin IsSystemAdmin,CAST(1 AS BIT) IsAuthorized,
                    N'Dependency type was not found.' DebugMessage;
                RETURN;
            END;

            SELECT
                d.dependency_id Id,
                pi.practice_instance_id PracticeInstanceId,
                pi.organization_id OrganizationId,
                pi.instance_name Name,
                ISNULL(d.owner_name,N'') OwningDepartment,
                ISNULL(pi.primary_owner,N'') PrimaryOwner,
                ISNULL(pi.frequency_type,N'') Frequency,
                d.dependency_type_id DependencyTypeId,
                dt.dependency_type_name DependencyCategory,
                CAST(NULL AS BIGINT) ResolvedDependencyId,
                CAST(NULL AS NVARCHAR(300)) ResolvedDependencyName,
                N'Pending' ResolutionStatus,
                CAST(NULL AS NVARCHAR(300)) ResolutionOwner,
                d.updated_dt LastUpdated
            FROM grac_practice.practice_instance_dependency d
            JOIN grac_practice.practice_instance pi
              ON pi.practice_instance_id=d.practice_instance_id
             AND pi.organization_id=d.organization_id
            JOIN grac_practice.dependency_type_master dt
              ON dt.dependency_type_id=d.dependency_type_id
            WHERE (@dependency_type_id IS NULL OR d.dependency_type_id=@dependency_type_id)
              AND d.status='Active'
              AND (@organization_id IS NULL OR d.organization_id=@organization_id)
              AND (@p_id=0 OR d.dependency_id=@p_id OR pi.practice_instance_id=@p_id)
              AND (@p_status='' OR @p_status='Pending')
              AND (@p_search='' OR ISNULL(pi.instance_name,N'') LIKE N'%'+@p_search+N'%' OR ISNULL(d.dependency_name,N'') LIKE N'%'+@p_search+N'%')
            ORDER BY pi.instance_name
            OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

            SELECT
                @organization_id SelectedOrganizationId,
                @dependency_type_id DependencyTypeId,
                @dependency_type_code DependencyTypeCode,
                @subject LoggedInUser,
                @is_system_admin IsSystemAdmin,
                CAST(1 AS BIT) IsAuthorized,
                N'Compatibility query used. Run the latest PracticeManagement 002 script to enable resolved dependency/custodian columns.' DebugMessage;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@dependency_type_code", dependencyTypeCode);
        Add(command, "@payload_dependency_type_id", payloadDependencyTypeId);
        Add(command, "@organization_id", organizationId);
        Add(command, "@subject", subject ?? "");
        Add(command, "@is_system_admin", isSystemAdmin ? 1 : 0);
        Add(command, "@p_id", id);
        Add(command, "@p_status", status ?? "");
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryEvidenceConfigurationFallbackAsync(DbConnection connection,
        int id, string search, string status, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var practiceInstanceId = JsonInt(payload, "practiceInstanceId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT
                e.evidence_id Id,
                e.practice_instance_id PracticeInstanceId,
                e.evidence_type_id EvidenceTypeId,
                COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id)) EvidenceType,
                e.is_mandatory Mandatory,
                e.collection_method_id CollectionMethodId,
                cm.collection_method_name CollectionMethod,
                e.collection_frequency_id CollectionFrequencyId,
                f.frequency_name CollectionFrequency,
                e.evidence_owner EvidenceOwner,
                e.assurance_type_id AssuranceTypeId,
                at.assurance_type_name AssuranceTypeName,
                e.retention_period RetentionPeriod,
                e.record_status_id StatusId,
                COALESCE(rs.status_name,e.status) Status,
                COALESCE(et.display_order,999) DisplayOrder
            FROM grac_practice.practice_instance_evidence e
            LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=e.evidence_type_id
            LEFT JOIN grac_practice.collection_method_master cm ON cm.collection_method_id=e.collection_method_id
            LEFT JOIN grac_practice.assurance_type_master at ON at.assurance_type_id=e.assurance_type_id
            LEFT JOIN grac_practice.frequency_master f ON f.frequency_id=e.collection_frequency_id
            LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=e.record_status_id
            WHERE (@p_id=0 OR e.evidence_id=@p_id)
              AND (@practice_instance_id IS NULL OR e.practice_instance_id=@practice_instance_id)
              AND (@organization_id IS NULL OR e.organization_id=@organization_id)
              AND (@p_status='' OR e.status=@p_status OR rs.status_code=@p_status OR rs.status_name=@p_status)
              AND (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%' OR e.evidence_owner LIKE '%'+@p_search+'%' OR cm.collection_method_name LIKE '%'+@p_search+'%' OR f.frequency_name LIKE '%'+@p_search+'%')
            ORDER BY COALESCE(et.display_order,999),COALESCE(et.evidence_type_name,N'Evidence Type #' + CONVERT(NVARCHAR(20),e.evidence_type_id))
            OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@p_id", id);
        Add(command, "@organization_id", organizationId);
        Add(command, "@practice_instance_id", practiceInstanceId);
        Add(command, "@p_status", status ?? "");
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 25, 1, 200);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static async Task<List<List<Dictionary<string, object?>>>> QueryEvidenceObligationsFallbackAsync(DbConnection connection,
        string search, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var organizationRequirementId = JsonInt(payload, "organizationRequirementId");
        var practiceId = JsonInt(payload, "practiceId");
        var practiceInstanceId = JsonInt(payload, "practiceInstanceId");

        await using var command = connection.CreateCommand();
        command.CommandText = """
            ;WITH context_requirement AS (
                SELECT DISTINCT
                    req.organization_requirement_id,
                    req.organization_id,
                    COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
                    req.org_statement_id,
                    req.organization_control_id,
                    oc.repository_control_id,
                    COALESCE(ofs.release_id,oc.release_id) context_release_id
                FROM grac_practice.organization_requirement req
                LEFT JOIN grac_practice.organization_framework_statements ofs
                  ON ofs.org_statement_id=req.org_statement_id
                 AND ofs.organization_id=req.organization_id
                LEFT JOIN grac_practice.organization_control oc
                  ON oc.organization_control_id=req.organization_control_id
                 AND oc.organization_id=req.organization_id
                LEFT JOIN GRAC_New.requirement repo_req
                  ON repo_req.requirement_code=req.requirement_code
                 AND repo_req.status='Active'
                WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id=@organization_requirement_id)
                   OR (@practice_id IS NOT NULL AND EXISTS (
                        SELECT 1
                        FROM grac_practice.practice p
                        WHERE p.practice_id=@practice_id
                          AND p.organization_requirement_id=req.organization_requirement_id
                   ))
                   OR (@practice_instance_id IS NOT NULL AND EXISTS (
                        SELECT 1
                        FROM grac_practice.practice_instance pi
                        JOIN grac_practice.practice p ON p.practice_id=pi.practice_id
                        WHERE pi.practice_instance_id=@practice_instance_id
                          AND p.organization_requirement_id=req.organization_requirement_id
                   ))
            ),
            distinct_requirements AS (
                SELECT DISTINCT repository_requirement_id, organization_id
                FROM context_requirement
                WHERE repository_requirement_id IS NOT NULL
            ),
            /* Step 1: DISTINCT obligation_ids — no CROSS JOIN with releases */
            distinct_obligations AS (
                SELECT DISTINCT orm.obligation_id
                FROM distinct_requirements dr
                JOIN GRAC_New.obligation_requirement_release_map orm
                  ON orm.requirement_id=dr.repository_requirement_id AND orm.status='Active'
                WHERE (@organization_id IS NULL OR dr.organization_id=@organization_id)
            )
            /* Step 2: Evidence by obligation_id only — no release multiplication */
            SELECT
                rel.release_id FrameworkReleaseId,
                rel.FrameworkRelease,
                o.obligation_id ObligationId,
                COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)),N''),LEFT(o.obligation_text,300)) ObligationName,
                COALESCE(exec_freq.option_label,o.frequency_type) ExecutionFrequency,
                o.retention_requirement ObligationRetention,
                o.approval_authority ApprovalAuthority,
                o.responsibility Responsibility,
                roe.obligation_evidence_id EvidenceId,
                roe.evidence_type_id EvidenceTypeId,
                et.evidence_type_name EvidenceType,
                f.frequency_id FrequencyId,
                COALESCE(f.frequency_name,cm_freq.option_label) Frequency,
                roe.retention_requirement RetentionRequirement,
                roe.remarks Remarks
            FROM distinct_obligations dob
            JOIN GRAC_New.requirement_obligation o
              ON o.obligation_id=dob.obligation_id AND o.status='Active'
            JOIN GRAC_New.requirement_obligation_evidence roe
              ON roe.obligation_id=o.obligation_id AND roe.status='Active'
            JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id=roe.evidence_type_id
            LEFT JOIN GRAC_New.reference_option exec_freq ON exec_freq.reference_option_id=o.execution_frequency_id
            LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id=roe.frequency_id
            OUTER APPLY (
              SELECT TOP 1 f2.frequency_id,f2.frequency_name
              FROM grac_practice.frequency_master f2
              WHERE f2.frequency_code=cm_freq.option_value OR f2.frequency_name=cm_freq.option_label
            ) f
            OUTER APPLY (
              SELECT TOP 1 r.release_id,
                COALESCE(a.artifact_code + N' ' + r.version_no,a.artifact_name + N' ' + r.version_no,r.version_no) FrameworkRelease
              FROM distinct_requirements dr2
              JOIN GRAC_New.obligation_requirement_release_map orm2
                ON orm2.requirement_id=dr2.repository_requirement_id AND orm2.obligation_id=dob.obligation_id AND orm2.status='Active'
              JOIN GRAC_New.release r ON r.release_id=orm2.release_id
              LEFT JOIN GRAC_New.artifact a ON a.artifact_id=r.artifact_id
              WHERE (@organization_id IS NULL OR dr2.organization_id=@organization_id)
            ) rel
            WHERE (@p_search='' OR et.evidence_type_name LIKE '%'+@p_search+'%'
                   OR ISNULL(rel.FrameworkRelease,'') LIKE '%'+@p_search+'%'
                   OR ISNULL(o.obligation_name,'') LIKE '%'+@p_search+'%')
            ORDER BY rel.FrameworkRelease,et.display_order,et.evidence_type_name
            OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
            """;
        command.CommandType = CommandType.Text;
        Add(command, "@organization_id", organizationId);
        Add(command, "@organization_requirement_id", organizationRequirementId);
        Add(command, "@practice_id", practiceId);
        Add(command, "@practice_instance_id", practiceInstanceId);
        Add(command, "@p_search", search ?? "");
        var pageNumber = Math.Max(JsonInt(payload, "pageNumber") ?? 1, 1);
        var pageSize = Math.Clamp(JsonInt(payload, "pageSize") ?? 200, 1, 500);
        Add(command, "@offset", (pageNumber - 1) * pageSize);
        Add(command, "@page_size", pageSize);
        return await ReadTablesAsync(command, cancellationToken);
    }

    private static int? JsonInt(string payload, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            return document.RootElement.TryGetProperty(propertyName, out var property)
                ? property.ValueKind switch
                {
                    JsonValueKind.Number when property.TryGetInt32(out var value) => value,
                    JsonValueKind.String when int.TryParse(property.GetString(), out var value) => value,
                    _ => null
                }
                : null;
        }
        catch (JsonException) { return null; }
    }

    private static int[] JsonIntArray(string payload, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            if (!document.RootElement.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
                return [];
            return property.EnumerateArray()
                .Select(el => el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var v) ? v : 0)
                .Where(v => v > 0)
                .ToArray();
        }
        catch (JsonException) { return []; }
    }

    private static string? JsonText(string payload, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            if (!document.RootElement.TryGetProperty(propertyName, out var property)) return null;
            var value = property.ValueKind == JsonValueKind.String ? property.GetString() : property.ToString();
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }
        catch (JsonException) { return null; }
    }

    private static string? JsonSecuritySubject(string payload)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            if (!document.RootElement.TryGetProperty("_security", out var security)) return null;
            return security.TryGetProperty("subject", out var subject) ? subject.GetString() : null;
        }
        catch (JsonException) { return null; }
    }

    private static bool JsonSecurityIsSystemAdmin(string payload)
    {
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            if (!document.RootElement.TryGetProperty("_security", out var security)) return false;
            if (!security.TryGetProperty("isSystemAdmin", out var isSystemAdmin)) return false;
            return isSystemAdmin.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.String => string.Equals(isSystemAdmin.GetString(), "true", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(isSystemAdmin.GetString(), "1", StringComparison.OrdinalIgnoreCase),
                JsonValueKind.Number when isSystemAdmin.TryGetInt32(out var value) => value == 1,
                _ => false
            };
        }
        catch (JsonException) { return false; }
    }

    private static bool TryGetWorkbenchDependencyCode(string entityType, out string dependencyTypeCode)
    {
        dependencyTypeCode = entityType.ToLowerInvariant() switch
        {
            "workbench-all" => "ALL",
            "workbench-applications" => "APPLICATION",
            "workbench-tools" => "TOOL",
            "workbench-vendors" => "VENDOR",
            "workbench-assets" => "ASSET",
            "workbench-teams" => "TEAM",
            "workbench-committees" => "COMMITTEE",
            "workbench-processes" => "PROCESS",
            "workbench-locations" => "LOCATION",
            _ => ""
        };
        return dependencyTypeCode.Length > 0;
    }

    private static DateTime? JsonDate(string payload, string propertyName)
    {
        var value = JsonText(payload, propertyName);
        return DateTime.TryParse(value, out var date) ? date : null;
    }

    private static bool CanUseOrganizationFallback(string payload)
    {
        if (JsonInt(payload, "organizationId").HasValue) return true;
        try
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payload) ? "{}" : payload);
            if (!document.RootElement.TryGetProperty("_security", out var security)) return false;
            if (!security.TryGetProperty("isSystemAdmin", out var isSystemAdmin)) return false;
            return isSystemAdmin.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.String => string.Equals(isSystemAdmin.GetString(), "true", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(isSystemAdmin.GetString(), "1", StringComparison.OrdinalIgnoreCase),
                JsonValueKind.Number when isSystemAdmin.TryGetInt32(out var value) => value == 1,
                _ => false
            };
        }
        catch (JsonException) { return false; }
    }

    private static async Task<bool> HasOrganizationAccessAsync(DbConnection connection, string? subject, int organizationId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(subject)) return false;
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT CASE WHEN EXISTS(
                SELECT 1
                FROM grac_practice.user_organization_map m
                LEFT JOIN grac_practice.record_status_master rs ON rs.record_status_id=m.record_status_id
                WHERE m.organization_id=@organization_id
                  AND m.status='Active'
                  AND (rs.record_status_id IS NULL OR rs.status_code='Active' OR rs.status_name='Active')
                  AND LOWER(m.user_email)=LOWER(@subject)
            )
            OR EXISTS(
                SELECT 1
                FROM grac_practice.organization_employee e
                WHERE e.organization_id=@organization_id
                  AND e.status='Active'
                  AND (LOWER(e.email)=LOWER(@subject) OR LOWER(e.employee_code)=LOWER(@subject))
            )
            THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END;
            """;
        Add(command, "@organization_id", organizationId);
        Add(command, "@subject", subject);
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is bool allowed ? allowed : Convert.ToInt32(result) == 1;
    }

    public static object? GetLastSqlDiagnostic()
    {
        lock (DiagnosticLock) return LastSqlDiagnostic;
    }

    private string? GetConnectionString()
    {
        var connectionString = configuration.GetConnectionString("PracticeManagement");
        if (!string.IsNullOrWhiteSpace(connectionString)) return connectionString;

        var gracConnection = configuration.GetConnectionString("DbConnection");
        var encryptedPassword = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(gracConnection) || string.IsNullOrWhiteSpace(encryptedPassword)) return null;

        var passwordParts = encryptedPassword.Split('~', 2);
        if (passwordParts.Length != 2) throw new InvalidOperationException("ConnectionStrings:Password must contain the GRAC encryption key and encrypted password.");
        return gracConnection + DecryptPassword(passwordParts[1], passwordParts[0]);
    }

    private string ConfigureConnectionString(string provider, string connectionString)
    {
        if (!provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase)) return connectionString;

        var builder = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(connectionString)
        {
            Encrypt = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return builder.ConnectionString;
    }

    private static string DecryptPassword(string encryptedPassword, string key)
    {
        using var aes = Aes.Create();
        aes.Key = Encoding.UTF8.GetBytes(key.Substring(4, 32));
        aes.IV = Encoding.UTF8.GetBytes(key.ToLowerInvariant().Substring(4, 16));
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
        using var memoryStream = new MemoryStream(Convert.FromBase64String(encryptedPassword));
        using var cryptoStream = new CryptoStream(memoryStream, decryptor, CryptoStreamMode.Read);
        using var reader = new StreamReader(cryptoStream);
        return reader.ReadToEnd();
    }

    private static void Add(DbCommand command, string name, object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.Value = value ?? DBNull.Value;
        command.Parameters.Add(parameter);
    }

    private static bool IsSafeSqlName(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length <= 128
        && value.All(character => char.IsLetterOrDigit(character) || character == '_');

    private static string QuoteName(string value) => $"[{value.Replace("]", "]]")}]";

    private static bool ToBool(object? value, bool fallback = false)
    {
        if (value is null || value is DBNull) return fallback;
        if (value is bool boolean) return boolean;
        if (value is byte or short or int or long) return Convert.ToInt64(value) == 1;
        var text = Convert.ToString(value);
        if (string.IsNullOrWhiteSpace(text)) return fallback;
        return text.Equals("true", StringComparison.OrdinalIgnoreCase)
            || text.Equals("1", StringComparison.OrdinalIgnoreCase)
            || text.Equals("yes", StringComparison.OrdinalIgnoreCase);
    }

    // ========== Assurance Calendar: lazy occurrence generation ==========

    private async Task<List<List<Dictionary<string, object?>>>> QueryCalendarEventsAsync(
        DbConnection connection, string payload, CancellationToken cancellationToken)
    {
        var organizationId = JsonInt(payload, "organizationId");
        var rangeFromText = JsonText(payload, "dateFrom");
        var rangeToText = JsonText(payload, "dateTo");

        // Default range: -3 months to +12 months
        var rangeFrom = DateTime.TryParse(rangeFromText, out var rf) ? rf : DateTime.UtcNow.AddMonths(-3);
        var rangeTo = DateTime.TryParse(rangeToText, out var rt) ? rt : DateTime.UtcNow.AddMonths(12);

        // 1. Fetch schedule rules with frequency info
        await using var ruleCmd = connection.CreateCommand();
        ruleCmd.CommandText = """
            SELECT r.schedule_rule_id, r.organization_id, r.practice_instance_id,
                   pi.instance_code, pi.instance_name, pi.criticality, pi.assurance_mode,
                   pi.primary_owner,
                   r.frequency_id, fm.frequency_name, fm.frequency_value, fm.frequency_unit,
                   r.anchor_date, r.end_date, r.schedule_owner, r.notes, r.is_active
            FROM grac_practice.assurance_schedule_rule r
            JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
            JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
            WHERE r.status = N'Active' AND r.is_active = 1
              AND (@organization_id IS NULL OR r.organization_id = @organization_id)
            ORDER BY pi.instance_name
            """;
        Add(ruleCmd, "@organization_id", organizationId.HasValue ? organizationId.Value : DBNull.Value);
        var rules = new List<Dictionary<string, object?>>();
        await using (var reader = await ruleCmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>();
                for (var i = 0; i < reader.FieldCount; i++)
                    row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                rules.Add(row);
            }
        }

        // 2. Fetch overrides for the date range
        await using var ovrCmd = connection.CreateCommand();
        ovrCmd.CommandText = """
            SELECT o.override_id, o.schedule_rule_id, o.original_date, o.override_type,
                   o.new_date, o.reason, o.apply_to_future, o.override_by
            FROM grac_practice.assurance_schedule_override o
            WHERE o.status = N'Active'
              AND (@organization_id IS NULL OR o.organization_id = @organization_id)
              AND (o.original_date <= @range_to)
              AND (o.new_date IS NULL OR o.new_date >= @range_from OR o.original_date >= @range_from)
            ORDER BY o.original_date
            """;
        Add(ovrCmd, "@organization_id", organizationId.HasValue ? organizationId.Value : DBNull.Value);
        Add(ovrCmd, "@range_from", rangeFrom.Date);
        Add(ovrCmd, "@range_to", rangeTo.Date);
        var overrides = new List<Dictionary<string, object?>>();
        await using (var reader = await ovrCmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>();
                for (var i = 0; i < reader.FieldCount; i++)
                    row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                overrides.Add(row);
            }
        }

        // 3. Compute occurrences from rules and apply overrides
        var overridesByRule = overrides
            .Where(o => o.TryGetValue("schedule_rule_id", out var rid) && rid is not null)
            .GroupBy(o => Convert.ToInt64(o["schedule_rule_id"]))
            .ToDictionary(g => g.Key, g => g.ToList());

        var events = new List<Dictionary<string, object?>>();
        foreach (var rule in rules)
        {
            var ruleId = Convert.ToInt64(rule["schedule_rule_id"]);
            var anchorDate = Convert.ToDateTime(rule["anchor_date"]);
            var endDate = rule["end_date"] is DateTime ed ? ed : rangeTo;
            var freqValue = rule["frequency_value"] is not null and not DBNull ? Convert.ToInt32(rule["frequency_value"]) : 0;
            var freqUnit = rule["frequency_unit"]?.ToString() ?? "";
            var instanceCode = rule["instance_code"]?.ToString() ?? "";
            var instanceName = rule["instance_name"]?.ToString() ?? "";
            var practiceLabel = $"{instanceCode} - {instanceName}";
            var criticality = rule["criticality"]?.ToString() ?? "Medium";
            var assuranceMode = rule["assurance_mode"]?.ToString() ?? "Manual";
            var owner = rule["schedule_owner"]?.ToString() ?? rule["primary_owner"]?.ToString() ?? "";
            var frequencyName = rule["frequency_name"]?.ToString() ?? "";

            // Non-periodic frequencies (Event Driven, Continuous, Custom) — skip
            if (freqValue <= 0 || string.IsNullOrWhiteSpace(freqUnit)) continue;

            // Get overrides for this rule
            overridesByRule.TryGetValue(ruleId, out var ruleOverrides);
            var skipDates = new HashSet<DateTime>();
            var movedDates = new Dictionary<DateTime, DateTime>(); // original -> new
            if (ruleOverrides is not null)
            {
                foreach (var ovr in ruleOverrides)
                {
                    var originalDate = Convert.ToDateTime(ovr["original_date"]);
                    var overrideType = ovr["override_type"]?.ToString() ?? "";
                    if (overrideType.Equals("Skipped", StringComparison.OrdinalIgnoreCase))
                        skipDates.Add(originalDate.Date);
                    else if (overrideType.Equals("Moved", StringComparison.OrdinalIgnoreCase) && ovr["new_date"] is DateTime newDate)
                        movedDates[originalDate.Date] = newDate.Date;
                }
            }

            // Generate occurrences
            var effectiveEnd = endDate < rangeTo ? endDate : rangeTo;
            var current = anchorDate;
            while (current <= effectiveEnd)
            {
                if (current >= rangeFrom.Date && current <= rangeTo.Date)
                {
                    if (skipDates.Contains(current.Date))
                    {
                        events.Add(new Dictionary<string, object?>
                        {
                            ["RuleId"] = ruleId,
                            ["Date"] = current.Date,
                            ["PracticeInstance"] = practiceLabel,
                            ["FrequencyName"] = frequencyName,
                            ["Criticality"] = criticality,
                            ["AssuranceMode"] = assuranceMode,
                            ["Owner"] = owner,
                            ["Status"] = "Skipped",
                            ["IsOverride"] = true,
                            ["OriginalDate"] = current.Date,
                            ["OverrideType"] = "Skipped"
                        });
                    }
                    else if (movedDates.TryGetValue(current.Date, out var newDate))
                    {
                        // Show at new date
                        events.Add(new Dictionary<string, object?>
                        {
                            ["RuleId"] = ruleId,
                            ["Date"] = newDate,
                            ["PracticeInstance"] = practiceLabel,
                            ["FrequencyName"] = frequencyName,
                            ["Criticality"] = criticality,
                            ["AssuranceMode"] = assuranceMode,
                            ["Owner"] = owner,
                            ["Status"] = "Moved",
                            ["IsOverride"] = true,
                            ["OriginalDate"] = current.Date,
                            ["OverrideType"] = "Moved"
                        });
                    }
                    else
                    {
                        events.Add(new Dictionary<string, object?>
                        {
                            ["RuleId"] = ruleId,
                            ["Date"] = current.Date,
                            ["PracticeInstance"] = practiceLabel,
                            ["FrequencyName"] = frequencyName,
                            ["Criticality"] = criticality,
                            ["AssuranceMode"] = assuranceMode,
                            ["Owner"] = owner,
                            ["Status"] = current.Date < DateTime.UtcNow.Date ? "Past" : "Upcoming",
                            ["IsOverride"] = false,
                            ["OriginalDate"] = (object?)null,
                            ["OverrideType"] = (object?)null
                        });
                    }
                }

                // Advance by frequency
                current = freqUnit.Equals("Day", StringComparison.OrdinalIgnoreCase)
                    ? current.AddDays(freqValue)
                    : freqUnit.Equals("Week", StringComparison.OrdinalIgnoreCase)
                        ? current.AddDays(freqValue * 7)
                        : freqUnit.Equals("Month", StringComparison.OrdinalIgnoreCase)
                            ? current.AddMonths(freqValue)
                            : freqUnit.Equals("Year", StringComparison.OrdinalIgnoreCase)
                                ? current.AddYears(freqValue)
                                : current.AddMonths(freqValue > 0 ? freqValue : 1);
            }

            // Add "Added" overrides (manually created occurrences)
            if (ruleOverrides is not null)
            {
                foreach (var ovr in ruleOverrides)
                {
                    var overrideType = ovr["override_type"]?.ToString() ?? "";
                    if (!overrideType.Equals("Added", StringComparison.OrdinalIgnoreCase)) continue;
                    var addedDate = ovr["new_date"] is DateTime nd ? nd : Convert.ToDateTime(ovr["original_date"]);
                    if (addedDate >= rangeFrom.Date && addedDate <= rangeTo.Date)
                    {
                        events.Add(new Dictionary<string, object?>
                        {
                            ["RuleId"] = ruleId,
                            ["Date"] = addedDate.Date,
                            ["PracticeInstance"] = practiceLabel,
                            ["FrequencyName"] = frequencyName,
                            ["Criticality"] = criticality,
                            ["AssuranceMode"] = assuranceMode,
                            ["Owner"] = owner,
                            ["Status"] = "Added",
                            ["IsOverride"] = true,
                            ["OriginalDate"] = (object?)null,
                            ["OverrideType"] = "Added"
                        });
                    }
                }
            }
        }

        // 4. Auto-generate events from practice instances that have an assurance frequency
        //    but do NOT have an explicit assurance_schedule_rule yet.
        await using var autoCmd = connection.CreateCommand();
        autoCmd.CommandText = """
            SELECT pi.practice_instance_id, pi.organization_id, pi.instance_code, pi.instance_name,
                   pi.criticality, pi.assurance_mode, pi.primary_owner,
                   pi.assurance_frequency_id, fm.frequency_name, fm.frequency_value, fm.frequency_unit
            FROM grac_practice.practice_instance pi
            JOIN grac_practice.frequency_master fm ON fm.frequency_id = pi.assurance_frequency_id
            WHERE pi.assurance_frequency_id IS NOT NULL
              AND pi.status IN (N'Active', N'Resolved', N'Operationalized')
              AND NOT EXISTS (
                  SELECT 1 FROM grac_practice.assurance_schedule_rule r
                  WHERE r.practice_instance_id = pi.practice_instance_id
                    AND r.status = N'Active' AND r.is_active = 1
              )
              AND (@organization_id IS NULL OR pi.organization_id = @organization_id)
            ORDER BY pi.instance_name
            """;
        Add(autoCmd, "@organization_id", organizationId.HasValue ? organizationId.Value : DBNull.Value);
        await using (var reader = await autoCmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var freqValue = reader.IsDBNull(reader.GetOrdinal("frequency_value")) ? 0 : reader.GetInt32(reader.GetOrdinal("frequency_value"));
                var freqUnit = reader.IsDBNull(reader.GetOrdinal("frequency_unit")) ? "" : reader.GetString(reader.GetOrdinal("frequency_unit"));
                if (freqValue <= 0 || string.IsNullOrWhiteSpace(freqUnit)) continue;

                var instanceCode = reader.IsDBNull(reader.GetOrdinal("instance_code")) ? "" : reader.GetString(reader.GetOrdinal("instance_code"));
                var instanceName = reader.IsDBNull(reader.GetOrdinal("instance_name")) ? "" : reader.GetString(reader.GetOrdinal("instance_name"));
                var practiceLabel = $"{instanceCode} - {instanceName}";
                var criticality = reader.IsDBNull(reader.GetOrdinal("criticality")) ? "Medium" : reader.GetString(reader.GetOrdinal("criticality"));
                var assuranceMode = reader.IsDBNull(reader.GetOrdinal("assurance_mode")) ? "Manual" : reader.GetString(reader.GetOrdinal("assurance_mode"));
                var owner = reader.IsDBNull(reader.GetOrdinal("primary_owner")) ? "" : reader.GetString(reader.GetOrdinal("primary_owner"));
                var frequencyName = reader.IsDBNull(reader.GetOrdinal("frequency_name")) ? "" : reader.GetString(reader.GetOrdinal("frequency_name"));
                var practiceInstanceId = reader.GetInt64(reader.GetOrdinal("practice_instance_id"));

                // Use the first day of the current month as anchor for auto-generated events
                var anchorDate = new DateTime(DateTime.UtcNow.Year, DateTime.UtcNow.Month, 1);
                // Go back enough to cover rangeFrom
                while (anchorDate > rangeFrom) anchorDate = freqUnit.Equals("Year", StringComparison.OrdinalIgnoreCase)
                    ? anchorDate.AddYears(-freqValue) : freqUnit.Equals("Month", StringComparison.OrdinalIgnoreCase)
                    ? anchorDate.AddMonths(-freqValue) : freqUnit.Equals("Week", StringComparison.OrdinalIgnoreCase)
                    ? anchorDate.AddDays(-freqValue * 7) : anchorDate.AddDays(-freqValue);

                var current = anchorDate;
                while (current <= rangeTo)
                {
                    if (current >= rangeFrom.Date && current <= rangeTo.Date)
                    {
                        events.Add(new Dictionary<string, object?>
                        {
                            ["RuleId"] = (object?)null,
                            ["PracticeInstanceId"] = practiceInstanceId,
                            ["Date"] = current.Date,
                            ["PracticeInstance"] = practiceLabel,
                            ["FrequencyName"] = frequencyName,
                            ["Criticality"] = criticality,
                            ["AssuranceMode"] = assuranceMode,
                            ["Owner"] = owner,
                            ["Status"] = current.Date < DateTime.UtcNow.Date ? "Past" : "Upcoming",
                            ["IsOverride"] = false,
                            ["IsAutoGenerated"] = true,
                            ["OriginalDate"] = (object?)null,
                            ["OverrideType"] = (object?)null
                        });
                    }
                    current = freqUnit.Equals("Day", StringComparison.OrdinalIgnoreCase)
                        ? current.AddDays(freqValue)
                        : freqUnit.Equals("Week", StringComparison.OrdinalIgnoreCase)
                            ? current.AddDays(freqValue * 7)
                            : freqUnit.Equals("Month", StringComparison.OrdinalIgnoreCase)
                                ? current.AddMonths(freqValue)
                                : freqUnit.Equals("Year", StringComparison.OrdinalIgnoreCase)
                                    ? current.AddYears(freqValue)
                                    : current.AddMonths(freqValue > 0 ? freqValue : 1);
                }
            }
        }

        // 5. Fetch calendar config
        await using var cfgCmd = connection.CreateCommand();
        cfgCmd.CommandText = """
            SELECT config_id, organization_id, look_back_months, look_ahead_months, default_view
            FROM grac_practice.assurance_calendar_config
            WHERE (@organization_id IS NULL OR organization_id = @organization_id)
            """;
        Add(cfgCmd, "@organization_id", organizationId.HasValue ? organizationId.Value : DBNull.Value);
        var config = new List<Dictionary<string, object?>>();
        await using (var reader = await cfgCmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>();
                for (var i = 0; i < reader.FieldCount; i++)
                    row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                config.Add(row);
            }
        }

        // 6. Fetch organizations accessible to this user (avoids separate GET /organizations permission)
        var allowedOrgIds = JsonIntArray(payload, "allowedOrganizationIds");
        var orgs = new List<Dictionary<string, object?>>();
        if (allowedOrgIds.Length > 0)
        {
            await using var orgCmd = connection.CreateCommand();
            orgCmd.CommandText = $"""
                SELECT o.organization_id Id, o.organization_code Code, o.organization_name Name
                FROM grac_practice.organization o
                WHERE o.organization_id IN ({string.Join(",", allowedOrgIds)})
                ORDER BY o.organization_name
                """;
            await using var orgReader = await orgCmd.ExecuteReaderAsync(cancellationToken);
            while (await orgReader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>();
                for (var i = 0; i < orgReader.FieldCount; i++)
                    row[orgReader.GetName(i)] = orgReader.IsDBNull(i) ? null : orgReader.GetValue(i);
                orgs.Add(row);
            }
        }

        // Return: [0] = computed events, [1] = rules, [2] = config, [3] = organizations
        return [events, rules, config, orgs];
    }

}
