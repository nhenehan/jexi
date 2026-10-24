# The encoder: events in, EXI bytes out (https://www.w3.org/TR/exi/#encodingBody).
#
# Call the event functions in document order: `start_document!`,
# `start_element!`, `attribute!` (in EXI order: xsi:type, xsi:nil, then the
# others sorted by local name and URI, as the XML front-end gives them),
# `characters!`, `end_element!`, `end_document!`, then `finish!` for the bytes.
# Text is buffered until the next structural event, so whitespace-only text can
# be dropped the way EXIficient does.

"""
    Encoder(tables, options = strict_options(); header = HeaderConfig())

An encoder for one stream, over the grammar tables `tables` (a `GrammarSet`).
It writes the header (and the options document when
`header.include_options`) right away.
"""
mutable struct Encoder
    out::BitWriter
    tables::GrammarSet
    rt::RuntimeTables
    options::ExiOptions
    strings::StringTable
    frames::Vector{Frame}
    cursor::DocCursor
    # Text not yet written: the first `pending_len` bytes of `pending`.
    pending::Vector{UInt8}
    pending_len::Int
    has_pending::Bool
    after_start_tag::Bool
    # The header each stream starts with (for `reset!`); `nothing` for a body only.
    header::Union{Nothing,HeaderConfig}
end

"""A string table started from the grammar's partitions, with the options' value limits."""
init_string_table(tables::GrammarSet, o::ExiOptions) = StringTable(tables;
    value_max_length = o.value_max_length, value_partition_capacity = o.value_partition_capacity)

function Encoder(tables::GrammarSet, options::ExiOptions = strict_options(); header::HeaderConfig = HeaderConfig())
    validate_options(options)
    w = BitWriter()
    write_header_bits!(w, header)
    header.include_options && write_options_document!(w, options)
    is_byte_aligned(options) && set_byte_aligned!(w, true)
    enc = encoder_for_body(w, tables, options)
    enc.header = header
    return enc
end

"""An encoder that writes only a body, into an existing writer."""
function encoder_for_body(w::BitWriter, tables::GrammarSet, options::ExiOptions)
    validate_options(options)
    return Encoder(w, tables, runtime_tables(tables), options, init_string_table(tables, options), Frame[], CUR_DOCUMENT,
        UInt8[], 0, false, false, nothing)
end

bit_position(enc::Encoder) = bit_position(enc.out)

"""The productions of the current rule (empty at document level)."""
current_productions(enc::Encoder) =
    isempty(enc.frames) ? view(enc.tables.productions, 1:0) : rule_productions(enc.tables, enc.frames[end].rule)

"""
    finish!(enc) -> Vector{UInt8}

The encoded bytes, with the last byte padded. The document must be complete.
The vector is the encoder's own buffer: after [`reset!`](@ref) the encoder
writes the next stream into it, so copy what you need to keep first.
"""
function finish!(enc::Encoder)
    enc.cursor == CUR_DONE || throw(GrammarError("ED before finish", "incomplete document"))
    return finish!(enc.out)
end

function Base.push!(enc::Encoder, ev::Event)
    ev isa StartDocument && return start_document!(enc)
    ev isa EndDocument && return end_document!(enc)
    ev isa StartElement && return start_element!(enc, ev.uri, ev.local_name)
    ev isa EndElement && return end_element!(enc)
    ev isa Attribute && return attribute!(enc, ev.uri, ev.local_name, ev.value)
    ev isa XsiType && return xsi_type!(enc, ev.uri, ev.local_name)
    ev isa XsiNil && return xsi_nil!(enc, ev.nil)
    ev isa Characters && return characters!(enc, ev.value)
    ev isa NamespaceDecl && throw(UnsupportedError(FEATURE_PRESERVE_PREFIXES))
    ev isa Comment && throw(UnsupportedError(FEATURE_PRESERVE_COMMENTS))
    ev isa ProcessingInstruction && throw(UnsupportedError(FEATURE_PRESERVE_PIS))
    ev isa DocType && throw(UnsupportedError(FEATURE_PRESERVE_DTD))
    ev isa EntityReference && throw(UnsupportedError(FEATURE_ENTITY_REFERENCE))
    throw(UnsupportedError(FEATURE_SELF_CONTAINED))
end

function top(enc::Encoder)
    isempty(enc.frames) && throw(GrammarError("an open element", "document level"))
    return @inbounds enc.frames[end]
end

set_top!(enc::Encoder, f::Frame) = (@inbounds enc.frames[end] = f; nothing)

function mismatch(enc::Encoder, got::AbstractString)
    c = enc.cursor
    expected = if c == CUR_DOCUMENT
        "SD"
    elseif c == CUR_DOC_END
        "ED"
    elseif c == CUR_DONE
        "nothing (document complete)"
    elseif isempty(enc.frames)
        "SE(root element)"
    else
        describe_rule(enc.tables, enc.frames[end].rule, enc.frames[end])
    end
    return GrammarError(expected, String(got))
end

@inline emit_code!(enc::Encoder, code::Integer, width::Integer) =
    write_nbit_unsigned!(enc.out, UInt64(code), width)

"""
The first production of `rule` whose terminal passes `pred`, with its 0-based
event code (`find_production` over the flat tables).
"""
@inline function find_prod(pred::F, enc::Encoder, rule::RuleIdx) where {F}
    rt = enc.rt
    r = Int(rule) + 1
    first = Int(@inbounds rt.rule_first[r])
    prods = enc.tables.productions
    for i in 0:(Int(@inbounds rt.rule_len[r]) - 1)
        p = @inbounds prods[first + i + 1]
        pred(p.terminal) && return (i, p)
    end
    return nothing
end

"""The first-level event code width of the open element's current rule."""
@inline fl_width(enc::Encoder, f::Frame) =
    ceil_log2(Int(@inbounds enc.rt.rule_len[Int(f.rule) + 1]) + (escape_count(f) > 0 ? 1 : 0))

function start_document!(enc::Encoder)
    enc.cursor == CUR_DOCUMENT || throw(mismatch(enc, "SD"))
    # Document : SD DocContent. One production, so its code takes zero bits.
    enc.cursor = CUR_DOC_CONTENT
    return enc
end

function end_document!(enc::Encoder)
    flush_chars!(enc, false)
    enc.cursor == CUR_DOC_END || throw(mismatch(enc, "ED"))
    enc.cursor = CUR_DONE
    return enc
end

"""Starts an element by name. The name must be declared in the schema."""
start_element!(enc::Encoder, uri::AbstractString, local_name::AbstractString) =
    start_element_resolved!(enc, lookup_qname(enc.rt, uri, local_name), uri, local_name)

"""Starts an element by its compact ids (the `LN_*` constants of generated tables)."""
start_element!(enc::Encoder, q::QNameId) = start_element_resolved!(enc, q, nothing, nothing)

function name_text(enc::Encoder, q, uri, local_name)
    uri !== nothing && return qname_text(uri, local_name)
    q === nothing && return "?"
    return describe_qname(enc.tables, q)
end

function start_element_resolved!(enc::Encoder, q::Union{Nothing,QNameId}, uri, local_name)
    flush_chars!(enc, false)
    g = enc.tables
    if isempty(enc.frames)
        enc.cursor == CUR_DOC_CONTENT || throw(mismatch(enc, "SE"))
        # DocContent : SE(G_0) ... SE(G_n-1) SE(*)
        # (https://www.w3.org/TR/exi/#informedDocGrammars). The root's code is its
        # place among the sorted global elements; any other root would need SE(*)
        # and a built-in grammar.
        q === nothing && throw(UnsupportedError(FEATURE_BUILT_IN_ELEMENT_GRAMMAR))
        pos = findfirst(e -> gelement(g, e).qname == q, g.global_elements)
        pos === nothing && throw(UnsupportedError(FEATURE_BUILT_IN_ELEMENT_GRAMMAR))
        emit_code!(enc, pos - 1, ceil_log2(length(g.global_elements) + 1))
        push_element!(enc, g.global_elements[pos])
        return enc
    end
    f = top(enc)
    elem_frames = enc.rt.elem_frames
    found = q === nothing ? nothing :
            find_prod(t -> t.kind == T_SE && (@inbounds elem_frames[Int(t.a) + 1]).context == q, enc, f.rule)
    if found === nothing
        wildcard = find_prod(t -> t.kind == T_SE_ANY || t.kind == T_SE_NS, enc, f.rule)
        wildcard === nothing || throw(UnsupportedError(FEATURE_WILDCARD))
        throw(mismatch(enc, "SE($(name_text(enc, q, uri, local_name)))"))
    end
    code, prod = found
    emit_code!(enc, code, fl_width(enc, f))
    set_top!(enc, with_rule(f, prod.next))
    push_element!(enc, prod.terminal.a)
    return enc
end

function push_element!(enc::Encoder, elem::ElemIdx)
    push!(enc.frames, @inbounds enc.rt.elem_frames[Int(elem) + 1])
    enc.after_start_tag = true
    return nothing
end

"""Writes an attribute by name. `value` is typed, a `Lexical`, or text."""
function attribute!(enc::Encoder, uri::AbstractString, local_name::AbstractString, value)
    q = lookup_qname(enc.rt, uri, local_name)
    xml_space = uri == XML_NS && local_name == "space"
    return attribute_resolved!(enc, q, uri, local_name, xml_space, value)
end

function attribute!(enc::Encoder, q::QNameId, value)
    g = enc.tables
    xml_space = q.uri == URI_XML && uri_str(g, q.uri) == XML_NS && local_name_str(g, q) == "space"
    return attribute_resolved!(enc, q, nothing, nothing, xml_space, value)
end

function attribute_resolved!(enc::Encoder, q::Union{Nothing,QNameId}, uri, local_name, xml_space::Bool, value)
    flush_chars!(enc, false)
    g = enc.tables
    f = top(enc)
    found = q === nothing ? nothing : find_prod(t -> t.kind == T_AT && term_qname(t) == q, enc, f.rule)
    if found === nothing
        wildcard = find_prod(t -> t.kind == T_AT_ANY || t.kind == T_AT_NS, enc, f.rule)
        wildcard === nothing || throw(UnsupportedError(FEATURE_WILDCARD))
        throw(mismatch(enc, "AT($(name_text(enc, q, uri, local_name)))"))
    end
    code, prod = found
    emit_code!(enc, code, fl_width(enc, f))
    write_typed_value!(enc, kind_of(enc, term_type(prod.terminal)), value, term_qname(prod.terminal))
    f = with_rule(f, prod.next)
    if xml_space
        text = value isa Lexical ? value.text : value isa AbstractString ? value : nothing
        f = with_space(f, text === nothing ? Int8(-1) : Int8(strip(text) == "preserve"))
    end
    set_top!(enc, f)
    return enc
end

"""
    xsi_type!(enc, uri, local)

Writes `xsi:type`: the escape codes, then the type's QName through the string
table, and switches the element to that type's grammar. As in EXIficient, the
target type's own grammar is used, which has no escapes left
(https://github.com/EXIficient/exificient-grammars/blob/9baa044237f649a65ae4190aed75081c75c86a16/src/main/java/com/siemens/ct/exi/grammars/XSDGrammarsBuilder.java#L1474-L1499).
"""
function xsi_type!(enc::Encoder, uri::AbstractString, local_name::AbstractString)
    flush_chars!(enc, false)
    g = enc.tables
    f = top(enc)
    code2 = xsi_type_code(f)
    code2 === nothing && throw(mismatch(enc, "AT(xsi:type)"))
    # The escape is the code just past the last production.
    emit_code!(enc, length(rule_productions(g, f.rule)), first_level_width(g, f))
    emit_code!(enc, code2, second_level_width(f))
    q = write_qname!(enc.strings, enc.out, uri, local_name)
    t = find_type(g, q)
    t === nothing && throw(SchemaError("xsi:type names unknown type $(qname_text(uri, local_name))"))
    set_top!(enc, cast_to(f, grammar_start_rule(g, gtype(g, t).grammar), t))
    return enc
end

"""Writes `xsi:nil`; when true, the element switches to its TypeEmpty grammar."""
function xsi_nil!(enc::Encoder, nil::Bool)
    flush_chars!(enc, false)
    g = enc.tables
    f = top(enc)
    code2 = xsi_nil_code(f)
    code2 === nothing && throw(mismatch(enc, "AT(xsi:nil)"))
    # The escape is the code just past the last production.
    emit_code!(enc, length(rule_productions(g, f.rule)), first_level_width(g, f))
    emit_code!(enc, code2, second_level_width(f))
    write_bool!(enc.out, nil)
    nil && set_top!(enc, nil_to(f, grammar_start_rule(g, gtype(g, f.type_idx).empty_grammar)))
    return enc
end

"""
    characters!(enc, value)

Character content. Text (a `String` or `Lexical`) is buffered and joined with
the text that follows; a typed value is written at once.
"""
function characters!(enc::Encoder, value)
    if value isa Lexical || value isa AbstractString
        s = value isa Lexical ? value.text : value
        pend_text!(enc, codeunits(s), ncodeunits(s))
    else
        flush_chars!(enc, false)
        encode_chars!(enc, value)
    end
    return enc
end

"""Adds the first `n` bytes of `bytes` to the text not yet written."""
function pend_text!(enc::Encoder, bytes::AbstractVector{UInt8}, n::Int)
    buf = enc.pending
    len = enc.pending_len
    # Grow only: the buffer is reused for every run of text.
    len + n > length(buf) && resize!(buf, max(len + n, 2 * length(buf), 64))
    copyto!(buf, len + 1, bytes, 1, n)
    enc.pending_len = len + n
    enc.has_pending = true
    return nothing
end

function end_element!(enc::Encoder)
    flush_chars!(enc, true)
    g = enc.tables
    f = top(enc)
    # Empty simple content (`<a></a>`, an empty list) is an empty CH: simple type
    # grammars have no EE before their CH
    # (https://www.w3.org/TR/exi/#simpleTypeGrammars), and EXIficient writes the
    # empty value the same way:
    # https://github.com/EXIficient/exificient-core/blob/9d853cb456a9d5557fa9d4544917a894c576ab96/src/main/java/com/siemens/ct/exi/core/coder/AbstractEXIBodyEncoder.java#L609-L625
    found = find_prod(t -> t.kind == T_EE, enc, f.rule)
    if found === nothing && !f.nil && find_prod(t -> t.kind == T_CH, enc, f.rule) !== nothing
        encode_chars!(enc, Lexical(""))
        f = top(enc)
        found = find_prod(t -> t.kind == T_EE, enc, f.rule)
    end
    found === nothing && throw(mismatch(enc, "EE"))
    emit_code!(enc, found[1], fl_width(enc, f))
    pop!(enc.frames)
    enc.after_start_tag = false
    isempty(enc.frames) && (enc.cursor = CUR_DOC_END)
    return enc
end

function space_preserved(enc::Encoder)
    for i in length(enc.frames):-1:1
        sp = enc.frames[i].space_preserve
        sp >= 0 && return sp == 1
    end
    return false
end

"""
Writes the buffered text. Whitespace-only text is dropped as EXIficient does:
unless the rule's first production is a typed CH, or the text is the whole
content between a start tag and its end tag, or `xml:space="preserve"` is in
force.
"""
function flush_chars!(enc::Encoder, before_end_tag::Bool)
    enc.has_pending || return nothing
    buf = enc.pending
    n = enc.pending_len
    enc.pending_len = 0
    enc.has_pending = false
    if all_space(buf, n)
        g = enc.tables
        f = top(enc)
        has_ch = find_prod(t -> t.kind == T_CH || t.kind == T_CH_UNTYPED, enc, f.rule) !== nothing
        has_ch || return nothing
        prods = rule_productions(g, f.rule)
        typed_first = !isempty(prods) && prods[1].terminal.kind == T_CH
        simple_data = enc.after_start_tag && before_end_tag
        (!typed_first && !simple_data && !space_preserved(enc)) && return nothing
    end
    encode_chars!(enc, Lexical(GC.@preserve buf unsafe_string(pointer(buf), n)))
    return nothing
end

"""The datatype of type `t` (`datatype` from the flat tables)."""
@inline kind_of(enc::Encoder, t::Integer) = 0 <= t < length(enc.rt.kinds) ? (@inbounds enc.rt.kinds[Int(t) + 1]) : UNTYPED_KIND

function all_space(buf::Vector{UInt8}, n::Int)
    for i in 1:n
        b = @inbounds buf[i]
        (b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')) || return false
    end
    return true
end

function encode_chars!(enc::Encoder, value)
    g = enc.tables
    f = top(enc)
    found = find_prod(t -> t.kind == T_CH || t.kind == T_CH_UNTYPED, enc, f.rule)
    found === nothing && throw(mismatch(enc, "CH"))
    code, prod = found
    emit_code!(enc, code, fl_width(enc, f))
    kind = prod.terminal.kind == T_CH ? kind_of(enc, prod.terminal.a) : UNTYPED_KIND
    write_typed_value!(enc, kind, value, f.context)
    set_top!(enc, with_rule(f, prod.next))
    enc.after_start_tag = false
    return nothing
end

"""
Writes a value of `kind`. Strings go through the value string table with
`context` (the element's or attribute's name); lists are walked item by item.
Plain text given for a typed kind is parsed like XML text.
"""
function write_typed_value!(enc::Encoder, kind::DatatypeKind, value, context::QNameId)
    if kind.tag == K_RESTRICTED_STRING
        # No alphabet (a pattern that did not parse): refused before the string
        # table is touched. See `K_RESTRICTED_STRING`.
        has_alphabet(kind) || throw(UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET))
        s = value isa Lexical ? apply_whitespace(kind.whitespace, value.text) :
            value isa AbstractString ? value : throw(mismatch(kind, value))
        return write_value!(enc.strings, enc.out, context, s, gstring(enc.tables, kind.set))
    end
    if is_string_like(kind)
        ws = kind.tag == K_STRING ? kind.whitespace : WS_PRESERVE
        s = value isa Lexical ? apply_whitespace(ws, value.text) :
            value isa AbstractString ? value : format_value(kind, value, enc.tables)
        return write_value!(enc.strings, enc.out, context, s)
    end
    if kind.tag == K_LIST
        item_kind = datatype(enc.tables, kind.item)
        if value isa ExiList
            write_unsigned!(enc.out, UInt64(length(value.items)))
            for it in value.items
                write_typed_value!(enc, item_kind, it, context)
            end
            return nothing
        elseif value isa Lexical || value isa AbstractString
            text = value isa Lexical ? value.text : value
            # Split on the four XML spaces only, not on every Unicode space.
            items = split(text, is_xml_space; keepempty = false)
            write_unsigned!(enc.out, UInt64(length(items)))
            for it in items
                write_typed_value!(enc, item_kind, Lexical(String(it)), context)
            end
            return nothing
        end
        throw(ValueError("List", "expected a list or lexical value"))
    end
    kind.tag == K_QNAME && throw(InternalError("QName values are encoded by the codec"))
    v = value isa AbstractString ? Lexical(String(value)) : value
    write_scalar!(enc.out, kind, v, enc.tables)
    return nothing
end
