// =====================================================================
// PermissionService  (charter §12.1.6)
//
// Thin façade over grac_practice.sp_pm_permissions_probe. Kept in its
// own file per charter §5 non-negotiable: "new services / procedures go
// into new files" — never extend PracticeRepositoryService.cs.
//
// Wired via Api/Infrastructure/PermissionServiceRegistration.cs; the
// caller Program.cs adds one line:
//     builder.Services.AddPracticePermissionService();
// Introducing that line requires an explicit request per charter §5 —
// leave Program.cs untouched until the reviewer confirms.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;

namespace PracticeManagement.Api.Services;

/// <summary>
/// Probe result for /api/practice/permissions/probe.
/// </summary>
public sealed record PermissionProbeResult(
    string Verdict,          // Allowed | Denied | RequiresApproval
    string ResolvedRole,
    string ResolvedScope,
    string Origin,
    string Action,
    string Reason);

/// <summary>
/// Input parameters for a permission probe. Mirrors the API contract
/// declared in the TDD (§6 New API endpoints).
/// </summary>
public sealed record PermissionProbeRequest(
    string EntityType,
    long EntityId,
    long? ActorEmployeeId,
    string OriginCode,       // GRAC | Custom | ANY
    string ActionCode,       // e.g. RETIRE_CONTROL, MARK_NA
    long? OrganizationId);

public interface IPermissionService
{
    Task<PermissionProbeResult?> ProbeAsync(PermissionProbeRequest request, CancellationToken cancellationToken);
}

public sealed class PermissionService(IConfiguration configuration, ILogger<PermissionService> logger)
    : IPermissionService
{
    // Delegates to SqlConnectionStringResolver so we get the same
    // Encrypt / TrustServerCertificate / password-decryption behaviour
    // as PracticeRepositoryService without extending the monolith.

    public async Task<PermissionProbeResult?> ProbeAsync(PermissionProbeRequest request, CancellationToken cancellationToken)
    {
        if (request is null) throw new ArgumentNullException(nameof(request));
        if (string.IsNullOrWhiteSpace(request.EntityType))
            throw new ArgumentException("EntityType is required.", nameof(request));
        if (string.IsNullOrWhiteSpace(request.ActionCode))
            throw new ArgumentException("ActionCode is required.", nameof(request));

        var connectionString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogWarning("PermissionService: no connection string configured; returning Denied by policy default.");
            return new PermissionProbeResult(
                Verdict: "Denied",
                ResolvedRole: "ANY",
                ResolvedScope: "ANY",
                Origin: request.OriginCode,
                Action: request.ActionCode,
                Reason: "No database connection configured; fail closed.");
        }

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_pm_permissions_probe";

        AddParam(command, "@entity_type",       DbType.String,  request.EntityType,             60);
        AddParam(command, "@entity_id",         DbType.Int64,   request.EntityId);
        AddParam(command, "@actor_employee_id", DbType.Int64,   (object?)request.ActorEmployeeId ?? DBNull.Value);
        AddParam(command, "@origin_code",       DbType.String,  request.OriginCode ?? "GRAC",   30);
        AddParam(command, "@action_code",       DbType.String,  request.ActionCode,             80);
        AddParam(command, "@organization_id",   DbType.Int64,   (object?)request.OrganizationId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new PermissionProbeResult(
            Verdict:       reader["Verdict"]?.ToString()       ?? "Denied",
            ResolvedRole:  reader["ResolvedRole"]?.ToString()  ?? "ANY",
            ResolvedScope: reader["ResolvedScope"]?.ToString() ?? "ANY",
            Origin:        reader["Origin"]?.ToString()        ?? request.OriginCode,
            Action:        reader["Action"]?.ToString()        ?? request.ActionCode,
            Reason:        reader["Reason"]?.ToString()        ?? "");
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
