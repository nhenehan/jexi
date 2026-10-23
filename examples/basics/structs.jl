# Maps plain Julia structs to EXI and back, guided by the schema.
#
# Fields become attributes or child elements, depending on what the schema says,
# and in the schema's order. `Union{Nothing,T}` is an optional item and a
# `Vector` is a repeated one. The full rules are in the docstring at the top of
# jexi/src/structs/structs.jl.
#
# Rust version: rexi/examples/basics/src/bin/structs.rs.

import JExi
using Printf
include("common.jl")

# ANCHOR: main
# ANCHOR: types
# Names follow the XML: `exi_rename_all` and `exi_names` map Julia field names
# to them.
struct Customer
    loyalty_id::Union{Nothing,String}
    name::String
    tier::String
end
JExi.exi_rename_all(::Type{Customer}) = :PascalCase
JExi.exi_names(::Type{Customer}) = (loyalty_id = "loyaltyId",)

struct Item
    sku::String
    description::String
    quantity::Int32
    price::Float64
end
JExi.exi_rename_all(::Type{Item}) = :PascalCase
JExi.exi_names(::Type{Item}) = (sku = "sku",)

struct Order
    order_id::String
    priority::Union{Nothing,Bool}
    customer::Customer
    items::Vector{Item}
    notes::Union{Nothing,String}
end
JExi.exi_names(::Type{Order}) = (order_id = "orderId", customer = "Customer", items = "Item", notes = "Notes")

# ANCHOR_END: types

tables = JExi.compile_files(data("order.xsd"))
options = JExi.strict_options()

order = Order("ORD-2026-0007", true, Customer("L-8821", "Raven Bookstore", "gold"),
    [Item("BK-001", "Distributed Systems Patterns", 2, 42.95),
     Item("BK-014", "Practical EXI", 1, 31.50)],
    "gift-wrap requested")

# The root element's name comes from the struct's name, `Order`.
exi = JExi.to_exi(order, tables; options)
from_xml = JExi.encode_xml(read(data("order.xml"), String), tables; options)
println("EXI: ", length(exi), " bytes")
println("same bytes as encoding order.xml: ", exi == from_xml)

back = JExi.from_exi(Order, exi, tables; options)
again = JExi.to_exi(back, tables; options)
println("decodes and encodes to the same bytes: ", again == exi)

println("order ", back.order_id, " for ", back.customer.name, " (", back.customer.tier, ")")
total = 0.0
for item in back.items
    @printf("  %d x %-30s %7.2f\n", item.quantity, item.description, item.price)
    global total += item.quantity * item.price
end
@printf("  total %.2f\n", total)
back.notes === nothing || println("  notes: ", back.notes)
# ANCHOR_END: main
