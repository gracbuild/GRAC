// =====================================================================
// FeatureFlagService  (charter §7 cross-cut, §12.1.6)
//
// Single Api-tier entry point for the grac_practice.feature_flag[_master]
// registry created in migration 041_feature_flag.sql. All feature-flag
// probes MUST go through here so the Web tier never talks to the DB
// directly (project-wide rule: one shared connection string, resolved by
// Infrastructure.SqlConnectionStringResolver, used by every Api service).
//
// Charter §5 non-negotiable — do NOT extend PracticeRepositoryService.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;

namespace PracticeManagement.Api.Services;

public interface IFeatureFlagService
{
    Task<FeatureFlagStatus> IsEnabledAsync(long? organizationId, string featureCode, CancellationToken cancellationToken);
}

public sealed record FeatureFlagStatus(bool Enabled, long? OrganizationId, string FeatureCode, string Reason);

public sealed class FeatureFlagService(IConfiguration configuration, ILogger<FeatureFlagService> logger) : IFeatureFlagService
{
    public async Task<FeatureFlagStatus> IsEnabledAsync(long? organizationId, string featureCode, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(featureCode))
            return new FeatureFlagStatus(false, organizationId, featureCode ?? "", "Feature code is required.");

        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            return new FeatureFlagStatus(false, organizationId, featureCode, "PracticeManagement connection string is not configured.");

        try
        {
            await using var connection = new SqlConnection(connString);
            await connection.OpenAsync(cancellationToken);

            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.Text;
            command.CommandText = "SELECT grac_practice.fn_pm_feature_enabled(@org, @code)";

            AddParam(command, "@org",  DbType.Int64,  (object?)organizationId ?? DBNull.Value);
            AddParam(command, "@code", DbType.String, featureCode, 80);

            var raw = await command.ExecuteScalarAsync(cancellationToken);
            var enabled = raw is not null && raw != DBNull.Value && Convert.ToBoolean(raw);
            var reason  = enabled
                ? $"{featureCode} enabled"
                : $"{featureCode} disabled for organization {organizationId?.ToString() ?? "(none)"}";
            return new FeatureFlagStatus(enabled, organizationId, featureCode, reason);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "FeatureFlagService probe failed for {FeatureCode} / org {OrganizationId}; failing closed.", featureCode, organizationId);
            return new FeatureFlagStatus(false, organizationId, featureCode, "Probe error; fail closed.");
        }
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
