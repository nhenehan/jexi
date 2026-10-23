# Allocation budgets and type stability (rexi-tests/tests/static_alloc.rs and
# setup_cost.rs). The budgets have some headroom over what
# 0.1 measures, so a regression trips them; doc/performance.md has the numbers.
import JExi as J

const PERF_G = OrderComplex.GRAMMARS
const PERF_O = J.strict_options()
const PERF_BYTES = read(joinpath(INTEROP, "order-complex.strict-bp.exi"))
const PERF_EVENTS = J.xml_events(read(joinpath(INTEROP, "order-complex.xml"), String))

perf_lookup() = J.find_qname(PERF_G, "urn:rexi:interop:order", "Order")
perf_rule() = length(J.rule_productions(PERF_G, 5))
perf_encoder() = J.Encoder(PERF_G, PERF_O)
perf_decoder() = J.Decoder(PERF_BYTES, PERF_G; options = PERF_O)
function perf_decode()
    d = J.decoder_for_body(J.BitReader(PERF_BYTES), PERF_G, PERF_O)
    J.read_header_bits!(d.inp)
    n = 0
    while J.next!(d) != J.EV_DONE
        n += 1
    end
    return n
end
function perf_encode()
    e = J.Encoder(PERF_G, PERF_O)
    for ev in PERF_EVENTS
        push!(e, ev)
    end
    return J.finish!(e)
end

const PERF_DEC = J.Decoder(PERF_BYTES, PERF_G; options = PERF_O)
const PERF_ENC = J.Encoder(PERF_G, PERF_O)
function perf_reset_decode()
    d = J.reset!(PERF_DEC, PERF_BYTES)
    n = 0
    while J.next!(d) != J.EV_DONE
        n += 1
    end
    return n
end
function perf_reset_encode()
    e = J.reset!(PERF_ENC)
    for ev in PERF_EVENTS
        push!(e, ev)
    end
    return J.finish!(e)
end

allocs(f) = (f(); f(); @allocations f())

@testset "performance" begin
    @testset "reading static tables allocates nothing" begin
        @test allocs(perf_lookup) == 0
        @test allocs(perf_rule) == 0
    end
    @testset "per-stream setup" begin
        @test allocs(perf_encoder) <= 16
        @test allocs(perf_decoder) <= 10
    end
    @testset "whole documents" begin
        @test perf_decode() == 42
        @test allocs(perf_decode) <= 30
        @test allocs(perf_encode) <= 45
    end
    @testset "reused codecs (reset!)" begin
        @test allocs(() -> J.reset!(PERF_DEC, PERF_BYTES)) == 0
        @test allocs(() -> J.reset!(PERF_ENC)) == 0
        @test allocs(perf_reset_decode) <= 14
        @test allocs(perf_reset_encode) <= 21
        @test perf_reset_decode() == 42
        @test perf_reset_encode() == perf_encode()
    end
    if JET_OK
        @testset "the decode loop has no runtime dispatch" begin
            JET.@test_opt target_modules = (J,) perf_decode()
        end
    end
end
