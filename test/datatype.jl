# Datatypes, ported from rexi-core/src/datatype/*.rs (exip check_streamIO.c
# vectors and EXIficient core tests).
import JExi as J

function enc(f; aligned = false)
    w = J.BitWriter(; byte_aligned = aligned)
    f(w)
    return J.finish!(w)
end
reader(bytes; aligned = false) = J.BitReader(bytes; byte_aligned = aligned)

# A type resolver for the tests (rexi lexical.rs `Mock`).
struct Mock end
const COLOURS = ["red", "green", "blue"]
const NUMBERS = ["1", "2", "3", "10"]
const DECIMALS = ["1.0", "2.5"]
function J.datatype(::Mock, t::Integer)
    t == 0 && return J.INTEGER_KIND
    t == 1 && return J.string_kind(J.WS_COLLAPSE)
    t == 2 && return J.FLOAT_KIND
    t == 3 && return J.DECIMAL_KIND
    t == 4 && return J.list_kind(0)
    t == 5 && return J.nbit_kind(2, 4)
    t == 6 && return J.enum_kind(0, 1)
    t == 7 && return J.enum_kind(1, 0)
    return J.enum_kind(2, 3)
end
mock_set(set) = set == 0 ? COLOURS : set == 1 ? NUMBERS : DECIMALS
J.enum_count(::Mock, set::Integer) = length(mock_set(set))
J.enum_value(::Mock, set::Integer, i::Integer) = 0 <= i < length(mock_set(set)) ? mock_set(set)[i + 1] : nothing

@testset "datatypes" begin
    @testset "unsigned: exip vectors" begin
        @test enc(w -> J.write_unsigned!(w, UInt64(421))) == [0xa5, 0x03]
        @test enc(w -> J.write_unsigned!(w, UInt64(0))) == [0x00]
        @test J.read_unsigned!(reader(UInt8[0xd4, 0x60, 0x48])) == 12372
        @test enc(w -> J.write_unsigned!(w, UInt64(421)); aligned = true) == [0xa5, 0x03]
    end

    @testset "unsigned: EXIficient values round trip" begin
        for v in UInt64[0, 1, 2, 127, 128, 200, 2000, 20000, 200000, 2000000, typemax(UInt32), typemax(UInt64)]
            @test J.read_unsigned!(reader(enc(w -> J.write_unsigned!(w, v)))) == v
        end
    end

    @testset "unsigned: big values" begin
        @test enc(w -> J.write_unsigned!(w, big(12678967543233))) ==
              enc(w -> J.write_unsigned!(w, UInt64(12678967543233)))
        huge = parse(BigInt, "123456789012345678901234567890")
        bytes = enc(w -> J.write_unsigned!(w, huge))
        @test_throws J.ValueError J.read_unsigned!(reader(bytes))
        @test J.read_unsigned_any!(reader(bytes)) == huge
        @test J.read_unsigned_any!(reader(bytes)) isa BigInt
    end

    @testset "unsigned: any-size reader matches a plain big reader" begin
        function reference(bytes)
            r = reader(bytes)
            v = big(0)
            shift = 0
            while true
                o = J.read_byte!(r)
                v |= big(o & 0x7f) << shift
                o & 0x80 == 0 && break
                shift += 7
            end
            return v <= typemax(UInt64) ? UInt64(v) : v
        end
        values = UInt64[0, 1, 127, 128, 16383, 16384, typemax(UInt64), typemax(UInt64) - 1]
        for b in 0:63
            push!(values, UInt64(1) << b, (UInt64(1) << b) - 1)
        end
        state = Ref(0x9e37_79b9_7f4a_7c15)
        for _ in 1:2000
            s = xorshift(state)
            push!(values, s >> (s % 64))
        end
        cases = [enc(w -> J.write_unsigned!(w, v)) for v in values]
        push!(cases, vcat(fill(0xff, 9), 0x7f), vcat(fill(0xff, 10), 0x01), vcat(fill(0x80, 12), 0x00),
            vcat(0x81, fill(0x80, 12), 0x00), vcat(0x81, fill(0x80, 12), 0x01),
            UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x80, 0x01],
            UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
            UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02])
        for bytes in cases
            a = J.read_unsigned_any!(reader(bytes))
            b = reference(bytes)
            @test a == b && typeof(a) == typeof(b)
        end
        @test_throws J.TruncatedError J.read_unsigned_any!(reader(UInt8[0x80, 0x80]))
    end

    @testset "unsigned: same bytes as one octet at a time" begin
        function reference!(w, v)
            while true
                o = (v & 0x7f) % UInt8
                v >>= 7
                v != 0 && (o |= 0x80)
                J.write_byte!(w, o)
                v == 0 && return
            end
        end
        values = UInt64[0, 1, 127, 128, typemax(UInt64)]
        for b in 0:63
            push!(values, UInt64(1) << b, (UInt64(1) << b) - 1, (UInt64(1) << b) + 1)
        end
        for offset in 0:7, v in values
            a = J.BitWriter()
            b = J.BitWriter()
            J.write_raw_bits!(a, UInt64(0x55), offset)
            J.write_raw_bits!(b, UInt64(0x55), offset)
            J.write_unsigned!(a, v)
            reference!(b, v)
            @test J.bit_position(a) == J.bit_position(b)
            @test J.finish!(a) == J.finish!(b)
        end
    end

    @testset "integer: exip vectors" begin
        r = reader(UInt8[0x94, 0x60, 0x48])
        @test J.read_integer!(r) == -41
        @test J.bit_position(r) == 9
        r = reader(UInt8[0x14, 0x60, 0x48])
        @test J.read_integer!(r) == 40
        @test J.bit_position(r) == 9
        @test enc(w -> J.write_integer!(w, -913)) == [0xc8, 0x03, 0x80]
        @test enc(w -> J.write_integer!(w, -913); aligned = true) == [0x01, 0x90, 0x07]
        @test enc(w -> J.write_integer!(w, 40); aligned = true) == [0x00, 0x28]
    end

    round_int(v; aligned = false) = J.read_integer!(reader(enc(w -> J.write_integer!(w, v); aligned); aligned))

    @testset "integer: EXIficient core values" begin
        for v in Int64[0, 1, typemin(Int32), -128, 12_131_321_321, 12_678_967_543_233,
            typemin(Int64), typemax(Int64), -1, typemin(Int64) + 1]
            @test round_int(v) === v
            @test round_int(v; aligned = true) === v
        end
        for s in ["0", "1", "-128", "12131321321", "2137000000000000000000000000001", "12678967543233",
            "-5153135115135135135135153153135135153"]
            v = J.int_from_decimal_str(s)
            @test string(round_int(v)) == s
            @test string(round_int(v; aligned = true)) == s
        end
        # 2^63 and -(2^63) - 1 do not fit Int64.
        @test round_int(big(2)^63) == big(2)^63
        @test round_int(-big(2)^63 - 1) == -big(2)^63 - 1
        @test round_int(-big(2)^63 - 1; aligned = true) == -big(2)^63 - 1
        # A BigInt that fits Int64 decodes as Int64 and has the same bytes.
        @test round_int(big(-5)) === Int64(-5)
        @test enc(w -> J.write_integer!(w, big(-5))) == enc(w -> J.write_integer!(w, -5))
    end

    @testset "integer: sequence" begin
        w = J.BitWriter()
        wb = J.BitWriter(; byte_aligned = true)
        for i in 0:19_999
            J.write_integer!(w, i)
            J.write_integer!(wb, i)
        end
        r = reader(J.finish!(w))
        rb = reader(J.finish!(wb); aligned = true)
        ok = true
        for i in 0:19_999
            ok &= J.read_integer!(r) == i && J.read_integer!(rb) == i
        end
        @test ok
    end

    @testset "n-bit" begin
        for (value, bits) in ((0, 1), (1, 1), (8, 4), (33, 9), (78935, 20), (8448, 20)), aligned in (false, true)
            bytes = enc(w -> J.write_nbit!(w, value, 0, bits); aligned)
            @test J.read_nbit!(reader(bytes; aligned), 0, bits) == value
        end
        w = J.BitWriter()
        @test_throws J.ValueError J.write_nbit!(w, 18, 2, 4)
        @test_throws J.ValueError J.write_nbit!(w, 1, 2, 4)
        J.write_nbit!(w, 10, 2, 4)
        for aligned in (false, true)
            bytes = enc(w -> J.write_nbit!(w, -12, -200, 8); aligned)
            @test J.read_nbit!(reader(bytes; aligned), -200, 8) == -12
        end
        @test enc(w -> J.write_nbit!(w, -12, -200, 8)) == [188]
        @test_throws J.ValueError J.write_nbit!(J.BitWriter(), big(2)^70, 0, 12)
        @test_throws J.ValueError J.write_nbit!(J.BitWriter(), typemin(Int64), typemax(Int64), 1)
        @test_throws J.ValueError J.write_nbit!(J.BitWriter(), typemax(Int64), typemin(Int64), 1)
        J.write_nbit!(J.BitWriter(), 0, 0, 0)
    end

    @testset "boolean" begin
        r = reader(UInt8[0xd4, 0x60])
        @test J.read_boolean!(r)
        @test J.bit_position(r) == 1
        @test enc(w -> J.write_boolean!(w, true))[1] >> 7 == 1
        for (s, expected) in (("0", false), ("1", true), ("false", false), ("true", true))
            @test J.parse_boolean(s) === expected
        end
        for s in ("00", "fAlse", " true")
            @test J.parse_boolean(s) === nothing
        end
        for (s, id) in (("false", 0), ("0", 1), ("true", 2), ("1", 3)), aligned in (false, true)
            @test J.parse_boolean_pattern(s) == id
            bytes = enc(w -> J.write_boolean_pattern!(w, id); aligned)
            @test J.read_boolean_pattern!(reader(bytes; aligned)) == id
        end
        @test J.parse_boolean_pattern("TRUE") === nothing
        @test enc(w -> (J.write_boolean_pattern!(w, 3); J.write_boolean_pattern!(w, 1))) == [0b1101_0000]
        @test enc(w -> J.write_boolean_pattern!(w, 2); aligned = true) == [0x02]
        @test enc(w -> J.write_boolean!(w, true); aligned = true) == [0x01]
    end

    @testset "string" begin
        bytes = enc(w -> J.write_string!(w, "TEST encodeString()"))
        @test bytes[1] == 19
        @test bytes[2:3] == b"TE"
        @test length(bytes) == 20
        @test J.read_string!(reader(UInt8[0x02, 0x65, 0x54])) == "eT"
        bytes = enc(w -> J.write_string!(w, "héllo €"))
        @test bytes[1] == 7
        @test J.read_string!(reader(bytes)) == "héllo €"
        # A surrogate code point in the stream is refused.
        bytes = enc(w -> (J.write_unsigned!(w, UInt64(1)); J.write_unsigned!(w, UInt64(0xd800))))
        @test_throws J.ValueError J.read_string!(reader(bytes))
        @test_throws J.ValueError J.write_string!(J.BitWriter(), String(UInt8[0xff]))
    end

    dec_round(d; aligned = false) =
        J.decimal_to_lexical(J.read_decimal!(reader(enc(w -> J.write_decimal!(w, d); aligned); aligned)))

    @testset "decimal" begin
        r = reader(UInt8[0x02, 0xb2, 0x12])
        d = J.read_decimal!(r)
        @test d == J.ExiDecimal(false, 5, 100)
        @test J.decimal_to_lexical(d) == "5.001"
        @test J.bit_position(r) == 17
        bytes = enc(w -> J.write_decimal!(w, J.ExiDecimal(false, 5, 100)))
        @test length(bytes) == 3 && bytes[1:2] == [0x02, 0xb2] && bytes[3] >> 7 == 0
        parts(s) = (d = J.decimal_from_lexical(s); (d.negative, string(d.integral), string(d.fraction_reversed)))
        @test parts("31.50") == (false, "31", "5")
        @test parts("42.95") == (false, "42", "59")
        @test parts("-0.5") == (true, "0", "5")
        @test parts("5") == (false, "5", "0")
        @test parts("+100000.0012") == (false, "100000", "2100")
        @test parts("0.001359") == (false, "0", "953100")
        @test J.decimal_to_lexical(J.ExiDecimal(false, 31, 5)) == "31.5"
        @test J.decimal_to_lexical(J.ExiDecimal(true, 0, 5)) == "-0.5"
        @test J.decimal_to_lexical(J.decimal_from_int(-7)) == "-7.0"
        @test J.decimal_to_lexical(J.decimal_from_int(0)) == "0.0"
        @test J.decimal_to_lexical(J.decimal_from_int(UInt64(42))) == "42.0"
        long = "123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890.1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678912345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
        for (input, expected) in (("-1.23", "-1.23"), ("12678967.543233", "12678967.543233"),
            ("+100000.0012", "100000.0012"), ("210", "210.0"), ("380", "380.0"), ("0.001359", "0.001359"),
            ("110.74080", "110.7408"), ("55000.0", "55000.0"), ("3.141592653589", "3.141592653589"),
            ("-.1", "-0.1"), ("-.234", "-0.234"),
            ("36.087139166666670000000000000000001", "36.087139166666670000000000000000001"),
            (long, long), ("-1.3", "-1.3"),
            ("1236.087139166666670000000000000000001", "1236.087139166666670000000000000000001"),
            ("-65.12033898980989080", "-65.1203389898098908"))
            d = J.decimal_from_lexical(input)
            @test d !== nothing
            @test J.decimal_to_lexical(d) == expected
            @test dec_round(d) == expected
            @test dec_round(d; aligned = true) == expected
        end
        zero = J.ExiDecimal(false, 0, 0)
        for s in ("-0.0", "+0.0", "0.0", "+.0", "-0", "0")
            @test J.decimal_from_lexical(s) == zero
        end
        @test J.decimal_to_lexical(zero) == "0.0"
        for s in ("9.213.456", "", "-", "+", ".", "1a", "1.2a", "--1", "1.-2", " 1", "1 ")
            @test J.decimal_from_lexical(s) === nothing
        end
        @test J.decimal_to_lexical(J.decimal_from_lexical("5.")) == "5.0"
        d = J.decimal_from_lexical("-18446744073709551616.00000000000000000000123")
        @test d.integral isa BigInt && d.fraction_reversed isa BigInt
        @test dec_round(d) == "-18446744073709551616.00000000000000000000123"
        @test enc(w -> J.write_decimal!(w, J.decimal_from_lexical("-1.23")); aligned = true) == [0x01, 0x01, 0x20]
        @test J.read_decimal!(reader(UInt8[0x01, 0x00, 0x00]; aligned = true)) == zero
    end

    float_round(f; aligned = false) = J.read_float!(reader(enc(w -> J.write_float!(w, f); aligned); aligned))

    @testset "float" begin
        r = reader(UInt8[0x02, 0x80, 0x92])
        @test J.read_float!(r) == J.ExiFloat(5, 2)
        @test J.bit_position(r) == 18
        bytes = enc(w -> J.write_float!(w, J.ExiFloat(5, 2)))
        @test length(bytes) == 3 && bytes[1:2] == [0x02, 0x80] && bytes[3] & 0xc0 == 0x80
        for (input, m, e, canonical) in (("NaN", 0, -16384, "NaN"), ("INF", 1, -16384, "INF"),
            ("-INF", -1, -16384, "-INF"), ("-1E4", -1, 4, "-1E4"), ("1267.43233E12", 126_743_233, 7, "126743233E7"),
            ("12.78e-2", 1278, -4, "1278E-4"), ("12", 12, 0, "12E0"), ("0", 0, 0, "0E0"), ("-0", 0, 0, "0E0"),
            ("-1", -1, 0, "-1E0"), ("119.999999999929", 119_999_999_999_929, -12, "119999999999929E-12"),
            ("000123400.0031200", 12_340_000_312, -5, "12340000312E-5"),
            ("562949953421312", 562_949_953_421_312, 0, "562949953421312E0"),
            ("-9223372036854775808E123", typemin(Int64), 123, "-9223372036854775808E123"),
            ("9223372036854775807E123", typemax(Int64), 123, "9223372036854775807E123"),
            ("456E-16383", 456, -16383, "456E-16383"), ("456E16383", 456, 16383, "456E16383"),
            ("85.00", 85, 0, "85E0"), ("44.10", 441, -1, "441E-1"), ("73.25", 7325, -2, "7325E-2"),
            ("19.5", 195, -1, "195E-1"), ("1.0E3", 1, 3, "1E3"))
            f = J.float_from_lexical(input)
            @test f == J.ExiFloat(m, e)
            @test J.float_to_lexical(f) == canonical
            @test float_round(f) == f
            @test float_round(f; aligned = true) == f
        end
        p = J.float_from_lexical
        @test p("234E2") == p("2340E1")
        @test p("30E0") == p("3E1")
        @test p("123.012300") == J.ExiFloat(1_230_123, -4)
        @test p("0.0") == J.ExiFloat(0, 0) == p("-0.0")
        @test p("1.0") == J.ExiFloat(1, 0)
        @test p("-1230.01") == J.ExiFloat(-123_001, -2)
        @test p("0.1230") == J.ExiFloat(123, -3)
        for s in ("12.0", "120E-1", "1.2E1")
            @test p(s) == J.ExiFloat(12, 0)
        end
        @test p("12300") == J.ExiFloat(123, 2)
        @test p("234E3") != p("2340E1")
        @test J.float_normalized(0, 12) == J.ExiFloat(0, 0)
        @test J.float_normalized(2, 120) == J.ExiFloat(2, 120)
        @test J.float_normalized(12300, 0) == J.ExiFloat(123, 2)
        @test J.float_normalized(7, -16384) == J.FLOAT_NAN
        @test J.float_normalized(-1, -16384) == J.FLOAT_NEG_INFINITY
        @test J.float_normalized(1, 16384) === nothing
        @test J.float_normalized(1, -16385) === nothing
        for s in ("x11.1", "", "1.1223x", "E", "9223372036854775808E3", "9223372036854775809E3", "123E16384",
            "-9223372036854775809E3", "123E-16384", "123E-+16384", "-", "+", ".",
            "1E", "1E1+2", "1.2.3", " 1", "1 ", "inf", "nan", "99999999999999999999", "10E16383")
            @test p(s) === nothing
        end
        # Trailing zeros go into the exponent as they are read, so a big whole
        # number written out in full no longer overflows the mantissa.
        @test p("10000000000000000000") == J.ExiFloat(1, 19) == p("1E19")
        @test p("-10000000000000000000.0") == J.ExiFloat(-1, 19)
        @test p("179769313486231570" * "0"^291) == J.ExiFloat(17976931348623157, 292)
        @test p("0." * "0"^40 * "1") == J.ExiFloat(1, -41)
        @test p("1001000") == J.ExiFloat(1001, 3)
        # EXIficient's list calls this invalid only because its mantissa overflows.
        @test p("-9223372036854775810E3") == J.ExiFloat(-922337203685477581, 4)
        @test p("3.141592653589793238462643") === nothing
        # 1200E-2 on the wire decodes as 12E0.
        bytes = enc(w -> (J.write_integer!(w, 1200); J.write_integer!(w, -2)))
        @test J.read_float!(reader(bytes)) == J.ExiFloat(12, 0)
        @test enc(w -> J.write_float!(w, J.ExiFloat(7325, -2)); aligned = true) == [0x00, 0x9d, 0x39, 0x01, 0x01]
        @test enc(w -> J.write_float!(w, J.FLOAT_INFINITY); aligned = true) == [0x00, 0x01, 0x01, 0xff, 0x7f]
        @test float_round(J.FLOAT_NAN; aligned = true) == J.FLOAT_NAN
        @test float_round(J.FLOAT_NEG_INFINITY) == J.FLOAT_NEG_INFINITY
    end

    @testset "binary" begin
        data = UInt8[0x22, 0x65, 0xd4, 0x5a, 0xd7]
        @test enc(w -> J.write_binary!(w, data)) == [0x05; data]
        @test enc(w -> J.write_binary!(w, data); aligned = true) == [0x05; data]
        stream = UInt8[0x05, 0xf0, 0xcc, 0xaa, 0x55, 0x33, 0x08, 0x6e, 0xca, 0x59, 0xd8, 0x59, 0xca, 0x6c, 0xd8, 0x07]
        r = reader(stream)
        @test J.read_binary!(r) == [0xf0, 0xcc, 0xaa, 0x55, 0x33]
        @test J.bit_position(r) == 48
        @test J.read_binary!(r) == [0x6e, 0xca, 0x59, 0xd8, 0x59, 0xca, 0x6c, 0xd8]
        @test J.bit_position(r) == 120
        @test J.parse_hex("0FB7") == [0x0f, 0xb7]
        @test J.format_hex([0x0f, 0xb7]) == "0FB7"
        bytes = J.parse_hex(repeat("0123456789ABCDEFabcdef", 20))
        @test length(bytes) == 220
        @test J.format_hex(bytes) == repeat("0123456789ABCDEFABCDEF", 20)
        for s in ("ZHM=", "R0lGODlhAgSzzs7O3t7e", "0FB", "0F B7", "0G")
            @test J.parse_hex(s) === nothing
        end
        @test J.parse_hex("") == UInt8[]
        @test J.format_hex(UInt8[]) == ""
        s1 = "R0lGODdhWAK+ov////v7++fn58DAwI6Ojl5eXjExMQMDAyxYAr5AA/8Iutz+MMpJq7046827/2Ao"
        s2 = "jmRpnmiqPsKxvvBqCIxgxHg="
        for (input, expected) in (("0FB7", "0FB7"), ("  0  F B 7 ", "0FB7"), ("ZHM=", "ZHM="),
            ("SMOkdHRlbiBIw7x0ZSBlaW4gw58gaW0gTmFtZW4sIHfDpHJlbiBzaWUgbcO2Z2xpY2hlcndlaXNlIGtlaW5lIEjDvHRlIG1laHIsDQpzb25kZXJuIEjDvMOfZS4NCg==",
                "SMOkdHRlbiBIw7x0ZSBlaW4gw58gaW0gTmFtZW4sIHfDpHJlbiBzaWUgbcO2Z2xpY2hlcndlaXNlIGtlaW5lIEjDvHRlIG1laHIsDQpzb25kZXJuIEjDvMOfZS4NCg=="),
            ("$s1\n \n $s2", s1 * s2))
            bytes = J.parse_base64(input)
            @test bytes !== nothing
            @test J.format_base64(bytes) == expected
            for aligned in (false, true)
                back = J.read_binary!(reader(enc(w -> J.write_binary!(w, bytes); aligned); aligned))
                @test J.format_base64(back) == expected
            end
        end
        @test J.parse_base64("ZHM=") == b"ds"
        for s in ("0FB7 x", "0FB", "ZHM", "Z===", "ZH=M", "ZHM-", "0FB7=", "ZHN=", "ZQ=A")
            @test J.parse_base64(s) === nothing
        end
        @test J.parse_base64("") == UInt8[]
        @test J.parse_base64(" \n") == UInt8[]
        @test J.format_base64(b"f") == "Zg=="
        @test J.format_base64(b"fo") == "Zm8="
        @test J.format_base64(b"foo") == "Zm9v"
        @test J.format_base64(b"foobar") == "Zm9vYmFy"
        @test J.parse_base64("Zg==") == b"f"
        for s in ("blabla", "X", ""), aligned in (false, true)
            stream = enc(; aligned) do w
                J.write_nbit_unsigned!(w, UInt64(2), 3)
                J.write_binary!(w, Vector{UInt8}(s))
                J.write_nbit_unsigned!(w, UInt64(5), 7)
            end
            r = reader(stream; aligned)
            @test J.read_nbit_unsigned!(r, 3) == 2
            @test J.read_binary!(r) == Vector{UInt8}(s)
            @test J.read_nbit_unsigned!(r, 7) == 5
        end
        big = UInt8[i % UInt8 for i in 0:199_999]
        @test J.read_binary!(reader(enc(w -> J.write_binary!(w, big)))) == big
        @test_throws J.TruncatedError J.read_binary!(reader(UInt8[0xff, 0xff, 0x7f, 0x00]))
    end

    K = J
    dt_lex(kind, s) = J.datetime_from_lexical(kind, s)
    function check_dt(kind, input, expected)
        dt = dt_lex(kind, input)
        @test dt !== nothing
        dt === nothing && return
        @test J.datetime_to_lexical(dt) == expected
        for aligned in (false, true)
            back = J.read_datetime!(reader(enc(w -> J.write_datetime!(w, dt); aligned); aligned), kind)
            @test J.datetime_to_lexical(back) == expected
        end
    end

    @testset "date-time" begin
        for (k, i, e) in ((K.DTK_GYEAR, "2007", "2007"), (K.DTK_GYEAR, "-0007", "-0007"), (K.DTK_GYEAR, "2001Z", "2001Z"),
            (K.DTK_GYEAR, "2001+05:00", "2001+05:00"), (K.DTK_GYEAR, "2009-13:59", "2009-13:59"),
            (K.DTK_GYEARMONTH, "1999-10", "1999-10"), (K.DTK_GYEARMONTH, "2007-10", "2007-10"),
            (K.DTK_GYEARMONTH, "1999-10-12:11", "1999-10-12:11"), (K.DTK_GYEARMONTH, "1809-10+00:33", "1809-10+00:33"),
            (K.DTK_GYEARMONTH, "1809-02Z", "1809-02Z"), (K.DTK_DATE, "2002-10-11+13:00", "2002-10-11+13:00"),
            (K.DTK_DATE, "0100-10-11-00:50", "0100-10-11-00:50"),
            (K.DTK_DATETIME, "0001-01-01T01:03:12", "0001-01-01T01:03:12"),
            (K.DTK_DATETIME, "2005-01-01T00:00:00Z", "2005-01-01T00:00:00Z"),
            (K.DTK_DATETIME, "1979-01-01T00:00:00.0120", "1979-01-01T00:00:00.012"),
            (K.DTK_DATETIME, "0001-01-01T00:00:00.111+00:33", "0001-01-01T00:00:00.111+00:33"),
            (K.DTK_DATETIME, "2009-04-01T12:34:56Z", "2009-04-01T12:34:56Z"), (K.DTK_GMONTH, "--12", "--12"),
            (K.DTK_GMONTH, "--07Z", "--07Z"), (K.DTK_GMONTH, "--07+12:34", "--07+12:34"),
            (K.DTK_GMONTH, "--07--+09:00", "--07+09:00"), (K.DTK_GMONTHDAY, "--01-28", "--01-28"),
            (K.DTK_GMONTHDAY, "--10-17+00:00", "--10-17Z"), (K.DTK_GDAY, "---16", "---16"),
            (K.DTK_TIME, "12:34:56", "12:34:56"), (K.DTK_TIME, "12:34:56.135", "12:34:56.135"),
            (K.DTK_TIME, "12:34:56.135-12:56", "12:34:56.135-12:56"),
            # Hour 24 rolls over to the next day.
            (K.DTK_DATETIME, "2015-08-11T24:00:00-07:30", "2015-08-12T00:00:00-07:30"),
            (K.DTK_DATETIME, "2015-08-11T24:00:00", "2015-08-12T00:00:00"),
            (K.DTK_DATETIME, "1999-12-31T24:00:00Z", "2000-01-01T00:00:00Z"),
            (K.DTK_DATETIME, "2015-08-31T24:00:00", "2015-09-01T00:00:00"),
            (K.DTK_DATETIME, "2012-02-28T24:00:00", "2012-02-29T00:00:00"),
            (K.DTK_DATETIME, "2013-02-28T24:00:00", "2013-03-01T00:00:00"), (K.DTK_TIME, "24:00:00", "00:00:00"),
            (K.DTK_DATETIME, "2026-04-15T17:45:00Z", "2026-04-15T17:45:00Z"),
            (K.DTK_DATETIME, "2001-10-26T21:32:52.12679+02:00", "2001-10-26T21:32:52.12679+02:00"),
            (K.DTK_GMONTH, "--05", "--05"), (K.DTK_GDAY, "---12", "---12"), (K.DTK_GYEARMONTH, "2001-10", "2001-10"),
            (K.DTK_GYEAR, "2001", "2001"), (K.DTK_GYEAR, "12345", "12345"), (K.DTK_GYEAR, "-12345Z", "-12345Z"),
            (K.DTK_DATETIME, "2001-10-26T21:32:52.000", "2001-10-26T21:32:52"),
            (K.DTK_DATETIME, "2001-10-26T21:32:52.5", "2001-10-26T21:32:52.5"),
            (K.DTK_DATETIME, "2001-10-26T21:32:52.05", "2001-10-26T21:32:52.05"),
            (K.DTK_DATETIME, "2001-10-26T21:32:52.50", "2001-10-26T21:32:52.5"), (K.DTK_TIME, "23:59:60", "23:59:60"))
            check_dt(k, i, e)
        end
        @test dt_lex(K.DTK_TIME, "12:34:XXX") === nothing
        dt = dt_lex(K.DTK_DATETIME, "2015-08-11T24:00:00-07:30")
        @test (dt.month, dt.day, dt.hour, dt.minute, dt.second) == (8, 12, 0, 0, 0)
        dt = dt_lex(K.DTK_DATETIME, "2001-10-26T21:32:52.12679+02:00")
        @test dt.fractional_secs == 97621 && dt.timezone == 120
        dt = dt_lex(K.DTK_GDAY, "---12")
        @test (dt.month, dt.day) == (0, 12)
        dt = dt_lex(K.DTK_GMONTH, "--05")
        @test (dt.month, dt.day) == (5, 0)
        # The decoder fixes hour 24 too; the encoder fixes it first, so it never
        # writes hour 24.
        raw = J.ExiDateTime(K.DTK_DATETIME; year = 2015, month = 8, day = 11, hour = 24)
        fixed = J.ExiDateTime(K.DTK_DATETIME; year = 2015, month = 8, day = 12)
        bytes = enc() do w
            J.write_integer!(w, 15)
            J.write_nbit_unsigned!(w, UInt64(8 * 32 + 11), 9)
            J.write_nbit_unsigned!(w, UInt64(24 * 64 * 64), 17)
            J.write_bool!(w, false)
            J.write_bool!(w, false)
        end
        @test bytes != enc(w -> J.write_datetime!(w, raw))
        @test enc(w -> J.write_datetime!(w, raw)) == enc(w -> J.write_datetime!(w, fixed))
        @test J.datetime_to_lexical(J.read_datetime!(reader(bytes), K.DTK_DATETIME)) == "2015-08-12T00:00:00"
        for (k, s) in ((K.DTK_GYEAR, "207"), (K.DTK_GYEAR, "2007-"), (K.DTK_GYEAR, "2007+5:00"),
            (K.DTK_GYEAR, "2007+05:00x"), (K.DTK_GYEAR, "2007+15:00"), (K.DTK_GYEAR, "2007+05:60"),
            (K.DTK_GYEAR, " 2007"), (K.DTK_GYEARMONTH, "2007-13"), (K.DTK_GYEARMONTH, "2007-00"),
            (K.DTK_DATE, "2007-01-32"), (K.DTK_DATE, "2007-01-00"), (K.DTK_DATE, "2007-01-01T"),
            (K.DTK_DATETIME, "2007-01-01 10:00:00"), (K.DTK_DATETIME, "2007-01-01T25:00:00"),
            (K.DTK_DATETIME, "2007-01-01T10:60:00"), (K.DTK_DATETIME, "2007-01-01T10:00:61"),
            (K.DTK_DATETIME, "2007-01-01T10:00:00."), (K.DTK_TIME, "12:34"), (K.DTK_TIME, "12:34:56:78"),
            (K.DTK_GMONTH, "-12"), (K.DTK_GMONTH, "--12-"), (K.DTK_GMONTHDAY, "--12"), (K.DTK_GDAY, "--12"),
            (K.DTK_GDAY, "---1"))
            @test dt_lex(k, s) === nothing
        end
        gy = dt_lex(K.DTK_GYEAR, "2001Z")
        @test enc(w -> J.write_datetime!(w, gy)) == [0x00, 0xdc, 0x00]
        @test enc(w -> J.write_datetime!(w, gy); aligned = true) == [0x00, 0x01, 0x01, 0x80, 0x03]
        @test J.timezone_to_wire(Int16(0)) == 896
        @test J.timezone_to_wire(Int16(33)) == 929
        @test J.timezone_to_wire(Int16(-839)) == 5
        @test J.timezone_to_wire(Int16(840)) == 896 + 896
        @test J.timezone_to_wire(Int16(-840)) == 0
        for tz in Int16[-840, -839, -50, -1, 0, 1, 33, 120, 839, 840]
            @test J.timezone_from_wire(J.timezone_to_wire(tz)) == tz
        end
        gd = dt_lex(K.DTK_GDAY, "---16")
        @test enc(w -> J.write_datetime!(w, gd)) == [0b0000_1000, 0b0000_0000]
        @test enc(w -> J.write_datetime!(w, gd); aligned = true) == [16, 0, 0]
        t = dt_lex(K.DTK_TIME, "12:34:56.135")
        @test enc(w -> J.write_datetime!(w, t); aligned = true) == [0xb8, 0xc8, 0x00, 0x01, 0x93, 0x04, 0x00]
        @test_throws J.ValueError J.write_datetime!(J.BitWriter(), J.ExiDateTime(K.DTK_DATE; month = 13, day = 1))
        @test_throws J.ValueError J.write_datetime!(J.BitWriter(), J.ExiDateTime(K.DTK_DATE; month = 1, day = 1, timezone = 841))
        J.write_datetime!(J.BitWriter(), J.ExiDateTime(K.DTK_GYEAR; year = 2001, month = 99, day = 99, hour = 99))
        # "31:60:09" fits the 17-bit field but is no time (found by fuzzing rexi).
        bytes = enc(w -> (J.write_nbit_unsigned!(w, UInt64((31 * 64 + 60) * 64 + 9), 17); J.write_bool!(w, false); J.write_bool!(w, false)))
        @test_throws J.ValueError J.read_datetime!(reader(bytes), K.DTK_TIME)
        @test enc(w -> J.write_datetime!(w, J.ExiDateTime(K.DTK_TIME; hour = 1, fractional_secs = 0))) ==
              enc(w -> J.write_datetime!(w, J.ExiDateTime(K.DTK_TIME; hour = 1)))
    end

    @testset "whitespace facets" begin
        @test J.apply_whitespace(J.WS_PRESERVE, " a\tb ") == " a\tb "
        @test J.apply_whitespace(J.WS_REPLACE, "ab") == "ab"
        @test J.apply_whitespace(J.WS_REPLACE, " a\tb\r\nc ") == " a b  c "
        @test J.apply_whitespace(J.WS_COLLAPSE, "a b") == "a b"
        @test J.apply_whitespace(J.WS_COLLAPSE, "  a \t b\n\nc  ") == "a b c"
        @test J.apply_whitespace(J.WS_COLLAPSE, " \n ") == ""
        @test J.apply_whitespace(J.WS_COLLAPSE, "") == ""
    end

    lenc(kind, value; aligned = false) = enc(w -> J.write_scalar!(w, kind, value, Mock()); aligned)
    ldec(kind, bytes; aligned = false) = J.read_scalar!(reader(bytes; aligned), kind, Mock())

    @testset "lexical and typed values encode the same" begin
        date = J.datetime_from_lexical(J.DTK_DATE, "2026-04-15")
        cases = Any[(J.BOOLEAN_KIND, true, " true "), (J.BOOLEAN_KIND, false, "0"),
            (J.BOOLEAN_PATTERN_KIND, true, "\ttrue\n"), (J.INTEGER_KIND, -913, " -913 "),
            (J.INTEGER_KIND, UInt64(40), "+40"), (J.UNSIGNED_KIND, UInt64(421), "421"),
            (J.UNSIGNED_KIND, 421, " 421"), (J.nbit_kind(-200, 8), -12, "-12"),
            (J.DECIMAL_KIND, J.ExiDecimal(false, 5, 100), "5.001"), (J.DECIMAL_KIND, -7, "-7.0"),
            (J.FLOAT_KIND, J.ExiFloat(7325, -2), " 73.25 "), (J.datetime_kind(J.DTK_DATE), date, "2026-04-15"),
            (J.HEX_KIND, UInt8[0x0f, 0xb7], " 0fb7 "), (J.BASE64_KIND, UInt8[0x0f, 0xb7], "D7c=\n"),
            (J.enum_kind(0, 1), J.EnumOrdinal(1), "  green "), (J.enum_kind(1, 0), J.EnumOrdinal(3), "+10"),
            (J.enum_kind(2, 3), J.EnumOrdinal(1), "02.50"), (J.enum_kind(2, 3), J.ExiDecimal(false, 1, 0), "1")]
        for (kind, typed, lexical) in cases, aligned in (false, true)
            a = lenc(kind, typed; aligned)
            b = lenc(kind, J.Lexical(lexical); aligned)
            @test a == b
            decoded = ldec(kind, a; aligned)
            @test J.format_value(kind, decoded, Mock()) == J.format_value(kind, typed, Mock())
        end
    end

    @testset "exact bytes" begin
        @test lenc(J.INTEGER_KIND, J.Lexical("-913")) == [0xc8, 0x03, 0x80]
        @test lenc(J.INTEGER_KIND, J.Lexical("-913"); aligned = true) == [0x01, 0x90, 0x07]
        @test lenc(J.DECIMAL_KIND, J.Lexical("5.001"))[1:2] == [0x02, 0xb2]
        @test lenc(J.FLOAT_KIND, J.Lexical("500"))[1:2] == [0x02, 0x80]
        @test lenc(J.enum_kind(0, 1), J.Lexical("blue")) == [0b1000_0000]
        @test lenc(J.enum_kind(1, 0), J.Lexical("3"); aligned = true) == [0x02]
        @test lenc(J.BOOLEAN_PATTERN_KIND, J.Lexical("1")) == [0b1100_0000]
        @test lenc(J.BOOLEAN_PATTERN_KIND, J.Lexical("0")) == [0b0100_0000]
        @test lenc(J.BASE64_KIND, J.Lexical("ZHM=")) == [0x02, UInt8('d'), UInt8('s')]
    end

    @testset "type checks and errors" begin
        date = J.datetime_from_lexical(J.DTK_GYEAR, "2026")
        for (kind, value) in Any[(J.UNSIGNED_KIND, -1), (J.UNSIGNED_KIND, J.Lexical("-1")),
            (J.nbit_kind(2, 4), J.Lexical("18")), (J.nbit_kind(2, 4), 1), (J.FLOAT_KIND, 1),
            (J.FLOAT_KIND, J.Lexical("1.2.3")), (J.BOOLEAN_KIND, J.Lexical("yes")), (J.BOOLEAN_KIND, 1),
            (J.INTEGER_KIND, true), (J.DECIMAL_KIND, J.Lexical("abc")), (J.DECIMAL_KIND, true),
            (J.HEX_KIND, J.Lexical("0F B7")), (J.BASE64_KIND, J.Lexical("0FB7 x")),
            (J.enum_kind(0, 1), J.Lexical("purple")), (J.enum_kind(0, 1), J.EnumOrdinal(3)),
            (J.enum_kind(1, 0), J.Lexical("4")), (J.datetime_kind(J.DTK_DATE), J.Lexical("2026")),
            (J.datetime_kind(J.DTK_DATE), date)]
            @test_throws J.ValueError lenc(kind, value)
        end
        for kind in (J.string_kind(J.WS_PRESERVE), J.UNTYPED_KIND, J.QNAME_KIND, J.list_kind(0))
            @test_throws J.InternalError lenc(kind, J.Lexical("x"))
            @test_throws J.InternalError ldec(kind, UInt8[0])
        end
        @test_throws J.ValueError ldec(J.enum_kind(0, 1), UInt8[0b1100_0000])
    end

    @testset "parse and format" begin
        m = Mock()
        list = J.parse_lexical(J.list_kind(0), " 1  -2\n3 ", m)
        @test list == J.ExiList(Any[1, -2, 3])
        @test J.format_value(J.list_kind(0), list, m) == "1 -2 3"
        @test J.format_value(J.list_kind(0), J.Lexical(" 1  -2\n3 "), m) == "1 -2 3"
        @test J.parse_lexical(J.list_kind(0), "", m) == J.ExiList(Any[])
        @test_throws J.ValueError J.parse_lexical(J.list_kind(0), "1 x", m)
        @test J.parse_lexical(J.string_kind(J.WS_COLLAPSE), " a  b ", m) == "a b"
        @test J.parse_lexical(J.UNTYPED_KIND, " a  b ", m) == " a  b "
        @test J.parse_lexical(J.enum_kind(0, 1), "blue", m) == J.EnumOrdinal(2)
        @test J.parse_lexical(J.enum_kind(2, 3), "+1.00", m) == J.EnumOrdinal(0)
        @test J.parse_lexical(J.BOOLEAN_PATTERN_KIND, "1", m) === true
        @test J.parse_lexical(J.FLOAT_KIND, " 1.0E3 ", m) == J.ExiFloat(1, 3)
        @test_throws J.ValueError J.parse_lexical(J.QNAME_KIND, "a:b", m)
        @test J.format_value(J.enum_kind(0, 1), J.EnumOrdinal(1), m) == "green"
        @test_throws J.ValueError J.format_value(J.enum_kind(0, 1), J.EnumOrdinal(9), m)
        @test J.format_value(J.FLOAT_KIND, J.Lexical("12.0"), m) == "12E0"
        @test J.format_value(J.DECIMAL_KIND, J.Lexical("-.50"), m) == "-0.5"
        @test J.format_value(J.DECIMAL_KIND, -7, m) == "-7.0"
        @test J.format_value(J.INTEGER_KIND, -7, m) == "-7"
        @test J.format_value(J.HEX_KIND, UInt8[0xab], m) == "AB"
        @test J.format_value(J.BASE64_KIND, b"foo", m) == "Zm9v"
        @test_throws J.ValueError J.format_value(J.INTEGER_KIND, b"foo", m)
        @test J.format_value(J.BOOLEAN_KIND, J.Lexical("1"), m) == "true"
        @test J.format_value(J.datetime_kind(J.DTK_TIME), J.Lexical("12:00:00+00:00"), m) == "12:00:00Z"
    end

    @testset "read_scalar, all kinds" begin
        for (kind, value) in Any[(J.BOOLEAN_KIND, true), (J.BOOLEAN_PATTERN_KIND, false), (J.INTEGER_KIND, -41),
            (J.UNSIGNED_KIND, UInt64(12372)), (J.nbit_kind(0, 12), 4095), (J.DECIMAL_KIND, J.ExiDecimal(true, 1, 32)),
            (J.FLOAT_KIND, J.FLOAT_NEG_INFINITY), (J.HEX_KIND, UInt8[1, 2, 3]), (J.enum_kind(1, 0), J.EnumOrdinal(2))],
            aligned in (false, true)
            @test ldec(kind, lenc(kind, value; aligned); aligned) == value
        end
        dt = J.datetime_from_lexical(J.DTK_DATETIME, "2026-04-15T17:45:00.5+02:00")
        kind = J.datetime_kind(J.DTK_DATETIME)
        @test ldec(kind, lenc(kind, dt)) == dt
    end
end
