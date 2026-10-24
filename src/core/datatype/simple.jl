# Booleans (https://www.w3.org/TR/exi/#encodingBoolean), strings
# (https://www.w3.org/TR/exi/#encodingString) and binary values
# (https://www.w3.org/TR/exi/#encodingBinary).

# The four text forms of a boolean with pattern facets, in wire order: the
# two-bit form keeps which text was used.
const PATTERN_LEXICAL = ("false", "0", "true", "1")

write_boolean!(w::BitWriter, v::Bool) = write_bool!(w, v)
read_boolean!(r::BitReader) = read_bool!(r)

write_boolean_pattern!(w::BitWriter, id::Integer) = write_nbit_unsigned!(w, UInt64(id & 3), 2)
read_boolean_pattern!(r::BitReader) = read_nbit_unsigned!(r, 2) % UInt8

function parse_boolean(s::AbstractString)
    (s == "true" || s == "1") && return true
    (s == "false" || s == "0") && return false
    return nothing
end

function parse_boolean_pattern(s::AbstractString)
    i = findfirst(==(s), PATTERN_LEXICAL)
    return i === nothing ? nothing : UInt8(i - 1)
end

pattern_id_for(v::Bool) = v ? 0x02 : 0x00
pattern_to_bool(id::Integer) = id >= 2

# A string is its length in characters (code points), then each code point as
# an unsigned integer.

"""Writes the code points of `s`, each as an unsigned integer."""
function write_chars!(w::BitWriter, s::AbstractString)
    isvalid(s) || throw(ValueError("String", "text is not valid UTF-8"))
    return write_code_points!(w, s)
end

"""
Writes the code points of `s`, which must be valid UTF-8, each as an unsigned
integer. A code point takes one to three octets (7 bits each, up to U+10FFFF).
The octets are read straight from the UTF-8 bytes, gathered into one word, and
written up to eight at a time.
"""
function write_code_points!(w::BitWriter, s::Union{String,SubString{String}})
    n = ncodeunits(s)
    word = UInt64(0)
    k = 0
    i = 1
    @inbounds while i <= n
        b = UInt32(codeunit(s, i))
        if b < 0x80
            cp = b
            i += 1
        elseif b < 0xe0
            cp = ((b & 0x1f) << 6) | (UInt32(codeunit(s, i + 1)) & 0x3f)
            i += 2
        elseif b < 0xf0
            cp = ((b & 0x0f) << 12) | ((UInt32(codeunit(s, i + 1)) & 0x3f) << 6) | (UInt32(codeunit(s, i + 2)) & 0x3f)
            i += 3
        else
            cp = ((b & 0x07) << 18) | ((UInt32(codeunit(s, i + 1)) & 0x3f) << 12) |
                 ((UInt32(codeunit(s, i + 2)) & 0x3f) << 6) | (UInt32(codeunit(s, i + 3)) & 0x3f)
            i += 4
        end
        # The low 7-bit group goes first, with the high bit set when more follow.
        if cp < 0x80
            word = (word << 8) | cp
            k += 1
        elseif cp < 0x4000
            word = (word << 16) | (UInt64((cp & 0x7f) | 0x80) << 8) | (cp >> 7)
            k += 2
        else
            word = (word << 24) | (UInt64((cp & 0x7f) | 0x80) << 16) | (UInt64(((cp >> 7) & 0x7f) | 0x80) << 8) |
                   (cp >> 14)
            k += 3
        end
        if k > 5
            write_raw_bits!(w, word, 8k)
            word = UInt64(0)
            k = 0
        end
    end
    k > 0 && write_raw_bits!(w, word, 8k)
    return w
end

function write_code_points!(w::BitWriter, s::AbstractString)
    for c in s
        write_unsigned!(w, UInt64(codepoint(c)))
    end
    return w
end

# Restricted character sets (https://www.w3.org/TR/exi/#restrictedCharSet):
# each character is an n-bit index into the alphabet, n = ceil(log2(N + 1)) for
# N characters; index N escapes a character outside it, whose code point follows.

"""Writes the characters of `s` against `alphabet` (its characters in code point order)."""
function write_rcs_chars!(w::BitWriter, s::AbstractString, alphabet::String)
    n = length(alphabet)
    bits = ceil_log2(n + 1)
    for c in s
        i = 0
        for a in alphabet
            (a == c || a > c) && break
            i += 1
        end
        if i < n && alphabet[nextind(alphabet, 0, i + 1)] == c
            write_nbit_unsigned!(w, UInt64(i), bits)
        else
            write_nbit_unsigned!(w, UInt64(n), bits)
            write_unsigned!(w, UInt64(codepoint(c)))
        end
    end
    return w
end

"""Reads `count` characters written against `alphabet`; same checks as `read_chars!`."""
function read_rcs_string!(r::BitReader, count::Integer, alphabet::String)
    n = length(alphabet)
    bits = ceil_log2(n + 1)
    out = IOBuffer(; sizehint = Int(min(count, UInt64(1024))))
    for _ in 1:count
        i = read_nbit_unsigned!(r, bits)
        if i < n
            print(out, alphabet[nextind(alphabet, 0, Int(i) + 1)])
        elseif i == n
            cp = read_unsigned!(r)
            if cp > 0x10ffff || !isvalid(Char, UInt32(cp))
                throw(ValueError("String", "invalid code point $cp"))
            end
            print(out, Char(UInt32(cp)))
        else
            throw(ValueError("String", "restricted character index $i is past the escape $n"))
        end
    end
    return String(take!(out))
end

"""Writes a string: character count, then the code points."""
function write_string!(w::BitWriter, s::AbstractString)
    isvalid(s) || throw(ValueError("String", "text is not valid UTF-8"))
    write_unsigned!(w, UInt64(length(s)))
    return write_chars!(w, s)
end

"""
    read_chars!(r, count, out::IOBuffer)

Reads `count` code points into `out`. A surrogate or a value above U+10FFFF is
a `ValueError`.
"""
function read_chars!(r::BitReader, count::Integer, out::IOBuffer)
    for _ in 1:count
        cp = read_unsigned!(r)
        if cp > 0x10ffff || !isvalid(Char, UInt32(cp))
            throw(ValueError("String", "invalid code point $cp"))
        end
        print(out, Char(UInt32(cp)))
    end
    return out
end

"""
    read_chars_string!(r, count, buf) -> String

Reads `count` code points and returns them as a `String`. The UTF-8 bytes are
built in `buf`, a scratch vector the caller keeps between calls, so a string
costs one allocation (the `String` itself). Same checks as `read_chars!`.
"""
# The next whole octet of a stream that sits `pl` bits off a byte boundary,
# with the new position and pending bits (a plain function, so the caller's
# state stays in registers; a closure over it would box it).
@inline function next_octet(data, i::Int, stop::Int, pl::Int, pend::UInt8, mask::UInt8)
    i > stop && throw(TruncatedError())
    b = @inbounds data[i]
    pl == 0 && return (b, i + 1, pend)
    return ((pend << (8 - pl)) | (b >> pl), i + 1, b & mask)
end

function read_chars_string!(r::BitReader, count::Integer, buf::Vector{UInt8})
    # `buf` only grows (never shrinks), so after the first few strings of a
    # stream no call allocates anything but the result. The reader's position
    # and pending bits live in locals for the whole string and are stored back
    # once at the end: every octet of a character is a whole byte of the
    # stream, shifted by the same `pl` bits.
    data = r.data
    i = r.next
    stop = lastindex(data)
    pl = r.pending_len
    pend = r.pending
    mask = pl == 0 ? 0x00 : (0x01 << pl) - 0x01
    first = i
    n = 0
    for _ in 1:count
        n + 4 > length(buf) && resize!(buf, max(2 * length(buf), n + 64))
        o, i, pend = next_octet(data, i, stop, pl, pend, mask)
        if o < 0x80
            # One-octet unsigned integer: an ASCII character, one UTF-8 byte.
            n += 1
            @inbounds buf[n] = o
            continue
        end
        cp = UInt64(o & 0x7f)
        shift = 7
        while true
            o, i, pend = next_octet(data, i, stop, pl, pend, mask)
            cp |= UInt64(o & 0x7f) << shift
            o < 0x80 && break
            shift += 7
            shift > 28 && throw(ValueError("String", "invalid code point"))
        end
        if cp > 0x10ffff || (0xd800 <= cp <= 0xdfff)
            throw(ValueError("String", "invalid code point $cp"))
        end
        c = UInt32(cp)
        @inbounds if c < 0x800
            buf[n + 1] = (0xc0 | (c >> 6)) % UInt8
            buf[n + 2] = (0x80 | (c & 0x3f)) % UInt8
            n += 2
        elseif c < 0x10000
            buf[n + 1] = (0xe0 | (c >> 12)) % UInt8
            buf[n + 2] = (0x80 | ((c >> 6) & 0x3f)) % UInt8
            buf[n + 3] = (0x80 | (c & 0x3f)) % UInt8
            n += 3
        else
            buf[n + 1] = (0xf0 | (c >> 18)) % UInt8
            buf[n + 2] = (0x80 | ((c >> 12) & 0x3f)) % UInt8
            buf[n + 3] = (0x80 | ((c >> 6) & 0x3f)) % UInt8
            buf[n + 4] = (0x80 | (c & 0x3f)) % UInt8
            n += 4
        end
    end
    r.next = i
    r.pending = pend
    r.bits_read += UInt64(8 * (i - first))
    return GC.@preserve buf unsafe_string(pointer(buf), n)
end

"""Reads a string: character count, then the code points."""
read_string!(r::BitReader) = read_chars_string!(r, read_unsigned!(r), UInt8[])

# Binary values: the byte count as an unsigned integer, then the bytes.

function write_binary!(w::BitWriter, bytes::AbstractVector{UInt8})
    write_unsigned!(w, UInt64(length(bytes)))
    return write_bytes!(w, bytes)
end

"""
Reads a binary value. It grows the result in steps of at most 64 KiB, so a
broken length gives a `TruncatedError` when the stream runs out, not a failed
allocation.
"""
function read_binary!(r::BitReader)
    remaining = read_unsigned!(r)
    # The common case, at most 64 KiB: one vector of the exact size.
    if remaining <= UInt64(1) << 16
        return read_bytes!(r, Vector{UInt8}(undef, Int(remaining)))
    end
    out = UInt8[]
    sizehint!(out, Int(min(remaining, UInt64(1) << 16)))
    while remaining > 0
        take = Int(min(remaining, UInt64(1) << 16))
        start = length(out)
        resize!(out, start + take)
        read_bytes!(r, view(out, (start + 1):(start + take)))
        remaining -= take
    end
    return out
end

const BASE64_ALPHABET = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const HEX_ALPHABET = b"0123456789ABCDEF"

function base64_value(c::UInt8)
    UInt8('A') <= c <= UInt8('Z') && return c - UInt8('A')
    UInt8('a') <= c <= UInt8('z') && return c - UInt8('a') + 0x1a
    UInt8('0') <= c <= UInt8('9') && return c - UInt8('0') + 0x34
    c == UInt8('+') && return 0x3e
    c == UInt8('/') && return 0x3f
    return nothing
end

is_xml_space_byte(c::UInt8) = c == 0x20 || c == 0x0d || c == 0x0a || c == 0x09

"""
    parse_base64(s) -> Union{Nothing,Vector{UInt8}}

Parses `xsd:base64Binary` text. XML spaces anywhere are skipped. The unused low
bits before `=` padding must be zero.
"""
function parse_base64(s::AbstractString)
    data = UInt8[c for c in codeunits(s) if !is_xml_space_byte(c)]
    length(data) % 4 == 0 || return nothing
    quads = length(data) ÷ 4
    out = UInt8[]
    quads == 0 && return out
    sizehint!(out, 3quads)
    for q in 0:(quads - 2)
        b1 = base64_value(data[4q + 1])
        b2 = base64_value(data[4q + 2])
        b3 = base64_value(data[4q + 3])
        b4 = base64_value(data[4q + 4])
        (b1 === nothing || b2 === nothing || b3 === nothing || b4 === nothing) &&
            return nothing
        push!(out, (b1 << 2) | (b2 >> 4), ((b2 & 0x0f) << 4) | ((b3 >> 2) & 0x0f), (b3 << 6) | b4)
    end
    k = 4(quads - 1)
    b1 = base64_value(data[k + 1])
    b2 = base64_value(data[k + 2])
    (b1 === nothing || b2 === nothing) && return nothing
    c3 = data[k + 3]
    c4 = data[k + 4]
    b3 = base64_value(c3)
    b4 = base64_value(c4)
    if b3 === nothing && b4 === nothing && c3 == UInt8('=') && c4 == UInt8('=')
        # `xx==`: one byte. The low 4 bits of the second character are unused.
        b2 & 0x0f == 0 || return nothing
        push!(out, (b1 << 2) | (b2 >> 4))
    elseif b3 !== nothing && b4 === nothing && c3 != UInt8('=') && c4 == UInt8('=')
        # `xxx=`: two bytes. The low 2 bits of the third character are unused.
        b3 & 0x03 == 0 || return nothing
        push!(out, (b1 << 2) | (b2 >> 4), ((b2 & 0x0f) << 4) | ((b3 >> 2) & 0x0f))
    elseif b3 !== nothing && b4 !== nothing
        push!(out, (b1 << 2) | (b2 >> 4), ((b2 & 0x0f) << 4) | ((b3 >> 2) & 0x0f), (b3 << 6) | b4)
    else
        return nothing
    end
    return out
end

"""Formats bytes as `xsd:base64Binary` text, with `=` padding and no line breaks."""
function format_base64(bytes::AbstractVector{UInt8})
    out = IOBuffer(sizehint = 4cld(length(bytes), 3))
    n = length(bytes)
    i = firstindex(bytes)
    while n - (i - firstindex(bytes)) >= 3
        v = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8) | UInt32(bytes[i + 2])
        for shift in (18, 12, 6, 0)
            write(out, BASE64_ALPHABET[((v >> shift) & 0x3f) + 1])
        end
        i += 3
    end
    rest = n - (i - firstindex(bytes))
    if rest == 1
        v = UInt32(bytes[i]) << 16
        write(out, BASE64_ALPHABET[((v >> 18) & 0x3f) + 1], BASE64_ALPHABET[((v >> 12) & 0x3f) + 1])
        write(out, "==")
    elseif rest == 2
        v = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8)
        for shift in (18, 12, 6)
            write(out, BASE64_ALPHABET[((v >> shift) & 0x3f) + 1])
        end
        write(out, '=')
    end
    return String(take!(out))
end

function hex_value(c::UInt8)
    UInt8('0') <= c <= UInt8('9') && return c - UInt8('0')
    UInt8('A') <= c <= UInt8('F') && return c - UInt8('A') + 0x0a
    UInt8('a') <= c <= UInt8('f') && return c - UInt8('a') + 0x0a
    return nothing
end

"""Parses `xsd:hexBinary` text (either case, no spaces)."""
function parse_hex(s::AbstractString)
    cu = codeunits(s)
    length(cu) % 2 == 0 || return nothing
    out = Vector{UInt8}(undef, length(cu) ÷ 2)
    for i in eachindex(out)
        hi = hex_value(cu[2i - 1])
        lo = hex_value(cu[2i])
        (hi === nothing || lo === nothing) && return nothing
        out[i] = (hi << 4) | lo
    end
    return out
end

"""Formats bytes as upper-case `xsd:hexBinary` text."""
function format_hex(bytes::AbstractVector{UInt8})
    out = Vector{UInt8}(undef, 2length(bytes))
    for (i, b) in enumerate(bytes)
        out[2i - 1] = HEX_ALPHABET[(b >> 4) + 1]
        out[2i] = HEX_ALPHABET[(b & 0x0f) + 1]
    end
    return String(out)
end
