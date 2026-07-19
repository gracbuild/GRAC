// =====================================================================
// OrganizationAccessContext
//
// Reads session identity keys (DataScope, allowed org IDs, primary org id,
// email, employee code) and derives:
//   * IsGlobalScope   — true for GRAC Admin (DataScope == "GLOBAL")
//   * AllowedOrganizationIds  — set of org IDs the user can operate on
//                               (empty for GLOBAL scope: allowed = "any")
//   * IsOrganizationAllowed(id) — server-side authorisation helper
//
// Kept as a static extension over HttpContext so every controller that
// needs the check applies the same rules (do NOT duplicate this logic
// inline — that is what enables cross-org data leaks in the future).
// =====================================================================
using Microsoft.AspNetCore.Http;

namespace PracticeManagement.Web.Security;

public static class OrganizationAccessContext
{
    public static bool IsGlobalScope(this HttpContext context)
    {
        var scope = context.Session.GetString(PracticeSessionIdentity.DataScopeKey);
        return string.Equals(scope, "GLOBAL", StringComparison.OrdinalIgnoreCase);
    }

    public static long? PrimaryOrganizationId(this HttpContext context)
    {
        var raw = context.Session.GetString(PracticeSessionIdentity.OrganizationIdKey);
        return long.TryParse(raw, out var id) && id > 0 ? id : null;
    }

    public static IReadOnlyCollection<long> AllowedOrganizationIds(this HttpContext context)
    {
        var raw = context.Session.GetString(PracticeSessionIdentity.AllowedOrganizationIdsKey);
        if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<long>();
        var ids = new HashSet<long>();
        foreach (var token in raw.Split(',', StringSplitOptions.RemoveEmptyEntries))
            if (long.TryParse(token.Trim(), out var v) && v > 0) ids.Add(v);
        return ids;
    }

    /// <summary>
    /// True if the caller is authorised to operate on the given organization.
    /// GLOBAL scope (GRAC Admin) → true for any active org id (existence
    /// check is enforced by the DB; we don't need to gate here).
    /// Everyone else → orgId must be in AllowedOrganizationIds.
    /// </summary>
    public static bool IsOrganizationAllowed(this HttpContext context, long organizationId)
    {
        if (organizationId <= 0) return false;
        if (context.IsGlobalScope()) return true;
        return context.AllowedOrganizationIds().Contains(organizationId);
    }

    public static string? Email(this HttpContext context) =>
        context.Session.GetString(PracticeSessionIdentity.UserKey);

    // The Web tier does not currently store employee_code in session as a
    // distinct key — UserKey is populated with email (preferred) or
    // employee_code by PracticeLoginService. Expose it as an alias so
    // OrganizationAccessService can match either.
    public static string? EmployeeCode(this HttpContext context) =>
        context.Session.GetString(PracticeSessionIdentity.UserKey);
}
