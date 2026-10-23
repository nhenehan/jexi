# Decoder limits: caps that keep a hostile EXI stream from using up memory,
# CPU time or the call stack.
#
# EXI is very compact, so a few bytes can describe a huge amount of work: a
# list of a million empty items, elements nested a million deep, an integer
# with millions of digits, or one long string repeated through the string
# table. These limits refuse such streams early with a `LimitError`. They are
# not part of `ExiOptions`, which mirrors the EXI options document in the
# header; limits are a choice of the program that reads, not of the stream.

"""
    DecodeLimits(; max_depth = 256, max_list_items = 1_000_000,
                   max_integer_bits = 4096, max_string_bytes = 256 * 1024 * 1024)

Caps on what one decoded stream may ask for. EXI packs a lot into few bytes,
so a small hostile stream can otherwise make the decoder run out of memory,
spend minutes on one number, or overflow the stack. When a stream goes over a
cap, the decoder throws a [`LimitError`] and stops.

- `max_depth`: elements open at once. Stops endless self-nesting and very deep
  trees (which would also overflow the stack in `from_exi`).
- `max_list_items`: items in one list value. Stops a short stream that claims
  a list of billions of zero-size items.
- `max_integer_bits`: bits in one integer (also the parts of decimals, floats
  and years). Reading a huge integer takes time that grows fast with its size.
- `max_string_bytes`: total UTF-8 bytes of all string values in the stream.
  A string-table hit repeats a long string for a few bits, so this stops a
  small stream from growing into gigabytes of text.

`nothing` turns a cap off; [`unlimited_limits`] turns them all off. The
defaults are far above what normal documents need. Pass limits with the
`limits` keyword of `Decoder`, `decode_events`, `decode_to_xml` and
`from_exi`, or with the `--max-*` and `--no-limits` flags of the `jexi` tool:

```julia
limits = JExi.DecodeLimits(max_depth = 1000)
xml = JExi.decode_to_xml(bytes, tables; options, limits)
```
"""
Base.@kwdef struct DecodeLimits
    max_depth::Union{Nothing,Int} = 256
    max_list_items::Union{Nothing,Int} = 1_000_000
    max_integer_bits::Union{Nothing,Int} = 4096
    max_string_bytes::Union{Nothing,Int} = 256 * 1024 * 1024
end

"""
    unlimited_limits() -> DecodeLimits

Limits with every cap turned off. Use this only for input you trust.
"""
unlimited_limits() = DecodeLimits(nothing, nothing, nothing, nothing)

# A cap as a plain Int, with "no cap" as the largest Int, for fast checks.
limit_value(x::Union{Nothing,Int}) = x === nothing ? typemax(Int) : x

"""
    LimitError(limit, max)

The stream went over one of the [`DecodeLimits`]. `limit` is
`:depth`, `:list_items`, `:integer_bits` or `:string_bytes`, and `max` is the
cap that was set. Raise the cap (or turn it off) only if you trust the input.
"""
struct LimitError <: ExiError
    limit::Symbol
    max::Int
end

const LIMIT_NAMES = Dict(:depth => "nesting depth", :list_items => "list items",
    :integer_bits => "integer bits", :string_bytes => "string bytes")

Base.showerror(io::IO, e::LimitError) =
    print(io, "decoder limit exceeded: ", get(LIMIT_NAMES, e.limit, string(e.limit)), " is over ", e.max)
