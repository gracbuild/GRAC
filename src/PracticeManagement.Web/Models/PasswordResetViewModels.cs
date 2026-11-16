using System.ComponentModel.DataAnnotations;

namespace PracticeManagement.Web.Models;

/// <summary>
/// Forgot password (migration 529, 2026-11-10): the "send me a reset link"
/// form. <see cref="Sent"/> switches the view to its one confirmation
/// message, shown whether or not an account matched, so the page cannot be
/// used to find out which accounts exist.
/// </summary>
public sealed class ForgotPasswordViewModel
{
    [Required(ErrorMessage = "User ID / Email ID is required.")]
    public string LoginId { get; set; } = "";

    public bool Sent { get; set; }
}

/// <summary>
/// Forgot password (migration 529): the page the emailed link opens. The
/// token is the link's only credential; it is checked again on submit.
/// </summary>
public sealed class ResetPasswordViewModel
{
    public string Token { get; set; } = "";

    /// <summary>Email of the account the link belongs to (display only).</summary>
    public string Account { get; set; } = "";

    /// <summary>The link is unknown, used, superseded or expired.</summary>
    public bool LinkInvalid { get; set; }

    [Required(ErrorMessage = "New password is required.")]
    [DataType(DataType.Password)]
    public string NewPassword { get; set; } = "";

    [Required(ErrorMessage = "Please confirm the new password.")]
    [DataType(DataType.Password)]
    [Compare(nameof(NewPassword), ErrorMessage = "The new password and confirmation do not match.")]
    public string ConfirmPassword { get; set; } = "";
}
