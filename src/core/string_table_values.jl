# The value partitions of the string table
# (https://www.w3.org/TR/exi/#encodingOptimizedForMisses).
#
# Every value added goes into the global partition and into the local
# partition of its context (the qname of the element or attribute it belongs
# to). With `valuePartitionCapacity` the global partition is a ring: when it is
# full, the next value takes the oldest slot, and the old value's local id
# stays counted but is never assigned again
# (https://www.w3.org/TR/exi/#key-valuePartitionCapacity).
#
# Storage: one entry per value ever added. Small tables (16 entries or fewer)
# are scanned; past that a `Dict` from text to entry and a per-context list are
# built once and kept up to date (the bits do not depend on this).
# Julia strings are shared, not copied, so a hit returns the stored `String`
# with no allocation.

const VALUE_SCAN_LIMIT = 16

struct ValueEntry
    text::String
    context::QNameId
    local_id::LocalId
    # The slot in the global partition; `NONE` once evicted.
    global_id::UInt32
end

is_live(e::ValueEntry) = e.global_id != NONE

mutable struct ValuePartitions
    max_length::Union{Nothing,UInt32}
    capacity::Union{Nothing,UInt32}
    entries::Vector{ValueEntry}
    # With a capacity: entry index (0-based) of each global slot.
    slots::Vector{UInt32}
    # Past the scan limit: live text -> entry index, and context -> entry indexes.
    index::Union{Nothing,Dict{String,UInt32}}
    by_context::Union{Nothing,Dict{QNameId,Vector{UInt32}}}
    next_global::UInt32
    # Scratch bytes for decoding strings (see `read_chars_string!`).
    scratch::Vector{UInt8}
end

ValuePartitions(max_length::Union{Nothing,Integer}, capacity::Union{Nothing,Integer}) =
    ValuePartitions(max_length === nothing ? nothing : UInt32(max_length),
        capacity === nothing ? nothing : UInt32(capacity), ValueEntry[], UInt32[], nothing,
        nothing, UInt32(0), UInt8[])

global_count(vp::ValuePartitions) = vp.capacity === nothing ? length(vp.entries) : length(vp.slots)

function local_count(vp::ValuePartitions, ctx::QNameId)
    bc = vp.by_context
    if bc !== nothing
        v = get(bc, ctx, nothing)
        return v === nothing ? 0 : length(v)
    end
    n = 0
    for e in vp.entries
        e.context == ctx && (n += 1)
    end
    return n
end

"""Entry index (0-based) of the live value `text`, or nothing."""
function find_value(vp::ValuePartitions, text::AbstractString)
    index = vp.index
    if index === nothing
        for (i, e) in enumerate(vp.entries)
            (is_live(e) && e.text == text) && return UInt32(i - 1)
        end
        return nothing
    end
    return get(index, text, nothing)
end

function entry_of_global(vp::ValuePartitions, gid::Integer)
    if vp.capacity === nothing
        return gid < length(vp.entries) ? UInt32(gid) : nothing
    end
    return gid < length(vp.slots) ? vp.slots[Int(gid) + 1] : nothing
end

function entry_of_local(vp::ValuePartitions, ctx::QNameId, lid::Integer)
    bc = vp.by_context
    if bc !== nothing
        v = get(bc, ctx, nothing)
        (v === nothing || lid >= length(v)) && return nothing
        return v[Int(lid) + 1]
    end
    for (i, e) in enumerate(vp.entries)
        (e.context == ctx && e.local_id == lid) && return UInt32(i - 1)
    end
    return nothing
end

function is_addable(vp::ValuePartitions, len::Integer)
    (len == 0 || vp.capacity == 0) && return false
    return vp.max_length === nothing || len <= vp.max_length
end

# `indexed`: the caller has already put `text` in `vp.index` (see `read_value!`).
function add_value!(vp::ValuePartitions, ctx::QNameId, text::String, indexed::Bool = false)
    # Past the scan limit, the context's list gives the local count and takes
    # the new entry: one lookup.
    bc = vp.by_context
    ctx_list = bc === nothing ? nothing : get!(Vector{UInt32}, bc, ctx)
    lid = UInt32(ctx_list === nothing ? local_count(vp, ctx) : length(ctx_list))
    gid = vp.next_global
    idx = UInt32(length(vp.entries))
    cap = vp.capacity
    if cap !== nothing
        if gid < length(vp.slots)
            # Slot in use: the new value replaces the old one, whose local id
            # becomes permanently unassigned.
            old_idx = vp.slots[Int(gid) + 1]
            old = vp.entries[Int(old_idx) + 1]
            index = vp.index
            index === nothing || delete!(index, old.text)
            vp.entries[Int(old_idx) + 1] = ValueEntry("", old.context, old.local_id, NONE)
            vp.slots[Int(gid) + 1] = idx
        else
            push!(vp.slots, idx)
        end
        vp.next_global = (gid + 1) % cap
    else
        vp.next_global = gid + 1
    end
    push!(vp.entries, ValueEntry(text, ctx, lid, gid))
    index = vp.index
    if index !== nothing && ctx_list !== nothing
        indexed || (index[text] = idx)
        push!(ctx_list, idx)
    elseif length(vp.entries) > VALUE_SCAN_LIMIT
        # Leaving the small range: build both indexes once.
        index = sizehint!(Dict{String,UInt32}(), 4 * VALUE_SCAN_LIMIT)
        bc = Dict{QNameId,Vector{UInt32}}()
        for (i, e) in enumerate(vp.entries)
            is_live(e) && (index[e.text] = UInt32(i - 1))
            push!(get!(Vector{UInt32}, bc, e.context), UInt32(i - 1))
        end
        vp.index = index
        vp.by_context = bc
    end
    return nothing
end

"""
    write_value!(vp, w, ctx, value, alphabet = nothing)

Writes a value: a hit, or the literal with its length plus two. `alphabet` is
the restricted character set of the value's type, if it has one.
"""
function write_value!(vp::ValuePartitions, w::BitWriter, ctx::QNameId, value::AbstractString,
    alphabet::Union{Nothing,String} = nothing)
    index = vp.index
    if index !== nothing && value isa String && !isempty(value) && vp.max_length === nothing && vp.capacity != 0
        # Every non-empty value is added on a miss, so one hash finds the value
        # or puts it in the index (as `read_value!` does).
        new = UInt32(length(vp.entries))
        idx = get!(index, value, new)
        idx == new || return write_hit!(vp, w, ctx, idx)
        if !isvalid(value)
            delete!(index, value)
            throw(ValueError("String", "text is not valid UTF-8"))
        end
        write_unsigned!(w, UInt64(length(value)) + 2)
        alphabet === nothing ? write_code_points!(w, value) : write_rcs_chars!(w, value, alphabet)
        add_value!(vp, ctx, value, true)
        return w
    end
    idx = find_value(vp, value)
    idx === nothing || return write_hit!(vp, w, ctx, idx)
    isvalid(value) || throw(ValueError("String", "text is not valid UTF-8"))
    len = length(value)
    write_unsigned!(w, UInt64(len) + 2)
    alphabet === nothing ? write_code_points!(w, value) : write_rcs_chars!(w, value, alphabet)
    is_addable(vp, len) && add_value!(vp, ctx, String(value))
    return w
end

"""Writes a value found in the table: its local id when the context matches, else its global id."""
function write_hit!(vp::ValuePartitions, w::BitWriter, ctx::QNameId, idx::UInt32)
    e = vp.entries[Int(idx) + 1]
    if e.context == ctx
        write_unsigned!(w, UInt64(0))
        return write_nbit_unsigned!(w, UInt64(e.local_id), ceil_log2(local_count(vp, ctx)))
    end
    write_unsigned!(w, UInt64(1))
    return write_nbit_unsigned!(w, UInt64(e.global_id), ceil_log2(global_count(vp)))
end

function read_value!(vp::ValuePartitions, r::BitReader, ctx::QNameId, alphabet::Union{Nothing,String} = nothing)
    v = read_unsigned!(r)
    if v == 0
        lid = read_nbit_unsigned!(r, ceil_log2(local_count(vp, ctx)))
        idx = entry_of_local(vp, ctx, lid)
        idx === nothing && throw(StringTableError("local value identifier out of range"))
        e = vp.entries[Int(idx) + 1]
        is_live(e) || throw(StringTableError("local value identifier is unassigned"))
        return e.text
    elseif v == 1
        gid = read_nbit_unsigned!(r, ceil_log2(global_count(vp)))
        idx = entry_of_global(vp, gid)
        idx === nothing && throw(StringTableError("global value identifier out of range"))
        return vp.entries[Int(idx) + 1].text
    end
    len = v - 2
    s = alphabet === nothing ? read_chars_string!(r, len, vp.scratch) : read_rcs_string!(r, len, alphabet)
    is_addable(vp, len) || return s
    index = vp.index
    if index === nothing
        find_value(vp, s) === nothing && add_value!(vp, ctx, s)
    else
        # One hash: insert `s` unless it is already live.
        idx = UInt32(length(vp.entries))
        get!(index, s, idx) == idx && add_value!(vp, ctx, s, true)
    end
    return s
end
