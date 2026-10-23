# Small helpers shared by the example scripts.

"""The path of a file in the `data` folder."""
data(name) = joinpath(@__DIR__, "data", name)

"""Bytes as hex, 16 to a line, each line indented by two spaces."""
hex_lines(bytes) = join(("  " * join(string.(chunk; base = 16, pad = 2), ' ') * '\n'
                         for chunk in Iterators.partition(bytes, 16)))

"""The first `n` bytes as hex on one line."""
hex_start(bytes, n) = join(string.(first(bytes, n); base = 16, pad = 2), ' ')
