# The `jexi` command line (rexi-xml bin/rexi.rs), same commands and flags as
# `rexi`, so the rexi-interop harness drives both the same way. `bin/jexi` runs
# `JExi.CLI.main(ARGS)`.

"""
    CLI

The `jexi` command: `encode`, `decode`, `dump-events`, `dump-grammar`,
`xml-events` and `bench encode|decode`. See `JExi.CLI.USAGE`.
"""
module CLI

import ..JExi as J

const USAGE = """
usage:
  jexi encode  --xsd <main.xsd>[,<more.xsd>...] [options] <in.xml> <out.exi>
  jexi decode  --xsd <main.xsd>[,...] [options] <in.exi>        EXI to XML on stdout
  jexi dump-events --xsd <main.xsd>[,...] [options] <in.exi>    EXI to .events on stdout
  jexi dump-grammar --xsd <main.xsd>[,...]                      list the compiled grammars
  jexi xml-events <in.xml>                                      XML to .events on stdout
  jexi bench encode --xsd ... [options] [bench] <in.xml>        time encoding, JSON on stdout
  jexi bench decode --xsd ... [options] [bench] <in.exi>        time decoding, JSON on stdout

options (encode: header contents; decode/dump-events: out-of-band options used when
the stream carries none):
  --strict | --no-strict            strict schema-informed mode (default: strict)
  --alignment bit-packed|byte-aligned
  --include-options                 write the EXI options document into the header
  --cookie                          write the \$EXI cookie
  --schema-id ID | --schema-id-nil  schemaId option (default: absent)
  --value-max-length N
  --value-partition-capacity N

decode limits (decode, dump-events, bench decode; 0 = no limit):
  --max-depth N                     elements open at once (default 256)
  --max-list-items N                items in one list value (default 1000000)
  --max-integer-bits N              bits in one integer value (default 4096)
  --max-string-bytes N              bytes of decoded string values (default 268435456)
  --no-limits                       turn every limit off

schema loading (every command with --xsd):
  --schema-root DIR                 xs:include and xs:import read only files under DIR
                                    (default: the main schema's folder; / allows any)

bench options (schemas are compiled once, outside the timed region):
  --warmup N                        untimed iterations first (default 20)
  --warmup-ms MS                    and keep warming up until MS milliseconds
                                    have passed (default 0); JIT runtimes need time,
                                    not a count, to reach optimized code
  --iterations N                    timed iterations (default 200)
  --from xml|events                 encode: time XML parsing + encoding (default), or
                                    encoding only, from events parsed once beforehand
  --out FILE                        encode: write the EXI produced
  --events-out FILE                 decode: write the decoded .events dump
"""

"""A command-line problem: the message goes to stderr, exit code 1."""
struct UsageError <: Exception
    msg::String
end

Base.@kwdef mutable struct Args
    xsd::Vector{String} = String[]
    # --schema-root: where includes and imports may read from.
    schema_root::Union{Nothing,String} = nothing
    strict::Union{Nothing,Bool} = nothing
    alignment::J.Alignment = J.ALIGN_BIT_PACKED
    include_options::Bool = false
    cookie::Bool = false
    schema_id::Union{Nothing,J.SchemaIdNil,String} = nothing
    value_max_length::Union{Nothing,UInt32} = nothing
    value_partition_capacity::Union{Nothing,UInt32} = nothing
    warmup::Int = 20
    warmup_ms::Int = 0
    iterations::Int = 200
    from_events::Bool = false
    out::Union{Nothing,String} = nothing
    events_out::Union{Nothing,String} = nothing
    limits::J.DecodeLimits = J.DecodeLimits()
    positional::Vector{String} = String[]
end

function parse_u32(flag, v)
    x = tryparse(UInt32, v)
    x === nothing && throw(UsageError("$flag expects an unsigned integer, got $(repr(v))"))
    return x
end

"""A decode limit flag: 0 means no limit (`nothing`)."""
function parse_limit(flag, v)
    x = tryparse(UInt64, v)
    x === nothing && throw(UsageError("$flag expects an unsigned integer, got $(repr(v))"))
    return x == 0 ? nothing : Int(min(x, UInt64(typemax(Int))))
end

with_limit(l::J.DecodeLimits; kw...) = J.DecodeLimits(; max_depth = l.max_depth, max_list_items = l.max_list_items,
    max_integer_bits = l.max_integer_bits, max_string_bytes = l.max_string_bytes, kw...)

function parse_args(argv::Vector{String})
    a = Args()
    i = 1
    function value_of(flag)
        i += 1
        i <= length(argv) || throw(UsageError("$flag needs a value"))
        return argv[i]
    end
    while i <= length(argv)
        arg = argv[i]
        if arg == "--xsd"
            append!(a.xsd, filter(!isempty, split(value_of(arg), ',')))
        elseif arg == "--schema-root"
            a.schema_root = String(value_of(arg))
        elseif arg == "--strict"
            a.strict = true
        elseif arg == "--no-strict"
            a.strict = false
        elseif arg == "--alignment"
            v = value_of(arg)
            a.alignment = v == "bit-packed" ? J.ALIGN_BIT_PACKED : v == "byte-aligned" ? J.ALIGN_BYTE_ALIGNED :
                          throw(UsageError("unknown alignment $(repr(v))"))
        elseif arg == "--include-options"
            a.include_options = true
        elseif arg == "--cookie"
            a.cookie = true
        elseif arg == "--schema-id"
            a.schema_id = value_of(arg)
        elseif arg == "--schema-id-nil"
            a.schema_id = J.SCHEMA_ID_NIL
        elseif arg == "--value-max-length"
            a.value_max_length = parse_u32(arg, value_of(arg))
        elseif arg == "--value-partition-capacity"
            a.value_partition_capacity = parse_u32(arg, value_of(arg))
        elseif arg == "--max-depth"
            a.limits = with_limit(a.limits; max_depth = parse_limit(arg, value_of(arg)))
        elseif arg == "--max-list-items"
            a.limits = with_limit(a.limits; max_list_items = parse_limit(arg, value_of(arg)))
        elseif arg == "--max-integer-bits"
            a.limits = with_limit(a.limits; max_integer_bits = parse_limit(arg, value_of(arg)))
        elseif arg == "--max-string-bytes"
            a.limits = with_limit(a.limits; max_string_bytes = parse_limit(arg, value_of(arg)))
        elseif arg == "--no-limits"
            a.limits = J.unlimited_limits()
        elseif arg == "--warmup"
            a.warmup = Int(parse_u32(arg, value_of(arg)))
        elseif arg == "--warmup-ms"
            a.warmup_ms = Int(parse_u32(arg, value_of(arg)))
        elseif arg == "--iterations"
            a.iterations = Int(parse_u32(arg, value_of(arg)))
        elseif arg == "--from"
            v = value_of(arg)
            a.from_events = v == "events" ? true : v == "xml" ? false :
                            throw(UsageError("--from expects xml or events, got $(repr(v))"))
        elseif arg == "--out"
            a.out = value_of(arg)
        elseif arg == "--events-out"
            a.events_out = value_of(arg)
        elseif arg in ("-h", "--help")
            throw(UsageError(USAGE))
        elseif startswith(arg, "--")
            throw(UsageError("unknown option $arg"))
        else
            push!(a.positional, arg)
        end
        i += 1
    end
    return a
end

function options_of(a::Args)
    a.strict == false &&
        throw(UsageError("--no-strict: non-strict (schema-informed with deviations) encoding is not supported yet"))
    return J.strict_options(; alignment = a.alignment, value_max_length = a.value_max_length,
        value_partition_capacity = a.value_partition_capacity, schema_id = a.schema_id)
end

function tables_of(a::Args)
    isempty(a.xsd) && throw(UsageError("--xsd is required"))
    return J.compile_files(a.xsd...; load_options = J.SchemaLoadOptions(; root = a.schema_root))
end

function positional(a::Args, n::Int, names::AbstractString)
    length(a.positional) == n || throw(UsageError("expected $names\n$USAGE"))
    return a.positional
end

header_of(a::Args) = J.HeaderConfig(; cookie = a.cookie, include_options = a.include_options)

"""
    main(argv; out = stdout, err = stderr) -> Int

Runs one `jexi` command and returns the exit code: 0, or 1 with `jexi: <message>` on `err`.
"""
function main(argv::Vector{String} = ARGS; out::IO = stdout, err::IO = stderr)
    try
        run(argv, out)
        return 0
    catch e
        e isa InterruptException && rethrow()
        msg = e isa UsageError ? e.msg : sprint(showerror, e)
        println(err, "jexi: ", rstrip(msg))
        return 1
    end
end

function run(argv::Vector{String}, out::IO)
    isempty(argv) && throw(UsageError(USAGE))
    command = argv[1]
    a = parse_args(argv[2:end])
    if command == "encode"
        input, output = positional(a, 2, "<in.xml> <out.exi>")
        opts = options_of(a)
        bytes = J.encode_xml(read(input, String), tables_of(a); options = opts, header = header_of(a))
        write(output, bytes)
    elseif command == "decode" || command == "dump-events"
        input, = positional(a, 1, "<in.exi>")
        opts = options_of(a)
        tables = tables_of(a)
        bytes = read(input)
        limits = a.limits
        print(out, command == "decode" ? J.decode_to_xml(bytes, tables; options = opts, limits) :
                   J.events_dump(J.decode_events(bytes, tables; options = opts, limits)))
    elseif command == "dump-grammar"
        positional(a, 0, "no positional arguments")
        print(out, J.grammar_listing(tables_of(a)))
    elseif command == "xml-events"
        input, = positional(a, 1, "<in.xml>")
        print(out, J.events_dump(J.xml_events(read(input, String))))
    elseif command == "bench"
        bench(a, out)
    elseif command in ("help", "-h", "--help")
        throw(UsageError(USAGE))
    else
        throw(UsageError("unknown command $(repr(command))\n$USAGE"))
    end
    return nothing
end

"""
Runs `op` untimed at least `warmup` times and for at least `warmup_ms`
milliseconds, then `iterations` times timed; the nanoseconds of each.
"""
function time_runs(op, warmup::Int, warmup_ms::Int, iterations::Int)
    start = time_ns()
    done = 0
    while done < warmup || (time_ns() - start) < UInt64(warmup_ms) * 1_000_000
        op()
        done += 1
    end
    ns = Vector{UInt64}(undef, iterations)
    for i in 1:iterations
        t = time_ns()
        op()
        ns[i] = time_ns() - t
    end
    return ns
end

function count_events(bytes, tables, opts, limits)
    dec = J.Decoder(bytes, tables; options = opts, limits)
    n = 0
    while J.next!(dec) != J.EV_DONE
        n += 1
    end
    return n
end

"""
`jexi bench encode|decode`: timing inside this process, for the interop
benchmark. Prints one JSON object with the operation, sizes, the setup time
(schema compiling) and the nanoseconds of every timed run. For `encode`,
`output` is the EXI size in bytes; for `decode`, the number of events.
"""
function bench(a::Args, out::IO)
    op, input = positional(a, 2, "encode|decode <input>")
    opts = options_of(a)
    header = header_of(a)
    t0 = time_ns()
    tables = tables_of(a)
    setup_ns = time_ns() - t0
    data = read(input)
    if op == "encode"
        xml = String(copy(data))
        encoded = J.encode_xml(xml, tables; options = opts, header)
        out_path = a.out
        out_path === nothing || write(out_path, encoded)
        ns = if a.from_events
            xml_evs = J.xml_events(xml)
            time_runs(a.warmup, a.warmup_ms, a.iterations) do
                enc = J.Encoder(tables, opts; header)
                for ev in xml_evs
                    push!(enc, ev)
                end
                J.finish!(enc)
            end
        else
            time_runs(() -> J.encode_xml(xml, tables; options = opts, header), a.warmup, a.warmup_ms, a.iterations)
        end
        kind, output = a.from_events ? "events" : "xml", length(encoded)
    elseif op == "decode"
        limits = a.limits
        events = J.decode_events(data, tables; options = opts, limits)
        events_path = a.events_out
        events_path === nothing || write(events_path, J.events_dump(events))
        # Only the decoder is timed; events are counted and thrown away.
        ns = time_runs(() -> count_events(data, tables, opts, limits), a.warmup, a.warmup_ms, a.iterations)
        kind, output = "exi", length(events)
    else
        throw(UsageError("bench: unknown operation $(repr(op)) (encode|decode)"))
    end
    print(out, "{\"impl\":\"jexi\",\"version\":\"", pkgversion(J), "\",\"op\":\"", op, "\",\"input\":\"", kind,
        "\",\"input_bytes\":", length(data), ",\"output\":", output, ",\"setup_ns\":", setup_ns, ",\"warmup\":",
        a.warmup, ",\"iterations\":", a.iterations, ",\"ns\":[", join(ns, ','), "]}\n")
    return nothing
end

end # module CLI
