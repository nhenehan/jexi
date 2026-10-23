# Performance (0.1)

Measured in October 2026 on an AMD Ryzen 7 7840U, Linux 7.1.5, Julia 1.12.7,
with the rexi-interop harness. Each library times itself in-process: 2000
warm-up runs, then 2000 timed runs. The tables give the median in µs. Schema
compilation is not included. rexi is a release build with rustc 1.99.
EXIficient 1.0.7 runs in-process on Java 25.

**Longer warm-up.** Java and Julia compile code while they run, so 2000 warm-up
runs were not always enough. With at least 3 s of warm-up per cell,
EXIficient decodes faster. jexi then ties it on P0 S3 (0.7), P0 R5 (1.6) and
P2 U1 (6.2), and is faster everywhere else. Encoding from XML stays faster
than EXIficient on every case. The smallest margin is U1: 24.6 against 28.3 in
P0, and 22.8 against 27.8 in P2. jexi's own numbers stay within noise of the
tables below, except a few cells with wide spreads from garbage-collector
pauses.

## Decoding (median µs)

| case | P0 EXIficient | P0 rexi | P0 jexi | P2 EXIficient | P2 rexi | P2 jexi |
|---|---|---|---|---|---|---|
| S1 order | 29.1 | 1.7 | 0.9 | 2.1 | 1.6 | 0.8 |
| S2 telemetry | 5.6 | 1.6 | 0.9 | 2.2 | 1.5 | 0.8 |
| S3 inheritance | 2.2 | 1.1 | 0.6 | 0.8 | 1.1 | 0.5 |
| S4 cross-schema | 1.3 | 1.3 | 0.6 | 1.4 | 1.3 | 0.5 |
| S5 polymorphic | 1.1 | 1.7 | 0.8 | 1.9 | 1.5 | 0.7 |
| R1 | 2.7 | 2.5 | 1.3 | 2.0 | 2.4 | 1.2 |
| R2 | 2.6 | 3.0 | 1.9 | 4.0 | 2.9 | 1.8 |
| R3 | 1.3 | 1.8 | 1.1 | 1.4 | 1.8 | 0.9 |
| R4 | 1.0 | 1.5 | 0.7 | 1.1 | 1.5 | 0.7 |
| R5 | 1.7 | 2.5 | 1.5 | 1.8 | 2.2 | 1.4 |
| X1 xsi:type | 4.5 | 2.0 | 1.2 | 1.9 | 1.9 | 1.1 |
| X2 xsi:nil | 1.6 | 1.9 | 1.2 | 1.6 | 1.9 | 1.1 |
| U1 multilingual | 69.5 | 9.1 | 6.1 | 6.2 | 8.5 | 5.8 |
| B1 binary | 0.7 | 0.9 | 0.5 | 1.1 | 0.8 | 0.5 |

EXIficient's P0 S1 and U1 decode medians (29.1, 69.5) are outliers in this
run, with wide spreads (p10 4.0 and 7.7). Another run gave 4.4 and 8.7.

jexi's median is below EXIficient's and rexi's in every cell. There are two
caveats. First, the margin over EXIficient is small on U1 in P2 (5.8 against
6.2), and EXIficient's U1 varies by about ±1 µs between runs. Second, jexi's
p90 is higher than EXIficient's because of garbage-collector pauses, so the win
is on medians.

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

| case | P0 EXIficient | P0 rexi | P0 jexi | P2 EXIficient | P2 rexi | P2 jexi |
|---|---|---|---|---|---|---|
| S1 order | 36.0 | 6.6 | 4.9 | 14.6 | 6.2 | 4.9 |
| S2 telemetry | 32.0 | 6.1 | 5.3 | 13.1 | 5.7 | 5.0 |
| S3 inheritance | 10.8 | 3.6 | 3.0 | 11.0 | 3.5 | 3.1 |
| S4 cross-schema | 11.8 | 4.4 | 3.5 | 12.1 | 4.3 | 3.5 |
| S5 polymorphic | 12.4 | 5.5 | 4.3 | 12.3 | 5.4 | 4.0 |
| R1 | 14.6 | 8.7 | 6.7 | 15.0 | 8.5 | 7.0 |
| R2 | 20.5 | 13.6 | 10.0 | 17.4 | 12.4 | 9.6 |
| R3 | 12.3 | 5.5 | 4.5 | 12.4 | 5.1 | 4.1 |
| R4 | 13.1 | 5.7 | 4.3 | 13.2 | 5.4 | 4.5 |
| R5 | 15.3 | 8.7 | 6.6 | 14.7 | 8.5 | 6.8 |
| X1 xsi:type | 16.7 | 8.7 | 7.7 | 17.5 | 8.4 | 7.6 |
| X2 xsi:nil | 15.9 | 9.1 | 7.9 | 15.7 | 9.0 | 7.4 |
| U1 multilingual | 28.3 | 24.3 | 20.2 | 26.9 | 24.1 | 21.3 |
| B1 binary | 10.7 | 3.3 | 3.1 | 10.6 | 3.3 | 3.2 |

jexi's median is below EXIficient's and rexi's in every cell. The smallest
margin over EXIficient is U1: 20.2 against 28.3 in P0, and 21.3 against 26.9
in P2. Encoding from events (no XML parsing) takes 1.7–6.1 µs (15 on U1),
which is 1.0–1.8× rexi's time.

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
