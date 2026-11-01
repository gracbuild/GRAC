// =====================================================================
// OrganizationSsoSettingModels  (migration 466 -- organization-wise SSO)
//
// Contracts for OrganizationSsoSettingController (Organization Administration ->
// Organization tab -> "Single Sign-On") and for the sign-in check in
// PracticeAuthenticationService. See docs/single-sign-on.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public static class SsoLoginModes
{
    public const string SsoAndPassword = "SSO_AND_PASSWORD";
    public const string SsoOnly        = "SSO_ONLY";
}

/// <summary>Why a sign-in was refused, carried to the Web tier in
/// PracticeRepositoryResult.Field so the login page can say what to do.
/// Never set for "no such account / wrong password" -- those stay one
/// uniform message (no user-enumeration oracle).</summary>
public static class SignInFailures
{
    /// <summary>Password was correct, but the organization is SSO Only.</summary>
    public const string SsoRequired   = "sso-required";
    /// <summary>The identity provider vouched for the person, but the
    /// organization does not accept this provider / tenant / domain.</summary>
    public const string SsoNotAllowed = "sso-not-allowed";
    /// <summary>Migration 467: the person's account was created by SSO (or
    /// earlier) and is waiting for an administrator's approval.</summary>
    public const string SsoPending    = "sso-pending";
}

public sealed record AuthenticationOutcome(AuthenticatedUser? User, string? Failure = null)
{
    // Named argument on purpose: a bare new(null) binds to the record's
    // compiler-generated COPY constructor (AuthenticationOutcome(original)), which then
    // dereferences the null original -> NullReferenceException in the type
    // initializer, breaking every sign-in.
    public static readonly AuthenticationOutcome Rejected = new(User: null);
}

public sealed record OrganizationSsoSetting(
    long      OrganizationId,
    bool      SsoEnabled,
    bool      AllowMicrosoft,
    bool      AllowGoogle,
    string    MicrosoftTenantIds,
    string    AllowedEmailDomains,
    string    LoginMode,
    // 467 -- auto-provisioning
    bool      AutoCreateUsers,
    long?     DefaultRoleId,
    string?   DefaultRoleName,
    bool      RequireAdminApproval,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrganizationSsoSettingSaveRequest(
    long    OrganizationId,
    bool    SsoEnabled,
    bool    AllowMicrosoft,
    bool    AllowGoogle,
    string? MicrosoftTenantIds,
    string? AllowedEmailDomains,
    string? LoginMode,
    // 467 -- auto-provisioning
    bool    AutoCreateUsers = false,
    long?   DefaultRoleId = null,
    bool    RequireAdminApproval = true);

/// <summary>Migration 467: approve a user created by SSO that waits for approval.</summary>
public sealed record OrganizationSsoUserApproveRequest(long OrganizationId, long EmployeeId);

public sealed record OrganizationSsoSettingSaveResult(bool Success, string? Error, OrganizationSsoSetting? Saved);
