# Events to XML (rexi-xml writer.rs and dump.rs).
#
# The writer invents prefixes: the root's namespace is the default namespace,
# every other namespace gets `ns1`, `ns2`, ... in order of first use, and
# `xsi` is declared when xsi:type or xsi:nil appear. All declarations go on the
# root, except that an element in a namespace with no prefix redeclares the
# default namespace, and an element whose xsi:type names a type in no
# namespace turns the default namespace off.

function escape_text(io::IO, s::AbstractString)
    for c in s
        c == '&' ? print(io, "&amp;") : c == '<' ? print(io, "&lt;") : c == '>' ? print(io, "&gt;") :
        c == '\r' ? print(io, "&#13;") : print(io, c)
    end
end

function escape_attribute(io::IO, s::AbstractString)
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == '\t'
            print(io, "&#9;")
        elseif c == '\n'
            print(io, "&#10;")
        elseif c == '\r'
            print(io, "&#13;")
        else
            print(io, c)
        end
    end
end

const XSI_PREFIX = "xsi"

mutable struct Namespaces
    default::String
    prefixed::Vector{Tuple{String,String}}
    xsi::Bool
    # One entry per start element (its tag name and the default namespace it
    # declares, if any) and per xsi:type (the type's name as written).
    tags::Vector{Tuple{String,Union{Nothing,String}}}
    types::Vector{String}
end

function prefix_for!(ns::Namespaces, uri::String)
    i = findfirst(p -> p[1] == uri, ns.prefixed)
    i === nothing || return ns.prefixed[i][2]
    p = "ns$(length(ns.prefixed) + 1)"
    push!(ns.prefixed, (uri, p))
    return p
end

function existing_prefix(ns::Namespaces, uri::AbstractString)
    uri == XSI_NS && return XSI_PREFIX
    i = findfirst(p -> p[1] == uri, ns.prefixed)
    return i === nothing ? nothing : ns.prefixed[i][2]
end

function element_name(ns::Namespaces, uri::String, local_name::String, current::String)
    uri == current && return (local_name, nothing)
    p = existing_prefix(ns, uri)
    return p === nothing ? (local_name, uri) : ("$p:$local_name", nothing)
end

function attribute_name(ns::Namespaces, uri::String, local_name::String)
    isempty(uri) && return local_name
    p = existing_prefix(ns, uri)
    return p === nothing ? local_name : "$p:$local_name"
end

# The layout of names; a namespace still missing a prefix is returned instead.
function plan(ns::Namespaces, events::Vector{Event})
    tags = Tuple{String,Union{Nothing,String}}[]
    types = String[]
    scopes = String[]
    for (i, ev) in enumerate(events)
        if ev isa StartElement
            current = isempty(scopes) ? ns.default : scopes[end]
            name, redeclare = element_name(ns, ev.uri, ev.local_name, current)
            scope_inside = redeclare === nothing ? current : redeclare
            # The events right after a start element are its xsi:type, xsi:nil
            # and attributes.
            untyped_ns = false
            for e in view(events, (i + 1):length(events))
                (e isa XsiType || e isa XsiNil || e isa Attribute) || break
                (e isa XsiType && isempty(e.uri)) && (untyped_ns = true)
            end
            if untyped_ns && !isempty(scope_inside)
                # The type has no namespace, so this element turns the default
                # namespace off and can no longer use it for its own name.
                if !isempty(ev.uri)
                    p = existing_prefix(ns, ev.uri)
                    p === nothing && return ev.uri
                    name = "$p:$(ev.local_name)"
                end
                redeclare = ""
            end
            push!(tags, (name, redeclare))
            push!(scopes, redeclare === nothing ? current : redeclare)
        elseif ev isa EndElement
            pop!(scopes)
        elseif ev isa XsiType
            current = isempty(scopes) ? ns.default : scopes[end]
            if ev.uri == current || isempty(ev.uri)
                push!(types, ev.local_name)
            else
                p = existing_prefix(ns, ev.uri)
                p === nothing && return ev.uri
                push!(types, "$p:$(ev.local_name)")
            end
        end
    end
    return (tags, types)
end

function Namespaces(events::Vector{Event})
    i = findfirst(e -> e isa StartElement, events)
    default = i === nothing ? "" : (events[i]::StartElement).uri
    ns = Namespaces(default, Tuple{String,String}[], false, Tuple{String,Union{Nothing,String}}[], String[])
    for ev in events
        if ev isa StartElement && !isempty(ev.uri) && ev.uri != ns.default
            prefix_for!(ns, ev.uri)
        elseif ev isa Attribute && !isempty(ev.uri)
            ev.uri == XSI_NS ? (ns.xsi = true) : prefix_for!(ns, ev.uri)
        elseif ev isa XsiType
            ns.xsi = true
            (!isempty(ev.uri) && ev.uri != ns.default) && prefix_for!(ns, ev.uri)
        elseif ev isa XsiNil
            ns.xsi = true
        end
    end
    # Each missing prefix the layout finds is added and the layout redone; this
    # ends, since a namespace gets a prefix at most once.
    while true
        r = plan(ns, events)
        if r isa String
            prefix_for!(ns, r)
        else
            ns.tags, ns.types = r
            return ns
        end
    end
end

function declarations(io::IO, ns::Namespaces, with_default::Bool)
    if with_default && !isempty(ns.default)
        print(io, " xmlns=\"")
        escape_attribute(io, ns.default)
        print(io, '"')
    end
    ns.xsi && print(io, " xmlns:", XSI_PREFIX, "=\"", XSI_NS, '"')
    for (uri, p) in ns.prefixed
        print(io, " xmlns:", p, "=\"")
        escape_attribute(io, uri)
        print(io, '"')
    end
end

"""Text of a value for XML and for event dumps: strings as they are, binary as upper hex."""
plain_format(v::AbstractString) = String(v)
plain_format(v::Lexical) = v.text
plain_format(v::Bool) = v ? "true" : "false"
plain_format(v::Integer) = string(v)
plain_format(v::ExiDecimal) = decimal_to_lexical(v)
plain_format(v::ExiFloat) = float_to_lexical(v)
plain_format(v::ExiDateTime) = datetime_to_lexical(v)
plain_format(v::AbstractVector{UInt8}) = format_hex(v)
plain_format(v::EnumOrdinal) = string(v.ordinal)
plain_format(v::ExiList) = join((plain_format(x) for x in v.items), ' ')

"""
    write_xml(events; formatter = plain_format) -> String

Writes events as an XML document (no XML declaration, no added whitespace).
"""
function write_xml(events::Vector{Event}; formatter = plain_format)
    ns = Namespaces(events)
    io = IOBuffer()
    open = String[]
    tag_pending = false
    tag_i = 0
    type_i = 0
    close_tag!() = (tag_pending && (print(io, '>'); tag_pending = false))
    for ev in events
        if ev isa StartElement
            close_tag!()
            is_root = isempty(open)
            tag_i += 1
            name, redeclare = ns.tags[tag_i]
            print(io, '<', name)
            if is_root
                declarations(io, ns, redeclare === nothing)
            elseif redeclare !== nothing
                print(io, " xmlns=\"")
                escape_attribute(io, redeclare)
                print(io, '"')
            end
            push!(open, name)
            tag_pending = true
        elseif ev isa EndElement
            if tag_pending
                print(io, "/>")
                tag_pending = false
                pop!(open)
            elseif !isempty(open)
                print(io, "</", pop!(open), '>')
            end
        elseif ev isa Attribute
            print(io, ' ', attribute_name(ns, ev.uri, ev.local_name), "=\"")
            escape_attribute(io, formatter(ev.value))
            print(io, '"')
        elseif ev isa XsiType
            type_i += 1
            print(io, " xsi:type=\"")
            escape_attribute(io, ns.types[type_i])
            print(io, '"')
        elseif ev isa XsiNil
            print(io, " xsi:nil=\"", ev.nil ? "true" : "false", '"')
        elseif ev isa Characters
            close_tag!()
            escape_text(io, formatter(ev.value))
        end
    end
    return String(take!(io))
end

function escape_dump(io::IO, s::AbstractString)
    for c in s
        c == '\\' ? print(io, "\\\\") : c == '\n' ? print(io, "\\n") : c == '\r' ? print(io, "\\r") :
        c == '\t' ? print(io, "\\t") : print(io, c)
    end
end

"""
    events_dump(events; formatter = plain_format) -> String

The `.events` text format of the interop fixtures, one event per line: `SD`,
`SE {uri}local`, `AT {uri}local value`, `XSI_TYPE {uri}local`, `XSI_NIL b`,
`CH value`, `EE`, `ED`. Backslash, LF, CR and tab in values are escaped.
"""
function events_dump(events::Vector{Event}; formatter = plain_format)
    io = IOBuffer()
    for ev in events
        if ev isa StartDocument
            print(io, "SD")
        elseif ev isa EndDocument
            print(io, "ED")
        elseif ev isa StartElement
            print(io, "SE {", ev.uri, '}', ev.local_name)
        elseif ev isa EndElement
            print(io, "EE")
        elseif ev isa Attribute
            print(io, "AT {", ev.uri, '}', ev.local_name, ' ')
            escape_dump(io, formatter(ev.value))
        elseif ev isa XsiType
            print(io, "XSI_TYPE {", ev.uri, '}', ev.local_name)
        elseif ev isa XsiNil
            print(io, "XSI_NIL ", ev.nil ? "true" : "false")
        elseif ev isa Characters
            print(io, "CH ")
            escape_dump(io, formatter(ev.value))
        end
        print(io, '\n')
    end
    return String(take!(io))
end

"""
    decode_events(bytes, tables; options = nothing, typed = false, limits = DecodeLimits()) -> Vector{Event}

Decodes a stream into events. Values are given in their standard text form
(the datatype's canonical form), or as typed values with `typed = true`.
`limits` caps what a hostile stream can ask for (see `DecodeLimits`).
"""
function decode_events(bytes::AbstractVector{UInt8}, tables::GrammarSet; options::Union{Nothing,ExiOptions} = nothing,
    typed::Bool = false, limits::DecodeLimits = DecodeLimits())
    dec = Decoder(bytes, tables; options, limits)
    out = Event[]
    while true
        ev = next_event!(dec)
        ev === nothing && break
        if !typed
            if ev isa Attribute
                ev = Attribute(ev.uri, ev.local_name, format_value(dec.last_kind, ev.value, tables))
            elseif ev isa Characters
                ev = Characters(format_value(dec.last_kind, ev.value, tables))
            end
        end
        push!(out, ev)
    end
    return out
end

"""
    decode_to_xml(bytes, tables; options = nothing, limits = DecodeLimits()) -> String

Decodes a stream to an XML document. `limits` caps what a hostile stream can
ask for (see `DecodeLimits`).
"""
decode_to_xml(bytes::AbstractVector{UInt8}, tables::GrammarSet; options::Union{Nothing,ExiOptions} = nothing,
    limits::DecodeLimits = DecodeLimits()) =
    write_xml(decode_events(bytes, tables; options, limits))
