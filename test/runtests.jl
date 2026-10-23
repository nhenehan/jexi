using JExi
using Test

@testset "JExi" begin
    include("io.jl")
    include("datatype.jl")
    include("string_table.jl")
    include("header.jl")
    include("schema.jl")
    include("fixtures_strict.jl")
    include("reuse.jl")
    include("xml.jl")
    include("generated_tables.jl")
    include("structs.jl")
    include("cli.jl")
    include("quality.jl")
    include("performance.jl")
end
