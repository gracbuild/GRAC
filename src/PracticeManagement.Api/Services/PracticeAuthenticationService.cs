using System.Data;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;
using PracticeManagement.Web.Security; // PasswordHasher — linked source file, shared with the Web tier

namespace PracticeManagement.Api.Services;

public interface IPracticeAuthenticationService
{
    /// <summary>Verify credentials and return the caller's identity (User null on any failure).
    /// Failure is set only for <see cref="SignInFailures.SsoRequired"/> -- the password was
    /// right but the organization is SSO Only (migration 466).</summary>
    Task<AuthenticationOutcome> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken);

    /// <summary>
    /// Single sign-on (2026-10-12). The Web tier has already authenticated
    /// the person with Microsoft or Google (OpenID Connect) and passes the
    /// identity provider's VERIFIED email. Returns the same identity a
    /// password sign-in returns -- roles, permissions, data scope from GRAC --
    /// for the active employee with that EMAIL (never employee code), or
    /// null when there is none: an unknown person is blocked, not created.
    /// No password is checked and MustChangePassword is always false.
    /// Migration 466: the employee's ORGANIZATION must have SSO enabled and
    /// accept this provider, Microsoft tenant (<paramref name="tenantId"/>,
    /// the token's tid) and email domain; otherwise Failure is
    /// <see cref="SignInFailures.SsoNotAllowed"/>.
    /// Migration 467: with no employee for the email, an organization set to
    /// auto-create users creates one (<paramref name="displayName"/> from the
    /// token); when it needs admin approval, Failure is
    /// <see cref="SignInFailures.SsoPending"/>.
    /// </summary>
    Task<AuthenticationOutcome> AuthenticateExternalAsync(string email, string provider, string? subject, string? tenantId, string? displayName, CancellationToken cancellationToken);

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

    public Task<AuthenticationOutcome> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken) =>
        AuthenticateCoreAsync(loginId, password, null, null, null, cancellationToken);

    public async Task<AuthenticationOutcome> AuthenticateExternalAsync(string email, string provider, string? subject, string? tenantId, string? displayName, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(email) || string.IsNullOrWhiteSpace(provider)) return AuthenticationOutcome.Rejected;
        var outcome = await AuthenticateCoreAsync(email, null, provider, subject, tenantId, cancellationToken);
        if (outcome.User is not null || outcome.Failure is not null) return outcome;

        // Migration 467: no active employee has this email. If the policy of
        // exactly one organization auto-creates users for this provider /
        // tenant / domain, create one; then sign in (auto approve) or report
        // that it waits for approval.
        var provisioned = await ProvisionExternalUserAsync(email, provider, subject, tenantId, displayName, cancellationToken);
        return provisioned switch
        {
            "CREATED_ACTIVE"                 => await AuthenticateCoreAsync(email, null, provider, subject, tenantId, cancellationToken),
            "CREATED_PENDING" or "PENDING"   => new AuthenticationOutcome(null, SignInFailures.SsoPending),
            _                                => AuthenticationOutcome.Rejected
        };
    }

    // sp_org_sso_provision_user (467). Returns its Result code, or null when
    // 467 is not applied (auto-create then simply does not exist). Any SQL
    // failure is logged and treated as "not created" -- the person stays
    // blocked, exactly as before 467.
    private async Task<string?> ProvisionExternalUserAsync(string email, string provider, string? subject,
        string? tenantId, string? displayName, CancellationToken cancellationToken)
    {
        var connectionString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString)) return null;
        try
        {
            await using var connection = new SqlConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            await using (var probe = connection.CreateCommand())
            {
                probe.CommandText = "SELECT OBJECT_ID('grac_practice.sp_org_sso_provision_user','P');";
                var exists = await probe.ExecuteScalarAsync(cancellationToken);
                if (exists is null || exists == DBNull.Value) return null;
            }
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sso_provision_user";
            command.Parameters.Add(new SqlParameter("@email", SqlDbType.NVarChar, 250) { Value = email.Trim() });
            command.Parameters.Add(new SqlParameter("@display_name", SqlDbType.NVarChar, 200)
                { Value = string.IsNullOrWhiteSpace(displayName) ? DBNull.Value : (displayName.Length > 200 ? displayName[..200] : displayName) });
            command.Parameters.Add(new SqlParameter("@provider", SqlDbType.NVarChar, 40) { Value = provider });
            command.Parameters.Add(new SqlParameter("@tenant_id", SqlDbType.NVarChar, 64) { Value = (object?)tenantId ?? DBNull.Value });
            command.Parameters.Add(new SqlParameter("@subject", SqlDbType.NVarChar, 200) { Value = (object?)subject ?? DBNull.Value });
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken)) return null;
            var result = Convert.ToString(reader["Result"]);
            logger.LogInformation("SSO auto-provisioning for {Email} via {Provider} (tenant {TenantId}): {Result}, employee {EmployeeId}, organization {OrganizationId}.",
                email, provider, tenantId, result, reader["EmployeeId"], reader["OrganizationId"]);
            return result;
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "SSO auto-provisioning failed for {Email} via {Provider}.", email, provider);
            return null;
        }
    }

    // One sign-in body for both paths, so a single-sign-on user gets exactly
    // the identity, permissions and data scope a password user would.
    //   password != null : password sign-in, matched on employee code OR email
    //   externalProvider : SSO, matched on EMAIL only, no password, never
    //                      MustChangePassword, success written to
    //                      practice_audit_trace (entity 'sso-login')
    // Migration 466: both paths then apply the employee organization's SSO
    // policy (organization_sso_setting) -- see CheckSsoPolicy.
    private async Task<AuthenticationOutcome> AuthenticateCoreAsync(string loginId, string? password,
        string? externalProvider, string? externalSubject, string? externalTenantId, CancellationToken cancellationToken)
    {
        var isExternal = externalProvider is not null;
        var connectionString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogError("Sign-in cannot proceed: no database connection is configured (ConnectionStrings:PracticeManagement or DbConnection+Password).");
            return AuthenticationOutcome.Rejected;
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
              AND (LOWER(e.email) = LOWER(@login_id)
                   OR (@email_only = 0 AND LOWER(e.employee_code) = LOWER(@login_id)));
            """;
        command.Parameters.Add(new SqlParameter("@login_id", SqlDbType.NVarChar, 250) { Value = loginId.Trim() });
        // SSO matches the identity provider's email only -- an employee code
        // that happens to look like someone's email must not match.
        command.Parameters.Add(new SqlParameter("@email_only", SqlDbType.Bit) { Value = isExternal });

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
            return AuthenticationOutcome.Rejected;
        }

        var passwordHash = reader["password_hash"] as string;
        if (isExternal)
        {
            // No password step: the identity provider authenticated the person.
        }
        else if (string.IsNullOrWhiteSpace(passwordHash))
        {
            logger.LogWarning(
                "Sign-in failed for {LoginId}: employee {EmployeeId} has no password hash. The account was written without one.",
                loginId, reader["employee_id"]);
            return AuthenticationOutcome.Rejected;
        }
        else if (!passwordHasher.Verify(password!, passwordHash))
        {
            logger.LogWarning(
                "Sign-in failed for {LoginId}: password mismatch for employee {EmployeeId} (created {EnteredDt} by {EnteredBy}). "
                + "The stored hash is valid but does not correspond to the password supplied. If this account was provisioned "
                + "with the default, confirm UserProvisioning:DefaultPassword in the deployment that CREATED the account matches "
                + "what was configured when the account was created.",
                loginId, reader["employee_id"], reader["entered_dt"], reader["entered_by"]);
            return AuthenticationOutcome.Rejected;
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
        // An SSO user has no GRAC password to change.
        var mustChangePassword = !isExternal
            && reader["force_password_change"] != DBNull.Value && Convert.ToBoolean(reader["force_password_change"]);
        await reader.CloseAsync();

        // Organization-wise SSO policy (migration 466), checked AFTER the
        // password was verified so "SSO Only" is never revealed to someone
        // who does not hold the password.
        var policy = await LoadSsoPolicyAsync(connection, organizationId, cancellationToken);
        if (isExternal)
        {
            var refusal = CheckSsoPolicy(policy, externalProvider!, externalTenantId, loginId);
            if (refusal is not null)
            {
                logger.LogWarning("SSO sign-in via {Provider} for {LoginId} (employee {EmployeeId}, organization {OrganizationId}) refused: {Reason}",
                    externalProvider, loginId, employeeId, organizationId, refusal);
                return new AuthenticationOutcome(null, SignInFailures.SsoNotAllowed);
            }
        }
        else if (policy is { SsoEnabled: true } && string.Equals(policy.LoginMode, SsoLoginModes.SsoOnly, StringComparison.OrdinalIgnoreCase))
        {
            logger.LogWarning("Password sign-in for {LoginId} (employee {EmployeeId}) refused: organization {OrganizationId} is SSO Only.",
                loginId, employeeId, organizationId);
            return new AuthenticationOutcome(null, SignInFailures.SsoRequired);
        }

        var permissions = await LoadPermissionsAsync(connection, employeeId, roleId, cancellationToken);
        var allowedOrganizationIds = await LoadAllowedOrganizationsAsync(connection, email, employeeCode, organizationId, cancellationToken);
        var effectiveDataScope = await LoadEffectiveDataScopeAsync(connection, employeeId, roleId, dataScope, cancellationToken);
        if (permissions.Count == 0)
            logger.LogWarning("Practice employee {EmployeeId} signed in with no menu permissions.", employeeId);
        if (isExternal)
            await WriteSsoAuditAsync(connection, employeeId, email, externalProvider!, externalSubject, externalTenantId, cancellationToken);

        return new AuthenticationOutcome(new AuthenticatedUser(
            employeeId, employeeCode, employeeName, email,
            organizationId, organizationCode, organizationName,
            roleId, roleName, effectiveDataScope,
            permissions, allowedOrganizationIds, mustChangePassword));
    }

    // Audit an SSO sign-in in practice_audit_trace (the table the Audit
    // Traceability page reads). Best-effort: a failed audit write is logged
    // and never blocks a sign-in the identity provider has already approved.
    private async Task WriteSsoAuditAsync(SqlConnection connection, long employeeId, string email,
        string provider, string? subject, string? tenantId, CancellationToken cancellationToken)
    {
        try
        {
            await using var audit = connection.CreateCommand();
            audit.CommandText = """
                INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, after_json, status, entered_by)
                VALUES (N'sso-login', @employee_id, N'LOGIN',
                        (SELECT @provider AS provider, @subject AS subject, @tenant_id AS tenantId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                        N'Active', @entered_by);
                """;
            audit.Parameters.Add(new SqlParameter("@employee_id", SqlDbType.BigInt) { Value = employeeId });
            audit.Parameters.Add(new SqlParameter("@provider", SqlDbType.NVarChar, 40) { Value = provider });
            audit.Parameters.Add(new SqlParameter("@subject", SqlDbType.NVarChar, 200) { Value = (object?)subject ?? DBNull.Value });
            audit.Parameters.Add(new SqlParameter("@tenant_id", SqlDbType.NVarChar, 64) { Value = (object?)tenantId ?? DBNull.Value });
            audit.Parameters.Add(new SqlParameter("@entered_by", SqlDbType.NVarChar, 100)
                { Value = string.IsNullOrWhiteSpace(email) ? "sso" : (email.Length > 100 ? email[..100] : email) });
            await audit.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SSO sign-in audit could not be written for employee {EmployeeId}.", employeeId);
        }
    }

    // -----------------------------------------------------------------
    // Organization-wise SSO policy (migration 466, docs/single-sign-on.md)
    // -----------------------------------------------------------------
    private sealed record SsoPolicy(bool SsoEnabled, bool AllowMicrosoft, bool AllowGoogle,
        IReadOnlySet<string> TenantIds, IReadOnlySet<string> EmailDomains, string LoginMode);

    // Null when the organization has no row, or 466 is not applied yet:
    // then no SSO sign-in is accepted and password sign-in is unchanged.
    private static async Task<SsoPolicy?> LoadSsoPolicyAsync(SqlConnection connection, long organizationId, CancellationToken cancellationToken)
    {
        if (await TableMissingAsync(connection, "grac_practice.organization_sso_setting", cancellationToken)) return null;
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT sso_enabled, allow_microsoft, allow_google,
                   ISNULL(microsoft_tenant_ids, N'') AS microsoft_tenant_ids,
                   ISNULL(allowed_email_domains, N'') AS allowed_email_domains,
                   login_mode
            FROM grac_practice.organization_sso_setting
            WHERE organization_id = @organization_id;
            """;
        command.Parameters.Add(new SqlParameter("@organization_id", SqlDbType.BigInt) { Value = organizationId });
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        static HashSet<string> List(object value) =>
            new((Convert.ToString(value) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries),
                StringComparer.OrdinalIgnoreCase);
        return new SsoPolicy(
            Convert.ToBoolean(reader["sso_enabled"]),
            Convert.ToBoolean(reader["allow_microsoft"]),
            Convert.ToBoolean(reader["allow_google"]),
            List(reader["microsoft_tenant_ids"]),
            List(reader["allowed_email_domains"]),
            Convert.ToString(reader["login_mode"]) ?? SsoLoginModes.SsoAndPassword);
    }

    // Null = allowed; otherwise the reason, for the log only (the visitor
    // sees one "not enabled for your organization" message).
    private static string? CheckSsoPolicy(SsoPolicy? policy, string provider, string? tenantId, string email)
    {
        if (policy is null || !policy.SsoEnabled) return "single sign-on is not enabled for the organization";
        var at = email.LastIndexOf('@');
        var domain = at >= 0 ? email[(at + 1)..].Trim() : "";
        if (provider.Equals("Microsoft", StringComparison.OrdinalIgnoreCase))
        {
            if (!policy.AllowMicrosoft) return "Microsoft sign-in is not allowed for the organization";
            // The tenant is what makes a Microsoft identity trustworthy for
            // THIS organization: an email from any other tenant is refused.
            if (string.IsNullOrWhiteSpace(tenantId) || !policy.TenantIds.Contains(tenantId.Trim()))
                return $"Microsoft tenant '{tenantId}' is not an allowed tenant of the organization";
        }
        else if (provider.Equals("Google", StringComparison.OrdinalIgnoreCase))
        {
            if (!policy.AllowGoogle) return "Google sign-in is not allowed for the organization";
            // Google has no tenant: the email domain is the only boundary.
            if (policy.EmailDomains.Count == 0) return "no allowed email domain is set for Google sign-in";
        }
        else return $"unknown provider '{provider}'";
        if (policy.EmailDomains.Count > 0 && !policy.EmailDomains.Contains(domain))
            return $"email domain '{domain}' is not an allowed domain of the organization";
        return null;
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
        // 2026-10-06: a CONTAINER menu (menu_url NULL / '' / '#', e.g. Risk
        // Management 'risk-centre' since 383/416) has no row of its own in
        // Role Master's permission matrix -- role-menu-permission-editor.js
        // draws only its children -- so no role created through the matrix
        // can hold it. Screens that are governed by their container
        // (PracticeController.ScreenPermissionArea: risk-centre-* ->
        // risk-centre, and the Risk Centre API) then refused everyone:
        // "Your role does not have View permission for Risk Candidate ...
        // risk-centre". A container now holds, per action, whatever any of
        // its Active children hold (plus any row it has itself). Applied
        // only when menu_master.parent_menu_id exists (052).
        if (await ColumnExistsAsync(connection, "grac_practice.menu_master", "parent_menu_id", cancellationToken))
        {
            command.CommandText = """
                ;WITH granted AS (
                    SELECT p.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve
                    FROM grac_practice.organization_role_menu_permission p
                    WHERE p.status = 'Active'
                      AND p.role_id IN (
                          SELECT er.role_id
                          FROM grac_practice.organization_employee_role er
                          WHERE er.employee_id = @employee_id AND er.status = 'Active'
                          UNION
                          SELECT @role_id WHERE @role_id IS NOT NULL
                      )
                ), effective AS (
                    SELECT g.menu_id, g.can_view, g.can_add, g.can_edit, g.can_delete, g.can_approve
                    FROM granted g
                    UNION ALL
                    SELECT child.parent_menu_id, g.can_view, g.can_add, g.can_edit, g.can_delete, g.can_approve
                    FROM granted g
                    JOIN grac_practice.menu_master child
                      ON child.menu_id = g.menu_id AND child.status = 'Active' AND child.parent_menu_id IS NOT NULL
                    JOIN grac_practice.menu_master container
                      ON container.menu_id = child.parent_menu_id
                     AND LTRIM(RTRIM(ISNULL(container.menu_url, ''))) IN ('', '#')
                )
                SELECT m.menu_key,
                       CAST(MAX(CAST(e.can_view AS INT)) AS BIT) can_view,
                       CAST(MAX(CAST(e.can_add AS INT)) AS BIT) can_add,
                       CAST(MAX(CAST(e.can_edit AS INT)) AS BIT) can_edit,
                       CAST(MAX(CAST(e.can_delete AS INT)) AS BIT) can_delete,
                       CAST(MAX(CAST(e.can_approve AS INT)) AS BIT) can_approve
                FROM effective e
                JOIN grac_practice.menu_master m ON m.menu_id = e.menu_id
                WHERE m.status = 'Active'
                GROUP BY m.menu_key;
                """;
        }
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
