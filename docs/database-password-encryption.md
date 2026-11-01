# Database password encryption (Production deployment)

The API reads its SQL Server connection from `ConnectionStrings` in the deployed
`PracticeManagement.Api` `appsettings.json` (`Infrastructure/SqlConnectionStringResolver.cs`,
mirrored by `PracticeRepositoryService`). The Web tier has no connection string.

## How the API resolves it
1. `ConnectionStrings:PracticeManagement` set -> used as-is (plain password). **Leave it out in Production.**
2. Otherwise `ConnectionStrings:DbConnection` + the decrypted `ConnectionStrings:Password`:
   - `Password` = `<key>~<base64 ciphertext>`
   - AES-256-CBC, PKCS7. Key = UTF-8 of `key.Substring(4, 32)`, IV = UTF-8 of `key.ToLowerInvariant().Substring(4, 16)`.
   - The plaintext is **appended** to `DbConnection`, which must therefore end with `Password=`.
3. `Database:Encrypt` / `Database:TrustServerCertificate` are applied on top.

## Producing the value - `tools/Grac-DbPassword.ps1`
```powershell
# new random key per environment
.\tools\Grac-DbPassword.ps1 -Password '<sql login password>'

# check a deployed value (never prints the password)
.\tools\Grac-DbPassword.ps1 -Password '<sql login password>' -Encrypted '<key>~<ciphertext>'
```
Then in Production `appsettings.json`:
```json
"ConnectionStrings": {
  "DbConnection": "Data Source=<server>;Initial Catalog=<database>;User ID=<login>;Password=",
  "Password": "<script output>"
}
```
- Windows PowerShell 5.1 or PowerShell 7+. No code change, no rebuild: the API decrypts at start-up; recycle the app pool after editing.
- The script refuses a password containing `;`, leading/trailing spaces or a leading quote, because the value is appended unquoted.
- Verified 2026-10-27: the script's output decrypts with the API's exact algorithm, and the existing UAT value re-encrypts byte-for-byte.

## Limits
The key sits next to the ciphertext, so this keeps the password out of plain sight and out of
source control; it does not stop someone who can read the deployed file. Restrict the file's NTFS
permissions to the IIS app pool identity and administrators, and use a dedicated SQL login for the
application rather than `sa`.
