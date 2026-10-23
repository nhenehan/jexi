# JExi basics

Small scripts, one idea each, in the order the [user guide](../../guide/src/introduction.md)
uses. Each one has a Rust twin in `rexi/examples/basics` that prints exactly the
same output, so you can compare the two side by side.

| # | Julia | Rust | Shows |
|---|---|---|---|
| 1 | [`roundtrip.jl`](roundtrip.jl) | `roundtrip.rs` | XML to EXI and back |
| 2 | [`options.jl`](options.jl) | `options.rs` | Alignment, cookie, options in the header |
| 3 | [`read_events.jl`](read_events.jl) | `read_events.rs` | The pull decoder and typed values |
| 4 | [`write_events.jl`](write_events.jl) | `write_events.rs` | Writing a document event by event |
| 5 | [`structs.jl`](structs.jl) | `structs.rs` | Your own types to EXI and back |
| 6 | [`prebuilt_tables.jl`](prebuilt_tables.jl) | `prebuilt_tables.rs` | Tables built ahead of time |

All of them use [`data/order.xml`](data/order.xml) and [`data/order.xsd`](data/order.xsd).
From the jexi folder:

```bash
julia --project=examples/basics -e 'using Pkg; Pkg.develop(path=".")'   # once
julia --project=examples/basics examples/basics/roundtrip.jl         # one example
julia --project=examples/basics examples/basics/run-all.jl           # all of them
```

`order_tables.jl` is made by `JExi.SchemaGen`; see `prebuilt_tables.jl` to make
it again. rexi's `examples/basics/compare.sh` runs each pair and diffs the output.
