# The decoder: EXI bytes in, events out (a pull API, like StAX).
#
# `next!(dec)` reads one event and returns its kind; `event_qname(dec)` and
# `event_value(dec)` give its name and value. `next_event!(dec)` and iterating a
# decoder give whole `Event` objects instead.

"""What `next!` found (`EV_DONE` after the end of the document)."""
@enum EventKind::UInt8 EV_SD EV_ED EV_SE EV_EE EV_AT EV_XSI_TYPE EV_XSI_NIL EV_CH EV_DONE

"""What the header said (https://www.w3.org/TR/exi/#header)."""
Base.@kwdef struct HeaderInfo
    cookie::Bool = false
    options_in_stream::Bool = false
    preview_version::Bool = false
    format_version::Int = 1
end

"""
    Decoder(bytes, tables; options = nothing, limits = DecodeLimits())

A decoder for one stream over the grammar tables `tables`. `options` are the
options agreed out of band; they are needed when the header carries none.
`limits` caps what a hostile stream can make the decoder do; going over a cap
throws a `LimitError` (see `DecodeLimits`).
"""
mutable struct Decoder{V<:AbstractVector{UInt8}}
    inp::BitReader{V}
    tables::GrammarSet
    rt::RuntimeTables
    options::ExiOptions
    header::HeaderInfo
    strings::StringTable
    frames::Vector{Frame}
    cursor::DocCursor
    # The current event's name (SE, AT, xsi:type), value (AT, CH) and nil flag.
    qname::QNameId
    value::Any
    nil::Bool
    last_kind::DatatypeKind
    # The caps of `DecodeLimits` as plain Ints (typemax(Int) when off).
    max_depth::Int
    max_list_items::Int
    max_integer_bits::Int
    max_string_bytes::Int
    # Bytes of string values decoded so far, for `max_string_bytes`.
    string_bytes::Int
    # For `reset!`: whether streams start with a header, and the options
    # given out of band (as opposed to read from a stream's header).
    has_header::Bool
    given_options::Union{Nothing,ExiOptions}
end

function Decoder(bytes::AbstractVector{UInt8}, tables::GrammarSet; options::Union{Nothing,ExiOptions} = nothing,
    limits::DecodeLimits = DecodeLimits())
    r = BitReader(bytes)
    info = read_header_bits!(r)
    opts = if info.options_in_stream
        read_options_document!(r)
    else
        options === nothing && throw(HeaderError("stream carries no options and none were given out of band"))
        options
    end
    validate_options(opts)
    is_byte_aligned(opts) && set_byte_aligned!(r, true)
    dec = decoder_for_body(r, tables, opts, limits)
    dec.header = info
    dec.has_header = true
    dec.given_options = options
    return dec
end

"""A decoder that reads only a body, from an existing reader."""
function decoder_for_body(r::BitReader, tables::GrammarSet, options::ExiOptions, limits::DecodeLimits = DecodeLimits())
    validate_options(options)
    return Decoder(r, tables, runtime_tables(tables), options, HeaderInfo(), init_string_table(tables, options), Frame[],
        CUR_DOCUMENT, QNameId(NONE, NONE), nothing, false, UNTYPED_KIND, limit_value(limits.max_depth),
        limit_value(limits.max_list_items), limit_value(limits.max_integer_bits),
        limit_value(limits.max_string_bytes), 0, false, options)
end

bit_position(dec::Decoder) = bit_position(dec.inp)

"""The current event's name as `(uri, local)`."""
function event_qname(dec::Decoder)
    n = qname(dec.strings, dec.qname)
    n === nothing && throw(StringTableError("name identifier out of range"))
    return n
end

"""The current event's value (AT, CH): typed, as the datatype gives it."""
event_value(dec::Decoder) = dec.value

"""The datatype of the last value read."""
last_datatype(dec::Decoder) = dec.last_kind

"""The standard text form of `value` as a value of `kind`, with this decoder's tables."""
format_with(dec::Decoder, kind::DatatypeKind, value) = format_value(kind, value, dec.tables)

function top(dec::Decoder)
    isempty(dec.frames) && throw(InternalError("empty grammar stack"))
    return @inbounds dec.frames[end]
end

set_top!(dec::Decoder, f::Frame) = (@inbounds dec.frames[end] = f; nothing)

function push_element!(dec::Decoder, elem::ElemIdx)
    # One frame per open element: refuse the one that would go over the cap.
    length(dec.frames) >= dec.max_depth && throw(LimitError(:depth, dec.max_depth))
    f = dec.rt.elem_frames[Int(elem) + 1]
    push!(dec.frames, f)
    dec.qname = f.context
    return nothing
end

"""
    next!(dec) -> EventKind

Reads the next event. After `EV_ED` it returns `EV_DONE`.
"""
function next!(dec::Decoder)
    c = dec.cursor
    if c == CUR_DOCUMENT
        dec.cursor = CUR_DOC_CONTENT
        return EV_SD
    elseif c == CUR_DOC_END
        dec.cursor = CUR_DONE
        return EV_ED
    elseif c == CUR_DONE
        return EV_DONE
    end
    g = dec.tables
    if isempty(dec.frames)
        # DocContent : SE(G_0) ... SE(G_n-1) SE(*). A code of n or more is SE(*),
        # which would need a built-in grammar.
        n = length(g.global_elements)
        code = read_nbit_unsigned!(dec.inp, ceil_log2(n + 1))
        code >= n && throw(UnsupportedError(FEATURE_BUILT_IN_ELEMENT_GRAMMAR))
        push_element!(dec, g.global_elements[Int(code) + 1])
        return EV_SE
    end
    f = @inbounds dec.frames[end]
    rt = dec.rt
    r = Int(f.rule) + 1
    len = Int(rt.rule_len[r])
    esc = escape_count(f) > 0
    code = Int(read_nbit_unsigned!(dec.inp, ceil_log2(len + esc)))
    if code >= len
        (code == len && esc) && return step_escape!(dec, f)
        throw(GrammarError("event code < $len", "$code at bit $(bit_position(dec.inp))"))
    end
    prod = g.productions[Int(rt.rule_first[r]) + code + 1]
    t = prod.terminal
    k = t.kind
    if k == T_SE
        set_top!(dec, with_rule(f, prod.next))
        push_element!(dec, t.a)
        return EV_SE
    elseif k == T_AT
        kind = rt.kinds[Int(t.c) + 1]
        dec.last_kind = kind
        dec.qname = term_qname(t)
        dec.value = read_typed_value!(dec, kind, term_qname(t))
        set_top!(dec, with_rule(f, prod.next))
        return EV_AT
    elseif k == T_CH || k == T_CH_UNTYPED
        kind = k == T_CH ? rt.kinds[Int(t.a) + 1] : UNTYPED_KIND
        dec.last_kind = kind
        dec.value = read_typed_value!(dec, kind, f.context)
        set_top!(dec, with_rule(f, prod.next))
        return EV_CH
    elseif k == T_EE
        pop!(dec.frames)
        isempty(dec.frames) && (dec.cursor = CUR_DOC_END)
        return EV_EE
    elseif k == T_SE_ANY || k == T_SE_NS || k == T_AT_ANY || k == T_AT_NS || k == T_AT_ANY_UNTYPED
        throw(UnsupportedError(FEATURE_WILDCARD))
    end
    throw(GrammarError("a strict schema-informed production", string(k)))
end

function step_escape!(dec::Decoder, f::Frame)
    g = dec.tables
    code2 = Int(read_nbit_unsigned!(dec.inp, second_level_width(f)))
    if code2 == xsi_type_code(f)
        q = read_qname!(dec.strings, dec.inp)
        t = find_type(g, q)
        if t === nothing
            n = qname(dec.strings, q)
            throw(SchemaError("xsi:type names unknown type $(n === nothing ? "?" : qname_text(n...))"))
        end
        # No escapes after a cast: see `xsi_type!` of the encoder.
        set_top!(dec, cast_to(f, grammar_start_rule(g, gtype(g, t).grammar), t))
        dec.qname = q
        return EV_XSI_TYPE
    elseif code2 == xsi_nil_code(f)
        nil = read_bool!(dec.inp)
        nil && set_top!(dec, nil_to(f, grammar_start_rule(g, gtype(g, f.type_idx).empty_grammar)))
        dec.nil = nil
        return EV_XSI_NIL
    end
    throw(GrammarError("xsi:type or xsi:nil escape", "second-level code $code2"))
end

function read_typed_value!(dec::Decoder, kind::DatatypeKind, context::QNameId)
    if is_string_like(kind)
        s = read_value!(dec.strings, dec.inp, context)
        # A string-table hit costs a few bits but can repeat a long string, so
        # the total is capped, not each string.
        dec.string_bytes += ncodeunits(s)
        dec.string_bytes > dec.max_string_bytes && throw(LimitError(:string_bytes, dec.max_string_bytes))
        return s
    end
    # Refused before the string table is touched: see `K_RESTRICTED_STRING`.
    kind.tag == K_RESTRICTED_STRING && throw(UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET))
    if kind.tag == K_LIST
        item_kind = datatype(dec.tables, kind.item)
        # The item count, then the items (https://www.w3.org/TR/exi/#encodingList).
        # The first allocation is capped so a bad count cannot ask for a huge buffer.
        n = read_unsigned!(dec.inp)
        # Items can take zero bits each, so a short stream can claim billions.
        n > UInt64(dec.max_list_items) && throw(LimitError(:list_items, dec.max_list_items))
        items = Any[]
        sizehint!(items, Int(min(n, UInt64(1024))))
        for _ in 1:n
            push!(items, read_typed_value!(dec, item_kind, context))
        end
        return ExiList(items)
    end
    kind.tag == K_QNAME && throw(InternalError("QName values are decoded by the codec"))
    return read_scalar!(dec.inp, kind, dec.tables, dec.max_integer_bits)
end

"""
    next_event!(dec) -> Union{Nothing,Event}

Reads the next event as an `Event` object; `nothing` after the end.
"""
function next_event!(dec::Decoder)
    k = next!(dec)
    k == EV_SD && return StartDocument()
    k == EV_ED && return EndDocument()
    k == EV_EE && return EndElement()
    k == EV_DONE && return nothing
    k == EV_XSI_NIL && return XsiNil(dec.nil)
    k == EV_CH && return Characters(dec.value)
    u, l = event_qname(dec)
    k == EV_SE && return StartElement(u, l)
    k == EV_AT && return Attribute(u, l, dec.value)
    return XsiType(u, l)
end

Base.IteratorSize(::Type{<:Decoder}) = Base.SizeUnknown()
Base.eltype(::Type{<:Decoder}) = Event

function Base.iterate(dec::Decoder, _ = nothing)
    ev = next_event!(dec)
    return ev === nothing ? nothing : (ev, nothing)
end
