# The EXI header (https://www.w3.org/TR/exi/#header) and the options document
# it may carry (https://www.w3.org/TR/exi/#options).
#
# Layout: an optional `$EXI` cookie, the distinguishing bits `10`, the presence
# bit for options, the preview bit (0) and the version in 4-bit chunks (`0000`
# for version 1). The options document, when present, follows at once and is
# coded with the grammars of the Appendix C schema.

const EXI_COOKIE = UInt8[0x24, 0x45, 0x58, 0x49] # "$EXI"

function write_header_bits!(w::BitWriter, h::HeaderConfig)
    h.cookie && write_bytes!(w, EXI_COOKIE)
    write_raw_bits!(w, UInt64(0b10), 2)
    write_raw_bits!(w, UInt64(h.include_options), 1)
    # Final version 1: preview bit 0, then the single chunk 0000 (0 + 1 = 1).
    write_raw_bits!(w, UInt64(0), 1)
    write_raw_bits!(w, UInt64(0), 4)
    return w
end

function read_header_bits!(r::BitReader)
    cookie = false
    first = read_raw_bits!(r, 2)
    if first == 0b00
        # '$' is 0x24 = 00 100100: the other six bits must match.
        read_raw_bits!(r, 6) == (EXI_COOKIE[1] & 0x3f) || throw(HeaderError("invalid EXI cookie"))
        for b in EXI_COOKIE[2:end]
            read_byte!(r) == b || throw(HeaderError("invalid EXI cookie"))
        end
        cookie = true
        read_raw_bits!(r, 2) == 0b10 || throw(HeaderError("invalid distinguishing bits after cookie"))
    elseif first != 0b10
        throw(HeaderError("invalid distinguishing bits"))
    end
    options_in_stream = read_raw_bits!(r, 1) == 1
    preview = read_raw_bits!(r, 1) == 1
    version = 0
    while true
        chunk = Int(read_raw_bits!(r, 4))
        version += chunk
        chunk == 15 || break
    end
    info = HeaderInfo(; cookie, options_in_stream, preview_version = preview, format_version = version + 1)
    (preview || info.format_version != 1) && throw(UnsupportedError(FEATURE_FORMAT_VERSION))
    return info
end

"""
    write_options_document!(w, options)

Writes `options` as an options document: only the elements that differ from
the defaults, in the schema's order. `tables` are the grammars of the Appendix C
schema (tests pass compiled ones).
"""
function write_options_document!(w::BitWriter, o::ExiOptions; tables::GrammarSet = OPTIONS_GRAMMARS)
    enc = encoder_for_body(w, tables, strict_options())
    ns = EXI_OPTIONS_NS
    open!(name) = start_element!(enc, ns, name)
    leaf!(name) = (open!(name); end_element!(enc))
    function number!(name, n)
        open!(name)
        characters!(enc, UInt64(n))
        end_element!(enc)
    end
    start_document!(enc)
    open!("header")
    uncommon = o.alignment != ALIGN_BIT_PACKED || o.self_contained || o.value_max_length !== nothing ||
               o.value_partition_capacity !== nothing || o.datatype_representation_map
    p = o.preserve
    preserve = any_preserve(p)
    if uncommon || preserve || o.block_size !== nothing
        open!("lesscommon")
        if uncommon
            open!("uncommon")
            if o.alignment != ALIGN_BIT_PACKED
                open!("alignment")
                leaf!(o.alignment == ALIGN_BYTE_ALIGNED ? "byte" : "pre-compress")
                end_element!(enc)
            end
            o.self_contained && leaf!("selfContained")
            o.value_max_length === nothing || number!("valueMaxLength", o.value_max_length)
            o.value_partition_capacity === nothing || number!("valuePartitionCapacity", o.value_partition_capacity)
            o.datatype_representation_map && throw(UnsupportedError(FEATURE_DATATYPE_REPRESENTATION_MAP))
            end_element!(enc)
        end
        if preserve
            open!("preserve")
            for (flag, name) in ((p.dtd, "dtd"), (p.prefixes, "prefixes"), (p.lexical_values, "lexicalValues"),
                (p.comments, "comments"), (p.pis, "pis"))
                flag && leaf!(name)
            end
            end_element!(enc)
        end
        o.block_size === nothing || number!("blockSize", o.block_size)
        end_element!(enc)
    end
    if o.compression || o.fragment || o.schema_id !== nothing
        open!("common")
        o.compression && leaf!("compression")
        o.fragment && leaf!("fragment")
        sid = o.schema_id
        if sid isa SchemaIdNil
            open!("schemaId")
            xsi_nil!(enc, true)
            end_element!(enc)
        elseif sid isa String
            open!("schemaId")
            characters!(enc, sid)
            end_element!(enc)
        end
        end_element!(enc)
    end
    o.strict && leaf!("strict")
    end_element!(enc)
    end_document!(enc)
    return w
end

"""
    read_options_document!(r) -> ExiOptions

Reads an options document from the header.
"""
function read_options_document!(r::BitReader)
    dec = decoder_for_body(r, OPTIONS_GRAMMARS, strict_options())
    alignment = ALIGN_BIT_PACKED
    compression = strict = fragment = self_contained = dtrm = false
    dtd = prefixes = lexical_values = comments = pis = false
    value_max_length = value_partition_capacity = block_size = nothing
    schema_id = nothing
    path = LocalId[]
    while true
        k = next!(dec)
        k == EV_DONE && break
        (k == EV_SD || k == EV_ED) && continue
        if k == EV_SE
            dec.qname.uri == EXI_URI || throw(HeaderError("unknown element in options document"))
            id = dec.qname.local_name
            id == OPT_LN_BYTE && (alignment = ALIGN_BYTE_ALIGNED)
            id == OPT_LN_PRE_COMPRESS && (alignment = ALIGN_PRE_COMPRESSION)
            id == OPT_LN_SELFCONTAINED && (self_contained = true)
            id == OPT_LN_DATATYPEREPRESENTATIONMAP && (dtrm = true)
            id == OPT_LN_DTD && (dtd = true)
            id == OPT_LN_PREFIXES && (prefixes = true)
            id == OPT_LN_LEXICALVALUES && (lexical_values = true)
            id == OPT_LN_COMMENTS && (comments = true)
            id == OPT_LN_PIS && (pis = true)
            id == OPT_LN_COMPRESSION && (compression = true)
            id == OPT_LN_FRAGMENT && (fragment = true)
            id == OPT_LN_STRICT && (strict = true)
            id == OPT_LN_SCHEMAID && (schema_id = "")
            push!(path, id)
        elseif k == EV_EE
            pop!(path)
        elseif k == EV_XSI_NIL
            (dec.nil && !isempty(path) && path[end] == OPT_LN_SCHEMAID) && (schema_id = SCHEMA_ID_NIL)
        elseif k == EV_CH
            isempty(path) && throw(HeaderError("character data outside an element"))
            cur = path[end]
            v = dec.value
            if cur == OPT_LN_SCHEMAID
                v isa AbstractString || throw(HeaderError("schemaId is not a string"))
                schema_id = String(v)
            elseif cur == OPT_LN_VALUEMAXLENGTH || cur == OPT_LN_VALUEPARTITIONCAPACITY || cur == OPT_LN_BLOCKSIZE
                (v isa Integer && 0 <= v <= typemax(UInt32)) || throw(HeaderError("option value out of range"))
                n = UInt32(v)
                if cur == OPT_LN_VALUEMAXLENGTH
                    value_max_length = n
                elseif cur == OPT_LN_VALUEPARTITIONCAPACITY
                    value_partition_capacity = n
                else
                    block_size = n
                end
            else
                throw(HeaderError("unexpected character data in options document"))
            end
        elseif k == EV_XSI_TYPE
            throw(HeaderError("xsi:type in options document"))
        else
            throw(HeaderError("unexpected event in options document"))
        end
    end
    return ExiOptions(; alignment, compression, strict, fragment,
        preserve = Preserve(; dtd, prefixes, lexical_values, comments, pis), self_contained,
        value_max_length, value_partition_capacity, block_size, schema_id,
        datatype_representation_map = dtrm)
end
