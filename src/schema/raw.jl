# The XSD syntax tree as written: one `RawDocument` per schema document, before
# names are resolved (rexi-schema xsd/raw.rs).

"""A qualified name in the schema: namespace and local name."""
struct QName
    ns::String
    local_name::String
end

Base.:(==)(a::QName, b::QName) = a.ns == b.ns && a.local_name == b.local_name
Base.hash(q::QName, h::UInt) = hash(q.local_name, hash(q.ns, hash(:QName, h)))
Base.isless(a::QName, b::QName) = (a.ns, a.local_name) < (b.ns, b.local_name)
Base.show(io::IO, q::QName) = print(io, '{', q.ns, '}', q.local_name)

"""
A namespace constraint of a wildcard: any namespace, any but one (`##other`),
or a list (`""` stands for no namespace).
"""
abstract type NsConstraint end
struct NsAny <: NsConstraint end
struct NsOther <: NsConstraint
    ns::String
end
struct NsList <: NsConstraint
    uris::Vector{String}
end
Base.:(==)(a::NsList, b::NsList) = a.uris == b.uris
Base.:(==)(a::NsOther, b::NsOther) = a.ns == b.ns

@enum AttrUse::UInt8 USE_OPTIONAL USE_REQUIRED USE_PROHIBITED
@enum Compositor::UInt8 COMP_SEQUENCE COMP_CHOICE COMP_ALL

"""A facet of a simple type restriction (`kind` is the facet's element name)."""
struct Facet
    kind::Symbol
    value::String
end

"""Occurrence bounds; `max === nothing` is unbounded."""
const MaxOccurs = Union{Nothing,Int}

abstract type RawType end

struct RawElement
    name::Union{Nothing,String}
    ns::String
    reference::Union{Nothing,QName}
    type_name::Union{Nothing,QName}
    inline_type::Union{Nothing,RawType}
    min::Int
    max::MaxOccurs
    nillable::Bool
    substitution_group::Union{Nothing,QName}
    is_abstract::Bool
end

abstract type RawVariety end

struct RawSimpleType <: RawType
    name::Union{Nothing,String}
    ns::String
    variety::RawVariety
end

struct RawRestriction <: RawVariety
    base::Union{Nothing,QName}
    inline::Union{Nothing,RawSimpleType}
    facets::Vector{Facet}
end

struct RawList <: RawVariety
    item::Union{Nothing,QName}
    inline::Union{Nothing,RawSimpleType}
end

struct RawUnion <: RawVariety
    members::Vector{QName}
    inline::Vector{RawSimpleType}
end

struct RawAttribute
    name::Union{Nothing,String}
    ns::String
    reference::Union{Nothing,QName}
    type_name::Union{Nothing,QName}
    inline_type::Union{Nothing,RawSimpleType}
    use::AttrUse
end

"""An attribute or an attribute group reference, in a type or group."""
const RawAttrItem = Union{RawAttribute,QName}

abstract type RawParticle end

struct RawElementParticle <: RawParticle
    element::RawElement
end

struct RawAnyParticle <: RawParticle
    ns::NsConstraint
    min::Int
    max::MaxOccurs
end

struct RawGroupParticle <: RawParticle
    compositor::Compositor
    particles::Vector{RawParticle}
    min::Int
    max::MaxOccurs
end

struct RawGroupRef <: RawParticle
    name::QName
    min::Int
    max::MaxOccurs
end

abstract type RawDerivation end

struct DerivNone <: RawDerivation
    particle::Union{Nothing,RawParticle}
end
struct DerivComplexExtension <: RawDerivation
    base::QName
    particle::Union{Nothing,RawParticle}
end
struct DerivComplexRestriction <: RawDerivation
    base::QName
    particle::Union{Nothing,RawParticle}
end
struct DerivSimpleExtension <: RawDerivation
    base::QName
end
struct DerivSimpleRestriction <: RawDerivation
    base::QName
    facets::Vector{Facet}
    inline::Union{Nothing,RawSimpleType}
end

struct RawComplexType <: RawType
    name::Union{Nothing,String}
    ns::String
    mixed::Bool
    derivation::RawDerivation
    attributes::Vector{RawAttrItem}
    any_attribute::Union{Nothing,NsConstraint}
end

struct RawGroup
    name::String
    ns::String
    particle::RawParticle
end

struct RawAttributeGroup
    name::String
    ns::String
    attributes::Vector{RawAttrItem}
    any_attribute::Union{Nothing,NsConstraint}
end

Base.@kwdef mutable struct RawDocument
    target_ns::String = ""
    element_qualified::Bool = false
    attribute_qualified::Bool = false
    elements::Vector{RawElement} = RawElement[]
    attributes::Vector{RawAttribute} = RawAttribute[]
    complex_types::Vector{RawComplexType} = RawComplexType[]
    simple_types::Vector{RawSimpleType} = RawSimpleType[]
    groups::Vector{RawGroup} = RawGroup[]
    attribute_groups::Vector{RawAttributeGroup} = RawAttributeGroup[]
end
