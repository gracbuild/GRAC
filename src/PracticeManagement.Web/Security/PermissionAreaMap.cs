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
        // Bulk applies the same rules to several statements at once, so it is
        // governed by the same screen and the same permission as marking one.
        // Mapping it anywhere else would let a role that cannot mark a single
        // statement mark fifty.
        "statement-applicability-bulk",
        "custom-release",
        "custom-release-statements",
        "custom-release-source-structure",
        "custom-statement",
        // Statement Classification management for Custom Release authoring
        // (change request 2026-09-22, part 2) -- same screen, same gate as
        // custom-release-source-structure above.
        "custom-statement-classification",
        "subscription-owner"
    };

    // Single-owner helpers that map to a screen of their own.
    private static readonly Dictionary<string, string> DirectMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["evidence-obligations-typed"] = "evidence-obligations",
        // Calendar grid feed (practice-calendar.js). No menu of its own;
        // the screen it belongs to is assurance-calendar (migration 028).
        ["assurance-calendar-events"] = "assurance-calendar",
        // Move/Skip an occurrence (the Calendar's "Edit Schedule" dialog,
        // now also reachable from the Schedule List's 3-dot menu -- change
        // request 2026-09) and the schedule-rule row it moves/skips
        // against. Neither has ever had a menu_master row of its own --
        // both are governed by the screen that renders their only editor,
        // assurance-calendar. Left unmapped, PermissionAreaMap.For()
        // returns each raw entity type unchanged and IsAllowed(...) is
        // asked for a permission area no role can hold, so the save 403s
        // for every real role -- exactly the release-statements bug this
        // file's header describes, silent for admin@grac.local's "*:*"
        // wildcard and only surfacing for an actual Editor. Caught while
        // wiring the List's Edit action, which is what made a non-admin
        // role's save path matter for the first time.
        ["assurance-schedule-rules"] = "assurance-calendar",
        ["assurance-schedule-overrides"] = "assurance-calendar",
        // Practice instances lost their own menu row to migration 288, and
        // only Active rows pass the permission filter -- so the entity
        // would be refused for everybody. Instances are now created from
        // "New Practice Instance" on an Organization Requirement row, so
        // that screen governs them.
        //
        // This has to match ScreenPermissionArea in PracticeController:
        // that one permissions the FORM, this one permissions the SAVE.
        // Mapping only one of them renders a form that 403s on submit.
        ["practice-instances"] = "organization-requirements",
        // Bulk practice applicability is the Organization Practices screen's
        // own action, governed by that screen's permission -- same rule as
        // statement-applicability-bulk above.
        ["requirement-applicability-bulk"] = "organization-requirements",
        // Source Statement mapping picker on the Add/Edit Practice form
        // (change request 2026-09): read-only helper for that same screen,
        // same rule as practice-instances above -- mapping only this one
        // and not the screen itself would be pointless, but leaving this
        // one unmapped 403s the picker's pre-population query while the
        // rest of the form works fine.
        ["practice-statement-mappings"] = "organization-requirements",
        // Migration 345: the user-ownership entity (list + reassign) is read
        // and written only by the Ownership Management screen, so that screen
        // governs it on both tiers -- VIEW to list, EDIT/ADD to reassign.
        ["user-ownership"] = "ownership-management",
        // Migration 370: Committee Designation Master's "Add Designation"
        // quick-create, reached from the Committee Member row on the
        // Add/Edit Committee form. No menu_master row of its own -- it is
        // a per-form auxiliary write, governed by the same permission as
        // the Committee form itself (committees:ADD / committees:EDIT),
        // same reasoning as practice-instances/user-ownership above.
        // Reading designations (committee-designations:VIEW) is instead
        // granted to every role via LoginController.SupportingReads, same
        // as team-department-employees/team-members -- see that list's
        // own comment for why.
        ["committee-designations"] = "committees"
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
