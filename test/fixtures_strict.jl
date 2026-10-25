# Milestone 1: the interop fixtures (rexi-tests/tests/fixtures_strict.rs).
# For each case and profile:
#   (a) encoding the XML gives EXIficient 1.0.7's bytes, bit for bit;
#   (b) decoding EXIficient's bytes gives the oracle's event stream;
#   (c) re-encoding the typed decoded events gives the bytes back;
#   (e) exipd, the exip decoder, accepts JExi's output.
import JExi as J

const INTEROP = joinpath(@__DIR__, "fixtures", "interop")

struct Profile
    name::String
    options::Function
    header::J.HeaderConfig
    exipd_ops::Union{Nothing,String}
end

const PROFILES = [
    Profile("strict-bp", _ -> J.strict_options(), J.HeaderConfig(), "-%v%-%-%-"),
    Profile("strict-bp-opts", c -> J.strict_options(schema_id = c.name), J.HeaderConfig(include_options = true), nothing),
    Profile("strict-ba", _ -> J.strict_options(alignment = J.ALIGN_BYTE_ALIGNED), J.HeaderConfig(), "-%va%-%-%-"),
]

reference(c, p) = read(joinpath(INTEROP, "$(c.name).$(p.name).exi"))
out_of_band(c, p) = p.header.include_options ? nothing : p.options(c)

function first_bit_difference(a::Vector{UInt8}, b::Vector{UInt8})
    for i in 1:min(length(a), length(b))
        a[i] == b[i] || return (i - 1) * 8 + leading_zeros(a[i] ⊻ b[i])
    end
    return length(a) == length(b) ? nothing : min(length(a), length(b)) * 8
end

function describe_diff(label, actual, expected)
    bit = first_bit_difference(actual, expected)
    bit === nothing && return "$label: identical ($(length(actual)) bytes)"
    byte = bit ÷ 8
    lo = max(byte - 4, 0)
    hex(s) = join((string(x; base = 16, pad = 2) for x in s[(lo + 1):min(end, lo + 12)]), ' ')
    return "$label: first difference at bit $bit (byte $byte); actual $(length(actual)) bytes, expected $(length(expected)) bytes\n" *
           "  actual   [$lo..]: $(hex(actual))\n  expected [$lo..]: $(hex(expected))"
end

third_party_dir() = get(ENV, "JEXI_THIRD_PARTY", joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "jexi", "third_party"))
exipd_binary() = (p = joinpath(third_party_dir(), "exip", "build", "examples", "simpleDecoding", "exipd"); isfile(p) ? p : nothing)
judges_required() = haskey(ENV, "JEXI_REQUIRE_JUDGES")
schema_exis(c) = [joinpath(INTEROP, basename(x) * ".exi") for x in c.xsds]

"""Runs exipd on a stream; `nothing` when it accepts it, else what it said."""
function run_exipd(ops, schemas, stream)
    cmd = `$(exipd_binary()) $(ops === nothing ? String[] : ["-ops=$ops"]) -schema=$(join(schemas, ','))`
    out = IOBuffer()
    err = IOBuffer()
    ok = success(pipeline(cmd; stdin = IOBuffer(stream), stdout = out, stderr = err))
    text = String(take!(out))
    (ok && !occursin("Error", text)) && return nothing
    return "exipd failed\nstdout:\n$text\nstderr:\n$(String(take!(err)))"
end

function check_fixtures(tables_for)
    @testset "$(c.name)" for c in interop_cases()
        # Named after the case, as the strict-bp-opts streams' schemaId says.
        tables = J.with_schema_id(tables_for(c), c.name)
        xml = read(c.xml, String)
        @testset "$(p.name)" for p in PROFILES
            expected = reference(c, p)
            # (a)
            actual = J.encode_xml(xml, tables; options = p.options(c), header = p.header)
            same = first_bit_difference(actual, expected) === nothing
            same || @info describe_diff("$(c.name) $(p.name)", actual, expected)
            @test same
            # (b)
            events = J.decode_events(expected, tables; options = out_of_band(c, p))
            want = read(joinpath(INTEROP, "$(c.name).$(p.name).events"), String)
            got = J.events_dump(events)
            if rstrip(got) != rstrip(want)
                a, b = split(got, '\n'), split(want, '\n')
                i = something(findfirst(k -> a[k] != b[k], 1:min(length(a), length(b))), 0)
                @info "$(c.name) $(p.name): events differ at line $i" got = get(a, i, "") want = get(b, i, "")
            end
            @test rstrip(got) == rstrip(want)
            # (c)
            typed = J.decode_events(expected, tables; options = out_of_band(c, p), typed = true)
            enc = J.Encoder(tables, p.options(c); header = p.header)
            foreach(e -> push!(enc, e), typed)
            again = J.finish!(enc)
            same = first_bit_difference(again, expected) === nothing
            same || @info describe_diff("$(c.name) $(p.name) (re-encode)", again, expected)
            @test same
            # (e)
            if p.exipd_ops !== nothing
                if exipd_binary() === nothing
                    @test !judges_required()
                else
                    verdict = run_exipd(p.exipd_ops, schema_exis(c), actual)
                    verdict === nothing || @info "$(c.name) $(p.name): $verdict"
                    @test verdict === nothing
                end
            end
        end
    end
end

@testset "interop fixtures (runtime tables)" begin
    check_fixtures(c -> J.compile_files(c.xsds...))
end
