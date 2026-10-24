# Changelog

## Unreleased

- Restricted character sets
  ([EXI 7.1.10.1](https://www.w3.org/TR/exi/#restrictedCharSet)) are encoded
  and decoded instead of refused. The alphabet a string type's patterns allow
  is kept in the grammar tables (the kind's `set` is its `StrIdx`), and each
  character of a string-table miss is written as an n-bit index into it, or
  as the escape index and the code point. The bytes equal EXIficient 1.0.7's,
  bit-packed and byte-aligned, on new test vectors (an ISO 3779 VIN pattern,
  escaped characters, non-ASCII alphabets, the empty alphabet, string-table
  hits, list items, `xs:token`, and two alphabets in one document). A
  character outside the BMP is one escaped code point, as the spec says;
  EXIficient writes it as two (see the README).
- A restricted string whose pattern does not parse still has no alphabet, and
  its values are still refused with
  `UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET)`.
- `restricted_string_kind(ws, alphabet)` takes the alphabet's `StrIdx`, and
  `SchemaGen` writes it. Tables generated before this change hold restricted
  kinds with no alphabet, which behave as before (refused); regenerate them.

## 0.1.0

First release. JExi encodes and decodes schema-informed, strict EXI 1.0 in
native Julia. It is a port of [rexi](https://github.com/nhenehan/rexi) and
writes the same bytes as rexi and as EXIficient 1.0.7 on the interop test
cases. Anything outside the supported profile is refused with an
`UnsupportedError` (the list is in the README).

### Codec and supported EXI profile

- Strict, schema-informed EXI 1.0 (Second Edition), bit-packed or
  byte-aligned, with or without the `$EXI` cookie, with the options in the
  header or out of band.
- Every datatype of the strict profile, string tables, grammar tables, the EXI
  header and the options document.
- An `Encoder` (push) and a `Decoder` (pull) that work one event at a time.
  Plain text passed to `attribute!` or `characters!` for a typed datatype is
  parsed like XML text.
- `reset!(dec, bytes)` and `reset!(enc)` reuse a codec for the next document.
  A reset codec writes and reads the same bits as a new one, with about half
  the allocations. `reset!` itself allocates nothing.
- `event_qname_id(dec)` gives the current name as a `QNameId`, with no string
  lookup.
- XML front end over XML.jl: `encode_xml`, `decode_events`, `decode_to_xml`,
  `write_xml` and the `.events` text format. Encoding from XML streams
  through the tokenizer and builds no tree.

### Schemas

- An XSD compiler that handles `xs:include`, `xs:import`, groups, derived
  types, substitution groups and `xs:all`. Its tables equal rexi's for every
  test schema, and its EXIficient-format grammar dump equals EXIficient's.
- Include and import rules: `xs:include` and `xs:import` read only regular
  local files under the main schema's folder, at most 16 MiB each, and never
  a URL. Set the root with `load_options = SchemaLoadOptions(; root)` on
  `compile_files` and `compile_string`, or `--schema-root DIR` on the command
  line. A file outside the rules is refused with a `SchemaError` before it is
  opened.
- Size limits: a group that refers to itself is an invalid-schema error, and
  one type's content may expand to at most 100,000 grammar rules
  (`SchemaLoadOptions(; max_grammar_size)`). Past that, a `SchemaError` says
  "schema too large".
- Pattern refusal: a string type whose `xs:pattern` allows only a small
  alphabet is a restricted character set
  ([EXI 7.1.10.1](https://www.w3.org/TR/exi/#restrictedCharSet)). Its values
  are refused with `UnsupportedError(FEATURE_RESTRICTED_CHARACTER_SET)`.
  Wildcards (`xs:any`, `xs:anyAttribute`) are refused with
  `UnsupportedError(FEATURE_WILDCARD)`. In both cases the schema still
  compiles, and only a document that uses that part is refused.

### Safety: decoder limits

- `DecodeLimits`, on by default: depth 256, 1,000,000 list items, 4096-bit
  integers and 256 MiB strings. A stream past a limit stops with a
  `LimitError`. `unlimited_limits()` turns them off.
- A `limits` keyword on `Decoder`, `decode_events`, `decode_to_xml` and
  `from_exi`.
- Big integers and mixed-content text are read in linear time.

### Structs and SchemaGen

- `to_exi` and `from_exi` map your own Julia structs to EXI, with the same
  rules as rexi's serde mapping: attributes or elements, `Vector` for repeats,
  `Union{Nothing,T}` for optional parts, `@enum`, choices and `xsi:type`.
- `Float32` and `Float16` fields are written as the shortest text at their own
  width.
- `JExi.SchemaGen` writes grammar tables as a Julia module, so they
  precompile into the package that includes them.

### Command line

- `bin/jexi` takes the same commands and flags as rexi's command line:
  `encode`, `decode`, `dump-events`, `dump-grammar` and `bench`.
- `--max-depth`, `--max-list-items`, `--max-integer-bits`,
  `--max-string-bytes` and `--no-limits` on `decode`, `dump-events` and
  `bench decode`.

### Docs and examples

- A user guide in `guide/` (mdbook) that walks through the examples one at a
  time, with a chapter on untrusted input.
- Small examples in `examples/basics`, one idea each. Each has a Rust twin in
  rexi that prints the same output.
- Speed and allocation numbers in `doc/performance.md`.
