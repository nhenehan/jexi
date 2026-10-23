# Uses grammar tables that were turned into Julia code ahead of time, so the
# program never reads or compiles the XSD when it runs.
#
# `order_tables.jl` was written by `JExi.SchemaGen`. To write it again after the
# schema changes, run this from the jexi folder:
#
#     julia --project -e 'import JExi; JExi.SchemaGen.generate(
#         ["examples/basics/data/order.xsd"];
#         out = "examples/basics/order_tables.jl", module_name = "OrderTables")'
#
# The tables are a constant, so a package that includes them gets them
# precompiled, with no start-up work. The file also has a `QNameId` constant for
# every name, such as `LN_ORDER`, for `start_element!(enc, id)`.
#
# Rust version: rexi/examples/basics/src/bin/prebuilt_tables.rs.

import JExi
include("common.jl")
include("order_tables.jl")

# ANCHOR: main
xml = read(data("order.xml"), String)
options = JExi.strict_options()

# Timings vary from run to run, so they go to stderr; stdout stays the same on
# every run.
t = @elapsed compiled = JExi.compile_files(data("order.xsd"))
println(stderr, "compiling the XSD took ", round(t * 1e6; digits = 1), "µs")

prebuilt = OrderTables.GRAMMARS
a = JExi.encode_xml(xml, compiled; options)
b = JExi.encode_xml(xml, prebuilt; options)
println("EXI: ", length(b), " bytes")
println("same bytes with compiled and prebuilt tables: ", a == b)

back = JExi.decode_to_xml(b, prebuilt; options)
first_tag = first(split(back, '>'))
println("decoded with prebuilt tables: ", first_tag, ">...")
# ANCHOR_END: main
