# JExi

JExi is a Julia library for EXI (Efficient XML Interchange), the W3C format
that sends XML as small, fast binary. You give it your XML Schema. Both ends use
the schema to agree on the format, so the messages can leave out names and
types. JExi is a port of [rexi](https://github.com/nhenehan/rexi), the Rust
version, and makes the same bytes.

Supported profile of EXI 1.0 (Second Edition): **schema-informed, strict, bit-packed or byte-aligned,
with or without the `$EXI` cookie, options in the header or out of band** (with
no cookie and the options out of band, the header is one byte).

## Quick example

With [`order.xsd`](examples/basics/data/order.xsd) and
[`order.xml`](examples/basics/data/order.xml) from `examples/basics/data` in the
current folder:

```julia
import JExi

# Turn the schema into tables once, then reuse them for every message.
tables = JExi.compile_files("order.xsd")
xml = read("order.xml", String)

options = JExi.strict_options()
exi = JExi.encode_xml(xml, tables; options)       # XML to EXI
back = JExi.decode_to_xml(exi, tables; options)   # and back again

println(sizeof(xml), " bytes of XML became ", length(exi), " bytes of EXI")
println(back)
```

It prints `538 bytes of XML became 129 bytes of EXI`, then the XML.

## Add to your project

JExi is not in the Julia registry yet. Add it from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/nhenehan/jexi", rev = "v0.2.0")
```

To work on JExi itself, use a local copy instead:
`Pkg.develop(path = "path/to/jexi")`.

JExi needs Julia 1.10 or newer. It has no exports, so every name is written
`JExi.name`.

## Learn more

- **The user guide**, in [`guide/`](guide/src/introduction.md), walks through
  the examples one at a time, from a first round trip to prebuilt tables. To
  read it in a browser, install [mdbook](https://rust-lang.github.io/mdBook/)
  and mdbook-mermaid, then run
  `mdbook-mermaid install guide && mdbook serve guide`.
- **The examples**, in [`examples/basics`](examples/basics/README.md), are
  small scripts, one idea each. Each has a Rust twin in rexi that prints the
  same output.
- **The command line**, [`bin/jexi`](bin/jexi), encodes and decodes files and
  lists a schema's grammars. `bin/jexi --help` lists every command.

## What it does

- Turns XML Schemas (with `xs:include`, `xs:import`, groups, derived types,
  substitution groups and `xs:all`) into grammar tables.
- Encodes and decodes XML text, one event at a time, or your own Julia
  structs (`to_exi` / `from_exi`).
- Writes the tables as a Julia module ahead of time (`JExi.SchemaGen`), so
  they precompile into your package.
- Writes the same bytes as EXIficient, the reference Java library, for every
  interop test case in the strict profiles.
- Refuses anything it does not support with an `UnsupportedError`. It never
  quietly writes something close enough.

## What it doesn't do yet

- **Compression and pre-compression.** They regroup the values and add
  DEFLATE, a large separate piece of work.
- **Schema-less streams.** JExi needs your schema; the built-in grammars for
  streams without one are not written yet.
- **Non-strict mode.** Documents that stray from the schema need extra grammar
  rules everywhere, which JExi does not build.
- **Preserve options.** Strict mode drops comments, processing instructions,
  DTDs and prefixes by design; keeping lexical values is not done yet.
- **Wildcards** (`xs:any`, `xs:anyAttribute`). The stream must then carry the
  name of the element or attribute, and that path is not built yet. Documents
  that don't use the wildcard work.
- **Unreadable patterns on restricted strings.** When an `xs:pattern` cannot
  be parsed, the alphabet of its restricted character set is unknown, and its
  values are refused (more below).
- **Fragments.** JExi encodes whole documents with one root element.
- **selfContained.** The EXI spec does not allow it together with strict.
- **datatypeRepresentationMap.** It swaps in other encodings for datatypes; it
  is rarely used, and every reader would need the same map.

The schema still compiles when it uses a wildcard or an unreadable pattern.
The refusal happens only when a document uses that part, so a large schema
with one such spot still works.

Restricted character sets ([EXI 7.1.10.1](https://www.w3.org/TR/exi/#restrictedCharSet))
are supported. One comes from a string type whose `xs:pattern` allows fewer
than 256 characters, all in the BMP, such as `[A-Z]{2}[0-9]{4}`; each
character is then written as an n-bit index into that alphabet, in code point
order, and a character outside it as an escape and its code point. The bytes
equal EXIficient 1.0.7's, bit-packed and byte-aligned, except for a character
outside the BMP: EXIficient counts it as two UTF-16 units and writes its low
surrogate as a second character, where the spec counts one character. Patterns
with a large alphabet (`\d+`, `\p{L}+`, `.*`, `[^x]`, anything outside the
BMP) are not restricted and stay plain strings.

## Safe with untrusted data

EXI is compact, so a few bytes can ask for a huge amount of work. The decoder
has four limits, on by default, and stops with a `LimitError` when a stream
goes past one. Schemas have rules too: `xs:include` and `xs:import` read only
regular local files under the main schema's folder, and a schema's grammars
may only grow so large. The guide chapter
[Untrusted input](guide/src/untrusted-input.md) explains each one and how to
change it.

## Thanks

EXI is a W3C Recommendation, and it is a really good one: a careful design,
written up clearly, with solid open libraries behind it. That work is what got
this project started. rexi and JExi are my effort to take EXI further, to more
languages and more places.

- **Rumen Kyusakov** wrote [exip](https://exip.sourceforge.net/), a compact C
  implementation of EXI, and co-edited the Second Edition of the
  [EXI specification](https://www.w3.org/TR/exi/). exip's decoder is one of the
  checks JExi's output must pass.
- **Daniel Peintner** wrote [EXIficient](https://exificient.github.io/) with
  Richard Kuntschke at Siemens, co-edited the Second Edition, and edited the
  [EXI Primer](https://www.w3.org/TR/exi-primer/). JExi's bytes are checked
  against EXIficient's.
- **Takuki Kamiya** edited the First Edition, chaired the EXI Working Group,
  and wrote Nagasena ([OpenEXI](https://sourceforge.net/projects/openexi/)).
  **John Schneider** also edited the First Edition, and **Santiago
  Pericas-Geertsen** co-edited the Primer and wrote the W3C test framework.
- The **W3C EXI Working Group** as a whole made the specification that JExi
  follows closely.

Thank you.

## License

BSD-3-Clause, see [LICENSE](LICENSE).

## For maintainers

**Status.** 0.2.0, the same scope as rexi 0.2. The interop
fixtures (EXIficient 1.0.7 reference bytes) encode bit for bit in the strict
bit-packed, bit-packed with options, and byte-aligned profiles, decode to the
oracle's event stream, re-encode from decoded events, and are accepted by
exipd. The schema compiler makes the same tables as rexi's for every fixture
schema, and its EXIficient-format grammar dump equals the oracle's. In the
rexi-interop matrix JExi matches rexi in every strict cell. Wildcards are refused
with `UnsupportedError(FEATURE_WILDCARD)`, restricted strings whose pattern
does not parse with `UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET)`.

**Layout.** One package with the layers of rexi's crates:

| Part | Files | rexi crate |
|---|---|---|
| Codec core: bit I/O, datatypes, string tables, grammar tables and runtime, `Encoder` / `Decoder`, header and options document | `src/core/` | `rexi-core` |
| XSD compiler: loader, resolver, proto-grammars, normalization, emit; EXIficient-format grammar dump | `src/schema/` | `rexi-schema` |
| Static tables written as a Julia module (`JExi.SchemaGen`) | `src/schemagen.jl` | `rexi-schema-gen` |
| XML front end over XML.jl: namespace-aware tree, reader, writer, `.events` dump | `src/xml/` | `rexi-xml` |
| Struct mapping: `to_exi` / `from_exi`; the rules (attributes vs elements, `Vector` for repeats, `Union{Nothing,T}` for optional, `@enum`, choices and xsi:type, `$text`) are in the docstring at the top of `src/structs/structs.jl` | `src/structs/` | `rexi-serde` |
| Command line (`bin/jexi`, `JExi.CLI`) | `src/cli.jl` | `rexi` binary |

Grammar tables (`GrammarSet`) are flat vectors of plain bits structs indexed by
0-based ids, like rexi's, so a table written by `SchemaGen` is a constant that
precompiles into the package that includes it.

**Commands.**

```bash
scripts/fetch-third-party.sh --build   # exip (exipd, EXIficient oracle) and rexi, pinned
scripts/sync-fixtures.sh [--check]     # fixtures and rexi's grammar listings, from the pinned rexi
scripts/gen-tables.sh [--check]        # static tables in test/generated
scripts/gate.sh [--quick]              # everything a commit must pass
bin/jexi encode --xsd a.xsd in.xml out.exi
bin/jexi decode --xsd a.xsd [--max-depth N ... | --no-limits] out.exi
bin/jexi dump-grammar --xsd a.xsd[,b.xsd]
bin/jexi bench encode|decode --xsd a.xsd [--warmup N --iterations N] in
```

`bin/jexi` takes rexi's command line (`rexi --help` and `bin/jexi --help` list
the same commands and flags) and prints the same `bench` JSON, which is how the
rexi-interop harness drives both. Speed notes are in
[`doc/performance.md`](doc/performance.md).

**Julia versions.** 1.10 (LTS) and newer. The gate runs the tests, with Aqua
and JET, on 1.10 and on the current release (juliaup channels `release` and
`1.12` by default), then checks the generated tables and the fixtures. The full
gate needs the judges (exipd, exip's test data); `--quick` runs only the
current Julia.

**Reference fixtures.** `test/fixtures/interop` is a copy of rexi's
`crates/rexi-tests/fixtures/interop` at the commit pinned in
`third-party.lock`: EXIficient 1.0.7 bytes, decoded event streams and grammar
dumps, with their sha256 in `manifest.tsv`. `test/fixtures/listings` holds
`rexi dump-grammar` for each case, which `JExi.grammar_listing` must reproduce
exactly.

**Third parties.** Nothing third-party lives in the working tree.
`scripts/fetch-third-party.sh` checks out the commits pinned in
`third-party.lock` (exip for the exipd judge and the EXIficient oracle, rexi
for the fixtures and its CLI) into
`${JEXI_THIRD_PARTY:-${XDG_CACHE_HOME:-~/.cache}/jexi/third_party}`. Julia
dependencies: XML.jl and PrecompileTools; tests also use Aqua and JET.
