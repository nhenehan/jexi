# The schema compiler, against rexi's grammar listings and its unit tests
# (rexi-schema builtin.rs, datatype_map.rs, proto/normalize.rs).
import JExi as J

const FIX = joinpath(@__DIR__, "fixtures")

function interop_cases()
    cases = []
    for line in eachline(joinpath(FIX, "interop", "cases.tsv"))
        startswith(line, "name\t") && continue
        f = split(line, '\t')
        imports = length(f) >= 4 ? [x for x in split(f[4], ',') if !isempty(x)] : String[]
        push!(cases, (name = String(f[1]), xml = joinpath(FIX, "interop", f[2]),
            xsds = [joinpath(FIX, "interop", f[3]); [joinpath(FIX, "interop", x) for x in imports]]))
    end
    return cases
end

@testset "schema compiler" begin
    @testset "tables equal rexi's for $(c.name)" for c in interop_cases()
        listing = J.grammar_listing(J.compile_files(c.xsds...))
        expected = read(joinpath(FIX, "listings", c.name * ".txt"), String)
        if listing != expected
            a, b = split(listing, '\n'), split(expected, '\n')
            i = findfirst(k -> k > length(a) || k > length(b) || a[k] != b[k], 1:max(length(a), length(b)))
            @info "first difference at line $i" jexi = get(a, i, "") rexi = get(b, i, "")
        end
        @test listing == expected
    end

    @testset "built-in table" begin
        @test [b.name for b in J.BUILTINS] == collect(J.XSD_LOCAL_NAMES)
        @test J.BUILTINS[J.ANY_TYPE + 1].name == "anyType"
        @test J.BUILTINS[J.ANY_SIMPLE_TYPE + 1].name == "anySimpleType"
        @test J.BUILTINS[J.STRING_TYPE + 1].name == "string"
        @test J.BUILTINS[J.INTEGER_TYPE + 1].name == "integer"
        @test J.BUILTINS[J.QNAME_TYPE + 1].name == "QName"
        @test J.BUILTINS[J.NOTATION_TYPE + 1].name == "NOTATION"
        for i in 0:(J.BUILTIN_COUNT - 1)
            cur, steps = i, 0
            while cur !== nothing
                cur = J.BUILTINS[cur + 1].base
                steps += 1
            end
            @test steps < 20
        end
    end

    @testset "integer bounds" begin
        @test J.integer_kind(-128, 127) == J.nbit_kind(-128, 8)
        @test J.integer_kind(0, 255) == J.nbit_kind(0, 8)
        @test J.integer_kind(0, 65535) == J.UNSIGNED_KIND
        @test J.integer_kind(-32768, 32767) == J.INTEGER_KIND
        @test J.integer_kind(0, nothing) == J.UNSIGNED_KIND
        @test J.integer_kind(nothing, 0) == J.INTEGER_KIND
        @test J.integer_kind(nothing, nothing) == J.INTEGER_KIND
        @test J.integer_kind(1, 4096) == J.nbit_kind(1, 12)
        @test J.integer_kind(1, 4097) == J.UNSIGNED_KIND
        @test J.integer_kind(5, 5) == J.nbit_kind(5, 0)
        @test J.integer_kind(-3, 3) == J.nbit_kind(-3, 3)
    end

    @testset "normalize inlines non-terminals and merges duplicates" begin
        se(e, next) = J.pterm(J.term_se(e), next, e)
        # 0: NonTerm(1) | NonTerm(2); 1: SE(a) 3; 2: SE(a) 4 | EE; 3: EE; 4: SE(b) 3
        p = J.Proto([[J.pnonterm(1), J.pnonterm(2)], [se(0, 3)], [se(0, 4), J.P_END], [J.P_END], [se(1, 3)]])
        n = J.normalize(p)
        @test length(n.rules[1]) == 2
        @test n.rules[1][1].terminal == J.term_se(0)
        @test n.rules[1][2] == J.P_END
        union = n.rules[n.rules[1][1].next + 1]
        @test J.P_END in union
        @test any(x -> x.kind == J.P_TERM && x.terminal == J.term_se(1), union)
    end

    @testset "Appendix C schema writes the options documents the same bytes" begin
        compiled = J.compile_files(joinpath(FIX, "spec", "exi-options.xsd"))
        for o in (J.strict_options(), J.strict_options(schema_id = "a"),
            J.strict_options(schema_id = "a", alignment = J.ALIGN_BYTE_ALIGNED),
            J.strict_options(schema_id = "a", value_max_length = 12, value_partition_capacity = 66),
            J.strict_options(schema_id = J.SCHEMA_ID_NIL), J.strict_options(schema_id = ""),
            J.strict_options(block_size = 500))
            w1 = J.BitWriter()
            J.write_options_document!(w1, o)
            w2 = J.BitWriter()
            J.write_options_document!(w2, o; tables = compiled)
            @test J.finish!(w1) == J.finish!(w2)
        end
    end

    @testset "group cycles and grammar size" begin
        xsb(body) = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">$body</xs:schema>"""
        repeated(min, max) = xsb("""<xs:element name="r"><xs:complexType><xs:sequence>
            <xs:element name="e" type="xs:int" minOccurs="$min" maxOccurs="$max"/>
            </xs:sequence></xs:complexType></xs:element>""")
        message(f) = try
            f()
            ""
        catch e
            e isa J.SchemaError ? e.msg : rethrow()
        end
        circular(x) = occursin("circular group reference", message(() -> J.compile_string(x)))
        too_large(x; kw...) = occursin("schema too large", message(() -> J.compile_string(x; kw...)))

        @test circular(xsb("""<xs:group name="g"><xs:sequence><xs:group ref="g"/></xs:sequence></xs:group>
            <xs:element name="r"><xs:complexType><xs:group ref="g"/></xs:complexType></xs:element>"""))
        @test circular(xsb("""<xs:group name="a"><xs:sequence><xs:group ref="b"/></xs:sequence></xs:group>
            <xs:group name="b"><xs:choice><xs:element name="x"/><xs:group ref="a"/></xs:choice></xs:group>
            <xs:element name="r"><xs:complexType><xs:group ref="a"/></xs:complexType></xs:element>"""))
        # Back through a local element's anonymous type: endless copies.
        @test circular(xsb("""<xs:group name="g"><xs:sequence>
            <xs:element name="d" minOccurs="0"><xs:complexType><xs:group ref="g"/></xs:complexType></xs:element>
            </xs:sequence></xs:group>
            <xs:element name="r"><xs:complexType><xs:group ref="g"/></xs:complexType></xs:element>"""))
        # Through a global element or a named type it ends, so it compiles.
        @test J.compile_string(xsb("""<xs:group name="flow"><xs:choice>
            <xs:element ref="div"/><xs:element name="p" type="xs:string"/></xs:choice></xs:group>
            <xs:element name="div"><xs:complexType>
            <xs:group ref="flow" minOccurs="0" maxOccurs="unbounded"/></xs:complexType></xs:element>""")) isa J.GrammarSet
        @test J.compile_string(xsb("""<xs:group name="kids"><xs:sequence>
            <xs:element name="node" type="Node" minOccurs="0" maxOccurs="unbounded"/></xs:sequence></xs:group>
            <xs:complexType name="Node"><xs:group ref="kids"/></xs:complexType>
            <xs:element name="tree" type="Node"/>""")) isa J.GrammarSet

        t = time()
        @test too_large(repeated("0", "4000000000"))
        @test too_large(repeated("4000000000", "unbounded"))
        body = """<xs:group name="g0"><xs:sequence><xs:element name="x"/></xs:sequence></xs:group>"""
        for i in 1:20
            body *= """<xs:group name="g$i"><xs:sequence><xs:group ref="g$(i - 1)"/><xs:group ref="g$(i - 1)"/></xs:sequence></xs:group>"""
        end
        @test too_large(xsb(body * """<xs:element name="r"><xs:complexType><xs:group ref="g20"/></xs:complexType></xs:element>"""))
        @test time() - t < 5

        small = J.SchemaLoadOptions(; max_grammar_size = 1000)
        @test too_large(repeated("0", "600"); load_options = small)
        @test J.compile_string(repeated("0", "100"); load_options = small) isa J.GrammarSet
        @test J.compile_string(repeated("1", "3"); load_options = J.SchemaLoadOptions(; max_grammar_size = nothing)) isa J.GrammarSet
        # 20,000 optional copies are only 40,000 rules, but normalizing them makes
        # about 200 million productions; the production count stops it quickly.
        t = time()
        @test too_large(repeated("0", "20000"))
        @test time() - t < 20
        @test J.compile_string(repeated("0", "2000")) isa J.GrammarSet

        # A list of itself (or of a list) is refused; a decoder would follow it
        # without end.
        listed(item) = message(() -> J.compile_string(xsb("""<xs:simpleType name="A"><xs:list itemType="$item"/></xs:simpleType>
            <xs:element name="r" type="A"/>""")))
        @test occursin("list type", listed("A"))
        @test occursin("list type", listed("xs:NMTOKENS"))
        @test listed("xs:int") == ""
    end

    @testset "include and import load rules" begin
        types = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
          <xs:simpleType name="T"><xs:restriction base="xs:string"/></xs:simpleType></xs:schema>"""
        including(loc) = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
          <xs:include schemaLocation="$loc"/><xs:element name="r" type="T"/></xs:schema>"""
        put(path, text) = (mkpath(dirname(path)); write(path, text); path)
        refusal(f) = try
            f()
            ""
        catch e
            (e isa J.SchemaError && occursin("refused", e.msg)) ? e.msg : rethrow()
        end
        anywhere = J.SchemaLoadOptions(; root = :anywhere)

        dir = mktempdir()
        put(joinpath(dir, "types.xsd"), types)
        put(joinpath(dir, "sub", "more.xsd"), types)
        @test J.compile_files(put(joinpath(dir, "main.xsd"), including("types.xsd"))) isa J.GrammarSet
        @test J.compile_files(put(joinpath(dir, "main2.xsd"), including("sub/./more.xsd"))) isa J.GrammarSet

        # A UBL-style set reaches outside the main schema's folder: needs a root.
        set = mktempdir()
        put(joinpath(set, "common", "types.xsd"), types)
        main = put(joinpath(set, "maindoc", "order.xsd"), including("../common/types.xsd"))
        @test occursin("set a schema root", refusal(() -> J.compile_files(main)))
        @test J.compile_files(main; load_options = J.SchemaLoadOptions(; root = set)) isa J.GrammarSet
        @test J.compile_files(main; load_options = anywhere) isa J.GrammarSet

        # Outside paths are refused the same way whether or not they exist.
        other = mktempdir()
        put(joinpath(other, "types.xsd"), types)
        for loc in (joinpath(other, "types.xsd"), "../../../../../../../../etc/passwd",
            "../../../../../../../../no/such/file.xsd")
            m = put(joinpath(dir, "out.xsd"), including(loc))
            @test occursin("outside", refusal(() -> J.compile_files(m)))
        end

        # URLs are never fetched.
        for loc in ("http://example.com/types.xsd", "file:///etc/passwd")
            m = put(joinpath(dir, "url.xsd"), including(loc))
            @test occursin("URL", refusal(() -> J.compile_files(m; load_options = anywhere)))
        end

        # In memory: only under base_dir; none without one.
        @test occursin("no base folder", refusal(() -> J.compile_string(including("types.xsd"))))
        @test J.compile_string(including("types.xsd"); base_dir = dir) isa J.GrammarSet

        # Devices, big files, links out of the root and pipes.
        if isfile("/dev/zero") || ispath("/dev/zero")
            m = put(joinpath(dir, "zero.xsd"), including("/dev/zero"))
            @test occursin("regular file", refusal(() -> J.compile_files(m; load_options = anywhere)))
        end
        small = J.SchemaLoadOptions(; max_file_bytes = sizeof(types) - 1)
        @test occursin("bigger than", refusal(() -> J.compile_files(joinpath(dir, "main.xsd"); load_options = small)))
        if Sys.isunix()
            symlink(joinpath(other, "types.xsd"), joinpath(dir, "link.xsd"))
            @test occursin("outside", refusal(() -> J.compile_files(put(joinpath(dir, "l.xsd"), including("link.xsd")))))
            if success(`mkfifo $(joinpath(dir, "pipe.xsd"))`)
                m = put(joinpath(dir, "p.xsd"), including("pipe.xsd"))
                @test occursin("regular file", refusal(() -> J.compile_files(m)))
            end
        end
        @test_throws ArgumentError J.SchemaLoadOptions(; root = :elsewhere)
    end

    @testset "schema errors" begin
        xs(body; extra = "") = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" $extra>$body</xs:schema>"""
        @test_throws J.SchemaError J.compile_string("<a/>")
        @test_throws J.SchemaError J.compile_string("<xs:schema")
        @test_throws J.SchemaError J.compile_string(xs("""<xs:redefine schemaLocation="x.xsd"/>"""))
        @test_throws J.SchemaError J.compile_string(xs("""<xs:element name="a" type="nope"/>"""))
        @test_throws J.SchemaError J.compile_string(xs("""<xs:element name="a" type="p:t"/>"""))
        @test_throws J.SchemaError J.compile_string(xs("""
            <xs:complexType name="a"><xs:complexContent><xs:extension base="b"/></xs:complexContent></xs:complexType>
            <xs:complexType name="b"><xs:complexContent><xs:extension base="a"/></xs:complexContent></xs:complexType>"""))
        @test_throws J.SchemaError J.compile_string(xs("""<xs:element name="a"/><xs:element name="a"/>"""))
        @test_throws J.SchemaError J.compile_string(xs("""<xs:element name="a"><xs:complexType><xs:sequence>
            <xs:element name="b" minOccurs="2" maxOccurs="1"/></xs:sequence></xs:complexType></xs:element>"""))
        g = J.compile_string(xs("""<xs:element name="a" type="xs:int"/>"""))
        @test J.find_qname(g, "", "a") !== nothing
        @test length(g.global_elements) == 1
    end

    # https://www.w3.org/TR/exi/#restrictedCharSet. The cases come from the W3C
    # test suite (exi-testsuite/data/interop/datatypes/rcs).
    @testset "restricted character sets" begin
        rc(p) = J.restricted_charset([p])
        @test rc("[abcゕ©]") == J.CharsetRestricted(5)
        @test rc("[0-9]{3}-[0-9]{2}-[0-9]{4}") == J.CharsetRestricted(11)
        @test rc("[A-X]") == J.CharsetRestricted(24)
        @test rc("[ϗ-Ϛ]") == J.CharsetRestricted(4)
        @test rc("[a-z-[aeiou]]") == J.CharsetRestricted(21)
        @test rc("(a|b)+c?") == J.CharsetRestricted(3)
        @test rc(raw"\s") == J.CharsetRestricted(4)
        @test rc(raw"[\n\r\t\\\|\.\-\^\?\*\+\{\}\(\)\[\]]") == J.CharsetRestricted(17)
        @test rc("x{2,5}y{3}z{1,}") == J.CharsetRestricted(3)
        @test rc("[a-]") == J.CharsetRestricted(2)
        @test rc("") == J.CharsetRestricted(0)
        @test J.restricted_charset(["[a-c]", "[b-e]"]) == J.CharsetRestricted(5)
        @test rc("[ -~]") == J.CharsetRestricted(95)
        # Large alphabets.
        for p in (".", raw"\d+", raw"\D", raw"\w", raw"\W", raw"\i", raw"\I", raw"\c", raw"\C", raw"\S",
                  raw"\p{Lm}", raw"\P{L}", "[^:]", "[ABC\U10fff]", "[a-[b]]x|.", "[Ā-Ȁ]")
            @test rc(p) == J.CharsetNotRestricted()
        end
        @test J.restricted_charset(String[]) == J.CharsetNotRestricted()
        # Patterns that do not parse.
        for p in ("[a-", "(ab", "a{", "a{x}", raw"\q", "[]", "*a", "[z-a]", raw"\p{}", "a)")
            @test rc(p) == J.CharsetUnreadable()
        end
        # A big pattern makes the joined set big, even next to an unreadable one.
        @test J.restricted_charset(["[z-a]", raw"\d+"]) == J.CharsetNotRestricted()
        @test J.restricted_charset(["[z-a]", "[ab]"]) == J.CharsetUnreadable()

        xs(body) = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">$body</xs:schema>"""
        restricted(base, p) = xs("""<xs:simpleType name="R"><xs:restriction base="$base">
            $(p === nothing ? "" : "<xs:pattern value=\"$p\"/>")</xs:restriction></xs:simpleType>
            <xs:element name="r" type="R"/>""")
        # The same schema without the pattern.
        plain(base) = restricted(base, nothing)
        refused = J.UnsupportedError(J.FEATURE_RESTRICTED_CHARACTER_SET)
        @test J.restricted_alphabet(["[c-a]"]) == J.CharsetUnreadable()
        @test J.restricted_alphabet(["[ca]", "b"]) == "abc"
        @test J.restricted_alphabet(["[abcゕ©]"]) == "abc©ゕ"
        @test J.restricted_alphabet([raw"\d"]) === nothing
        @test J.restricted_alphabet([""]) == ""

        # EXIficient 1.0.7's bytes (strict, bit-packed and byte-aligned) for
        # each case, and the same document back from them.
        bp, ba = J.strict_options(), J.strict_options(alignment = J.ALIGN_BYTE_ALIGNED)
        r_type(p) = """<xs:simpleType name="R"><xs:restriction base="xs:string"><xs:pattern value="$p"/>
            </xs:restriction></xs:simpleType>"""
        r_elem = """<xs:element name="r" type="R"/>"""
        for (schema, xml, decoded, hex_bp, hex_ba) in (
                # The VIN of ISO 3779.
                (r_type("[A-HJ-NPR-Z0-9]{17}") * r_elem, "<r>1HGCM82633A004352</r>", nothing,
                 "8009828a062a404306194000206284", "8000130111100c1508020603030a000004030502"),
                # Characters outside the alphabet: the escape index, then the code point.
                (r_type("[A-HJ-NPR-Z0-9]{17}") * r_elem, "<r>IOQ-é€</r>", nothing,
                 "800442930a7c2a3096c3d2030d6208", "8000082149214f2151212d21e90121ac41"),
                # Indexes are in code point order, not pattern order.
                (r_type("[abc&#x3095;&#x00A9;]+") * r_elem, "<r>a©ゕcb</r>", nothing,
                 "80038711", "8000070003040201"),
                # An empty alphabet: zero-bit indexes, every character escaped.
                (r_type("") * r_elem, "<r>xy</r>", nothing, "80023c3c80", "8000047879"),
                # String-table hits, local and global, in an element and an attribute.
                ("""$(r_type("[0-9]{3}-[0-9]{2}-[0-9]{4}"))<xs:element name="r"><xs:complexType><xs:sequence>
                    <xs:element name="a" type="R" maxOccurs="unbounded"/></xs:sequence>
                    <xs:attribute name="b" type="R"/></xs:complexType></xs:element>""",
                 """<r b="123-45-6789"><a>123-45-6789</a><a>123-45-6789</a><a>987-65-4321</a></r>""", nothing,
                 "800348d01581e26804020da98076054328",
                 "8000000d020304000506000708090a010001000d0a0908000706000504030201"),
                # The item type of a list.
                (r_type("[A-X]+") * """<xs:simpleType name="L"><xs:list itemType="R"/></xs:simpleType>
                    <xs:element name="r" type="L"/>""", "<r>AB CD AB Z</r>", nothing,
                 "80020200208218000f0b40", "800004040001040203000003185a"),
                # xs:token collapses before the characters are written.
                ("""<xs:simpleType name="R"><xs:restriction base="xs:token"><xs:pattern value="[a-c ]+"/>
                    </xs:restriction></xs:simpleType>""" * r_elem, "<r>  a  b   c </r>", "<r>a b c</r>",
                 "80039083", "8000070100020003"),
                # Two types, two alphabets.
                (r_type("[a-c]+") * """<xs:simpleType name="S"><xs:restriction base="xs:string">
                    <xs:pattern value="[x-z]+"/></xs:restriction></xs:simpleType><xs:element name="r">
                    <xs:complexType><xs:sequence><xs:element name="p" type="R"/><xs:element name="q" type="S"/>
                    </xs:sequence></xs:complexType></xs:element>""", "<r><p>abc</p><q>zyx</q></r>", nothing,
                 "80028c0b20", "80000500010205020100"),
                # 95 characters: 7-bit indexes.
                (r_type("[ -~]*") * r_elem, "<r>Hello, World! ~</r>", nothing,
                 "8008a88b3264f1801bcfa53220101780", "80001128454c4c4f0c00374f524c4401005e"))
            g = J.compile_string(xs(schema))
            @test occursin(r"RestrictedString \{ whitespace: \w+, alphabet: Some\(\d+\) \}", J.grammar_listing(g))
            for (o, hex) in ((bp, hex_bp), (ba, hex_ba))
                @test bytes2hex(J.encode_xml(xml, g; options = o)) == hex
                @test J.decode_to_xml(hex2bytes(hex), g; options = o) == something(decoded, xml)
            end
        end
        # A character outside the BMP is one escaped code point. EXIficient
        # 1.0.7 counts UTF-16 units instead (AbstractTypeEncoder.writeRCSValue
        # loops over String.length() and writes the low surrogate as a second
        # escaped character), so its bytes are not the reference here.
        g = J.compile_string(xs(r_type("[A-Z]+") * r_elem))
        bytes = J.encode_xml("<r>A😀B</r>", g)
        @test J.decode_to_xml(bytes, g; options = bp) == "<r>A😀B</r>"
        # The literal is 3 characters ("A", escape + U+1F600, "B"), not 4.
        @test bytes == J.encode_xml("<r>A\U0001F600B</r>", g)
        @test length(bytes) == length(J.encode_xml("<r>A\u0100B</r>", g)) + 1
        # A bad index past the escape is an error, not a character.
        g = J.compile_string(xs(r_type("[a-e]") * r_elem))
        @test_throws J.ValueError J.decode_to_xml(hex2bytes("8003" * "ff"), g; options = bp)

        # Derived twice: the patterns of the most-derived type that has any count.
        g = J.compile_string(xs("""<xs:simpleType name="A"><xs:restriction base="xs:string"><xs:pattern value=".*"/>
            </xs:restriction></xs:simpleType><xs:simpleType name="B"><xs:restriction base="A">
            <xs:pattern value="[a-c]+"/></xs:restriction></xs:simpleType>
            <xs:simpleType name="C"><xs:restriction base="B"><xs:maxLength value="3"/></xs:restriction></xs:simpleType>
            <xs:element name="r" type="C"/>"""))
        @test occursin("RestrictedString", J.grammar_listing(g))
        @test J.decode_to_xml(J.encode_xml("<r>abc</r>", g), g; options = bp) == "<r>abc</r>"
        @test J.encode_xml("<r>abc</r>", g) != J.encode_xml("<r>abc</r>", J.compile_string(plain("xs:string")))

        # A pattern that does not parse: no alphabet, so values are refused.
        g = J.compile_string(restricted("xs:string", "[a-"))
        @test occursin("RestrictedString { whitespace: Preserve, alphabet: None }", J.grammar_listing(g))
        @test_throws refused J.encode_xml("<r>abc</r>", g)
        bytes = J.encode_xml("<r>abc</r>", J.compile_string(plain("xs:string")))
        @test_throws refused J.decode_to_xml(bytes, g; options = bp)
        # ... but a document that does not use the type works.
        g = J.compile_string(xs("""<xs:simpleType name="R"><xs:restriction base="xs:string"><xs:pattern value="[a-"/>
            </xs:restriction></xs:simpleType><xs:element name="r"><xs:complexType><xs:sequence>
            <xs:element name="a" type="R" minOccurs="0"/><xs:element name="b" type="xs:string"/>
            </xs:sequence></xs:complexType></xs:element>"""))
        @test occursin("<b>x</b>", J.decode_to_xml(J.encode_xml("<r><b>x</b></r>", g), g; options = bp))
        @test_throws refused J.encode_xml("<r><a>ab</a><b>x</b></r>", g)

        # Large alphabets, and types other than xs:string: the same bytes as before.
        for (base, p, text) in (("xs:string", raw"\p{Lm}", "abc"), ("xs:string", raw"\d+", "123"),
                ("xs:string", ".*", "abc"), ("xs:string", "[^:]", "a"), ("xs:string", "[ABC&#x10FFF;]", "A"),
                ("xs:duration", "P[0-9]Y", "P1Y"), ("xs:anyURI", "[a-z:]*", "urn:x"))
            g = J.compile_string(restricted(base, p))
            @test !occursin("RestrictedString", J.grammar_listing(g))
            bytes = J.encode_xml("<r>$text</r>", g)
            @test bytes == J.encode_xml("<r>$text</r>", J.compile_string(plain(base)))
            @test J.decode_to_xml(bytes, g; options = J.strict_options()) == J.decode_to_xml(bytes,
                J.compile_string(plain(base)); options = J.strict_options())
        end
        g = J.compile_string(restricted("xs:boolean", "true|false"))
        @test occursin("BooleanPattern", J.grammar_listing(g))
        # Enumerations win over patterns.
        g = J.compile_string(xs("""<xs:simpleType name="R"><xs:restriction base="xs:string"><xs:pattern value="[a-c]+"/>
            <xs:enumeration value="ab"/></xs:restriction></xs:simpleType><xs:element name="r" type="R"/>"""))
        @test !occursin("RestrictedString", J.grammar_listing(g))
        @test J.encode_xml("<r>ab</r>", g) isa Vector{UInt8}

        @test sprint(showerror, refused) == "not supported: restricted character sets"
        # SchemaGen writes the kind out and reads it back the same.
        k = J.restricted_string_kind(J.WS_COLLAPSE)
        @test J.SchemaGen.kind(k) == "J.restricted_string_kind(J.WS_COLLAPSE)"
        @test Core.eval(@__MODULE__, Meta.parse(J.SchemaGen.kind(k))) == k
        k7 = J.restricted_string_kind(J.WS_PRESERVE, 7)
        @test J.SchemaGen.kind(k7) == "J.restricted_string_kind(J.WS_PRESERVE, 7)"
        @test Core.eval(@__MODULE__, Meta.parse(J.SchemaGen.kind(k7))) == k7
        @test J.kind_name(k) == "String" && sprint(show, k) == "RestrictedString(WS_COLLAPSE)"
        @test J.parse_lexical(k, " a  b ", nothing) == "a b"
        @test_throws J.InternalError J.read_scalar!(J.BitReader(UInt8[0]), k, nothing)
    end
end

# ------------------------------------------------- EXIficient's grammar dumps
# Ported from rexi-schema/tests/oracle_dump.rs. EXIficient and JExi number
# their grammar objects differently and EXIficient keeps duplicates, so both
# dumps are canonicalized first: equal blocks are merged by partition
# refinement, then renumbered depth-first from the document grammar.

const REF_KEYS = ("grammar=", "-> ", "type-grammar=", "global-element=", "element-content=", "fragment-grammar ")

# The grammar numbers a line refers to, as (first, last, number) byte ranges.
function dump_refs(line::AbstractString)
    out = Tuple{Int,Int,Int}[]
    for key in REF_KEYS
        start = 1
        while (r = findnext(key, line, start)) !== nothing
            a = last(r) + 1
            b = a
            while b <= ncodeunits(line) && isdigit(line[b])
                b += 1
            end
            b > a && push!(out, (a, b - 1, parse(Int, line[a:(b - 1)])))
            start = max(b, first(r) + 1)
        end
    end
    sort!(out)
    return unique(r -> r[1], out)
end

function replace_refs(line::AbstractString, f)
    io = IOBuffer()
    last_ = 1
    for (a, b, n) in dump_refs(line)
        print(io, line[last_:(a - 1)], f(n))
        last_ = b + 1
    end
    print(io, line[last_:end])
    return String(take!(io))
end

function canonicalise(dump::AbstractString)
    lines = [l for l in split(dump, '\n') if !startswith(l, '#')]
    blocks = Dict{Int,Vector{String}}()
    preamble = String[]
    current = nothing
    for l in lines
        if startswith(l, "grammar ")
            current = parse(Int, split(l[9:end])[1])
            push!(get!(Vector{String}, blocks, current), l)
        elseif current !== nothing
            push!(blocks[current], l)
        else
            push!(preamble, l)
        end
    end
    function render(block, f)
        local buf = IOBuffer()
        for (j, l) in enumerate(block)
            if j == 1
                rest = l[9:end]
                sp = findfirst(' ', rest)
                l = "grammar " * (sp === nothing ? "" : rest[(sp + 1):end])
            end
            println(buf, replace_refs(l, f))
        end
        return String(take!(buf))
    end
    ids = sort!(collect(keys(blocks)))
    class = Dict(n => 0 for n in ids)
    while true
        sigs = Dict{String,Int}()
        next = Dict{Int,Int}()
        for n in ids
            sig = render(blocks[n], m -> haskey(class, m) ? string(class[m]) : "?")
            next[n] = get!(sigs, sig, length(sigs))
        end
        stable = all(n -> next[n] == class[n], ids) && length(sigs) == length(unique(values(class)))
        class = next
        stable && break
    end
    rep = Dict{Int,Int}()
    for n in ids
        haskey(rep, class[n]) || (rep[class[n]] = n)
    end
    order = Int[]
    number = Dict{Int,Int}()
    visit(n) = (local c = get(class, n, nothing); (c === nothing || haskey(number, c)) || (number[c] = length(order); push!(order, c)))
    visit(0)
    for l in preamble, (_, _, n) in dump_refs(l)
        visit(n)
    end
    i = 1
    while i <= length(order)
        for l in blocks[rep[order[i]]], (_, _, m) in dump_refs(l)
            visit(m)
        end
        i += 1
    end
    map_num(n) = (local c = get(class, n, nothing); c === nothing || !haskey(number, c) ? "?" : string(number[c]))
    io = IOBuffer()
    for l in preamble
        println(io, replace_refs(l, map_num))
    end
    for (k, c) in enumerate(order)
        print(io, replace(render(blocks[rep[c]], map_num), "grammar " => "grammar $(k - 1) "; count = 1))
    end
    return strip(String(take!(io)))
end

@testset "grammars match EXIficient's dump for $(c.name)" for c in interop_cases()
    # rexi checks these five; multilingual has no oracle grammar comparison there.
    c.name == "multilingual" && continue
    actual = canonicalise(J.exificient_dump(J.compile_files(c.xsds...)))
    expected = canonicalise(read(joinpath(FIX, "interop", c.name * ".grammars.txt"), String))
    if actual != expected
        a, e = split(actual, '\n'), split(expected, '\n')
        i = something(findfirst(k -> a[k] != e[k], 1:min(length(a), length(e))), min(length(a), length(e)) + 1)
        @info "$(c.name): differs at line $i ($(length(a)) vs $(length(e)) lines)" ours = get(a, i, "<eof>") oracle = get(e, i, "<eof>")
    end
    @test actual == expected
end
