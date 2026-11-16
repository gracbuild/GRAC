// =====================================================================
// SubscriptionRequestModels  (migration 511)
//
// Contracts for SubscriptionRequestController: Organization Management ->
// Subscription Requests, the platform-side approval of the requests an
// organization raises from Add Release -> Subscribe from Repository (406).
// Own file per charter section 5.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Approve or reject one Pending subscription request. Remark is
/// optional for Approve and required for Reject (51412). Actor is the
/// sign-in that decided -- set by the Web tier from the session, never by
/// the browser.</summary>
public sealed record SubscriptionRequestDecisionRequest(string? Decision, string? Remark, string? Actor);

public sealed record SubscriptionRequestDecisionResult(long RequestId, bool Success, string Message, long? SubscriptionId);
