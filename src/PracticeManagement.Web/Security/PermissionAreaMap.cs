namespace PracticeManagement.Web.Security;

// =====================================================================
// PermissionAreaMap
//
// Maps a gateway entity type onto the permission area that governs it.
//
// WHY THIS IS ITS OWN FILE, LINKED INTO BOTH TIERS
//   The mapping used to live only in
//   PracticeManagementGatewayController.PermissionArea. The API ran its
//   own check on the RAW entity type:
//
//       permissionPolicy.IsAllowed(principal.Roles, request.EntityType, action)
//
//   so the two tiers disagreed. Opening a row on Organization Controls
//   sends entityType "release-statements": the Web tier mapped it to
//   "organization-controls" and let it through on the caller's
//   organization-controls:VIEW grant, then the API asked for
//   "release-statements:VIEW" — a permission no role can hold, because
//   there is no menu_master row by that name — and answered 403:
//
//       The practice API returned HTTP 403 ... for entity [release-statements]
//
//   admin@grac.local never saw it: PM_ADMIN is "*:*" on both tiers.
//
//   Copying the mapping into the API would have left two lists to keep
//   in step. Instead this file is authored once here and LINKED into
//   PracticeManagement.Api.csproj, the same arrangement PasswordHasher
//   already uses — one source file, two assemblies, one definition of
//   which permission governs which entity type.
//
// WHAT BELONGS HERE
//   Only helper entity types with a SINGLE owning screen. An entity type
//   read by several screens has no parent to map to and belongs in
//   LoginController.SupportingReads instead (that is where
//   subscribed-frameworks, lookups, dashboard-summary and menu-master
//   are handled).
//
//   An entity type that is neither a menu_master row, nor mapped here,
//   nor in SupportingReads is unreachable for every database user and
//   will answer 403 or 500 on the screen that reads it.
// =====================================================================
public static class PermissionAreaMap
{
    // Helper entity types that are governed by the Organization Controls
    // screen: the release drill-down, its statements, and the custom
    // release authoring flow all render inside that screen.
    private static readonly HashSet<string> OrganizationControlsHelpers = new(StringComparer.OrdinalIgnoreCase)
    {
        "release-statements",
        "statement-applicability",
        "custom-release",
        "custom-release-statements",
        "custom-release-source-structure",
        "custom-statement",
        "subscription-owner"
    };

    // Single-owner helpers that map to a screen of their own.
    private static readonly Dictionary<string, string> DirectMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["evidence-obligations-typed"] = "evidence-obligations",
        // Calendar grid feed (practice-calendar.js). No menu of its own;
        // the screen it belongs to is assurance-calendar (migration 028).
        ["assurance-calendar-events"] = "assurance-calendar"
    };

    /// <summary>
    /// The permission area that governs <paramref name="entityType"/>.
    /// Returns the entity type unchanged when it is a screen in its own
    /// right, which is the common case.
    /// </summary>
    public static string For(string entityType)
    {
        if (string.IsNullOrWhiteSpace(entityType)) return entityType;
        if (DirectMap.TryGetValue(entityType, out var mapped)) return mapped;
        return OrganizationControlsHelpers.Contains(entityType) ? "organization-controls" : entityType;
    }
}
