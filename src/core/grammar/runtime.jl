# Walking the grammar tables: the state both the encoder and the decoder keep.
#
# Event codes (https://www.w3.org/TR/exi/#eventCodes): the first level is the
# production's position in its rule, `ceil_log2(productions + escape)` bits
# wide. In strict mode xsi:type and xsi:nil are not productions: while an
# element is still in its start rule (and not nil), one extra first-level code
# (equal to the number of productions) escapes to a second level, with code 0
# for xsi:type (when typecastable) and the next for xsi:nil (when nillable)
# (https://www.w3.org/TR/exi/#addingProductionsStrict).

"""Where the document is outside any element."""
@enum DocCursor::UInt8 CUR_DOCUMENT CUR_DOC_CONTENT CUR_DOC_END CUR_DONE

"""
The state of one open element: its current and start rule, its name (the
context of its values), declaration and type, the escape flags, whether
`xsi:nil="true"` was seen, and `xml:space` (-1 not set, 0 default, 1 preserve).
"""
struct Frame
    rule::RuleIdx
    start_rule::RuleIdx
    context::QNameId
    elem::ElemIdx
    type_idx::TypeIdx
    nillable::Bool
    typecastable::Bool
    nil::Bool
    space_preserve::Int8
end

with_rule(f::Frame, rule::RuleIdx) =
    Frame(rule, f.start_rule, f.context, f.elem, f.type_idx, f.nillable, f.typecastable, f.nil, f.space_preserve)

with_space(f::Frame, sp::Int8) =
    Frame(f.rule, f.start_rule, f.context, f.elem, f.type_idx, f.nillable, f.typecastable, f.nil, sp)

"""After `xsi:type`: the target type's grammar, with no escapes left (as EXIficient)."""
cast_to(f::Frame, start::RuleIdx, t::TypeIdx) =
    Frame(start, start, f.context, f.elem, t, false, false, f.nil, f.space_preserve)

"""After `xsi:nil="true"`: the TypeEmpty grammar."""
nil_to(f::Frame, start::RuleIdx) =
    Frame(start, f.start_rule, f.context, f.elem, f.type_idx, f.nillable, f.typecastable, true, f.space_preserve)

escape_count(f::Frame) = (f.rule == f.start_rule && !f.nil) ? Int(f.typecastable) + Int(f.nillable) : 0

first_level_width(g::GrammarSet, f::Frame) =
    ceil_log2(length(rule_productions(g, f.rule)) + (escape_count(f) > 0 ? 1 : 0))

second_level_width(f::Frame) = ceil_log2(escape_count(f))

xsi_type_code(f::Frame) = (escape_count(f) > 0 && f.typecastable) ? 0 : nothing
xsi_nil_code(f::Frame) = (escape_count(f) > 0 && f.nillable) ? Int(f.typecastable) : nothing

"""
    find_production(pred, g, rule) -> Union{Nothing,Tuple{Int,Production}}

The first production of `rule` whose terminal passes `pred`, with its 0-based
event code.
"""
@inline function find_production(pred::F, g::GrammarSet, rule::RuleIdx) where {F}
    prods = rule_productions(g, rule)
    for i in eachindex(prods)
        p = prods[i]
        pred(p.terminal) && return (i - 1, p)
    end
    return nothing
end

"""A frame for a newly opened element `elem`, in its type's start rule."""
function element_frame(g::GrammarSet, elem::ElemIdx)
    d = gelement(g, elem)
    t = gtype(g, d.type_idx)
    start = grammar_start_rule(g, t.grammar)
    return Frame(start, start, d.qname, elem, d.type_idx, d.nillable, t.typecastable, false, Int8(-1))
end

"""
Flat tables the codec reads on every event, worked out once per `GrammarSet`:
each rule's first production (0-based) and production count, the frame each
element starts in, each type's datatype (`UNTYPED_KIND` when it has none), and
the compact ids of every name in the initial string table, by text.
"""
struct RuntimeTables
    rule_first::Vector{UInt32}
    rule_len::Vector{UInt32}
    elem_frames::Vector{Frame}
    kinds::Vector{DatatypeKind}
    qnames::Dict{Tuple{String,String},QNameId}
end

function qname_map(g::GrammarSet)
    d = Dict{Tuple{String,String},QNameId}()
    for (u, e) in enumerate(g.uris)
        uri = gstring(g, e.uri)
        for (l, s) in enumerate(view(g.local_names, span_range(e.local_names)))
            # The first of equal names wins, as in `find_qname`.
            get!(d, (uri, gstring(g, s)), QNameId(UInt32(u - 1), UInt32(l - 1)))
        end
    end
    return d
end

"""The compact ids of a name, by text (see `find_qname`); `nothing` if unknown."""
@inline lookup_qname(rt::RuntimeTables, uri::AbstractString, local_name::AbstractString) =
    get(rt.qnames, (uri, local_name), nothing)

function runtime_tables(g::GrammarSet)
    c = g.cache.runtime
    c === nothing || return c::RuntimeTables
    rt = RuntimeTables(UInt32[r.productions.start for r in g.rules], UInt32[r.productions.len for r in g.rules],
        Frame[element_frame(g, ElemIdx(e - 1)) for e in eachindex(g.elements)],
        DatatypeKind[datatype(g, t - 1) for t in eachindex(g.types)], qname_map(g))
    g.cache.runtime = rt
    return rt
end

function describe_qname(g::GrammarSet, q::QNameId)
    u = uri_str(g, q.uri)
    l = local_name_str(g, q)
    return qname_text(u === nothing ? "?" : u, l === nothing ? "?" : l)
end

function describe_terminal(g::GrammarSet, t::Terminal)
    k = t.kind
    k == T_SD && return "SD"
    k == T_ED && return "ED"
    k == T_EE && return "EE"
    k == T_SE && return "SE($(describe_qname(g, gelement(g, t.a).qname)))"
    k == T_SE_NS && return "SE($(something(uri_str(g, t.a), "?")):*)"
    k == T_SE_ANY && return "SE(*)"
    k == T_AT && return "AT($(describe_qname(g, term_qname(t))))"
    k == T_AT_NS && return "AT($(something(uri_str(g, t.a), "?")):*)"
    k == T_AT_ANY && return "AT(*)"
    k == T_CH && return "CH"
    k == T_CH_UNTYPED && return "CH[untyped]"
    return string(k)
end

"""The events a rule allows, for error messages."""
function describe_rule(g::GrammarSet, rule::RuleIdx, f::Union{Nothing,Frame} = nothing)
    parts = [describe_terminal(g, p.terminal) for p in rule_productions(g, rule)]
    if f !== nothing
        xsi_type_code(f) === nothing || push!(parts, "AT(xsi:type)")
        xsi_nil_code(f) === nothing || push!(parts, "AT(xsi:nil)")
    end
    return "one of [" * join(parts, ", ") * "]"
end
