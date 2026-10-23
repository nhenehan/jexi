# Encodes an XML file to EXI with the help of its XML Schema, then decodes it back.
#
# Both ends build the same grammars from the schema. Because of that, the stream
# can leave out names and types that both sides already know
# (EXI 8.5, https://www.w3.org/TR/exi/#informedGrammars).
#
# Rust version: rexi/examples/basics/src/bin/roundtrip.rs.

import JExi
include("common.jl")

# ANCHOR: main
# Turn the schema into grammar tables. This is the slow step, so do it once and
# reuse the tables for every document.
tables = JExi.compile_files(data("order.xsd"))

xml = read(data("order.xml"), String)
# Strict and bit-packed, with the options agreed outside the stream: the smallest
# output, with a header of a single byte.
options = JExi.strict_options()
exi = JExi.encode_xml(xml, tables; options)

println("XML: ", sizeof(xml), " bytes")
println("EXI: ", length(exi), " bytes")
print(hex_lines(exi))

# The stream does not say which options it used, so the decoder is told.
# Values come back in their standard text form, so "31.50" turns into "31.5".
back = JExi.decode_to_xml(exi, tables; options)
println("decoded XML:")
println(back)
# ANCHOR_END: main
