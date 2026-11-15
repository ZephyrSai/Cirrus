using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace Cirrus.Core;

/// <summary>
/// Client side of Apple's SRP-6a variant used by idmsa.apple.com
/// (RFC 5054 2048-bit group, SHA-256, username omitted from x, s2k / s2k_fo password derivation).
/// Port of Sources/CirrusCore/Auth/SRP.swift (itself mirroring rclone's backend/iclouddrive/api/srp.go).
/// </summary>
public sealed class AppleSRPClient
{
    public static readonly BigInteger N = FromHex(
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050" +
        "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50" +
        "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8" +
        "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B" +
        "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748" +
        "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861602790" +
        "04E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8" +
        "E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
        "9E4AFF73");
    public static readonly BigInteger G = 2;
    public const int NLen = 256;

    public sealed class SRPException(string message) : Exception(message) { }

    readonly BigInteger _a;
    public BigInteger A { get; }
    public byte[] M1 { get; private set; } = [];
    public byte[] M2 { get; private set; } = [];
    public byte[] K { get; private set; } = [];

    public AppleSRPClient(byte[]? secret = null)
    {
        var bytes = secret ?? RandomNumberGenerator.GetBytes(32);
        _a = FromBytes(bytes);
        A = BigInteger.ModPow(G, _a, N);
    }

    public byte[] ABytes => Pad(A);

    public static BigInteger FromBytes(ReadOnlySpan<byte> bytes) => bytes.Length == 0 ? BigInteger.Zero : new BigInteger(bytes, isUnsigned: true, isBigEndian: true);

    public static BigInteger FromHex(string hex) => FromBytes(Convert.FromHexString(hex.Length % 2 == 1 ? "0" + hex : hex));

    /// <summary>Minimal big-endian bytes (empty for zero), like Swift's BigUInt.serialize().</summary>
    public static byte[] Serialize(BigInteger v) => v.IsZero ? [] : v.ToByteArray(isUnsigned: true, isBigEndian: true);

    public static byte[] Pad(BigInteger v, int length = NLen)
    {
        var b = Serialize(v);
        if (b.Length >= length) return b;
        var o = new byte[length];
        b.CopyTo(o, length - b.Length);
        return o;
    }

    public static byte[] H(params byte[][] parts)
    {
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var p in parts) h.AppendData(p);
        return h.GetHashAndReset();
    }

    static BigInteger K_ => FromBytes(H(Serialize(N), Pad(G)));

    public static byte[] DerivePassword(string password, byte[] salt, int iterations, string protocol)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(password));
        byte[] input = protocol switch
        {
            "s2k" => digest,
            "s2k_fo" => Encoding.UTF8.GetBytes(Convert.ToHexStringLower(digest)),
            _ => throw new SRPException($"Unsupported password protocol \"{protocol}\"."),
        };
        try { return Rfc2898DeriveBytes.Pbkdf2(input, salt, iterations, HashAlgorithmName.SHA256, 32); }
        catch (Exception e) when (e is not SRPException) { throw new SRPException("Password key derivation failed."); }
        finally { CryptographicOperations.ZeroMemory(input); }
    }

    /// <summary><paramref name="username"/> must already be lowercased.</summary>
    public void ProcessChallenge(string username, byte[] derivedKey, byte[] salt, byte[] serverB)
    {
        var B = FromBytes(serverB);
        if (B.IsZero || B >= N) throw new SRPException("Apple returned an invalid sign-in challenge.");
        var x = FromBytes(H(salt, H(Encoding.UTF8.GetBytes(":"), derivedKey)));
        var u = FromBytes(H(Pad(A), Pad(B)));
        if (u.IsZero) throw new SRPException("Sign-in challenge failed a safety check.");
        var gx = BigInteger.ModPow(G, x, N);
        var kgx = (K_ * gx) % N;
        var @base = ((B + N) - kgx) % N;
        var exp = _a + u * x;
        var S = BigInteger.ModPow(@base, exp, N);
        K = H(Pad(S));
        var hg = H(Pad(G));
        var hn = H(Serialize(N));
        var hxor = new byte[hg.Length];
        for (int i = 0; i < hg.Length; i++) hxor[i] = (byte)(hg[i] ^ hn[i]);
        var hi = H(Encoding.UTF8.GetBytes(username));
        M1 = H(hxor, hi, salt, Pad(A), Pad(B), K);
        M2 = H(Pad(A), M1, K);
    }
}
