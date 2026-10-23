# XML to events (rexi-xml reader.rs).
#
# Namespace declarations are dropped (strict EXI keeps no prefixes). An
# element's attributes come in EXI order: xsi:type first, then xsi:nil, then the
# others sorted by local name and then URI
# (https://www.w3.org/TR/exi/#eventCodeAssignment). Values are `Lexical`, so
# the encoder parses them with the schema's datatypes. Whitespace text is kept
# inside the root element (the encoder decides what to drop, as EXIficient
# does) and dropped outside it.

function parse_nil(value::AbstractString)
    v = strip(c -> c in (' ', '\t', '\n', '\r'), value)
    (v == "true" || v == "1") && return true
    (v == "false" || v == "0") && return false
    throw(XmlSyntaxError("xsi:nil value $(repr(v)) is not a boolean"))
end

"""
    xml_events(xml) -> Vector{Event}

The events of an XML document, from SD to ED, with `Lexical` values.
"""
function xml_events(xml::AbstractString)
    sink = EventSink(Event[StartDocument()])
    scan_xml!(sink, xml)
    push!(sink.out, EndDocument())
    return sink.out
end

# The encoder is a sink too: the document goes straight in, with no events in
# between.
sink_start!(enc::Encoder, uri::SubStr, l::SubStr) = (start_element!(enc, uri, l); nothing)
sink_xsi_type!(enc::Encoder, uri::SubStr, l::SubStr) = (xsi_type!(enc, uri, l); nothing)
sink_xsi_nil!(enc::Encoder, nil::Bool) = (xsi_nil!(enc, nil); nothing)
sink_attr!(enc::Encoder, uri::SubStr, l::SubStr, v::SubStr) = (attribute!(enc, uri, l, Lexical(String(v))); nothing)
sink_text!(enc::Encoder, buf::Vector{UInt8}, n::Int) = (pend_text!(enc, buf, n); nothing)
sink_end!(enc::Encoder) = (end_element!(enc); nothing)

"""Encodes the events of an XML document with `enc`."""
function push_xml!(enc::Encoder, xml::AbstractString)
    start_document!(enc)
    scan_xml!(enc, xml)
    end_document!(enc)
    return enc
end

"""
    encode_xml(xml, tables; options = strict_options(), header = HeaderConfig()) -> Vector{UInt8}

Encodes an XML document as EXI with the grammar tables of its schema.
"""
function encode_xml(xml::AbstractString, tables::GrammarSet; options::ExiOptions = strict_options(),
    header::HeaderConfig = HeaderConfig())
    enc = Encoder(tables, options; header)
    push_xml!(enc, xml)
    return finish!(enc)
end
