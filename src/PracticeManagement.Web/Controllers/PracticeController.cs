using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Models;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;

namespace PracticeManagement.Web.Controllers;

public sealed class PracticeController(PermissionPolicy permissionPolicy, PracticeMenuService menuService, IConfiguration configuration) : Controller
{
    private static readonly HashSet<string> OrganizationManagementAreas = new(StringComparer.OrdinalIgnoreCase)
    {
        "organization-setup",
        "organization-dependencies"
    };

    public Task<IActionResult> Index(string? areaKey = null, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(areaKey) && IsOrganizationManagementModule()) return OrganizationSetupIndex(cancellationToken);
        if (string.IsNullOrWhiteSpace(areaKey)) return Dashboard(cancellationToken);
        return ShowArea(areaKey, cancellationToken: cancellationToken);
    }

    [HttpGet("OrganizationSetup")]
    [HttpGet("organization-setup")]
    public Task<IActionResult> OrganizationSetupIndex(CancellationToken cancellationToken) => OrganizationSetup("organization-setup", cancellationToken);

    [HttpGet("OrganizationSetup/{areaKey}")]
    [HttpGet("organization-setup/{areaKey}")]
    public Task<IActionResult> OrganizationSetup(string areaKey, CancellationToken cancellationToken) => ShowArea(areaKey, PracticeScreen.OrganizationOnboardingGroup, cancellationToken);

    [HttpGet("OrganizationAdministration")]
    [HttpGet("organization-administration")]
    public Task<IActionResult> OrganizationAdministrationIndex(CancellationToken cancellationToken) => OrganizationAdministration("organization-administration", cancellationToken);

    [HttpGet("OrganizationAdministration/{areaKey}")]
    [HttpGet("organization-administration/{areaKey}")]
    public Task<IActionResult> OrganizationAdministration(string areaKey, CancellationToken cancellationToken) => ShowArea(areaKey, PracticeScreen.OrganizationAdministrationGroup, cancellationToken);

    [HttpGet("OrganizationDependencies")]
    [HttpGet("organization-dependencies")]
    public Task<IActionResult> OrganizationDependenciesIndex(CancellationToken cancellationToken) => OrganizationDependencies("organization-dependencies", cancellationToken);

    [HttpGet("OrganizationDependencies/{areaKey}")]
    [HttpGet("organization-dependencies/{areaKey}")]
    public Task<IActionResult> OrganizationDependencies(string areaKey, CancellationToken cancellationToken) => ShowArea(areaKey, PracticeScreen.OrganizationDependenciesGroup, cancellationToken);

    [HttpGet("PracticeManagement/{areaKey}")]
    [HttpGet("practice-management/{areaKey}")]
    public Task<IActionResult> PracticeManagement(string areaKey, CancellationToken cancellationToken) => ShowPracticeArea(areaKey, cancellationToken);

    [HttpGet("resolve")]
    public Task<IActionResult> Resolve(CancellationToken cancellationToken) => ShowPracticeArea("resolve", cancellationToken);

    [HttpGet("practice-menu-diagnostics")]
    public async Task<IActionResult> MenuDiagnostics(CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        var roles = Roles();
        var diagnostics = await menuService.GetDiagnosticsAsync(Token(), roles, cancellationToken);
        if (IsOrganizationManagementModule())
            diagnostics = diagnostics with
            {
                VisibleRowCount = Math.Min(diagnostics.VisibleRowCount, OrganizationManagementAreas.Count),
                Rows = diagnostics.Rows.Where(row => OrganizationManagementAreas.Contains(row.MenuKey)).ToArray()
            };
        return Json(new
        {
            success = true,
            roles,
            diagnostics.ApiSucceeded,
            diagnostics.ApiMessage,
            diagnostics.ApiRowCount,
            diagnostics.KnownRowCount,
            diagnostics.VisibleRowCount,
            diagnostics.Rows
        });
    }

    private async Task<IActionResult> Dashboard(CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return RedirectToLogin();
        ViewBag.ApiBaseUrl = $"{ModuleRouteBase()}/practice-management-gateway";
        ViewBag.ModuleTitle = ModuleTitle();
        ViewBag.IsOrganizationManagementModule = IsOrganizationManagementModule();
        ViewBag.AppBasePath = ModuleRouteBase();
        ViewBag.Screens = await VisibleScreens(cancellationToken);
        ViewBag.MenuItems = await VisibleMenu(cancellationToken);
        ViewBag.Permissions = Array.Empty<string>();
        return View("Dashboard");
    }

    private async Task<IActionResult> ShowArea(string areaKey, string? requiredGroup = null, CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return RedirectToLogin();
        if (IsOrganizationManagementModule() && !OrganizationManagementAreas.Contains(areaKey)) return NotFound();
        ViewBag.ApiBaseUrl = $"{ModuleRouteBase()}/practice-management-gateway";
        ViewBag.ModuleTitle = ModuleTitle();
        ViewBag.IsOrganizationManagementModule = IsOrganizationManagementModule();
        ViewBag.AppBasePath = ModuleRouteBase();
        ViewBag.Screens = await VisibleScreens(cancellationToken);
        ViewBag.MenuItems = await VisibleMenu(cancellationToken);
        ViewBag.Permissions = ActionsFor(areaKey);
        if (areaKey.Equals("practice-operationalization", StringComparison.OrdinalIgnoreCase)) areaKey = "resolve";
        var screen = PracticeScreen.All.FirstOrDefault(x => x.Key.Equals(areaKey, StringComparison.OrdinalIgnoreCase));
        if (screen is null) return NotFound();
        if (!string.IsNullOrWhiteSpace(requiredGroup) && !screen.Group.Equals(requiredGroup, StringComparison.OrdinalIgnoreCase)) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), screen.Key, "VIEW")) return Forbid();
        if (screen.Key.Equals("assurance-calendar", StringComparison.OrdinalIgnoreCase))
            return View("Calendar", screen);
        return View("Manage", screen);
    }

    private async Task<IActionResult> ShowPracticeArea(string areaKey, CancellationToken cancellationToken)
    {
        if (IsOrganizationManagementModule()) return NotFound();
        if (!IsSignedIn()) return RedirectToLogin();
        if (areaKey.Equals("practice-operationalization", StringComparison.OrdinalIgnoreCase)) areaKey = "resolve";
        ViewBag.ApiBaseUrl = $"{ModuleRouteBase()}/practice-management-gateway";
        ViewBag.Screens = await VisibleScreens(cancellationToken);
        ViewBag.MenuItems = await VisibleMenu(cancellationToken);
        ViewBag.Permissions = ActionsFor(areaKey);
        var screen = PracticeScreen.All.FirstOrDefault(x => x.Key.Equals(areaKey, StringComparison.OrdinalIgnoreCase));
        if (screen is null) return NotFound();
        var allowedGroup = screen.Group.Equals(PracticeScreen.PracticeManagementGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.DependencyWorkbenchGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.AssuranceManagementGroup, StringComparison.OrdinalIgnoreCase);
        if (!allowedGroup) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), screen.Key, "VIEW")) return Forbid();
        if (screen.Key.Equals("assurance-calendar", StringComparison.OrdinalIgnoreCase))
            return View("Calendar", screen);
        return View("Manage", screen);
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is not null;

    private string Token() => HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey) ?? "";

    private string[] Roles() => (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);

    private async Task<PracticeScreen[]> VisibleScreens(CancellationToken cancellationToken)
    {
        var screens = await menuService.GetVisibleScreensAsync(Token(), Roles(), cancellationToken);
        return IsOrganizationManagementModule()
            ? screens.Where(screen => OrganizationManagementAreas.Contains(screen.Key)).ToArray()
            : screens;
    }

    private async Task<IReadOnlyList<PracticeMenuItem>> VisibleMenu(CancellationToken cancellationToken)
    {
        if (!IsOrganizationManagementModule()) return await menuService.GetVisibleMenuAsync(Token(), Roles(), cancellationToken);

        var screens = await VisibleScreens(cancellationToken);
        var byKey = screens.ToDictionary(screen => screen.Key, StringComparer.OrdinalIgnoreCase);
        return OrganizationManagementAreas
            .Select((key, index) => byKey.TryGetValue(key, out var screen)
                ? new PracticeMenuItem(
                    index + 1,
                    null,
                    screen.Key,
                    screen.Title,
                    OrganizationManagementMenuUrl(screen.Key),
                    screen.Icon,
                    "Organization Management",
                    index + 1,
                    screen,
                    [])
                : null)
            .Where(item => item is not null)
            .Cast<PracticeMenuItem>()
            .ToArray();
    }

    private string[] ActionsFor(string? areaKey)
    {
        if (string.IsNullOrWhiteSpace(areaKey)) return [];
        return permissionPolicy.ActionsFor(Roles(), areaKey);
    }

    private bool IsOrganizationManagementModule() =>
        configuration["Module:Key"]?.Equals("OrganizationManagement", StringComparison.OrdinalIgnoreCase) == true
        || Request.PathBase.Equals("/OrganizationManagement", StringComparison.OrdinalIgnoreCase)
        || RouteData.Values["moduleKey"]?.ToString()?.Equals("OrganizationManagement", StringComparison.OrdinalIgnoreCase) == true;

    private string ModuleTitle() => IsOrganizationManagementModule() ? "Organization Management" : "Practice Management";

    private string ModuleRouteBase()
    {
        var pathBase = Request.PathBase.Value?.TrimEnd('/') ?? "";
        if (!string.IsNullOrWhiteSpace(pathBase)) return pathBase;
        return RouteData.Values["moduleKey"]?.ToString()?.Equals("OrganizationManagement", StringComparison.OrdinalIgnoreCase) == true
            ? "/OrganizationManagement"
            : "";
    }

    private IActionResult RedirectToLogin()
    {
        var returnUrl = Request.Path + Request.QueryString;
        var moduleBase = ModuleRouteBase();
        return string.IsNullOrWhiteSpace(moduleBase)
            ? RedirectToAction("Index", "Login", new { returnUrl })
            : LocalRedirect($"{moduleBase}/Login?returnUrl={Uri.EscapeDataString(returnUrl)}");
    }

    private string OrganizationManagementMenuUrl(string areaKey)
    {
        var path = areaKey.Equals("organization-setup", StringComparison.OrdinalIgnoreCase)
            ? "OrganizationSetup"
            : "OrganizationDependencies";
        return Request.PathBase.Equals("/OrganizationManagement", StringComparison.OrdinalIgnoreCase)
            ? path
            : $"OrganizationManagement/{areaKey}";
    }
}
