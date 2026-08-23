using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using PracticeManagement.Web.Models;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;

namespace PracticeManagement.Web.Controllers;

public sealed class LoginController(
    IConfiguration configuration,
    PasswordHasher passwordHasher,
    SignedAccessTokenService tokenService,
    PracticeLoginService loginService,
    ILogger<LoginController> logger) : Controller
{
    // =================================================================
    // Supporting reads — entity types the gateway serves that are NOT
    // screens, so menu_master has no row for them and no role can ever
    // be granted them from Organization > Role Menu Permissions.
    //
    // Without this list a database user hits
    //   permissionPolicy.IsAllowed(Roles(), "<key>", "VIEW") == false
    // on a read the screen makes for itself, and the request is refused.
    // The ReviewLogin admin never notices: PM_ADMIN is "*:*".
    //
    // Granting them to every signed-in user is safe because each one is
    // still organisation-scoped at the gateway —
    // OrganizationScopedEntityTypes contains them, so
    // ValidateRequestedOrganization keeps the caller inside their own
    // AllowedOrganizationIds. What is being granted here is "may ask",
    // not "may see everything".
    //
    // subscribed-frameworks was the one that got missed: it backs the
    // "All subscribed frameworks" filter (practice.js loadSubscribedFrameworks)
    // AND the Repository Subscriptions release grid (loadReleaseSummary),
    // so it belongs to more than one screen and could not be aliased to a
    // parent area the way PermissionArea() maps release-statements and
    // custom-release onto organization-controls.
    //
    // Both sign-in paths use this one array — they previously repeated
    // the same three literals, which is how the fourth went missing from
    // only one of them.
    // =================================================================
    private static readonly string[] SupportingReads =
    [
        "menu-master:VIEW",
        "lookups:VIEW",
        "dashboard-summary:VIEW",
        "subscribed-frameworks:VIEW"
    ];

    [HttpGet]
    public IActionResult Index(string? returnUrl = null)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is not null)
            return DefaultRedirect();

        return View(new LoginViewModel { ReturnUrl = returnUrl });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> Index(LoginViewModel model, CancellationToken cancellationToken)
    {
        if (!ModelState.IsValid) return View(model);

        var dbLogin = await loginService.AuthenticateAsync(model.LoginId, model.Password, cancellationToken);
        if (dbLogin is not null)
        {
            // An account still on the shared default password gets no session.
            // Two signals, because they catch different rows: the flag is set
            // by provisioning (migration 208 / 034), while the password
            // comparison also catches accounts created before either existed.
            if (RequiresPasswordChange(dbLogin, model.Password))
            {
                logger.LogInformation("PracticeManagement sign-in for {User} requires a password change before a session is issued.", model.LoginId);
                // Redirect rather than render: the address bar then matches the
                // screen, a refresh does not re-post the sign-in, and the
                // change-password form starts with clean ModelState instead of
                // inheriting this POST's entries.
                return RedirectToChangePassword(model.LoginId, model.ReturnUrl);
            }

            SignIn(dbLogin, model.LoginId);
            if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
            return DefaultRedirect();
        }

        if (loginService.IsConfigured && string.IsNullOrWhiteSpace(configuration["ReviewLogin:Email"]))
        {
            logger.LogWarning("Rejected PracticeManagement employee sign-in for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);
            ModelState.AddModelError("", "Invalid user ID/email or password.");
            return View(model);
        }

        var email = configuration["ReviewLogin:Email"];
        var passwordHash = configuration["ReviewLogin:PasswordHash"];
        if (string.IsNullOrWhiteSpace(email) || string.IsNullOrWhiteSpace(passwordHash))
        {
            ModelState.AddModelError("", "Configure Practice Management login credentials before signing in.");
            return View(model);
        }

        if (!string.Equals(model.LoginId, email, StringComparison.OrdinalIgnoreCase) || !passwordHasher.Verify(model.Password, passwordHash))
        {
            logger.LogWarning("Rejected PracticeManagement sign-in for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);
            ModelState.AddModelError("", "Invalid user ID/email or password.");
            return View(model);
        }

        var roles = ExpandPermissionAliases(configuration.GetSection("ReviewLogin:Roles").Get<string[]>() ?? ["PM_REVIEWER"])
            .Concat(SupportingReads)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        HttpContext.Session.Clear();
        HttpContext.Session.SetString(PracticeSessionIdentity.UserKey, model.LoginId);
        // The bootstrap login has no employee record behind it, so the
        // sign-in id is the only honest name to show.
        HttpContext.Session.SetString(PracticeSessionIdentity.DisplayNameKey, model.LoginId);
        HttpContext.Session.SetString(PracticeSessionIdentity.RolesKey, string.Join(',', roles));
        HttpContext.Session.SetString(PracticeSessionIdentity.TokenKey, tokenService.Issue(model.LoginId, roles));
        // ReviewLogin path is treated as GRAC Admin (data_scope=GLOBAL) so the
        // Organization filter used by Task Center and other organization-scoped
        // screens lists every active organization for this admin. Note: we do
        // NOT set OrganizationIdKey here — GRAC Admin picks the target org
        // via the dropdown, and the server validates the choice against the
        // user's allowed organizations on every request.
        HttpContext.Session.SetString(PracticeSessionIdentity.DataScopeKey, "GLOBAL");
        HttpContext.Session.SetString(PracticeSessionIdentity.RoleNameKey,
            configuration["ReviewLogin:DisplayRole"] ?? "GRAC Admin");
        logger.LogInformation("PracticeManagement sign-in succeeded for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);

        if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
        return DefaultRedirect();
    }

    // =================================================================
    // Forced first-login password change (migration 208).
    //
    // Reached only from the sign-in POST above, which has already verified
    // the credentials — but no session exists yet, so this action re-verifies
    // the current password rather than trusting the LoginId round-tripping
    // through the form. Without that check, posting someone else's LoginId
    // would reset their password.
    // =================================================================
    [HttpGet]
    public IActionResult ChangePassword(string? loginId = null, string? returnUrl = null, bool forced = false)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is not null)
            return DefaultRedirect();

        return View(new ChangePasswordViewModel
        {
            LoginId = loginId ?? "",
            ReturnUrl = returnUrl,
            IsForced = forced
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> ChangePassword(ChangePasswordViewModel model, CancellationToken cancellationToken)
    {
        if (!ModelState.IsValid) return View(model);

        var minimumLength = configuration.GetValue("UserProvisioning:MinimumPasswordLength", 8);
        if (model.NewPassword.Length < minimumLength)
        {
            ModelState.AddModelError(nameof(model.NewPassword), $"The new password must be at least {minimumLength} characters.");
            return View(model);
        }
        if (string.Equals(model.NewPassword, model.CurrentPassword, StringComparison.Ordinal))
        {
            ModelState.AddModelError(nameof(model.NewPassword), "The new password must be different from the current one.");
            return View(model);
        }
        if (IsDefaultPassword(model.NewPassword))
        {
            ModelState.AddModelError(nameof(model.NewPassword), "The new password cannot be the default password.");
            return View(model);
        }

        var dbLogin = await loginService.AuthenticateAsync(model.LoginId, model.CurrentPassword, cancellationToken);
        if (dbLogin is null)
        {
            logger.LogWarning("Rejected PracticeManagement password change for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);
            ModelState.AddModelError("", "Invalid user ID/email or current password.");
            return View(model);
        }

        if (!await loginService.SetPasswordAsync(dbLogin.EmployeeId, model.NewPassword, cancellationToken))
        {
            ModelState.AddModelError("", "The password could not be changed. Please contact your administrator.");
            return View(model);
        }

        // Re-authenticate on the new password so the session is built from the
        // stored state (force_password_change now 0), not from the pre-change
        // result we already hold.
        var signedIn = await loginService.AuthenticateAsync(model.LoginId, model.NewPassword, cancellationToken);
        if (signedIn is null)
        {
            ModelState.AddModelError("", "Your password was changed. Please sign in with the new password.");
            return View("Index", new LoginViewModel { LoginId = model.LoginId, ReturnUrl = model.ReturnUrl });
        }

        SignIn(signedIn, model.LoginId);
        if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
        return DefaultRedirect();
    }

    private bool RequiresPasswordChange(PracticeLoginResult dbLogin, string suppliedPassword) =>
        dbLogin.MustChangePassword || IsDefaultPassword(suppliedPassword);

    private bool IsDefaultPassword(string password)
    {
        var configured = configuration["UserProvisioning:DefaultPassword"];
        return !string.IsNullOrWhiteSpace(configured)
            && string.Equals(password, configured, StringComparison.Ordinal);
    }

    private void SignIn(PracticeLoginResult dbLogin, string loginId)
    {
        HttpContext.Session.Clear();
        var permissionRoles = ExpandPermissionAliases(dbLogin.Permissions.Count > 0 ? dbLogin.Permissions : ["practice-management:VIEW"])
            .Concat(SupportingReads)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var subject = dbLogin.Email.Length > 0 ? dbLogin.Email : dbLogin.EmployeeCode;
        HttpContext.Session.SetString(PracticeSessionIdentity.UserKey, subject);
        // Falls back to the subject rather than to a constant: a user with
        // no employee_name on file should see their own email, not
        // somebody else's job title.
        HttpContext.Session.SetString(PracticeSessionIdentity.DisplayNameKey,
            string.IsNullOrWhiteSpace(dbLogin.EmployeeName) ? subject : dbLogin.EmployeeName);
        HttpContext.Session.SetString(PracticeSessionIdentity.EmployeeIdKey, dbLogin.EmployeeId.ToString());
        HttpContext.Session.SetString(PracticeSessionIdentity.OrganizationIdKey, dbLogin.OrganizationId.ToString());
        var allowedOrganizations = dbLogin.AllowedOrganizationIds.Count > 0
            ? dbLogin.AllowedOrganizationIds
            : new[] { dbLogin.OrganizationId };
        HttpContext.Session.SetString(PracticeSessionIdentity.AllowedOrganizationIdsKey, string.Join(',', allowedOrganizations));
        HttpContext.Session.SetString(PracticeSessionIdentity.OrganizationNameKey, dbLogin.OrganizationName);
        HttpContext.Session.SetString(PracticeSessionIdentity.RoleIdKey, dbLogin.RoleId?.ToString() ?? "");
        HttpContext.Session.SetString(PracticeSessionIdentity.RoleNameKey, dbLogin.RoleName);
        HttpContext.Session.SetString(PracticeSessionIdentity.DataScopeKey, dbLogin.DataScope);
        HttpContext.Session.SetString(PracticeSessionIdentity.RolesKey, string.Join(',', permissionRoles));
        HttpContext.Session.SetString(PracticeSessionIdentity.TokenKey, tokenService.Issue(subject, permissionRoles));
        logger.LogInformation("PracticeManagement employee sign-in succeeded for {User} from {RemoteAddress}", loginId, HttpContext.Connection.RemoteIpAddress);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public IActionResult Logout()
    {
        logger.LogInformation("PracticeManagement sign-out for {User}", HttpContext.Session.GetString(PracticeSessionIdentity.UserKey));
        HttpContext.Session.Clear();
        return DefaultRedirectToLogin();
    }

    private IActionResult DefaultRedirect()
    {
        var pathBase = CurrentPathBase();
        return IsOrganizationManagementRequest()
            ? LocalRedirect(BuildLocalUrl(pathBase, "/OrganizationManagement"))
            : LocalRedirect(BuildLocalUrl(pathBase, "/Practice"));
    }

    private IActionResult DefaultRedirectToLogin()
    {
        var pathBase = CurrentPathBase();
        return IsOrganizationManagementRequest()
            ? LocalRedirect(BuildLocalUrl(pathBase, "/OrganizationManagement/Login"))
            : LocalRedirect(BuildLocalUrl(pathBase, "/Login"));
    }

    // Built explicitly for the same reason DefaultRedirectToLogin is: Url.Action
    // / RedirectToAction can pick the organization-management-login route via
    // LinkGenerator scoring and emit /OrganizationManagement/Login/... on a
    // Practice Management host, which PathBase then double-prefixes.
    private IActionResult RedirectToChangePassword(string loginId, string? returnUrl)
    {
        var pathBase = CurrentPathBase();
        var root = IsOrganizationManagementRequest() ? "/OrganizationManagement/Login" : "/Login";
        var query = $"?loginId={Uri.EscapeDataString(loginId)}&forced=true";
        if (Url.IsLocalUrl(returnUrl)) query += $"&returnUrl={Uri.EscapeDataString(returnUrl!)}";
        return LocalRedirect(BuildLocalUrl(pathBase, $"{root}/ChangePassword") + query);
    }

    // Strict — anchor the module identity on positive configuration and
    // on the deployed PathBase only. Do NOT infer OrganizationManagement
    // from Request.Path segments; otherwise a stray "/OrganizationManagement"
    // in the URL (e.g. after a bad redirect) permanently poisons the
    // module mode for a Practice Management host.
    private bool IsOrganizationManagementRequest() =>
        string.Equals(configuration["Module:Key"], "OrganizationManagement", StringComparison.OrdinalIgnoreCase)
        || Request.PathBase.Equals("/OrganizationManagement", StringComparison.OrdinalIgnoreCase);

    private string CurrentPathBase() => Request.PathBase.Value?.TrimEnd('/') ?? "";

    private static string BuildLocalUrl(string pathBase, string path) =>
        string.IsNullOrEmpty(pathBase) ? path : $"{pathBase}{path}";

    private static IEnumerable<string> ExpandPermissionAliases(IEnumerable<string> permissions)
    {
        foreach (var permission in permissions)
        {
            yield return permission;
            if (permission.StartsWith("practice-operationalization:", StringComparison.OrdinalIgnoreCase))
                yield return "resolve:" + permission.Split(':', 2)[1];
            if (permission.StartsWith("resolve:", StringComparison.OrdinalIgnoreCase)
                || permission.StartsWith("practice-operationalization:", StringComparison.OrdinalIgnoreCase))
            {
                var action = permission.Split(':', 2)[1];
                yield return $"practice-dependency-resolutions:{action}";
                yield return $"evidence-configurations:{action}";
                if (action.Equals("EDIT", StringComparison.OrdinalIgnoreCase)
                    || action.Equals("ADD", StringComparison.OrdinalIgnoreCase)
                    || action.Equals("APPROVE", StringComparison.OrdinalIgnoreCase))
                {
                    yield return "practice-dependency-resolutions:ADD";
                    yield return "practice-dependency-resolutions:EDIT";
                    yield return "evidence-configurations:ADD";
                    yield return "evidence-configurations:EDIT";
                }
            }
        }
    }
}
