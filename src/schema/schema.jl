# The schema compiler's entry points (rexi-schema lib.rs).

"""
    compile_files(paths...; load_options = SchemaLoadOptions()) -> GrammarSet

Compiles XSD files (and what they import and include) into grammar tables.
Includes and imports may only read files under the main files' folders unless
`load_options` says otherwise (see [`SchemaLoadOptions`](@ref)).
"""
function compile_files(paths::AbstractString...; load_options::SchemaLoadOptions = SchemaLoadOptions())
    return emit(load_model(paths...; load_options); load_options.max_grammar_size)
end

compile_files(paths::AbstractVector{<:AbstractString}; kw...) = compile_files(paths...; kw...)

"""
    compile_string(xsd; base_dir = nothing, load_options = SchemaLoadOptions()) -> GrammarSet

Compiles one XSD document given as text; relative schema locations resolve
against `base_dir`. Includes and imports may only read files under `base_dir`
(with no `base_dir`, none at all) unless `load_options` says otherwise.
"""
function compile_string(xsd::AbstractString; base_dir = nothing,
    load_options::SchemaLoadOptions = SchemaLoadOptions())
    ld = Loader(load_options)
    load_string!(ld, xsd, base_dir)
    model = resolve(ld.docs; load_options.max_grammar_size)
    return emit(model; load_options.max_grammar_size)
end

"""Loads and resolves XSD files into the schema model, without emitting tables."""
function load_model(paths::AbstractString...; load_options::SchemaLoadOptions = SchemaLoadOptions())
    ld = Loader(load_options)
    # Every main file's folder first, so an include in one may reach another's.
    foreach(p -> add_main_folder!(ld, dirname(abspath(p))), paths)
    foreach(p -> load_file!(ld, p), paths)
    return resolve(ld.docs; load_options.max_grammar_size)
end

# ---------------------------------------------------------------- listing

# Rust's `Debug` form of a string, so listings compare with `rexi dump-grammar`.
function rust_debug(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\0'
            print(io, "\\0")
        elseif iscntrl(c)
            print(io, "\\u{", string(UInt32(c); base = 16), "}")
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

rust_debug(v::AbstractVector) = "[" * join((rust_debug(x) for x in v), ", ") * "]"

const WS_DEBUG = Dict(WS_PRESERVE => "Preserve", WS_REPLACE => "Replace", WS_COLLAPSE => "Collapse")
const DTK_DEBUG = ("DateTime", "Date", "Time", "GYear", "GYearMonth", "GMonth", "GMonthDay", "GDay")

function rust_debug(k::DatatypeKind)
    t = k.tag
    t == K_STRING && return "String { whitespace: $(WS_DEBUG[k.whitespace]) }"
    t == K_RESTRICTED_STRING && return "RestrictedString { whitespace: $(WS_DEBUG[k.whitespace]) }"
    t == K_BOOLEAN && return "Boolean"
    t == K_BOOLEAN_PATTERN && return "BooleanPattern"
    t == K_INTEGER && return "Integer"
    t == K_UNSIGNED && return "UnsignedInteger"
    t == K_NBIT && return "NBit { min: $(k.min), bits: $(Int(k.bits)) }"
    t == K_DECIMAL && return "Decimal"
    t == K_FLOAT && return "Float"
    t == K_DATETIME && return "DateTime($(DTK_DEBUG[Int(k.datetime) + 1]))"
    t == K_BASE64 && return "Base64Binary"
    t == K_HEX && return "HexBinary"
    t == K_QNAME && return "QName"
    t == K_ENUMERATION && return "Enumeration { set: $(Int(k.set)), item: $(Int(k.item)) }"
    t == K_LIST && return "List { item: $(Int(k.item)) }"
    return "Untyped"
end

"""
    grammar_listing(g) -> String

A plain listing of the grammar tables: the URIs and names, element and type
declarations, and every grammar's rules with their productions in event-code
order. It is the same text as `rexi dump-grammar`, so the two compilers can be
compared line by line.
"""
function grammar_listing(g::GrammarSet)
    io = IOBuffer()
    p(line) = println(io, line)
    p("schemaId: " * (g.schema_id === nothing ? "None" : "Some($(rust_debug(g.schema_id)))"))
    p("uris:")
    for (i, e) in enumerate(g.uris)
        locals = [gstring(g, s) for s in view(g.local_names, span_range(e.local_names))]
        p("  [$(i - 1)] $(rust_debug(gstring(g, e.uri))) local-names $(rust_debug(locals))")
    end
    p("global elements:")
    for e in g.global_elements
        d = gelement(g, e)
        p("  element $e: $(describe_qname(g, d.qname)) type $(d.type_idx)")
    end
    p("elements:")
    for (i, d) in enumerate(g.elements)
        p("  [$(i - 1)] $(describe_qname(g, d.qname)) type $(d.type_idx) nillable $(d.nillable) global $(d.is_global)")
    end
    p("types:")
    for (i, t) in enumerate(g.types)
        name = is_anonymous(t) ? "(anonymous)" : describe_qname(g, t.qname)
        dt = t.has_datatype ? "Some($(rust_debug(t.datatype)))" : "None"
        p("  [$(i - 1)] $name grammar $(t.grammar) empty-grammar $(t.empty_grammar) datatype $dt typecastable $(t.typecastable)")
    end
    p("grammars:")
    for (gi, gr) in enumerate(g.grammars)
        s = gr.rules
        p("  grammar $(gi - 1): rules $(s.start)..$(s.start + s.len)")
        for rule in s.start:(s.start + s.len - 1)
            prods = ["$(c - 1): $(describe_terminal(g, x.terminal)) -> $(x.next)"
                     for (c, x) in enumerate(rule_productions(g, rule))]
            p("    rule $rule: [$(join(prods, ", "))]")
        end
    end
    p("enumerations:")
    for (i, s) in enumerate(g.enum_sets)
        p("  [$(i - 1)] $(rust_debug([gstring(g, v) for v in view(g.enum_values, span_range(s))]))")
    end
    return String(take!(io))
end
