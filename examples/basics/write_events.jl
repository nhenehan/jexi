# Builds the order document event by event, with no XML text at all.
#
# This is the lowest-level way to write EXI. Each call is one EXI event: start
# element (SE), attribute (AT), characters (CH), end element (EE)
# (EXI 4, https://www.w3.org/TR/exi/#eventTypes). The encoder checks every call
# against the schema and throws if it is not allowed at that point.
#
# Rust version: rexi/examples/basics/src/bin/write_events.rs.

import JExi
include("common.jl")

# ANCHOR: main
const NS = "urn:rexi:interop:order"

"""Writes `<name>value</name>` in the order namespace."""
function text_element!(enc, name, value)
    JExi.start_element!(enc, NS, name)
    JExi.characters!(enc, value)
    JExi.end_element!(enc)
end

tables = JExi.compile_files(data("order.xsd"))
enc = JExi.Encoder(tables, JExi.strict_options())

JExi.start_document!(enc)
JExi.start_element!(enc, NS, "Order")
# The schema puts attributes in no namespace, so their URI is "". Strict EXI
# wants attributes sorted by name, which is also the order here.
JExi.attribute!(enc, "", "orderId", "ORD-2026-0007")
# A typed value goes in as it is, with no text to parse.
JExi.attribute!(enc, "", "priority", true)

JExi.start_element!(enc, NS, "Customer")
JExi.attribute!(enc, "", "loyaltyId", "L-8821")
text_element!(enc, "Name", "Raven Bookstore")
text_element!(enc, "Tier", "gold")
JExi.end_element!(enc)

items = [
    ("BK-001", "Distributed Systems Patterns", 2, "42.95"),
    ("BK-014", "Practical EXI", 1, "31.50"),
]
for (sku, description, quantity, price) in items
    JExi.start_element!(enc, NS, "Item")
    JExi.attribute!(enc, "", "sku", sku)
    text_element!(enc, "Description", description)
    text_element!(enc, "Quantity", quantity)
    # `Lexical` is text that the encoder parses with the schema's type, here
    # xs:decimal, just as if it came from an XML file.
    text_element!(enc, "Price", JExi.Lexical(price))
    JExi.end_element!(enc)
end

text_element!(enc, "Notes", "gift-wrap requested")
JExi.end_element!(enc)
JExi.end_document!(enc)
exi = JExi.finish!(enc)

# The same document, encoded from the XML file, gives the same bytes.
from_xml = JExi.encode_xml(read(data("order.xml"), String), tables)
println("EXI: ", length(exi), " bytes")
println("same bytes as encoding order.xml: ", exi == from_xml)
# ANCHOR_END: main
