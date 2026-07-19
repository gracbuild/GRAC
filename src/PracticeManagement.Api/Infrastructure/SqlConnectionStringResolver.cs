// =====================================================================
// SqlConnectionStringResolver
//
// Shared helper that mirrors PracticeRepositoryService.GetConnectionString +
// ConfigureConnectionString + DecryptPassword so new services (Permission,
// Task, PracticeInstanceWorkflow) don't have to duplicate password
// decryption and Encrypt / TrustServerCertificate handling.
//
// Charter §5: PracticeRepositoryService.cs is a monolith we don't extend;
// instead, we EXTRACT the resolver logic to this shared file. The
// monolith continues to work — its private methods are unchanged.
// =====================================================================
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;

namespace PracticeManagement.Api.Infrastructure;

public static class SqlConnectionStringResolver
{
    /// <summary>
    /// Resolve + finalise the SQL Server connection string:
    ///   1. Prefer ConnectionStrings:PracticeManagement (full ready-to-use).
    ///   2. Else combine ConnectionStrings:DbConnection with the encrypted
    ///      ConnectionStrings:Password (format: key~ciphertext).
    ///   3. Apply Encrypt + TrustServerCertificate from Database:* config.
    /// Returns null when nothing usable is configured.
    /// </summary>
    public static string? Resolve(IConfiguration configuration)
    {
        var provider = configuration["Database:Provider"] ?? "Microsoft.Data.SqlClient";

        var direct = configuration.GetConnectionString("PracticeManagement");
        if (!string.IsNullOrWhiteSpace(direct))
            return ApplyTls(direct, provider, configuration);

        var gracConnection    = configuration.GetConnectionString("DbConnection");
        var encryptedPassword = configuration.GetConnectionString("Password");
        if (string.IsNullOrWhiteSpace(gracConnection)) return null;

        var full = gracConnection;
        if (!string.IsNullOrWhiteSpace(encryptedPassword))
        {
            var parts = encryptedPassword.Split('~', 2);
            if (parts.Length != 2)
                throw new InvalidOperationException(
                    "ConnectionStrings:Password must contain the GRAC encryption key and encrypted password separated by '~'.");
            full = gracConnection + DecryptPassword(parts[1], parts[0]);
        }

        return ApplyTls(full, provider, configuration);
    }

    private static string ApplyTls(string connectionString, string provider, IConfiguration configuration)
    {
        if (!provider.Equals("Microsoft.Data.SqlClient", StringComparison.OrdinalIgnoreCase))
            return connectionString;

        var builder = new SqlConnectionStringBuilder(connectionString)
        {
            Encrypt                = configuration.GetValue("Database:Encrypt", true),
            TrustServerCertificate = configuration.GetValue("Database:TrustServerCertificate", false)
        };
        return builder.ConnectionString;
    }

    // Mirrors PracticeRepositoryService.DecryptPassword byte-for-byte so
    // the same encrypted secret works across both services.
    private static string DecryptPassword(string encryptedPassword, string key)
    {
        using var aes = Aes.Create();
        aes.Key     = Encoding.UTF8.GetBytes(key.Substring(4, 32));
        aes.IV      = Encoding.UTF8.GetBytes(key.ToLowerInvariant().Substring(4, 16));
        aes.Mode    = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor(aes.Key, aes.IV);
        using var ms        = new MemoryStream(Convert.FromBase64String(encryptedPassword));
        using var cs        = new CryptoStream(ms, decryptor, CryptoStreamMode.Read);
        using var reader    = new StreamReader(cs);
        return reader.ReadToEnd();
    }
}
