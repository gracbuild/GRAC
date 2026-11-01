// =====================================================================
// SsoProviders -- single sign-on configuration (2026-10-12)
//
// Microsoft (Entra ID) and Google, both through OpenID Connect. One app
// registration per provider, held in configuration (secrets via
// environment variables / key vault in production, never in git):
//
//   "Sso": {
//     "Microsoft": { "ClientId": "", "ClientSecret": "", "TenantId": "" },
//     "Google":    { "ClientId": "", "ClientSecret": "" }
//   }
//
// A provider is ENABLED only when its ClientId and ClientSecret are both
// set. An empty section leaves the login page exactly as it was -- no
// button, no handler registered.
//
// Organization-wise (migration 466): the Microsoft app is MULTI-TENANT.
// TenantId is now optional -- blank means "organizations" (any Entra work
// / school tenant); WHICH tenant may sign in to WHICH organization is the
// organization's own policy (Organization Administration -> Single Sign-On), checked
// by the API against the token's tid. A TenantId still set from the
// single-tenant setup keeps working (sign-in limited to that tenant).
//
// The scheme name doubles as the provider key in URLs (/Login/External?
// provider=Microsoft) and in the audit row the API writes.
// =====================================================================
namespace PracticeManagement.Web.Services;

public sealed record SsoProvider(string Scheme, string DisplayName, string Icon, string CallbackPath);

public static class SsoProviders
{
    /// <summary>Cookie scheme that holds the identity provider's answer for the
    /// few seconds between the provider's callback and LoginController
    /// .ExternalCallback. It is never the GRAC sign-in -- that is the session.</summary>
    public const string ExternalScheme = "PracticeManagement.External";

    public const string Microsoft = "Microsoft";
    public const string Google = "Google";

    public static IReadOnlyList<SsoProvider> Enabled(IConfiguration configuration)
    {
        var list = new List<SsoProvider>();
        if (IsMicrosoftConfigured(configuration))
            list.Add(new SsoProvider(Microsoft, "Microsoft", "fab fa-microsoft", "/signin-oidc-microsoft"));
        if (IsGoogleConfigured(configuration))
            list.Add(new SsoProvider(Google, "Google", "fab fa-google", "/signin-oidc-google"));
        return list;
    }

    public static SsoProvider? Find(IConfiguration configuration, string? scheme) =>
        Enabled(configuration).FirstOrDefault(p => p.Scheme.Equals(scheme ?? "", StringComparison.OrdinalIgnoreCase));

    public static bool IsMicrosoftConfigured(IConfiguration c) =>
        !string.IsNullOrWhiteSpace(c["Sso:Microsoft:ClientId"])
        && !string.IsNullOrWhiteSpace(c["Sso:Microsoft:ClientSecret"]);

    /// <summary>Entra authority: the configured TenantId, else
    /// "organizations" (multi-tenant, work / school accounts only).</summary>
    public static string MicrosoftAuthority(IConfiguration c)
    {
        var tenant = c["Sso:Microsoft:TenantId"];
        return $"https://login.microsoftonline.com/{(string.IsNullOrWhiteSpace(tenant) ? "organizations" : tenant.Trim())}/v2.0";
    }

    /// <summary>
    /// Issuer check for a multi-tenant Entra app. The discovery document of
    /// /organizations publishes the issuer as a template
    /// (https://login.microsoftonline.com/{tenantid}/v2.0), which the default
    /// validator cannot match. A token is accepted only when its issuer is
    /// exactly that template filled with the token's own tid -- i.e. a real
    /// Entra tenant vouched for it. WHICH tenants an organization accepts is
    /// then decided by the API (organization_sso_setting, migration 466).
    /// </summary>
    public static bool IsValidMicrosoftIssuer(string? issuer, string? tid) =>
        !string.IsNullOrWhiteSpace(issuer)
        && Guid.TryParse(tid, out _)
        && string.Equals(issuer, $"https://login.microsoftonline.com/{tid}/v2.0", StringComparison.OrdinalIgnoreCase);

    public static bool IsGoogleConfigured(IConfiguration c) =>
        !string.IsNullOrWhiteSpace(c["Sso:Google:ClientId"])
        && !string.IsNullOrWhiteSpace(c["Sso:Google:ClientSecret"]);
}
