using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Models;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;

namespace PracticeManagement.Web.Controllers;

public sealed class PracticeController(
    PermissionPolicy permissionPolicy,
    PracticeMenuService menuService,
    IConfiguration configuration,
    ILogger<PracticeController> logger) : Controller
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
        // Rules 3 + 4 — Source Statements needs to render actions and
        // filter releases based on the caller's role scope, not just
        // permissions. Expose the session identity to the view layer.
        ViewBag.DataScope = HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey) ?? "ORGANIZATION";
        ViewBag.RoleName = HttpContext.Session.GetString(PracticeSessionIdentity.RoleNameKey) ?? "";
        ViewBag.EmployeeId = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey) ?? "";
        ViewBag.IsSystemAdmin = IsSystemAdmin();
        if (areaKey.Equals("practice-operationalization", StringComparison.OrdinalIgnoreCase)) areaKey = "resolve";
        var screen = PracticeScreen.All.FirstOrDefault(x => x.Key.Equals(areaKey, StringComparison.OrdinalIgnoreCase));
        if (screen is null) return NotFound();
        if (!string.IsNullOrWhiteSpace(requiredGroup) && !screen.Group.Equals(requiredGroup, StringComparison.OrdinalIgnoreCase)) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), ScreenPermissionArea(screen.Key), "VIEW")) return ScreenAccessDenied(screen);
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
        ViewBag.DataScope = HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey) ?? "ORGANIZATION";
        ViewBag.RoleName = HttpContext.Session.GetString(PracticeSessionIdentity.RoleNameKey) ?? "";
        ViewBag.EmployeeId = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey) ?? "";
        ViewBag.IsSystemAdmin = IsSystemAdmin();
        var screen = PracticeScreen.All.FirstOrDefault(x => x.Key.Equals(areaKey, StringComparison.OrdinalIgnoreCase));
        if (screen is null) return NotFound();
        var allowedGroup = screen.Group.Equals(PracticeScreen.PracticeManagementGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.DependencyWorkbenchGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.AssuranceManagementGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.OversightGroup, StringComparison.OrdinalIgnoreCase)
            // Sidebar reorganisation (migration 051) — new top-level groups.
            // Keep the older groups above for direct-URL back-compat.
            || screen.Group.Equals(PracticeScreen.GovernanceGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.OrganizationGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.OperationsGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.AdministrationGroup, StringComparison.OrdinalIgnoreCase)
            // Workflow & Event-Driven Assurance Engine (BRD v1.0).
            || screen.Group.Equals(PracticeScreen.WorkflowGroup, StringComparison.OrdinalIgnoreCase)
            // Phase 2 Assurance Management (BRD Part 2) -- Organization Portal.
            // NEW, INDEPENDENT module; screens live under nav-assurance (migration 071).
            || screen.Group.Equals(PracticeScreen.AuditManagementGroup, StringComparison.OrdinalIgnoreCase);
        if (!allowedGroup) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), ScreenPermissionArea(screen.Key), "VIEW")) return ScreenAccessDenied(screen);
        if (screen.Key.Equals("assurance-calendar", StringComparison.OrdinalIgnoreCase))
            return View("Calendar", screen);
        return View("Manage", screen);
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is not null;

    private string Token() => HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey) ?? "";

    private string[] Roles() => (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);

    // Task Calendar -- Scheduler Edit Permission (change request 2026-09-23).
    // Same check PracticeManagementGatewayController.IsSystemAdmin() already
    // uses -- mirrored here rather than shared, matching how Roles() itself
    // is already a small private per-controller helper rather than a shared
    // service method in this codebase. Exposed to the Calendar view so its
    // JS can apply the same admin bypass the API tier enforces server-side.
    private bool IsSystemAdmin() => Roles().Any(role => role.Equals("PM_ADMIN", StringComparison.OrdinalIgnoreCase));

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
        return permissionPolicy.ActionsFor(Roles(), ScreenPermissionArea(areaKey));
    }

    // A screen key is normally the same string as its menu_master row.
    // A few helper pages, however, sit under an owning screen and have
    // no menu row of their own -- the permission check against their
    // literal key would refuse every role, because no role can hold a
    // grant on a menu that does not exist. This map routes those helper
    // screens onto their owning menu. Same idea as PermissionAreaMap
    // for the gateway entity types, kept separate here because that map
    // is keyed on Web -> API entity types, and this one is keyed on the
    // Web-tier's screen list.
    private static string ScreenPermissionArea(string screenKey)
    {
        if (string.IsNullOrWhiteSpace(screenKey)) return screenKey;

        if (screenKey.Equals("resolve-workspace", StringComparison.OrdinalIgnoreCase))
            return "resolve";

        // practice-instances became exactly the case this map exists for
        // when migration 288 set its menu row Inactive. Only 'Active' rows
        // pass the permission filter (see 279's header), so the screen
        // would otherwise grant nobody anything -- and it is still reached
        // deliberately, by "New Practice Instance" on an Organization
        // Requirement row, which is the screen that now governs it.
        //
        // So whoever may add or edit an organization requirement may
        // create an instance under it. That is the same rule the row
        // action applies in the UI, enforced here rather than only there.
        if (screenKey.Equals("practice-instances", StringComparison.OrdinalIgnoreCase))
            return "organization-requirements";

        // custom-source-statements has no menu_master row either (see the
        // comment on its PracticeScreen entry) -- it is reached only by a
        // link from the Standards & Frameworks screen, so it shares that
        // screen's permission area rather than getting its own row/migration.
        // Every entity type the new partial calls (custom-release,
        // custom-release-source-structure, custom-statement,
        // custom-release-statements) is already mapped to
        // "organization-controls" in PermissionAreaMap.cs, so this keeps
        // page-load VIEW access and API-call access on the same area.
        if (screenKey.Equals("custom-source-statements", StringComparison.OrdinalIgnoreCase))
            return "organization-controls";

        return screenKey;
    }

    // Strict — module identity comes from positive configuration, the
    // deployed PathBase, or an explicit moduleKey route value. Do NOT
    // widen this to Request.Path segments — a Practice Management host
    // must never flip into OrgMgmt mode because of a bad redirect.
    private bool IsOrganizationManagementModule() =>
        string.Equals(configuration["Module:Key"], "OrganizationManagement", StringComparison.OrdinalIgnoreCase)
        || Request.PathBase.Equals("/OrganizationManagement", StringComparison.OrdinalIgnoreCase)
        || string.Equals(RouteData.Values["moduleKey"]?.ToString(), "OrganizationManagement", StringComparison.OrdinalIgnoreCase);

    private string ModuleTitle() => IsOrganizationManagementModule() ? "Organization Management" : "Practice Management";

    private string ModuleRouteBase()
    {
        var pathBase = Request.PathBase.Value?.TrimEnd('/') ?? "";
        if (!string.IsNullOrWhiteSpace(pathBase)) return pathBase;
        return RouteData.Values["moduleKey"]?.ToString()?.Equals("OrganizationManagement", StringComparison.OrdinalIgnoreCase) == true
            ? "/OrganizationManagement"
            : "";
    }

    // =================================================================
    // Replaces ControllerBase.Forbid() on the two screen-render paths.
    //
    // Forbid() delegates to HttpContext.ForbidAsync(), which needs an
    // authentication scheme to hand the challenge to, and this
    // application registers none -- Program.cs has AddSession and
    // UseAuthorization but deliberately no AddAuthentication, because
    // identity lives in the session rather than in a ClaimsPrincipal.
    // So Forbid() threw "No authenticationScheme was specified, and
    // there was no DefaultForbidScheme found", and a user without the
    // screen's VIEW grant was shown the developer exception page in
    // Development, or /Home/Error in every other environment, instead of
    // being told what was missing.
    //
    // The status code stays 403; only the body changes.
    // =================================================================
    private IActionResult ScreenAccessDenied(PracticeScreen screen)
    {
        logger.LogWarning("PracticeManagement screen blocked by menu permission. Screen={ScreenKey} User={User}",
            screen.Key, HttpContext.Session.GetString(PracticeSessionIdentity.UserKey));
        Response.StatusCode = StatusCodes.Status403Forbidden;
        return View("AccessDenied", screen);
    }

    private IActionResult RedirectToLogin()
    {
        // returnUrl MUST include PathBase — Request.Path is post-strip,
        // so a raw Path+QueryString would send the browser to the wrong
        // origin after login on a hosted PathBase deployment.
        var returnUrl = Request.PathBase + Request.Path + Request.QueryString;
        var moduleBase = ModuleRouteBase();
        return string.IsNullOrWhiteSpace(moduleBase)
            ? LocalRedirect($"/Login?returnUrl={Uri.EscapeDataString(returnUrl)}")
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
