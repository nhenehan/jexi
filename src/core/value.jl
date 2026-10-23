# Typed values passed in and out through the event API. Each kind matches one of
# the built-in EXI datatype encodings (https://www.w3.org/TR/exi/#encodingDatatypes).
#
# rexi has one `Value` enum. Here each kind is its own Julia type:
#
# | rexi            | JExi                                          |
# |-----------------|-----------------------------------------------|
# | Lexical(&str)   | `Lexical`: XML text the datatype must parse   |
# | String(&str)    | `String`                                      |
# | Boolean         | `Bool`                                        |
# | Integer(Int)    | `Int64`, or `BigInt` when it does not fit     |
# | Unsigned(Uint)  | `UInt64`, or `BigInt` when it does not fit    |
# | Decimal         | `ExiDecimal`                                  |
# | Float           | `ExiFloat`                                    |
# | DateTime(k, dt) | `ExiDateTime` (it carries its kind)           |
# | Binary(&[u8])   | `Vector{UInt8}`                               |
# | Enum(u32)       | `EnumOrdinal`                                 |
# | List(Vec)       | `ExiList`                                     |

"""
    Lexical(text)

A value in its XML text form (XML Schema calls it the "lexical" form). The
grammar's datatype decides how it is parsed.
"""
struct Lexical
    text::String
end

"""An unsigned integer of any size: `UInt64` when it fits, else `BigInt`."""
const ExiUint = Union{UInt64,BigInt}

# Gives the smallest form of a non-negative integer: UInt64 when it fits.
@inline small_uint(v::UInt64) = v
@inline small_uint(v::BigInt) = v <= typemax(UInt64) ? UInt64(v) : v
small_uint(v::Integer) = small_uint(BigInt(v))

# Gives the smallest form of a signed integer: Int64 when it fits.
@inline small_int(v::Int64) = v
@inline small_int(v::UInt64) = v <= typemax(Int64) ? Int64(v) : BigInt(v)
@inline small_int(v::BigInt) = typemin(Int64) <= v <= typemax(Int64) ? Int64(v) : v
small_int(v::Integer) = small_int(BigInt(v))

"""
    ExiDecimal(negative, integral, fraction_reversed)

A decimal ([EXI 7.1.3](https://www.w3.org/TR/exi/#encodingDecimal)): sign, the
whole-number part, and the digits after the point in reverse order, as an
integer. So `.05` is stored as 50 and `.50` as 5 (trailing zeros cannot be
stored). Zero is never negative.
"""
struct ExiDecimal
    negative::Bool
    integral::ExiUint
    fraction_reversed::ExiUint
    function ExiDecimal(negative::Bool, integral::Integer, fraction_reversed::Integer)
        i = small_uint(integral isa BigInt ? integral : UInt64(integral))
        f = small_uint(fraction_reversed isa BigInt ? fraction_reversed : UInt64(fraction_reversed))
        return new(negative && !(iszero(i) && iszero(f)), i, f)
    end
end

Base.:(==)(a::ExiDecimal, b::ExiDecimal) =
    a.negative == b.negative && a.integral == b.integral &&
    a.fraction_reversed == b.fraction_reversed
Base.hash(d::ExiDecimal, h::UInt) =
    hash(d.fraction_reversed, hash(d.integral, hash(d.negative, hash(:ExiDecimal, h))))

"""
    ExiFloat(mantissa, exponent)

A float ([EXI 7.1.4](https://www.w3.org/TR/exi/#encodingFloat)):
`mantissa * 10^exponent`. The exponent `-16384` marks the special values:
mantissa 1 is +INF, -1 is -INF, and anything else is NaN.
"""
struct ExiFloat
    mantissa::Int64
    exponent::Int16
end

const FLOAT_SPECIAL_EXPONENT = Int16(-16384)
const FLOAT_INFINITY = ExiFloat(1, FLOAT_SPECIAL_EXPONENT)
const FLOAT_NEG_INFINITY = ExiFloat(-1, FLOAT_SPECIAL_EXPONENT)
const FLOAT_NAN = ExiFloat(0, FLOAT_SPECIAL_EXPONENT)

"""
Which XML Schema date/time type a value belongs to
([EXI 7.1.8](https://www.w3.org/TR/exi/#encodingDateTime), Table 7-4).
"""
@enum DateTimeKind::UInt8 begin
    DTK_DATETIME
    DTK_DATE
    DTK_TIME
    DTK_GYEAR
    DTK_GYEARMONTH
    DTK_GMONTH
    DTK_GMONTHDAY
    DTK_GDAY
end

"""
    ExiDateTime(kind; year, month, day, hour, minute, second, fractional_secs, timezone)

A date/time value ([EXI 7.1.8](https://www.w3.org/TR/exi/#encodingDateTime)).
Which fields mean anything depends on `kind`. `fractional_secs` holds the digits
after the point reversed (`.5` is 5, `.05` is 50); `timezone` is the offset from
UTC in minutes. Both are `nothing` when absent.
"""
struct ExiDateTime
    kind::DateTimeKind
    year::Int64
    month::UInt8
    day::UInt8
    hour::UInt8
    minute::UInt8
    second::UInt8
    fractional_secs::Union{Nothing,UInt64}
    timezone::Union{Nothing,Int16}
end

ExiDateTime(
    kind::DateTimeKind;
    year::Integer = 0,
    month::Integer = 0,
    day::Integer = 0,
    hour::Integer = 0,
    minute::Integer = 0,
    second::Integer = 0,
    fractional_secs::Union{Nothing,Integer} = nothing,
    timezone::Union{Nothing,Integer} = nothing,
) = ExiDateTime(
    kind,
    Int64(year),
    UInt8(month),
    UInt8(day),
    UInt8(hour),
    UInt8(minute),
    UInt8(second),
    fractional_secs === nothing ? nothing : UInt64(fractional_secs),
    timezone === nothing ? nothing : Int16(timezone),
)

"""
    EnumOrdinal(ordinal)

Position (from 0) of an enumeration value, in the order the schema lists them
([EXI 7.2](https://www.w3.org/TR/exi/#encodingEnumerations)).
"""
struct EnumOrdinal
    ordinal::UInt32
end

"""
    ExiList(items)

The items of a List value ([EXI 7.1.11](https://www.w3.org/TR/exi/#encodingList)).
"""
struct ExiList
    items::Vector{Any}
end

Base.:(==)(a::ExiList, b::ExiList) = a.items == b.items
Base.hash(l::ExiList, h::UInt) = hash(l.items, hash(:ExiList, h))
