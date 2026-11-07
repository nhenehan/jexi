# Getting started

In this chapter you'll add JExi to a project and run the examples.

## Add JExi to your project

JExi is not in the Julia registry yet, so add it from GitHub. It needs
Julia 1.10 or newer.

```julia
using Pkg
Pkg.add(url = "https://github.com/nhenehan/jexi", rev = "v0.2.0")
```

To work on JExi itself, use a local copy instead:
`Pkg.develop(path = "path/to/jexi")`.

Then:

```julia
import JExi
```

JExi has no exports. You write every name as `JExi.name`, so it is always clear
where a name comes from.

## Run the examples

The examples live in `examples/basics`, with their own `Project.toml`. From the
jexi folder:

```bash
julia --project=examples/basics -e 'using Pkg; Pkg.develop(path=".")'   # once
julia --project=examples/basics examples/basics/roundtrip.jl
julia --project=examples/basics examples/basics/run-all.jl          # every example
```

## The sample order

Every example uses the same two files in `examples/basics/data`. The
[schema](glossary.md#schema) says an `Order` has an `orderId`, a `Customer`,
one or more `Item`s and maybe some `Notes`:

```xml
{{#include ../../examples/basics/data/order.xml}}
```

<details>
<summary>The schema, <code>order.xsd</code></summary>

```xml
{{#include ../../examples/basics/data/order.xsd}}
```

</details>
