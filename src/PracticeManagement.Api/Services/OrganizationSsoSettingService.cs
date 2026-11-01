// =====================================================================
// OrganizationSsoSettingService  (migration 466 -- organization-wise SSO)
//
// Facade over the organization SSO policy procedures:
//   sp_org_sso_setting_get    the organization's policy (defaults = off)
//   sp_org_sso_setting_save   write it (validated + normalized in SQL,
//                             audited to practice_audit_trace)
// The policy is ENFORCED at sign-in by PracticeAuthenticationService;
// this class only reads and writes it. Same shape as
// RoleViewDataScopeService.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrganizationSsoSettingService
{
    Task<OrganizationSsoSetting?> GetAsync(long organizationId, CancellationToken cancellationToken);
    Task<OrganizationSsoSettingSaveResult> SaveAsync(OrganizationSsoSettingSaveRequest request, string actor, CancellationToken cancellationToken);
    /// <summary>Migration 467: 'Pending Approval' -> Active. Error text on refusal, null on success.</summary>
    Task<string?> ApproveUserAsync(OrganizationSsoUserApproveRequest request, string actor, CancellationToken cancellationToken);
}

public sealed class OrganizationSsoSettingService(IConfiguration configuration, ILogger<OrganizationSsoSettingService> logger)
    : IOrganizationSsoSettingService
{
    public async Task<OrganizationSsoSetting?> GetAsync(long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_sso_setting_get";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        return await r.ReadAsync(cancellationToken) ? Map(r) : null;
    }

    public async Task<OrganizationSsoSettingSaveResult> SaveAsync(OrganizationSsoSettingSaveRequest request, string actor, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sso_setting_save";
            AddParam(command, "@organization_id", DbType.Int64, request.OrganizationId);
            AddParam(command, "@sso_enabled", DbType.Boolean, request.SsoEnabled);
            AddParam(command, "@allow_microsoft", DbType.Boolean, request.AllowMicrosoft);
            AddParam(command, "@allow_google", DbType.Boolean, request.AllowGoogle);
            AddParam(command, "@microsoft_tenant_ids", DbType.String, request.MicrosoftTenantIds?.Trim(), 1000);
            AddParam(command, "@allowed_email_domains", DbType.String, request.AllowedEmailDomains?.Trim(), 1000);
            AddParam(command, "@login_mode", DbType.String, string.IsNullOrWhiteSpace(request.LoginMode) ? SsoLoginModes.SsoAndPassword : request.LoginMode.Trim(), 20);
            AddParam(command, "@actor", DbType.String, actor, 100);
            // 467
            AddParam(command, "@auto_create_users", DbType.Boolean, request.AutoCreateUsers);
            AddParam(command, "@default_role_id", DbType.Int64, request.DefaultRoleId is > 0 ? request.DefaultRoleId : null);
            AddParam(command, "@require_admin_approval", DbType.Boolean, request.RequireAdminApproval);
            await using var r = await command.ExecuteReaderAsync(cancellationToken);
            return await r.ReadAsync(cancellationToken)
                ? new(true, null, Map(r))
                : new(false, "Organization not found.", null);
        }
        catch (SqlException ex) when (ex.Number is >= 57466 and <= 57479)
        {
            // The procedure's own refusals are written for the user.
            return new(false, ex.Message, null);
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "Organization SSO setting save failed for organization {OrganizationId}", request.OrganizationId);
            return new(false, ex.Message, null);
        }
    }

    public async Task<string?> ApproveUserAsync(OrganizationSsoUserApproveRequest request, string actor, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sso_user_approve";
            AddParam(command, "@organization_id", DbType.Int64, request.OrganizationId);
            AddParam(command, "@employee_id", DbType.Int64, request.EmployeeId);
            AddParam(command, "@actor", DbType.String, actor, 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return null;
        }
        catch (SqlException ex) when (ex.Number is >= 57466 and <= 57479)
        {
            return ex.Message;
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "SSO user approve failed for employee {EmployeeId}", request.EmployeeId);
            return ex.Message;
        }
    }

    private static OrganizationSsoSetting Map(DbDataReader r) => new(
        Convert.ToInt64(r["OrganizationId"]),
        Convert.ToBoolean(r["SsoEnabled"]),
        Convert.ToBoolean(r["AllowMicrosoft"]),
        Convert.ToBoolean(r["AllowGoogle"]),
        Convert.ToString(r["MicrosoftTenantIds"]) ?? "",
        Convert.ToString(r["AllowedEmailDomains"]) ?? "",
        Convert.ToString(r["LoginMode"]) ?? SsoLoginModes.SsoAndPassword,
        // 467 -- absent when only 466 is applied
        HasColumn(r, "AutoCreateUsers") && Convert.ToBoolean(r["AutoCreateUsers"]),
        HasColumn(r, "DefaultRoleId") && r["DefaultRoleId"] != DBNull.Value ? Convert.ToInt64(r["DefaultRoleId"]) : null,
        HasColumn(r, "DefaultRoleName") && r["DefaultRoleName"] != DBNull.Value ? Convert.ToString(r["DefaultRoleName"]) : null,
        !HasColumn(r, "RequireAdminApproval") || Convert.ToBoolean(r["RequireAdminApproval"]),
        r["UpdatedBy"] == DBNull.Value ? null : Convert.ToString(r["UpdatedBy"]),
        r["UpdatedDt"] == DBNull.Value ? null : Convert.ToDateTime(r["UpdatedDt"]));

    private static bool HasColumn(DbDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

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
