# String tables, ported from rexi-core/src/string_table/{mod,initial,value}.rs
# (with EXIficient's StringTableCoreTest, BoundedTableTestCase and
# InitialEntriesStringTablePartitionsTestCase).
import JExi as J

const QN = J.QNameId

function default_table(; kw...)
    t = J.StringTable(; kw...)
    for u in ("", J.XML_NS, J.XSI_NS, J.XSD_NS)
        J.add_uri!(t, u)
    end
    return t
end

# The plain model of the value partitions (rexi value_reference.rs): one global
# list, an index, and per-context lists of global ids (`nothing` once evicted).
mutable struct RefValues
    max_length::Union{Nothing,Int}
    capacity::Union{Nothing,Int}
    global_::Vector{Tuple{String,QN,Int}}
    index::Dict{String,Int}
    locals::Dict{QN,Vector{Union{Nothing,Int}}}
    next::Int
end
RefValues(m, c) = RefValues(m, c, Tuple{String,QN,Int}[], Dict{String,Int}(), Dict{QN,Vector{Union{Nothing,Int}}}(), 0)
ref_local_count(v, ctx) = length(get(v.locals, ctx, []))
ref_addable(v, len) = !(len == 0 || v.capacity == 0) && (v.max_length === nothing || len <= v.max_length)
function ref_add!(v, ctx, s)
    lid = ref_local_count(v, ctx)
    gid = v.next
    if v.capacity !== nothing && gid < length(v.global_)
        old = v.global_[gid + 1]
        v.global_[gid + 1] = (s, ctx, lid)
        delete!(v.index, old[1])
        v.locals[old[2]][old[3] + 1] = nothing
        v.next = (gid + 1) % v.capacity
    else
        push!(v.global_, (s, ctx, lid))
        v.next = v.capacity === nothing ? gid + 1 : (gid + 1) % v.capacity
    end
    push!(get!(v.locals, ctx, Union{Nothing,Int}[]), gid)
    v.index[s] = gid
end
function ref_write!(v, w, ctx, s)
    gid = get(v.index, s, nothing)
    if gid !== nothing
        slot = v.global_[gid + 1]
        if slot[2] == ctx
            J.write_unsigned!(w, UInt64(0))
            J.write_nbit_unsigned!(w, UInt64(slot[3]), J.ceil_log2(ref_local_count(v, ctx)))
        else
            J.write_unsigned!(w, UInt64(1))
            J.write_nbit_unsigned!(w, UInt64(gid), J.ceil_log2(length(v.global_)))
        end
    else
        J.write_unsigned!(w, UInt64(length(s) + 2))
        J.write_chars!(w, s)
        ref_addable(v, length(s)) && ref_add!(v, ctx, s)
    end
end

mutable struct Lcg
    s::UInt64
end
next!(l::Lcg) = (l.s = l.s * 0x5851f42d4c957f2d + 0x14057b7ef767814f; l.s >> 33)
pick!(l::Lcg, items) = items[next!(l) % length(items) + 1]

function random_items(seed, n)
    rng = Lcg(seed)
    contexts = [QN(0, 0), QN(0, 1), QN(0, 2), QN(1, 0), QN(2, 5)]
    alphabet = ['a', 'b', 'c', 'é', '€', '😀', '0', '1']
    return [(pick!(rng, contexts), String([pick!(rng, alphabet) for _ in 1:(next!(rng) % 9)])) for _ in 1:n]
end

function vencode(vp, aligned, items)
    w = J.BitWriter(; byte_aligned = aligned)
    for (ctx, v) in items
        J.write_value!(vp, w, ctx, v)
    end
    return J.finish!(w)
end

function vdecode(vp, aligned, bytes, ctxs)
    r = J.BitReader(bytes; byte_aligned = aligned)
    return [J.read_value!(vp, r, c) for c in ctxs]
end

function vround_trip(max_len, cap, aligned, items)
    enc = J.ValuePartitions(max_len, cap)
    bytes = vencode(enc, aligned, items)
    dec = J.ValuePartitions(max_len, cap)
    ctxs = first.(items)
    ok = vdecode(dec, aligned, bytes, ctxs) == last.(items)
    ok &= J.global_count(enc) == J.global_count(dec)
    ok &= all(J.local_count(enc, c) == J.local_count(dec, c) for c in ctxs)
    return ok
end

@testset "string table" begin
    @testset "initial entries, schema-less" begin
        t = J.initial_string_table(false)
        @test J.uri_count(t) == 3
        @test [J.uri(t, i) for i in 0:2] == ["", J.XML_NS, J.XSI_NS]
        @test [J.prefix_count(t, i) for i in 0:2] == [1, 1, 1]
        @test [J.prefix(t, i, 0) for i in 0:2] == ["", "xml", "xsi"]
        @test J.local_name_count(t, 0) == 0
        @test [J.local_name(t, 1, i) for i in 0:3] == ["base", "id", "lang", "space"]
        @test [J.local_name(t, 2, i) for i in 0:1] == ["nil", "type"]
        @test J.uri(t, 3) === nothing
    end

    @testset "initial entries, schema-informed" begin
        t = J.initial_string_table(true)
        @test J.uri_count(t) == 4
        @test J.uri(t, 3) == J.XSD_NS
        @test J.prefix_count(t, 3) == 0
        @test J.local_name_count(t, 3) == 46
        @test J.local_name(t, 3, 0) == "ENTITIES"
        @test J.local_name(t, 3, 45) == "unsignedShort"
        @test J.find_local_name(t, 3, "dateTime") == 18
        @test J.qname_id(t, J.XSI_NS, "type") == QN(2, 1)
        # Spec D.3: each partition is in dictionary order already.
        @test issorted(collect(J.XSD_LOCAL_NAMES)) && issorted(collect(J.XML_LOCAL_NAMES))
        before = [J.local_name(t, 3, i) for i in 0:45]
        J.sort_local_names!(t)
        @test [J.local_name(t, 3, i) for i in 0:45] == before
    end

    @testset "borrowing the grammar's partitions" begin
        g = J.empty_grammar_set()
        append!(g.strings, ["", "urn:a", "a", "b", "c"])
        append!(g.local_names, UInt32[2, 3, 4])
        push!(g.uris, J.UriEntry(0, J.Span(0, 0), J.Span(0, 0)), J.UriEntry(1, J.Span(0, 0), J.Span(0, 3)))
        t = J.StringTable(g)
        @test J.borrows_initial_entries(t)
        @test J.qname_id(t, "urn:a", "c") == QN(1, 2)
        @test J.add_local_name!(t, 1, "d") == 3
        @test J.local_name(t, 1, 3) == "d"
        # Out of order: copied in instead, in the listed order. (A fresh set:
        # tables must not change after their first stream, see GrammarCache.)
        g = J.GrammarSet(g.strings, g.uris, UInt32[], UInt32[4, 2, 3], J.Production[], J.Rule[], J.Grammar[],
            J.ElementDecl[], J.ElemIdx[], J.GlobalAttribute[], J.TypeDecl[], J.Span[], UInt32[], nothing)
        t = J.StringTable(g)
        @test !J.borrows_initial_entries(t)
        @test J.qname_id(t, "urn:a", "c") == QN(1, 0)
        @test J.qname_id(t, "urn:a", "b") == QN(1, 2)
    end

    @testset "add_uri" begin
        t = default_table()
        @test J.uri_count(t) == 4
        @test J.add_uri!(t, J.XSI_NS) == 2
        @test J.add_uri!(t, "urn:a") == 4
        @test J.add_uri!(t, "urn:a") == 4
        @test J.find_uri(t, "urn:a") == 4
        @test J.find_uri(t, "urn:b") === nothing
        @test J.uri(t, 4) == "urn:a"
        @test J.uri(t, 5) === nothing
    end

    @testset "bad uri ids" begin
        t = default_table()
        @test J.add_prefix!(t, 99, "p") == J.NONE
        @test J.add_local_name!(t, 99, "l") == J.NONE
        @test J.local_name_count(t, 99) == 0
        @test J.prefix_count(t, 99) == 0
        @test J.local_name(t, 99, 0) === nothing
        @test J.prefix(t, 99, 0) === nothing
        @test_throws J.StringTableError J.write_local_name!(t, J.BitWriter(), 99, "l")
        @test_throws J.StringTableError J.write_prefix!(t, J.BitWriter(), 99, "p")
    end

    @testset "uri hit" begin
        t = default_table()
        w = J.BitWriter()
        @test J.write_uri!(t, w, J.XSI_NS) == 2
        @test J.bit_position(w) == 3
        @test J.write_uri!(t, w, "") == 0
        @test J.bit_position(w) == 6
        bytes = J.finish!(w)
        @test bytes == [0b0110_0100]
        d = default_table()
        r = J.BitReader(bytes)
        @test J.read_uri!(d, r) == 2
        @test J.read_uri!(d, r) == 0
    end

    @testset "uri miss" begin
        t = default_table()
        w = J.BitWriter()
        @test J.write_uri!(t, w, "urn:x") == 4
        @test J.uri_count(t) == 5
        @test J.bit_position(w) == 3 + 8 + 40
        @test J.write_uri!(t, w, "urn:x") == 4
        @test J.bit_position(w) == 3 + 48 + 3
        bytes = J.finish!(w)
        r = J.BitReader(bytes)
        @test J.read_nbit_unsigned!(r, 3) == 0
        @test J.read_string!(r) == "urn:x"
        @test J.read_nbit_unsigned!(r, 3) == 5
        d = default_table()
        r = J.BitReader(bytes)
        @test J.read_uri!(d, r) == 4
        @test J.uri(d, 4) == "urn:x"
        @test J.read_uri!(d, r) == 4
        @test J.uri_count(d) == 5
    end

    @testset "uri widths follow the partition" begin
        t = J.StringTable()
        w = J.BitWriter()
        @test J.write_uri!(t, w, "a") == 0
        @test J.bit_position(w) == 16
        @test J.write_uri!(t, w, "a") == 0
        @test J.bit_position(w) == 17
        for (i, u) in enumerate(["b", "c", "d", "e", "f", "g"])
            @test J.write_uri!(t, w, u) == i
        end
        before = J.bit_position(w)
        @test J.write_uri!(t, w, "g") == 6
        @test J.bit_position(w) - before == 3
        @test J.write_uri!(t, w, "h") == 7
        before = J.bit_position(w)
        @test J.write_uri!(t, w, "h") == 7
        @test J.bit_position(w) - before == 4
        d = J.StringTable()
        r = J.BitReader(J.finish!(w))
        @test [J.read_uri!(d, r) for _ in 1:11] == [0, 0, 1, 2, 3, 4, 5, 6, 6, 7, 7]
    end

    @testset "uri id out of range" begin
        @test_throws J.StringTableError J.read_uri!(default_table(), J.BitReader(UInt8[0b110_00000]))
    end

    @testset "local name hit and miss" begin
        t = J.initial_string_table(false)
        x = J.URI_XML
        w = J.BitWriter()
        @test J.write_local_name!(t, w, x, "lang") == 2
        @test J.bit_position(w) == 10
        @test J.write_local_name!(t, w, x, "foo") == 4
        @test J.bit_position(w) == 10 + 8 + 24
        @test J.local_name_count(t, x) == 5
        @test J.local_name(t, x, 4) == "foo"
        @test J.write_local_name!(t, w, x, "foo") == 4
        @test J.bit_position(w) == 42 + 8 + 3
        @test J.write_local_name!(t, w, 0, "root") == 0
        @test J.write_local_name!(t, w, 0, "root") == 0
        bytes = J.finish!(w)
        r = J.BitReader(bytes)
        @test J.read_unsigned!(r) == 0
        @test J.read_nbit_unsigned!(r, 2) == 2
        @test J.read_unsigned!(r) == 4
        @test String(take!(J.read_chars!(r, 3, IOBuffer()))) == "foo"
        @test J.read_unsigned!(r) == 0
        @test J.read_nbit_unsigned!(r, 3) == 4
        @test J.read_unsigned!(r) == 5
        d = J.initial_string_table(false)
        r = J.BitReader(bytes)
        @test J.read_local_name!(d, r, x) == 2
        @test J.read_local_name!(d, r, x) == 4
        @test J.local_name(d, x, 4) == "foo"
        @test J.read_local_name!(d, r, x) == 4
        @test J.read_local_name!(d, r, 0) == 0
        @test J.read_local_name!(d, r, 0) == 0
        @test J.local_name(d, 0, 0) == "root"
    end

    @testset "local name length counts code points" begin
        t = J.initial_string_table(false)
        w = J.BitWriter()
        @test J.write_local_name!(t, w, 0, "é€") == 0
        bytes = J.finish!(w)
        @test bytes[1] == 3
        d = J.initial_string_table(false)
        @test J.read_local_name!(d, J.BitReader(bytes), 0) == 0
        @test J.local_name(d, 0, 0) == "é€"
    end

    @testset "local name id out of range" begin
        # xml has 4 names: a hit reads 2 bits; nothing above 3 exists, so use the
        # empty partition: 0 bits read, id 0, but no entry.
        @test_throws J.StringTableError J.read_local_name!(J.initial_string_table(false), J.BitReader(UInt8[0x00]), 0)
    end

    @testset "prefix hit and miss" begin
        t = J.initial_string_table(false)
        x = J.URI_XML
        w = J.BitWriter()
        @test J.write_prefix!(t, w, x, "xml") == 0
        @test J.bit_position(w) == 1
        @test J.write_prefix!(t, w, x, "x") == 1
        @test J.bit_position(w) == 1 + 1 + 16
        @test J.write_prefix!(t, w, x, "x") == 1
        @test J.bit_position(w) == 20
        @test J.prefix_count(t, x) == 2
        @test J.find_prefix(t, x, "x") == 1
        d = J.initial_string_table(false)
        r = J.BitReader(J.finish!(w))
        @test J.read_prefix!(d, r, x) == 0
        @test J.read_prefix!(d, r, x) == 1
        @test J.read_prefix!(d, r, x) == 1
        @test J.prefix(d, x, 1) == "x"
    end

    @testset "qname round trip and lookup" begin
        t = J.initial_string_table(true)
        w = J.BitWriter()
        seq = [(J.XSI_NS, "type"), ("urn:ex", "root"), ("urn:ex", "child"), ("urn:ex", "root"), ("", "a"),
            (J.XSD_NS, "dateTime")]
        ids = [J.write_qname!(t, w, u, l) for (u, l) in seq]
        @test ids == [QN(2, 1), QN(4, 0), QN(4, 1), QN(4, 0), QN(0, 0), QN(3, 18)]
        @test J.qname_id(t, "urn:ex", "child") == ids[3]
        @test J.qname_id(t, "urn:ex", "nope") === nothing
        @test J.qname_id(t, "urn:nope", "root") === nothing
        @test J.qname(t, ids[3]) == ("urn:ex", "child")
        @test J.qname(t, QN(4, 9)) === nothing
        d = J.initial_string_table(true)
        r = J.BitReader(J.finish!(w))
        for (i, (u, l)) in enumerate(seq)
            @test J.read_qname!(d, r) == ids[i]
            @test J.qname(d, ids[i]) == (u, l)
        end
    end

    @testset "value: miss, local hit, global hit" begin
        t = default_table()
        at = QN(0, 0)
        el = QN(0, 1)
        w = J.BitWriter()
        J.write_value!(t, w, at, "abc")
        @test J.bit_position(w) == 32
        J.write_value!(t, w, at, "abc")
        @test J.bit_position(w) == 40
        J.write_value!(t, w, el, "abc")
        @test J.bit_position(w) == 48
        bytes = J.finish!(w)
        @test bytes == [5, UInt8('a'), UInt8('b'), UInt8('c'), 0, 1]
        @test J.global_value_count(t) == 1
        @test J.local_value_count(t, at) == 1
        @test J.local_value_count(t, el) == 0
        @test J.has_value(t, "abc")
        d = default_table()
        r = J.BitReader(bytes)
        @test [J.read_value!(d, r, c) for c in (at, at, el)] == ["abc", "abc", "abc"]
    end

    @testset "value limits are reported" begin
        t = J.StringTable(; value_max_length = 10, value_partition_capacity = 100)
        @test J.value_max_length(t) == 10
        @test J.value_partition_capacity(t) == 100
        t = J.StringTable()
        @test J.value_max_length(t) === nothing
        @test J.value_partition_capacity(t) === nothing
    end

    @testset "byte-aligned round trip" begin
        t = J.initial_string_table(true)
        w = J.BitWriter(; byte_aligned = true)
        ctx = QN(0, 0)
        @test J.write_qname!(t, w, "urn:ex", "root") == QN(4, 0)
        @test J.write_qname!(t, w, "urn:ex", "root") == QN(4, 0)
        @test J.write_prefix!(t, w, 4, "ex") == 0
        @test J.write_prefix!(t, w, 4, "ex") == 0
        @test J.write_qname!(t, w, J.XML_NS, "lang") == QN(1, 2)
        vals = ["one", "two", "one", "", "three", "two"]
        foreach(v -> J.write_value!(t, w, ctx, v), vals)
        J.write_value!(t, w, QN(4, 0), "three")
        bytes = J.finish!(w)
        r = J.BitReader(bytes; byte_aligned = true)
        @test J.read_nbit_unsigned!(r, 3) == 0
        @test J.bit_position(r) == 8
        d = J.initial_string_table(true)
        r = J.BitReader(bytes; byte_aligned = true)
        @test J.read_qname!(d, r) == QN(4, 0)
        @test J.read_qname!(d, r) == QN(4, 0)
        @test J.read_prefix!(d, r, 4) == 0
        @test J.read_prefix!(d, r, 4) == 0
        @test J.read_qname!(d, r) == QN(1, 2)
        @test [J.read_value!(d, r, ctx) for _ in vals] == vals
        @test J.read_value!(d, r, QN(4, 0)) == "three"
        @test J.uri(d, 4) == "urn:ex"
        @test J.prefix(d, 4, 0) == "ex"
    end

    @testset "random operation sequences round trip" begin
        uris = ["", J.XML_NS, "urn:a", "urn:b", "urn:c"]
        locals = ["x", "y", "z", "lang", "élan", "w"]
        prefixes = ["p", "q", "xml", ""]
        values = ["", "1", "22", "333", "4444", "€uro", "xyzzy", "a b"]
        for seed in 1:4, aligned in (false, true), (max_len, cap) in ((nothing, nothing), (2, nothing), (nothing, 3), (3, 1))
            rng = Lcg(seed)
            ops = map(1:300) do _
                k = next!(rng) % 4
                k == 0 && return (:qname, pick!(rng, uris), pick!(rng, locals))
                k == 1 && return (:prefix, Int(next!(rng) % 3), pick!(rng, prefixes))
                return (:value, QN(next!(rng) % 3, next!(rng) % 3), pick!(rng, values))
            end
            enc = J.initial_string_table(false; value_max_length = max_len, value_partition_capacity = cap)
            w = J.BitWriter(; byte_aligned = aligned)
            expected = map(ops) do op
                op[1] == :qname && return J.write_qname!(enc, w, op[2], op[3])
                op[1] == :prefix && return J.write_prefix!(enc, w, op[2], op[3])
                J.write_value!(enc, w, op[2], op[3])
                return op[3]
            end
            dec = J.initial_string_table(false; value_max_length = max_len, value_partition_capacity = cap)
            r = J.BitReader(J.finish!(w); byte_aligned = aligned)
            got = map(ops) do op
                if op[1] == :qname
                    id = J.read_qname!(dec, r)
                    J.qname(dec, id) == (op[2], op[3]) || return :wrong_name
                    return id
                end
                op[1] == :prefix && return J.read_prefix!(dec, r, op[2])
                return J.read_value!(dec, r, op[2])
            end
            @test got == expected
        end
    end

    A, B, C = QN(0, 0), QN(0, 1), QN(0, 2)

    @testset "value partitions" begin
        vp = J.ValuePartitions(nothing, nothing)
        @test vencode(vp, false, [(A, "ab")]) == [4, UInt8('a'), UInt8('b')]
        @test J.global_count(vp) == 1 && J.local_count(vp, A) == 1
        vp = J.ValuePartitions(nothing, nothing)
        @test vencode(vp, false, [(A, ""), (A, "")]) == [2, 2]
        @test J.global_count(vp) == 0 && J.local_count(vp, A) == 0
        @test vround_trip(nothing, nothing, false, [(A, ""), (B, ""), (A, "x"), (A, "")])
        bytes = vencode(J.ValuePartitions(nothing, nothing), false, [(A, "x"), (A, "y"), (A, "x"), (A, "y")])
        # A local hit is 0, then the local id in ceil_log2(2) = 1 bit.
        r = J.BitReader(bytes)
        @test J.read_unsigned!(r) == 3 && J.read_byte!(r) == UInt8('x')
        @test J.read_unsigned!(r) == 3 && J.read_byte!(r) == UInt8('y')
        @test J.read_unsigned!(r) == 0 && J.read_nbit_unsigned!(r, 1) == 0
        @test J.read_unsigned!(r) == 0 && J.read_nbit_unsigned!(r, 1) == 1
        vp = J.ValuePartitions(nothing, nothing)
        r = J.BitReader(vencode(vp, false, [(A, "x"), (B, "y"), (C, "z"), (B, "z")]))
        for ch in "xyz"
            @test J.read_unsigned!(r) == 3 && J.read_byte!(r) == UInt8(ch)
        end
        @test J.read_unsigned!(r) == 1
        @test J.read_nbit_unsigned!(r, 2) == 2
        @test J.local_count(vp, B) == 1
        @test vencode(J.ValuePartitions(nothing, nothing), false, [(A, "v"), (A, "v")]) == [3, UInt8('v'), 0]
        @test vround_trip(nothing, nothing, false,
            [(A, "val1"), (A, "val2"), (A, "val1"), (A, "val3"), (A, "val3"), (A, "val3")])
        @test vround_trip(nothing, nothing, false,
            [(A, "val1"), (C, "val2"), (B, "val1"), (C, "val3"), (A, "val3"), (C, "val3")])
        at1, elx2, elx3, elxx1, elxx2 = QN(0, 0), QN(0, 1), QN(0, 2), QN(0, 3), QN(0, 4)
        @test vround_trip(nothing, nothing, false,
            [(at1, "at-ch1"), (elxx1, "ch1"), (elxx2, "ch2"), (elx2, "ch2"), (elx3, "ch3"), (at1, "at-ch2"),
                (elxx1, "ch1"), (elxx2, "ch2"), (elx2, "ch2"), (elx2, "ch3")])
    end

    @testset "valueMaxLength" begin
        enc = J.ValuePartitions(5, nothing)
        items = [(A, "123"), (B, "1234"), (A, "12345"), (B, "123456"), (A, "1234567")]
        bytes = vencode(enc, false, items)
        @test J.find_value(enc, "123") !== nothing && J.find_value(enc, "12345") !== nothing
        @test J.find_value(enc, "123456") === nothing && J.find_value(enc, "1234567") === nothing
        @test J.global_count(enc) == 3 && J.local_count(enc, A) == 2 && J.local_count(enc, B) == 1
        dec = J.ValuePartitions(5, nothing)
        @test vdecode(dec, false, bytes, first.(items)) == last.(items)
        @test J.global_count(dec) == 3
        enc = J.ValuePartitions(5, nothing)
        vencode(enc, false, [(A, "héllo")])
        @test J.find_value(enc, "héllo") !== nothing
    end

    @testset "valuePartitionCapacity wraps and evicts" begin
        enc = J.ValuePartitions(nothing, 3)
        w = J.BitWriter()
        has(v) = J.find_value(enc, v) !== nothing
        for (c, v) in ((A, "1"), (B, "12"), (A, "123"), (C, "123"))
            J.write_value!(enc, w, c, v)
        end
        @test J.global_count(enc) == 3
        J.write_value!(enc, w, C, "1234")
        @test !has("1") && has("1234") && J.global_count(enc) == 3
        # "1" left A's local partition: id 0 is unassigned but still counted.
        @test J.local_count(enc, A) == 2
        @test !J.is_live(enc.entries[J.entry_of_local(enc, A, 0) + 1])
        J.write_value!(enc, w, A, "1")
        @test has("1234") && has("1") && has("123") && !has("12")
        @test J.local_count(enc, A) == 3 && J.local_count(enc, B) == 1
        J.write_value!(enc, w, C, "12")
        @test has("1234") && has("1") && has("12") && !has("123")
        dec = J.ValuePartitions(nothing, 3)
        @test vdecode(dec, false, J.finish!(w), [A, B, A, C, C, A, C]) == ["1", "12", "123", "123", "1234", "1", "12"]
        @test J.global_count(dec) == 3 && J.local_count(dec, A) == 3 && J.local_count(dec, C) == 2
    end

    @testset "capacity 0 and 1" begin
        enc = J.ValuePartitions(nothing, 0)
        @test vencode(enc, false, [(A, "x"), (A, "x")]) == [3, UInt8('x'), 3, UInt8('x')]
        @test J.global_count(enc) == 0
        @test vround_trip(nothing, 0, false, [(A, "x"), (A, "x"), (B, "x")])
        @test vround_trip(nothing, 1, false, [(A, "x"), (A, "y"), (A, "x"), (B, "x"), (A, "y"), (A, "y")])
    end

    @testset "EXIficient bounded table 80" begin
        vals = ["VAL_$i" for i in 0:100]
        items = Tuple{QN,String}[]
        for v in vals
            push!(items, (A, v), (B, v))
        end
        for v in reverse(vals)
            push!(items, (A, v), (B, v))
        end
        @test vround_trip(nothing, 80, false, items)
        @test vround_trip(nothing, 80, true, items)
    end

    @testset "random sequences under every limit" begin
        ok = true
        for seed in 1:6
            items = random_items(seed, 400)
            for max_len in (nothing, 0, 2, 5), cap in (nothing, 0, 1, 3, 7, 64), aligned in (false, true)
                ok &= vround_trip(max_len, cap, aligned, items)
            end
        end
        @test ok
    end

    @testset "identical bits to the reference model" begin
        ok = true
        for seed in 1:8, n in (5, 16, 17, 40, 600)
            items = random_items(seed, n)
            for max_len in (nothing, 3), cap in (nothing, 1, 7, 16, 17, 50), aligned in (false, true)
                ours = vencode(J.ValuePartitions(max_len, cap), aligned, items)
                ref = RefValues(max_len, cap)
                w = J.BitWriter(; byte_aligned = aligned)
                foreach(((c, v),) -> ref_write!(ref, w, c, v), items)
                ok &= ours == J.finish!(w)
                ok &= vdecode(J.ValuePartitions(max_len, cap), aligned, ours, first.(items)) == last.(items)
            end
        end
        @test ok
        # Heavy eviction through a 10-slot table.
        items = [(i % 3 == 0 ? A : B, lpad(string(i), 100, '0')) for i in 0:2999]
        ref = RefValues(nothing, 10)
        w = J.BitWriter()
        foreach(((c, v),) -> ref_write!(ref, w, c, v), items)
        @test vencode(J.ValuePartitions(nothing, 10), false, items) == J.finish!(w)
    end

    @testset "decode rejects bad identifiers" begin
        vp = J.ValuePartitions(nothing, nothing)
        @test_throws J.StringTableError J.read_value!(vp, J.BitReader(UInt8[0]), A)
        @test_throws J.StringTableError J.read_value!(vp, J.BitReader(UInt8[1]), A)
        enc = J.ValuePartitions(nothing, 1)
        bytes = vencode(enc, false, [(A, "x"), (A, "y")])
        dec = J.ValuePartitions(nothing, 1)
        vdecode(dec, false, bytes, [A, A])
        # Local id 0 of A is now unassigned.
        err = try
            J.read_value!(dec, J.BitReader(UInt8[0, 0]), A)
            nothing
        catch e
            e
        end
        @test err isa J.StringTableError && occursin("unassigned", err.msg)
    end
end
