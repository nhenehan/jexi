# Runs every example, in the order the guide uses:
#     julia --project=examples/basics examples/basics/run-all.jl
# Each one runs in a fresh Julia, the same way you would run it by hand.
for name in ("roundtrip", "options", "read_events", "write_events", "structs", "prebuilt_tables")
    println("=== ", name)
    run(`$(Base.julia_cmd()) --startup-file=no --project=$(@__DIR__) $(joinpath(@__DIR__, name * ".jl"))`)
end
