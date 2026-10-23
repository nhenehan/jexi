# Text forms of values, and the scalar dispatch.
#
# `parse_lexical` turns XML text into a typed value, `format_value` gives a
# value's one standard text form (EXIficient's canonical form: float `7325E-2`,
# decimal `210.0`, dateTime `...Z`), and `write_scalar!` / `read_scalar!`
# encode and decode a scalar value of a datatype. A `Lexical` value is parsed
# with the datatype first, so typed and text input give the same bytes.

is_xml_space(c::Char) = c == ' ' || c == '\t' || c == '\n' || c == '\r'
is_other_space(c::Char) = c == '\t' || c == '\n' || c == '\r'

"""
    apply_whitespace(ws, s) -> String

Applies an XSD `whiteSpace` facet to text (see [`WhiteSpace`](@ref)).
"""
function apply_whitespace(ws::WhiteSpace, s::AbstractString)
    ws == WS_PRESERVE && return String(s)
    if ws == WS_REPLACE
        any(is_other_space, s) || return String(s)
        return map(c -> is_other_space(c) ? ' ' : c, String(s))
    end
    unchanged = !isempty(s) ? !(is_xml_space(first(s)) || is_xml_space(last(s))) : true
    if unchanged && !any(is_other_space, s) && !occursin("  ", s)
        return String(s)
    end
    return join(split(s, is_xml_space; keepempty = false), ' ')
end

collapse(s::AbstractString) = apply_whitespace(WS_COLLAPSE, s)

invalid(kind::DatatypeKind, s::AbstractString) =
    ValueError(kind_name(kind), "$(repr(s)) is not a valid lexical value")

value_name(::Lexical) = "lexical"
value_name(::AbstractString) = "String"
value_name(::Bool) = "Boolean"
value_name(::Integer) = "Integer"
value_name(::ExiDecimal) = "Decimal"
value_name(::ExiFloat) = "Float"
value_name(::ExiDateTime) = "Date-Time"
value_name(::AbstractVector{UInt8}) = "Binary"
value_name(::EnumOrdinal) = "Enumeration"
value_name(::ExiList) = "List"
value_name(::Any) = "unknown"

mismatch(kind::DatatypeKind, value) =
    ValueError(kind_name(kind), "typed $(value_name(value)) value does not match the datatype")

function not_scalar(kind::DatatypeKind)
    is_string_like(kind) && return InternalError(
        "string values are encoded through the string table, not the datatype layer")
    kind.tag == K_RESTRICTED_STRING &&
        return InternalError("restricted-character-set strings are refused by the codec")
    kind.tag == K_QNAME &&
        return InternalError("QName values are encoded by the codec, not the datatype layer")
    kind.tag == K_LIST &&
        return InternalError("list values are iterated by the codec, not the datatype layer")
    return InternalError("datatype kind is not a scalar")
end

"""
    int_from_decimal_str(s) -> Union{Nothing,Int64,BigInt}

Parses base-10 digits with an optional `+` or `-` sign. Spaces are not allowed.
"""
function int_from_decimal_str(s::AbstractString)
    cu = codeunits(s)
    start = (!isempty(cu) && (cu[1] == UInt8('+') || cu[1] == UInt8('-'))) ? 2 : 1
    start > length(cu) && return nothing
    for i in start:length(cu)
        UInt8('0') <= cu[i] <= UInt8('9') || return nothing
    end
    v = tryparse(Int64, s)
    v === nothing || return v
    return small_int(parse(BigInt, s))
end

nbit_in_range(v::Integer, min::Int64, bits::Integer) =
    typemin(Int64) <= v <= typemax(Int64) && 0 <= Int128(v) - Int128(min) <= nbit_max(bits)

"""
    parse_lexical(kind, s, types)

Turns XML text into the typed value of `kind`. `types` resolves the item types
of lists and enumerations.
"""
function parse_lexical(kind::DatatypeKind, s::AbstractString, types)
    t = kind.tag
    (t == K_STRING || t == K_RESTRICTED_STRING) && return apply_whitespace(kind.whitespace, s)
    t == K_UNTYPED && return String(s)
    t == K_QNAME && throw(ValueError(kind_name(kind), "QName values are resolved by the codec"))
    if t == K_LIST
        item_kind = datatype(types, kind.item)
        items = Any[parse_lexical(item_kind, tok, types) for tok in split(s, is_xml_space; keepempty = false)]
        return ExiList(items)
    end
    t == K_ENUMERATION && return EnumOrdinal(enum_ordinal(kind, Lexical(String(s)), types))
    c = collapse(s)
    v = parse_scalar(kind, c)
    v === nothing && throw(invalid(kind, c))
    return v
end

function parse_scalar(kind::DatatypeKind, s::AbstractString)
    t = kind.tag
    t == K_BOOLEAN && return parse_boolean(s)
    if t == K_BOOLEAN_PATTERN
        id = parse_boolean_pattern(s)
        return id === nothing ? nothing : pattern_to_bool(id)
    end
    t == K_INTEGER && return int_from_decimal_str(s)
    if t == K_UNSIGNED
        v = int_from_decimal_str(s)
        (v === nothing || v < 0) && return nothing
        return small_uint(v isa BigInt ? v : UInt64(v))
    end
    if t == K_NBIT
        v = int_from_decimal_str(s)
        (v === nothing || !nbit_in_range(v, kind.min, kind.bits)) && return nothing
        return Int64(v)
    end
    t == K_DECIMAL && return decimal_from_lexical(s)
    t == K_FLOAT && return float_from_lexical(s)
    t == K_DATETIME && return datetime_from_lexical(kind.datetime, s)
    t == K_BASE64 && return parse_base64(s)
    t == K_HEX && return parse_hex(s)
    return nothing
end

"""
    format_value(kind, value, types) -> String

The one standard text form of `value` as a value of `kind`.
"""
function format_value(kind::DatatypeKind, value, types)
    if value isa Lexical
        return format_value(kind, parse_lexical(kind, value.text, types), types)
    end
    value isa AbstractString && return String(value)
    value isa Bool && return value ? "true" : "false"
    if value isa Integer
        kind.tag == K_DECIMAL && return decimal_to_lexical(decimal_from_int(value))
        return string(value)
    end
    value isa ExiDecimal && return decimal_to_lexical(value)
    value isa ExiFloat && return float_to_lexical(value)
    value isa ExiDateTime && return datetime_to_lexical(value)
    if value isa AbstractVector{UInt8}
        kind.tag == K_HEX && return format_hex(value)
        kind.tag == K_BASE64 && return format_base64(value)
        kind.tag == K_ENUMERATION && return format_value(datatype(types, kind.item), value, types)
        throw(mismatch(kind, value))
    end
    if value isa EnumOrdinal
        kind.tag == K_ENUMERATION || throw(mismatch(kind, value))
        s = enum_value(types, kind.set, value.ordinal)
        s === nothing &&
            throw(ValueError(kind_name(kind), "ordinal $(value.ordinal) out of range"))
        return s
    end
    if value isa ExiList
        kind.tag == K_LIST || throw(mismatch(kind, value))
        item_kind = datatype(types, kind.item)
        return join((format_value(item_kind, v, types) for v in value.items), ' ')
    end
    throw(mismatch(kind, value))
end

"""
    enum_ordinal(kind, value, types) -> UInt32

The position of `value` in the enumeration of `kind`. Text and typed values
are compared in standard form, so `+10` matches the listed value `10`.
"""
function enum_ordinal(kind::DatatypeKind, value, types)
    count = enum_count(types, kind.set)
    if value isa EnumOrdinal
        value.ordinal < count && return value.ordinal
        throw(ValueError(kind_name(kind), "ordinal $(value.ordinal) out of range (count $count)"))
    end
    item_kind = datatype(types, kind.item)
    canonical = format_value(item_kind, value, types)
    for i in 0:(count - 1)
        s = enum_value(types, kind.set, i)
        s === nothing && continue
        candidate = try
            format_value(item_kind, parse_lexical(item_kind, s, types), types)
        catch err
            err isa ExiError || rethrow()
            nothing
        end
        candidate == canonical && return UInt32(i)
    end
    throw(ValueError(kind_name(kind), "$(repr(canonical)) is not an enumerated value"))
end

function as_int(kind::DatatypeKind, value)
    value isa Bool && throw(mismatch(kind, value))
    value isa Integer && return small_int(value)
    if value isa Lexical
        s = collapse(value.text)
        v = int_from_decimal_str(s)
        v === nothing && throw(invalid(kind, s))
        return v
    end
    throw(mismatch(kind, value))
end

function as_uint(kind::DatatypeKind, value)
    v = as_int(kind, value)
    v < 0 && throw(ValueError(kind_name(kind), "$v is negative"))
    return small_uint(v isa BigInt ? v : UInt64(v))
end

"""
    write_scalar!(w, kind, value, types)

Encodes a scalar value of `kind`. `value` may be a [`Lexical`](@ref), which is
parsed first. String-like, QName and list kinds are the codec's job.
"""
function write_scalar!(w::BitWriter, kind::DatatypeKind, value, types)
    t = kind.tag
    (is_string_like(kind) || t == K_QNAME || t == K_LIST || t == K_RESTRICTED_STRING) &&
        throw(not_scalar(kind))
    if t == K_BOOLEAN || t == K_BOOLEAN_PATTERN
        if value isa Bool
            b = value
            t == K_BOOLEAN && return write_boolean!(w, b)
            return write_boolean_pattern!(w, pattern_id_for(b))
        elseif value isa Lexical
            s = collapse(value.text)
            if t == K_BOOLEAN
                b = parse_boolean(s)
                b === nothing && throw(invalid(kind, s))
                return write_boolean!(w, b)
            end
            id = parse_boolean_pattern(s)
            id === nothing && throw(invalid(kind, s))
            return write_boolean_pattern!(w, id)
        end
        throw(mismatch(kind, value))
    end
    t == K_INTEGER && return write_integer!(w, as_int(kind, value))
    t == K_UNSIGNED && return write_unsigned!(w, as_uint(kind, value))
    t == K_NBIT && return write_nbit!(w, as_int(kind, value), kind.min, kind.bits)
    if t == K_DECIMAL
        if value isa ExiDecimal
            return write_decimal!(w, value)
        elseif value isa Lexical
            s = collapse(value.text)
            d = decimal_from_lexical(s)
            d === nothing && throw(invalid(kind, s))
            return write_decimal!(w, d)
        elseif value isa Integer && !(value isa Bool)
            return write_decimal!(w, decimal_from_int(value))
        end
        throw(mismatch(kind, value))
    end
    if t == K_FLOAT
        value isa ExiFloat && return write_float!(w, value)
        if value isa Lexical
            s = collapse(value.text)
            f = float_from_lexical(s)
            f === nothing && throw(invalid(kind, s))
            return write_float!(w, f)
        end
        throw(mismatch(kind, value))
    end
    if t == K_DATETIME
        if value isa ExiDateTime
            value.kind == kind.datetime && return write_datetime!(w, value)
            throw(ValueError(kind_name(kind),
                "$(datetime_kind_name(value.kind)) value where $(datetime_kind_name(kind.datetime)) is expected"))
        elseif value isa Lexical
            s = collapse(value.text)
            dt = datetime_from_lexical(kind.datetime, s)
            dt === nothing && throw(invalid(kind, s))
            return write_datetime!(w, dt)
        end
        throw(mismatch(kind, value))
    end
    if t == K_BASE64 || t == K_HEX
        value isa AbstractVector{UInt8} && return write_binary!(w, value)
        if value isa Lexical
            s = collapse(value.text)
            bytes = t == K_HEX ? parse_hex(s) : parse_base64(s)
            bytes === nothing && throw(invalid(kind, s))
            return write_binary!(w, bytes)
        end
        throw(mismatch(kind, value))
    end
    # K_ENUMERATION
    ordinal = enum_ordinal(kind, value, types)
    return write_nbit_unsigned!(w, UInt64(ordinal), ceil_log2(enum_count(types, kind.set)))
end

"""
    read_scalar!(r, kind, types, max_bits = typemax(Int))

Decodes a scalar value of `kind`. String-like, QName and list kinds are the
codec's job. `max_bits` caps each integer read (the decoder's
`max_integer_bits`).
"""
function read_scalar!(r::BitReader, kind::DatatypeKind, types, max_bits::Int = typemax(Int))
    t = kind.tag
    (is_string_like(kind) || t == K_QNAME || t == K_LIST || t == K_RESTRICTED_STRING) &&
        throw(not_scalar(kind))
    t == K_BOOLEAN && return read_boolean!(r)
    t == K_BOOLEAN_PATTERN && return pattern_to_bool(read_boolean_pattern!(r))
    t == K_INTEGER && return read_integer!(r, max_bits)
    t == K_UNSIGNED && return read_unsigned_any!(r, max_bits)
    t == K_NBIT && return read_nbit!(r, kind.min, kind.bits)
    t == K_DECIMAL && return read_decimal!(r, max_bits)
    t == K_FLOAT && return read_float!(r, max_bits)
    t == K_DATETIME && return read_datetime!(r, kind.datetime, max_bits)
    (t == K_BASE64 || t == K_HEX) && return read_binary!(r)
    count = enum_count(types, kind.set)
    ordinal = read_nbit_unsigned!(r, ceil_log2(count))
    ordinal >= count &&
        throw(ValueError(kind_name(kind), "ordinal $ordinal out of range (count $count)"))
    return enum_ordinal_value(UInt32(ordinal))
end

# Boxed ordinals made once: the decoder keeps values as `Any`, and a fresh
# `EnumOrdinal` there would be an allocation per value.
const ENUM_ORDINALS = Any[EnumOrdinal(UInt32(i)) for i in 0:255]
enum_ordinal_value(o::UInt32) = o < 256 ? (@inbounds ENUM_ORDINALS[o + 1]) : EnumOrdinal(o)
