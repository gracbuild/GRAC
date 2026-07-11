namespace PracticeManagement.Web.Models;

public sealed record PracticeMenuItem(
    long Id,
    long? ParentMenuId,
    string MenuKey,
    string MenuName,
    string? MenuUrl,
    string? IconClass,
    string? ModuleType,
    int DisplayOrder,
    PracticeScreen? Screen,
    IReadOnlyList<PracticeMenuItem> Children);
