using System.ComponentModel.DataAnnotations;

namespace PracticeManagement.Web.Models;

/// <summary>
/// Backs the forced first-login password change. A user provisioned with the
/// configured default password (see migration 208) reaches this screen instead
/// of a session — LoginController issues no session until the change succeeds.
/// </summary>
public sealed class ChangePasswordViewModel
{
    [Required(ErrorMessage = "User ID / Email ID is required.")]
    public string LoginId { get; set; } = "";

    [Required(ErrorMessage = "Current password is required.")]
    [DataType(DataType.Password)]
    public string CurrentPassword { get; set; } = "";

    [Required(ErrorMessage = "New password is required.")]
    [DataType(DataType.Password)]
    public string NewPassword { get; set; } = "";

    [Required(ErrorMessage = "Please confirm the new password.")]
    [DataType(DataType.Password)]
    [Compare(nameof(NewPassword), ErrorMessage = "The new password and confirmation do not match.")]
    public string ConfirmPassword { get; set; } = "";

    public string? ReturnUrl { get; set; }

    /// <summary>
    /// Set when the user arrived here because their account still holds the
    /// shared default password, so the view can say why rather than looking
    /// like an unprompted demand.
    /// </summary>
    public bool IsForced { get; set; }
}
