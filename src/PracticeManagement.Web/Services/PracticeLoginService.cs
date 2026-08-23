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

        var envelope = Deserialize(responseJson);
        if (envelope is null || !envelope.Success || envelope.Data is null)
            return null;

        return envelope.Data;
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

        var envelope = Deserialize(responseJson);
        return envelope?.Success == true;
    }

    // A validly-signed token whose PM_LOGIN role carries no entity permissions.
    // Subject is only for correlation in logs.
    private string BootstrapToken(string subject) => tokenService.Issue(subject, BootstrapRoles);

    private static AuthEnvelope? Deserialize(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            return JsonSerializer.Deserialize<AuthEnvelope>(json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // Mirrors the API's PracticeRepositoryResult { Success, Message, Data }.
    // Data carries the AuthenticatedUser, whose field names line up 1:1 with
    // PracticeLoginResult, so it deserializes straight into it.
    private sealed record AuthEnvelope(bool Success, string? Message, PracticeLoginResult? Data);
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
    IReadOnlyList<long> AllowedOrganizationIds,
    bool MustChangePassword);
