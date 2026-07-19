// =====================================================================
// OrganizationAccessService  (charter §7 cross-cut)
//
// Single Api-tier entry point for resolving the list of organizations a
// given user is allowed to see. Callers (Web tier) pass the caller's
// identity (data scope + email + employee code + primary org) and receive
// back the concrete list of organizations for the Organization filter.
//
// Rules:
//   * GLOBAL data scope (e.g. GRAC Admin)  → every Active organization.
//   * Otherwise                            → union of:
//        - primary_organization_id (if > 0 and Active)
//        - user_organization_map rows for the caller's email OR employee code
//     restricted to Active organizations.
//
// Uses SqlConnectionStringResolver so the single shared connection string
// is honoured (project-wide rule: no per-controller connection strings).
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;

namespace PracticeManagement.Api.Services;

public interface IOrganizationAccessService
{
    Task<IReadOnlyList<AllowedOrganization>> ListAllowedAsync(
        AllowedOrganizationQuery query,
        CancellationToken cancellationToken);
}

public sealed record AllowedOrganizationQuery(
    bool IsGlobalScope,
    string? Email,
    string? EmployeeCode,
    long? PrimaryOrganizationId);

public sealed record AllowedOrganization(
    long OrganizationId,
    string OrganizationCode,
    string OrganizationName);

public sealed class OrganizationAccessService(IConfiguration configuration, ILogger<OrganizationAccessService> logger)
    : IOrganizationAccessService
{
    public async Task<IReadOnlyList<AllowedOrganization>> ListAllowedAsync(
        AllowedOrganizationQuery query,
        CancellationToken cancellationToken)
    {
        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
        {
            logger.LogWarning("OrganizationAccessService: no connection string configured.");
            return Array.Empty<AllowedOrganization>();
        }

        await using var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);

        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;

        if (query.IsGlobalScope)
        {
            command.CommandText = """
                SELECT organization_id   AS OrganizationId,
                       organization_code AS OrganizationCode,
                       organization_name AS OrganizationName
                FROM grac_practice.organization
                WHERE status = 'Active'
                ORDER BY organization_name;
                """;
        }
        else
        {
            command.CommandText = """
                ;WITH allowed AS (
                    SELECT @primary_org AS organization_id
                    WHERE @primary_org IS NOT NULL AND @primary_org > 0
                    UNION
                    SELECT DISTINCT m.organization_id
                    FROM grac_practice.user_organization_map m
                    WHERE m.status = 'Active'
                      AND (
                          (@email IS NOT NULL         AND LOWER(m.user_email) = LOWER(@email))
                          OR (@employee_code IS NOT NULL AND LOWER(m.user_email) = LOWER(@employee_code))
                      )
                )
                SELECT o.organization_id   AS OrganizationId,
                       o.organization_code AS OrganizationCode,
                       o.organization_name AS OrganizationName
                FROM grac_practice.organization o
                JOIN allowed a ON a.organization_id = o.organization_id
                WHERE o.status = 'Active'
                ORDER BY o.organization_name;
                """;
            AddParam(command, "@primary_org",   DbType.Int64,  (object?)query.PrimaryOrganizationId ?? DBNull.Value);
            AddParam(command, "@email",         DbType.String, string.IsNullOrWhiteSpace(query.Email)        ? DBNull.Value : (object)query.Email!,        250);
            AddParam(command, "@employee_code", DbType.String, string.IsNullOrWhiteSpace(query.EmployeeCode) ? DBNull.Value : (object)query.EmployeeCode!,  80);
        }

        var rows = new List<AllowedOrganization>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new AllowedOrganization(
                Convert.ToInt64(reader["OrganizationId"]),
                reader["OrganizationCode"]?.ToString() ?? "",
                reader["OrganizationName"]?.ToString() ?? ""));
        }
        return rows;
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
