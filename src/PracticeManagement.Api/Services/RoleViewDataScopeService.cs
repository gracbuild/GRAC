// =====================================================================
// RoleViewDataScopeService  (migration 415 -- View Data Scope)
//
// Facade over the role View Data Scope procedures:
//   sp_role_view_data_scope_get    the role's setting
//   sp_role_view_data_scope_save   write it (validated in SQL)
// The setting itself is ENFORCED elsewhere -- by the row-level security
// policy pm_view_data_scope_policy, applied per connection through
// Infrastructure.ViewScopeSession. This class only reads and writes it.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IRoleViewDataScopeService
{
    Task<RoleViewDataScope?> GetAsync(long organizationId, long roleId, CancellationToken cancellationToken);
    Task<RoleViewDataScopeSaveResult> SaveAsync(long roleId, RoleViewDataScopeSaveRequest request, string actor, CancellationToken cancellationToken);
}

public sealed class RoleViewDataScopeService(IConfiguration configuration, ILogger<RoleViewDataScopeService> logger)
    : IRoleViewDataScopeService
{
    public async Task<RoleViewDataScope?> GetAsync(long organizationId, long roleId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_role_view_data_scope_get";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@role_id", DbType.Int64, roleId);
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        return await r.ReadAsync(cancellationToken) ? Map(r) : null;
    }

    public async Task<RoleViewDataScopeSaveResult> SaveAsync(long roleId, RoleViewDataScopeSaveRequest request, string actor, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!ViewDataScopes.IsValid(request.ViewDataScope))
            return new(false, "View Data Scope must be All records, Location, Team or Assigned Owner.", null);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_role_view_data_scope_save";
            AddParam(command, "@organization_id", DbType.Int64, request.OrganizationId);
            AddParam(command, "@role_id", DbType.Int64, roleId);
            AddParam(command, "@view_data_scope", DbType.String, request.ViewDataScope!.Trim().ToUpperInvariant(), 20);
            AddParam(command, "@actor", DbType.String, actor, 100);
            await using var r = await command.ExecuteReaderAsync(cancellationToken);
            return await r.ReadAsync(cancellationToken)
                ? new(true, null, Map(r))
                : new(false, "Role not found.", null);
        }
        catch (SqlException ex) when (ex.Number is >= 57320 and <= 57329)
        {
            // The procedure's own refusals are written for the user.
            return new(false, ex.Message, null);
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "RoleViewDataScope save failed for role {RoleId}", roleId);
            return new(false, ex.Message, null);
        }
    }

    private static RoleViewDataScope Map(DbDataReader r) => new(
        Convert.ToInt64(r["RoleId"]), Convert.ToInt64(r["OrganizationId"]),
        Convert.ToString(r["ViewDataScope"]) ?? ViewDataScopes.All);

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
