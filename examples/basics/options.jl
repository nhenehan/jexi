# Encodes the same document with different EXI options and header settings, and
# shows how the size and the first bytes change.
#
# The header (EXI 5, https://www.w3.org/TR/exi/#header) can hold the `$EXI`
# cookie and an options document. Without them, both sides must agree on the
# options some other way ("out of band"). The options are listed in EXI 5.4,
# https://www.w3.org/TR/exi/#options.
#
# Rust version: rexi/examples/basics/src/bin/options.rs.

import JExi
include("common.jl")

# ANCHOR: main
# Named, so a decoder can check a stream's schemaId against it.
tables = JExi.with_schema_id(JExi.compile_files(data("order.xsd")), "urn:rexi:interop:order")
xml = read(data("order.xml"), String)

plain = JExi.HeaderConfig()
with_options = JExi.HeaderConfig(; include_options = true)
with_cookie = JExi.HeaderConfig(; cookie = true, include_options = true)
cases = [
    ("bit-packed", JExi.strict_options(), plain),
    # Every event code and value starts on a new byte: bigger, but easier to
    # read in a hex dump.
    ("byte-aligned", JExi.strict_options(; alignment = JExi.ALIGN_BYTE_ALIGNED), plain),
    ("options in header", JExi.strict_options(), with_options),
    ("cookie + options + schemaId", JExi.strict_options(; schema_id = "urn:rexi:interop:order"), with_cookie),
]

streams = map(cases) do (label, options, header)
    exi = JExi.encode_xml(xml, tables; options, header)
    println(rpad(label, 28), " ", lpad(length(exi), 4), " bytes  starts ", hex_start(exi, 8))
    (exi, options, header)
end

# A stream that carries its options can be decoded without being told them. The
# others need them passed in.
decoded = map(streams) do (exi, options, header)
    JExi.decode_to_xml(exi, tables; options = header.include_options ? nothing : options)
end
println("all four decode to the same XML: ", all(==(decoded[1]), decoded))

# Options this library does not support are refused, never guessed at.
for (label, options) in [("compression", JExi.strict_options(; compression = true)),
                         ("non-strict", JExi.ExiOptions())]
    try
        JExi.validate_options(options)
        println(label, ": accepted")
    catch e
        e isa JExi.UnsupportedError || rethrow()
        println(label, ": refused as unsupported")
    end
end
# ANCHOR_END: main
