# Restricted character sets (https://www.w3.org/TR/exi/#restrictedCharSet).
#
# When a string type has pattern facets, EXI may work out a small alphabet from
# them: the characters the patterns can ever match. If that alphabet has fewer
# than 256 characters, all in the BMP, EXI writes each character as a short
# index into it instead of a full code point. Appendix E of the spec says how to
# get the alphabet from an XSD regular expression
# (https://www.w3.org/TR/exi/#regexToCharset).
#
# This file answers "is this type's set restricted?" and, when it is, gives the
# alphabet, which the codec writes characters against. A pattern it cannot
# read gives no alphabet, and values of that type are refused rather than
# written as a plain string (which other readers would turn into garbage with
# no error).
#
# The parser below follows the XSD regex grammar
# (https://www.w3.org/TR/xmlschema-2/#regexs) but only collects characters.
# Quantifiers are read and ignored, since they never add characters.

"""The answer for one type: a restricted set of `n` characters, not restricted, or unreadable."""
abstract type CharsetResult end
struct CharsetRestricted <: CharsetResult
    n::Int
end
struct CharsetNotRestricted <: CharsetResult end
struct CharsetUnreadable <: CharsetResult end

# A set of characters as sorted, non-touching closed ranges of code points.
const CharRanges = Vector{UnitRange{UInt32}}

function normalize_ranges(rs::CharRanges)
    sorted = sort(rs; by = first)
    out = CharRanges()
    for r in sorted
        isempty(r) && continue
        if !isempty(out) && first(r) <= last(out[end]) + 1
            out[end] = first(out[end]):max(last(out[end]), last(r))
        else
            push!(out, r)
        end
    end
    return out
end

union_ranges(a::CharRanges, b::CharRanges) = normalize_ranges(vcat(a, b))

"""The characters of `a` that are not in `b`."""
function subtract_ranges(a::CharRanges, b::CharRanges)
    out = CharRanges()
    for r in a
        lo, hi = first(r), last(r)
        for s in b
            (last(s) < lo || first(s) > hi) && continue
            first(s) > lo && push!(out, lo:(first(s) - 1))
            last(s) >= hi && (lo = hi + 1; break)
            lo = last(s) + 1
        end
        lo <= hi && push!(out, lo:hi)
    end
    return normalize_ranges(out)
end

count_chars(rs::CharRanges) = sum((length(r) for r in rs); init = 0)

# Thrown inside the parser when the pattern does not follow the grammar.
struct RegexSyntax <: Exception end

mutable struct CharsetParser
    s::Vector{Char}
    pos::Int
    # Set once the pattern uses something with a large alphabet (`.`, `\d`,
    # `[^...]`, `\p{..}` and so on). Parsing goes on, to check the syntax.
    open::Bool
end

at_end(p::CharsetParser) = p.pos > length(p.s)
peek_char(p::CharsetParser, k::Int = 0) = p.pos + k <= length(p.s) ? p.s[p.pos + k] : nothing

function take_char!(p::CharsetParser)
    at_end(p) && throw(RegexSyntax())
    c = p.s[p.pos]
    p.pos += 1
    return c
end

function expect_char!(p::CharsetParser, c::Char)
    take_char!(p) == c || throw(RegexSyntax())
    return nothing
end

one_char(c::Char) = CharRanges([UInt32(c):UInt32(c)])

# `\s`: space, tab, line feed, carriage return.
const SPACE_CHARS = normalize_ranges(CharRanges([0x20:0x20, 0x09:0x0a, 0x0d:0x0d]))

# Characters that may follow `\` as a single-character escape
# (https://www.w3.org/TR/xmlschema-2/#nt-SingleCharEsc).
const SINGLE_ESCAPES = Set("\\|.-^?*+{}()[]")

"""
    regexp!(p) -> CharRanges

regExp ::= branch ('|' branch)*. The set is the union of all branches.
"""
function regexp!(p::CharsetParser)
    set = branch!(p)
    while peek_char(p) == '|'
        p.pos += 1
        set = union_ranges(set, branch!(p))
    end
    return set
end

# branch ::= piece*; a piece is an atom and an optional quantifier.
function branch!(p::CharsetParser)
    set = CharRanges()
    while true
        c = peek_char(p)
        (c === nothing || c == '|' || c == ')') && return set
        set = union_ranges(set, atom!(p))
        quantifier!(p)
    end
end

# quantifier ::= [?*+] | '{' quantity '}'. It is checked and then ignored.
function quantifier!(p::CharsetParser)
    c = peek_char(p)
    if c == '?' || c == '*' || c == '+'
        p.pos += 1
    elseif c == '{'
        p.pos += 1
        digits!(p)
        if peek_char(p) == ','
            p.pos += 1
            isdigit(something(peek_char(p), ' ')) && digits!(p)
        end
        expect_char!(p, '}')
    end
    return nothing
end

function digits!(p::CharsetParser)
    isdigit(something(peek_char(p), ' ')) || throw(RegexSyntax())
    while isdigit(something(peek_char(p), ' '))
        p.pos += 1
    end
    return nothing
end

# atom ::= NormalChar | charClass | '(' regExp ')'
function atom!(p::CharsetParser)
    c = take_char!(p)
    if c == '('
        set = regexp!(p)
        expect_char!(p, ')')
        return set
    elseif c == '['
        return class_expr_body!(p)
    elseif c == '\\'
        return escape!(p)
    elseif c == '.'
        p.open = true
        return CharRanges()
    elseif c in ('?', '*', '+', '{', '}', ')', ']', '|')
        throw(RegexSyntax())
    end
    return one_char(c)
end

"""
Reads what follows a `\\`, outside or inside a class. Single-character escapes
give that character, `\\s` gives the four spaces, and every other class escape
has a large alphabet.
"""
function escape!(p::CharsetParser)
    c = take_char!(p)
    c == 'n' && return one_char('\n')
    c == 'r' && return one_char('\r')
    c == 't' && return one_char('\t')
    c in SINGLE_ESCAPES && return one_char(c)
    c == 's' && return copy(SPACE_CHARS)
    if c in ('S', 'i', 'I', 'c', 'C', 'd', 'D', 'w', 'W')
        p.open = true
        return CharRanges()
    end
    if c == 'p' || c == 'P'
        # \p{IsBasicLatin}, \P{L} and so on: skip the name.
        expect_char!(p, '{')
        n = 0
        while (d = take_char!(p)) != '}'
            (isletter(d) || isdigit(d) || d == '-') || throw(RegexSyntax())
            n += 1
        end
        n == 0 && throw(RegexSyntax())
        p.open = true
        return CharRanges()
    end
    throw(RegexSyntax())
end

"""
Reads a character class after its `[`, up to and including the `]`.
charGroup ::= posCharGroup | negCharGroup | charClassSub
"""
function class_expr_body!(p::CharsetParser)
    if peek_char(p) == '^'
        # A negative group matches almost everything.
        p.pos += 1
        p.open = true
    end
    set = CharRanges()
    first_item = true
    while true
        c = take_char!(p)
        if c == ']'
            first_item && throw(RegexSyntax())
            return set
        elseif c == '['
            throw(RegexSyntax())
        elseif c == '-' && peek_char(p) == '['
            # Class subtraction: [a-z-[aeiou]]. It must end the group.
            first_item && throw(RegexSyntax())
            p.pos += 1
            sub = class_expr_body!(p)
            expect_char!(p, ']')
            return subtract_ranges(set, sub)
        end
        first_item = false
        if c == '\\'
            k = peek_char(p)
            # Multi-character escapes cannot start a range.
            if k !== nothing && k in ('s', 'S', 'i', 'I', 'c', 'C', 'd', 'D', 'w', 'W', 'p', 'P')
                set = union_ranges(set, escape!(p))
                continue
            end
            lo = only_char(escape!(p))
        else
            lo = c
        end
        # A range s-e, unless the dash ends the group or starts a subtraction.
        if peek_char(p) == '-' && peek_char(p, 1) !== nothing && peek_char(p, 1) != ']' &&
           peek_char(p, 1) != '['
            p.pos += 1
            e = take_char!(p)
            if e == '\\'
                hi = only_char(escape!(p))
            elseif e == '['
                throw(RegexSyntax())
            else
                hi = e
            end
            hi < lo && throw(RegexSyntax())
            set = union_ranges(set, CharRanges([UInt32(lo):UInt32(hi)]))
        else
            set = union_ranges(set, one_char(lo))
        end
    end
end

function only_char(rs::CharRanges)
    (length(rs) == 1 && length(rs[1]) == 1) || throw(RegexSyntax())
    return Char(first(rs[1]))
end

"""
    pattern_charset(pattern) -> Union{CharRanges,Nothing,CharsetUnreadable}

The characters one XSD pattern can match: the ranges, `nothing` when the
alphabet is large (not restricted), or `CharsetUnreadable()` when the pattern
does not parse.
"""
function pattern_charset(pattern::AbstractString)
    isvalid(pattern) || return CharsetUnreadable()
    p = CharsetParser(collect(pattern), 1, false)
    set = try
        s = regexp!(p)
        at_end(p) || throw(RegexSyntax())
        s
    catch e
        e isa RegexSyntax || rethrow()
        return CharsetUnreadable()
    end
    return p.open ? nothing : set
end

"""
    restricted_charset(patterns) -> CharsetResult

Works out the character set of a type from the patterns written on it
(https://www.w3.org/TR/exi/#regexToCharset). Several patterns on one type mean
"any of them", so their sets are joined. The set is restricted when it has
fewer than 256 characters, all in the BMP (each fits in 16 bits). A pattern
that does not parse gives `CharsetUnreadable`: the caller must not guess. But
if the patterns we can read already make the set too big, the joined set is
too big whatever the unreadable one holds, so the answer is "not restricted".
"""
function restricted_charset(patterns::AbstractVector{<:AbstractString})
    return first(charset_of(patterns))
end

"""
    restricted_alphabet(patterns) -> Union{String,Nothing,CharsetUnreadable}

The alphabet of a restricted set, as a string of its characters in code point
order (the order EXI numbers them in), `nothing` when the set is not
restricted, or `CharsetUnreadable()`.
"""
function restricted_alphabet(patterns::AbstractVector{<:AbstractString})
    r, set = charset_of(patterns)
    r isa CharsetRestricted || return r isa CharsetUnreadable ? r : nothing
    return String([Char(c) for rg in set for c in rg])
end

function charset_of(patterns::AbstractVector{<:AbstractString})
    set = CharRanges()
    isempty(patterns) && return (CharsetNotRestricted(), set)
    open = false
    unreadable = false
    for pat in patterns
        r = pattern_charset(pat)
        if r isa CharsetUnreadable
            unreadable = true
        elseif r === nothing
            open = true
        else
            set = union_ranges(set, r)
        end
    end
    open && return (CharsetNotRestricted(), set)
    n = count_chars(set)
    n < 256 || return (CharsetNotRestricted(), set)
    (isempty(set) || last(set[end]) <= 0xffff) || return (CharsetNotRestricted(), set)
    unreadable && return (CharsetUnreadable(), set)
    return (CharsetRestricted(n), set)
end
