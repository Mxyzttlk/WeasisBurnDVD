using System;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace DicomReceiver.Models;

public class PacsNetwork
{
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public string Username { get; set; } = "";
    public string EncryptedPassword { get; set; } = "";

    [JsonIgnore]
    public string DecryptedPassword
    {
        get => CryptoHelper.Decrypt(EncryptedPassword);
        set => EncryptedPassword = CryptoHelper.Encrypt(value);
    }
}

public static class CryptoHelper
{
    public static string Encrypt(string plainText)
    {
        if (string.IsNullOrEmpty(plainText)) return "";
        try
        {
            var data = Encoding.UTF8.GetBytes(plainText);
            var encrypted = ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(encrypted);
        }
        catch
        {
            return "";
        }
    }

    public static string Decrypt(string encrypted)
    {
        if (string.IsNullOrEmpty(encrypted)) return "";
        try
        {
            var data = Convert.FromBase64String(encrypted);
            var decrypted = ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(decrypted);
        }
        catch
        {
            return "";
        }
    }
}
