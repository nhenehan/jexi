# Reusing a decoder or an encoder for the next stream.
#
# `reset!` puts a codec back into the state a new one built with the same
# arguments would be in, keeping its buffers, so a program that handles many
# small documents (one per network message, say) doesn't build a string
# table, a bit reader or writer and a grammar stack for each. A reset codec
# reads and writes exactly the same bits as a new one; test/reuse.jl checks
# that against fresh codecs.

function reset!(r::BitReader{V}, data::V) where {V}
    r.data = data
    r.next = firstindex(data)
    r.pending = 0x00
    r.pending_len = 0
    r.byte_aligned = false
    r.bits_read = UInt64(0)
    return r
end

function reset!(w::BitWriter)
    empty!(w.out)
    w.pending = 0x00
    w.pending_len = 0
    w.byte_aligned = false
    w.bits_written = UInt64(0)
    return w
end

function reset!(vp::ValuePartitions)
    empty!(vp.entries)
    empty!(vp.slots)
    # Back to scanning: the index is rebuilt when the stream passes the limit,
    # exactly as in a new table.
    vp.index = nothing
    vp.by_context = nothing
    vp.next_global = UInt32(0)
    return vp
end

function reset!(st::StringTable)
    st.added_uris = nothing
    st.uri_index = nothing
    st.added_prefixes = nothing
    st.added_locals = nothing
    reset!(st.values)
    return st
end

"""
A string table for the next stream under options `o`: `st` itself, reset,
when it can be (same value limits, partitions borrowed from the grammar);
otherwise a new one.
"""
function string_table_for(st::StringTable, tables::GrammarSet, o::ExiOptions)
    vp = st.values
    same_limits = vp.max_length == (o.value_max_length === nothing ? nothing : UInt32(o.value_max_length)) &&
                  vp.capacity == (o.value_partition_capacity === nothing ? nothing : UInt32(o.value_partition_capacity))
    copied = isempty(st.slots) && !isempty(tables.uris)  # names were copied in, not borrowed
    return same_limits && !copied ? reset!(st) : init_string_table(tables, o)
end

"""
    reset!(dec::Decoder{V}, bytes::V) -> dec

Points `dec` at the next stream, `bytes` (of the same type as before),
and makes it behave as a new `Decoder` over those bytes with the arguments it
was built with: same tables, out-of-band options and limits. A header that
carries options applies to this stream only. Buffers are kept.
"""
function reset!(dec::Decoder{V}, bytes::V) where {V}
    # The grammar state first, so that a bad header still leaves a clean decoder.
    empty!(dec.frames)
    dec.cursor = CUR_DOCUMENT
    dec.qname = QNameId(NONE, NONE)
    dec.value = nothing
    dec.nil = false
    dec.last_kind = UNTYPED_KIND
    dec.string_bytes = 0
    r = reset!(dec.inp, bytes)
    opts = dec.options
    if dec.has_header
        info = read_header_bits!(r)
        opts = if info.options_in_stream
            read_options_document!(r)
        else
            given = dec.given_options
            given === nothing && throw(HeaderError("stream carries no options and none were given out of band"))
            given
        end
        if opts !== dec.options
            validate_options(opts)
            check_schema_id(opts.schema_id, dec.tables.schema_id)
        end
        dec.header = info
    end
    is_byte_aligned(opts) && set_byte_aligned!(r, true)
    dec.strings = string_table_for(dec.strings, dec.tables, opts)
    dec.options = opts
    return dec
end

"""
    reset!(enc::Encoder) -> enc

Starts the next stream: `enc` behaves as a new `Encoder` built with the same
arguments, and writes the header again. Buffers are kept, including the one
[`finish!`](@ref) returned, which the next stream overwrites.
"""
function reset!(enc::Encoder)
    w = reset!(enc.out)
    h = enc.header
    if h !== nothing
        write_header_bits!(w, h)
        h.include_options && write_options_document!(w, enc.options)
    end
    is_byte_aligned(enc.options) && set_byte_aligned!(w, true)
    enc.strings = string_table_for(enc.strings, enc.tables, enc.options)
    empty!(enc.frames)
    enc.cursor = CUR_DOCUMENT
    enc.pending_len = 0
    enc.has_pending = false
    enc.after_start_tag = false
    return enc
end

"""
    event_qname_id(dec) -> QNameId

The current event's name (SE, AT, xsi:type) as the string table's id pair,
without looking the strings up. Compare it with ids from `qname_id` or a
generated table's constants.
"""
event_qname_id(dec::Decoder) = dec.qname
