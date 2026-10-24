# The string table (https://www.w3.org/TR/exi/#stringTable): it gives strings
# already seen small numbers (compact identifiers), so a repeat can be sent as
# a short number instead of the text.
#
# Partitions:
#
# | partition  | hit                                   | miss                              |
# |------------|---------------------------------------|-----------------------------------|
# | URI        | id + 1 in ceil_log2(m + 1) bits       | 0, then the string; added         |
# | prefix     | id + 1 in ceil_log2(m + 1) bits       | 0, then the string; added         |
# | local name | unsigned 0, then id in ceil_log2(m)   | unsigned (length + 1), the chars  |
# | value      | local: 0 + id; global: 1 + id         | unsigned (length + 2), the chars  |
#
# (https://www.w3.org/TR/exi/#encodingOptimizedForHits and
# https://www.w3.org/TR/exi/#encodingOptimizedForMisses.)
#
# The table starts with the partitions the grammar tables list (spec D.3). It
# refers to the grammar's sorted lists instead of copying them, so building a
# table per stream is cheap. Strings added during the stream go
# into per-URI lists that are made only when first needed.

# Strings added to one URI's prefix or local-name partition during a stream.
mutable struct AddedNames
    names::Vector{String}
    index::Dict{String,UInt32}
end
AddedNames() = AddedNames(String[], Dict{String,UInt32}())

"""
One URI of the initial string table as the grammar lists it: the URI and the
1-based ranges of its prefixes and local names in the grammar's vectors. The
slots are worked out once per `GrammarSet` and shared by every stream.
"""
struct UriSlot
    uri::String
    initial_prefixes::UnitRange{Int}
    initial_locals::UnitRange{Int}
end

include("string_table_values.jl")

"""
    StringTable(tables; value_max_length, value_partition_capacity)

A string table for one stream, started from the partitions in `tables` (a
`GrammarSet`). The two limits are the EXI options of the same names
(https://www.w3.org/TR/exi/#key-valueMaxLength); `nothing` means unbounded.

The initial partitions are the grammar's own sorted lists, found by binary
search. Only what the stream adds is per stream: added URIs, and
added prefixes and local names per URI, each made when first needed. So a new
table costs a few small objects, whatever the size of the schema.
"""
mutable struct StringTable
    tables::GrammarSet
    slots::Vector{UriSlot}
    added_uris::Union{Nothing,Vector{String}}
    uri_index::Union{Nothing,Dict{String,UInt32}}
    added_prefixes::Union{Nothing,Dict{UInt32,AddedNames}}
    added_locals::Union{Nothing,Dict{UInt32,AddedNames}}
    values::ValuePartitions
end

function strictly_sorted(g::GrammarSet, idx::AbstractVector{StrIdx})
    for i in 2:length(idx)
        gstring(g, idx[i - 1]) < gstring(g, idx[i]) || return false
    end
    return true
end

"""
The initial URI slots of `g`, worked out on first use and kept in `g.cache`.
They are empty when the grammar's partitions cannot be searched (a URI listed
twice, or names not strictly sorted); tables then copy the names in instead.
"""
function string_table_slots(g::GrammarSet)
    c = g.cache.slots
    c === nothing || return c::Vector{UriSlot}
    borrowable = true
    for (i, e) in enumerate(g.uris)
        u = gstring(g, e.uri)
        for j in 1:(i - 1)
            gstring(g, g.uris[j].uri) == u && (borrowable = false)
        end
        borrowable &= strictly_sorted(g, view(g.prefixes, span_range(e.prefixes)))
        borrowable &= strictly_sorted(g, view(g.local_names, span_range(e.local_names)))
    end
    slots = borrowable ? UriSlot[UriSlot(gstring(g, e.uri), span_range(e.prefixes), span_range(e.local_names))
                                 for e in g.uris] : UriSlot[]
    g.cache.slots = slots
    return slots
end

function StringTable(
    tables::GrammarSet = empty_grammar_set();
    value_max_length::Union{Nothing,Integer} = nothing,
    value_partition_capacity::Union{Nothing,Integer} = nothing,
)
    g = tables
    slots = string_table_slots(g)
    st = StringTable(g, slots, nothing, nothing, nothing, nothing,
        ValuePartitions(value_max_length, value_partition_capacity))
    if isempty(slots) && !isempty(g.uris)
        # Not searchable: copy the names in, in the listed order.
        for e in g.uris
            id = add_uri!(st, gstring(g, e.uri))
            for p in view(g.prefixes, span_range(e.prefixes))
                add_prefix!(st, id, gstring(g, p))
            end
            for l in view(g.local_names, span_range(e.local_names))
                add_local_name!(st, id, gstring(g, l))
            end
        end
    end
    return st
end

"""
    initial_string_table(schema_informed; value_max_length, value_partition_capacity)

The initial entries of spec D.1-D.3 without any grammar: the empty, XML and XSI
URIs with their prefixes and names, plus the XSD URI and its 46 type names when
`schema_informed`.
"""
function initial_string_table(schema_informed::Bool; kw...)
    st = StringTable(empty_grammar_set(); kw...)
    e = add_uri!(st, "")
    add_prefix!(st, e, "")
    x = add_uri!(st, XML_NS)
    add_prefix!(st, x, "xml")
    foreach(n -> add_local_name!(st, x, n), XML_LOCAL_NAMES)
    s = add_uri!(st, XSI_NS)
    add_prefix!(st, s, "xsi")
    foreach(n -> add_local_name!(st, s, n), XSI_LOCAL_NAMES)
    if schema_informed
        d = add_uri!(st, XSD_NS)
        foreach(n -> add_local_name!(st, d, n), XSD_LOCAL_NAMES)
    end
    return st
end

borrows_initial_entries(st::StringTable) = !isempty(st.slots)
value_max_length(st::StringTable) = st.values.max_length
value_partition_capacity(st::StringTable) = st.values.capacity

# ------------------------------------------------------------------- lookup

function uri_count(st::StringTable)
    a = st.added_uris
    return length(st.slots) + (a === nothing ? 0 : length(a))
end

valid_uri(st::StringTable, uri::Integer) = 0 <= uri < uri_count(st)

# The initial ranges of a URI (empty for one added during the stream).
@inline function initial_prefixes(st::StringTable, uri::Integer)
    uri < length(st.slots) ? (@inbounds st.slots[Int(uri) + 1].initial_prefixes) : (1:0)
end
@inline function initial_locals(st::StringTable, uri::Integer)
    uri < length(st.slots) ? (@inbounds st.slots[Int(uri) + 1].initial_locals) : (1:0)
end

added_of(d::Union{Nothing,Dict{UInt32,AddedNames}}, uri::Integer) = d === nothing ? nothing : get(d, UInt32(uri), nothing)

function find_uri(st::StringTable, uri::AbstractString)
    for (i, s) in enumerate(st.slots)
        s.uri == uri && return UInt32(i - 1)
    end
    index = st.uri_index
    index === nothing && return nothing
    return get(index, uri, nothing)
end

# Binary search of a borrowed, sorted partition; 0-based id or nothing.
function search_initial(g::GrammarSet, idx::Vector{StrIdx}, r::UnitRange{Int}, key::AbstractString)
    isempty(r) && return nothing
    v = view(idx, r)
    lo = lower_bound(g, v, key)
    (lo <= length(v) && gstring(g, v[lo]) == key) ? UInt32(lo - 1) : nothing
end

function find_prefix(st::StringTable, uri::Integer, prefix::AbstractString)
    valid_uri(st, uri) || return nothing
    id = search_initial(st.tables, st.tables.prefixes, initial_prefixes(st, uri), prefix)
    id === nothing || return id
    a = added_of(st.added_prefixes, uri)
    a === nothing && return nothing
    return get(a.index, prefix, nothing)
end

function find_local_name(st::StringTable, uri::Integer, local_name::AbstractString)
    valid_uri(st, uri) || return nothing
    id = search_initial(st.tables, st.tables.local_names, initial_locals(st, uri), local_name)
    id === nothing || return id
    a = added_of(st.added_locals, uri)
    a === nothing && return nothing
    return get(a.index, local_name, nothing)
end

function uri(st::StringTable, id::Integer)
    valid_uri(st, id) || return nothing
    n = length(st.slots)
    id < n && return @inbounds st.slots[Int(id) + 1].uri
    return (st.added_uris::Vector{String})[Int(id) - n + 1]
end

function local_name(st::StringTable, uri::Integer, id::Integer)
    valid_uri(st, uri) || return nothing
    r = initial_locals(st, uri)
    n = length(r)
    0 <= id < n && return gstring(st.tables, @inbounds st.tables.local_names[first(r) + Int(id)])
    a = added_of(st.added_locals, uri)
    (a === nothing || id - n >= length(a.names)) && return nothing
    return a.names[Int(id) - n + 1]
end

function prefix(st::StringTable, uri::Integer, id::Integer)
    valid_uri(st, uri) || return nothing
    r = initial_prefixes(st, uri)
    n = length(r)
    0 <= id < n && return gstring(st.tables, st.tables.prefixes[first(r) + Int(id)])
    a = added_of(st.added_prefixes, uri)
    (a === nothing || id - n >= length(a.names)) && return nothing
    return a.names[Int(id) - n + 1]
end

function local_name_count(st::StringTable, uri::Integer)
    valid_uri(st, uri) || return 0
    a = added_of(st.added_locals, uri)
    return length(initial_locals(st, uri)) + (a === nothing ? 0 : length(a.names))
end

function prefix_count(st::StringTable, uri::Integer)
    valid_uri(st, uri) || return 0
    a = added_of(st.added_prefixes, uri)
    return length(initial_prefixes(st, uri)) + (a === nothing ? 0 : length(a.names))
end

function qname_id(st::StringTable, uri::AbstractString, local_name::AbstractString)
    u = find_uri(st, uri)
    u === nothing && return nothing
    l = find_local_name(st, u, local_name)
    l === nothing && return nothing
    return QNameId(u, l)
end

function qname(st::StringTable, q::QNameId)
    u = uri(st, q.uri)
    l = local_name(st, q.uri, q.local_name)
    (u === nothing || l === nothing) && return nothing
    return (u, l)
end

global_value_count(st::StringTable) = global_count(st.values)
local_value_count(st::StringTable, ctx::QNameId) = local_count(st.values, ctx)
has_value(st::StringTable, v::AbstractString) = find_value(st.values, v) !== nothing

# --------------------------------------------------------------- population

"""Adds a URI (if new) and returns its id."""
function add_uri!(st::StringTable, uri::AbstractString)
    id = find_uri(st, uri)
    id === nothing || return id
    id = UInt32(uri_count(st))
    s = String(uri)
    a = st.added_uris
    if a === nothing
        a = String[]
        st.added_uris = a
    end
    push!(a, s)
    index = st.uri_index
    if index === nothing
        index = Dict{String,UInt32}()
        st.uri_index = index
    end
    index[s] = id
    return id
end

# The added names of `uri` in `d`, made when first needed; the Dict is made too.
function added_names!(st::StringTable, field::Symbol, uri::Integer)
    d = getfield(st, field)::Union{Nothing,Dict{UInt32,AddedNames}}
    if d === nothing
        d = Dict{UInt32,AddedNames}()
        setfield!(st, field, d)
    end
    return get!(AddedNames, d, UInt32(uri))
end

"""Adds a prefix to a URI's partition (if new) and returns its id; `NONE` for a bad URI."""
function add_prefix!(st::StringTable, uri::Integer, prefix::AbstractString)
    id = find_prefix(st, uri, prefix)
    id === nothing || return id
    valid_uri(st, uri) || return NONE
    a = added_names!(st, :added_prefixes, uri)
    id = UInt32(length(initial_prefixes(st, uri)) + length(a.names))
    s = String(prefix)
    push!(a.names, s)
    a.index[s] = id
    return id
end

"""Adds a local name to a URI's partition (if new) and returns its id; `NONE` for a bad URI."""
function add_local_name!(st::StringTable, uri::Integer, local_name::AbstractString)
    id = find_local_name(st, uri, local_name)
    id === nothing || return id
    valid_uri(st, uri) || return NONE
    a = added_names!(st, :added_locals, uri)
    id = UInt32(length(initial_locals(st, uri)) + length(a.names))
    s = String(local_name)
    push!(a.names, s)
    a.index[s] = id
    return id
end

"""
Sorts the local names added to partitions that borrow nothing from the
grammar. The schema compiler uses it to build the sorted initial partitions.
"""
function sort_local_names!(st::StringTable)
    d = st.added_locals
    d === nothing && return st
    for (u, a) in d
        isempty(initial_locals(st, u)) || continue
        sort!(a.names)
        empty!(a.index)
        for (i, n) in enumerate(a.names)
            a.index[n] = UInt32(i - 1)
        end
    end
    return st
end

# ------------------------------------------------------- uri and prefix (7.3.2)

"""Writes a URI: a hit is id + 1, a miss is 0 and then the string (and adds it)."""
function write_uri!(st::StringTable, w::BitWriter, uri::AbstractString)
    n = ceil_log2(uri_count(st) + 1)
    id = find_uri(st, uri)
    if id !== nothing
        write_nbit_unsigned!(w, UInt64(id) + 1, n)
        return id
    end
    write_nbit_unsigned!(w, UInt64(0), n)
    write_string!(w, uri)
    return add_uri!(st, uri)
end

function read_uri!(st::StringTable, r::BitReader)
    n = ceil_log2(uri_count(st) + 1)
    v = read_nbit_unsigned!(r, n)
    v == 0 && return add_uri!(st, read_string!(r))
    v - 1 < uri_count(st) || throw(StringTableError("uri identifier out of range"))
    return UInt32(v - 1)
end

function write_prefix!(st::StringTable, w::BitWriter, uri::Integer, prefix::AbstractString)
    valid_uri(st, uri) || throw(StringTableError("uri identifier out of range"))
    n = ceil_log2(prefix_count(st, uri) + 1)
    id = find_prefix(st, uri, prefix)
    if id !== nothing
        write_nbit_unsigned!(w, UInt64(id) + 1, n)
        return id
    end
    write_nbit_unsigned!(w, UInt64(0), n)
    write_string!(w, prefix)
    return add_prefix!(st, uri, prefix)
end

function read_prefix!(st::StringTable, r::BitReader, uri::Integer)
    valid_uri(st, uri) || throw(StringTableError("uri identifier out of range"))
    count = prefix_count(st, uri)
    v = read_nbit_unsigned!(r, ceil_log2(count + 1))
    v == 0 && return add_prefix!(st, uri, read_string!(r))
    v - 1 < count || throw(StringTableError("prefix identifier out of range"))
    return UInt32(v - 1)
end

# ------------------------------------------------------------ local name (7.3.3)

"""Writes a local name: a hit is unsigned 0 and then the id, a miss is length + 1 and the chars."""
function write_local_name!(st::StringTable, w::BitWriter, uri::Integer, local_name::AbstractString)
    valid_uri(st, uri) || throw(StringTableError("uri identifier out of range"))
    id = find_local_name(st, uri, local_name)
    if id !== nothing
        write_unsigned!(w, UInt64(0))
        write_nbit_unsigned!(w, UInt64(id), ceil_log2(local_name_count(st, uri)))
        return id
    end
    isvalid(local_name) || throw(ValueError("String", "text is not valid UTF-8"))
    write_unsigned!(w, UInt64(length(local_name)) + 1)
    write_chars!(w, local_name)
    return add_local_name!(st, uri, local_name)
end

function read_local_name!(st::StringTable, r::BitReader, uri::Integer)
    valid_uri(st, uri) || throw(StringTableError("uri identifier out of range"))
    count = local_name_count(st, uri)
    v = read_unsigned!(r)
    if v == 0
        id = read_nbit_unsigned!(r, ceil_log2(count))
        id < count || throw(StringTableError("local-name identifier out of range"))
        return UInt32(id)
    end
    return add_local_name!(st, uri, read_chars_string!(r, v - 1, st.values.scratch))
end

# ----------------------------------------------------------------- QName (7.1.7)

"""Writes a QName: the URI, then the local name (https://www.w3.org/TR/exi/#encodingQName)."""
function write_qname!(st::StringTable, w::BitWriter, uri::AbstractString, local_name::AbstractString)
    u = write_uri!(st, w, uri)
    return QNameId(u, write_local_name!(st, w, u, local_name))
end

function read_qname!(st::StringTable, r::BitReader)
    u = read_uri!(st, r)
    return QNameId(u, read_local_name!(st, r, u))
end

# ------------------------------------------------------------------ value (7.3.3)

"""Writes a value string in the partition of `context` (the element or attribute name)."""
write_value!(st::StringTable, w::BitWriter, context::QNameId, value::AbstractString,
    alphabet::Union{Nothing,String} = nothing) = write_value!(st.values, w, context, value, alphabet)

"""Reads a value string of `context`. A hit returns the stored `String` itself."""
read_value!(st::StringTable, r::BitReader, context::QNameId, alphabet::Union{Nothing,String} = nothing) =
    read_value!(st.values, r, context, alphabet)
