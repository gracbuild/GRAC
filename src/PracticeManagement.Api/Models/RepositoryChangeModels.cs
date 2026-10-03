// =====================================================================
// RepositoryChangeModels  (statement subscription copy model, phase 3)
//
// Contracts for RepositoryChangeController. Own file per charter section 5.
// Backing migration: 395. See docs/statement-subscription-copy-model-design.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Approve or reject one pending repository change.
/// Remark is required for Reject.</summary>
public sealed record RepositoryChangeDecisionRequest(string? Decision, string? Remark);

/// <summary>The same decision for several changes. Applied one by one in
/// repository order (structure before statements before links), each in
/// its own transaction, so one refusal does not undo the others.</summary>
public sealed record RepositoryChangeBulkDecisionRequest(long[]? ChangeIds, string? Decision, string? Remark);

public sealed record RepositoryChangeDecisionResult(long ChangeId, bool Success, string Message);

public sealed record RepositoryChangeDetectResult(Guid? DetectionRunId, int RaisedCount, int NotifiedCount);
