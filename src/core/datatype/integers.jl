# Unsigned integers (https://www.w3.org/TR/exi/#encodingUnsignedInteger), signed
# integers (https://www.w3.org/TR/exi/#encodingInteger) and n-bit bounded
# integers (https://www.w3.org/TR/exi/#encodingBoundedUnsigned).
#
# An unsigned integer is a run of octets. Each octet holds 7 bits of the value,
# least significant group first; its high bit is 1 when more octets follow. The
# octets are always whole (8 bits), even bit-packed, and even byte-aligned they
# are the same octets.

"""
    write_unsigned!(w, value)

Writes an unsigned integer as 7-bit groups. Values below 128 take one octet.
Otherwise up to eight octets are built in one word and written with one call;
longer values go on one octet at a time.
"""
@inline function write_unsigned!(w::BitWriter, value::UInt64)
    value < 0x80 && return write_byte!(w, value % UInt8)
    # The first octet in the stream (least significant group) ends up as the
    # most significant byte of `word`, so writing `word` from the top gives the
    # right order. A word holds 8 octets: 56 value bits.
    word = UInt64(0)
    v = value
    for len in 1:8
        octet = v & 0x7f
        v >>= 7
        v != 0 && (octet |= 0x80)
        word = (word << 8) | octet
        v == 0 && return write_raw_bits!(w, word, 8len)
    end
    write_raw_bits!(w, word, 64)
    while true
        octet = (v & 0x7f) % UInt8
        v >>= 7
        v != 0 && (octet |= 0x80)
        write_byte!(w, octet)
        v == 0 && return w
    end
end

function write_unsigned!(w::BitWriter, value::BigInt)
    value < 0 && throw(ValueError("Unsigned Integer", "$value is negative"))
    value <= typemax(UInt64) && return write_unsigned!(w, UInt64(value))
    n = value
    while true
        octet = UInt8(n & 0x7f)
        n >>= 7
        n != 0 && (octet |= 0x80)
        write_byte!(w, octet)
        n == 0 && return w
    end
end

write_unsigned!(w::BitWriter, value::Unsigned) = write_unsigned!(w, UInt64(value))

"""
    read_unsigned!(r) -> UInt64

Reads an unsigned integer that must fit in 64 bits (lengths, code points).
"""
function read_unsigned!(r::BitReader)
    o = read_byte!(r)
    o < 0x80 && return UInt64(o)
    value = UInt64(o & 0x7f)
    shift = 7
    while true
        octet = read_byte!(r)
        low = UInt64(octet & 0x7f)
        if shift >= 64 || (shift > 57 && (low >> (64 - shift)) != 0)
            throw(ValueError("Unsigned Integer", "value exceeds 64 bits"))
        end
        value |= low << shift
        octet & 0x80 == 0 && return value
        shift += 7
    end
end

"""
    read_unsigned_any!(r, max_bits = typemax(Int)) -> Union{UInt64,BigInt}

Reads an unsigned integer of any size. It stays in a `UInt64` while the value
fits and moves to a `BigInt` only when it must. The result is a
`UInt64` whenever the value fits, even if the stream used extra zero groups.

`max_bits` is the decoder's `max_integer_bits` cap: once the 7-bit groups add
up to more bits than that, it throws a `LimitError` before building the value.
"""
function read_unsigned_any!(r::BitReader, max_bits::Int = typemax(Int))
    # Most values are one octet: the fast path, then the general case.
    o = r.next <= lastindex(r.data) && r.pending_len == 0 ? (@inbounds r.data[r.next]) : 0xff
    if o < 0x80 && max_bits >= 7
        r.next += 1
        r.bits_read += UInt64(8)
        return UInt64(o)::ExiUint
    end
    value = UInt64(0)
    shift = 0
    while true
        shift + 7 > max_bits && throw(LimitError(:integer_bits, max_bits))
        octet = read_byte!(r)
        low = UInt64(octet & 0x7f)
        # A zero group always fits, since it adds nothing.
        fits = low == 0 || shift <= 57 || (shift < 64 && (low >> (64 - shift)) == 0)
        fits || return read_big_unsigned!(r, value, octet, shift, max_bits)
        low != 0 && (value |= low << shift)
        octet & 0x80 == 0 && return value::ExiUint
        shift += 7
    end
end

"""
Finishes an unsigned integer that does not fit in 64 bits. `value` holds the
groups below bit `shift`, and `octet` is the group at `shift`. The groups are
packed into bytes first and the `BigInt` is built once at the end, so the time
grows in line with the size (adding to a `BigInt` group by group would grow
with the square of it).
"""
function read_big_unsigned!(r::BitReader, value::UInt64, octet::UInt8, shift::Int, max_bits::Int)
    # Little-endian bytes of the value: first the 64-bit part, then the groups.
    bytes = UInt8[(value >> (8i)) % UInt8 for i in 0:7]
    put_group!(bytes, octet & 0x7f, shift)
    while octet & 0x80 != 0
        shift += 7
        shift + 7 > max_bits && throw(LimitError(:integer_bits, max_bits))
        octet = read_byte!(r)
        put_group!(bytes, octet & 0x7f, shift)
    end
    # Hex text, most significant byte first; base 16 parses in linear time.
    big = parse(BigInt, bytes2hex(reverse!(bytes)); base = 16)
    return small_uint(big)::ExiUint
end

"""ORs the 7-bit `group` into the little-endian `bytes` at bit `shift`."""
function put_group!(bytes::Vector{UInt8}, group::UInt8, shift::Int)
    need = (shift + 7 + 7) >> 3
    while length(bytes) < need
        push!(bytes, 0x00)
    end
    i = shift >> 3 + 1
    s = shift & 7
    bytes[i] |= (group << s) % UInt8
    s > 1 && (bytes[i + 1] |= group >> (8 - s))
    return nothing
end

"""
    write_integer!(w, value)

Writes a signed integer: a sign bit (1 for negative), then the magnitude as an
unsigned integer. A negative value stores `|v| - 1`, so zero has one form.
"""
function write_integer!(w::BitWriter, value::Int64)
    if value < 0
        write_bool!(w, true)
        # |v| - 1 == -(v + 1), which cannot overflow for any negative v.
        return write_unsigned!(w, UInt64(-(value + 1)))
    end
    write_bool!(w, false)
    return write_unsigned!(w, UInt64(value))
end

function write_integer!(w::BitWriter, value::BigInt)
    if value < 0
        write_bool!(w, true)
        return write_unsigned!(w, -(value + 1))
    end
    write_bool!(w, false)
    return write_unsigned!(w, value)
end

write_integer!(w::BitWriter, value::Integer) = write_integer!(w, small_int(value))

"""
    read_integer!(r, max_bits = typemax(Int)) -> Union{Int64,BigInt}

Reads a signed integer. The result is an `Int64` whenever the value fits.
`max_bits` caps the size of the magnitude, as in `read_unsigned_any!`.
"""
function read_integer!(r::BitReader, max_bits::Int = typemax(Int))
    negative = read_bool!(r)
    m = read_unsigned_any!(r, max_bits)
    if m isa UInt64
        if m <= typemax(Int64)
            v = Int64(m)
            return (negative ? -v - 1 : v)::Union{Int64,BigInt}
        end
        return (negative ? -BigInt(m) - 1 : BigInt(m))::Union{Int64,BigInt}
    end
    return small_int(negative ? -m - 1 : m)::Union{Int64,BigInt}
end

nbit_max(bits::Integer) = (Int128(1) << min(bits, 64)) - 1

"""
    write_nbit!(w, value, min, bits)

Writes a bounded integer as its offset from `min`, `bits` wide. Fails when the
value is outside `min:min + 2^bits - 1`.
"""
function write_nbit!(w::BitWriter, value::Integer, min::Int64, bits::Integer)
    fits = typemin(Int64) <= value <= typemax(Int64)
    offset = fits ? Int128(value) - Int128(min) : Int128(-1)
    if !(0 <= offset <= nbit_max(bits))
        throw(ValueError(
            "n-bit Unsigned Integer",
            "$value is outside the bounded range $min..=$(Int128(min) + nbit_max(bits))",
        ))
    end
    return write_nbit_unsigned!(w, UInt64(offset), bits)
end

"""Reads a bounded integer and adds `min` back."""
function read_nbit!(r::BitReader, min::Int64, bits::Integer)
    v = Int128(min) + Int128(read_nbit_unsigned!(r, bits))
    v > typemax(Int64) &&
        throw(ValueError("n-bit Unsigned Integer", "decoded value exceeds Int64"))
    return Int64(v)
end
