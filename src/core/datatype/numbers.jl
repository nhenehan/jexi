# Decimals (https://www.w3.org/TR/exi/#encodingDecimal) and floats
# (https://www.w3.org/TR/exi/#encodingFloat).

"""
    digits_to_uint(s) -> Union{Nothing,UInt64,BigInt}

Parses a run of ASCII digits (at least one, no sign) as an unsigned integer.
"""
function digits_to_uint(s::AbstractString)
    isempty(s) && return nothing
    all(c -> '0' <= c <= '9', s) || return nothing
    v = tryparse(UInt64, s)
    return v === nothing ? parse(BigInt, s) : v
end

"""An integer as a decimal with no digits after the point."""
decimal_from_int(v::Int64) = ExiDecimal(v < 0, v < 0 ? UInt64(-(v + 1)) + 1 : UInt64(v), 0)
decimal_from_int(v::UInt64) = ExiDecimal(false, v, 0)
decimal_from_int(v::BigInt) = ExiDecimal(v < 0, small_uint(abs(v)), 0)
decimal_from_int(v::Integer) = decimal_from_int(BigInt(v))

"""
    decimal_from_lexical(s) -> Union{Nothing,ExiDecimal}

Parses an `xsd:decimal` text form: an optional sign, digits, and an optional
point with more digits (`5.` and `.5` are both allowed, as XSD allows them).
"""
function decimal_from_lexical(s::AbstractString)
    negative = false
    rest = s
    if startswith(s, '-')
        negative = true
        rest = SubString(s, 2)
    elseif startswith(s, '+')
        rest = SubString(s, 2)
    end
    dot = findfirst('.', rest)
    int_part = dot === nothing ? rest : SubString(rest, 1, prevind(rest, dot))
    frac_part = dot === nothing ? "" : SubString(rest, nextind(rest, dot))
    (isempty(int_part) && isempty(frac_part)) && return nothing
    integral = isempty(int_part) ? UInt64(0) : digits_to_uint(int_part)
    integral === nothing && return nothing
    fraction = isempty(frac_part) ? UInt64(0) : digits_to_uint(reverse(frac_part))
    fraction === nothing && return nothing
    return ExiDecimal(negative, integral, fraction)
end

"""The standard text form of a decimal: always a point, at least one digit after."""
function decimal_to_lexical(d::ExiDecimal)
    return string(d.negative ? "-" : "", d.integral, '.', reverse(string(d.fraction_reversed)))
end

function write_decimal!(w::BitWriter, d::ExiDecimal)
    write_bool!(w, d.negative)
    write_unsigned!(w, d.integral)
    return write_unsigned!(w, d.fraction_reversed)
end

function read_decimal!(r::BitReader, max_bits::Int = typemax(Int))
    negative = read_bool!(r)
    integral = read_unsigned_any!(r, max_bits)
    fraction = read_unsigned_any!(r, max_bits)
    return ExiDecimal(negative, integral, fraction)
end

# Exponents must lie in -(2^14 - 1) .. 2^14 - 1; -2^14 marks the special values.
const FLOAT_EXPONENT_LIMIT = 16383

is_special(f::ExiFloat) = f.exponent == FLOAT_SPECIAL_EXPONENT

"""
    float_normalized(mantissa, exponent) -> Union{Nothing,ExiFloat}

Puts a float in its one standard form, as EXIficient does: trailing zeros move
from the mantissa into the exponent, zero has exponent 0, and the special
exponent keeps only mantissa 1 (INF), -1 (-INF) or 0 (NaN). `nothing` when the
exponent is out of range.
"""
function float_normalized(mantissa::Int64, exponent::Int64)
    special = Int64(FLOAT_SPECIAL_EXPONENT)
    if mantissa == 0
        exponent != special && (exponent = 0)
    else
        while mantissa % 10 == 0
            mantissa = mantissa ÷ 10
            exponent += 1
        end
    end
    if exponent == special && mantissa != 1 && mantissa != -1
        mantissa = 0
    end
    if exponent != special && !(-FLOAT_EXPONENT_LIMIT <= exponent <= FLOAT_EXPONENT_LIMIT)
        return nothing
    end
    return ExiFloat(mantissa, Int16(exponent))
end

"""
    float_from_lexical(s) -> Union{Nothing,ExiFloat}

Parses an `xsd:float` / `xsd:double` text form. The mantissa must fit in an
`Int64` (as in EXIficient); the result is in standard form. Zeros at the end of
the digits go into the exponent as they are read, so a whole number past 2^63
written out in full (`10000000000000000000`) still fits, where EXIficient
overflows.
"""
function float_from_lexical(s::AbstractString)
    s == "INF" && return FLOAT_INFINITY
    s == "-INF" && return FLOAT_NEG_INFINITY
    s == "NaN" && return FLOAT_NAN
    b = codeunits(s)
    n = length(b)
    index_e = findfirst(==(UInt8('E')), b)
    index_e === nothing && (index_e = findfirst(==(UInt8('e')), b))
    mantissa_end = index_e === nothing ? n : index_e - 1
    negative = n > 0 && b[1] == UInt8('-')
    i = (n > 0 && (b[1] == UInt8('-') || b[1] == UInt8('+'))) ? 2 : 1
    i > mantissa_end && return nothing
    magnitude = UInt64(0)
    dec_point = false
    decimal_digits = 0
    digits = 0
    # Zeros are only multiplied in when a later digit is not zero. Zeros at the end
    # go into the exponent instead (they would be moved there anyway), so a whole
    # number like 1e19 written out in full, "10000000000000000000", is mantissa 1
    # and does not overflow the Int64. Zeros before the first other digit change
    # nothing.
    pending_zeros = 0
    while i <= mantissa_end
        c = b[i]
        if c == UInt8('0')
            pending_zeros += 1
            dec_point && (decimal_digits += 1)
            digits += 1
        elseif UInt8('1') <= c <= UInt8('9')
            if magnitude == 0
                magnitude = UInt64(c - UInt8('0'))
            else
                scale = pending_zeros >= 19 ? nothing : UInt64(10)^(pending_zeros + 1)
                scale === nothing && return nothing
                next = widemul(magnitude, scale) + (c - UInt8('0'))
                next > typemax(UInt64) && return nothing
                magnitude = UInt64(next)
            end
            pending_zeros = 0
            dec_point && (decimal_digits += 1)
            digits += 1
        elseif c == UInt8('.') && !dec_point
            dec_point = true
        else
            return nothing
        end
        i += 1
    end
    digits == 0 && return nothing
    # The mantissa must fit in Int64. A negative value may reach 2^63 (that is,
    # typemin(Int64)).
    if negative
        magnitude > UInt64(1) << 63 && return nothing
        mantissa = -(magnitude % Int64)
    else
        magnitude > typemax(Int64) && return nothing
        mantissa = Int64(magnitude)
    end
    exponent = Int64(0)
    if index_e !== nothing
        j = index_e + 1
        negative_exp = j <= n && b[j] == UInt8('-')
        (j <= n && (b[j] == UInt8('-') || b[j] == UInt8('+'))) && (j += 1)
        j > n && return nothing
        while j <= n
            c = b[j]
            UInt8('0') <= c <= UInt8('9') || return nothing
            next = widemul(exponent, Int64(10)) + (c - UInt8('0'))
            next > typemax(Int64) && return nothing
            exponent = Int64(next)
            j += 1
        end
        negative_exp && (exponent = -exponent)
    end
    # Each digit after the point lowers the exponent by one. The range is
    # checked here, before zeros are stripped, and again in `float_normalized`.
    exponent -= decimal_digits
    magnitude != 0 && (exponent += pending_zeros)
    -FLOAT_EXPONENT_LIMIT <= exponent <= FLOAT_EXPONENT_LIMIT || return nothing
    return float_normalized(mantissa, exponent)
end

"""The standard text form of a float, as EXIficient writes it: `7325E-2`, `INF`, `NaN`."""
function float_to_lexical(f::ExiFloat)
    if is_special(f)
        f.mantissa == 1 && return "INF"
        f.mantissa == -1 && return "-INF"
        return "NaN"
    end
    return string(f.mantissa, 'E', f.exponent)
end

function write_float!(w::BitWriter, f::ExiFloat)
    write_integer!(w, f.mantissa)
    return write_integer!(w, Int64(f.exponent))
end

function read_float!(r::BitReader, max_bits::Int = typemax(Int))
    mantissa = read_integer!(r, max_bits)
    mantissa isa Int64 || throw(ValueError("Float", "mantissa exceeds 64 bits"))
    exponent = read_integer!(r, max_bits)
    exponent isa Int64 || throw(ValueError("Float", "exponent exceeds 64 bits"))
    f = float_normalized(mantissa, exponent)
    f === nothing && throw(ValueError("Float", "exponent $exponent out of range"))
    return f
end
