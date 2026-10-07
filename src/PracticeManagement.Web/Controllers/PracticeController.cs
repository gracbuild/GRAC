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
        // Home "My work" (change request 2026-09-27). Identity comes from
        // the session, exactly as on every other screen; the browser never
        // names the employee it asks about. Each section is offered only
        // when the caller already holds the grant that opens its detailed
        // page, via the same permissionPolicy + ScreenPermissionArea check
        // ShowArea uses -- so Home never shows what the full page would
        // refuse. Approvals needs APPROVE on Risk Centre (the grant that
        // decides a risk analysis), not merely VIEW.
        ViewBag.EmployeeId  = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey) ?? "";
        ViewBag.DisplayName = HttpContext.Session.GetString(PracticeSessionIdentity.DisplayNameKey)
                              ?? HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) ?? "";
        var roles = Roles();
        bool CanView(string screenKey) => permissionPolicy.IsAllowed(roles, ScreenPermissionArea(screenKey), "VIEW");
        // Tasks and practice instances are "assigned to / owned by ME" --
        // a sign-in with no employee record (the bootstrap admin) has no
        // such work, so those two areas are left off Home rather than
        // shown as permanently unavailable.
        var hasEmployee = long.TryParse((string?)ViewBag.EmployeeId, out var sessionEmployeeId) && sessionEmployeeId > 0;
        ViewBag.HomeAccess = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            ["notifications"]    = CanView("my-notifications"),
            ["tasks"]            = hasEmployee && CanView("tasks"),
            ["practices"]        = hasEmployee && CanView("resolve"),
            ["approvals"]        = permissionPolicy.IsAllowed(roles, ScreenPermissionArea("risk-centre-candidates"), "APPROVE"),   // same "risk-centre" area; the queue lives on Candidates
            ["acknowledgements"] = CanView("my-acknowledgements"),
            // Migration 395: repository updates waiting for this person's
            // approval (release owner / organization admin) -- an attention
            // item only, no My work line. The notices are addressed to an
            // employee, so a sign-in without one has none.
            ["repositoryUpdates"] = hasEmployee && CanView("organization-controls")
        };
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
        if (!CanViewScreen(screen.Key)) return ScreenAccessDenied(screen);
        // Management dashboards (413/414): the sections this caller may see.
        if (ManagementDashboards.IsDashboard(screen.Key))
            ViewBag.DashboardSections = ManagementDashboards.AllowedSections(screen.Key, CanViewScreen);
        screen = WithSidebarLabel(screen);
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
            || screen.Group.Equals(PracticeScreen.AuditManagementGroup, StringComparison.OrdinalIgnoreCase)
            // Migration 384 -- Policies & Documents root and the My Notification parent.
            || screen.Group.Equals(PracticeScreen.PoliciesDocumentsGroup, StringComparison.OrdinalIgnoreCase)
            || screen.Group.Equals(PracticeScreen.MyNotificationGroup, StringComparison.OrdinalIgnoreCase);
        if (!allowedGroup) return NotFound();
        if (!CanViewScreen(screen.Key)) return ScreenAccessDenied(screen);
        // Management dashboards (413/414): the sections this caller may see.
        if (ManagementDashboards.IsDashboard(screen.Key))
            ViewBag.DashboardSections = ManagementDashboards.AllowedSections(screen.Key, CanViewScreen);
        screen = WithSidebarLabel(screen);
        if (screen.Key.Equals("assurance-calendar", StringComparison.OrdinalIgnoreCase))
            return View("Calendar", screen);
        return View("Manage", screen);
    }

    // The page heading and eyebrow follow the sidebar label (change request
    // 2026-09-28): ViewBag.Screens already carries each screen with its
    // menu_master name / module overlaid (PracticeMenuService), while
    // PracticeScreen.All holds the static defaults -- e.g. the menu reads
    // "Organization Practices" but the page said "Practices". Applied after
    // the group and permission checks above, which keep using the static
    // definition.
    private PracticeScreen WithSidebarLabel(PracticeScreen screen)
    {
        var visible = (ViewBag.Screens as PracticeScreen[] ?? [])
            .FirstOrDefault(x => x.Key.Equals(screen.Key, StringComparison.OrdinalIgnoreCase));
        return visible is null ? screen : screen with { Title = visible.Title, Group = visible.Group };
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

    // VIEW on a screen. A module dashboard (414) is its "Dashboard"
    // submenu since 416: it needs VIEW on its own menu row AND on at least
    // one child screen it summarises (ManagementDashboards.CanOpen) -- the
    // same rule the Web proxy applies to its data
    // (ManagementDashboardController).
    private bool CanViewScreen(string screenKey)
    {
        if (ManagementDashboards.IsDashboard(screenKey))
            return ManagementDashboards.CanOpen(screenKey,
                key => permissionPolicy.IsAllowed(Roles(), key, "VIEW"), CanViewScreen);
        return permissionPolicy.IsAllowed(Roles(), ScreenPermissionArea(screenKey), "VIEW");
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
    // internal: the management dashboard Web proxy applies the same mapping.
    internal static string ScreenPermissionArea(string screenKey)
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

        // Practice View has no menu_master row at all, so "practice-view:VIEW"
        // could never be granted and the page refused everyone but PM_ADMIN.
        // It is opened only by "View" on the Organization Practices grid, so
        // it follows that screen -- same rule as practice-instances above,
        // and the same mapping PermissionAreaMap gives the gateway's
        // navigation-code / navigation-context checks.
        if (screenKey.Equals("practice-view", StringComparison.OrdinalIgnoreCase))
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

        // repository-updates (migration 395) is opened from the same screen's
        // release row, so it shares that screen's permission area too. Who
        // may APPROVE is decided by sp_repository_change_apply (release
        // owner or organization admin), not by this VIEW grant.
        if (screenKey.Equals("repository-updates", StringComparison.OrdinalIgnoreCase))
            return "organization-controls";

        // Risk Management submenus (migration 383) are standalone pages that
        // reuse the risk-centre partial, so they share risk-centre's VIEW
        // permission rather than each carrying its own -- same pattern as
        // practice-instances / custom-source-statements above. Their own
        // menu rows still exist for the sidebar; enforcement rides on the
        // existing 'risk-centre' grant every user with Risk access already has.
        if (screenKey.StartsWith("risk-centre-", StringComparison.OrdinalIgnoreCase))
            return "risk-centre";

        // Issues & Actions "route" screens (2026-10-03). None has a
        // menu_master row -- each is always about one record and is opened
        // from its centre's grid/menu or another view -- so
        // pm_grant_organization_default_access (217), which grants an
        // organisation's Admin every ACTIVE menu row, had nothing to grant
        // and every role but PM_ADMIN got "No permission" (e.g. a new
        // organisation's Admin opening Gap Details). Each follows the
        // centre it belongs to, same rule as practice-view above:
        //   gap-detail, gap-view            -> gaps (Gap Register)
        //   task-view                       -> tasks (Task Board)
        //   exception-analysis, -view       -> exception-centre
        if (screenKey.Equals("gap-detail", StringComparison.OrdinalIgnoreCase)
            || screenKey.Equals("gap-view", StringComparison.OrdinalIgnoreCase))
            return "gaps";
        if (screenKey.Equals("task-view", StringComparison.OrdinalIgnoreCase))
            return "tasks";
        if (screenKey.Equals("exception-analysis", StringComparison.OrdinalIgnoreCase)
            || screenKey.Equals("exception-view", StringComparison.OrdinalIgnoreCase))
            return "exception-centre";

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
