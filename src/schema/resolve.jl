# Resolving the raw documents into the model (rexi-schema xsd/resolve.rs):
# built-ins first, then names registered, then global elements and attributes
# in document order, then every named type. Groups and attribute groups are
# inlined, derivations merged, and types resolved when first needed, with a
# check for circular derivation.

mutable struct Resolver
    model::Model
    named_types::Dict{QName,Int}
    raw_types::Dict{QName,Union{RawSimpleType,RawComplexType}}
    resolved::Vector{Bool}
    resolving::Vector{Int}
    groups::Dict{QName,RawGroup}
    attr_groups::Dict{QName,RawAttributeGroup}
    raw_global_elements::Dict{QName,RawElement}
    raw_global_attributes::Dict{QName,RawAttribute}
    global_elements::Dict{QName,Int}
    global_attributes::Dict{QName,Int}
    # The groups being expanded right now, outermost first. A group met again
    # while it is on this list refers back to itself, which would never end.
    expanding_groups::Vector{QName}
    # Particles made so far for the type whose content is being resolved, and the
    # most allowed (max_grammar_size), so group references that each expand
    # several others cannot grow without end.
    particles::Int
    max_particles::Union{Nothing,Int}
end

too_large(max) = SchemaError("schema too large: one type's content expands past $max (raise max_grammar_size to allow it)")

unresolved(kind::AbstractString, q::QName) = SchemaError("unresolved $kind $(sprint(show, q))")
invalid_schema(msg::AbstractString) = SchemaError("invalid schema: $msg")

"""
    resolve(docs; max_grammar_size = 100_000) -> Model

Builds the model from the raw documents of a `Loader`. One type's content may
expand to at most `max_grammar_size` particles once group references are
replaced (`nothing`: no limit).
"""
function resolve(docs::Vector{RawDocument}; max_grammar_size::Union{Nothing,Int} = SchemaLoadOptions().max_grammar_size)
    r = Resolver(Model(), Dict{QName,Int}(), Dict{QName,Union{RawSimpleType,RawComplexType}}(), Bool[], Int[],
        Dict{QName,RawGroup}(), Dict{QName,RawAttributeGroup}(), Dict{QName,RawElement}(),
        Dict{QName,RawAttribute}(), Dict{QName,Int}(), Dict{QName,Int}(), QName[], 0, max_grammar_size)
    install_builtins!(r)
    register!(r, docs)
    for d in docs, e in d.elements
        e.name === nothing || global_element!(r, QName(d.target_ns, e.name))
    end
    for d in docs, a in d.attributes
        a.name === nothing || global_attribute!(r, QName(d.target_ns, a.name))
    end
    for id in BUILTIN_COUNT:(length(r.model.types) - 1)
        resolve_named!(r, id)
    end
    ns = r.model.namespaces
    for d in docs
        d.target_ns in ns || push!(ns, d.target_ns)
    end
    # Spec 8.5.4.1.3.2 (https://www.w3.org/TR/exi/#complexTypeGrammars): each URI
    # of an attribute wildcard's namespace list goes into the URI partition. The
    # URIs of xs:any wildcards (https://www.w3.org/TR/exi/#wildcardTerms) were
    # collected while particles were resolved. A complex type's wildcard already
    # includes those of its attribute groups and base type.
    for t in r.model.types
        c = as_complex(t)
        (c !== nothing && c.any_attribute isa NsList) || continue
        for u in c.any_attribute.uris
            u in ns || push!(ns, u)
        end
    end
    sort!(ns)
    check_list_items(r.model)
    return r.model
end

const ANY_TYPE_DEF = ComplexType(true,
    ParticleContent(Particle(1, 1, GroupTerm(COMP_SEQUENCE, [Particle(0, nothing, AnyTerm(NsAny()))]))),
    AttributeUse[], NsAny())

function install_builtins!(r::Resolver)
    for (i, b) in enumerate(BUILTINS)
        id = i - 1
        name = QName(XSD_NS, b.name)
        c = b.category
        kind = if c isa CatAnyType
            ANY_TYPE_DEF
        elseif c isa CatList
            SimpleType(ListOf(c.item), Facets(), id)
        else
            SimpleType(Atomic(), Facets(), id)
        end
        r.named_types[name] = id
        push!(r.model.types, TypeDef(name, b.base, kind))
        push!(r.resolved, true)
    end
end

function register!(r::Resolver, docs::Vector{RawDocument})
    for d in docs
        for ct in d.complex_types
            ct.name === nothing || register_type!(r, QName(d.target_ns, ct.name), ct)
        end
        for st in d.simple_types
            st.name === nothing || register_type!(r, QName(d.target_ns, st.name), st)
        end
        for g in d.groups
            q = QName(d.target_ns, g.name)
            haskey(r.groups, q) && throw(invalid_schema("duplicate xs:group $(sprint(show, q))"))
            r.groups[q] = g
        end
        for g in d.attribute_groups
            q = QName(d.target_ns, g.name)
            haskey(r.attr_groups, q) && throw(invalid_schema("duplicate xs:attributeGroup $(sprint(show, q))"))
            r.attr_groups[q] = g
        end
        for e in d.elements
            e.name === nothing && continue
            q = QName(d.target_ns, e.name)
            haskey(r.raw_global_elements, q) && throw(invalid_schema("duplicate global element $(sprint(show, q))"))
            r.raw_global_elements[q] = e
        end
        for a in d.attributes
            a.name === nothing && continue
            q = QName(d.target_ns, a.name)
            haskey(r.raw_global_attributes, q) && throw(invalid_schema("duplicate global attribute $(sprint(show, q))"))
            r.raw_global_attributes[q] = a
        end
    end
end

function register_type!(r::Resolver, q::QName, raw)
    haskey(r.named_types, q) && throw(invalid_schema("duplicate type $(sprint(show, q))"))
    id = length(r.model.types)
    push!(r.model.types, TypeDef(q, nothing, SimpleType(Atomic(), Facets(), nothing)))
    push!(r.resolved, false)
    r.named_types[q] = id
    r.raw_types[q] = raw
end

function type_id(r::Resolver, q::QName)
    id = get(r.named_types, q, nothing)
    id === nothing && throw(unresolved("type", q))
    return id
end

function resolved_type!(r::Resolver, q::QName)
    id = type_id(r, q)
    resolve_named!(r, id)
    return id
end

function resolve_named!(r::Resolver, id::Int)
    r.resolved[id + 1] && return nothing
    name = something(mtype(r.model, id).name, QName("", ""))
    id in r.resolving && throw(invalid_schema("circular derivation of type $(sprint(show, name))"))
    push!(r.resolving, id)
    raw = get(r.raw_types, name, nothing)
    raw === nothing && throw(unresolved("type", name))
    # A named type is resolved once; a loop back to it is caught by `resolving`.
    # So the groups being expanded outside do not count inside it.
    def = without_outer_groups(r) do
        raw isa RawSimpleType ? resolve_simple!(r, raw, name) : resolve_complex!(r, raw, name)
    end
    r.model.types[id + 1] = def
    r.resolved[id + 1] = true
    pop!(r.resolving)
    return nothing
end

function push_anonymous!(r::Resolver, def::TypeDef)
    push!(r.model.types, def)
    push!(r.resolved, true)
    return length(r.model.types) - 1
end

anonymous_simple!(r::Resolver, raw::RawSimpleType) = push_anonymous!(r, resolve_simple!(r, raw, nothing))

anonymous_type!(r::Resolver, raw::RawType) =
    push_anonymous!(r, raw isa RawSimpleType ? resolve_simple!(r, raw, nothing) : resolve_complex!(r, raw, nothing))

# A list's item type must be a simple type that is not itself a list
# (https://www.w3.org/TR/xmlschema-2/#cos-list-of-atomic). Item types are only
# given an index while types are resolved, so this is checked once every type is
# known. It also catches a list whose item type is the list itself, which a
# decoder would otherwise follow without end.
function check_list_items(m::Model)
    for t in m.types
        s = as_simple(t)
        (s !== nothing && s.variety isa ListOf) || continue
        item = as_simple(mtype(m, s.variety.item))
        if item === nothing || item.variety isa ListOf
            name = t.name === nothing ? "<anonymous>" : sprint(show, t.name)
            throw(invalid_schema("list type $name has an item type that is a list or not simple"))
        end
    end
    return nothing
end

function resolve_simple!(r::Resolver, raw::RawSimpleType, name::Union{Nothing,QName})
    v = raw.variety
    if v isa RawRestriction
        base_id = v.base !== nothing ? resolved_type!(r, v.base) :
                  v.inline !== nothing ? anonymous_simple!(r, v.inline) :
                  throw(invalid_schema("restriction without base"))
        bk = mtype(r.model, base_id).kind
        bk isa SimpleType || throw(invalid_schema(
            "simple type $(name === nothing ? "<anonymous>" : sprint(show, name)) restricts complex type"))
        return TypeDef(name, base_id, SimpleType(bk.variety, collect_facets(v.facets), nothing))
    elseif v isa RawList
        item = v.item !== nothing ? type_id(r, v.item) :
               v.inline !== nothing ? anonymous_simple!(r, v.inline) : throw(invalid_schema("list without item"))
        return TypeDef(name, ANY_SIMPLE_TYPE, SimpleType(ListOf(item), Facets(), nothing))
    end
    ids = Int[type_id(r, m) for m in v.members]
    for inl in v.inline
        push!(ids, anonymous_simple!(r, inl))
    end
    return TypeDef(name, ANY_SIMPLE_TYPE, SimpleType(UnionOf(ids), Facets(), nothing))
end

function base_complex!(r::Resolver, base::QName)
    id = resolved_type!(r, base)
    c = as_complex(mtype(r.model, id))
    c === nothing && throw(invalid_schema("complexContent derivation from simple type $(sprint(show, base))"))
    return (id, c)
end

empty_sequence() = Particle(1, 1, GroupTerm(COMP_SEQUENCE, Particle[]))

function resolve_complex!(r::Resolver, raw::RawComplexType, name::Union{Nothing,QName})
    mixed = raw.mixed
    own_attrs, own_any = attr_items!(r, raw.attributes, raw.any_attribute)
    d = raw.derivation
    m = r.model
    if d isa DerivNone
        content = d.particle !== nothing ? ParticleContent(content_particle!(r, d.particle)) :
                  mixed ? ParticleContent(empty_sequence()) : EmptyContent()
        attrs, any = merge_attributes(m, AttributeUse[], own_attrs, nothing, own_any)
        base = ANY_TYPE
    elseif d isa DerivComplexExtension
        base, bc = base_complex!(r, d.base)
        mixed |= bc.mixed
        own = d.particle === nothing ? nothing : content_particle!(r, d.particle)
        bcon = bc.content
        content = if bcon isa ParticleContent
            own === nothing ? bcon : ParticleContent(Particle(1, 1, GroupTerm(COMP_SEQUENCE, [bcon.particle, own])))
        elseif bcon isa EmptyContent
            own !== nothing ? ParticleContent(own) : mixed ? ParticleContent(empty_sequence()) : EmptyContent()
        else
            own === nothing || throw(invalid_schema(
                "extension of simple-content type $(sprint(show, d.base)) adds a content model"))
            bcon
        end
        attrs, any = merge_attributes(m, copy(bc.attributes), own_attrs, bc.any_attribute, own_any)
    elseif d isa DerivComplexRestriction
        base, bc = base_complex!(r, d.base)
        content = d.particle !== nothing ? ParticleContent(content_particle!(r, d.particle)) :
                  mixed ? ParticleContent(empty_sequence()) : EmptyContent()
        attrs, any = merge_attributes(m, copy(bc.attributes), own_attrs, nothing, own_any)
    elseif d isa DerivSimpleExtension
        base = resolved_type!(r, d.base)
        bk = mtype(m, base).kind
        if bk isa SimpleType
            content, base_attrs, base_any = SimpleContent(base), AttributeUse[], nothing
        else
            bk.content isa SimpleContent || throw(invalid_schema(
                "simpleContent extension of $(sprint(show, d.base)) which has no simple content"))
            content, base_attrs, base_any = bk.content, copy(bk.attributes), bk.any_attribute
        end
        attrs, any = merge_attributes(m, base_attrs, own_attrs, base_any, own_any)
    else # DerivSimpleRestriction
        base = resolved_type!(r, d.base)
        bk = mtype(m, base).kind
        if bk isa SimpleType
            simple_id, base_attrs = base, AttributeUse[]
        else
            bk.content isa SimpleContent || throw(invalid_schema(
                "simpleContent restriction of $(sprint(show, d.base)) which has no simple content"))
            simple_id, base_attrs = bk.content.type_id, copy(bk.attributes)
        end
        d.inline === nothing || (simple_id = anonymous_simple!(r, d.inline))
        if !isempty(d.facets)
            s = as_simple(mtype(r.model, simple_id))
            variety = s === nothing ? Atomic() : s.variety
            simple_id = push_anonymous!(r, TypeDef(nothing, simple_id, SimpleType(variety, collect_facets(d.facets), nothing)))
        end
        attrs, any = merge_attributes(m, base_attrs, own_attrs, nothing, own_any)
        content = SimpleContent(simple_id)
    end
    return TypeDef(name, base, ComplexType(mixed, content, attrs, any))
end

# The attribute uses of a type or group: (name, use), where a prohibited use is
# `nothing`. Attribute groups are inlined once each.
function attr_items!(r::Resolver, items::Vector{RawAttrItem}, any::Union{Nothing,NsConstraint})
    out = Tuple{QName,Union{Nothing,AttributeUse}}[]
    any_ref = Ref{Union{Nothing,NsConstraint}}(any)
    attr_items_into!(r, items, out, any_ref, Set{QName}())
    return (out, any_ref[])
end

function attr_items_into!(r::Resolver, items, out, any_ref, visited::Set{QName})
    for item in items
        if item isa RawAttribute
            q, id = attribute!(r, item)
            use = item.use == USE_PROHIBITED ? nothing : AttributeUse(id, item.use == USE_REQUIRED)
            push!(out, (q, use))
        else
            item in visited && continue
            push!(visited, item)
            g = get(r.attr_groups, item, nothing)
            g === nothing && throw(unresolved("attributeGroup", item))
            (g.any_attribute !== nothing && any_ref[] === nothing) && (any_ref[] = g.any_attribute)
            attr_items_into!(r, g.attributes, out, any_ref, visited)
        end
    end
end

function attribute!(r::Resolver, a::RawAttribute)
    a.reference === nothing || return (a.reference, global_attribute!(r, a.reference))
    q = QName(a.ns, something(a.name, ""))
    t = a.type_name !== nothing ? type_id(r, a.type_name) :
        a.inline_type !== nothing ? anonymous_simple!(r, a.inline_type) : ANY_SIMPLE_TYPE
    push!(r.model.attributes, AttributeDef(q, t, false))
    return (q, length(r.model.attributes) - 1)
end

function global_attribute!(r::Resolver, q::QName)
    id = get(r.global_attributes, q, nothing)
    id === nothing || return id
    raw = get(r.raw_global_attributes, q, nothing)
    raw === nothing && throw(unresolved("attribute", q))
    id = length(r.model.attributes)
    push!(r.model.attributes, AttributeDef(q, ANY_SIMPLE_TYPE, true))
    r.global_attributes[q] = id
    t = raw.type_name !== nothing ? type_id(r, raw.type_name) :
        raw.inline_type !== nothing ? anonymous_simple!(r, raw.inline_type) : ANY_SIMPLE_TYPE
    mattribute(r.model, id).type_id = t
    return id
end

function global_element!(r::Resolver, q::QName)
    id = get(r.global_elements, q, nothing)
    id === nothing || return id
    raw = get(r.raw_global_elements, q, nothing)
    raw === nothing && throw(unresolved("element", q))
    id = length(r.model.elements)
    push!(r.model.elements, ElementDef(q, ANY_TYPE, raw.nillable, true, raw.substitution_group, raw.is_abstract))
    r.global_elements[q] = id
    # The element is listed before its type is resolved, so a group that reaches
    # it again stops there. That kind of loop is fine, so the groups being
    # expanded outside do not count inside its type.
    melement(r.model, id).type_id = without_outer_groups(() -> element_type!(r, raw), r)
    return id
end

function without_outer_groups(f, r::Resolver)
    outer = r.expanding_groups
    r.expanding_groups = QName[]
    try
        return f()
    finally
        r.expanding_groups = outer
    end
end

element_type!(r::Resolver, raw::RawElement) =
    raw.type_name !== nothing ? type_id(r, raw.type_name) :
    raw.inline_type !== nothing ? anonymous_type!(r, raw.inline_type) : ANY_TYPE

"""
The particle of one type's content. It gets its own size count, which is put
back afterward: an anonymous type met inside another type's content is
resolved in the middle of it.
"""
function content_particle!(r::Resolver, raw::RawParticle)
    outer = r.particles
    r.particles = 0
    try
        return particle!(r, raw)
    finally
        r.particles = outer
    end
end

function particle!(r::Resolver, raw::RawParticle)
    r.particles += 1
    (r.max_particles !== nothing && r.particles > r.max_particles) && throw(too_large(r.max_particles))
    if raw isa RawElementParticle
        e = raw.element
        elem = if e.reference !== nothing
            global_element!(r, e.reference)
        else
            q = QName(e.ns, something(e.name, ""))
            t = element_type!(r, e)
            push!(r.model.elements, ElementDef(q, t, e.nillable, false, nothing, e.is_abstract))
            length(r.model.elements) - 1
        end
        return Particle(e.min, e.max, ElementTerm(elem))
    elseif raw isa RawAnyParticle
        if raw.ns isa NsList
            for u in raw.ns.uris
                u in r.model.namespaces || push!(r.model.namespaces, u)
            end
        end
        return Particle(raw.min, raw.max, AnyTerm(raw.ns))
    elseif raw isa RawGroupParticle
        return Particle(raw.min, raw.max, GroupTerm(raw.compositor, Particle[particle!(r, p) for p in raw.particles]))
    end
    g = get(r.groups, raw.name, nothing)
    g === nothing && throw(unresolved("group", raw.name))
    # A group that contains itself, directly or through other groups, has no
    # finite content, so XML Schema forbids it
    # (https://www.w3.org/TR/xmlschema-1/#coss-modelGroupDef).
    raw.name in r.expanding_groups && throw(invalid_schema("circular group reference to $(sprint(show, raw.name))"))
    push!(r.expanding_groups, raw.name)
    inner = try
        particle!(r, g.particle)
    finally
        pop!(r.expanding_groups)
    end
    return Particle(raw.min, raw.max, inner.term)
end

function collect_facets(facets::Vector{Facet})
    out = Facets()
    for f in facets
        k = f.kind
        if k == :enumeration
            en = out.enumeration
            if en === nothing
                en = String[]
                out.enumeration = en
            end
            push!(en, f.value)
        elseif k == :minInclusive
            out.min_inclusive = f.value
        elseif k == :maxInclusive
            out.max_inclusive = f.value
        elseif k == :minExclusive
            out.min_exclusive = f.value
        elseif k == :maxExclusive
            out.max_exclusive = f.value
        elseif k == :pattern
            push!(out.patterns, f.value)
        elseif k == :whiteSpace
            v = strip(f.value)
            out.whitespace = v == "preserve" ? WS_PRESERVE : v == "replace" ? WS_REPLACE : WS_COLLAPSE
        end
    end
    return out
end

function merge_attributes(m::Model, base::Vector{AttributeUse}, own, base_any, own_any)
    out = base
    for (q, use) in own
        pos = findfirst(b -> mattribute(m, b.attr).qname == q, out)
        if use !== nothing
            pos === nothing ? push!(out, use) : (out[pos] = use)
        elseif pos !== nothing
            deleteat!(out, pos)
        end
    end
    any = if own_any isa NsAny || base_any isa NsAny
        NsAny()
    elseif own_any === nothing
        base_any
    elseif base_any === nothing
        own_any
    elseif own_any isa NsList && base_any isa NsList
        uris = copy(own_any.uris)
        for u in base_any.uris
            u in uris || push!(uris, u)
        end
        NsList(uris)
    else
        own_any
    end
    return (out, any)
end
