# Events passed to the encoder and produced by the decoder, one per item of the
# XML document (https://www.w3.org/TR/exi/#eventTypes). Names are given as a
# namespace URI and a local name; prefixes are not kept in strict mode.

"""The parent type of every event."""
abstract type Event end

struct StartDocument <: Event end
struct EndDocument <: Event end

"""`SE`: the start of an element."""
struct StartElement <: Event
    uri::String
    local_name::String
end

struct EndElement <: Event end

"""`AT`: an attribute and its value (a typed value or a [`Lexical`](@ref))."""
struct Attribute <: Event
    uri::String
    local_name::String
    value::Any
end

"""The `xsi:type` attribute, which switches the element to the named type."""
struct XsiType <: Event
    uri::String
    local_name::String
end

"""The `xsi:nil` attribute."""
struct XsiNil <: Event
    nil::Bool
end

"""`CH`: character content (a typed value or a [`Lexical`](@ref))."""
struct Characters <: Event
    value::Any
end

# Events the strict profile never carries; the encoder refuses them.
struct NamespaceDecl <: Event
    uri::String
    prefix::String
end
struct Comment <: Event
    text::String
end
struct ProcessingInstruction <: Event
    target::String
    data::String
end
struct DocType <: Event
    name::String
end
struct EntityReference <: Event
    name::String
end
struct SelfContained <: Event end

for T in (StartElement, Attribute, XsiType, XsiNil, Characters, NamespaceDecl, Comment,
    ProcessingInstruction, DocType, EntityReference)
    @eval Base.:(==)(a::$T, b::$T) = all(getfield(a, f) == getfield(b, f) for f in fieldnames($T))
end

"""`{uri}local`, or just `local` when the URI is empty."""
qname_text(uri::AbstractString, local_name::AbstractString) =
    isempty(uri) ? String(local_name) : string('{', uri, '}', local_name)

event_name(::StartDocument) = "SD"
event_name(::EndDocument) = "ED"
event_name(e::StartElement) = "SE($(qname_text(e.uri, e.local_name)))"
event_name(::EndElement) = "EE"
event_name(e::Attribute) = "AT($(qname_text(e.uri, e.local_name)))"
event_name(::XsiType) = "AT(xsi:type)"
event_name(::XsiNil) = "AT(xsi:nil)"
event_name(::Characters) = "CH"
event_name(::Event) = "unsupported event"
