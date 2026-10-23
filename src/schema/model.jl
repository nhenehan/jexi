# The resolved schema model: types, elements and attributes with every name
# resolved to an index (rexi-schema xsd/model.rs). Indexes are 0-based, like
# the grammar tables: the 46 built-in types come first, at the index of their
# name in the XSD partition of the string table (spec D.3), so a built-in's type
# index equals its local-name id.

Base.@kwdef mutable struct Facets
    enumeration::Union{Nothing,Vector{String}} = nothing
    min_inclusive::Union{Nothing,String} = nothing
    max_inclusive::Union{Nothing,String} = nothing
    min_exclusive::Union{Nothing,String} = nothing
    max_exclusive::Union{Nothing,String} = nothing
    # The pattern facets written on this type itself (not inherited).
    patterns::Vector{String} = String[]
    whitespace::Union{Nothing,WhiteSpace} = nothing
end

abstract type Variety end
struct Atomic <: Variety end
struct ListOf <: Variety
    item::Int
end
struct UnionOf <: Variety
    members::Vector{Int}
end

struct SimpleType
    variety::Variety
    facets::Facets
    # The built-in this is, if it is one.
    builtin::Union{Nothing,Int}
end

abstract type Term end

struct Particle
    min::Int
    max::MaxOccurs
    term::Term
end

struct ElementTerm <: Term
    elem::Int
end
struct AnyTerm <: Term
    ns::NsConstraint
end
struct GroupTerm <: Term
    compositor::Compositor
    particles::Vector{Particle}
end

abstract type Content end
struct EmptyContent <: Content end
struct SimpleContent <: Content
    type_id::Int
end
struct ParticleContent <: Content
    particle::Particle
end

struct AttributeUse
    attr::Int
    required::Bool
end

struct ComplexType
    mixed::Bool
    content::Content
    attributes::Vector{AttributeUse}
    any_attribute::Union{Nothing,NsConstraint}
end

struct TypeDef
    name::Union{Nothing,QName}
    base::Union{Nothing,Int}
    kind::Union{SimpleType,ComplexType}
end

as_simple(t::TypeDef) = t.kind isa SimpleType ? t.kind : nothing
as_complex(t::TypeDef) = t.kind isa ComplexType ? t.kind : nothing

mutable struct ElementDef
    qname::QName
    type_id::Int
    nillable::Bool
    is_global::Bool
    substitution_group::Union{Nothing,QName}
    is_abstract::Bool
end

mutable struct AttributeDef
    qname::QName
    type_id::Int
    is_global::Bool
end

Base.@kwdef mutable struct Model
    types::Vector{TypeDef} = TypeDef[]
    elements::Vector{ElementDef} = ElementDef[]
    attributes::Vector{AttributeDef} = AttributeDef[]
    namespaces::Vector{String} = String[]
end

mtype(m::Model, t::Integer) = m.types[t + 1]
melement(m::Model, e::Integer) = m.elements[e + 1]
mattribute(m::Model, a::Integer) = m.attributes[a + 1]

function find_type(m::Model, ns::AbstractString, local_name::AbstractString)
    i = findfirst(t -> t.name !== nothing && t.name.ns == ns && t.name.local_name == local_name, m.types)
    return i === nothing ? nothing : i - 1
end

function find_global_element(m::Model, ns::AbstractString, local_name::AbstractString)
    i = findfirst(e -> e.is_global && e.qname.ns == ns && e.qname.local_name == local_name, m.elements)
    return i === nothing ? nothing : i - 1
end

"""The type and its bases, nearest first (stops at a cycle)."""
function ancestors(m::Model, t::Int)
    out = Int[]
    cur = t
    while cur !== nothing
        cur in out && break
        push!(out, cur)
        cur = mtype(m, cur).base
    end
    return out
end

"""The nearest built-in in the type's base chain (anyType for complex types)."""
function closest_builtin(m::Model, t::Int)
    for a in ancestors(m, t)
        k = mtype(m, a).kind
        if k isa SimpleType
            k.builtin === nothing || return k.builtin
        elseif a == ANY_TYPE
            return a
        end
    end
    return nothing
end

"""Every global element in the substitution group of `head`, transitively."""
function substitution_members(m::Model, head::Int)
    members = Int[]
    frontier = [head]
    while !isempty(frontier)
        h = pop!(frontier)
        hq = melement(m, h).qname
        for (i, e) in enumerate(m.elements)
            id = i - 1
            if e.is_global && e.substitution_group == hq && id != head && !(id in members)
                push!(members, id)
                push!(frontier, id)
            end
        end
    end
    return members
end
