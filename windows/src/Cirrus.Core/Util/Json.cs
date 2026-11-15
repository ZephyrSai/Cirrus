using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// Null-safe view over Apple's loosely typed JSON (port of the Swift <c>JSON</c> enum).
/// Indexing a missing key or a non-object yields an empty value instead of throwing.
/// </summary>
public readonly struct J
{
    public readonly JsonNode? Node;
    public J(JsonNode? node) { Node = node; }

    public static readonly J Null = default;

    public static J Parse(byte[]? data)
    {
        if (data is null || data.Length == 0) return Null;
        try { return new J(JsonNode.Parse(data)); } catch (JsonException) { return Null; }
    }

    public static J Parse(string? text)
    {
        if (string.IsNullOrEmpty(text)) return Null;
        try { return new J(JsonNode.Parse(text)); } catch (JsonException) { return Null; }
    }

    public J this[string key] => Node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? new J(v) : Null;
    public J this[int index] => Node is JsonArray a && index >= 0 && index < a.Count ? new J(a[index]) : Null;

    public bool IsNull => Node is null;

    JsonValueKind Kind => Node switch
    {
        null => JsonValueKind.Null,
        JsonObject => JsonValueKind.Object,
        JsonArray => JsonValueKind.Array,
        JsonValue v => v.GetValueKind(),
        _ => JsonValueKind.Undefined,
    };

    bool TryDouble(out double d)
    {
        d = 0;
        if (Node is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return false;
        if (v.TryGetValue(out double dd)) { d = dd; return true; }
        if (v.TryGetValue(out long l)) { d = l; return true; }
        if (v.TryGetValue(out int i)) { d = i; return true; }
        if (v.TryGetValue(out JsonElement e) && e.TryGetDouble(out dd)) { d = dd; return true; }
        return double.TryParse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out d);
    }

    bool TryLong(out long l)
    {
        l = 0;
        if (Node is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return false;
        if (v.TryGetValue(out long ll)) { l = ll; return true; }
        if (v.TryGetValue(out int i)) { l = i; return true; }
        if (v.TryGetValue(out JsonElement e) && e.TryGetInt64(out ll)) { l = ll; return true; }
        if (TryDouble(out var d)) { l = (long)d; return true; }
        return false;
    }

    /// <summary>Strings as-is; integral numbers without a decimal point; booleans as "true"/"false".</summary>
    public string? Str
    {
        get
        {
            switch (Kind)
            {
                case JsonValueKind.String: return Node!.GetValue<string>();
                case JsonValueKind.Number:
                    if (TryLong(out var l) && TryDouble(out var d) && d == Math.Round(d) && Math.Abs(d) < 1e15) return l.ToString(CultureInfo.InvariantCulture);
                    return TryDouble(out var dd) ? dd.ToString("R", CultureInfo.InvariantCulture) : null;
                case JsonValueKind.True: return "true";
                case JsonValueKind.False: return "false";
                default: return null;
            }
        }
    }

    public long? Int64
    {
        get
        {
            switch (Kind)
            {
                case JsonValueKind.Number: return TryLong(out var l) ? l : null;
                case JsonValueKind.String: return long.TryParse(Node!.GetValue<string>(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s) ? s : null;
                case JsonValueKind.True: return 1;
                case JsonValueKind.False: return 0;
                default: return null;
            }
        }
    }

    public int? Int => Int64 is long l ? (int)l : null;

    public double? Double
    {
        get
        {
            switch (Kind)
            {
                case JsonValueKind.Number: return TryDouble(out var d) ? d : null;
                case JsonValueKind.String: return double.TryParse(Node!.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var s) ? s : null;
                default: return null;
            }
        }
    }

    public bool? Bool
    {
        get
        {
            switch (Kind)
            {
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                case JsonValueKind.Number: return TryDouble(out var d) ? d != 0 : null;
                case JsonValueKind.String: { var s = Node!.GetValue<string>(); return s == "true" || s == "1"; }
                default: return null;
            }
        }
    }

    public IReadOnlyList<J> Array => Node is JsonArray a ? a.Select(n => new J(n)).ToList() : [];

    public IEnumerable<KeyValuePair<string, J>> Object =>
        Node is JsonObject o ? o.Select(kv => new KeyValuePair<string, J>(kv.Key, new J(kv.Value))) : [];

    /// <summary>Apple's mixed date encodings: ISO-8601 strings or epoch (milli)seconds.</summary>
    public DateTimeOffset? Date
    {
        get
        {
            switch (Kind)
            {
                case JsonValueKind.Number: return TryDouble(out var n) ? FromEpoch(n) : null;
                case JsonValueKind.String:
                    var s = Node!.GetValue<string>();
                    if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return FromEpoch(d);
                    return ParseIso(s);
                default: return null;
            }
        }
    }

    static DateTimeOffset? FromEpoch(double n)
    {
        var secs = n > 1e11 ? n / 1000 : n;
        try { return DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(secs * 1000)); } catch (ArgumentOutOfRangeException) { return null; }
    }

    internal static DateTimeOffset? ParseIso(string s) =>
        DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;

    public override string ToString() => Node?.ToJsonString() ?? "null";
}

/// <summary>Helpers for building request bodies.</summary>
public static class Jx
{
    /// <summary>Compact JSON without HTML-escaping (file names keep their real characters on the wire).</summary>
    public static readonly JsonSerializerOptions Wire = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = false };

    public static readonly JsonSerializerOptions Pretty = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = true };

    public static byte[] Bytes(JsonNode? node) => Encoding.UTF8.GetBytes(node?.ToJsonString(Wire) ?? "null");

    public static JsonArray Strings(IEnumerable<string> values)
    {
        var a = new JsonArray();
        foreach (var v in values) a.Add(v);
        return a;
    }

    /// <summary>JsonNodes have a single parent; clone before reusing a node in a second body.</summary>
    public static JsonNode? Clone(this JsonNode? node) => node?.DeepClone();
}
