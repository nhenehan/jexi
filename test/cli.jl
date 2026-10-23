# The jexi command line, run in-process (rexi-xml/tests/cli.rs).
import JExi as J

function jexi(args...)
    out, err = IOBuffer(), IOBuffer()
    code = J.CLI.main(String[args...]; out, err)
    return (code, String(take!(out)), String(take!(err)))
end

@testset "command line" begin
    dir = mktempdir()
    c = first(filter(c -> c.name == "cross-schema-main", interop_cases()))
    xsd = join(c.xsds, ',')
    exi = joinpath(dir, "out.exi")
    @test jexi("encode", "--xsd", xsd, c.xml, exi)[1] == 0
    @test read(exi) == read(joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    @test jexi("encode", "--xsd", xsd, "--alignment", "byte-aligned", c.xml, exi)[1] == 0
    @test read(exi) == read(joinpath(INTEROP, "cross-schema-main.strict-ba.exi"))
    @test jexi("encode", "--xsd", xsd, "--include-options", "--schema-id", "cross-schema-main", c.xml, exi)[1] == 0
    @test read(exi) == read(joinpath(INTEROP, "cross-schema-main.strict-bp-opts.exi"))
    code, text, _ = jexi("dump-events", "--xsd", xsd, joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    @test code == 0 && rstrip(text) == rstrip(read(joinpath(INTEROP, "cross-schema-main.strict-bp.events"), String))
    code, xml, _ = jexi("decode", "--xsd", xsd, joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    @test code == 0 && J.encode_xml(xml, J.compile_files(c.xsds...)) == read(joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    code, text, _ = jexi("dump-grammar", "--xsd", xsd)
    @test code == 0 && text == read(joinpath(@__DIR__, "fixtures", "listings", "cross-schema-main.txt"), String)
    code, text, _ = jexi("xml-events", c.xml)
    @test code == 0 && startswith(text, "SD\nSE {urn:rexi:interop:main}IncidentReport\n")
    evs = joinpath(dir, "out.events")
    code, json, _ = jexi("bench", "decode", "--xsd", xsd, "--warmup", "1", "--iterations", "3", "--events-out", evs,
        joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    @test code == 0 && occursin("\"impl\":\"jexi\"", json) && occursin("\"op\":\"decode\"", json)
    @test length(split(match(r"\"ns\":\[([^\]]*)\]", json)[1], ',')) == 3
    @test rstrip(read(evs, String)) == rstrip(read(joinpath(INTEROP, "cross-schema-main.strict-bp.events"), String))
    for from in ("xml", "events")
        # `--warmup-ms` keeps warming up until that much time has passed.
        t = time_ns()
        code, json, _ = jexi("bench", "encode", "--xsd", xsd, "--from", from, "--warmup", "0", "--warmup-ms", "25",
            "--iterations", "2", "--out", exi, c.xml)
        @test time_ns() - t >= 25_000_000
        @test code == 0 && occursin("\"input\":\"$from\"", json)
        @test read(exi) == read(joinpath(INTEROP, "cross-schema-main.strict-bp.exi"))
    end
    code, _, err = jexi("encode", "--xsd", xsd, "--no-strict", c.xml, exi)
    @test code == 1 && occursin("not supported", err)
    @test jexi("bogus")[1] == 1
    @test jexi("encode", "--xsd")[1] == 1
    @test jexi("decode", c.xml)[1] == 1
    code, _, err = jexi("encode", "--xsd", xsd, joinpath(dir, "missing.xml"), exi)
    @test code == 1 && startswith(err, "jexi: ")

    # Decode limits.
    code, _, err = jexi("--help")
    @test code == 1 && occursin("""
        decode limits (decode, dump-events, bench decode; 0 = no limit):
          --max-depth N                     elements open at once (default 256)
          --max-list-items N                items in one list value (default 1000000)
          --max-integer-bits N              bits in one integer value (default 4096)
          --max-string-bytes N              bytes of decoded string values (default 268435456)
          --no-limits                       turn every limit off
        """, err)
    lxsd = joinpath(dir, "limits.xsd")
    write(lxsd, """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="r"><xs:complexType>
        <xs:sequence><xs:element name="r" type="xs:integer" minOccurs="0"/></xs:sequence>
        <xs:attribute name="a"><xs:simpleType><xs:list itemType="xs:string"/></xs:simpleType></xs:attribute>
        </xs:complexType></xs:element></xs:schema>""")
    lxml = joinpath(dir, "limits.xml")
    write(lxml, """<r a="x y z"><r>$(big(2)^100)</r></r>""")
    lexi = joinpath(dir, "limits.exi")
    @test jexi("encode", "--xsd", lxsd, lxml, lexi)[1] == 0
    for (flags, msg) in ((["--max-depth", "1"], "nesting depth is over 1"),
            (["--max-list-items", "2"], "list items is over 2"),
            (["--max-integer-bits", "64"], "integer bits is over 64"),
            (["--max-string-bytes", "2"], "string bytes is over 2"))
        for cmd in (["decode"], ["dump-events"], ["bench", "decode", "--warmup", "0", "--iterations", "1"])
            code, _, err = jexi(cmd..., "--xsd", lxsd, flags..., lexi)
            @test code == 1 && occursin("jexi: decoder limit exceeded: $msg", err)
        end
        # 0 turns that limit off.
        @test jexi("decode", "--xsd", lxsd, flags[1], "0", lexi)[1] == 0
    end
    @test jexi("decode", "--xsd", lxsd, "--max-depth", "1", "--no-limits", lexi)[1] == 0
    @test jexi("decode", "--xsd", lxsd, "--max-depth", "2", "--max-list-items", "3", "--max-integer-bits", "105",
        "--max-string-bytes", "3", lexi)[1] == 0
    @test jexi("decode", "--xsd", lxsd, "--max-depth", "-1", lexi)[1] == 1
    @test jexi("decode", "--xsd", lxsd, "--max-depth", lexi)[1] == 1

    # --schema-root: maindoc/order.xsd includes ../common/types.xsd.
    set = mktempdir()
    mkpath(joinpath(set, "common"))
    mkpath(joinpath(set, "maindoc"))
    write(joinpath(set, "common", "types.xsd"), """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
      <xs:simpleType name="T"><xs:restriction base="xs:string"/></xs:simpleType></xs:schema>""")
    main = joinpath(set, "maindoc", "order.xsd")
    write(main, """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
      <xs:include schemaLocation="../common/types.xsd"/><xs:element name="r" type="T"/></xs:schema>""")
    code, _, err = jexi("dump-grammar", "--xsd", main)
    @test code == 1 && occursin("refused", err)
    @test jexi("dump-grammar", "--schema-root", set, "--xsd", main)[1] == 0
    @test occursin("--schema-root DIR", jexi("--help")[3])
end
