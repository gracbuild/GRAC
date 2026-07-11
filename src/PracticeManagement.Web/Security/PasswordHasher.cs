using System.Security.Cryptography;

namespace PracticeManagement.Web.Security;

public sealed class PasswordHasher
{
    private const int Iterations = 210_000;

    public string Hash(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, 32);
        return $"{Iterations}.{Convert.ToBase64String(salt)}.{Convert.ToBase64String(hash)}";
    }

    public bool Verify(string password, string encodedHash)
    {
        try
        {
            var parts = encodedHash.Split('.');
            if (parts.Length != 3 || !int.TryParse(parts[0], out var iterations) || iterations < 100_000) return false;
            var salt = Convert.FromBase64String(parts[1]);
            var expected = Convert.FromBase64String(parts[2]);
            var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, expected.Length);
            return CryptographicOperations.FixedTimeEquals(expected, actual);
        }
        catch
        {
            return false;
        }
    }
}
