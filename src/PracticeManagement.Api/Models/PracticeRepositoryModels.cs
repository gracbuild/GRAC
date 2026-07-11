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

public sealed record PracticeRepositoryResult(bool Success, string Message, object? Data = null);
