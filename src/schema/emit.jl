# From the model to grammar tables (rexi-schema proto/emit.rs,
# proto/string_table.rs and datatype_map.rs).

# ------------------------------------------------------------- datatype map

"""
Maps simple types to datatype kinds (https://www.w3.org/TR/exi/#builtInEXITypes)
and collects the enumeration value sets and the restricted-character-set
alphabets. A restricted kind's `set` numbers its alphabet in `charsets` until
the tables are built, when it becomes the alphabet's `StrIdx`.
"""
mutable struct DatatypeMapper
    model::Model
    cache::Dict{Int,Union{Nothing,DatatypeKind}}
    enum_sets::Vector{Vector{String}}
    charsets::Vector{String}
end

DatatypeMapper(m::Model) =
    DatatypeMapper(m, Dict{Int,Union{Nothing,DatatypeKind}}(), Vector{String}[], String[])

function kind_of!(dm::DatatypeMapper, t::Int)
    haskey(dm.cache, t) && return dm.cache[t]
    k = compute_kind!(dm, t)
    dm.cache[t] = k
    return k
end

function compute_kind!(dm::DatatypeMapper, t::Int)
    0 <= t < length(dm.model.types) || throw(invalid_schema("type index $t out of range"))
    s = as_simple(mtype(dm.model, t))
    s === nothing && return nothing
    v = s.variety
    v isa ListOf && return list_kind(v.item)
    v isa UnionOf && return string_kind(WS_COLLAPSE)
    en = effective_enumeration(dm.model, t)
    en === nothing && return atomic_kind(dm, t)
    return enumeration_kind!(dm, en[1], en[2])
end

function effective_enumeration(m::Model, t::Int)
    for a in ancestors(m, t)
        s = as_simple(mtype(m, a))
        s === nothing && continue
        en = s.facets.enumeration
        en === nothing || return (a, en)
    end
    return nothing
end

function enumeration_kind!(dm::DatatypeMapper, enum_type::Int, values::Vector{String})
    m = dm.model
    # The item type is the nearest base that is not itself an enumeration.
    base = mtype(m, enum_type).base
    while base !== nothing
        k = kind_of!(dm, base)
        (k !== nothing && k.tag == K_ENUMERATION) || break
        base = mtype(m, base).base
    end
    base = something(base, ANY_SIMPLE_TYPE)
    base_kind = something(kind_of!(dm, base), string_kind(WS_PRESERVE))
    bs = as_simple(mtype(m, base))
    base_builtin = closest_builtin(m, base)
    base_kind.tag == K_LIST && return base_kind
    (bs !== nothing && bs.variety isa UnionOf) && return string_kind(WS_COLLAPSE)
    (base_builtin == QNAME_TYPE || base_builtin == NOTATION_TYPE) && return base_kind
    set = length(dm.enum_sets)
    push!(dm.enum_sets, values)
    return enum_kind(set, base)
end

function parse_int_facet(v::AbstractString)
    s = strip(v)
    startswith(s, '+') && (s = s[2:end])
    x = tryparse(Int128, s)
    x === nothing && throw(invalid_schema("integer facet value '$v'"))
    return x
end

"""
The restricted character set of a string type
(https://www.w3.org/TR/exi/#restrictedCharSet), as its alphabet: a string of
its characters in code point order, `nothing` when the type has none, or
`CharsetUnreadable()`. Only types derived from the
built-in `xs:string` count, not every type that is sent as a string (anyURI,
QName, duration and so on are not). The set comes from the patterns written on
the most-derived type in the chain that has any; built-in types never have one.
`below` is the chain from `t` up to, not including, its nearest built-in.
A pattern that cannot be read counts as restricted with no alphabet, so its
values are refused instead of guessed.
"""
function type_alphabet(m::Model, t::Int, below::Vector{Int})
    STRING_TYPE in ancestors(m, t) || return nothing
    for a in below
        s = as_simple(mtype(m, a))
        (s === nothing || isempty(s.facets.patterns)) && continue
        return restricted_alphabet(s.facets.patterns)
    end
    return nothing
end

function atomic_kind(dm::DatatypeMapper, t::Int)
    m = dm.model
    b = something(closest_builtin(m, t), ANY_SIMPLE_TYPE)
    # Types below the built-in, nearest first.
    below = Int[]
    for a in ancestors(m, t)
        a == b && break
        push!(below, a)
    end
    facets(a) = (s = as_simple(mtype(m, a)); s === nothing ? nothing : s.facets)
    c = BUILTINS[b + 1].category
    c isa CatAnyType && return string_kind(WS_PRESERVE)
    if c isa CatString
        ws = c.ws
        for a in below
            f = facets(a)
            f === nothing && continue
            w = f.whitespace
            if w !== nothing
                ws = w
                break
            end
        end
        a = type_alphabet(m, t, below)
        # An unreadable pattern still makes the kind restricted, with no
        # alphabet: its values are refused.
        a isa CharsetUnreadable && return restricted_string_kind(ws)
        if a !== nothing
            push!(dm.charsets, a)
            return restricted_string_kind(ws, length(dm.charsets) - 1)
        end
        return string_kind(ws)
    end
    if c isa CatBoolean
        pattern = any(a -> (f = facets(a); f !== nothing && !isempty(f.patterns)), below)
        return pattern ? BOOLEAN_PATTERN_KIND : BOOLEAN_KIND
    end
    c isa CatDecimal && return DECIMAL_KIND
    c isa CatFloat && return FLOAT_KIND
    c isa CatDateTime && return datetime_kind(c.kind)
    c isa CatBase64 && return BASE64_KIND
    c isa CatHex && return HEX_KIND
    c isa CatList && return list_kind(c.item)
    lo, hi = c.min, c.max
    for a in below
        f = facets(a)
        f === nothing && continue
        mi, me, xi, xe = f.min_inclusive, f.min_exclusive, f.max_inclusive, f.max_exclusive
        if mi !== nothing
            v = parse_int_facet(mi)
            lo = lo === nothing ? v : max(lo, v)
        end
        if me !== nothing
            v = parse_int_facet(me) + 1
            lo = lo === nothing ? v : max(lo, v)
        end
        if xi !== nothing
            v = parse_int_facet(xi)
            hi = hi === nothing ? v : min(hi, v)
        end
        if xe !== nothing
            v = parse_int_facet(xe) - 1
            hi = hi === nothing ? v : min(hi, v)
        end
    end
    return integer_kind(lo, hi)
end

"""
The integer representation for bounds `lo:hi` (https://www.w3.org/TR/exi/#encodingInteger):
n-bit when the range has at most 4096 values, unsigned when `lo >= 0`, else signed.
"""
function integer_kind(lo::Union{Nothing,Integer}, hi::Union{Nothing,Integer})
    if lo !== nothing && hi !== nothing && hi >= lo
        range = UInt128(hi - lo + 1)
        if range <= 4096 && typemin(Int64) <= lo <= typemax(Int64)
            return nbit_kind(Int64(lo), 128 - leading_zeros(range - 1))
        end
    end
    return (lo !== nothing && lo >= 0) ? UNSIGNED_KIND : INTEGER_KIND
end

# ------------------------------------------------------- schema string table

struct UriPartition
    uri::String
    prefixes::Vector{String}
    local_names::Vector{String}
end

"""
The initial string table of a schema (spec D.3): "", xml, xsi and xsd first
with their fixed entries, then the schema's namespaces in sorted order; each
partition holds the sorted local names of every element, attribute and named
type in it.
"""
struct SchemaStrings
    uris::Vector{UriPartition}
end

function SchemaStrings(m::Model)
    names = Dict{String,Set{String}}()
    for ns in m.namespaces
        get!(Set{String}, names, ns)
    end
    for e in m.elements
        push!(get!(Set{String}, names, e.qname.ns), e.qname.local_name)
    end
    for a in m.attributes
        push!(get!(Set{String}, names, a.qname.ns), a.qname.local_name)
    end
    for t in m.types
        (t.name !== nothing && t.name.ns != XSD_NS) && push!(get!(Set{String}, names, t.name.ns), t.name.local_name)
    end
    function partition_names(uri, fixed)
        s = Set{String}(fixed)
        extra = pop!(names, uri, nothing)
        extra === nothing || union!(s, extra)
        return sort!(collect(s))
    end
    uris = [UriPartition("", [""], partition_names("", ())), UriPartition(XML_NS, ["xml"], partition_names(XML_NS, XML_LOCAL_NAMES)),
        UriPartition(XSI_NS, ["xsi"], partition_names(XSI_NS, XSI_LOCAL_NAMES)),
        UriPartition(XSD_NS, String[], partition_names(XSD_NS, XSD_LOCAL_NAMES))]
    for uri in sort!(collect(keys(names)))
        push!(uris, UriPartition(uri, String[], sort!(collect(names[uri]))))
    end
    return SchemaStrings(uris)
end

schema_uri_id(st::SchemaStrings, uri::AbstractString) = (i = findfirst(p -> p.uri == uri, st.uris); i === nothing ? nothing : UInt32(i - 1))

function schema_qname_id(st::SchemaStrings, ns::AbstractString, local_name::AbstractString)
    u = schema_uri_id(st, ns)
    u === nothing && return nothing
    l = findfirst(==(local_name), st.uris[u + 1].local_names)
    return l === nothing ? nothing : QNameId(u, UInt32(l - 1))
end

schema_uri_str(st::SchemaStrings, u::Integer) = 0 <= u < length(st.uris) ? st.uris[u + 1].uri : ""
schema_local_str(st::SchemaStrings, q::QNameId) =
    (0 <= q.uri < length(st.uris) && 0 <= q.local_name < length(st.uris[q.uri + 1].local_names)) ?
    st.uris[q.uri + 1].local_names[q.local_name + 1] : ""

# A grammar set being built, with a string index for interning.
struct TableBuilder
    g::GrammarSet
    index::Dict{String,StrIdx}
end

TableBuilder() = TableBuilder(empty_grammar_set(), Dict{String,StrIdx}())

function intern!(b::TableBuilder, s::AbstractString)
    i = get(b.index, s, nothing)
    i === nothing || return i
    push!(b.g.strings, String(s))
    i = StrIdx(length(b.g.strings) - 1)
    b.index[String(s)] = i
    return i
end

function write_strings!(b::TableBuilder, st::SchemaStrings)
    g = b.g
    for p in st.uris
        u = intern!(b, p.uri)
        ps = length(g.prefixes)
        foreach(x -> push!(g.prefixes, intern!(b, x)), p.prefixes)
        ls = length(g.local_names)
        foreach(x -> push!(g.local_names, intern!(b, x)), p.local_names)
        push!(g.uris, UriEntry(u, Span(ps, length(p.prefixes)), Span(ls, length(p.local_names))))
    end
end

# ---------------------------------------------------------------------- emit

function qname_of(st::SchemaStrings, q::QName)
    id = schema_qname_id(st, q.ns, q.local_name)
    id === nothing && throw(invalid_schema("name $(sprint(show, q)) missing from the string table"))
    return id
end

mutable struct GrammarBuilder
    model::Model
    strings::SchemaStrings
    elem_ir::Vector{ElemIdx}
    order::UInt32
    # The most rules one content grammar may have (nothing: no limit).
    max_rules::Union{Nothing,Int}
end

check_size(gb::GrammarBuilder, rules::Integer) =
    (gb.max_rules !== nothing && rules > gb.max_rules) && throw(too_large(gb.max_rules))

"""
    emit(model; max_grammar_size = 100_000) -> GrammarSet

Builds the grammar tables of a resolved model. One type's content grammar may
have at most `max_grammar_size` rules (`nothing`: no limit).
"""
function emit(m::Model; max_grammar_size::Union{Nothing,Int} = SchemaLoadOptions().max_grammar_size)
    st = SchemaStrings(m)
    b = TableBuilder()
    write_strings!(b, st)
    g = b.g
    # One element declaration for each distinct (qname, type, nillable); it is
    # global if any element sharing it is.
    keys_ = Dict{Tuple{QNameId,TypeIdx,Bool},ElemIdx}()
    elem_ir = ElemIdx[]
    for e in m.elements
        q = qname_of(st, e.qname)
        key = (q, TypeIdx(e.type_id), e.nillable)
        idx = get(keys_, key, nothing)
        if idx === nothing
            idx = ElemIdx(length(g.elements))
            push!(g.elements, ElementDecl(q, TypeIdx(e.type_id), e.nillable, e.is_global))
            keys_[key] = idx
        elseif e.is_global && !g.elements[idx + 1].is_global
            d = g.elements[idx + 1]
            g.elements[idx + 1] = ElementDecl(d.qname, d.type_idx, d.nillable, true)
        end
        push!(elem_ir, idx)
    end
    # Global elements in DocContent order: by local name, then URI
    # (https://www.w3.org/TR/exi/#informedDocGrammars).
    globals = ElemIdx[ElemIdx(i - 1) for (i, e) in enumerate(g.elements) if e.is_global]
    sort!(globals; by = e -> (schema_local_str(st, g.elements[e + 1].qname), schema_uri_str(st, g.elements[e + 1].qname.uri)),
        alg = MergeSort)
    append!(g.global_elements, globals)
    for a in m.attributes
        a.is_global && push!(g.global_attributes, GlobalAttribute(qname_of(st, a.qname), TypeIdx(a.type_id)))
    end
    # Typecastable: the type has a direct named subtype, or is a union, as in
    # EXIficient, which looks through every type (built-ins too) for one whose
    # base is this type. So xs:string, xs:int or xs:decimal are typecastable
    # through their built-in subtypes, and xs:double or xs:boolean are not:
    # https://github.com/EXIficient/exificient-grammars/blob/9baa044237f649a65ae4190aed75081c75c86a16/src/main/java/com/siemens/ct/exi/grammars/XSDGrammarsBuilder.java#L1558-L1582
    has_named_subtype = fill(false, length(m.types))
    for t in m.types
        (t.name !== nothing && t.base !== nothing) && (has_named_subtype[t.base + 1] = true)
    end
    dm = DatatypeMapper(m)
    gb = GrammarBuilder(m, st, elem_ir, 0, max_grammar_size)
    for (i, def) in enumerate(m.types)
        t = i - 1
        full, empty = type_protos!(gb, t)
        grammar = push_grammar!(g, st, full, max_grammar_size)
        empty_grammar = push_grammar!(g, st, empty, max_grammar_size)
        q = def.name === nothing ? QNameId(NONE, NONE) : qname_of(st, def.name)
        s = as_simple(def)
        is_union = s !== nothing && s.variety isa UnionOf
        k = kind_of!(dm, t)
        push!(g.types, TypeDecl(q, grammar, empty_grammar, something(k, UNTYPED_KIND), k !== nothing,
            has_named_subtype[i] || is_union))
    end
    # Each alphabet goes into the string pool, and its kind points at it.
    for (i, td) in enumerate(g.types)
        k = td.datatype
        (k.tag == K_RESTRICTED_STRING && k.set != NONE) || continue
        k = restricted_string_kind(k.whitespace, intern!(b, dm.charsets[Int(k.set) + 1]))
        g.types[i] = TypeDecl(td.qname, td.grammar, td.empty_grammar, k, td.has_datatype, td.typecastable)
    end
    for set in dm.enum_sets
        start = length(g.enum_values)
        foreach(v -> push!(g.enum_values, intern!(b, v)), set)
        push!(g.enum_sets, Span(start, length(set)))
    end
    return g
end

function push_grammar!(g::GrammarSet, st::SchemaStrings, p::Proto, max_grammar_size)
    n = normalize(p; max_grammar_size)
    assign_event_codes!(n, q -> schema_local_str(st, q), u -> schema_uri_str(st, u))
    rules_start = length(g.rules)
    for r in n.rules
        prods_start = length(g.productions)
        for x in r
            push!(g.productions, x.kind == P_TERM ? Production(x.terminal, RuleIdx(rules_start + x.next)) :
                                 Production(Terminal(T_EE), NONE))
        end
        push!(g.rules, Rule(Span(prods_start, length(r))))
    end
    push!(g.grammars, Grammar(Span(rules_start, length(n.rules))))
    return GrammarIdx(length(g.grammars) - 1)
end

function type_protos!(gb::GrammarBuilder, t::Int)
    m = gb.model
    ct = as_complex(mtype(m, t))
    ct === nothing && return (simple_content_proto(TypeIdx(t)), proto_ee())
    uses = Tuple{String,String,Proto}[]
    for u in ct.attributes
        a = mattribute(m, u.attr)
        push!(uses, (a.qname.local_name, a.qname.ns,
            attribute_use_proto(qname_of(gb.strings, a.qname), TypeIdx(a.type_id), u.required)))
    end
    sort!(uses; by = x -> (x[1], x[2]), alg = MergeSort)
    aw = ct.any_attribute
    wildcard = aw === nothing ? Terminal[] :
               aw isa NsList ? Terminal[term_at_ns(uri_id_of(gb, u)) for u in aw.uris] : [Terminal(T_AT_ANY)]
    gb.order = 0
    c = ct.content
    content = c isa EmptyContent ? proto_ee() : c isa SimpleContent ? simple_content_proto(TypeIdx(c.type_id)) :
              particle_of!(gb, c.particle)
    return complex_type_proto(Proto[x[3] for x in uses], wildcard, content, ct.mixed)
end

function uri_id_of(gb::GrammarBuilder, uri::AbstractString)
    u = schema_uri_id(gb.strings, uri)
    u === nothing && throw(invalid_schema("namespace '$uri' missing from the string table"))
    return u
end

next_order!(gb::GrammarBuilder) = (gb.order += 1)

function particle_of!(gb::GrammarBuilder, p::Particle)
    t = p.term
    term = if t isa ElementTerm
        element_term(members_of(gb, t.elem), next_order!(gb))
    elseif t isa AnyTerm
        order = next_order!(gb)
        uris = t.ns isa NsList ? UriId[uri_id_of(gb, u) for u in t.ns.uris] : nothing
        wildcard_term(wildcard_terminals(uris), order)
    else
        ps = Proto[particle_of!(gb, q) for q in t.particles]
        check_size(gb, sum(q -> length(q.rules), ps; init = 0))
        t.compositor == COMP_SEQUENCE ? sequence_proto(ps) : t.compositor == COMP_CHOICE ? choice_proto(ps) :
        all_proto(ps)
    end
    # The particle is `max` copies of the term (or `min` and a loop when
    # unbounded), so check the size before making any of them.
    copies = max(something(p.max, p.min + 1), 1)
    check_size(gb, widemul(length(term.rules), copies))
    return particle_proto(term, p.min, p.max)
end

"""An element and its substitution group, sorted by local name then URI."""
function members_of(gb::GrammarBuilder, e::Int)
    m = gb.model
    ids = [e]
    melement(m, e).is_global && append!(ids, substitution_members(m, e))
    sort!(ids; by = i -> (melement(m, i).qname.local_name, melement(m, i).qname.ns), alg = MergeSort)
    out = ElemIdx[]
    for id in ids
        ir = gb.elem_ir[id + 1]
        ir in out || push!(out, ir)
    end
    return out
end
