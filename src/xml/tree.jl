# A namespace-aware XML tree over XML.jl. Both the schema loader and the XML
# front-end read documents through it.
#
# XML.jl gives tags and attribute names with their prefixes; this resolves them
# to namespace URIs (https://www.w3.org/TR/xml-names/), keeps the namespaces in
# scope on each element (QName values such as `type="tns:t"` need them), and
# normalizes line ends in text (https://www.w3.org/TR/xml/#sec-line-ends).

import XML

"""An attribute with its name resolved: namespace URI, local name and value."""
struct XAttr
    uri::String
    local_name::String
    value::String
end

"""
An element: its resolved name, its attributes (namespace declarations taken
out), the namespaces in scope (prefix => URI; `""` is the default namespace),
and its children, which are elements and text (`String`).
"""
struct XElement
    uri::String
    local_name::String
    attributes::Vector{XAttr}
    namespaces::Dict{String,String}
    children::Vector{Union{XElement,String}}
end

const XMLNS_NS = "http://www.w3.org/2000/xmlns/"

"""An XML syntax or namespace error in a document."""
struct XmlSyntaxError <: Exception
    msg::String
end
Base.showerror(io::IO, e::XmlSyntaxError) = print(io, "XML error: ", e.msg)

split_name(name::AbstractString) =
    (i = findfirst(':', name); i === nothing ? ("", String(name)) : (String(name[1:prevind(name, i)]), String(name[nextind(name, i):end])))

function resolve_prefix(ns::Dict{String,String}, prefix::String, what::AbstractString)
    prefix == "xml" && return XML_NS
    u = get(ns, prefix, nothing)
    u === nothing && throw(XmlSyntaxError("undeclared namespace prefix '$prefix' in '$what'"))
    return u
end

# XML line-end handling (https://www.w3.org/TR/xml/#sec-line-ends): CR LF and a
# lone CR both become LF. It applies to the literal text only, so it runs before
# references are replaced: `&#13;` stays a carriage return.
normalize_newlines(s::AbstractString) = occursin('\r', s) ? replace(replace(s, "\r\n" => "\n"), '\r' => '\n') : String(s)

# Attribute-value normalization (https://www.w3.org/TR/xml/#AVNormalize), on the
# literal value: line ends as above, then each tab, LF or CR becomes a space.
normalize_attribute(s::AbstractString) = map(c -> c in ('\t', '\n', '\r') ? ' ' : c, normalize_newlines(s))

const PREDEFINED_ENTITIES = Dict("amp" => '&', "lt" => '<', "gt" => '>', "apos" => '\'', "quot" => '"')

"""
Replaces the references in literal text: the five predefined entities and
character references. Any other entity would need a DTD, which strict EXI
cannot carry.
"""
function unescape_xml(s::AbstractString)
    occursin('&', s) || return String(s)
    io = IOBuffer()
    i = firstindex(s)
    n = lastindex(s)
    while i <= n
        c = s[i]
        if c != '&'
            print(io, c)
            i = nextind(s, i)
            continue
        end
        j = findnext(';', s, i)
        j === nothing && throw(XmlSyntaxError("unterminated reference in '$s'"))
        name = SubString(s, nextind(s, i), prevind(s, j))
        if startswith(name, '#')
            hex = length(name) > 1 && name[2] in ('x', 'X')
            digits = SubString(name, hex ? 3 : 2)
            cp = isempty(digits) ? nothing : tryparse(UInt32, digits; base = hex ? 16 : 10)
            (cp === nothing || !isvalid(Char, cp) || cp == 0) &&
                throw(XmlSyntaxError("invalid character reference &$name;"))
            print(io, Char(cp))
        else
            ch = get(PREDEFINED_ENTITIES, name, nothing)
            ch === nothing && throw(UnsupportedError(FEATURE_PRESERVE_DTD))
            print(io, ch)
        end
        i = nextind(s, j)
    end
    return String(take!(io))
end

function build_element(node::XML.Node, inherited::Dict{String,String})
    # Namespace declarations hold literal values too.
    attrs = XML.attributes(node)
    ns = inherited
    if attrs !== nothing && any(k -> k == "xmlns" || startswith(k, "xmlns:"), keys(attrs))
        ns = copy(inherited)
        for (k, v) in attrs
            if k == "xmlns"
                ns[""] = unescape_xml(normalize_attribute(v))
            elseif startswith(k, "xmlns:")
                ns[k[7:end]] = unescape_xml(normalize_attribute(v))
            end
        end
    end
    tag = String(XML.tag(node)::AbstractString)
    prefix, local_name = split_name(tag)
    uri = prefix == "" ? get(ns, "", "") : resolve_prefix(ns, prefix, tag)
    xattrs = XAttr[]
    if attrs !== nothing
        for (k, v) in attrs
            (k == "xmlns" || startswith(k, "xmlns:")) && continue
            p, l = split_name(k)
            # Unprefixed attributes are in no namespace.
            push!(xattrs, XAttr(p == "" ? "" : resolve_prefix(ns, p, k), l, unescape_xml(normalize_attribute(v))))
        end
    end
    children = Union{XElement,String}[]
    for c in XML.children(node)
        t = XML.nodetype(c)
        if t == XML.Element
            push!(children, build_element(c, ns))
        elseif t == XML.Text || t == XML.CData
            raw = normalize_newlines(something(XML.value(c), ""))
            s = t == XML.Text ? unescape_xml(raw) : raw
            # Join neighboring text (text next to CDATA is one run of characters).
            if !isempty(children) && children[end] isa String
                children[end] = (children[end]::String) * s
            else
                push!(children, s)
            end
        elseif t == XML.DTD
            throw(UnsupportedError(FEATURE_PRESERVE_DTD))
        end
        # Comments and processing instructions carry no data in the strict profile.
    end
    return XElement(uri, local_name, xattrs, ns, children)
end

"""
    parse_xml(text) -> XElement

Parses an XML document and returns its root element.
"""
function parse_xml(text::AbstractString)
    doc = try
        # Parsed without replacing references, so line ends are normalized on
        # the literal text first (see `normalize_newlines`).
        XML.parse(String(text), XML.Node{SubString{String}})
    catch err
        err isa InterruptException && rethrow()
        throw(XmlSyntaxError(sprint(showerror, err)))
    end
    root = nothing
    for c in XML.children(doc)
        t = XML.nodetype(c)
        if t == XML.Element
            root === nothing || throw(XmlSyntaxError("more than one root element"))
            root = c
        elseif t == XML.DTD
            throw(UnsupportedError(FEATURE_PRESERVE_DTD))
        elseif t == XML.Text || t == XML.CData
            all(c -> c in (' ', '\t', '\n', '\r'), something(XML.value(c), "")) ||
                throw(XmlSyntaxError("character data outside the root element"))
        end
    end
    root === nothing && throw(XmlSyntaxError("no root element"))
    return build_element(root, Dict{String,String}())
end

parse_xml_file(path::AbstractString) = parse_xml(read(path, String))

"""The value of the unprefixed attribute `name`, or `nothing`."""
function attr(e::XElement, name::AbstractString)
    for a in e.attributes
        (a.uri == "" && a.local_name == name) && return a.value
    end
    return nothing
end

"""The child elements of `e`."""
child_elements(e::XElement) = (c for c in e.children if c isa XElement)

"""
    resolve_qname_value(e, value) -> (uri, local)

Resolves a QName written in an attribute value (`p:local` or `local`) with the
namespaces in scope at `e`. An unprefixed name takes the default namespace.
"""
function resolve_qname_value(e::XElement, value::AbstractString)
    v = strip(value)
    prefix, local_name = split_name(v)
    prefix == "" && return (get(e.namespaces, "", ""), local_name)
    return (resolve_prefix(e.namespaces, prefix, v), local_name)
end
