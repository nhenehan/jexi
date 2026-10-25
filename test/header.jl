# The EXI header, the options document and the codec over the options grammar,
# ported from rexi-core/tests/header_options.rs and the rexi-core crate example.
# The byte strings were confirmed against EXIficient 1.0.7 (and RFC 8428's SenML
# examples) in rexi.
import JExi as J

function header_bytes(o; cookie = false, include_options = false)
    w = J.BitWriter()
    J.write_header_bits!(w, J.HeaderConfig(; cookie, include_options))
    include_options && J.write_options_document!(w, o)
    return J.finish!(w)
end

function decode_header(bytes)
    r = J.BitReader(bytes)
    info = J.read_header_bits!(r)
    opts = info.options_in_stream ? J.read_options_document!(r) : nothing
    return (info.cookie, opts, J.bit_position(r))
end

@testset "header and options" begin
    @testset "bare header is 0x80" begin
        @test header_bytes(J.strict_options()) == [0x80]
        @test header_bytes(J.strict_options(); cookie = true) == [0x24, 0x45, 0x58, 0x49, 0x80]
        @test decode_header(UInt8[0x80]) == (false, nothing, 8)
        @test decode_header(UInt8[0x24, 0x45, 0x58, 0x49, 0x80]) == (true, nothing, 40)
    end

    @testset "strict-only options document" begin
        # 10 1 0 0000 | 0 (SE header) 10 (SE strict) | pad
        @test header_bytes(J.strict_options(); include_options = true) == [0xa0, 0x40]
        @test decode_header(UInt8[0xa0, 0x40]) == (false, J.strict_options(), 11)
    end

    @testset "RFC 8428 schemaId a" begin
        o = J.strict_options(schema_id = "a")
        @test header_bytes(o; include_options = true) == [0xa0, 0x30, 0x0d, 0x84]
        @test decode_header(UInt8[0xa0, 0x30, 0x0d, 0x84]) == (false, o, 31)
        o = J.strict_options(schema_id = "a", alignment = J.ALIGN_BYTE_ALIGNED)
        @test header_bytes(o; include_options = true) == [0xa0, 0x00, 0x48, 0x80, 0x6c, 0x20]
        @test decode_header(UInt8[0xa0, 0x00, 0x48, 0x80, 0x6c, 0x20])[2] == o
    end

    @testset "EXIficient value limits vector" begin
        o = J.strict_options(schema_id = "a", value_max_length = 12, value_partition_capacity = 66)
        bytes = header_bytes(o; include_options = true)
        @test bytes == [0xa0, 0x02, 0x0c, 0x10, 0xb1, 0x00, 0xd8, 0x40]
        @test decode_header(bytes) == (false, o, 59)
    end

    @testset "other options round trip" begin
        for o in (J.strict_options(schema_id = J.SCHEMA_ID_NIL), J.strict_options(schema_id = ""),
            J.strict_options(block_size = 500),
            J.strict_options(alignment = J.ALIGN_BYTE_ALIGNED, value_max_length = 0, value_partition_capacity = 0))
            @test decode_header(header_bytes(o; include_options = true))[2] == o
        end
    end

    @testset "unsupported options are rejected, not ignored" begin
        @test_throws J.UnsupportedError(J.FEATURE_COMPRESSION) J.validate_options(J.strict_options(compression = true))
        @test_throws J.UnsupportedError(J.FEATURE_PRE_COMPRESSION) J.validate_options(
            J.strict_options(alignment = J.ALIGN_PRE_COMPRESSION))
        @test_throws J.UnsupportedError(J.FEATURE_NON_STRICT_SCHEMA_INFORMED) J.validate_options(J.ExiOptions())
        @test_throws J.HeaderError J.validate_options(J.strict_options(preserve = J.Preserve(comments = true)))
        @test_throws J.UnsupportedError(J.FEATURE_PRESERVE_LEXICAL_VALUES) J.validate_options(
            J.strict_options(preserve = J.Preserve(lexical_values = true)))
        @test_throws J.UnsupportedError J.Encoder(J.OPTIONS_GRAMMARS, J.strict_options(fragment = true))
    end

    @testset "bad headers" begin
        @test_throws J.HeaderError J.read_header_bits!(J.BitReader(UInt8[0x40]))
        @test_throws J.HeaderError J.read_header_bits!(J.BitReader(UInt8[0x24, 0x45, 0x58, 0x58, 0x80]))
        # preview version
        @test_throws J.UnsupportedError(J.FEATURE_FORMAT_VERSION) J.read_header_bits!(J.BitReader(UInt8[0x90]))
        @test_throws J.HeaderError J.Decoder(UInt8[0x80], J.OPTIONS_GRAMMARS)
    end

    @testset "codec over the options grammar" begin
        # The rexi-core crate example: <header><strict/></header>, options out of band.
        ns = J.EXI_OPTIONS_NS
        enc = J.Encoder(J.OPTIONS_GRAMMARS)
        J.start_document!(enc)
        J.start_element!(enc, ns, "header")
        J.start_element!(enc, ns, "strict")
        J.end_element!(enc)
        J.end_element!(enc)
        J.end_document!(enc)
        bytes = J.finish!(enc)
        # 80 is the header; then SE(header) 0 bits, SE(strict) code 2 of 4 ("10").
        @test bytes == [0x80, 0x40]
        events = collect(J.Decoder(bytes, J.OPTIONS_GRAMMARS; options = J.strict_options()))
        @test events == [J.StartDocument(), J.StartElement(ns, "header"), J.StartElement(ns, "strict"),
            J.EndElement(), J.EndElement(), J.EndDocument()]
        # The same document through push!, with options in the header and a cookie.
        o = J.strict_options(schema_id = "x", alignment = J.ALIGN_BYTE_ALIGNED)
        enc = J.Encoder(J.OPTIONS_GRAMMARS, o; header = J.HeaderConfig(cookie = true, include_options = true))
        foreach(e -> push!(enc, e), events)
        bytes = J.finish!(enc)
        @test_throws J.SchemaIdError J.Decoder(bytes, J.OPTIONS_GRAMMARS)
        dec = J.Decoder(bytes, J.with_schema_id(J.OPTIONS_GRAMMARS, "x"))
        @test dec.options == o && dec.header.cookie
        @test collect(dec) == events
    end

    @testset "values, xsi:nil and errors" begin
        ns = J.EXI_OPTIONS_NS
        evs = [J.StartDocument(), J.StartElement(ns, "header"), J.StartElement(ns, "lesscommon"),
            J.StartElement(ns, "uncommon"), J.StartElement(ns, "valueMaxLength"), J.Characters(J.Lexical(" 42 ")),
            J.EndElement(), J.EndElement(), J.EndElement(), J.StartElement(ns, "common"),
            J.StartElement(ns, "schemaId"), J.XsiNil(true), J.EndElement(), J.EndElement(), J.EndElement(),
            J.EndDocument()]
        enc = J.Encoder(J.OPTIONS_GRAMMARS)
        foreach(e -> push!(enc, e), evs)
        got = collect(J.Decoder(J.finish!(enc), J.OPTIONS_GRAMMARS; options = J.strict_options()))
        @test got[6] == J.Characters(UInt64(42))
        @test got[12] == J.XsiNil(true)
        @test length(got) == length(evs)
        enc = J.Encoder(J.OPTIONS_GRAMMARS)
        J.start_document!(enc)
        @test_throws J.GrammarError J.end_document!(enc)
        @test_throws J.UnsupportedError(J.FEATURE_BUILT_IN_ELEMENT_GRAMMAR) J.start_element!(enc, ns, "strict")
        J.start_element!(enc, ns, "header")
        @test_throws J.GrammarError J.start_element!(enc, ns, "header")
        @test_throws J.GrammarError J.attribute!(enc, "", "a", "1")
        @test_throws J.GrammarError J.xsi_type!(enc, J.XSD_NS, "string")
        @test_throws J.GrammarError J.finish!(enc)
        @test_throws J.UnsupportedError(J.FEATURE_PRESERVE_COMMENTS) push!(enc, J.Comment("x"))
        # Truncated input.
        @test_throws J.TruncatedError collect(J.Decoder(UInt8[0x80], J.OPTIONS_GRAMMARS; options = J.strict_options()))
    end

    # The same table as rexi-core's tests/header_options.rs.
    @testset "schemaId is checked against the tables" begin
        cases = [(nothing, nothing, true), (nothing, "urn:a", true), ("urn:a", "urn:a", true),
            ("urn:a", "urn:b", false), ("urn:a", nothing, false), (J.SCHEMA_ID_NIL, "urn:a", false),
            (J.SCHEMA_ID_NIL, nothing, false), ("", "", true), ("", "urn:a", false), ("", nothing, false)]
        for (stream, tables, ok) in cases
            if ok
                @test J.check_schema_id(stream, tables) === nothing
            else
                @test_throws J.SchemaIdError(stream, tables) J.check_schema_id(stream, tables)
            end
        end
        @test sprint(showerror, J.SchemaIdError("urn:a", "urn:b")) ==
              "schemaId mismatch: the stream names \"urn:a\", the grammar is \"urn:b\""
        @test sprint(showerror, J.SchemaIdError(J.SCHEMA_ID_NIL, nothing)) ==
              "schemaId mismatch: the stream names no schema (nil), the grammar has no schemaId"
    end

    # rexi-core's decoder_checks_schema_id: an options document whose body is
    # another options document, decoded with the options grammar under a name.
    @testset "the decoder checks schemaId" begin
        named(id) = id === nothing ? J.OPTIONS_GRAMMARS : J.with_schema_id(J.OPTIONS_GRAMMARS, id)
        function stream(o; include_options = true)
            w = J.BitWriter()
            J.write_header_bits!(w, J.HeaderConfig(include_options = include_options))
            include_options && J.write_options_document!(w, o)
            J.write_options_document!(w, J.strict_options())
            return J.finish!(w)
        end
        a = stream(J.strict_options(schema_id = "urn:a"))
        @test length(collect(J.Decoder(a, named("urn:a")))) > 2
        @test_throws J.SchemaIdError J.Decoder(a, named("urn:b"))
        @test_throws J.SchemaIdError J.Decoder(a, named(nothing))
        @test_throws J.SchemaIdError J.Decoder(stream(J.strict_options(schema_id = J.SCHEMA_ID_NIL)), named("urn:a"))
        @test J.Decoder(stream(J.strict_options()), named(nothing)) isa J.Decoder
        bare = stream(nothing; include_options = false)
        oob = J.strict_options(schema_id = "urn:a")
        @test J.Decoder(bare, named("urn:a"); options = oob) isa J.Decoder
        @test_throws J.SchemaIdError J.Decoder(bare, named("urn:b"); options = oob)
        # reset! checks the next stream's header too.
        dec = J.Decoder(stream(J.strict_options()), named("urn:b"))
        @test_throws J.SchemaIdError J.reset!(dec, a)
    end
end
