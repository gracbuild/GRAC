// =====================================================================
// RoleViewDataScopeModels  (migration 415 -- View Data Scope)
//
// Contracts for RoleViewDataScopeController: the role-level "Advanced
// Settings -> View Data Scope" of the Role Menu Permission section.
// See docs/view-data-scope.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public static class ViewDataScopes
{
    public const string All      = "ALL";       // every record (the behaviour before 415)
    public const string Location = "LOCATION";
    public const string Team     = "TEAM";
    public const string Owner    = "OWNER";     // "Assigned Owner"

    public static readonly string[] Values = [All, Location, Team, Owner];

    public static bool IsValid(string? value) =>
        value is not null && Values.Contains(value.Trim().ToUpperInvariant());
}

public sealed record RoleViewDataScope(long RoleId, long OrganizationId, string ViewDataScope);

public sealed record RoleViewDataScopeSaveRequest(long OrganizationId, string? ViewDataScope);

public sealed record RoleViewDataScopeSaveResult(bool Success, string? Error, RoleViewDataScope? Saved);
