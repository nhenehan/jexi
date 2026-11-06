# Performance (0.1)

Measured on 2026-11-05 on an AMD Ryzen 7 7840U, Linux 7.2.6, Julia 1.12.7,
with the rexi-interop harness: jexi e336de8, and rexi b2ab2a8 as a release
build with rustc 1.99. Each library times itself in-process: a warm-up of at
least 2000 runs and 3 s, then 2000 timed runs. The tables give the median in
µs. Schema compilation is not included. The harness's `reports/latest.md` has
the same runs with p10–p90.

## Decoding (median µs)

| case | P0 rexi | P0 jexi | P2 rexi | P2 jexi |
|---|---|---|---|---|
| S1 order | 0.8 | 0.9 | 0.8 | 0.9 |
| S2 telemetry | 0.8 | 0.8 | 0.8 | 0.8 |
| S3 inheritance | 0.5 | 0.6 | 0.5 | 0.5 |
| S4 cross-schema | 0.6 | 0.6 | 0.6 | 0.5 |
| S5 polymorphic | 0.7 | 0.8 | 0.7 | 0.7 |
| R1 | 1.2 | 1.3 | 1.2 | 1.2 |
| R2 | 1.6 | 1.8 | 1.5 | 1.7 |
| R3 | 0.9 | 1.0 | 0.8 | 0.9 |
| R4 | 0.7 | 0.8 | 0.7 | 0.7 |
| R5 | 1.1 | 1.4 | 1.0 | 1.3 |
| X1 xsi:type | 1.2 | 1.2 | 1.1 | 1.1 |
| X2 xsi:nil | 1.1 | 1.1 | 1.1 | 1.1 |
| U1 multilingual | 4.4 | 5.9 | 4.0 | 5.4 |
| B1 binary | 0.4 | 0.5 | 0.4 | 0.5 |

rexi's median is at or below jexi's in every cell but P2 S4. jexi's p90 is
higher than its median by more than rexi's is, because of garbage-collector
pauses.

These changes made the decoder about 2.3× faster than the first working
version:

- The string table's starting layout and the decoder's flat tables are worked
  out once per `GrammarSet`. Stream setup went from 0.33 to 0.08 µs, and from
  16 to 8 allocations.
- Strings are decoded straight into a scratch buffer that only grows (one
  allocation per new value).
- The bit reader reads whole octets directly.
- The value table hashes a new value once, and hashes a `QNameId` by its two
  numbers instead of by `objectid`.

These ideas were tried and dropped because they measured slower: hashes
stored in value entries, presized vectors, a larger scan limit, and flat
(context, local id) maps.

## Encoding from XML (median µs, parsing included)

| case | P0 rexi | P0 jexi | P2 rexi | P2 jexi |
|---|---|---|---|---|
| S1 order | 3.2 | 4.8 | 3.1 | 5.1 |
| S2 telemetry | 3.1 | 5.2 | 3.0 | 5.2 |
| S3 inheritance | 1.9 | 2.9 | 1.7 | 3.2 |
| S4 cross-schema | 2.4 | 3.3 | 2.4 | 3.4 |
| S5 polymorphic | 2.7 | 4.2 | 2.8 | 4.2 |
| R1 | 4.7 | 6.5 | 4.2 | 7.2 |
| R2 | 6.6 | 9.1 | 6.1 | 9.4 |
| R3 | 3.4 | 4.0 | 2.7 | 3.9 |
| R4 | 3.4 | 4.4 | 2.7 | 4.2 |
| R5 | 4.5 | 6.5 | 4.2 | 6.4 |
| X1 xsi:type | 4.7 | 7.2 | 4.6 | 7.6 |
| X2 xsi:nil | 4.6 | 7.7 | 4.7 | 7.8 |
| U1 multilingual | 14.9 | 21.1 | 14.5 | 19.7 |
| B1 binary | 1.7 | 3.2 | 1.7 | 3.1 |

jexi takes 1.2–1.9× rexi's time. Encoding from events (no XML parsing) takes
1.6–5.9 µs (14.3–14.5 on U1), which is 1.2–2.1× rexi's time.

These changes made encoding from XML about 2× faster than the first working
version: from 178.5 to about 90 µs summed over the 14 cases, and from 37 to
20 µs on U1.

- **No tree.** `src/xml/stream.jl` walks XML.jl's tokenizer and hands each
  element's events straight to the encoder. Before, a document became an XML.jl
  node tree, then an `XElement` tree, then a list of events. On U1 the tokenizer
  alone takes 5.5 µs, against 19 µs for the tree route to events.
- **Cached name lookups.** Element and attribute names go through a
  `(uri, local)` map kept in `RuntimeTables`. Before, they took a URI scan and
  a binary search by string compare. Productions and code widths come from the same flat
  tables the decoder uses.
- **Text.** Text waiting to be written sits in a byte buffer that only grows,
  not an `IOBuffer`. Whitespace-only text is checked on the bytes, so dropped
  whitespace makes no `String`.
- **Characters.** `write_code_points!` reads code points from the UTF-8 bytes
  and writes up to eight octets at once.
- **Value table.** A new value is hashed once (`get!`), as in the decoder, and
  the context's list is looked up once.

## Allocations

`test/performance.jl` holds the budgets (each with some headroom):

| what | allocations | budget |
|---|---|---|
| `find_qname`, `rule_productions` on static tables | 0 | 0 |
| `Encoder(tables, options)` | 11 | 16 |
| `Decoder(bytes, tables)` | 8 | 10 |
| decoding order-complex (42 events) | 23 | 30 |
| encoding order-complex from events | 35 | 45 |
| `reset!(decoder, bytes)`, `reset!(encoder)` | 0 | 0 |
| decoding order-complex with a reset decoder | 11 | 14 |
| encoding order-complex with a reset encoder | 17 | 21 |

For many small documents, keep one `Decoder` and one `Encoder`, and `reset!`
them for each document instead of building new ones. A reset codec reads and
writes the same bits as a new one, with about half the allocations.

Strings added to the value table during a stream are stored once each; a value
hit returns the stored `String` without allocating.

## Type stability

JET's `report_opt` finds no runtime dispatch in the decode loop
(`next!` over the body). The test gate checks this on Julia 1.10 and 1.12. The
encoder has runtime dispatch in only two places: the enumeration lookup, which
compares values in their text form (as rexi does), and the options-document
reader.

## Start-up

A PrecompileTools workload (`src/precompile.jl`) compiles a small schema and
encodes and decodes a document in each profile at precompile time. A cold
`bin/jexi encode` takes about 0.75 s (13 s without the workload). Compiling a
test schema takes about 0.1 s.
