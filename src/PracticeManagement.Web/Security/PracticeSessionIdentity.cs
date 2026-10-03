namespace PracticeManagement.Web.Security;

public static class PracticeSessionIdentity
{
    public const string UserKey = "PracticeManagement.User";
    // What the navbar shows. UserKey holds the sign-in SUBJECT (an email
    // or employee code) because everything downstream — the token, the
    // audit trail, the log lines — identifies the caller by it. That is
    // the wrong thing to greet somebody with, so the human-readable name
    // is carried separately rather than overloading UserKey and quietly
    // changing what gets logged.
    public const string DisplayNameKey = "PracticeManagement.DisplayName";
    public const string TokenKey = "PracticeManagement.AccessToken";
    public const string RolesKey = "PracticeManagement.Roles";
    public const string EmployeeIdKey = "PracticeManagement.EmployeeId";
    public const string OrganizationIdKey = "PracticeManagement.OrganizationId";
    public const string AllowedOrganizationIdsKey = "PracticeManagement.AllowedOrganizationIds";
    public const string OrganizationNameKey = "PracticeManagement.OrganizationName";
    public const string RoleIdKey = "PracticeManagement.RoleId";
    public const string RoleNameKey = "PracticeManagement.RoleName";
    public const string DataScopeKey = "PracticeManagement.DataScope";

    // Stable per-session secret used ONLY to encrypt/decrypt navigation
    // codes (NavigationContextProtector). It is minted once per session and
    // never rotates, unlike TokenKey which the idle-timeout middleware
    // re-issues on every foreground request -- see NavigationKey() in
    // PracticeManagementGatewayController for why the rotating token made
    // navigation codes fail after deployment.
    public const string NavigationKeyKey = "PracticeManagement.NavigationKey";

    // Sent by requests the page makes on its own, without the user doing
    // anything (the sidebar notification poll in _Layout.cshtml). The
    // idle-timeout middleware in Program.cs does not renew the access
    // token for these, so an open-but-idle tab still times out after
    // Security:TokenLifetimeMinutes instead of being kept alive forever
    // by its own polling.
    public const string BackgroundRequestHeader = "X-PM-Background";
}
