using System.Text.Json;
using ControlManagement.Security;

namespace PracticeManagement.Web.Services;

// =====================================================================
// PracticeLoginService
//
// The Web tier no longer opens a database connection. Sign-in and the
// first-login password change now go through the API (secure/authenticate,
// secure/set-password) exactly like every other operation — the database is
// reached ONLY through the API. All the SQL that used to live here moved to
// PracticeManagement.Api's PracticeAuthenticationService.
//
// Bootstrap problem: the API's secure endpoints require a validly-signed
// token, but sign-in is the step BEFORE a user session (and its token)
// exists. So this service mints a short-lived token carrying the PM_LOGIN
// role — which is NOT in Security:RolePermissions, so it grants no entity
// access and is inert on every data endpoint — purely to authenticate the
// transport and key the request envelope. The API's authenticate/set-password
// endpoints require only a valid token, not a permission, because
// authenticating is what happens before permissions apply.
// =====================================================================
public sealed class PracticeLoginService(
    SecurePracticeClient client,
    SignedAccessTokenService tokenService,
    ILogger<PracticeLoginService> logger)
{
    // The API is always the authentication source now, so the DB-vs-ReviewLogin
    // gate in LoginController behaves as before: with no ReviewLogin:Email
    // configured (production), a failed API sign-in is rejected rather than
    // falling back.
    public bool IsConfigured => true;

    private static readonly string[] BootstrapRoles = ["PM_LOGIN"];

    public async Task<PracticeLoginResult?> AuthenticateAsync(string loginId, string password, CancellationToken cancellationToken)
    {
        var request = new SecureRepositoryRequest
        {
            EntityType = "authenticate",
            Action = "AUTH",
            Data = JsonSerializer.SerializeToElement(new { loginId, password })
        };

        string responseJson;
        try
        {
            responseJson = await client.AuthenticateAsync(BootstrapToken(loginId), request, cancellationToken);
        }
        catch (PracticeApiException ex)
        {
            // Transport / API failure is not a bad password. Log it plainly so an
            // outage is not misread as an authentication problem; the user still
            // sees the uniform "invalid credentials" message from LoginController.
            logger.LogError(ex, "Sign-in for {LoginId} could not reach the practice API.", loginId);
            return null;
        }

        var envelope = Deserialize<PracticeLoginResult>(responseJson);
        if (envelope is null || !envelope.Success || envelope.Data is null)
            return null;

        return envelope.Data;
    }

    /// <summary>
    /// Resolve the employee row behind a login id WITHOUT a password.
    /// <para>
    /// Only the ReviewLogin (bootstrap) sign-in calls this, and only with the
    /// CONFIGURED email it has just verified against configuration. That path
    /// has no employee record behind it, so its session used to carry no
    /// employee id -- and every procedure that requires an actor
    /// (approve, reject, owner stamps) refused the request. Null is a
    /// supported answer: no employee row simply means the session stays as
    /// it was.
    /// </para>
    /// </summary>
    public async Task<ResolvedIdentityResult?> ResolveIdentityAsync(string loginId, CancellationToken cancellationToken)
    {
        var request = new SecureRepositoryRequest
        {
            EntityType = "resolve-identity",
            Action = "RESOLVE",
            Data = JsonSerializer.SerializeToElement(new { loginId })
        };

        string responseJson;
        try
        {
            responseJson = await client.ResolveIdentityAsync(BootstrapToken(loginId), request, cancellationToken);
        }
        catch (PracticeApiException ex)
        {
            // Never fatal to a sign-in that has already been verified. The
            // admin gets in; only the actor stamp is missing.
            logger.LogWarning(ex, "Identity resolve for {LoginId} could not reach the practice API.", loginId);
            return null;
        }

        var envelope = Deserialize<ResolvedIdentityResult>(responseJson);
        return envelope is { Success: true } ? envelope.Data : null;
    }

    public async Task<bool> SetPasswordAsync(long employeeId, string newPassword, CancellationToken cancellationToken)
    {
        var request = new SecureRepositoryRequest
        {
            EntityType = "set-password",
            Action = "SET_PASSWORD",
            Data = JsonSerializer.SerializeToElement(new { employeeId, newPassword })
        };

        string responseJson;
        try
        {
            responseJson = await client.SetPasswordAsync(BootstrapToken(employeeId.ToString()), request, cancellationToken);
        }
        catch (PracticeApiException ex)
        {
            logger.LogError(ex, "Password change for employee {EmployeeId} could not reach the practice API.", employeeId);
            return false;
        }

        // No Data on this one; the shape is shared, the payload is not.
        var envelope = Deserialize<PracticeLoginResult>(responseJson);
        return envelope?.Success == true;
    }

    // A validly-signed token whose PM_LOGIN role carries no entity permissions.
    // Subject is only for correlation in logs.
    private string BootstrapToken(string subject) => tokenService.Issue(subject, BootstrapRoles);

    private static Envelope<T>? Deserialize<T>(string json) where T : class
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            return JsonSerializer.Deserialize<Envelope<T>>(json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // Mirrors the API's PracticeRepositoryResult { Success, Message, Data }.
    // Generic in Data because three endpoints now share the shape: sign-in
    // returns the AuthenticatedUser (whose field names line up 1:1 with
    // PracticeLoginResult), resolve-identity returns the smaller identity,
    // and set-password returns none.
    private sealed record Envelope<T>(bool Success, string? Message, T? Data) where T : class;
}

/// <summary>
/// The API's ResolvedIdentity, seen from the Web tier. Identity only --
/// no permissions, no data scope, no role. Widening it would make a
/// password-free lookup look like a sign-in.
/// </summary>
public sealed record ResolvedIdentityResult(
    long   EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    string Email,
    long   OrganizationId);

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
    IReadOnlyList<long> AllowedOrganizationIds,
    bool MustChangePassword);
