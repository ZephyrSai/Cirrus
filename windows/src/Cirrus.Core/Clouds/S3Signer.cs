using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Cirrus.Core;

/// <summary>
/// AWS Signature Version 4 (header-based), as S3 and every S3-compatible service uses it (port of S3Signer.swift).
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
/// Pure functions only: the canonical request, the string to sign, the signing key and the Authorization header. The
/// fake S3 server uses the same code to check what clients send, so the tests pin it to AWS's published vectors.
/// Nothing here logs a key, a canonical request or a signature.
/// </summary>
public static class S3Signer
{
    public const string Algorithm = "AWS4-HMAC-SHA256";
    /// <summary>SHA-256 of an empty body.</summary>
    public const string EmptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    /// <summary>Allowed by S3 instead of a body hash (Cirrus hashes every body it sends, but the fake accepts it too).</summary>
    public const string UnsignedPayload = "UNSIGNED-PAYLOAD";

    public sealed record Signed(string Authorization, string CanonicalRequest, string StringToSign, string Signature, string SignedHeaders);

    /// <summary>
    /// Signs one request. <paramref name="headers"/> are the headers to sign, including <c>host</c> and <c>x-amz-date</c>
    /// (names in any case); <paramref name="canonicalURI"/> and <paramref name="canonicalQuery"/> are already encoded
    /// (see <see cref="Encode"/> and <see cref="CanonicalQuery"/>).
    /// </summary>
    public static Signed Sign(string method, string canonicalURI, string canonicalQuery, IEnumerable<(string Name, string Value)> headers, string payloadHash,
        string amzDate, string region, string service, string accessKey, string secretKey)
    {
        var (canonHeaders, signedHeaders) = CanonicalHeaders(headers);
        var creq = string.Join('\n', method.ToUpperInvariant(), canonicalURI.Length == 0 ? "/" : canonicalURI, canonicalQuery, canonHeaders, signedHeaders, payloadHash);
        var day = amzDate.Length >= 8 ? amzDate[..8] : amzDate;
        var scope = $"{day}/{region}/{service}/aws4_request";
        var sts = string.Join('\n', Algorithm, amzDate, scope, Sha256Hex(Encoding.UTF8.GetBytes(creq)));
        var key = SigningKey(secretKey, day, region, service);
        var sig = Hex(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(sts)));
        var auth = $"{Algorithm} Credential={accessKey}/{scope}, SignedHeaders={signedHeaders}, Signature={sig}";
        return new Signed(auth, creq, sts, sig, signedHeaders);
    }

    /// <summary>kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, day), region), service), "aws4_request").</summary>
    public static byte[] SigningKey(string secret, string day, string region, string service)
    {
        var k = Encoding.UTF8.GetBytes("AWS4" + secret);
        foreach (var part in new[] { day, region, service, "aws4_request" }) k = HMACSHA256.HashData(k, Encoding.UTF8.GetBytes(part));
        return k;
    }

    /// <summary>
    /// Lower-case names, values trimmed with inner runs of spaces collapsed, repeated names joined by commas, sorted by
    /// name. Returns the canonical header block (each line ending in "\n") and the signed-headers list.
    /// </summary>
    public static (string Canonical, string Signed) CanonicalHeaders(IEnumerable<(string Name, string Value)> headers)
    {
        var merged = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var (name, value) in headers)
        {
            var n = name.Trim(' ', '\t').ToLowerInvariant();
            if (!merged.TryGetValue(n, out var list)) merged[n] = list = [];
            list.Add(TrimValue(value));
        }
        var sb = new StringBuilder();
        foreach (var (n, values) in merged) sb.Append(n).Append(':').Append(string.Join(',', values)).Append('\n');
        return (sb.ToString(), string.Join(';', merged.Keys));
    }

    public static string TrimValue(string v)
    {
        var sb = new StringBuilder(v.Length);
        var lastSpace = false;
        foreach (var ch in v.Trim())
        {
            var space = ch is ' ' or '\t' or '\n' or '\r';
            if (space) { if (!lastSpace) sb.Append(' '); }
            else sb.Append(ch);
            lastSpace = space;
        }
        return sb.ToString();
    }

    /// <summary>
    /// Query parameters: names and values URI-encoded (every byte but A–Z a–z 0–9 - _ . ~, "/" included), sorted by name
    /// then value, a missing value written as "name=".
    /// </summary>
    public static string CanonicalQuery(IEnumerable<(string Name, string? Value)> items) =>
        string.Join('&', items.Select(i => (Name: Encode(i.Name, slash: true), Value: Encode(i.Value ?? "", slash: true)))
            .OrderBy(p => p.Name, StringComparer.Ordinal).ThenBy(p => p.Value, StringComparer.Ordinal)
            .Select(p => p.Name + "=" + p.Value));

    const string HexDigits = "0123456789ABCDEF";

    /// <summary>
    /// AWS's URI encoding: each UTF-8 byte other than the unreserved characters becomes %XX (upper-case hex).
    /// <paramref name="slash"/> false keeps "/" (object keys in paths); S3 paths are encoded once and never normalized.
    /// </summary>
    public static string Encode(string s, bool slash)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        var sb = new StringBuilder(bytes.Length);
        foreach (var b in bytes)
        {
            if (Unreserved(b) || (b == (byte)'/' && !slash)) sb.Append((char)b);
            else sb.Append('%').Append(HexDigits[b >> 4]).Append(HexDigits[b & 0xF]);
        }
        return sb.ToString();
    }

    /// <summary>A–Z a–z 0–9 - _ . ~</summary>
    public static bool Unreserved(byte b) =>
        b is >= 0x41 and <= 0x5A or >= 0x61 and <= 0x7A or >= 0x30 and <= 0x39 or 0x2D or 0x5F or 0x2E or 0x7E;

    static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>Percent-decoding of raw bytes ("+" stays "+"); null when the escapes don't make UTF-8.</summary>
    public static string? Decode(string s)
    {
        if (!s.Contains('%')) return s;
        var src = Encoding.UTF8.GetBytes(s);
        var bytes = new List<byte>(src.Length);
        for (int i = 0; i < src.Length; i++)
        {
            if (src[i] == (byte)'%' && i + 2 < src.Length &&IsHex(src[i + 1]) && IsHex(src[i + 2]))
            {
                bytes.Add((byte)(HexValue(src[i + 1]) << 4 | HexValue(src[i + 2])));
                i += 2;
            }
            else bytes.Add(src[i]);
        }
        try { return StrictUtf8.GetString(bytes.ToArray()); } catch (ArgumentException) { return null; }
    }

    static bool IsHex(byte b) => b is >= (byte)'0' and <= (byte)'9' or >= (byte)'a' and <= (byte)'f' or >= (byte)'A' and <= (byte)'F';
    static int HexValue(byte b) => b <= (byte)'9' ? b - '0' : (b | 0x20) - 'a' + 10;

    /// <summary>The raw query of a URL ("a=1&amp;b") → decoded pairs, as a server reads them.</summary>
    public static List<(string Name, string? Value)> QueryItems(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return [];
        var output = new List<(string, string?)>();
        foreach (var part in raw.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            if (eq >= 0)
            {
                var name = part[..eq];
                output.Add((Decode(name) ?? name, Decode(part[(eq + 1)..]) ?? ""));
            }
            else output.Add((Decode(part) ?? part, null));
        }
        return output;
    }

    public static string Sha256Hex(byte[] d) => Hex(SHA256.HashData(d));
    public static string Hex(byte[] d) => Convert.ToHexStringLower(d);

    /// <summary>"20150830T123600Z" (UTC).</summary>
    public static string AmzDate(DateTimeOffset date) => date.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset? ParseAmzDate(string s)
    {
        if (s.Length != 16 || s[15] != 'Z' || s[8] != 'T' || s.Count(char.IsAsciiDigit) != 14) return null;
        return DateTimeOffset.TryParseExact(s, "yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
    }

    /// <summary>The parts of an Authorization header ("AWS4-HMAC-SHA256 Credential=…, SignedHeaders=…, Signature=…").</summary>
    public sealed record Parsed(string AccessKey, string Day, string Region, string Service, IReadOnlyList<string> SignedHeaders, string Signature);

    public static Parsed? Parse(string authorization)
    {
        if (!authorization.StartsWith(Algorithm + " ", StringComparison.Ordinal)) return null;
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in authorization[(Algorithm.Length + 1)..].Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var t = part.Trim(' ', '\t');
            var eq = t.IndexOf('=');
            if (eq < 0) return null;
            fields[t[..eq]] = t[(eq + 1)..];
        }
        if (!fields.TryGetValue("Credential", out var cred) || !fields.TryGetValue("SignedHeaders", out var sh) || !fields.TryGetValue("Signature", out var sig)) return null;
        var c = cred.Split('/');
        if (c.Length != 5 || c[4] != "aws4_request") return null;
        return new Parsed(c[0], c[1], c[2], c[3], sh.Split(';', StringSplitOptions.RemoveEmptyEntries), sig);
    }
}

/// <summary>
/// Operations on object keys. S3 keys are UTF-8 byte strings: equality and prefixes are ordinal, and ordering is by
/// UTF-8 bytes (which differs from UTF-16 ordinal order once characters beyond U+FFFF meet U+E000–U+FFFF).
/// </summary>
public static class S3Key
{
    public static bool HasPrefix(string s, string p) => s.StartsWith(p, StringComparison.Ordinal);
    public static bool Same(string a, string b) => string.Equals(a, b, StringComparison.Ordinal);
    public static int Compare(string a, string b) => Encoding.UTF8.GetBytes(a).AsSpan().SequenceCompareTo(Encoding.UTF8.GetBytes(b));
    public static bool Less(string a, string b) => Compare(a, b) < 0;
    public static string DropPrefix(string s, string p) => s.Length >= p.Length ? s[p.Length..] : "";
    public static bool IsFolder(string k) => k.EndsWith('/');

    /// <summary>"a/b/c.txt" → "c.txt", "a/b/" → "b".</summary>
    public static string LastSegment(string k)
    {
        if (k.EndsWith('/')) k = k[..^1];
        var i = k.LastIndexOf('/');
        return i >= 0 ? k[(i + 1)..] : k;
    }

    /// <summary>"a/b/c.txt" → "a/b/", "a/" → "", "x" → "".</summary>
    public static string Parent(string k)
    {
        if (k.EndsWith('/')) k = k[..^1];
        var i = k.LastIndexOf('/');
        return i >= 0 ? k[..(i + 1)] : "";
    }

    /// <summary>The first "/"-separated piece after <paramref name="prefix"/> (with its "/" when there is one): what a delimiter listing groups by.</summary>
    public static string? ChildPrefix(string k, string prefix)
    {
        var rest = DropPrefix(k, prefix);
        var i = rest.IndexOf('/');
        return i < 0 ? null : prefix + rest[..(i + 1)];
    }
}
