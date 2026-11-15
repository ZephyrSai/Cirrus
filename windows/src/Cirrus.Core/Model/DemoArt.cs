using System.Buffers.Binary;
using System.IO.Compression;

namespace Cirrus.Core;

/// <summary>Generates colourful PNG "photos" with a caption for the demo library (no imaging libraries needed).</summary>
public static class DemoArt
{
    public static byte[] Png(int width, int height, double hue, string label)
    {
        var (r1, g1, b1) = Hsv(hue, 0.55, 0.95);
        var (r2, g2, b2) = Hsv((hue + 0.12) % 1, 0.75, 0.55);
        var px = new byte[width * height * 3];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                double t = ((double)x / width + (double)y / height) / 2;
                var o = (y * width + x) * 3;
                px[o] = (byte)(r1 + (r2 - r1) * t); px[o + 1] = (byte)(g1 + (g2 - g1) * t); px[o + 2] = (byte)(b1 + (b2 - b1) * t);
            }
        // Soft translucent discs.
        for (int i = 0; i < 5; i++)
        {
            double r = height * (0.15 + 0.08 * i) / 2;
            double cx = width * 0.15 * i + r, cy = height * 0.8 - r;
            for (int y = Math.Max(0, (int)(cy - r)); y < Math.Min(height, (int)(cy + r)); y++)
                for (int x = Math.Max(0, (int)(cx - r)); x < Math.Min(width, (int)(cx + r)); x++)
                    if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) Blend(px, width, x, y, 255, 255, 255, 0.18);
        }
        // Centred caption so square (centre-cropped) thumbnails never clip it.
        int scale = Math.Max(2, Math.Min(width, height) / 70);
        int textW = label.Length * 6 * scale, textH = 7 * scale;
        int tx = (width - textW) / 2, ty = (int)(height * 0.45) - textH / 2;
        DrawText(px, width, height, label, tx + scale / 2, ty + scale / 2, scale, 0, 0, 0, 0.35);
        DrawText(px, width, height, label, tx, ty, scale, 255, 255, 255, 1);
        return Encode(width, height, px);
    }

    static (byte, byte, byte) Hsv(double h, double s, double v)
    {
        double i = Math.Floor(h * 6), f = h * 6 - i, p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
        var (r, g, b) = ((int)i % 6) switch { 0 => (v, t, p), 1 => (q, v, p), 2 => (p, v, t), 3 => (p, q, v), 4 => (t, p, v), _ => (v, p, q) };
        return ((byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }

    static void Blend(byte[] px, int w, int x, int y, byte r, byte g, byte b, double a)
    {
        var o = (y * w + x) * 3;
        px[o] = (byte)(px[o] * (1 - a) + r * a); px[o + 1] = (byte)(px[o + 1] * (1 - a) + g * a); px[o + 2] = (byte)(px[o + 2] * (1 - a) + b * a);
    }

    static void DrawText(byte[] px, int w, int h, string s, int x0, int y0, int scale, byte r, byte g, byte b, double a)
    {
        for (int ci = 0; ci < s.Length; ci++)
        {
            if (!Font.TryGetValue(char.ToUpperInvariant(s[ci]), out var rows)) continue;
            for (int row = 0; row < 7; row++)
                for (int col = 0; col < 5; col++)
                {
                    if (rows[row][col] != '#') continue;
                    for (int dy = 0; dy < scale; dy++)
                        for (int dx = 0; dx < scale; dx++)
                        {
                            int x = x0 + (ci * 6 + col) * scale + dx, y = y0 + row * scale + dy;
                            if (x >= 0 && y >= 0 && x < w && y < h) Blend(px, w, x, y, r, g, b, a);
                        }
                }
        }
    }

    static byte[] Encode(int w, int h, byte[] rgb)
    {
        using var raw = new MemoryStream();
        using (var z = new ZLibStream(raw, CompressionLevel.Fastest, leaveOpen: true))
        {
            for (int y = 0; y < h; y++) { z.WriteByte(0); z.Write(rgb, y * w * 3, w * 3); }
        }
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var ihdr = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, w);
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), h);
        ihdr[8] = 8; ihdr[9] = 2;   // 8-bit RGB
        Chunk(png, "IHDR", ihdr);
        Chunk(png, "IDAT", raw.ToArray());
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    static void Chunk(Stream s, string type, byte[] data)
    {
        Span<byte> len = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(len, data.Length);
        s.Write(len);
        var t = System.Text.Encoding.ASCII.GetBytes(type);
        s.Write(t);
        s.Write(data);
        var crc = Crc32(t, data);
        BinaryPrimitives.WriteUInt32BigEndian(len, crc);
        s.Write(len);
    }

    static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        uint c = (uint)n;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    static uint Crc32(byte[] a, byte[] b)
    {
        uint c = 0xFFFFFFFF;
        foreach (var x in a) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        foreach (var x in b) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFF;
    }

    // 5×7 bitmap font: digits, capitals and a few symbols.
    static readonly Dictionary<char, string[]> Font = new()
    {
        ['A'] = [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"], ['B'] = ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        ['C'] = [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."], ['D'] = ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        ['E'] = ["#####", "#....", "#....", "####.", "#....", "#....", "#####"], ['F'] = ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        ['G'] = [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"], ['H'] = ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        ['I'] = [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."], ['J'] = ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        ['K'] = ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"], ['L'] = ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        ['M'] = ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"], ['N'] = ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        ['O'] = [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."], ['P'] = ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        ['Q'] = [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"], ['R'] = ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        ['S'] = [".####", "#....", "#....", ".###.", "....#", "....#", "####."], ['T'] = ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        ['U'] = ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."], ['V'] = ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        ['W'] = ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."], ['X'] = ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        ['Y'] = ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."], ['Z'] = ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        ['0'] = [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."], ['1'] = ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        ['2'] = [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"], ['3'] = ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        ['4'] = ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."], ['5'] = ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        ['6'] = [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."], ['7'] = ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        ['8'] = [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."], ['9'] = [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
        ['-'] = [".....", ".....", ".....", "#####", ".....", ".....", "....."], ['.'] = [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        [' '] = [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    };
}
