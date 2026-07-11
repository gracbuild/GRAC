using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ControlManagement.Security;

namespace PracticeManagement.Web.Security;

public sealed class NavigationContextProtector(EnvelopeCrypto crypto)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public string Protect(string token, NavigationContext context)
    {
        context.TimestampUtc = DateTimeOffset.UtcNow;
        context.Nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
        var envelope = crypto.EncryptRequest(JsonSerializer.Serialize(context, JsonOptions), token);
        return Base64UrlEncode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope, JsonOptions)));
    }

    public NavigationContext Unprotect(string token, string code)
    {
        EncryptedRequest? envelope;
        try
        {
            var json = Encoding.UTF8.GetString(Base64UrlDecode(code));
            envelope = JsonSerializer.Deserialize<EncryptedRequest>(json, JsonOptions);
        }
        catch (Exception ex) when (ex is FormatException or JsonException or ArgumentException)
        {
            throw new CryptographicException("Invalid navigation context.", ex);
        }

        if (envelope is null || string.IsNullOrWhiteSpace(envelope.RequestStr))
            throw new CryptographicException("Invalid navigation context.");

        var context = JsonSerializer.Deserialize<NavigationContext>(crypto.DecryptRequest(envelope, token), JsonOptions);
        if (context is null || Math.Abs((DateTimeOffset.UtcNow - context.TimestampUtc).TotalMinutes) > 30)
            throw new CryptographicException("Navigation context has expired.");

        return context;
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Base64UrlDecode(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        base64 = base64.PadRight(base64.Length + (4 - base64.Length % 4) % 4, '=');
        return Convert.FromBase64String(base64);
    }
}

public sealed class NavigationContext
{
    public string SourceArea { get; set; } = "";
    public string TargetArea { get; set; } = "";
    public string FilterType { get; set; } = "";
    public int FilterId { get; set; }
    public int? OrganizationId { get; set; }
    public int? ReleaseId { get; set; }
    public int? OrganizationControlId { get; set; }
    public int? OrganizationRequirementId { get; set; }
    public string DisplayStatus { get; set; } = "";
    public string DisplayCode { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public DateTimeOffset TimestampUtc { get; set; }
    public string Nonce { get; set; } = "";
}
