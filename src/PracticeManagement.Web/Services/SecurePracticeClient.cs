using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using ControlManagement.Security;

namespace PracticeManagement.Web.Services;

public sealed class SecurePracticeClient(HttpClient httpClient, IConfiguration configuration, EnvelopeCrypto crypto, ILogger<SecurePracticeClient> logger)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private const string PracticeApiRoute = "api/practice-management";

    public Task<string> QueryAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        SendAsync("secure/query", token, request, cancellationToken);

    public Task<string> ManageAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        SendAsync("secure/manage", token, request, cancellationToken);

    // Pre-session sign-in. Called with a short-lived PM_LOGIN bootstrap token
    // rather than a user session token — the session does not exist yet. Same
    // envelope + freshness + nonce machinery as every other call.
    public Task<string> AuthenticateAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        SendAsync("secure/authenticate", token, request, cancellationToken);

    public Task<string> SetPasswordAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        SendAsync("secure/set-password", token, request, cancellationToken);

    // Password-free identity lookup, same bootstrap-token transport as
    // sign-in. Used only by the ReviewLogin path, to give a configuration-
    // verified admin the employee id every actor stamp needs.
    public Task<string> ResolveIdentityAsync(string token, SecureRepositoryRequest request, CancellationToken cancellationToken) =>
        SendAsync("secure/resolve-identity", token, request, cancellationToken);

    private async Task<string> SendAsync(string path, string token, SecureRepositoryRequest request, CancellationToken cancellationToken)
    {
        request.TimestampUtc = DateTimeOffset.UtcNow;
        request.Nonce = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
        var envelope = crypto.EncryptRequest(JsonSerializer.Serialize(request), token);
        var url = $"{ApiEndpointBaseUrl()}/{path}";
        logger.LogInformation("PracticeManagement API URL called {Url} for {EntityType}", url, request.EntityType);
        using var message = new HttpRequestMessage(HttpMethod.Post, url) { Content = JsonContent.Create(envelope) };
        message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await SendRequestAsync(message, url, cancellationToken);
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        logger.LogInformation("PracticeManagement API response {StatusCode} for {EntityType}", (int)response.StatusCode, request.EntityType);

        if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            throw new PracticeApiException("The practice API rejected the authorization token. Confirm Web/API Security:TokenSigningKey values match.");
        if (!response.IsSuccessStatusCode)
        {
            logger.LogError("PracticeManagement API returned HTTP {StatusCode} from {Url}. Body: {Body}",
                (int)response.StatusCode, url, Truncate(responseText, 1000));
            throw new PracticeApiException($"The practice API returned HTTP {(int)response.StatusCode} from {url} for entity [{request.EntityType}]. Body: {Truncate(responseText, 500)}");
        }

        EncryptedResponse? body;
        try { body = JsonSerializer.Deserialize<EncryptedResponse>(responseText, JsonOptions); }
        catch (JsonException)
        {
            logger.LogError("PracticeManagement API returned invalid JSON from {Url}. Body: {Body}", url, Truncate(responseText, 1000));
            throw new PracticeApiException($"The practice API returned an invalid response from {url}. HTTP {(int)response.StatusCode}.");
        }

        if (body is null || string.IsNullOrWhiteSpace(body.ResponseStr))
            throw new PracticeApiException("The practice API could not complete the request.");

        return crypto.DecryptResponse(body, token);
    }

    private async Task<HttpResponseMessage> SendRequestAsync(HttpRequestMessage message, string url, CancellationToken cancellationToken)
    {
        try { return await httpClient.SendAsync(message, cancellationToken); }
        catch (TaskCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new PracticeApiException($"Timed out while calling practice API: {url}. {ex.Message}");
        }
        catch (HttpRequestException ex)
        {
            throw new PracticeApiException($"Unable to reach practice API: {url}. {ex.Message}");
        }
    }

    public string ApiEndpointBaseUrl()
    {
        var configured = (configuration["ApiBaseUrl"] ?? "http://localhost:5045").Trim().TrimEnd('/');
        if (string.IsNullOrWhiteSpace(configured)) configured = "http://localhost:5045";

        var normalized = configured.Replace('\\', '/').TrimEnd('/');
        if (normalized.EndsWith("/api/PracticeManagement", StringComparison.OrdinalIgnoreCase))
            return normalized[..^"/api/PracticeManagement".Length] + "/" + PracticeApiRoute;
        if (normalized.EndsWith("/api/practice-management", StringComparison.OrdinalIgnoreCase))
            return normalized[..^"/api/practice-management".Length] + "/" + PracticeApiRoute;

        return normalized + "/" + PracticeApiRoute;
    }

    private static string Truncate(string value, int maxLength) =>
        string.IsNullOrEmpty(value) || value.Length <= maxLength ? value : value[..maxLength];
}

public sealed class PracticeApiException(string message) : Exception(message);
