using System.Text.Json;
using ControlManagement.Security;
using PracticeManagement.Web.Models;

namespace PracticeManagement.Web.Services;

public sealed class PracticeMenuService(SecurePracticeClient client, ILogger<PracticeMenuService> logger)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task<PracticeScreen[]> GetVisibleScreensAsync(string token, IEnumerable<string> roles, CancellationToken cancellationToken)
    {
        var result = await GetMenuResultAsync(token, roles, cancellationToken);
        return result.VisibleScreens;
    }

    public async Task<IReadOnlyList<PracticeMenuItem>> GetVisibleMenuAsync(string token, IEnumerable<string> roles, CancellationToken cancellationToken)
    {
        var result = await GetMenuResultAsync(token, roles, cancellationToken);
        return result.MenuItems;
    }

    public async Task<PracticeMenuDiagnostics> GetDiagnosticsAsync(string token, IEnumerable<string> roles, CancellationToken cancellationToken)
    {
        var result = await GetMenuResultAsync(token, roles, cancellationToken);
        return new PracticeMenuDiagnostics(
            result.ApiSucceeded,
            result.ApiMessage,
            result.ApiRowCount,
            result.KnownRowCount,
            result.VisibleScreens.Length,
            result.MenuRows.Select(row => new PracticeMenuDiagnosticRow(row.MenuKey, row.MenuName, row.ModuleType, row.DisplayOrder, result.KnownKeys.Contains(row.MenuKey), result.AllowedKeys.Contains(row.MenuKey))).ToArray());
    }

    private async Task<PracticeMenuResult> GetMenuResultAsync(string token, IEnumerable<string> roles, CancellationToken cancellationToken)
    {
        var roleArray = roles.ToArray();
        try
        {
            var response = await client.QueryAsync(token, new SecureRepositoryRequest
            {
                EntityType = "menu-master",
                Data = JsonSerializer.SerializeToElement(new { pageNumber = 1, pageSize = 500 })
            }, cancellationToken);

            var parsed = ReadMenuRows(response);
            var byKey = PracticeScreen.All.ToDictionary(screen => screen.Key, StringComparer.OrdinalIgnoreCase);
            var knownKeys = parsed.Rows.Where(row => byKey.ContainsKey(row.MenuKey)).Select(row => row.MenuKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var allowedKeys = parsed.Rows.Select(row => row.MenuKey).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var visibleScreens = parsed.Rows
                .Where(row => knownKeys.Contains(row.MenuKey))
                .OrderBy(row => row.DisplayOrder)
                .ThenBy(row => row.MenuName)
                .Select(row =>
                {
                    var existing = byKey[row.MenuKey];
                    return existing with
                    {
                        Title = string.IsNullOrWhiteSpace(row.MenuName) ? existing.Title : row.MenuName,
                        Icon = string.IsNullOrWhiteSpace(row.IconClass) ? existing.Icon : row.IconClass,
                        Group = string.IsNullOrWhiteSpace(row.ModuleType) ? existing.Group : row.ModuleType
                    };
                })
                .ToArray();
            var menuItems = BuildMenuItems(parsed.Rows, byKey);
            logger.LogInformation("PracticeManagement menu API returned {ApiRowCount} active rows; {KnownRowCount} matched web screens; {VisibleRowCount} screens will render. Permission filtering is disabled for base menu loading.",
                parsed.Rows.Count, knownKeys.Count, visibleScreens.Length);
            return new PracticeMenuResult(parsed.Success, parsed.Message, parsed.Rows, knownKeys, allowedKeys, visibleScreens, menuItems);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Could not load Practice Management menus from the Practice API menu-master endpoint.");
            return new PracticeMenuResult(false, ex.Message, [], new HashSet<string>(StringComparer.OrdinalIgnoreCase), new HashSet<string>(StringComparer.OrdinalIgnoreCase), [], []);
        }
    }

    private static IReadOnlyList<PracticeMenuItem> BuildMenuItems(List<MenuRow> rows, Dictionary<string, PracticeScreen> screens)
    {
        if (!rows.Any(row => row.ParentMenuId.HasValue))
            return BuildModuleGroups(rows, screens);

        var childrenByParent = rows
            .OrderBy(row => row.DisplayOrder)
            .ThenBy(row => row.MenuName)
            .GroupBy(row => row.ParentMenuId ?? 0)
            .ToDictionary(group => group.Key, group => group.ToList());

        var tree = BuildChildren(null);
        return tree.Any(item => item.Children.Count > 0) ? tree : BuildModuleGroups(rows, screens);

        IReadOnlyList<PracticeMenuItem> BuildChildren(long? parentId)
        {
            if (!childrenByParent.TryGetValue(parentId ?? 0, out var children)) return [];
            return children.Select(row =>
            {
                screens.TryGetValue(row.MenuKey, out var screen);
                return new PracticeMenuItem(
                    row.Id,
                    row.ParentMenuId,
                    row.MenuKey,
                    string.IsNullOrWhiteSpace(row.MenuName) ? screen?.Title ?? row.MenuKey : row.MenuName,
                    row.MenuUrl,
                    row.IconClass,
                    row.ModuleType,
                    row.DisplayOrder,
                    screen,
                    BuildChildren(row.Id));
            }).ToArray();
        }
    }

    private static IReadOnlyList<PracticeMenuItem> BuildModuleGroups(List<MenuRow> rows, Dictionary<string, PracticeScreen> screens)
    {
        var orderedRows = rows
            .OrderBy(row => row.DisplayOrder)
            .ThenBy(row => row.MenuName)
            .ToArray();
        var topLevel = new List<PracticeMenuItem>();
        var syntheticId = -1L;

        foreach (var group in orderedRows.GroupBy(row => NormalizeGroup(row, screens)))
        {
            var groupRows = group.ToArray();
            if (IsDashboardGroup(group.Key))
            {
                topLevel.AddRange(groupRows.Select(row => ToMenuItem(row, screens, [])));
                continue;
            }

            var children = groupRows.Select(row => ToMenuItem(row, screens, [])).ToArray();
            topLevel.Add(new PracticeMenuItem(
                syntheticId--,
                null,
                $"group-{Slug(group.Key)}",
                group.Key,
                null,
                IconForGroup(group.Key),
                group.Key,
                groupRows.Min(row => row.DisplayOrder),
                null,
                children));
        }

        return topLevel.OrderBy(item => item.DisplayOrder).ThenBy(item => item.MenuName).ToArray();
    }

    private static PracticeMenuItem ToMenuItem(MenuRow row, Dictionary<string, PracticeScreen> screens, IReadOnlyList<PracticeMenuItem> children)
    {
        screens.TryGetValue(row.MenuKey, out var screen);
        return new PracticeMenuItem(
            row.Id,
            row.ParentMenuId,
            row.MenuKey,
            string.IsNullOrWhiteSpace(row.MenuName) ? screen?.Title ?? row.MenuKey : row.MenuName,
            row.MenuUrl,
            row.IconClass,
            row.ModuleType,
            row.DisplayOrder,
            screen,
            children);
    }

    private static string NormalizeGroup(MenuRow row, Dictionary<string, PracticeScreen> screens)
    {
        if (!string.IsNullOrWhiteSpace(row.ModuleType)) return row.ModuleType.Trim();
        return screens.TryGetValue(row.MenuKey, out var screen) ? screen.Group : "Practice Management";
    }

    private static bool IsDashboardGroup(string group) =>
        group.Equals(PracticeScreen.DashboardGroup, StringComparison.OrdinalIgnoreCase)
        || group.Equals("Dashboard", StringComparison.OrdinalIgnoreCase);

    private static string IconForGroup(string group)
    {
        if (group.Equals(PracticeScreen.OrganizationOnboardingGroup, StringComparison.OrdinalIgnoreCase)) return "building";
        if (group.Equals(PracticeScreen.OrganizationAdministrationGroup, StringComparison.OrdinalIgnoreCase)) return "sitemap";
        if (group.Equals(PracticeScreen.OrganizationDependenciesGroup, StringComparison.OrdinalIgnoreCase)) return "diagram-project";
        if (group.Equals(PracticeScreen.OrganizationAccessAdministrationGroup, StringComparison.OrdinalIgnoreCase)) return "user-lock";
        if (group.Equals(PracticeScreen.DependencyWorkbenchGroup, StringComparison.OrdinalIgnoreCase)) return "network-wired";
        if (group.Equals(PracticeScreen.AssuranceManagementGroup, StringComparison.OrdinalIgnoreCase)) return "user-shield";
        if (group.Equals(PracticeScreen.OversightGroup, StringComparison.OrdinalIgnoreCase)) return "binoculars";
        // Migration 051 — new top-level groups.
        if (group.Equals(PracticeScreen.GovernanceGroup, StringComparison.OrdinalIgnoreCase)) return "landmark";
        if (group.Equals(PracticeScreen.OrganizationGroup, StringComparison.OrdinalIgnoreCase)) return "building";
        if (group.Equals(PracticeScreen.OperationsGroup, StringComparison.OrdinalIgnoreCase)) return "gears";
        if (group.Equals(PracticeScreen.AdministrationGroup, StringComparison.OrdinalIgnoreCase)) return "user-shield";
        return "clipboard-check";
    }

    private static string Slug(string value) =>
        string.Concat(value.ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) ? ch : '-')).Trim('-');

    private static ParsedMenuRows ReadMenuRows(string response)
    {
        using var document = JsonDocument.Parse(response);
        var success = !document.RootElement.TryGetProperty("Success", out var successElement) ||
            successElement.ValueKind != JsonValueKind.False;
        var message = document.RootElement.TryGetProperty("Message", out var messageElement)
            ? messageElement.GetString() ?? ""
            : "";
        if (!document.RootElement.TryGetProperty("Data", out var data) &&
            !document.RootElement.TryGetProperty("data", out data))
            return new ParsedMenuRows(success, message, []);

        var rows = data.ValueKind == JsonValueKind.Array && data.GetArrayLength() > 0 && data[0].ValueKind == JsonValueKind.Array
            ? data[0]
            : data;

        var menuRows = rows.ValueKind == JsonValueKind.Array
            ? rows.Deserialize<List<MenuRow>>(JsonOptions) ?? []
            : [];
        return new ParsedMenuRows(success, message, menuRows);
    }

    private sealed record MenuRow(
        long Id,
        string MenuKey,
        string MenuName,
        string? MenuUrl,
        long? ParentMenuId,
        string? IconClass,
        string? ModuleType,
        int DisplayOrder);

    private sealed record ParsedMenuRows(bool Success, string Message, List<MenuRow> Rows);

    private sealed record PracticeMenuResult(
        bool ApiSucceeded,
        string ApiMessage,
        List<MenuRow> MenuRows,
        HashSet<string> KnownKeys,
        HashSet<string> AllowedKeys,
        PracticeScreen[] VisibleScreens,
        IReadOnlyList<PracticeMenuItem> MenuItems)
    {
        public int ApiRowCount => MenuRows.Count;
        public int KnownRowCount => KnownKeys.Count;
    }
}

public sealed record PracticeMenuDiagnostics(
    bool ApiSucceeded,
    string ApiMessage,
    int ApiRowCount,
    int KnownRowCount,
    int VisibleRowCount,
    PracticeMenuDiagnosticRow[] Rows);

public sealed record PracticeMenuDiagnosticRow(
    string MenuKey,
    string MenuName,
    string? ModuleType,
    int DisplayOrder,
    bool KnownToWeb,
    bool AllowedByRole);
