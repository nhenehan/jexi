# Struct mapping, ported from rexi-tests/tests/serde_fixtures.rs and
# rexi-serde/tests/mapping.rs: Julia values of the interop schemas encode to
# EXIficient's bytes in every profile and decode back to the same values.
import JExi as J

# A float and a decimal field of one float type (Float32 or Float16).
struct F32Pair{T<:AbstractFloat}
    f::T
    d::T
end
J.exi_name(::Type{<:F32Pair}) = "F"

# order-complex -------------------------------------------------------------

struct Customer
    loyalty_id::Union{Nothing,String}
    name::String
    tier::String
end
J.exi_rename_all(::Type{Customer}) = :PascalCase
J.exi_names(::Type{Customer}) = (loyalty_id = "loyaltyId",)

struct OrderItem
    sku::String
    description::String
    quantity::Int32
    price::Float64
end
J.exi_rename_all(::Type{OrderItem}) = :PascalCase
J.exi_names(::Type{OrderItem}) = (sku = "sku",)

struct Order
    order_id::String
    priority::Union{Nothing,Bool}
    customer::Customer
    items::Vector{OrderItem}
    notes::Union{Nothing,String}
end
J.exi_names(::Type{Order}) = (order_id = "orderId", customer = "Customer", items = "Item", notes = "Notes")

order() = Order("ORD-2026-0007", true, Customer("L-8821", "Raven Bookstore", "gold"),
    [OrderItem("BK-001", "Distributed Systems Patterns", 2, 42.95), OrderItem("BK-014", "Practical EXI", 1, 31.50)],
    "gift-wrap requested")

# telemetry-complex ---------------------------------------------------------

struct Reading
    sample::Int32
    kind::String
    value::Float64
    unit::String
end
J.exi_rename_all(::Type{Reading}) = :PascalCase
J.exi_names(::Type{Reading}) = (sample = "sample", kind = "Type")

struct Alarm
    code::String
    severity::String
end
J.exi_rename_all(::Type{Alarm}) = :PascalCase

struct Device
    id::String
    model::Union{Nothing,String}
    readings::Vector{Reading}
    alarms::Vector{Alarm}
    healthy::Bool
end
J.exi_names(::Type{Device}) = (readings = "Reading", alarms = "Alarm", healthy = "Healthy")

struct TelemetryBatch
    site::String
    generated_at::String
    devices::Vector{Device}
end
J.exi_names(::Type{TelemetryBatch}) = (generated_at = "generatedAt", devices = "Device")

telemetry() = TelemetryBatch("north-hub", "2026-04-15T12:00:00Z", [
    Device("dev-01", "alpha", [Reading(1, "temperature", 21.75, "C"), Reading(2, "humidity", 44.10, "percent")],
        Alarm[], true),
    Device("dev-02", nothing, [Reading(1, "temperature", 85.00, "C")], [Alarm("OVER_TEMP", "critical")], false),
])

# polymorphic-choice --------------------------------------------------------

struct TempReading
    value::Float64
    unit::String
end
J.exi_rename_all(::Type{TempReading}) = :PascalCase

struct StatusMessage
    lang::Union{Nothing,String}
    text::String
end
J.exi_names(::Type{StatusMessage}) = (text = "\$text",)

struct Alert
    ticket::Union{Nothing,String}
    code::String
    severity::String
    acknowledged::Union{Nothing,Bool}
end
J.exi_rename_all(::Type{Alert}) = :PascalCase
J.exi_names(::Type{Alert}) = (ticket = "ticket",)

struct Entry
    source::String
    content::Union{TempReading,StatusMessage,Alert}
end
J.exi_names(::Type{Entry}) = (content = "\$value",)

struct Envelope
    batch_id::String
    entries::Vector{Entry}
    summary::Union{Nothing,String}
end
J.exi_names(::Type{Envelope}) = (batch_id = "batchId", entries = "Entry", summary = "Summary")

envelope() = Envelope("batch-2026-04-15", [Entry("sensor-1", TempReading(19.5, "C")),
        Entry("gateway-1", StatusMessage("en", "operational")),
        Entry("sensor-9", Alert("INC-77", "OVERHEAT", "high", false))], "3 entries processed")

# inheritance-extension -----------------------------------------------------

struct ReadingEvent
    event_id::String
    timestamp::String
    source::String
    metric::String
    value::Float64
    unit::String
    quality::Union{Nothing,String}
    sensor_id::String
    category::String
end
J.exi_rename_all(::Type{ReadingEvent}) = :PascalCase
J.exi_names(::Type{ReadingEvent}) = (sensor_id = "sensorId", category = "category")

reading_event() = ReadingEvent("evt-2026-04-15-001", "2026-04-15T17:00:00Z", "edge-gateway-2", "temperature", 73.25,
    "F", "good", "sensor-17", "telemetry")

# cross-schema-main ---------------------------------------------------------

@enum Severity Low Medium High
J.exi_rename_all(::Type{Severity}) = :lowercase

struct Location
    site::String
    zone::String
end
J.exi_rename_all(::Type{Location}) = :PascalCase

struct AuditInfo
    created_by::String
    created_at::String
end
J.exi_rename_all(::Type{AuditInfo}) = :PascalCase

struct IncidentReport
    status::String
    id::String
    severity::Severity
    location::Location
    audit_info::AuditInfo
end
J.exi_rename_all(::Type{IncidentReport}) = :PascalCase
J.exi_names(::Type{IncidentReport}) = (status = "status",)

incident() = IncidentReport("open", "INC-2026-0109", High, Location("plant-7", "north"),
    AuditInfo("operator-12", "2026-04-15T17:45:00Z"))

# mapping.rs ----------------------------------------------------------------

const DRAWING_XSD = """<?xml version="1.0"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:t"
           xmlns="urn:t" elementFormDefault="qualified">
  <xs:complexType name="Shape">
    <xs:sequence><xs:element name="Label" type="xs:string"/></xs:sequence>
  </xs:complexType>
  <xs:complexType name="Circle">
    <xs:complexContent>
      <xs:extension base="Shape">
        <xs:sequence><xs:element name="Radius" type="xs:double"/></xs:sequence>
      </xs:extension>
    </xs:complexContent>
  </xs:complexType>
  <xs:simpleType name="Ints"><xs:list itemType="xs:int"/></xs:simpleType>
  <xs:element name="Drawing">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="Shape" type="Shape" maxOccurs="unbounded"/>
        <xs:element name="Counts" type="Ints"/>
        <xs:element name="Blob" type="xs:hexBinary"/>
        <xs:element name="Note" type="xs:string" nillable="true"/>
        <xs:element name="When" type="xs:date"/>
        <xs:element name="Big" type="xs:integer"/>
        <xs:element name="Small" type="xs:unsignedByte"/>
      </xs:sequence>
      <xs:attribute name="b" type="xs:string"/>
      <xs:attribute name="a" type="xs:int" use="required"/>
    </xs:complexType>
  </xs:element>
</xs:schema>"""

abstract type Shape end
struct PlainShape <: Shape
    label::String
end
struct Circle <: Shape
    label::String
    radius::Float64
end
J.exi_choices(::Type{Shape}) = (PlainShape, Circle)
J.exi_xsi_type(::Type{Shape}) = true
J.exi_name(::Type{PlainShape}) = "Shape"
J.exi_names(::Type{PlainShape}) = (label = "Label",)
J.exi_names(::Type{Circle}) = (label = "Label", radius = "Radius")

struct Drawing
    # Field order b, a: written in schema order a, b.
    b::Union{Nothing,String}
    a::Int32
    shape::Vector{Shape}
    counts::Vector{Int32}
    blob::Vector{UInt8}
    note::Union{Nothing,String}
    when::String
    big::Int128
    small::UInt8
end
J.exi_rename_all(::Type{Drawing}) = :PascalCase
J.exi_names(::Type{Drawing}) = (b = "b", a = "a")

drawing() = Drawing("x", 7, Shape[Circle("c", 1.5), PlainShape("s")], Int32[1, 2, 3], UInt8[0xca, 0xfe], "hi",
    "2026-10-10", Int128(123_456_789_012_345_678_901_234_567_890), 200)

const DRAWING_XML = """<Drawing xmlns="urn:t" xmlns:t="urn:t"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" b="x" a="7">
  <Shape xsi:type="t:Circle"><Label>c</Label><Radius>1.5</Radius></Shape>
  <Shape xsi:type="t:Shape"><Label>s</Label></Shape>
  <Counts>1 2 3</Counts><Blob>CAFE</Blob><Note>hi</Note><When>2026-10-10</When>
  <Big>123456789012345678901234567890</Big><Small>200</Small>
</Drawing>"""

const EXIFICIENT_DRAWING = "8001c06f1a004036307c01a012037381804040302cafe02343486a9434a57f3c79277e2e70fb6ff23b8c7200"
const EXIFICIENT_NIL = "80403a0120373800070d08400000"

struct NilMarker
    nil::Bool
end
J.exi_names(::Type{NilMarker}) = (nil = "@xsi:nil",)

struct NilNote
    a::Int32
    shape::Vector{Shape}
    counts::Vector{Int32}
    blob::Vector{UInt8}
    note::NilMarker
    when::String
    big::Int64
    small::UInt8
end
J.exi_name(::Type{NilNote}) = "Drawing"
J.exi_rename_all(::Type{NilNote}) = :PascalCase
J.exi_names(::Type{NilNote}) = (a = "a",)

same(a, b) = repr(a) == repr(b)

# A struct that holds itself: a deep document of it nests deeply.
struct Nest
    n::Vector{Nest}
end

@testset "struct mapping" begin
    models = Dict("order-complex" => order(), "telemetry-complex" => telemetry(), "polymorphic-choice" => envelope(),
        "inheritance-extension" => reading_event(), "cross-schema-main" => incident())
    for (label, tables_for) in (("runtime", c -> J.compile_files(c.xsds...)), ("static", c -> module_of(c.name).GRAMMARS))
        @testset "$(c.name) ($label tables)" for c in interop_cases()
            haskey(models, c.name) || continue
            value = models[c.name]
            # Named after the case, as the strict-bp-opts streams' schemaId says.
            tables = J.with_schema_id(tables_for(c), c.name)
            for p in PROFILES
                expected = reference(c, p)
                actual = J.to_exi(value, tables; options = p.options(c), header = p.header)
                ok = actual == expected
                ok || @info describe_diff("$(c.name) $(p.name) to_exi", actual, expected)
                @test ok
                back = J.from_exi(typeof(value), expected, tables; options = out_of_band(c, p))
                same(back, value) || @info "$(c.name) $(p.name) from_exi" back value
                @test same(back, value)
            end
        end
    end

    t = J.compile_string(DRAWING_XSD)

    @testset "round trip matches XML encoding" begin
        bytes = J.to_exi(drawing(), t)
        @test bytes == J.encode_xml(DRAWING_XML, t)
        @test bytes2hex(bytes) == EXIFICIENT_DRAWING
        @test same(J.from_exi(Drawing, bytes, t; options = J.strict_options()), drawing())
    end

    @testset "xsi:nil writes and reads as nothing" begin
        value = NilNote(-1, Shape[PlainShape("s")], Int32[], UInt8[], NilMarker(true), "2026-01-01", 0, 0)
        bytes = J.to_exi(value, t)
        xml = """<Drawing xmlns="urn:t" xmlns:t="urn:t"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" a="-1">
          <Shape xsi:type="t:Shape"><Label>s</Label></Shape><Counts></Counts><Blob></Blob>
          <Note xsi:nil="true"/><When>2026-01-01</When><Big>0</Big><Small>0</Small></Drawing>"""
        @test bytes == J.encode_xml(xml, t)
        @test bytes2hex(bytes) == EXIFICIENT_NIL
        back = J.from_exi(Drawing, bytes, t; options = J.strict_options())
        @test back.note === nothing
        @test back.b === nothing
        @test back.counts == Int32[]
    end

    @testset "explicit root name" begin
        struct Anything
            a::Int32
        end
        err = try
            J.to_exi(Anything(1), t)
        catch e
            e
        end
        @test err isa J.MappingError && occursin("no global element named Anything", err.msg)
        @test_throws J.GrammarError J.to_exi(Anything(1), t; root = "{urn:t}Drawing")
    end

    @testset "values that do not fit are reported" begin
        struct MissingRequiredAttribute
            b::String
        end
        J.exi_name(::Type{MissingRequiredAttribute}) = "Drawing"
        err = try
            J.to_exi(MissingRequiredAttribute("x"), t)
        catch e
            e
        end
        @test err isa J.MappingError && occursin("no element b", err.msg)
        struct UnknownChild
            a::Int32
            bogus::String
        end
        J.exi_name(::Type{UnknownChild}) = "Drawing"
        J.exi_names(::Type{UnknownChild}) = (bogus = "Bogus",)
        err = try
            J.to_exi(UnknownChild(1, "x"), t)
        catch e
            e
        end
        @test err isa J.MappingError && occursin("no element Bogus allowed here; expected attribute b, element Shape", err.msg)
        d = drawing()
        bad = Drawing(d.b, d.a, d.shape, d.counts, d.blob, d.note, "not-a-date", d.big, d.small)
        @test_throws J.ValueError J.to_exi(bad, t)
    end

    @testset "schema-less is refused" begin
        @test_throws J.UnsupportedError(J.FEATURE_BUILT_IN_ELEMENT_GRAMMAR) J.to_exi(drawing(), J.empty_grammar_set())
        @test_throws J.UnsupportedError J.from_exi(Drawing, UInt8[0x80], J.empty_grammar_set())
    end

    @testset "plain float text" begin
        @test J.plain_float(2.0) == "2"
        @test J.plain_float(42.95) == "42.95"
        @test J.plain_float(1e20) == "100000000000000000000"
        @test J.plain_float(1.5e-7) == "0.00000015"
        @test J.plain_float(-2.5e-3) == "-0.0025"
        @test J.plain_float(NaN) == "NaN" && J.plain_float(-Inf) == "-INF"
    end

    @testset "decoder limits" begin
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
            <xs:complexType name="N"><xs:sequence><xs:element name="n" type="N" minOccurs="0" maxOccurs="unbounded"/>
            </xs:sequence></xs:complexType><xs:element name="n" type="N"/></xs:schema>""")
        O = J.strict_options()
        deep = J.encode_xml("<n>"^200_000 * "</n>"^200_000, g)
        # The default depth cap stops it before `from_node` can overflow the stack.
        t = @elapsed @test_throws J.LimitError(:depth, 256) J.from_exi(Nest, deep, g; options = O)
        @test t < 1
        b = J.encode_xml("<n>"^300 * "</n>"^300, g)
        @test_throws J.LimitError(:depth, 256) J.from_exi(Nest, b, g; options = O)
        x = J.from_exi(Nest, b, g; options = O, limits = J.DecodeLimits(max_depth = 300))
        d = 0
        while !isempty(x.n)
            x = x.n[1]
            d += 1
        end
        @test d == 299

        # Many runs of mixed text are joined once, not copied over and over.
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
            <xs:element name="r"><xs:complexType mixed="true"><xs:sequence>
            <xs:element name="b" type="xs:string" minOccurs="0" maxOccurs="unbounded"/>
            </xs:sequence></xs:complexType></xs:element></xs:schema>""")
        b = J.encode_xml("<r>" * "ab<b/>"^20_000 * "c</r>", g)
        node = J.read_document(J.Decoder(b, g; options = O))
        @test node.text.lexical == "ab"^20_000 * "c"
        @test length(node.children) == 20_000
    end

    @testset "Float32 fields write their own shortest text" begin
        # 0.1f0 is 0.1 to a Float32 reader; widened to Float64 it was written as
        # 0.10000000149011612, giving other bytes than rexi and than the XML "0.1".
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
            <xs:element name="F"><xs:complexType><xs:sequence>
              <xs:element name="f" type="xs:float"/><xs:element name="d" type="xs:decimal"/>
            </xs:sequence></xs:complexType></xs:element></xs:schema>""")
        for (x, text) in ((0.1f0, "0.1"), (1.0f-5, "0.00001"), (-2.5f-7, "-0.00000025"), (Float16(0.1), "0.099975586"))
            v = F32Pair(x, x)
            @test J.to_exi(v, g) == J.encode_xml("<F><f>$text</f><d>$text</d></F>", g)
            back = J.from_exi(F32Pair{typeof(x)}, J.to_exi(v, g), g; options = J.strict_options())
            @test back.f == x && back.d == x
        end
    end

    @testset "whole floats past 2^63" begin
        # Written out in full, 1e19 has 20 digits; the float parser now moves the
        # trailing zeros into the exponent, so the mantissa fits.
        g = J.compile_string("""<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
            <xs:element name="F"><xs:complexType><xs:sequence>
              <xs:element name="f" type="xs:double"/><xs:element name="d" type="xs:double"/>
            </xs:sequence></xs:complexType></xs:element></xs:schema>""")
        for (x, text) in ((1e19, "1E19"), (-1e300, "-1E300"), (floatmax(Float64), "17976931348623157E292"),
            (floatmax(Float32), "34028235E31"))
            v = F32Pair(x, x)
            @test J.to_exi(v, g) == J.encode_xml("<F><f>$text</f><d>$text</d></F>", g)
            @test J.from_exi(F32Pair{typeof(x)}, J.to_exi(v, g), g; options = J.strict_options()).f == x
        end
    end

    @testset "field names with a non-ASCII namespace" begin
        # `{uri}local` is split at '}', found by byte; once a StringIndexError.
        @test J.parse_field_name("{urn:é}x") == ("urn:é", "x")
        @test J.parse_field_name("@{urn:日本}é") == ("urn:日本", "é")
    end
end
