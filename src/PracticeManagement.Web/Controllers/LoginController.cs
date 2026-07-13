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
            HttpContext.Session.Clear();
            var permissionRoles = ExpandPermissionAliases(dbLogin.Permissions.Count > 0 ? dbLogin.Permissions : ["practice-management:VIEW"])
                .Append("menu-master:VIEW")
                .Append("lookups:VIEW")
                .Append("dashboard-summary:VIEW")
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            HttpContext.Session.SetString(PracticeSessionIdentity.UserKey, dbLogin.Email.Length > 0 ? dbLogin.Email : dbLogin.EmployeeCode);
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
            HttpContext.Session.SetString(PracticeSessionIdentity.TokenKey, tokenService.Issue(dbLogin.Email.Length > 0 ? dbLogin.Email : dbLogin.EmployeeCode, permissionRoles));
            logger.LogInformation("PracticeManagement employee sign-in succeeded for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);

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
            .Append("menu-master:VIEW")
            .Append("lookups:VIEW")
            .Append("dashboard-summary:VIEW")
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        HttpContext.Session.Clear();
        HttpContext.Session.SetString(PracticeSessionIdentity.UserKey, model.LoginId);
        HttpContext.Session.SetString(PracticeSessionIdentity.RolesKey, string.Join(',', roles));
        HttpContext.Session.SetString(PracticeSessionIdentity.TokenKey, tokenService.Issue(model.LoginId, roles));
        logger.LogInformation("PracticeManagement sign-in succeeded for {User} from {RemoteAddress}", model.LoginId, HttpContext.Connection.RemoteIpAddress);

        if (Url.IsLocalUrl(model.ReturnUrl)) return LocalRedirect(model.ReturnUrl!);
        return DefaultRedirect();
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
