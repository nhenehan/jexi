# Static tables from JExi.SchemaGen (rexi-tests/tests/generated_tables.rs and
# fixtures_strict_static.rs): they equal the tables compiled at run time, the
# Milestone 1 checks pass over them, and the Appendix C module codes options
# documents exactly like the hand-built OPTIONS_GRAMMARS.
import JExi as J

const GENERATED = joinpath(@__DIR__, "generated")
for f in sort!(readdir(GENERATED))
    endswith(f, ".jl") && include(joinpath(GENERATED, f))
end

module_of(case_name) = getfield(@__MODULE__, Symbol(join(uppercasefirst.(split(case_name, '-')))))

@testset "generated tables" begin
    @testset "screaming_snake" begin
        S = J.SchemaGen.screaming_snake
        @test S("orderId") == "ORDER_ID"
        @test S("pre-compress") == "PRE_COMPRESS"
        @test S("header") == "HEADER"
        @test S("ID") == "ID"
        @test S("item2Name") == "ITEM2_NAME"
        @test S("1st") == "_1ST"
    end

    @testset "$(c.name): static tables equal runtime tables" for c in interop_cases()
        m = module_of(c.name)
        @test m.GRAMMARS == J.compile_files(c.xsds...)
        # Every LN_ constant names what find_qname finds.
        for n in names(m; all = true)
            startswith(string(n), "LN_") || continue
            q = getfield(m, n)
            u = J.uri_str(m.GRAMMARS, q.uri)
            l = J.local_name_str(m.GRAMMARS, q)
            @test J.find_qname(m.GRAMMARS, u, l) == q
        end
    end

    @testset "interop fixtures (static tables)" begin
        check_fixtures(c -> module_of(c.name).GRAMMARS)
    end

    @testset "QNameId entry points give the same bytes" begin
        m = OrderComplex
        g = m.GRAMMARS
        xml = read(joinpath(INTEROP, "order-complex.xml"), String)
        by_id = J.Encoder(g)
        for ev in J.xml_events(xml)
            if ev isa J.StartElement
                J.start_element!(by_id, J.find_qname(g, ev.uri, ev.local_name))
            elseif ev isa J.Attribute
                J.attribute!(by_id, J.find_qname(g, ev.uri, ev.local_name), ev.value)
            else
                push!(by_id, ev)
            end
        end
        @test J.finish!(by_id) == J.encode_xml(xml, g)
        @test m.LN_ORDER == J.find_qname(g, "urn:rexi:interop:order", "Order")
    end

    @testset "Appendix C module codes options like OPTIONS_GRAMMARS" begin
        g = ExiOptions.EXI_OPTIONS
        for o in (J.strict_options(), J.strict_options(schema_id = "a"),
            J.strict_options(schema_id = "a", alignment = J.ALIGN_BYTE_ALIGNED),
            J.strict_options(schema_id = "a", value_max_length = 12, value_partition_capacity = 66),
            J.strict_options(schema_id = J.SCHEMA_ID_NIL), J.strict_options(schema_id = ""),
            J.strict_options(block_size = 500))
            w1 = J.BitWriter()
            J.write_options_document!(w1, o)
            w2 = J.BitWriter()
            J.write_options_document!(w2, o; tables = g)
            body = J.finish!(w1)
            @test J.finish!(w2) == body
            # Both decode the document to the same events.
            stream = [0x80; body]
            @test J.events_dump(J.decode_events(stream, g; options = J.strict_options())) ==
                  J.events_dump(J.decode_events(stream, J.OPTIONS_GRAMMARS; options = J.strict_options()))
        end
    end
end
