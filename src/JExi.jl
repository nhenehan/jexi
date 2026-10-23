"""
    JExi

Native Julia implementation of W3C Efficient XML Interchange (EXI) 1.0, Second
Edition ([spec](https://www.w3.org/TR/exi/)), a compact binary form of XML. It
follows the design of rexi, the Rust implementation.

The setup it aims at first is: schema-informed (the grammars come from an XML
Schema, [EXI 8.5](https://www.w3.org/TR/exi/#informedGrammars)), strict (only
what the schema declares may appear), bit-packed (no padding between items),
with no `\$EXI` cookie, and with the options usually agreed outside the stream.
Anything else is either supported or refused with an `UnsupportedError`.
Nothing is quietly encoded in some "close enough" way.

One such refusal is restricted character sets
([EXI 7.1.10.1](https://www.w3.org/TR/exi/#restrictedCharSet)). When a string
type's `xs:pattern` allows only a small alphabet, EXI writes each character as
a short index into it, so a plain string would give bytes that other readers
decode to garbage, with no error. Values of such types (kind
`K_RESTRICTED_STRING`) are refused when they are written or read; the schema
still compiles, and documents that do not use the type work.

The decoder is safe to point at untrusted bytes: `DecodeLimits` caps the
nesting depth, list sizes, integer sizes and the total size of decoded strings,
and a stream that goes over a cap stops with a `LimitError`. The defaults suit
normal documents; pass `limits` to `Decoder`, `decode_events`,
`decode_to_xml` or `from_exi` to change them.
"""
module JExi

include("core/errors.jl")
include("core/limits.jl")
include("core/io.jl")
include("core/value.jl")
include("core/datatype/kinds.jl")
include("core/datatype/integers.jl")
include("core/datatype/simple.jl")
include("core/datatype/numbers.jl")
include("core/datatype/datetime.jl")
include("core/datatype/lexical.jl")
include("core/grammar/ir.jl")
include("core/string_table.jl")
include("core/options.jl")
include("core/event.jl")
include("core/grammar/runtime.jl")
include("core/grammar/options_grammar.jl")
include("core/encoder.jl")
include("core/decoder.jl")
include("core/header.jl")
include("core/reuse.jl")

include("xml/tree.jl")

include("schema/raw.jl")
include("schema/model.jl")
include("schema/builtin.jl")
include("schema/loader.jl")
include("schema/resolve.jl")
include("schema/proto.jl")
include("schema/charset.jl")
include("schema/emit.jl")
include("schema/schema.jl")
include("schema/dump.jl")

include("xml/stream.jl")
include("xml/reader.jl")
include("xml/writer.jl")

include("schemagen.jl")

include("structs/structs.jl")

include("cli.jl")
include("precompile.jl")

end # module JExi
