using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Services;

public sealed class PracticeLoginService(IConfiguration configuration, PasswordHasher passwordHasher, ILogger<PracticeLoginService> logger)
{
    public bool IsConfigured => !string.IsNullOrWhiteSpace(GetConnectionString());

    public async Task<PracticeLoginResult?> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken)
    {
        var connectionString = GetConnectionString();
        if (string.IsNullOrWhiteSpace(connectionString)) return null;

        await using var connection = new SqlConnection(ConfigureConnectionString(connectionString));
        await connection.OpenAsync(cancellationToken);

        await using var command = connection.CreateCommand();
        command.CommandText = """
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
                   ISNULL(r.data_scope, 'ORGANIZATION') AS data_scope
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
        if (!await reader.ReadAsync(cancellationToken)) return null;

        var passwordHash = reader["password_hash"] as string;
        if (string.IsNullOrWhiteSpace(passwordHash) || !passwordHasher.Verify(password, passwordHash))
            return null;

        var result = new PracticeLoginResult(
            Convert.ToInt64(reader["employee_id"]),
            Convert.ToString(reader["employee_code"]) ?? loginId,
            Convert.ToString(reader["employee_name"]) ?? loginId,
            Convert.ToString(reader["email"]) ?? "",
            Convert.ToInt64(reader["organization_id"]),
            Convert.ToString(reader["organization_code"]) ?? "",
            Convert.ToString(reader["organization_name"]) ?? "",
            reader["role_id"] == DBNull.Value ? null : Convert.ToInt64(reader["role_id"]),
            Convert.ToString(reader["role_name"]) ?? "Organization User",
            Convert.ToString(reader["data_scope"]) ?? "ORGANIZATION",
            [],
            []);
        await reader.CloseAsync();

        var permissions = await LoadPermissionsAsync(connection, result.EmployeeId, result.RoleId, cancellationToken);
        var allowedOrganizationIds = await LoadAllowedOrganizationsAsync(connection, result.Email, result.EmployeeCode, result.OrganizationId, cancellationToken);
        var effectiveDataScope = await LoadEffectiveDataScopeAsync(connection, result.EmployeeId, result.RoleId, result.DataScope, cancellationToken);
        if (permissions.Count == 0)
            logger.LogWarning("Practice employee {EmployeeId} signed in with no menu permissions.", result.EmployeeId);

        return result with { Permissions = permissions, AllowedOrganizationIds = allowedOrganizationIds, DataScope = effectiveDataScope };
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

    // For multi-role users, pick the broadest data_scope across all roles.
    // Breadth order: GLOBAL > ORGANIZATION > RELEASE > STATEMENT > PRACTICE > INSTANCE
    private static readonly string[] DataScopePriority = ["GLOBAL", "ORGANIZATION", "RELEASE", "STATEMENT", "PRACTICE", "INSTANCE"];

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

    private string ConfigureConnectionString(string connectionString)
    {
        var builder = new SqlConnectionStringBuilder(connectionString)
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
}

public sealed record PracticeLoginResult(
    long EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    string Email,
    long OrganizationId,
    string OrganizationCode,
    string OrganizationName,
    long? RoleId,
    string RoleName,
    string DataScope,
    IReadOnlyList<string> Permissions,
    IReadOnlyList<long> AllowedOrganizationIds);
