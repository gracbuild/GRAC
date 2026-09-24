using System.Data;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;
using PracticeManagement.Web.Security; // PasswordHasher — linked source file, shared with the Web tier

namespace PracticeManagement.Api.Services;

public interface IPracticeAuthenticationService
{
    /// <summary>Verify credentials and return the caller's identity, or null on any failure.</summary>
    Task<AuthenticatedUser?> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken);

    /// <summary>Replace an employee's password and clear force_password_change. False on any failure.</summary>
    Task<bool> SetPasswordAsync(long employeeId, string newPassword, CancellationToken cancellationToken);

    /// <summary>
    /// Find the active employee behind a login id (employee code or email)
    /// WITHOUT verifying a password. Null when nothing matches.
    /// <para>
    /// This is NOT an authentication path and must never be used as one.
    /// It exists for the bootstrap (ReviewLogin) sign-in, which is verified
    /// against configuration rather than the database and therefore reaches
    /// the session with no employee_id — leaving every procedure that
    /// requires an actor (approve, reject, owner stamps) to fail with
    /// "employee id is required". The caller passes a CONFIGURED identity it
    /// has already authenticated, never a value typed by a visitor.
    /// </para>
    /// </summary>
    Task<ResolvedIdentity?> ResolveIdentityAsync(string loginId, CancellationToken cancellationToken);
}

/// <summary>
/// The identity fields a session needs when the password check happened
/// somewhere other than the employee table. Deliberately smaller than
/// <c>AuthenticatedUser</c>: no permissions, no data scope, no role — the
/// bootstrap login already has those from configuration, and widening this
/// would make a password-free lookup look like a sign-in.
/// </summary>
public sealed record ResolvedIdentity(
    long   EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    string Email,
    long   OrganizationId);

// =====================================================================
// PracticeAuthenticationService
//
// Sign-in used to run inside PracticeManagement.Web (PracticeLoginService),
// which opened its own SqlConnection. Per the architecture rule that the
// database is reached ONLY through the API, that logic now lives here and
// the Web tier calls secure/authenticate instead. The SQL below is the
// former PracticeLoginService body, moved verbatim; the only change is the
// connection source — SqlConnectionStringResolver, the same helper every
// other API service uses.
// =====================================================================
public sealed class PracticeAuthenticationService(
    IConfiguration configuration,
    PasswordHasher passwordHasher,
    ILogger<PracticeAuthenticationService> logger) : IPracticeAuthenticationService
{
    // For multi-role users, pick the broadest data_scope across all roles.
    // Breadth order: GLOBAL > ORGANIZATION > RELEASE > STATEMENT > PRACTICE > INSTANCE
    private static readonly string[] DataScopePriority = ["GLOBAL", "ORGANIZATION", "RELEASE", "STATEMENT", "PRACTICE", "INSTANCE"];

    public async Task<AuthenticatedUser?> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken)
    {
        var connectionString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogError("Sign-in cannot proceed: no database connection is configured (ConnectionStrings:PracticeManagement or DbConnection+Password).");
            return null;
        }

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        // force_password_change arrived in migration 032. Selecting it
        // unconditionally would turn an un-migrated database into "invalid
        // column name" on every sign-in, so an absent column reads as 0 and
        // the forced-change prompt simply never fires.
        var forcePasswordChangeColumn =
            await ColumnExistsAsync(connection, "grac_practice.organization_employee", "force_password_change", cancellationToken)
                ? "CAST(ISNULL(e.force_password_change, 0) AS BIT)"
                : "CAST(0 AS BIT)";

        await using var command = connection.CreateCommand();
        command.CommandText = $"""
            SELECT TOP (1)
                   e.employee_id,
                   e.employee_code,
                   e.employee_name,
                   e.email,
                   e.password_hash,
                   e.organization_id,
                   o.organization_code,
                   o.organization_name,
                   e.role_id,
                   r.role_name,
                   ISNULL(r.data_scope, 'ORGANIZATION') AS data_scope,
                   {forcePasswordChangeColumn} AS force_password_change,
                   -- Diagnostics only. A password mismatch is almost always an
                   -- account provisioned under different configuration than the
                   -- one now running, and the creation stamp says so at a glance.
                   e.entered_dt,
                   e.entered_by
            FROM grac_practice.organization_employee e
            JOIN grac_practice.organization o ON o.organization_id = e.organization_id
            JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
            LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id AND r.organization_id = e.organization_id
            WHERE e.status = 'Active'
              AND (rs.status_code = 'ACTIVE' OR rs.status_name = 'Active')
              AND (LOWER(e.employee_code) = LOWER(@login_id) OR LOWER(e.email) = LOWER(@login_id));
            """;
        command.Parameters.Add(new SqlParameter("@login_id", SqlDbType.NVarChar, 250) { Value = loginId.Trim() });

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        // The screen shows one message for every failure, deliberately — telling
        // an anonymous caller "that account exists but the password is wrong"
        // hands them a user enumeration oracle. The operator still needs to know
        // which it was, so the distinction goes to the log instead. Nothing here
        // logs the password or the hash.
        if (!await reader.ReadAsync(cancellationToken))
        {
            logger.LogWarning(
                "Sign-in failed for {LoginId}: no active employee matched. Either the account does not exist in this database, "
                + "or organization_employee.status is not 'Active', or its record_status_master row is not Active. "
                + "Run database/_diag_user_login.sql for the breakdown.",
                loginId);
            return null;
        }

        var passwordHash = reader["password_hash"] as string;
        if (string.IsNullOrWhiteSpace(passwordHash))
        {
            logger.LogWarning(
                "Sign-in failed for {LoginId}: employee {EmployeeId} has no password hash. The account was written without one.",
                loginId, reader["employee_id"]);
            return null;
        }
        if (!passwordHasher.Verify(password, passwordHash))
        {
            logger.LogWarning(
                "Sign-in failed for {LoginId}: password mismatch for employee {EmployeeId} (created {EnteredDt} by {EnteredBy}). "
                + "The stored hash is valid but does not correspond to the password supplied. If this account was provisioned "
                + "with the default, confirm UserProvisioning:DefaultPassword in the deployment that CREATED the account matches "
                + "what was configured when the account was created.",
                loginId, reader["employee_id"], reader["entered_dt"], reader["entered_by"]);
            return null;
        }

        var employeeId = Convert.ToInt64(reader["employee_id"]);
        var employeeCode = Convert.ToString(reader["employee_code"]) ?? loginId;
        var employeeName = Convert.ToString(reader["employee_name"]) ?? loginId;
        var email = Convert.ToString(reader["email"]) ?? "";
        var organizationId = Convert.ToInt64(reader["organization_id"]);
        var organizationCode = Convert.ToString(reader["organization_code"]) ?? "";
        var organizationName = Convert.ToString(reader["organization_name"]) ?? "";
        var roleId = reader["role_id"] == DBNull.Value ? (long?)null : Convert.ToInt64(reader["role_id"]);
        var roleName = Convert.ToString(reader["role_name"]) ?? "Organization User";
        var dataScope = Convert.ToString(reader["data_scope"]) ?? "ORGANIZATION";
        var mustChangePassword = reader["force_password_change"] != DBNull.Value && Convert.ToBoolean(reader["force_password_change"]);
        await reader.CloseAsync();

        var permissions = await LoadPermissionsAsync(connection, employeeId, roleId, cancellationToken);
        var allowedOrganizationIds = await LoadAllowedOrganizationsAsync(connection, email, employeeCode, organizationId, cancellationToken);
        var effectiveDataScope = await LoadEffectiveDataScopeAsync(connection, employeeId, roleId, dataScope, cancellationToken);
        if (permissions.Count == 0)
            logger.LogWarning("Practice employee {EmployeeId} signed in with no menu permissions.", employeeId);

        return new AuthenticatedUser(
            employeeId, employeeCode, employeeName, email,
            organizationId, organizationCode, organizationName,
            roleId, roleName, effectiveDataScope,
            permissions, allowedOrganizationIds, mustChangePassword);
    }

    /// <summary>
    /// The same WHERE clause AuthenticateAsync uses -- active employee,
    /// active record status, matched on employee_code OR email -- with the
    /// password step removed. Reusing the predicate is the point: an
    /// identity resolved here must be the same row a sign-in would have
    /// found, or the bootstrap admin would be stamped against a different
    /// employee than the one they appear to be.
    /// </summary>
    public async Task<ResolvedIdentity?> ResolveIdentityAsync(string loginId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(loginId)) return null;

        var connectionString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogError("Identity resolve cannot proceed: no database connection is configured.");
            return null;
        }

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT TOP (1)
                   e.employee_id,
                   e.employee_code,
                   e.employee_name,
                   e.email,
                   e.organization_id
            FROM grac_practice.organization_employee e
            JOIN grac_practice.record_status_master rs ON rs.record_status_id = e.record_status_id
            WHERE e.status = 'Active'
              AND (rs.status_code = 'ACTIVE' OR rs.status_name = 'Active')
              AND (LOWER(e.employee_code) = LOWER(@login_id) OR LOWER(e.email) = LOWER(@login_id))
            ORDER BY e.employee_id;
            """;
        command.Parameters.Add(new SqlParameter("@login_id", SqlDbType.NVarChar, 250) { Value = loginId.Trim() });

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            // Not an error. A bootstrap admin with no employee row is a
            // supported configuration; the session simply carries no
            // employee id, exactly as it did before.
            logger.LogInformation(
                "Identity resolve for {LoginId}: no active employee matched. The session will carry no employee id.",
                loginId);
            return null;
        }

        return new ResolvedIdentity(
            Convert.ToInt64(reader["employee_id"]),
            Convert.ToString(reader["employee_code"]) ?? loginId,
            Convert.ToString(reader["employee_name"]) ?? loginId,
            Convert.ToString(reader["email"]) ?? "",
            Convert.ToInt64(reader["organization_id"]));
    }

    /// <summary>
    /// Replaces an employee's password and clears force_password_change.
    /// Used by the first-login change flow, which runs BEFORE a session
    /// exists — the caller must have re-verified the current password via
    /// <see cref="AuthenticateAsync"/> first. Delegates to
    /// grac_practice.sp_org_user_set_password (migration 208) rather than the
    /// users entity save, so a pre-session caller cannot reach the fields
    /// that save also rewrites (organization, role, personnel type).
    /// </summary>
    public async Task<bool> SetPasswordAsync(long employeeId, string newPassword, CancellationToken cancellationToken)
    {
        var connectionString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString)) return false;

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);

        // A database that predates 208 has no procedure to call. Fail closed:
        // reporting success would leave the user on the default password
        // believing it had been changed.
        await using (var probe = connection.CreateCommand())
        {
            probe.CommandText = "SELECT OBJECT_ID('grac_practice.sp_org_user_set_password','P');";
            var exists = await probe.ExecuteScalarAsync(cancellationToken);
            if (exists is null || exists == DBNull.Value)
            {
                logger.LogError("grac_practice.sp_org_user_set_password is missing. Run database/208_default_password_provisioning.sql.");
                return false;
            }
        }

        await using var command = connection.CreateCommand();
        command.CommandText = "grac_practice.sp_org_user_set_password";
        command.CommandType = CommandType.StoredProcedure;
        command.Parameters.Add(new SqlParameter("@employee_id", SqlDbType.BigInt) { Value = employeeId });
        command.Parameters.Add(new SqlParameter("@password_hash", SqlDbType.NVarChar, 500) { Value = passwordHasher.Hash(newPassword) });
        command.Parameters.Add(new SqlParameter("@entered_by", SqlDbType.NVarChar, 100) { Value = "self-service" });

        try
        {
            await command.ExecuteNonQueryAsync(cancellationToken);
            logger.LogInformation("Password changed for practice employee {EmployeeId}.", employeeId);
            return true;
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "Password change failed for practice employee {EmployeeId}. SqlNumber={SqlNumber}", employeeId, ex.Number);
            return false;
        }
    }

    private static async Task<List<long>> LoadAllowedOrganizationsAsync(SqlConnection connection, string email, string employeeCode, long primaryOrganizationId, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT DISTINCT organization_id
            FROM grac_practice.user_organization_map
            WHERE status = 'Active'
              AND LOWER(user_email) IN (LOWER(@email), LOWER(@employee_code))
            UNION
            SELECT @primary_organization_id;
            """;
        command.Parameters.Add(new SqlParameter("@email", SqlDbType.NVarChar, 250) { Value = email });
        command.Parameters.Add(new SqlParameter("@employee_code", SqlDbType.NVarChar, 80) { Value = employeeCode });
        command.Parameters.Add(new SqlParameter("@primary_organization_id", SqlDbType.BigInt) { Value = primaryOrganizationId });

        var organizations = new List<long>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            organizations.Add(Convert.ToInt64(reader["organization_id"]));
        return organizations.Distinct().ToList();
    }

    private static async Task<List<string>> LoadPermissionsAsync(SqlConnection connection, long employeeId, long? roleId, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        // Union of the employee's primary role and every organization role
        // assigned through grac_practice.organization_employee_role, so
        // multi-role users receive the combined menu permissions.
        command.CommandText = """
            SELECT m.menu_key,
                   CAST(MAX(CAST(p.can_view AS INT)) AS BIT) can_view,
                   CAST(MAX(CAST(p.can_add AS INT)) AS BIT) can_add,
                   CAST(MAX(CAST(p.can_edit AS INT)) AS BIT) can_edit,
                   CAST(MAX(CAST(p.can_delete AS INT)) AS BIT) can_delete,
                   CAST(MAX(CAST(p.can_approve AS INT)) AS BIT) can_approve
            FROM grac_practice.organization_role_menu_permission p
            JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
            WHERE p.status = 'Active'
              AND m.status = 'Active'
              AND p.role_id IN (
                  SELECT er.role_id
                  FROM grac_practice.organization_employee_role er
                  WHERE er.employee_id = @employee_id AND er.status = 'Active'
                  UNION
                  SELECT @role_id WHERE @role_id IS NOT NULL
              )
            GROUP BY m.menu_key;
            """;
        // Fall back to the single-role query when the multi-role map has
        // not been migrated yet (script 027 not applied).
        if (await TableMissingAsync(connection, "grac_practice.organization_employee_role", cancellationToken))
        {
            if (!roleId.HasValue) return [];
            command.CommandText = """
                SELECT m.menu_key,
                       p.can_view,
                       p.can_add,
                       p.can_edit,
                       p.can_delete,
                       p.can_approve
                FROM grac_practice.organization_role_menu_permission p
                JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                WHERE p.role_id = @role_id
                  AND p.status = 'Active'
                  AND m.status = 'Active';
                """;
            command.Parameters.Add(new SqlParameter("@role_id", SqlDbType.BigInt) { Value = roleId.Value });
        }
        else
        {
            command.Parameters.Add(new SqlParameter("@employee_id", SqlDbType.BigInt) { Value = employeeId });
            command.Parameters.Add(new SqlParameter("@role_id", SqlDbType.BigInt) { Value = (object?)roleId ?? DBNull.Value });
        }

        var permissions = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = Convert.ToString(reader["menu_key"]) ?? "";
            if (string.IsNullOrWhiteSpace(key)) continue;
            if (reader.GetBoolean(reader.GetOrdinal("can_view"))) permissions.Add($"{key}:VIEW");
            if (reader.GetBoolean(reader.GetOrdinal("can_add"))) permissions.Add($"{key}:ADD");
            if (reader.GetBoolean(reader.GetOrdinal("can_edit"))) permissions.Add($"{key}:EDIT");
            if (reader.GetBoolean(reader.GetOrdinal("can_delete"))) permissions.Add($"{key}:DELETE");
            if (reader.GetBoolean(reader.GetOrdinal("can_approve"))) permissions.Add($"{key}:APPROVE");
        }
        return permissions.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static async Task<string> LoadEffectiveDataScopeAsync(SqlConnection connection, long employeeId, long? roleId, string fallback, CancellationToken cancellationToken)
    {
        if (await TableMissingAsync(connection, "grac_practice.organization_employee_role", cancellationToken))
            return fallback;
        if (!await ColumnExistsAsync(connection, "grac_practice.organization_role", "data_scope", cancellationToken))
            return fallback;

        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT DISTINCT ISNULL(r.data_scope, 'ORGANIZATION') AS data_scope
            FROM grac_practice.organization_employee_role er
            JOIN grac_practice.organization_role r ON r.role_id = er.role_id
            WHERE er.employee_id = @employee_id AND er.status = 'Active'
            UNION
            SELECT ISNULL(r2.data_scope, 'ORGANIZATION')
            FROM grac_practice.organization_role r2
            WHERE r2.role_id = @role_id
            """;
        command.Parameters.Add(new SqlParameter("@employee_id", SqlDbType.BigInt) { Value = employeeId });
        command.Parameters.Add(new SqlParameter("@role_id", SqlDbType.BigInt) { Value = (object?)roleId ?? DBNull.Value });

        var scopes = new List<string>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            scopes.Add(Convert.ToString(reader["data_scope"]) ?? "ORGANIZATION");

        if (scopes.Count == 0) return fallback;
        // Return the broadest scope (lowest index in priority array)
        return scopes.OrderBy(s => Array.IndexOf(DataScopePriority, s) is var i && i < 0 ? 999 : i).First();
    }

    private static async Task<bool> ColumnExistsAsync(SqlConnection connection, string tableName, string columnName, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COL_LENGTH(@table_name, @column_name);";
        command.Parameters.Add(new SqlParameter("@table_name", SqlDbType.NVarChar, 300) { Value = tableName });
        command.Parameters.Add(new SqlParameter("@column_name", SqlDbType.NVarChar, 128) { Value = columnName });
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is not null && result != DBNull.Value;
    }

    private static async Task<bool> TableMissingAsync(SqlConnection connection, string tableName, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT OBJECT_ID(@table_name,'U');";
        command.Parameters.Add(new SqlParameter("@table_name", SqlDbType.NVarChar, 300) { Value = tableName });
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is null || result == DBNull.Value;
    }
}
