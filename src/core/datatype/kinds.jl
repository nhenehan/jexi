# EXI datatype representations (https://www.w3.org/TR/exi/#encodingValues).
#
# A datatype representation is the bit layout EXI uses for one kind of typed
# value. `DatatypeKind` says which layout a value uses. Three kinds are not
# written by the datatype layer: strings go through the value string table,
# QNames through the URI and local-name partitions, and lists are walked by the
# encoder. Everything else is a single value (a scalar), handled by
# `write_scalar!` and `read_scalar!`.

"""
XSD `whiteSpace` facet, applied when parsing text values
([XML Schema 1.0 Part 2](https://www.w3.org/TR/xmlschema-2/#rf-whiteSpace)).
`WS_PRESERVE` keeps the text, `WS_REPLACE` turns tabs, line feeds and carriage
returns into spaces, `WS_COLLAPSE` also joins runs of spaces and cuts spaces
from both ends.
"""
@enum WhiteSpace::UInt8 WS_PRESERVE WS_REPLACE WS_COLLAPSE

"""Which datatype layout a `DatatypeKind` stands for (Table 7-1 of the spec)."""
@enum KindTag::UInt8 begin
    # Through the value string table.
    K_STRING
    # One bit (https://www.w3.org/TR/exi/#encodingBoolean).
    K_BOOLEAN
    # Two bits, when the boolean type has pattern facets.
    K_BOOLEAN_PATTERN
    # Sign bit then magnitude (https://www.w3.org/TR/exi/#encodingInteger).
    K_INTEGER
    # 7-bit groups (https://www.w3.org/TR/exi/#encodingUnsignedInteger).
    K_UNSIGNED
    # At most 4096 values, an offset from `min` that is `bits` wide
    # (https://www.w3.org/TR/exi/#encodingBoundedUnsigned).
    K_NBIT
    K_DECIMAL
    K_FLOAT
    K_DATETIME
    K_BASE64
    K_HEX
    # Only for xsi:type values; the codec writes these itself.
    K_QNAME
    # The item's position in the list of allowed values
    # (https://www.w3.org/TR/exi/#encodingEnumerations).
    K_ENUMERATION
    # Item count, then each item (https://www.w3.org/TR/exi/#encodingList).
    K_LIST
    # Untyped character content (mixed content); a string.
    K_UNTYPED
    # A string type whose patterns give a restricted character set
    # (https://www.w3.org/TR/exi/#restrictedCharSet). Not implemented: values
    # of it are refused. See `K_RESTRICTED_STRING`. Added last so the numbers
    # of the tags above stay the same.
    K_RESTRICTED_STRING
end

@doc """
    K_RESTRICTED_STRING

The kind of a string type whose `xs:pattern` facets allow only a small
alphabet: fewer than 256 characters, all in the BMP
([EXI 7.1.10.1](https://www.w3.org/TR/exi/#restrictedCharSet)). For such a
type EXI writes each character as a short index into that alphabet instead of
a full code point, so the bytes differ from a plain string.

JExi does not implement that form yet. Writing the value as a plain string
would give bytes that EXIficient and other readers decode to garbage, with no
error. So the encoder and the decoder throw
`UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET)` when a value of this kind
is written or read. A schema with such a type still compiles, and documents
that never use the type work as usual. Patterns with a large alphabet (`\\d+`,
`.*`, `[^x]`, `\\p{L}`) are not restricted and stay plain strings.
""" K_RESTRICTED_STRING

"""
    DatatypeKind

How a value is represented in the stream. It is a plain bits type (no
pointers), so grammar tables can hold it in flat vectors. Only the fields its
`tag` uses mean anything; build one with the constructors below.

- `whitespace`: for `K_STRING` and `K_RESTRICTED_STRING`
- `datetime`: for `K_DATETIME`
- `min`, `bits`: for `K_NBIT`
- `set` (enumeration set index) and `item` (type index): for `K_ENUMERATION`;
  `item` alone for `K_LIST`. `item` of an enumeration is its base type, used to
  put text values in their one standard form before they are matched.
"""
struct DatatypeKind
    tag::KindTag
    whitespace::WhiteSpace
    datetime::DateTimeKind
    bits::UInt8
    min::Int64
    set::UInt32
    item::UInt32
end

DatatypeKind(tag::KindTag) = DatatypeKind(tag, WS_PRESERVE, DTK_DATETIME, 0x00, 0, 0, 0)

string_kind(ws::WhiteSpace) = DatatypeKind(K_STRING, ws, DTK_DATETIME, 0x00, 0, 0, 0)
restricted_string_kind(ws::WhiteSpace) =
    DatatypeKind(K_RESTRICTED_STRING, ws, DTK_DATETIME, 0x00, 0, 0, 0)
nbit_kind(min::Integer, bits::Integer) =
    DatatypeKind(K_NBIT, WS_PRESERVE, DTK_DATETIME, UInt8(bits), Int64(min), 0, 0)
datetime_kind(k::DateTimeKind) = DatatypeKind(K_DATETIME, WS_PRESERVE, k, 0x00, 0, 0, 0)
enum_kind(set::Integer, item::Integer) =
    DatatypeKind(K_ENUMERATION, WS_PRESERVE, DTK_DATETIME, 0x00, 0, UInt32(set), UInt32(item))
list_kind(item::Integer) =
    DatatypeKind(K_LIST, WS_PRESERVE, DTK_DATETIME, 0x00, 0, 0, UInt32(item))

const BOOLEAN_KIND = DatatypeKind(K_BOOLEAN)
const BOOLEAN_PATTERN_KIND = DatatypeKind(K_BOOLEAN_PATTERN)
const INTEGER_KIND = DatatypeKind(K_INTEGER)
const UNSIGNED_KIND = DatatypeKind(K_UNSIGNED)
const DECIMAL_KIND = DatatypeKind(K_DECIMAL)
const FLOAT_KIND = DatatypeKind(K_FLOAT)
const BASE64_KIND = DatatypeKind(K_BASE64)
const HEX_KIND = DatatypeKind(K_HEX)
const QNAME_KIND = DatatypeKind(K_QNAME)
const UNTYPED_KIND = DatatypeKind(K_UNTYPED)

"""Whether values of this kind travel through the value string table."""
is_string_like(k::DatatypeKind) = k.tag == K_STRING || k.tag == K_UNTYPED

"""Short name of a kind, for error messages."""
function kind_name(k::DatatypeKind)
    t = k.tag
    (t == K_STRING || t == K_RESTRICTED_STRING) && return "String"
    (t == K_BOOLEAN || t == K_BOOLEAN_PATTERN) && return "Boolean"
    t == K_INTEGER && return "Integer"
    t == K_UNSIGNED && return "Unsigned Integer"
    t == K_NBIT && return "n-bit Unsigned Integer"
    t == K_DECIMAL && return "Decimal"
    t == K_FLOAT && return "Float"
    t == K_DATETIME && return "Date-Time"
    (t == K_BASE64 || t == K_HEX) && return "Binary"
    t == K_QNAME && return "QName"
    t == K_ENUMERATION && return "Enumeration"
    t == K_LIST && return "List"
    return "untyped"
end

function Base.show(io::IO, k::DatatypeKind)
    t = k.tag
    if t == K_STRING
        print(io, "String(", k.whitespace, ")")
    elseif t == K_RESTRICTED_STRING
        print(io, "RestrictedString(", k.whitespace, ")")
    elseif t == K_NBIT
        print(io, "NBit(min=", k.min, ", bits=", Int(k.bits), ")")
    elseif t == K_DATETIME
        print(io, "DateTime(", k.datetime, ")")
    elseif t == K_ENUMERATION
        print(io, "Enumeration(set=", Int(k.set), ", item=", Int(k.item), ")")
    elseif t == K_LIST
        print(io, "List(item=", Int(k.item), ")")
    else
        print(io, t)
    end
end

# Type resolvers. Grammar tables answer these three questions about type and
# enumeration indices (all from 0):
#
#   datatype(types, t::UInt32) -> DatatypeKind
#   enum_count(types, set::UInt32) -> Int
#   enum_value(types, set::UInt32, ordinal::Integer) -> Union{Nothing,String}
function datatype end
function enum_count end
function enum_value end
