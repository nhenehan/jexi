# The XML front-end, ported from rexi-xml (reader.rs, writer.rs and dump.rs
# unit tests; tests/whitespace.rs, wildcard_namespaces.rs, fixtures.rs) and
# rexi-tests/tests/exip_clones.rs. The hex strings are EXIficient 1.0.7
# `encode-xml --strict` output, recorded in rexi.
import JExi as J

se(u, l) = J.StartElement(u, l)
at(u, l, v) = J.Attribute(u, l, J.Lexical(v))
ch(v) = J.Characters(J.Lexical(v))
const SD, ED, EE = J.StartDocument(), J.EndDocument(), J.EndElement()
hexstr(b) = bytes2hex(b)

# Events with plain string values, as the writer and decoder give them, turned
# into the reader's Lexical form so the two can be compared.
lexical(evs) = map(evs) do e
    e isa J.Attribute && return J.Attribute(e.uri, e.local_name, J.Lexical(J.plain_format(e.value)))
    e isa J.Characters && return J.Characters(J.Lexical(J.plain_format(e.value)))
    e
end

@testset "XML front-end" begin
    @testset "attributes sorted, xsi first" begin
        xml = """<r xmlns="u" xmlns:x="http://www.w3.org/2001/XMLSchema-instance" xmlns:o="v"
                    z="1" x:nil="false" o:a="3" a="2" x:type="o:T"/>"""
        @test J.xml_events(xml) == [SD, se("u", "r"), J.XsiType("v", "T"), J.XsiNil(false), at("", "a", "2"),
            at("v", "a", "3"), at("", "z", "1"), EE, ED]
    end

    @testset "xsi:type without prefix uses the default namespace" begin
        xml = """<r xmlns="u" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="T"/>"""
        @test J.xml_events(xml)[3] == J.XsiType("u", "T")
    end

    @testset "text merged and unescaped" begin
        xml = "<r a=\"x &amp; y&#10;z\ttab\">one&lt;<![CDATA[<two>]]>&#x26;three\r\nfour</r>"
        @test J.xml_events(xml) == [SD, se("", "r"), at("", "a", "x & y\nz tab"), ch("one<<two>&three\nfour"), EE, ED]
        # Line ends are normalized in literal text only (XML 1.0 section 2.11).
        @test J.xml_events("<r>a&#13;b&#xD;&#xA;c\r\nd</r>")[3] == ch("a\rb\r\nc\nd")
        @test_throws J.UnsupportedError J.xml_events("<r>&nbsp;</r>")
        evs = J.xml_events("<r xmlns=\"urn:t\" a=\"1 &lt; 2 &amp;&#x41;\"><![CDATA[a < b & c]]>&gt;&#10;x</r>")
        @test evs == [SD, se("urn:t", "r"), at("", "a", "1 < 2 &A"), ch("a < b & c>\nx"), EE, ED]
        @test J.events_dump(evs) == "SD\nSE {urn:t}r\nAT {}a 1 < 2 &A\nCH a < b & c>\\nx\nEE\nED\n"
    end

    @testset "whitespace kept inside, dropped outside" begin
        xml = "<?xml version=\"1.0\"?>\n<!-- c -->\n<r>\n  <a/>\n</r>\n"
        @test J.xml_events(xml) == [SD, se("", "r"), ch("\n  "), se("", "a"), EE, ch("\n"), EE, ED]
    end

    @testset "rejected input" begin
        @test_throws J.UnsupportedError J.xml_events("<!DOCTYPE r><r/>")
        @test_throws J.XmlSyntaxError J.xml_events("<p:r/>")
        @test_throws J.XmlSyntaxError J.xml_events("<r><a></r>")
        @test_throws J.XmlSyntaxError J.xml_events("<r/><r/>")
        @test_throws J.XmlSyntaxError J.xml_events("")
        @test_throws J.XmlSyntaxError J.xml_events("<r>x</r>y")
        @test_throws J.XmlSyntaxError J.xml_events("<r xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:nil=\"maybe\"/>")
        # The streaming reader's own checks.
        @test_throws J.XmlSyntaxError J.xml_events("<r a=\"1\" a=\"2\"/>")
        @test_throws J.XmlSyntaxError J.xml_events("<r xmlns:p=\"u\" xmlns:q=\"u\" p:a=\"1\" q:a=\"2\"/>")
        @test_throws J.XmlSyntaxError J.xml_events("<r a=\"<\"/>")
        @test_throws J.XmlSyntaxError J.xml_events("<r a=\"1\"")
        @test_throws J.XmlSyntaxError J.xml_events("<r><a>")
        @test_throws J.XmlSyntaxError J.xml_events("</r>")
        @test_throws J.XmlSyntaxError J.xml_events("<r/><?xml version=\"1.0\"?>")
        @test_throws J.XmlSyntaxError J.xml_events("<1r/>")
        @test_throws J.XmlSyntaxError J.xml_events("<r>&amp</r>")
        @test_throws J.XmlSyntaxError J.xml_events("<r>&#0;</r>")
        @test_throws J.UnsupportedError J.xml_events("<r a=\"&nbsp;\"/>")
    end

    @testset "streaming reader details" begin
        # A byte-order mark is not content; namespaces end with their element.
        @test J.xml_events("\ufeff<r/>") == [SD, se("", "r"), EE, ED]
        xml = "<r xmlns=\"u\"><a xmlns=\"v\" xmlns:p=\"w\" p:x=\"1\"/><b/></r>"
        @test J.xml_events(xml) == [SD, se("u", "r"), se("v", "a"), at("w", "x", "1"), EE, se("u", "b"), EE, EE, ED]
        # Sorted by local name, then URI; the order in the tag does not matter.
        xml = "<r xmlns:p=\"b\" xmlns:q=\"a\" p:k=\"1\" q:k=\"2\" c=\"3\" b=\"4\"/>"
        @test J.xml_events(xml) == [SD, se("", "r"), at("", "b", "4"), at("", "c", "3"), at("a", "k", "2"),
            at("b", "k", "1"), EE, ED]
        # Comments and processing instructions split no text.
        @test J.xml_events("<r>a<!-- c -->b<?p x?>c</r>")[3] == ch("abc")
        @test J.xml_events("<r>\r\n</r>")[3] == ch("\n")
        # The encoder takes text split by markup as one value.
        @test J.xml_events("<r>é<![CDATA[ü]]>&#x4E2D;</r>")[3] == ch("éü中")
    end

    @testset "events dump line format" begin
        evs = J.Event[SD, se("urn:x", "r"), J.XsiType("urn:x", "T"), J.XsiNil(false), J.Attribute("", "a", "x\ty\\z"),
            J.Characters("l1\nl2\r"), J.Characters(-4), EE, ED]
        @test J.events_dump(evs) ==
              "SD\nSE {urn:x}r\nXSI_TYPE {urn:x}T\nXSI_NIL false\nAT {}a x\\ty\\\\z\nCH l1\\nl2\\r\nCH -4\nEE\nED\n"
        @test occursin("CH L1\\nL2\\r\n", J.events_dump(evs; formatter = v -> uppercase(J.plain_format(v))))
    end

    @testset "writer: namespaces, prefixes and empty elements" begin
        evs = J.Event[SD, se("urn:a", "root"), J.Attribute("", "id", "1"), J.Attribute("urn:a", "own", "2"),
            se("urn:b", "child"), J.XsiNil(true), EE, se("urn:c", "other"), J.XsiType("urn:a", "T"),
            J.Characters("a<b&c"), EE, se("", "plain"), EE, EE, ED]
        xml = J.write_xml(evs)
        @test xml == "<root xmlns=\"urn:a\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " *
                     "xmlns:ns1=\"urn:a\" xmlns:ns2=\"urn:b\" xmlns:ns3=\"urn:c\" id=\"1\" ns1:own=\"2\">" *
                     "<ns2:child xsi:nil=\"true\"/><ns3:other xsi:type=\"T\">a&lt;b&amp;c</ns3:other>" *
                     "<plain xmlns=\"\"/></root>"
        @test J.xml_events(xml) == lexical(evs)
    end

    @testset "writer: xsi:type in no namespace under a default namespace" begin
        evs = J.Event[SD, se("urn:a", "root"), J.XsiType("", "T"), se("urn:a", "child"), J.XsiType("", "U"),
            se("urn:a", "leaf"), EE, EE, EE, ED]
        xml = J.write_xml(evs)
        @test xml == "<ns1:root xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " *
                     "xmlns:ns1=\"urn:a\" xsi:type=\"T\"><ns1:child xsi:type=\"U\">" *
                     "<ns1:leaf/></ns1:child></ns1:root>"
        @test J.xml_events(xml) == evs
    end

    @testset "writer: xsi:type in the root namespace under no default namespace" begin
        evs = J.Event[SD, se("urn:a", "root"), se("", "plain"), J.XsiType("urn:a", "T"), EE, se("urn:a", "back"),
            J.XsiType("urn:a", "T"), EE, EE, ED]
        xml = J.write_xml(evs)
        @test xml == "<root xmlns=\"urn:a\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " *
                     "xmlns:ns1=\"urn:a\"><plain xmlns=\"\" xsi:type=\"ns1:T\"/>" *
                     "<back xsi:type=\"T\"/></root>"
        @test J.xml_events(xml) == evs
    end

    @testset "writer: attribute escaping survives reparsing" begin
        evs = J.Event[SD, se("", "r"), J.Attribute("", "a", "tab\tnl\ncr\rq\"lt<amp&"), J.Characters("x\ny>z"), EE, ED]
        xml = J.write_xml(evs)
        @test xml == "<r a=\"tab&#9;nl&#10;cr&#13;q&quot;lt&lt;amp&amp;\">x\ny&gt;z</r>"
        @test J.xml_events(xml) == lexical(evs)
    end

    @testset "whitespace-only text as EXIficient" begin
        ws = joinpath(@__DIR__, "fixtures", "whitespace")
        tables = J.compile_files(joinpath(ws, "ws.xsd"), joinpath(ws, "xml.xsd"))
        for (doc, expected) in (("""<m xmlns="urn:w"> <e/> t <e/> </m>""", "80340a40e84048"),
            ("""<m xmlns="urn:w"> </m>""", "80606408"),
            ("""<m xmlns="urn:w" xml:space="preserve"> <e/> </m>""", "80180c80a004"),
            ("""<m xmlns="urn:w" xml:space="preserve"><e> <e/> </e><e xml:space="default"> <e/> </e></m>""", "8013032028010128"),
            ("<m xmlns=\"urn:w\">\n  <e>\n  </e>\n  <e>x</e>\n</m>", "803828510102606f0a"))
            @test hexstr(J.encode_xml(doc, tables)) == expected
        end
    end

    @testset "attribute CR LF is one space, as EXIficient" begin
        xsd = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
            targetNamespace="urn:a" xmlns="urn:a" elementFormDefault="qualified">
          <xs:element name="r"><xs:complexType><xs:attribute name="a" type="xs:string"/></xs:complexType></xs:element>
        </xs:schema>"""
        t = J.compile_string(xsd)
        for (xml, expected) in (("<r xmlns=\"urn:a\" a=\"x\r\ny\"/>", "80015e081e40"),
            ("<r xmlns=\"urn:a\" a=\"x\ry\"/>", "80015e081e40"), ("<r xmlns=\"urn:a\" a=\"x\n\ty\"/>", "80019e08081e40"))
            @test hexstr(J.encode_xml(xml, t)) == expected
        end
    end

    @testset "list items split on XML spaces only" begin
        xsd = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
            targetNamespace="urn:l" xmlns="urn:l" elementFormDefault="qualified">
          <xs:element name="l"><xs:simpleType><xs:list itemType="xs:string"/></xs:simpleType></xs:element>
        </xs:schema>"""
        tables = J.compile_string(xsd)
        @test hexstr(J.encode_xml("<l xmlns=\"urn:l\">a　b c d</l>", tables)) == "800103b0c030315000b181b200"
    end

    @testset "attribute-wildcard URIs join the URI partition" begin
        xsd = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
            targetNamespace="urn:t" xmlns="urn:t" elementFormDefault="qualified">
          <xs:complexType name="Base"><xs:sequence><xs:element name="n" type="xs:string"/></xs:sequence></xs:complexType>
          <xs:complexType name="Derived"><xs:complexContent><xs:extension base="Base">
            <xs:sequence><xs:element name="m" type="xs:int"/></xs:sequence></xs:extension></xs:complexContent></xs:complexType>
          <xs:element name="r">
            <xs:complexType>
              <xs:sequence>
                <xs:element name="c" type="Base"/>
                <xs:any namespace="urn:only-in-any ##local" processContents="skip" minOccurs="0"/>
              </xs:sequence>
              <xs:attribute name="a" type="xs:int"/>
              <xs:anyAttribute namespace="urn:zz-only-in-anyAttribute urn:b-only-in-anyAttribute" processContents="skip"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>"""
        t = J.compile_string(xsd)
        @test [J.uri_str(t, u) for u in 4:(length(t.uris) - 1)] ==
              ["urn:b-only-in-anyAttribute", "urn:only-in-any", "urn:t", "urn:zz-only-in-anyAttribute"]
        xml = """<r xmlns="urn:t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" a="1"><c xsi:type="Derived"><n>x</n><m>7</m></c></r>"""
        @test hexstr(J.encode_xml(xml, t)) == "80001ae00406f003c0"
    end

    @testset "fixture XML gives the oracle's events (whitespace aside)" begin
        looks_numeric(v) = !isempty(v) && all(c -> isdigit(c) || c in ('.', '+', '-', 'E'), v)
        function lines_match(a, b)
            sa, sb = split(a, ' '; limit = 2), split(b, ' '; limit = 2)
            (length(sa) == 2 && length(sb) == 2 && sa[1] == sb[1] && sa[1] in ("CH", "AT")) || return a == b
            if sa[1] == "AT"
                na, va = split(sa[2], ' '; limit = 2)
                nb, vb = split(sb[2], ' '; limit = 2)
                return na == nb && (va == vb || looks_numeric(vb))
            end
            return sa[2] == sb[2] || looks_numeric(sb[2])
        end
        for name in ("order-complex", "telemetry-complex", "polymorphic-choice", "inheritance-extension", "cross-schema-main")
            evs = J.xml_events(read(joinpath(INTEROP, name * ".xml"), String))
            significant = filter(e -> !(e isa J.Characters && all(isspace, e.value.text)), evs)
            ours = split(rstrip(J.events_dump(significant)), '\n')
            oracle = split(rstrip(read(joinpath(INTEROP, name * ".strict-bp.events"), String)), '\n')
            @test length(ours) == length(oracle)
            @test all(lines_match(a, b) for (a, b) in zip(ours, oracle))
        end
        evs = J.xml_events(read(joinpath(INTEROP, "telemetry-complex.xml"), String))
        @test [e.local_name for e in evs[3:4] if e isa J.Attribute] == ["generatedAt", "site"]
        evs = J.xml_events(read(joinpath(INTEROP, "cross-schema-main.xml"), String))
        @test [e.local_name for e in evs if e isa J.StartElement && e.uri == "urn:rexi:interop:common"] ==
              ["Site", "Zone", "AuditInfo", "CreatedBy", "CreatedAt"]
        @test evs[2] == se("urn:rexi:interop:main", "IncidentReport")
    end

    @testset "decode to XML and back" begin
        for c in interop_cases()
            tables = J.compile_files(c.xsds...)
            bytes = read(joinpath(INTEROP, "$(c.name).strict-bp.exi"))
            xml = J.decode_to_xml(bytes, tables; options = J.strict_options())
            @test J.encode_xml(xml, tables) == bytes
        end
    end

    @testset "exip vectors" begin
        r = J.BitReader(UInt8[0x80, 0x60, 0x7c])
        info = J.read_header_bits!(r)
        @test !info.cookie && !info.options_in_stream && info.format_version == 1
        @test J.bit_position(r) == 8
        r = J.BitReader(UInt8[0x24, 0x45, 0x58, 0x49, 0x80, 0x60, 0x7c])
        info = J.read_header_bits!(r)
        @test info.cookie && !info.options_in_stream
        @test J.bit_position(r) == 40
        dir = joinpath(third_party_dir(), "exip", "tests", "test-set", "testStates")
        if isfile(joinpath(dir, "acceptance_a_01.exi"))
            tables = J.compile_files(joinpath(dir, "acceptance.xsd"))
            evs = J.decode_events(read(joinpath(dir, "acceptance_a_01.exi")), tables; options = J.strict_options(), typed = true)
            expected = J.Event[SD, se("urn:foo", "A")]
            for n in ("AB", "AC", "AC", "AD", "AE")
                push!(expected, se("urn:foo", n), J.Characters(""), EE)
            end
            push!(expected, EE, ED)
            @test evs == expected
        else
            @test !judges_required()
        end
    end

    @testset "wildcards are refused as wildcards" begin
        # xs:any and xs:anyAttribute are strict, schema-declared productions, so they
        # must not be reported as non-strict or as built-in grammars.
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
          <xs:attribute name="g" type="xs:int"/>
          <xs:element name="root"><xs:complexType>
            <xs:sequence><xs:any processContents="strict" minOccurs="0"/></xs:sequence>
            <xs:anyAttribute processContents="strict"/>
          </xs:complexType></xs:element>
          <xs:element name="leaf" type="xs:int"/>
        </xs:schema>""")
        feature(f) = try
            f()
            nothing
        catch e
            e isa J.UnsupportedError ? e.feature : nothing
        end
        for x in ("""<root g="5"/>""", "<root><leaf>3</leaf></root>")
            @test feature(() -> J.encode_xml(x, g)) == J.FEATURE_WILDCARD
        end
        @test !isempty(J.encode_xml("<root/>", g))
        # Every choice of event codes after the root's start: some hit a wildcard,
        # and only an undeclared root (codes 2 and 3, top bit set) is a built-in grammar.
        wildcards = 0
        for byte in 0x00:0xff
            f = feature(() -> J.decode_events(UInt8[0x80, byte, 0x00], g; options = J.strict_options()))
            f == J.FEATURE_WILDCARD && (wildcards += 1)
            @test f != J.FEATURE_NON_STRICT_SCHEMA_INFORMED
            f == J.FEATURE_BUILT_IN_ELEMENT_GRAMMAR && @test byte & 0x80 != 0
        end
        @test wildcards > 0
    end

    @testset "non-ASCII next to a byte-found separator" begin
        # Names and references are split at ASCII bytes (':', ';', spaces); the part
        # before must end at the start of its last character, which may be several
        # bytes long. These once threw StringIndexError.
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
            targetNamespace="urn:u"><xs:element name="r" type="xs:string"/></xs:schema>""")
        plain = J.encode_xml("""<r xmlns="urn:u">x</r>""", g)
        @test J.encode_xml("""<pé:r xmlns:pé="urn:u">x</pé:r>""", g) == plain
        @test J.encode_xml("""<日本:r xmlns:日本="urn:u">x</日本:r>""", g) == plain
        clean_error(x) = try
            J.encode_xml(x, g)
            false
        catch e
            e isa J.ExiError || e isa J.XmlSyntaxError
        end
        @test clean_error("""<pé:r>x</pé:r>""")          # undeclared prefix
        @test clean_error("""<r xmlns="urn:u">&é;</r>""") # unknown entity
        @test clean_error("""<r xmlns="urn:u" xmlns:xsi="$(J.XSI_NS)" xsi:type="é ">x</r>""")
        # The same in the schema reader.
        g2 = J.compile_string("""<xé:schema xmlns:xé="http://www.w3.org/2001/XMLSchema"
            targetNamespace="urn:u"><xé:element name="r" type="xé:string"/></xé:schema>""")
        @test J.encode_xml("""<r xmlns="urn:u">x</r>""", g2) == plain
    end

    # Hostile streams: each one stops with a LimitError, quickly, and raising
    # the cap lets a just-over stream through.
    @testset "decoder limits" begin
        xs(body) = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">$body</xs:schema>"""
        O = J.strict_options()
        lim(; kw...) = J.DecodeLimits(; kw...)
        # A stream by hand: header, SE(r) (1-bit code: one global element), then `body!`.
        function stream(body!)
            w = J.BitWriter()
            J.write_raw_bits!(w, UInt64(0x80), 8)
            J.write_raw_bits!(w, UInt64(0), 1)
            body!(w)
            J.write_raw_bits!(w, UInt64(0), 8)
            return J.finish!(w)
        end
        @test J.DecodeLimits() == J.DecodeLimits(256, 1_000_000, 4096, 256 * 1024 * 1024)
        @test J.unlimited_limits() == J.DecodeLimits(nothing, nothing, nothing, nothing)
        @test J.LimitError(:depth, 256) isa J.ExiError
        @test sprint(showerror, J.LimitError(:depth, 256)) == "decoder limit exceeded: nesting depth is over 256"
        @test sprint(showerror, J.LimitError(:list_items, 5)) == "decoder limit exceeded: list items is over 5"
        @test sprint(showerror, J.LimitError(:integer_bits, 5)) == "decoder limit exceeded: integer bits is over 5"
        @test sprint(showerror, J.LimitError(:string_bytes, 5)) == "decoder limit exceeded: string bytes is over 5"

        # A list of 0-bit items (a one-value enumeration): a few bytes claim
        # any number of items.
        g = J.compile_string(xs("""<xs:simpleType name="one"><xs:restriction base="xs:string">
            <xs:enumeration value="A"/></xs:restriction></xs:simpleType>
            <xs:simpleType name="L"><xs:list itemType="one"/></xs:simpleType><xs:element name="r" type="L"/>"""))
        huge = stream(w -> J.write_unsigned!(w, UInt64(1) << 62))
        @test length(huge) <= 12
        t = @elapsed @test_throws J.LimitError(:list_items, 1_000_000) J.decode_events(huge, g; options = O)
        @test t < 1
        eleven = stream(w -> J.write_unsigned!(w, UInt64(11)))
        @test_throws J.LimitError(:list_items, 10) J.decode_to_xml(eleven, g; options = O, limits = lim(max_list_items = 10))
        @test J.decode_to_xml(eleven, g; options = O, limits = lim(max_list_items = 11)) == "<r>" * join(fill("A", 11), ' ') * "</r>"

        # Required self-nesting: SE(T) inside T takes 0 bits, so 2 bytes nest forever.
        g = J.compile_string(xs("""<xs:element name="T"><xs:complexType><xs:sequence><xs:element ref="T"/>
            </xs:sequence></xs:complexType></xs:element>"""))
        t = @elapsed @test_throws J.LimitError(:depth, 256) J.decode_events(UInt8[0x80, 0x00], g; options = O)
        @test t < 1
        @test_throws J.LimitError(:depth, 1000) J.decode_events(UInt8[0x80, 0x00], g; options = O,
            limits = lim(max_depth = 1000))
        g = J.compile_string(xs("""<xs:complexType name="T"><xs:sequence><xs:element name="T" type="T" minOccurs="0"/>
            </xs:sequence></xs:complexType><xs:element name="T" type="T"/>"""))
        five = J.encode_xml("<T>"^5 * "</T>"^5, g)
        @test_throws J.LimitError(:depth, 4) J.decode_to_xml(five, g; options = O, limits = lim(max_depth = 4))
        @test J.decode_to_xml(five, g; options = O, limits = lim(max_depth = 5)) == "<T>"^4 * "<T/>" * "</T>"^4
        @test length(J.decode_events(five, g; options = O, limits = J.unlimited_limits())) == 12

        # A 100 KB integer: refused before any of it is built.
        g = J.compile_string(xs("""<xs:element name="r" type="xs:integer"/>"""))
        bigint = stream() do w
            # The CH code (1 bit: xs:integer has subtypes, so xsi:type may
            # follow), then the sign.
            J.write_raw_bits!(w, UInt64(0), 2)
            for _ in 1:100_000
                J.write_byte!(w, 0xff)
            end
            J.write_byte!(w, 0x01)
        end
        t = @elapsed @test_throws J.LimitError(:integer_bits, 4096) J.decode_events(bigint, g; options = O)
        @test t < 1
        # 2^4100 takes 586 groups of 7 bits: 4102 bits.
        v = big(2)^4100
        b = J.encode_xml("<r>$v</r>", g)
        @test_throws J.LimitError(:integer_bits, 4096) J.decode_events(b, g; options = O)
        @test_throws J.LimitError(:integer_bits, 4101) J.decode_events(b, g; options = O, limits = lim(max_integer_bits = 4101))
        @test J.decode_events(b, g; options = O, typed = true, limits = lim(max_integer_bits = 4102))[3] == J.Characters(v)
        t = @elapsed ev = J.decode_events(bigint, g; options = O, typed = true, limits = J.unlimited_limits())
        @test ev[3].value == big(2)^700_001 - 1
        @test t < 1
        # The big-integer read gives the right value for many sizes and signs.
        for x in (big(2)^64 - 1, big(2)^64, big(2)^70 + 12345, -(big(3)^500), big(10)^1000 + 7)
            b = J.encode_xml("<r>$x</r>", g)
            @test J.decode_events(b, g; options = O, typed = true)[3] == J.Characters(x)
        end
        @test_throws J.LimitError(:integer_bits, 6) J.decode_events(J.encode_xml("<r>1</r>", g), g; options = O,
            limits = lim(max_integer_bits = 6))
        # The cap reaches decimals, floats and years too.
        for (t, text) in (("xs:decimal", "12.5"), ("xs:double", "1.5"), ("xs:gYear", "2026"))
            g = J.compile_string(xs("""<xs:element name="r" type="$t"/>"""))
            b = J.encode_xml("<r>$text</r>", g)
            @test_throws J.LimitError(:integer_bits, 6) J.decode_events(b, g; options = O, limits = lim(max_integer_bits = 6))
            @test J.decode_to_xml(b, g; options = O, limits = lim(max_integer_bits = 7)) isa String
        end

        # String-table hits: one 64 KiB string, then thousands of short references to it.
        g = J.compile_string(xs("""<xs:element name="r"><xs:complexType><xs:sequence>
            <xs:element name="s" type="xs:string" maxOccurs="unbounded"/></xs:sequence></xs:complexType></xs:element>"""))
        function hits(n, text)
            enc = J.Encoder(g)
            push!(enc, J.StartDocument())
            push!(enc, se("", "r"))
            for _ in 1:n
                push!(enc, se("", "s"))
                push!(enc, J.Characters(text))
                push!(enc, EE)
            end
            push!(enc, EE)
            push!(enc, ED)
            return J.finish!(enc)
        end
        b = hits(4097, "x"^65536)
        @test length(b) < 200_000
        t = @elapsed @test_throws J.LimitError(:string_bytes, 256 * 1024 * 1024) J.decode_events(b, g; options = O)
        @test t < 1
        b = hits(3, "abcd")
        @test_throws J.LimitError(:string_bytes, 11) J.decode_events(b, g; options = O, limits = lim(max_string_bytes = 11))
        @test length(J.decode_events(b, g; options = O, limits = lim(max_string_bytes = 12))) == 13
    end
end
