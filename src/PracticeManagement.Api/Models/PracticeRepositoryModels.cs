using System.Text.Json;

namespace PracticeManagement.Api.Models;

public sealed class PracticeRepositoryQuery
{
    public string EntityType { get; set; } = "";
    public int? Id { get; set; }
    public string Search { get; set; } = "";
    public string Status { get; set; } = "";
    public string EnteredBy { get; set; } = "";
    public JsonElement Data { get; set; } = JsonSerializer.SerializeToElement(new { });
}

public sealed class PracticeRepositoryCommand
{
    public string EntityType { get; set; } = "";
    public string Action { get; set; } = "SAVE";
    public int? Id { get; set; }
    public string EnteredBy { get; set; } = "";
    public JsonElement Data { get; set; }
}

/// <param name="Field">
/// Payload key the failure belongs to, when the failure is a field-level
/// validation THROW raised by a stored procedure (see
/// PracticeRepositoryService.ValidationFieldFor). The Web UI highlights the
/// matching input instead of showing a bare correlation reference. Null for
/// failures that are not attributable to one field.
/// </param>
public sealed record PracticeRepositoryResult(bool Success, string Message, object? Data = null, string? Field = null);

// ---------------------------------------------------------------------
// Obligation Taxonomy (Phase 2E) DTOs.  Mirror the columns returned by
// dbo.sp_pm_view_obligations_typed (see database/122_view_obligations_typed_proc.sql).
// The controller flow still returns Dictionary rows in PracticeRepositoryResult.Data
// (matching every other entity type), so these classes are optional and
// primarily document the contract for the Web UI (Phase 2F).
//
// Per-type detail is exposed as raw JSON strings ('[]' when empty) that
// the caller parses; keeping them as strings avoids a second round of
// deserialization for shapes the SP already assembled.
// ---------------------------------------------------------------------

public sealed class ObligationTypedRow
{
    public long? FrameworkReleaseId { get; set; }
    public string FrameworkRelease { get; set; } = "";
    public long ObligationId { get; set; }
    public string ObligationName { get; set; } = "";
    public long? ObligationTypeId { get; set; }
    public string TypeCode { get; set; } = "";
    public string TypeName { get; set; } = "";
    public string ExecutionFrequency { get; set; } = "";
    public string ObligationRetention { get; set; } = "";
    public string ApprovalAuthority { get; set; } = "";
    public string Responsibility { get; set; } = "";

    // Per-type detail JSON arrays.  Each is a JSON string that parses to
    // an array of typed rows; parse only the one matching TypeCode for
    // the primary card, or expose all six for a "raw" inspector view.
    public string StateRulesJson { get; set; } = "[]";
    public string ExecutionSpecsJson { get; set; } = "[]";
    public string AssuranceSpecsJson { get; set; } = "[]";
    public string EventResponsesJson { get; set; } = "[]";
    public string ConstraintRulesJson { get; set; } = "[]";
    public string RetentionSpecsJson { get; set; } = "[]";

    // Combined evidence (Direct = legacy 1:M via requirement_obligation_evidence.obligation_id,
    // Link = M:M via one of the six per-type link tables; LinkTypeCode
    // identifies which link table each Link row came from).
    public string EvidenceJson { get; set; } = "[]";
}
