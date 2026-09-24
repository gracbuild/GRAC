namespace PracticeManagement.Web.Models;

/// <summary>
/// One step in an Audit Management flow (migration 276).
/// </summary>
/// <param name="Key">Slug used for the tab id, the <c>?step=</c> query value
/// and the panel's data attribute. Stable — it appears in URLs.</param>
/// <param name="Title">Tab label.</param>
/// <param name="Caption">One-line description shown under the tab strip.</param>
/// <param name="PartialName">The EXISTING screen partial rendered inside the
/// panel, e.g. <c>Partials/org-assurance-scope-builder</c>. Nothing about that
/// partial changes: the shell hosts it as-is so there is exactly one
/// implementation of every screen.</param>
/// <param name="HeaderPartial">Optional partial rendered INSIDE the panel,
/// above the hosted screen. Used by the Question Sets step to add the
/// audit-scoped adoption panel (migration 277) without editing the
/// org-assurance-question-sets partial, which stays the organization-level
/// library it has always been.</param>
public sealed record AuditFlowStep(
    string Key,
    string Title,
    string Caption,
    string PartialName,
    string? HeaderPartial = null);

/// <summary>
/// View model for <c>Partials/_audit-flow-shell.cshtml</c> — the tab / stepper
/// chrome shared by Audit Definition and Audit Configuration.
/// </summary>
/// <param name="Screen">The container screen, used for the page heading. It is
/// also handed to each hosted partial, which is safe because those partials
/// reference <c>@Model</c> only in the heading they render (and the shell hides
/// those nested headings via CSS).</param>
/// <param name="ShellId">DOM id for the shell root; must be unique per page.</param>
/// <param name="Steps">Ordered steps. Order is the flow order shown to the user.</param>
public sealed record AuditFlowShell(PracticeScreen Screen, string ShellId, AuditFlowStep[] Steps);
