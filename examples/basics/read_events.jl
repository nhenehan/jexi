# Reads an EXI stream one event at a time with the pull decoder, and prints each
# event with the type of its value.
#
# The decoder gives typed values (a Bool, an integer, a decimal), not just text,
# because the schema says what type each value has
# (EXI 7, https://www.w3.org/TR/exi/#encodingDatatypes).
#
# Rust version: rexi/examples/basics/src/bin/read_events.rs.

import JExi
include("common.jl")

# ANCHOR: main
"""The value as text, followed by the kind of value the decoder gave."""
function describe(value)
    kind = value isa AbstractString ? "string" :
           value isa Bool ? "boolean" :
           value isa Integer ? "integer" :
           value isa JExi.ExiDecimal ? "decimal" : "other"
    return "$(JExi.plain_format(value)) ($kind)"
end

tables = JExi.compile_files(data("order.xsd"))
exi = JExi.encode_xml(read(data("order.xml"), String), tables)

dec = JExi.Decoder(exi, tables; options = JExi.strict_options())
depth = 0
# A decoder is also an iterator: the loop ends after the end of the document.
for event in dec
    indent = "  "^depth
    if event isa JExi.StartDocument
        println("start document")
    elseif event isa JExi.EndDocument
        println("end document")
    elseif event isa JExi.StartElement
        println(indent, event.local_name)
        global depth += 1
    elseif event isa JExi.EndElement
        global depth -= 1
    elseif event isa JExi.Attribute
        println(indent, "@", event.local_name, " = ", describe(event.value))
    elseif event isa JExi.Characters
        println(indent, describe(event.value))
    else
        println(indent, JExi.event_name(event))
    end
end
# ANCHOR_END: main
