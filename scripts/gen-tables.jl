# Regenerates (or, with --check, verifies) the static grammar tables in
# test/generated: one module per interop fixture, plus the Appendix C schema.
# Run through scripts/gen-tables.sh.
using JExi

const ROOT = dirname(@__DIR__)
const FIX = joinpath(ROOT, "test", "fixtures")
const OUT = joinpath(ROOT, "test", "generated")

check = "--check" in ARGS
camel(name) = join(uppercasefirst.(split(name, '-')))
jobs = Tuple{String,String,String,Vector{String}}[]
for line in eachline(joinpath(FIX, "interop", "cases.tsv"))
    startswith(line, "name\t") && continue
    f = split(line, '\t')
    imports = length(f) >= 4 ? [String(x) for x in split(f[4], ',') if !isempty(x)] : String[]
    xsds = [joinpath(FIX, "interop", f[3]); [joinpath(FIX, "interop", x) for x in imports]]
    push!(jobs, (replace(String(f[1]), '-' => '_'), camel(f[1]), "GRAMMARS", xsds))
end
push!(jobs, ("exi_options", "ExiOptions", "EXI_OPTIONS", [joinpath(FIX, "spec", "exi-options.xsd")]))

ok = true
for (file, mod, name, xsds) in jobs
    out = joinpath(OUT, file * ".jl")
    same = JExi.SchemaGen.generate(xsds; out, name, module_name = mod, check)
    if check && !same
        println(stderr, "STALE    ", relpath(out, ROOT))
        global ok = false
    end
end
check && ok && println("generated tables ok")
check || println("wrote ", length(jobs), " modules to ", relpath(OUT, ROOT))
exit(ok ? 0 : 1)
