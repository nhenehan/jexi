# reset!: a reused decoder or encoder must behave exactly like a new one.
# Uses the interop fixtures of fixtures_strict.jl (INTEROP, PROFILES,
# reference, out_of_band, interop_cases).
import JExi as J

# Both sides iterate a Decoder (decode_events formats enumerations by name,
# iteration gives their ordinals).
events_of(dec) = J.events_dump(collect(dec))
fresh_events(bytes, tables, opts) = events_of(J.Decoder(bytes, tables; options = opts))

function encode_with!(enc, events)
    foreach(e -> push!(enc, e), events)
    return copy(J.finish!(enc))
end

@testset "reset! (reuse)" begin
    @testset "$(c.name)" for c in interop_cases()
        tables = J.compile_files(c.xsds...)
        bp, opts_in_stream, ba = PROFILES
        refs = Dict(p.name => reference(c, p) for p in PROFILES)

        @testset "decoder: streams with and without options in the header" begin
            # Out-of-band options are bit-packed; the -opts stream carries its
            # own, which must not stick to the streams after it.
            oob = bp.options(c)
            order = [bp, opts_in_stream, bp, opts_in_stream, opts_in_stream, bp]
            dec = J.Decoder(refs[bp.name], tables; options = oob)
            first = true
            for p in order
                first || J.reset!(dec, refs[p.name])
                first = false
                @test events_of(dec) == fresh_events(refs[p.name], tables, oob)
            end
        end

        @testset "decoder: byte-aligned, again and again" begin
            o = ba.options(c)
            dec = J.Decoder(refs[ba.name], tables; options = o)
            want = fresh_events(refs[ba.name], tables, o)
            for _ in 1:4
                @test events_of(dec) == want
                J.reset!(dec, refs[ba.name])
            end
        end

        @testset "decoder: a failed stream, then a good one" begin
            o = bp.options(c)
            good = refs[bp.name]
            dec = J.Decoder(good, tables; options = o)
            cut = good[1:max(2, length(good) ÷ 2)]
            J.reset!(dec, cut)
            @test_throws J.ExiError collect(dec)
            J.reset!(dec, good)
            @test events_of(dec) == fresh_events(good, tables, o)
        end

        @testset "encoder ($(p.name)): the same bytes as a new encoder" for p in PROFILES
            typed = J.decode_events(refs[p.name], tables; options = out_of_band(c, p), typed = true)
            enc = J.Encoder(tables, p.options(c); header = p.header)
            for i in 1:3
                i == 1 || J.reset!(enc)
                @test encode_with!(enc, typed) == refs[p.name]
            end
        end

        @testset "encoder and decoder: a value-partition ring that wraps" begin
            # Capacity 2 with a short valueMaxLength: values are evicted within
            # one stream, so stale slots or tombstones would change the bits.
            o = J.strict_options(value_partition_capacity = 2, value_max_length = 4)
            events = J.decode_events(refs[bp.name], tables; options = bp.options(c), typed = true)
            want = encode_with!(J.Encoder(tables, o), events)
            enc = J.Encoder(tables, o)
            encode_with!(enc, events)
            J.reset!(enc)
            @test encode_with!(enc, events) == want
            dec = J.Decoder(want, tables; options = o)
            collect(dec)
            J.reset!(dec, want)
            @test events_of(dec) == fresh_events(want, tables, o)
        end
    end

    @testset "finish! returns the buffer the next stream reuses" begin
        c = first(interop_cases())
        tables = J.compile_files(c.xsds...)
        events = J.decode_events(reference(c, PROFILES[1]), tables; options = PROFILES[1].options(c), typed = true)
        enc = J.Encoder(tables, J.strict_options())
        foreach(e -> push!(enc, e), events)
        out = J.finish!(enc)
        kept = copy(out)
        J.reset!(enc)
        foreach(e -> push!(enc, e), events)
        @test J.finish!(enc) === out    # same vector, rewritten
        @test out == kept               # (same document, so same bytes)
    end

    @testset "event_qname_id" begin
        c = first(interop_cases())
        tables = J.compile_files(c.xsds...)
        bytes = reference(c, PROFILES[1])
        dec = J.Decoder(bytes, tables; options = PROFILES[1].options(c))
        while J.next!(dec) != J.EV_SE
        end
        @test J.qname(dec.strings, J.event_qname_id(dec)) == J.event_qname(dec)
    end
end
