# A streaming XML reader over XML.jl's tokenizer. It builds no tree: each
# element's events go straight to a sink (the encoder, or a list of events).
#
# It follows the same rules as `parse_xml` plus the reader rules of reader.jl:
# namespaces are resolved (https://www.w3.org/TR/xml-names/), line ends are
# normalized in literal text (https://www.w3.org/TR/xml/#sec-line-ends),
# attribute values are normalized (https://www.w3.org/TR/xml/#AVNormalize),
# references are replaced, and an element's attributes come out in EXI order:
# xsi:type, then xsi:nil, then the rest sorted by local name and then URI
# (https://www.w3.org/TR/exi/#eventCodeAssignment).
#
# A sink takes these calls:
#   sink_start!(sink, uri, local)      sink_xsi_type!(sink, uri, local)
#   sink_xsi_nil!(sink, nil)           sink_attr!(sink, uri, local, value)
#   sink_text!(sink, bytes, n)         sink_end!(sink)
# Names and values are `SubString{String}`. Text is the first `n` bytes of a
# buffer the reader reuses, so a sink must copy what it keeps.

const XT = XML.XMLTokenizer
const TK = XT.TokenKinds

const SubStr = SubString{String}

"""The reader's working state, reused across the elements of one document."""
mutable struct XmlScan
    # The namespace bindings in scope, innermost last, with the binding count
    # at each open element's start.
    ns_prefix::Vector{SubStr}
    ns_uri::Vector{SubStr}
    ns_marks::Vector{Int}
    # The raw names of the open elements, to match their end tags.
    tags::Vector{SubStr}
    # The current start tag's attributes, raw, until the tag closes.
    attr_names::Vector{SubStr}
    attr_values::Vector{SubStr}
    # Resolved plain attributes of the current tag, and their sorted order.
    attr_uri::Vector{SubStr}
    attr_local::Vector{SubStr}
    attr_order::Vector{Int}
    attr_pos::Vector{Int}
    # Text since the last tag, normalized and unescaped.
    text::Vector{UInt8}
    text_len::Int
    has_text::Bool
    # Scratch for attribute values that need rewriting.
    scratch::Vector{UInt8}
end

XmlScan() = XmlScan(SubStr[], SubStr[], Int[], SubStr[], SubStr[], SubStr[], SubStr[], SubStr[], Int[],
    Int[], UInt8[], 0, false, UInt8[])

const XML_NS_SUB = SubString(XML_NS)
const XSI_NS_SUB = SubString(XSI_NS)
const EMPTY_SUB = SubString("")

@inline function grow!(buf::Vector{UInt8}, need::Int)
    # Grow only: the buffer is reused for every text run.
    need > length(buf) && resize!(buf, max(need, 2 * length(buf), 64))
    return buf
end

@inline function put_byte!(buf::Vector{UInt8}, n::Int, b::UInt8)
    grow!(buf, n + 1)
    @inbounds buf[n + 1] = b
    return n + 1
end

function put_char!(buf::Vector{UInt8}, n::Int, c::Char)
    u = reinterpret(UInt32, c)
    nb = ncodeunits(c)
    grow!(buf, n + nb)
    # A Char holds its UTF-8 bytes from the top byte down.
    for k in 1:nb
        @inbounds buf[n + k] = (u >> (8 * (4 - k))) % UInt8
    end
    return n + nb
end

"""
Replaces the reference that starts at byte `i` of `s` (at its `&`) and appends
its character to `buf`. Returns the new length and the byte after the `;`.
"""
function put_reference!(buf::Vector{UInt8}, n::Int, s::SubStr, i::Int)
    stop = ncodeunits(s)
    j = i + 1
    while j <= stop && codeunit(s, j) != UInt8(';')
        j += 1
    end
    j > stop && throw(XmlSyntaxError("unterminated reference in '$s'"))
    # End at the start of the last character: `j - 1` is a byte, which may sit
    # inside a character of two or more bytes (`&é;`).
    name = SubString(s, i + 1, prevind(s, j))
    if startswith(name, '#')
        hex = ncodeunits(name) > 1 && codeunit(name, 2) in (UInt8('x'), UInt8('X'))
        digits = SubString(name, hex ? 3 : 2)
        cp = isempty(digits) ? nothing : tryparse(UInt32, digits; base = hex ? 16 : 10)
        (cp === nothing || !isvalid(Char, cp) || cp == 0) &&
            throw(XmlSyntaxError("invalid character reference &$name;"))
        return put_char!(buf, n, Char(cp)), j + 1
    end
    b = name == "amp" ? UInt8('&') : name == "lt" ? UInt8('<') : name == "gt" ? UInt8('>') :
        name == "apos" ? UInt8('\'') : name == "quot" ? UInt8('"') : 0x00
    # Any other entity would need a DTD, which strict EXI cannot carry.
    b == 0x00 && throw(UnsupportedError(FEATURE_PRESERVE_DTD))
    return put_byte!(buf, n, b), j + 1
end

"""
Appends literal text to `buf`: CR LF and a lone CR become LF, then references
are replaced (not in CDATA). So `&#13;` stays a carriage return.
"""
function put_text!(buf::Vector{UInt8}, n::Int, s::SubStr, refs::Bool)
    stop = ncodeunits(s)
    grow!(buf, n + stop)
    i = 1
    @inbounds while i <= stop
        b = codeunit(s, i)
        if b == UInt8('\r')
            n = put_byte!(buf, n, UInt8('\n'))
            i += (i < stop && codeunit(s, i + 1) == UInt8('\n')) ? 2 : 1
        elseif b == UInt8('&') && refs
            n, i = put_reference!(buf, n, s, i)
        else
            n = put_byte!(buf, n, b)
            i += 1
        end
    end
    return n
end

"""
An attribute value, normalized: line ends as in text, then each tab, LF or CR
becomes a space, then references are replaced. Returns `raw` itself when there
is nothing to change.
"""
function attr_text(scan::XmlScan, raw::SubStr)
    clean = true
    for b in codeunits(raw)
        if b == UInt8('&') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')
            clean = false
            break
        end
        b == UInt8('<') && throw(XmlSyntaxError("'<' in attribute value '$raw'"))
    end
    clean && return raw
    buf = scan.scratch
    stop = ncodeunits(raw)
    n = 0
    i = 1
    while i <= stop
        b = codeunit(raw, i)
        if b == UInt8('\r')
            n = put_byte!(buf, n, UInt8(' '))
            i += (i < stop && codeunit(raw, i + 1) == UInt8('\n')) ? 2 : 1
        elseif b == UInt8('\t') || b == UInt8('\n')
            n = put_byte!(buf, n, UInt8(' '))
            i += 1
        elseif b == UInt8('&')
            n, i = put_reference!(buf, n, raw, i)
        else
            b == UInt8('<') && throw(XmlSyntaxError("'<' in attribute value '$raw'"))
            n = put_byte!(buf, n, b)
            i += 1
        end
    end
    return SubString(String(buf[1:n]))
end

"""
Splits `p:local` into its prefix and local name (prefix `""` when none). The
colon is found by byte; the prefix ends at the start of the character before it,
because that character may take more than one byte (`pé:r`).
"""
@inline function split_qname(name::SubStr)
    stop = ncodeunits(name)
    for i in 1:stop
        @inbounds codeunit(name, i) == UInt8(':') && return SubString(name, 1, prevind(name, i)), SubString(name, i + 1)
    end
    return EMPTY_SUB, name
end

function resolve(scan::XmlScan, prefix::SubStr, what::SubStr)
    prefix == "xml" && return XML_NS_SUB
    p = scan.ns_prefix
    for i in length(p):-1:1
        @inbounds p[i] == prefix && return scan.ns_uri[i]
    end
    # No default namespace declared: names are in no namespace.
    isempty(prefix) && return EMPTY_SUB
    throw(XmlSyntaxError("undeclared namespace prefix '$prefix' in '$what'"))
end

is_space_byte(b::UInt8) = b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')

function strip_space(s::SubStr)
    i, j = 1, ncodeunits(s)
    while i <= j && is_space_byte(codeunit(s, i))
        i += 1
    end
    while j >= i && is_space_byte(codeunit(s, j))
        j -= 1
    end
    # `j` is the last byte that is not a space; `thisind` moves it back to the start
    # of its character, so a character of several bytes is kept whole.
    return SubString(s, i, thisind(s, j))
end

is_name_start(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '_' || c == ':' || !isascii(c)

"""Gives the text since the last tag to the sink (inside the root only)."""
function flush_text!(sink, scan::XmlScan)
    scan.has_text || return nothing
    scan.has_text = false
    n = scan.text_len
    scan.text_len = 0
    if isempty(scan.tags)
        # Outside the root only whitespace may appear, and it is dropped.
        for i in 1:n
            is_space_byte(@inbounds scan.text[i]) ||
                throw(XmlSyntaxError("character data outside the root element"))
        end
        return nothing
    end
    sink_text!(sink, scan.text, n)
    return nothing
end

"""The start tag is complete: bind its namespaces and give its events to the sink."""
function start_tag!(sink, scan::XmlScan, tag::SubStr)
    names, values = scan.attr_names, scan.attr_values
    na = length(names)
    push!(scan.ns_marks, length(scan.ns_prefix))
    # Namespace declarations first: they apply to the tag's own names.
    for i in 1:na
        k = names[i]
        if k == "xmlns"
            push!(scan.ns_prefix, EMPTY_SUB)
            push!(scan.ns_uri, values[i])
        elseif startswith(k, "xmlns:")
            push!(scan.ns_prefix, SubString(k, 7))
            push!(scan.ns_uri, values[i])
        end
    end
    prefix, local_name = split_qname(tag)
    sink_start!(sink, resolve(scan, prefix, tag), local_name)
    xsi_type = 0
    xsi_nil = 0
    # The other attributes, resolved, and their order sorted by (local, uri).
    uris, locals, order = scan.attr_uri, scan.attr_local, scan.attr_order
    empty!(uris)
    empty!(locals)
    empty!(order)
    for i in 1:na
        k = names[i]
        (k == "xmlns" || startswith(k, "xmlns:")) && continue
        p, l = split_qname(k)
        # Unprefixed attributes are in no namespace.
        u = isempty(p) ? EMPTY_SUB : resolve(scan, p, k)
        if u == XSI_NS && l == "type"
            xsi_type = i
        elseif u == XSI_NS && l == "nil"
            xsi_nil = i
        else
            push!(uris, u)
            push!(locals, l)
            # Insertion sort, stable: tags have few attributes.
            push!(order, 0)
            j = length(order) - 1
            while j >= 1
                o = order[j]
                c = cmp(locals[o], l)
                c == 0 && (c = cmp(uris[o], u))
                c == 0 && throw(XmlSyntaxError("attribute {$u}$l appears twice in '$tag'"))
                c < 0 && break
                order[j + 1] = o
                j -= 1
            end
            # `order` holds positions in `uris` and `locals`; `attr_pos` maps a
            # position back to the attribute's value.
            order[j + 1] = length(uris)
            push!(scan.attr_pos, i)
        end
    end
    if xsi_type != 0
        v = strip_space(values[xsi_type])
        p, l = split_qname(v)
        sink_xsi_type!(sink, resolve(scan, p, v), l)
    end
    xsi_nil != 0 && sink_xsi_nil!(sink, parse_nil(values[xsi_nil]))
    pos = scan.attr_pos
    for o in order
        sink_attr!(sink, uris[o], locals[o], values[pos[o]])
    end
    empty!(pos)
    empty!(names)
    empty!(values)
    push!(scan.tags, tag)
    return nothing
end

function end_tag!(sink, scan::XmlScan, name::SubStr)
    isempty(scan.tags) && throw(XmlSyntaxError("end tag </$name> with no matching start tag"))
    open = pop!(scan.tags)
    open == name || throw(XmlSyntaxError("mismatched tags: expected </$open>, got </$name>"))
    resize!(scan.ns_prefix, pop!(scan.ns_marks))
    resize!(scan.ns_uri, length(scan.ns_prefix))
    sink_end!(sink)
    return nothing
end

"""
    scan_xml!(sink, xml)

Reads an XML document and gives its element events to `sink` (no SD or ED).
"""
function scan_xml!(sink, xml::AbstractString, scan::XmlScan = XmlScan())
    whole = String(xml)::String
    # A leading byte-order mark (3 bytes in UTF-8) is not content.
    text = startswith(whole, '\ufeff') ? String(SubString(whole, 4))::String : whole
    try
        scan_tokens!(sink, scan, text)
    catch err
        # The tokenizer's own errors are ArgumentErrors with this prefix.
        if err isa ArgumentError && startswith(err.msg, "XML tokenizer error")
            throw(XmlSyntaxError(err.msg))
        end
        rethrow()
    end
    return sink
end

function scan_tokens!(sink, scan::XmlScan, text::String)
    roots = 0
    in_tag = false
    in_decl = false
    tag = EMPTY_SUB
    attr_name = EMPTY_SUB
    first_token = true
    for tok in XT.tokenize(text)
        k = tok.kind
        if k == TK.TEXT || k == TK.CDATA_CONTENT
            raw = XT.raw(tok, text)
            scan.text_len = put_text!(scan.text, scan.text_len, raw, k == TK.TEXT && tok.has_entities)
            scan.has_text = true
        elseif k == TK.OPEN_TAG
            flush_text!(sink, scan)
            tag = XT.tag_name(tok, text)
            (isempty(tag) || !is_name_start(first(tag))) && throw(XmlSyntaxError("invalid element name \"$tag\""))
            if isempty(scan.tags)
                roots += 1
                roots > 1 && throw(XmlSyntaxError("more than one root element"))
            end
            in_tag = true
        elseif k == TK.ATTR_NAME
            attr_name = XT.raw(tok, text)
        elseif k == TK.ATTR_VALUE
            in_decl && continue
            for n in scan.attr_names
                n == attr_name && throw(XmlSyntaxError("duplicate attribute $attr_name in '$tag'"))
            end
            push!(scan.attr_names, attr_name)
            push!(scan.attr_values, attr_text(scan, XT.attr_value(tok, text)))
        elseif k == TK.TAG_CLOSE
            if in_tag
                in_tag = false
                start_tag!(sink, scan, tag)
            end
            # A `>` after an end tag's name: `end_tag!` already ran.
        elseif k == TK.SELF_CLOSE
            in_tag = false
            start_tag!(sink, scan, tag)
            end_tag!(sink, scan, tag)
        elseif k == TK.CLOSE_TAG
            flush_text!(sink, scan)
            end_tag!(sink, scan, XT.tag_name(tok, text))
        elseif k == TK.XML_DECL_OPEN
            first_token || throw(XmlSyntaxError("the XML declaration must come first"))
            in_decl = true
        elseif k == TK.XML_DECL_CLOSE
            in_decl = false
        elseif k == TK.DOCTYPE_OPEN
            throw(UnsupportedError(FEATURE_PRESERVE_DTD))
        end
        # Comments and processing instructions carry no data in the strict
        # profile; CDATA open and close marks only bound the CDATA text.
        first_token = false
    end
    in_tag && throw(XmlSyntaxError("unterminated start tag <$tag"))
    isempty(scan.tags) || throw(XmlSyntaxError("unclosed elements: $(join(scan.tags, ", "))"))
    flush_text!(sink, scan)
    roots == 0 && throw(XmlSyntaxError("no root element"))
    return nothing
end

# A sink that collects `Event`s with `Lexical` values (`xml_events`).
struct EventSink
    out::Vector{Event}
end

sink_start!(s::EventSink, uri::SubStr, l::SubStr) = (push!(s.out, StartElement(String(uri), String(l))); nothing)
sink_xsi_type!(s::EventSink, uri::SubStr, l::SubStr) = (push!(s.out, XsiType(String(uri), String(l))); nothing)
sink_xsi_nil!(s::EventSink, nil::Bool) = (push!(s.out, XsiNil(nil)); nothing)
sink_attr!(s::EventSink, uri::SubStr, l::SubStr, v::SubStr) =
    (push!(s.out, Attribute(String(uri), String(l), Lexical(String(v)))); nothing)
sink_text!(s::EventSink, buf::Vector{UInt8}, n::Int) =
    (push!(s.out, Characters(Lexical(String(buf[1:n])))); nothing)
sink_end!(s::EventSink) = (push!(s.out, EndElement()); nothing)
