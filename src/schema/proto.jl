# Proto-grammars: grammars still being built, before normalization
# (https://www.w3.org/TR/exi/#informedGrammars, rexi-schema proto/). A rule is
# a list of productions; a production is a terminal with its next rule, an EE
# (the end), or a bare non-terminal (a jump to another rule, removed by
# normalization). `order` is the schema position of an SE terminal, used to
# order SE event codes. Rules are numbered from 0.

@enum PKind::UInt8 P_TERM P_EE P_NONTERM

struct PProd
    kind::PKind
    terminal::Terminal
    next::Int
    order::UInt32
end

pterm(t::Terminal, next::Integer, order::Integer = 0) = PProd(P_TERM, t, Int(next), UInt32(order))
const P_END = PProd(P_EE, Terminal(T_EE), 0, 0)
pnonterm(k::Integer) = PProd(P_NONTERM, Terminal(T_EE), Int(k), 0)

const PRule = Vector{PProd}

struct Proto
    rules::Vector{PRule}
end

proto_ee() = Proto([[P_END]])
Base.copy(p::Proto) = Proto([copy(r) for r in p.rules])

"""Appends `other`'s rules (renumbered) and returns the offset they start at."""
function append_proto!(p::Proto, other::Proto)
    offset = length(p.rules)
    for r in other.rules
        push!(p.rules, PProd[x.kind == P_EE ? x : PProd(x.kind, x.terminal, x.next + offset, x.order) for x in r])
    end
    return offset
end

"""Turns every EE into a jump to rule `target`."""
function replace_ee!(p::Proto, target::Int)
    for r in p.rules, i in eachindex(r)
        r[i].kind == P_EE && (r[i] = pnonterm(target))
    end
    return p
end

"""
Many grammars joined in a row: the same result as joining them one by one with
`concat`, but quicker. After a join, only the grammar added last still has EEs,
so only its rules are scanned, and nothing is copied twice; the time then grows
with the total size, not with its square. An empty list gives the grammar that
only ends.
"""
function concat_all(parts)
    acc = nothing
    tail = 1  # the first rule (1-based) of the grammar added last
    for g in parts
        if acc === nothing
            acc = copy(g)
            continue
        end
        offset = length(acc.rules)
        for k in tail:offset, i in eachindex(acc.rules[k])
            acc.rules[k][i].kind == P_EE && (acc.rules[k][i] = pnonterm(offset))
        end
        append_proto!(acc, g)
        tail = offset + 1
    end
    return acc === nothing ? proto_ee() : acc
end

"""`left` then `right`: left's ends jump to right's start."""
function concat(left::Proto, right::Proto)
    g = copy(left)
    replace_ee!(g, length(g.rules))
    append_proto!(g, right)
    return g
end

rule_has_ee(p::Proto, rule::Int) = any(x -> x.kind == P_EE, p.rules[rule + 1])

"""SE terminals for an element and its substitution group, one rule then EE."""
element_term(members::Vector{ElemIdx}, order::Integer) =
    Proto([PProd[pterm(term_se(e), 1, order) for e in members], [P_END]])

wildcard_term(terms::Vector{Terminal}, order::Integer) =
    Proto([PProd[pterm(t, 1, order) for t in terms], [P_END]])

wildcard_terminals(uris::Union{Nothing,Vector{UriId}}) =
    uris === nothing ? [Terminal(T_SE_ANY)] : Terminal[term_se_ns(u) for u in uris]

"""
    particle_proto(term, min, max)

A term repeated `min` to `max` times (https://www.w3.org/TR/exi/#particleGrammars):
copies chained, the copies past `min` optional; unbounded ends in a loop.
"""
function particle_proto(term::Proto, min::Int, max::MaxOccurs)
    function optional_copy(i)
        c = copy(term)
        (i >= min && !rule_has_ee(c, 0)) && push!(c.rules[1], P_END)
        return c
    end
    if max !== nothing
        max == 0 && return proto_ee()
        return concat_all(optional_copy(i) for i in 0:(max - 1))
    end
    last = copy(term)
    replace_ee!(last, 0)
    rule_has_ee(last, 0) || push!(last.rules[1], P_END)
    return concat_all(Iterators.flatten(((term for _ in 1:min), (last,))))
end

sequence_proto(ps::Vector{Proto}) = concat_all(ps)

function choice_proto(ps::Vector{Proto})
    isempty(ps) && return proto_ee()
    g = Proto([PProd[]])
    for p in ps
        off = append_proto!(g, p)
        push!(g.rules[1], pnonterm(off))
    end
    return g
end

"""xs:all as a choice repeated any number of times (as EXIficient builds it)."""
function all_proto(ps::Vector{Proto})
    g = Proto([[P_END]])
    for p in ps
        off = append_proto!(g, p)
        for r in g.rules[(off + 1):end], i in eachindex(r)
            r[i].kind == P_EE && (r[i] = pnonterm(0))
        end
        push!(g.rules[1], pnonterm(off))
    end
    return g
end

function attribute_use_proto(q::QNameId, t::TypeIdx, required::Bool)
    first = PProd[pterm(term_at(q, t), 1)]
    required || push!(first, P_END)
    return Proto([first, [P_END]])
end

simple_content_proto(t::TypeIdx) = Proto([[pterm(term_ch(t), 1)], [P_END]])

"""
    complex_type_proto(uses, wildcard, content, mixed) -> (full, empty)

The type grammar (attribute uses, then content) and its TypeEmpty grammar
(https://www.w3.org/TR/exi/#complexTypeGrammars). An attribute wildcard is
added to every attribute-use rule; mixed content gets an untyped CH in every
content rule.
"""
function complex_type_proto(uses::Vector{Proto}, wildcard::Vector{Terminal}, content::Proto, mixed::Bool)
    us = [copy(u) for u in uses]
    if !isempty(wildcard)
        push!(us, Proto([[P_END], [P_END]]))
        for g in us, t in wildcard
            push!(g.rules[1], pterm(t, 0))
        end
    end
    isempty(us) && push!(us, proto_ee())
    c = copy(content)
    if mixed
        for (j, r) in enumerate(c.rules)
            push!(r, pterm(Terminal(T_CH_UNTYPED), j - 1))
        end
    end
    tg = us[1]
    for i in 2:length(us)
        tg = concat(tg, us[i])
    end
    return (concat(tg, c), concat(tg, proto_ee()))
end

# ---------------------------------------------------------------- normalization

# A set of original rules as a bitset (rexi CR: union rules keyed by bitsets).
struct RuleSet
    words::Vector{UInt64}
end
RuleSet(n::Int) = RuleSet(zeros(UInt64, cld(max(n, 1), 64)))
function rule_set_one(n::Int, r::Int)
    s = RuleSet(n)
    s.words[r ÷ 64 + 1] |= UInt64(1) << (r % 64)
    return s
end
Base.:(==)(a::RuleSet, b::RuleSet) = a.words == b.words
Base.hash(a::RuleSet, h::UInt) = hash(a.words, h)
union_with!(a::RuleSet, b::RuleSet) = (a.words .|= b.words; a)
has_two_or_more(a::RuleSet) = sum(count_ones, a.words) > 1
function set_members(a::RuleSet)
    out = Int[]
    for (k, w) in enumerate(a.words), b in 0:63
        (w >> b) & 1 == 1 && push!(out, (k - 1) * 64 + b)
    end
    return out
end

# A depth-first walk with its own stack of (rule, next production to look at),
# not recursion: a long chain of jumps would otherwise use up the call stack.
# The order of the output is the same as a recursive walk.
function expand_into!(p::Proto, k::Int, visited::Vector{Bool}, out::Vector{PProd})
    stack = [(k, 1)]
    while !isempty(stack)
        rule, i = pop!(stack)
        prods = p.rules[rule + 1]
        i > length(prods) && continue
        push!(stack, (rule, i + 1))
        x = prods[i]
        if x.kind == P_NONTERM
            if !visited[x.next + 1]
                visited[x.next + 1] = true
                push!(stack, (x.next, 1))
            end
        else
            push!(out, x)
        end
    end
    return out
end

"""How many productions normalizing may make, for each rule `max_grammar_size` allows."""
const PRODUCTIONS_PER_RULE = 100

"""
    normalize(proto; max_grammar_size = nothing) -> Proto

Normalizes a proto-grammar (https://www.w3.org/TR/exi/#normalizeGrammars):
1. each bare non-terminal is replaced by the productions it stands for;
2. productions with the same terminal are merged, going to a union rule of
   their targets (each union made once, unions of unions flattened; the
   smaller `order` is kept; EE kept once);
3. only rules reachable from rule 0 are kept, renumbered in breadth-first order.

With `max_grammar_size`, it throws "schema too large" once more than
`max_grammar_size * PRODUCTIONS_PER_RULE` productions have been made. The work
can grow with the square of the grammar's size: in a chain of n optional
particles each rule can skip to every later one, so expanding the jumps makes
about n * n / 2 productions. `maxOccurs="20000"` is only 40,000 rules but would
need about 200 million productions, so the count is checked as they are made.
"""
function normalize(p::Proto; max_grammar_size::Union{Nothing,Int} = nothing)
    n = length(p.rules)
    n == 0 && return proto_ee()
    made = 0
    function count!(k)
        made += k
        (max_grammar_size !== nothing && made > max_grammar_size * PRODUCTIONS_PER_RULE) &&
            throw(too_large(max_grammar_size))
    end
    rules = Vector{Vector{PProd}}(undef, n)
    for j in 0:(n - 1)
        out = PProd[]
        visited = fill(false, n)
        visited[j + 1] = true
        expand_into!(p, j, visited, out)
        count!(length(out))
        rules[j + 1] = out
    end
    members = [rule_set_one(n, i) for i in 0:(n - 1)]
    unions = Dict{RuleSet,Int}()
    # A union rule gets its productions only when the loop reaches it; by then
    # every original rule is merged, so it copies a few merged productions per
    # member instead of the raw ones (raw copies made maxOccurs="100" slow).
    filled = fill(true, n)
    i = 0
    while i < length(rules)
        if !filled[i + 1]
            rules[i + 1] = PProd[x for m in set_members(members[i + 1]) for x in rules[m + 1]]
            count!(length(rules[i + 1]))
            filled[i + 1] = true
        end
        out = PProd[]
        targets = RuleSet[]
        for x in rules[i + 1]
            if x.kind == P_EE
                if !any(y -> y.kind == P_EE, out)
                    push!(out, P_END)
                    push!(targets, RuleSet(n))
                end
            elseif x.kind == P_TERM
                pos = findfirst(y -> y.kind == P_TERM && y.terminal == x.terminal, out)
                if pos === nothing
                    push!(out, x)
                    push!(targets, RuleSet(copy(members[x.next + 1].words)))
                else
                    y = out[pos]
                    out[pos] = PProd(y.kind, y.terminal, y.next, min(y.order, x.order))
                    union_with!(targets[pos], members[x.next + 1])
                end
            end
        end
        for k in eachindex(out)
            x = out[k]
            if x.kind == P_TERM && has_two_or_more(targets[k])
                s = targets[k]
                u = get(unions, s, nothing)
                if u === nothing
                    u = length(rules)
                    push!(rules, PProd[])
                    push!(filled, false)
                    push!(members, s)
                    unions[s] = u
                end
                out[k] = PProd(x.kind, x.terminal, u, x.order)
            end
        end
        rules[i + 1] = out
        i += 1
    end
    # Keep the rules reachable from rule 0, numbered in breadth-first order.
    map = Dict{Int,Int}(0 => 0)
    order = [0]
    q = 1
    while q <= length(order)
        r = order[q]
        q += 1
        for x in rules[r + 1]
            if x.kind == P_TERM && !haskey(map, x.next)
                map[x.next] = length(order)
                push!(order, x.next)
            end
        end
    end
    return Proto([PProd[x.kind == P_TERM ? PProd(x.kind, x.terminal, get(map, x.next, 0), x.order) : x
                        for x in rules[r + 1]] for r in order])
end

# --------------------------------------------------------------- event codes

"""
The sort key of a production (https://www.w3.org/TR/exi/#eventCodeAssignment):
AT(qname) by local name then URI, AT(uri:*) by URI, AT(*), SE by schema order,
SE(uri:*), SE(*), EE, CH.
"""
function event_code_key(x::PProd, local_of, uri_of)
    x.kind == P_EE && return (6, "", "", UInt32(0))
    x.kind == P_NONTERM && return (9, "", "", UInt32(0))
    t = x.terminal
    k = t.kind
    k == T_AT && return (0, local_of(term_qname(t)), uri_of(t.a), UInt32(0))
    k == T_AT_NS && return (1, uri_of(t.a), "", UInt32(0))
    k == T_AT_ANY && return (2, "", "", UInt32(0))
    k == T_SE && return (3, "", "", x.order)
    k == T_SE_NS && return (4, "", "", x.order)
    k == T_SE_ANY && return (5, "", "", UInt32(0))
    k == T_EE && return (6, "", "", UInt32(0))
    (k == T_CH || k == T_CH_UNTYPED) && return (7, "", "", UInt32(0))
    return (8, "", "", x.order)
end

"""Sorts each rule's productions into event-code order (stable)."""
function assign_event_codes!(p::Proto, local_of, uri_of)
    for r in p.rules
        sort!(r; by = x -> event_code_key(x, local_of, uri_of), alg = MergeSort)
    end
    return p
end
