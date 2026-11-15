using System.Numerics;

namespace Cirrus.Core.Tests;

public class SrpTests
{
    [Fact]
    public void BigIntegerArithmeticMatchesPythonVectors()
    {
        var lines = TestEnv.Fixture("bigint-vectors.txt").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.True(lines.Length >= 30);
        foreach (var line in lines)
        {
            var f = line.Trim().Split(' ');
            BigInteger H(int i) => AppleSRPClient.FromHex(f[i]);
            BigInteger a = H(0), b = H(1), m = H(2);
            Assert.Equal(H(3), a * b);
            var q = BigInteger.DivRem(a, b, out var r);
            Assert.Equal(H(4), q);
            Assert.Equal(H(5), r);
            Assert.Equal(a, q * b + r);
            if (m > 1) Assert.Equal(H(6), BigInteger.ModPow(a, b, m));
        }
    }

    [Fact]
    public void BytesRoundTripLikeSwiftBigUInt()
    {
        byte[] bytes = [0, 0, 1, 2, 3, 4, 5, 255];
        var v = AppleSRPClient.FromBytes(bytes);
        Assert.Equal(new byte[] { 1, 2, 3, 4, 5, 255 }, AppleSRPClient.Serialize(v));
        Assert.Equal(bytes, AppleSRPClient.Pad(v, 8));
        Assert.True(AppleSRPClient.FromBytes([]).IsZero);
        Assert.Empty(AppleSRPClient.Serialize(BigInteger.Zero));
        Assert.Equal(256, AppleSRPClient.Pad(AppleSRPClient.G).Length);
    }

    [Fact]
    public void SrpMatchesIndependentImplementation()
    {
        var secret = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();
        var salt = TestEnv.Hex("a1b2c3d4e5f60718293a4b5c6d7e8f90");
        var lines = TestEnv.Fixture("srp-vectors.txt").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        foreach (var line in lines)
        {
            var parts = line.Trim().Split(' ');
            var proto = parts[0];
            var kv = parts.Skip(1).Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => p[1]);
            var key = AppleSRPClient.DerivePassword("correct horse battery staple", salt, 20000, proto);
            Assert.Equal(TestEnv.Hex(kv["key"]), key);
            var client = new AppleSRPClient(secret);
            Assert.Equal(TestEnv.Hex(kv["A"]), client.ABytes);
            client.ProcessChallenge("someone@example.com", key, salt, TestEnv.Hex(kv["B"]));
            Assert.Equal(TestEnv.Hex(kv["M1"]), client.M1);
            Assert.Equal(TestEnv.Hex(kv["M2"]), client.M2);
        }
    }

    [Fact]
    public void SrpRejectsBadServerValue()
    {
        var client = new AppleSRPClient(Enumerable.Repeat((byte)7, 32).ToArray());
        Assert.Throws<AppleSRPClient.SRPException>(() => client.ProcessChallenge("x", [1], [1], [0]));
        Assert.Throws<AppleSRPClient.SRPException>(() => client.ProcessChallenge("x", [1], [1], AppleSRPClient.Serialize(AppleSRPClient.N)));
        Assert.Throws<AppleSRPClient.SRPException>(() => AppleSRPClient.DerivePassword("pw", [1, 2], 10, "plain"));
    }
}
