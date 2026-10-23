# EXIficient's grammar dump format (rexi-schema dump.rs), so the compiled
# grammars can be compared with the oracle's `dump-grammars` output.
#
# EXIficient keeps separate grammar objects where JExi shares rules: the
# first start tag of an element that is nillable or typecastable (its own
# object), of a type, the element content after the attributes, and an "end"
# after simple content. The dumper rebuilds those objects from the tables, then
# numbers them in the order EXIficient visits them.

@enum DNodeKind::UInt8 begin
    DN_DOCUMENT
    DN_DOC_CONTENT
    DN_DOC_END
    DN_END
    DN_SIMPLE_END
    DN_ELEM_START
    DN_TYPE_START
    DN_CONTENT
    DN_CONTENT_ORIG
    DN_RULE
    DN_FRAGMENT
    DN_FRAGMENT_CONTENT
end

struct DNode
    kind::DNodeKind
    idx::UInt32
end
DNode(k::DNodeKind) = DNode(k, 0)

struct DProd
    label::String
    elem_grammar::Union{Nothing,DNode}
    next::DNode
end

struct RuleInfo
    type_idx::TypeIdx
    start_tag::Bool
end

mutable struct Dumper
    g::GrammarSet
    rule_info::Dict{RuleIdx,RuleInfo}
    bounds::Vector{Tuple{RuleIdx,RuleIdx}}
    ids::Dict{DNode,Int}
    order::Vector{DNode}
end

Dumper(g::GrammarSet) = Dumper(g, Dict{RuleIdx,RuleInfo}(), Tuple{RuleIdx,RuleIdx}[], Dict{DNode,Int}(), DNode[])

is_attribute_term(t::Terminal) = t.kind == T_AT || t.kind == T_AT_NS || t.kind == T_AT_ANY

"""
    exificient_dump(g) -> String

The grammars of `g` in EXIficient 1.0.7's `dump-grammars` format.
"""
function exificient_dump(g::GrammarSet)
    d = Dumper(g)
    analyse!(d)
    number!(d)
    return render(d)
end

function analyse!(d::Dumper)
    g = d.g
    for (i, td) in enumerate(g.types)
        ti = TypeIdx(i - 1)
        r0 = grammar_start_rule(g, td.grammar)
        gr = ggrammar(g, td.grammar)
        for r in gr.rules.start:(gr.rules.start + gr.rules.len - 1)
            d.rule_info[RuleIdx(r)] = RuleInfo(ti, false)
        end
        # The attribute chain: rules reached from r0 through AT(qname), breadth first.
        chain = RuleIdx[r0]
        k = 1
        while k <= length(chain)
            r = chain[k]
            k += 1
            for p in rule_productions(g, r)
                (p.terminal.kind == T_AT && p.next != NONE && !(p.next in chain)) && push!(chain, p.next)
            end
        end
        content_start = r0
        for r in chain
            if !any(p -> p.terminal.kind == T_AT, rule_productions(g, r))
                content_start = r
                break
            end
        end
        for r in chain
            info = get(d.rule_info, r, nothing)
            info === nothing || (d.rule_info[r] = RuleInfo(info.type_idx, true))
        end
        push!(d.bounds, (r0, content_start))
    end
end

function elem_node(d::Dumper, e::Integer)
    decl = gelement(d.g, e)
    castable = 0 <= decl.type_idx < length(d.g.types) && gtype(d.g, decl.type_idx).typecastable
    return (castable || decl.nillable) ? DNode(DN_ELEM_START, e) : DNode(DN_TYPE_START, decl.type_idx)
end

dump_qname(d::Dumper, q::QNameId) =
    string('{', something(uri_str(d.g, q.uri), ""), '}', something(local_name_str(d.g, q), ""))

function dump_type_name(d::Dumper, ti::Integer)
    (0 <= ti < length(d.g.types) && !is_anonymous(gtype(d.g, ti))) && return dump_qname(d, gtype(d.g, ti).qname)
    return "{}<anonymous>"
end

const WS_NAMES = Dict(WS_PRESERVE => "preserve", WS_REPLACE => "replace", WS_COLLAPSE => "collapse")

function datatype_text(d::Dumper, ti::Integer)
    st = dump_type_name(d, ti)
    k = datatype(d.g, ti)
    t = k.tag
    if t == K_STRING || t == K_UNTYPED || t == K_RESTRICTED_STRING
        ws = t == K_UNTYPED ? WS_PRESERVE : k.whitespace
        return "[STRING schema-type=$st id=exi_string ws=$(WS_NAMES[ws])]"
    end
    t == K_BOOLEAN && return "[BOOLEAN schema-type=$st id=exi_boolean ws=collapse]"
    t == K_BOOLEAN_PATTERN && return "[BOOLEAN_FACET schema-type=$st id=exi_boolean ws=collapse]"
    t == K_INTEGER && return "[INTEGER schema-type=$st id=exi_integer ws=collapse]"
    t == K_UNSIGNED && return "[UNSIGNED_INTEGER schema-type=$st id=exi_integer ws=collapse]"
    if t == K_NBIT
        upper = Int128(k.min) + (Int128(1) << k.bits) - 1
        return "[NBIT_UNSIGNED_INTEGER schema-type=$st id=exi_integer lower=$(k.min) upper=$upper bits=$(Int(k.bits)) ws=collapse]"
    end
    t == K_DECIMAL && return "[DECIMAL schema-type=$st id=exi_decimal ws=collapse]"
    t == K_FLOAT && return "[FLOAT schema-type=$st id=exi_double ws=collapse]"
    t == K_DATETIME && return "[DATETIME schema-type=$st id=exi_$(datetime_kind_name(k.datetime)) ws=collapse]"
    t == K_BASE64 && return "[BINARY_BASE64 schema-type=$st id=exi_base64Binary ws=collapse]"
    t == K_HEX && return "[BINARY_HEX schema-type=$st id=exi_hexBinary ws=collapse]"
    t == K_QNAME && return "[QNAME schema-type=$st id=exi_qname ws=collapse]"
    if t == K_ENUMERATION
        values = [enum_value(d.g, k.set, i) for i in 0:(enum_count(d.g, k.set) - 1)]
        n = max(length(values), 1)
        bits = 64 - leading_zeros(UInt64(n - 1))
        return "[ENUMERATION schema-type=$st id=$(datatype_id(d, k.item)) bits=$bits values=[$(join(values, '|'))] ws=collapse]"
    end
    return "[LIST schema-type=$st id=$(datatype_id(d, k.item)) item=$(datatype_text(d, k.item)) ws=collapse]"
end

function datatype_id(d::Dumper, ti::Integer)
    k = datatype(d.g, ti)
    t = k.tag
    (t == K_BOOLEAN || t == K_BOOLEAN_PATTERN) && return "exi_boolean"
    (t == K_INTEGER || t == K_UNSIGNED || t == K_NBIT) && return "exi_integer"
    t == K_DECIMAL && return "exi_decimal"
    t == K_FLOAT && return "exi_double"
    t == K_DATETIME && return "exi_" * datetime_kind_name(k.datetime)
    t == K_BASE64 && return "exi_base64Binary"
    t == K_HEX && return "exi_hexBinary"
    t == K_QNAME && return "exi_qname"
    (t == K_ENUMERATION || t == K_LIST) && return datatype_id(d, k.item)
    return "exi_string"
end

function terminal_label(d::Dumper, t::Terminal)
    k = t.kind
    k == T_SD && return "SD"
    k == T_ED && return "ED"
    k == T_EE && return "EE"
    k == T_SE && return "SE " * dump_qname(d, gelement(d.g, t.a).qname)
    k == T_SE_NS && return "SE {$(something(uri_str(d.g, t.a), ""))}*"
    k == T_SE_ANY && return "SE *"
    k == T_AT && return "AT $(dump_qname(d, term_qname(t))) $(datatype_text(d, t.c))"
    k == T_AT_NS && return "AT {$(something(uri_str(d.g, t.a), ""))}*"
    k == T_AT_ANY && return "AT *"
    k == T_CH && return "CH " * datatype_text(d, t.a)
    k == T_CH_UNTYPED && return "CH *"
    return string(k)
end

function map_rule(d::Dumper, r::RuleIdx, ti::TypeIdx, self_node::DNode, content_node::Bool)
    r0, r2 = 0 <= ti < length(d.bounds) ? d.bounds[ti + 1] : (NONE, NONE)
    out = DProd[]
    for p in rule_productions(d.g, r)
        attr = is_attribute_term(p.terminal)
        (content_node && attr) && continue
        eg = p.terminal.kind == T_SE ? elem_node(d, p.terminal.a) : nothing
        next = if p.next == NONE
            DNode(DN_END)
        elseif p.terminal.kind == T_CH
            DNode(DN_SIMPLE_END)
        elseif p.next == r0 && attr
            self_node
        elseif p.next == r2 && attr
            DNode(DN_RULE, r2)
        elseif p.next == r2 || p.next == r0
            DNode(DN_CONTENT_ORIG, ti)
        else
            DNode(DN_RULE, p.next)
        end
        push!(out, DProd(terminal_label(d, p.terminal), eg, next))
    end
    return out
end

function dump_productions(d::Dumper, n::DNode)
    g = d.g
    k = n.kind
    k == DN_DOCUMENT && return [DProd("SD", nothing, DNode(DN_DOC_CONTENT))]
    if k == DN_DOC_CONTENT
        v = DProd[DProd(terminal_label(d, term_se(e)), elem_node(d, e), DNode(DN_DOC_END)) for e in g.global_elements]
        push!(v, DProd("SE *", nothing, DNode(DN_DOC_END)))
        return v
    end
    k == DN_DOC_END && return [DProd("ED", nothing, DNode(DN_END))]
    k == DN_END && return DProd[]
    k == DN_SIMPLE_END && return [DProd("EE", nothing, DNode(DN_END))]
    if k == DN_ELEM_START
        ti = gelement(g, n.idx).type_idx
        return map_rule(d, d.bounds[ti + 1][1], ti, n, false)
    end
    k == DN_TYPE_START && return map_rule(d, d.bounds[n.idx + 1][1], n.idx, n, false)
    (k == DN_CONTENT || k == DN_CONTENT_ORIG) && return map_rule(d, d.bounds[n.idx + 1][2], n.idx, n, true)
    if k == DN_RULE
        info = get(d.rule_info, n.idx, nothing)
        return info === nothing ? DProd[] : map_rule(d, n.idx, info.type_idx, n, false)
    end
    k == DN_FRAGMENT && return [DProd("SD", nothing, DNode(DN_FRAGMENT_CONTENT))]
    # Fragment content: every element, global or local, by local name then URI,
    # each name once.
    elems = collect(UInt32(0):UInt32(length(g.elements) - 1))
    sort!(elems; by = e -> (something(local_name_str(g, gelement(g, e).qname), ""),
            something(uri_str(g, gelement(g, e).qname.uri), "")), alg = MergeSort)
    v = DProd[]
    seen = QNameId[]
    for e in elems
        q = gelement(g, e).qname
        q in seen && continue
        push!(seen, q)
        push!(v, DProd(terminal_label(d, term_se(e)), elem_node(d, e), DNode(DN_FRAGMENT_CONTENT)))
    end
    push!(v, DProd("SE *", nothing, DNode(DN_FRAGMENT_CONTENT)), DProd("ED", nothing, DNode(DN_END)))
    return v
end

function element_content(d::Dumper, n::DNode)
    n.kind == DN_ELEM_START && return DNode(DN_CONTENT, gelement(d.g, n.idx).type_idx)
    n.kind == DN_TYPE_START && return DNode(DN_CONTENT, n.idx)
    if n.kind == DN_RULE
        info = get(d.rule_info, n.idx, nothing)
        (info !== nothing && info.start_tag) && return DNode(DN_CONTENT, info.type_idx)
    end
    return nothing
end

function visit!(d::Dumper, n::DNode)
    haskey(d.ids, n) && return
    d.ids[n] = length(d.order)
    push!(d.order, n)
    for p in dump_productions(d, n)
        p.elem_grammar === nothing || visit!(d, p.elem_grammar)
        visit!(d, p.next)
    end
    ec = element_content(d, n)
    ec === nothing || visit!(d, ec)
end

function number!(d::Dumper)
    visit!(d, DNode(DN_DOCUMENT))
    # Named types in string-table order (URI, then local name).
    named = sort!([(t.qname, TypeIdx(i - 1)) for (i, t) in enumerate(d.g.types) if !is_anonymous(t)])
    for (_, ti) in named
        visit!(d, DNode(DN_TYPE_START, ti))
    end
    visit!(d, DNode(DN_FRAGMENT))
end

dump_id(d::Dumper, n::DNode) = haskey(d.ids, n) ? d.ids[n] : typemax(UInt64)

function dump_header(d::Dumper, n::DNode, prods::Vector{DProd})
    has_ee = any(p -> p.label == "EE", prods)
    declared = count(p -> startswith(p.label, "AT {"), prods)
    ecn = element_content(d, n)
    ec = ecn === nothing ? 0 : dump_id(d, ecn)
    k = n.kind
    k == DN_DOCUMENT && return "type=DOCUMENT declared-attributes=0 label=\"Document\" has-EE=false"
    k == DN_DOC_CONTENT && return "type=SCHEMA_INFORMED_DOC_CONTENT declared-attributes=0 label=\"DocContent\" has-EE=false"
    k == DN_DOC_END && return "type=DOC_END declared-attributes=0 label=\"DocEnd\" has-EE=false"
    k == DN_END && return "type=SCHEMA_INFORMED_ELEMENT_CONTENT declared-attributes=0 label=\"<END>\" has-EE=false"
    k == DN_FRAGMENT && return "type=FRAGMENT declared-attributes=0 label=\"Fragment\" has-EE=false"
    k == DN_FRAGMENT_CONTENT &&
        return "type=SCHEMA_INFORMED_FRAGMENT_CONTENT declared-attributes=0 label=\"FragmentContent\" has-EE=false"
    if k == DN_ELEM_START
        decl = gelement(d.g, n.idx)
        castable = 0 <= decl.type_idx < length(d.g.types) && gtype(d.g, decl.type_idx).typecastable
        return "type=SCHEMA_INFORMED_FIRST_START_TAG_CONTENT nillable=$(decl.nillable) typecastable=$castable declared-attributes=$declared has-EE=$has_ee element-content=$ec"
    end
    k == DN_TYPE_START &&
        return "type=SCHEMA_INFORMED_FIRST_START_TAG_CONTENT nillable=false typecastable=false declared-attributes=$declared has-EE=$has_ee element-content=$ec"
    (k == DN_RULE && ecn !== nothing) &&
        return "type=SCHEMA_INFORMED_START_TAG_CONTENT declared-attributes=$declared has-EE=$has_ee element-content=$ec"
    return "type=SCHEMA_INFORMED_ELEMENT_CONTENT declared-attributes=0 has-EE=$has_ee"
end

function render(d::Dumper)
    g = d.g
    io = IOBuffer()
    println(io, "# rexi grammar dump")
    println(io, "schema-informed true")
    println(io, "schema-id ", g.schema_id === nothing ? "<none>" : g.schema_id)
    println(io, "uri-contexts ", length(g.uris))
    println(io, "qname-contexts ", length(g.local_names))
    println(io, "\n# string table (Appendix D initial uri / prefix / local-name partitions)")
    for (ui, u) in enumerate(g.uris)
        prefixes = ["\"$(gstring(g, s))\"" for s in view(g.prefixes, span_range(u.prefixes))]
        println(io, "uri $(ui - 1) \"$(gstring(g, u.uri))\" prefixes=[$(join(prefixes, ','))]")
        for (li, s) in enumerate(view(g.local_names, span_range(u.local_names)))
            q = QNameId(ui - 1, li - 1)
            line = "  local $(li - 1) \"$(gstring(g, s))\""
            ti = findfirst(t -> t.qname == q, g.types)
            ti === nothing || (line *= " type-grammar=$(dump_id(d, DNode(DN_TYPE_START, ti - 1)))")
            e = find_global_element(g, q)
            e === nothing || (line *= " global-element=$(dump_id(d, elem_node(d, e)))")
            println(io, line)
        end
    end
    println(io, "\n# grammars")
    println(io, "document-grammar ", dump_id(d, DNode(DN_DOCUMENT)))
    println(io, "fragment-grammar ", dump_id(d, DNode(DN_FRAGMENT)))
    for (id, n) in enumerate(d.order)
        prods = dump_productions(d, n)
        println(io, "grammar $(id - 1) $(dump_header(d, n, prods))")
        for (i, p) in enumerate(prods)
            eg = p.elem_grammar === nothing ? "" : " grammar=$(dump_id(d, p.elem_grammar))"
            println(io, "  $(i - 1): $(p.label)$eg -> $(dump_id(d, p.next))")
        end
    end
    return String(take!(io))
end
