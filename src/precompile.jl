# A precompile workload (PrecompileTools): compiling a small schema and coding
# one document in each profile, so the first call in a fresh process (the CLI,
# the interop driver) does not wait for the compiler.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    xsd = """<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:p"
        xmlns="urn:p" elementFormDefault="qualified">
      <xs:complexType name="Base"><xs:sequence>
        <xs:element name="s" type="xs:string"/><xs:element name="i" type="xs:int" minOccurs="0"/>
      </xs:sequence><xs:attribute name="d" type="xs:decimal"/></xs:complexType>
      <xs:complexType name="More"><xs:complexContent><xs:extension base="Base"><xs:sequence>
        <xs:element name="f" type="xs:double"/><xs:element name="t" type="xs:dateTime"/>
        <xs:element name="b" type="xs:boolean"/><xs:element name="h" type="xs:hexBinary"/>
        <xs:element name="l"><xs:simpleType><xs:list itemType="xs:unsignedInt"/></xs:simpleType></xs:element>
        <xs:element name="e"><xs:simpleType><xs:restriction base="xs:string">
          <xs:enumeration value="x"/><xs:enumeration value="y"/></xs:restriction></xs:simpleType></xs:element>
      </xs:sequence></xs:extension></xs:complexContent></xs:complexType>
      <xs:element name="r"><xs:complexType><xs:choice maxOccurs="unbounded">
        <xs:element name="a" type="Base" nillable="true"/><xs:element name="m" type="xs:string"/>
      </xs:choice></xs:complexType></xs:element>
    </xs:schema>"""
    xml = """<r xmlns="urn:p" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <a d="1.5"><s>one</s><i>-7</i></a><m>two</m><a xsi:nil="true"/>
      <a xsi:type="More"><s>three</s><f>2.5E1</f><t>2026-10-18T12:00:00Z</t><b>true</b>
        <h>CAFE</h><l>1 2 3</l><e>y</e></a></r>"""
    @compile_workload begin
        g = with_schema_id(compile_string(xsd), "p")
        for o in (strict_options(), strict_options(alignment = ALIGN_BYTE_ALIGNED),
            strict_options(schema_id = "p", value_max_length = 8, value_partition_capacity = 4))
            for h in (HeaderConfig(), HeaderConfig(include_options = true, cookie = true))
                bytes = encode_xml(xml, g; options = o, header = h)
                events = decode_events(bytes, g; options = o)
                events_dump(events)
                typed = decode_events(bytes, g; options = o, typed = true)
                enc = Encoder(g, o; header = h)
                foreach(e -> push!(enc, e), typed)
                finish!(enc)
                write_xml(events)
            end
        end
        grammar_listing(g)
        exificient_dump(g)
        CLI.parse_args(["--xsd", "a.xsd", "--strict", "--alignment", "byte-aligned", "x"])
    end
end
