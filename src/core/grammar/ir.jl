# Grammar tables: flat vectors indexed by 0-based UInt32 ids, as in rexi.
#
# Every id is a 0-based index into one vector (the EXI event codes and compact
# identifiers are 0-based too). Julia vectors are 1-based, so the accessors
# below add one; nothing outside this file should index the vectors directly.
#
# A grammar (https://www.w3.org/TR/exi/#grammarNotation) is a set of rules; a
# rule is a list of productions; a production is one allowed event (its
# terminal) plus the rule to go to next. The position of a production within
# its rule is its event code.

const UriId = UInt32
const LocalId = UInt32
const PrefixId = UInt32
const TypeIdx = UInt32
const ElemIdx = UInt32
const GrammarIdx = UInt32
const RuleIdx = UInt32
const EnumSetIdx = UInt32
const StrIdx = UInt32

"""The id that means "none" in the tables."""
const NONE = typemax(UInt32)

"""
    QNameId(uri, local_name)

A qualified name as two compact identifiers: the URI's id in the string table
and the local name's id in that URI's local-name partition.
"""
struct QNameId
    uri::UriId
    local_name::LocalId
end

# The default hash of a plain struct goes through `objectid`, which is slow; the
# value table hashes a context per value.
Base.hash(q::QNameId, h::UInt) = hash((UInt64(q.uri) << 32) | UInt64(q.local_name), h)

Base.isless(a::QNameId, b::QNameId) =
    a.uri < b.uri || (a.uri == b.uri && a.local_name < b.local_name)

"""A run of `len` entries starting at 0-based index `start`."""
struct Span
    start::UInt32
    len::UInt32
end

"""The 1-based Julia range of a span, for indexing a table vector."""
@inline span_range(s::Span) = Int(s.start) + 1:Int(s.start) + Int(s.len)

"""One URI of the initial string table with its prefix and local-name partitions."""
struct UriEntry
    uri::StrIdx
    prefixes::Span
    local_names::Span
end

"""What a production stands for (https://www.w3.org/TR/exi/#grammarNotation)."""
@enum TermKind::UInt8 begin
    T_SD
    T_ED
    T_EE
    # SE(qname): `a` is the element declaration.
    T_SE
    # SE(uri:*): `a` is the URI.
    T_SE_NS
    T_SE_ANY
    # AT(qname): `a`, `b` are the QName, `c` its type.
    T_AT
    # AT(uri:*): `a` is the URI.
    T_AT_NS
    T_AT_ANY
    # CH: `a` is the type.
    T_CH
    T_CH_UNTYPED
    # The rest appear only in built-in and non-strict grammars. They are listed
    # so tables can describe those grammars; the strict codec never writes them.
    # (In strict mode xsi:type and xsi:nil are not productions: they are the
    # second-level codes the runtime adds.)
    T_XSI_TYPE
    T_XSI_NIL
    T_AT_ANY_UNTYPED
    T_NS
    T_SC
    T_CM
    T_PI
    T_DT
    T_ER
end

"""
    Terminal(kind, a, b, c)

The event a production allows. `a`, `b` and `c` hold the kind's ids (see
[`TermKind`](@ref)); the others are zero. A plain bits type, so a vector of
productions has no pointers.
"""
struct Terminal
    kind::TermKind
    a::UInt32
    b::UInt32
    c::UInt32
end

Terminal(kind::TermKind) = Terminal(kind, 0, 0, 0)
term_se(e::Integer) = Terminal(T_SE, UInt32(e), 0, 0)
term_se_ns(uri::Integer) = Terminal(T_SE_NS, UInt32(uri), 0, 0)
term_at(q::QNameId, t::Integer) = Terminal(T_AT, q.uri, q.local_name, UInt32(t))
term_at_ns(uri::Integer) = Terminal(T_AT_NS, UInt32(uri), 0, 0)
term_ch(t::Integer) = Terminal(T_CH, UInt32(t), 0, 0)

term_elem(t::Terminal) = t.a
term_uri(t::Terminal) = t.a
term_qname(t::Terminal) = QNameId(t.a, t.b)
term_type(t::Terminal) = t.kind == T_AT ? t.c : t.a

"""One allowed event and the rule to go to next (`NONE` after EE)."""
struct Production
    terminal::Terminal
    next::RuleIdx
end

"""A rule: its productions, in event-code order."""
struct Rule
    productions::Span
end

"""A grammar: its rules; the first one is the start rule."""
struct Grammar
    rules::Span
end

"""An element declaration: its name, type and whether it may be nil."""
struct ElementDecl
    qname::QNameId
    type_idx::TypeIdx
    nillable::Bool
    is_global::Bool
end

"""
A type: its name (`uri == NONE` when anonymous), its grammar, the grammar used
after `xsi:nil="true"` (TypeEmpty), its datatype when it has simple content,
and whether `xsi:type` may switch it (it has named subtypes, or is a union).
"""
struct TypeDecl
    qname::QNameId
    grammar::GrammarIdx
    empty_grammar::GrammarIdx
    datatype::DatatypeKind
    has_datatype::Bool
    typecastable::Bool
end

is_anonymous(t::TypeDecl) = t.qname.uri == NONE

"""A global attribute declaration."""
struct GlobalAttribute
    qname::QNameId
    type_idx::TypeIdx
end

"""
What is worked out once per `GrammarSet` and shared by every stream that uses
it, each part filled on first use: the initial string table's URI slots (see
`string_table_slots`) and the flat tables the codec walks (see
`runtime_tables`). The tables must not change after their first stream.
"""
mutable struct GrammarCache
    slots::Any
    runtime::Any
end
GrammarCache() = GrammarCache(nothing, nothing)

"""
    GrammarSet

All the grammar tables of one schema. Built at run time by the schema
compiler, or written ahead of time as Julia source by `SchemaGen`.

- `strings`: every string the tables name, referred to by `StrIdx`
- `uris`, `prefixes`, `local_names`: the initial string table (spec D.3); each
  `UriEntry` has spans into `prefixes` and `local_names`, which hold `StrIdx`
- `productions`, `rules`, `grammars`: the grammars
- `elements`, `global_elements` (sorted by local name, then URI, so their
  order is the DocContent event-code order), `global_attributes`, `types`
- `enum_sets` (spans into `enum_values`, which hold `StrIdx`)
- `schema_id`: the schemaId this schema goes by, if any
"""
struct GrammarSet
    strings::Vector{String}
    uris::Vector{UriEntry}
    prefixes::Vector{StrIdx}
    local_names::Vector{StrIdx}
    productions::Vector{Production}
    rules::Vector{Rule}
    grammars::Vector{Grammar}
    elements::Vector{ElementDecl}
    global_elements::Vector{ElemIdx}
    global_attributes::Vector{GlobalAttribute}
    types::Vector{TypeDecl}
    enum_sets::Vector{Span}
    enum_values::Vector{StrIdx}
    schema_id::Union{Nothing,String}
    cache::GrammarCache
end

# The fourteen tables, as SchemaGen writes them; the cache starts empty.
GrammarSet(strings, uris, prefixes, local_names, productions, rules, grammars, elements, global_elements,
    global_attributes, types, enum_sets, enum_values, schema_id) =
    GrammarSet(strings, uris, prefixes, local_names, productions, rules, grammars, elements, global_elements,
        global_attributes, types, enum_sets, enum_values, schema_id, GrammarCache())

"""An empty set of tables (no schema)."""
empty_grammar_set() = GrammarSet(String[], UriEntry[], StrIdx[], StrIdx[], Production[], Rule[],
    Grammar[], ElementDecl[], ElemIdx[], GlobalAttribute[], TypeDecl[], Span[], StrIdx[], nothing)

Base.:(==)(a::GrammarSet, b::GrammarSet) =
    all(getfield(a, f) == getfield(b, f) for f in fieldnames(GrammarSet) if f !== :cache)

@inline gstring(g::GrammarSet, i::Integer) = @inbounds g.strings[Int(i) + 1]
@inline gtype(g::GrammarSet, t::Integer) = g.types[Int(t) + 1]
@inline gelement(g::GrammarSet, e::Integer) = g.elements[Int(e) + 1]
@inline ggrammar(g::GrammarSet, i::Integer) = g.grammars[Int(i) + 1]

"""The productions of `rule`, in event-code order (a view, no copy)."""
@inline function rule_productions(g::GrammarSet, rule::Integer)
    r = g.rules[Int(rule) + 1]
    return view(g.productions, span_range(r.productions))
end

grammar_start_rule(g::GrammarSet, grammar::Integer) = ggrammar(g, grammar).rules.start

uri_str(g::GrammarSet, uri::Integer) =
    0 <= uri < length(g.uris) ? gstring(g, g.uris[Int(uri) + 1].uri) : nothing

function local_name_str(g::GrammarSet, q::QNameId)
    q.uri < length(g.uris) || return nothing
    s = g.uris[Int(q.uri) + 1].local_names
    q.local_name < s.len || return nothing
    return gstring(g, g.local_names[Int(s.start) + Int(q.local_name) + 1])
end

function find_type(g::GrammarSet, q::QNameId)
    i = findfirst(t -> t.qname == q, g.types)
    return i === nothing ? nothing : UInt32(i - 1)
end

function find_global_element(g::GrammarSet, q::QNameId)
    for e in g.global_elements
        gelement(g, e).qname == q && return e
    end
    return nothing
end

"""
The first position (1-based) in `idx` whose string is not less than `key`, by
byte order, which is code-point order for UTF-8.
"""
function lower_bound(g::GrammarSet, idx::AbstractVector{StrIdx}, key::AbstractString)
    lo, hi = 1, length(idx) + 1
    while lo < hi
        mid = (lo + hi) >>> 1
        if gstring(g, idx[mid]) < key
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

"""
    find_qname(g, uri, local) -> Union{Nothing,QNameId}

The compact ids of a name in the initial string table: a scan of the URIs,
then a binary search of the local names, stepping back to the
first of equal neighbors; a linear scan if the partition is not sorted.
"""
function find_qname(g::GrammarSet, uri::AbstractString, local_name::AbstractString)
    u = findfirst(e -> gstring(g, e.uri) == uri, g.uris)
    u === nothing && return nothing
    names = view(g.local_names, span_range(g.uris[u].local_names))
    lo = lower_bound(g, names, local_name)
    if lo <= length(names) && gstring(g, names[lo]) == local_name
        return QNameId(UInt32(u - 1), UInt32(lo - 1))
    end
    i = findfirst(s -> gstring(g, s) == local_name, names)
    return i === nothing ? nothing : QNameId(UInt32(u - 1), UInt32(i - 1))
end

# The tables are the type resolver of the datatype layer.
function datatype(g::GrammarSet, t::Integer)
    0 <= t < length(g.types) || return UNTYPED_KIND
    d = gtype(g, t)
    return d.has_datatype ? d.datatype : UNTYPED_KIND
end

enum_count(g::GrammarSet, set::Integer) = 0 <= set < length(g.enum_sets) ? Int(g.enum_sets[Int(set) + 1].len) : 0

function enum_value(g::GrammarSet, set::Integer, ordinal::Integer)
    0 <= set < length(g.enum_sets) || return nothing
    s = g.enum_sets[Int(set) + 1]
    0 <= ordinal < s.len || return nothing
    return gstring(g, g.enum_values[Int(s.start) + Int(ordinal) + 1])
end

# Well-known URIs and names of the initial string table (spec D.3).
const URI_EMPTY = UriId(0)
const URI_XML = UriId(1)
const URI_XSI = UriId(2)
const URI_XSD = UriId(3)

const XML_NS = "http://www.w3.org/XML/1998/namespace"
const XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
const XSD_NS = "http://www.w3.org/2001/XMLSchema"

const XML_LOCAL_NAMES = ("base", "id", "lang", "space")
const XSI_LOCAL_NAMES = ("nil", "type")
const XSI_NIL_LOCAL = LocalId(0)
const XSI_TYPE_LOCAL = LocalId(1)

const XSD_LOCAL_NAMES = (
    "ENTITIES", "ENTITY", "ID", "IDREF", "IDREFS", "NCName", "NMTOKEN", "NMTOKENS", "NOTATION",
    "Name", "QName", "anySimpleType", "anyType", "anyURI", "base64Binary", "boolean", "byte",
    "date", "dateTime", "decimal", "double", "duration", "float", "gDay", "gMonth", "gMonthDay",
    "gYear", "gYearMonth", "hexBinary", "int", "integer", "language", "long", "negativeInteger",
    "nonNegativeInteger", "nonPositiveInteger", "normalizedString", "positiveInteger", "short",
    "string", "time", "token", "unsignedByte", "unsignedInt", "unsignedLong", "unsignedShort",
)
