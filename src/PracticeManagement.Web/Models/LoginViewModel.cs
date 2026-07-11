using System.ComponentModel.DataAnnotations;

namespace PracticeManagement.Web.Models;

public sealed class LoginViewModel
{
    [Required(ErrorMessage = "User ID / Email ID is required.")]
    public string LoginId { get; set; } = "";

    [Required(ErrorMessage = "Password is required.")]
    [DataType(DataType.Password)]
    public string Password { get; set; } = "";

    public string? ReturnUrl { get; set; }
}
