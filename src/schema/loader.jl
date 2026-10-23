# Reading XSD documents into raw syntax trees, following xs:import and
# xs:include (rexi-schema xsd/loader.rs). A document is listed before the
# documents it imports. xs:redefine, xs:override and xs:notation are refused.

"""
    SchemaLoadOptions(; root = nothing, max_file_bytes = 16 * 1024 * 1024, max_grammar_size = 100_000)

Rules for loading a schema: which files `xs:include` and `xs:import` may read,
how big one schema file may be, and how big one type's content model may grow
once group references are replaced and `maxOccurs` copies are made, counted in
grammar rules (`nothing`: no limit for either size). EXI builds one copy of a
particle for each allowed occurrence (https://www.w3.org/TR/exi/#particles), so
`maxOccurs="4000000000"`, or groups that each use the one before twice, would
otherwise use up memory.

A schema names other schema files with `schemaLocation`. Without a rule, a hostile
schema could name any file the program can read (`/etc/passwd`, `../../secrets`),
or one that never ends (`/dev/zero`) or never answers (a named pipe); the error
messages would also tell which files exist. So by default every included or
imported file must sit under the main schema's folder. `root` is:

- `nothing` (default): under the folders of the main schema files (for
  `compile_string`, under its `base_dir`; with no `base_dir`, no file at all);
- a folder path: under that folder, for sets that reach outside the main
  schema's folder (UBL's `../common/...`, for example);
- `:anywhere`: any local file, only for schemas you trust.

In every mode only regular files are read (no pipes or devices), a
`schemaLocation` that is a URL is refused (nothing is fetched over a network),
and a file over `max_file_bytes` is refused, each with a `SchemaError` that says
"refused".
"""
Base.@kwdef struct SchemaLoadOptions
    root::Union{Nothing,String,Symbol} = nothing
    max_file_bytes::Union{Nothing,Int} = 16 * 1024 * 1024
    max_grammar_size::Union{Nothing,Int} = 100_000
    function SchemaLoadOptions(root, max_file_bytes, max_grammar_size)
        root isa Symbol && root !== :anywhere &&
            throw(ArgumentError("root must be nothing, a folder path or :anywhere, got :$root"))
        return new(root, max_file_bytes, max_grammar_size)
    end
end

"""Reads schema documents; `docs` holds them in load order."""
Base.@kwdef mutable struct Loader
    docs::Vector{RawDocument} = RawDocument[]
    loaded::Vector{String} = String[]
    options::SchemaLoadOptions = SchemaLoadOptions()
    # The folders includes and imports may read under. Each is kept twice: as
    # written (absolute, `..` removed) and as its real path (links followed), so
    # either form of a location can be matched.
    roots::Vector{String} = String[]
end

"""A loader with the given rules; a folder `root` must exist."""
function Loader(options::SchemaLoadOptions)
    ld = Loader(; options)
    options.root isa String && add_root!(ld, options.root)
    return ld
end

function add_root!(ld::Loader, dir::AbstractString)
    real = try
        realpath(dir)
    catch err
        throw(SchemaError("cannot read schema $dir: $(sprint(showerror, err))"))
    end
    for form in (normpath(abspath(dir)), real)
        form in ld.roots || push!(ld.roots, form)
    end
    return ld
end

"""
Notes the folder of a main schema (a file the caller named, or the `base_dir` of
a schema in memory) as a place includes may read from, when `root` is `nothing`.
"""
add_main_folder!(ld::Loader, dir::AbstractString) =
    ld.options.root === nothing ? add_root!(ld, dir) : ld

function inside_root(ld::Loader, path::AbstractString)
    ld.options.root === :anywhere && return true
    for r in ld.roots
        prefix = endswith(r, Base.Filesystem.path_separator) ? r : r * Base.Filesystem.path_separator
        (path == r || startswith(path, prefix)) && return true
    end
    return false
end

refused(location, reason) = SchemaError("schema location '$location' refused: $reason")

struct LoadCtx
    target_ns::String
    element_qualified::Bool
    attribute_qualified::Bool
end

is_xs(e::XElement, name::AbstractString) = e.uri == XSD_NS && e.local_name == name
xs_name(e::XElement) = e.uri == XSD_NS ? e.local_name : nothing

function required_attr(e::XElement, name::AbstractString)
    v = attr(e, name)
    v === nothing && throw(SchemaError("invalid schema: xs:$(e.local_name) is missing the $name attribute"))
    return v
end

function schema_qname(e::XElement, value::AbstractString)
    uri, l = try
        resolve_qname_value(e, value)
    catch err
        err isa XmlSyntaxError || rethrow()
        throw(SchemaError("invalid schema: $(err.msg)"))
    end
    return QName(uri, l)
end

opt_qname(e::XElement, name::AbstractString) = (v = attr(e, name); v === nothing ? nothing : schema_qname(e, v))

function occurs(e::XElement)
    mn = attr(e, "minOccurs")
    mx = attr(e, "maxOccurs")
    min = mn === nothing ? 1 : tryparse(Int, strip(mn))
    min === nothing && throw(SchemaError("invalid schema: bad minOccurs '$mn'"))
    max = if mx === nothing
        1
    elseif strip(mx) == "unbounded"
        nothing
    else
        m = tryparse(Int, strip(mx))
        m === nothing && throw(SchemaError("invalid schema: bad maxOccurs '$mx'"))
        m
    end
    (min < 0 || (max !== nothing && max < 0)) && throw(SchemaError("invalid schema: negative occurrence bound"))
    (max !== nothing && max < min) && throw(SchemaError("invalid schema: maxOccurs $max < minOccurs $min"))
    return (min, max)
end

bool_attr(e::XElement, name::AbstractString) = (v = attr(e, name); v !== nothing && strip(v) in ("true", "1"))

function ns_constraint(e::XElement, ctx::LoadCtx)
    v = attr(e, "namespace")
    v = v === nothing ? "##any" : strip(v)
    v == "##any" && return NsAny()
    v == "##other" && return NsOther(ctx.target_ns)
    return NsList([t == "##targetNamespace" ? ctx.target_ns : t == "##local" ? "" : String(t) for t in split(v)])
end

"""
    load_file!(loader, path; expected_ns, chameleon_ns)

Loads one schema document and, in turn, what it imports and includes. A file is
read once however often it is referred to.
"""
function load_file!(ld::Loader, path::AbstractString; expected_ns = nothing, chameleon_ns = nothing)
    canonical = try
        realpath(path)
    catch err
        throw(SchemaError("cannot read schema $path: $(sprint(showerror, err))"))
    end
    canonical in ld.loaded && return ld
    push!(ld.loaded, canonical)
    text = read_schema_file(canonical, ld.options.max_file_bytes)
    return load_text!(ld, text, dirname(canonical), canonical; expected_ns, chameleon_ns)
end

"""
Reads a schema file as text, after checking that it is a regular file (not a
pipe or a device, which could block or never end) and not over `max` bytes. The
read itself also stops after `max` bytes, because some files (under `/proc`, for
example) report a size of 0.
"""
function read_schema_file(path::AbstractString, max::Union{Nothing,Int})
    isfile(path) || throw(refused(path, "not a regular file"))
    (max !== nothing && filesize(path) > max) && throw(refused(path, "bigger than $max bytes"))
    bytes = try
        open(io -> max === nothing ? read(io) : read(io, max + 1), path)
    catch err
        throw(SchemaError("cannot read schema $path: $(sprint(showerror, err))"))
    end
    (max !== nothing && length(bytes) > max) && throw(refused(path, "bigger than $max bytes"))
    return String(bytes)
end

"""
Follows a `schemaLocation` from a document whose folder is `base_dir`, after
checking the load rules (see [`SchemaLoadOptions`](@ref)).
"""
function load_location!(ld::Loader, base_dir, loc::AbstractString; expected_ns = nothing, chameleon_ns = nothing)
    # Nothing is fetched over a network. "C:" style drive letters are one letter,
    # so a scheme of two or more letters is a URL.
    occursin(r"^[A-Za-z0-9+.-]{2,}:", loc) && throw(refused(loc, "URLs are not fetched"))
    reason = ld.options.root === nothing ?
             (isempty(ld.roots) ? "a schema in memory with no base folder may not include or import files" :
              "outside the main schema's folder (set a schema root to allow it)") :
             "outside the schema root folder"
    path = resolve_location(base_dir, loc)
    # First check the path as written, without touching the disk. A location
    # outside the root is refused the same way whether or not the file exists,
    # so the error never tells which files are there.
    inside_root(ld, normpath(abspath(path))) || throw(refused(loc, reason))
    # Then follow symbolic links, which may lead out of the root.
    real = try
        realpath(path)
    catch err
        throw(SchemaError("cannot read schema $path: $(sprint(showerror, err))"))
    end
    inside_root(ld, real) || throw(refused(loc, reason))
    return load_file!(ld, real; expected_ns, chameleon_ns)
end

"""
Loads a schema document from a string; relative locations resolve against
`base_dir`, which is also the main schema's folder for the load rules.
"""
function load_string!(ld::Loader, text::AbstractString, base_dir = nothing)
    base_dir === nothing || add_main_folder!(ld, base_dir)
    return load_text!(ld, text, base_dir, "<string>")
end

function load_text!(ld::Loader, text::AbstractString, base_dir, source::AbstractString;
    expected_ns = nothing, chameleon_ns = nothing)
    root = try
        parse_xml(text)
    catch err
        err isa XmlSyntaxError || rethrow()
        throw(SchemaError("schema $source is not well-formed: $(err.msg)"))
    end
    is_xs(root, "schema") || throw(SchemaError("invalid schema: $source: root element is not xs:schema"))
    target_ns = something(attr(root, "targetNamespace"), "")
    (isempty(target_ns) && chameleon_ns !== nothing) && (target_ns = chameleon_ns)
    if expected_ns !== nothing && expected_ns != target_ns
        throw(SchemaError("invalid schema: $source: imported for namespace '$expected_ns' but declares '$target_ns'"))
    end
    ctx = LoadCtx(target_ns, attr(root, "elementFormDefault") == "qualified",
        attr(root, "attributeFormDefault") == "qualified")
    raw = RawDocument(; target_ns, element_qualified = ctx.element_qualified,
        attribute_qualified = ctx.attribute_qualified)
    # Take this document's place in the list now, before following imports, so
    # a document always comes before the documents it imports.
    push!(ld.docs, RawDocument())
    slot = length(ld.docs)
    for child in child_elements(root)
        child.uri == XSD_NS || continue
        name = child.local_name
        if name == "annotation"
        elseif name == "import"
            loc = attr(child, "schemaLocation")
            loc === nothing || load_location!(ld, base_dir, loc; expected_ns = something(attr(child, "namespace"), ""))
        elseif name == "include"
            loc = attr(child, "schemaLocation")
            loc === nothing && throw(SchemaError("invalid schema: $source: xs:include without schemaLocation"))
            load_location!(ld, base_dir, loc; chameleon_ns = ctx.target_ns)
        elseif name in ("redefine", "override", "notation")
            throw(SchemaError("unsupported schema construct: xs:$name"))
        elseif name == "element"
            push!(raw.elements, parse_element(child, ctx, true))
        elseif name == "attribute"
            push!(raw.attributes, parse_attribute(child, ctx, true))
        elseif name == "complexType"
            push!(raw.complex_types, parse_complex_type(child, ctx))
        elseif name == "simpleType"
            push!(raw.simple_types, parse_simple_type(child, ctx))
        elseif name == "group"
            gname = required_attr(child, "name")
            p = first_particle(child, ctx)
            p === nothing && throw(SchemaError("invalid schema: xs:group $gname has no model group"))
            push!(raw.groups, RawGroup(gname, ctx.target_ns, p))
        elseif name == "attributeGroup"
            gname = required_attr(child, "name")
            items, any = attribute_items(child, ctx)
            push!(raw.attribute_groups, RawAttributeGroup(gname, ctx.target_ns, items, any))
        else
            throw(SchemaError("unsupported schema construct: xs:$name at schema level"))
        end
    end
    ld.docs[slot] = raw
    return ld
end

resolve_location(base_dir, loc::AbstractString) =
    (isabspath(loc) || base_dir === nothing) ? String(loc) : joinpath(base_dir, loc)

function form_ns(e::XElement, ctx::LoadCtx, qualified_default::Bool)
    f = attr(e, "form")
    f === nothing && return qualified_default ? ctx.target_ns : ""
    return f == "qualified" ? ctx.target_ns : ""
end

function parse_element(e::XElement, ctx::LoadCtx, is_global::Bool)
    min, max = is_global ? (1, 1) : occurs(e)
    reference = opt_qname(e, "ref")
    name = attr(e, "name")
    (reference === nothing && name === nothing) && throw(SchemaError("invalid schema: xs:element without name or ref"))
    ns = is_global ? ctx.target_ns : form_ns(e, ctx, ctx.element_qualified)
    inline = nothing
    for c in child_elements(e)
        n = xs_name(c)
        n == "complexType" && (inline = parse_complex_type(c, ctx))
        n == "simpleType" && (inline = parse_simple_type(c, ctx))
    end
    sg = opt_qname(e, "substitutionGroup")
    return RawElement(name, ns, reference, opt_qname(e, "type"), inline, min, max, bool_attr(e, "nillable"),
        is_global ? sg : nothing, bool_attr(e, "abstract"))
end

function parse_attribute(e::XElement, ctx::LoadCtx, is_global::Bool)
    reference = opt_qname(e, "ref")
    name = attr(e, "name")
    (reference === nothing && name === nothing) && throw(SchemaError("invalid schema: xs:attribute without name or ref"))
    ns = is_global ? ctx.target_ns : form_ns(e, ctx, ctx.attribute_qualified)
    inline = nothing
    for c in child_elements(e)
        if is_xs(c, "simpleType")
            inline = parse_simple_type(c, ctx)
            break
        end
    end
    u = attr(e, "use")
    use = u === nothing ? USE_OPTIONAL : strip(u) == "required" ? USE_REQUIRED :
          strip(u) == "prohibited" ? USE_PROHIBITED : USE_OPTIONAL
    return RawAttribute(name, ns, reference, opt_qname(e, "type"), inline, use)
end

function attribute_items(e::XElement, ctx::LoadCtx)
    items = RawAttrItem[]
    any = nothing
    for c in child_elements(e)
        n = xs_name(c)
        if n == "attribute"
            push!(items, parse_attribute(c, ctx, false))
        elseif n == "attributeGroup"
            push!(items, schema_qname(c, required_attr(c, "ref")))
        elseif n == "anyAttribute"
            any = ns_constraint(c, ctx)
        end
    end
    return (items, any)
end

function parse_particle(e::XElement, ctx::LoadCtx)
    n = xs_name(e)
    n == "element" && return RawElementParticle(parse_element(e, ctx, false))
    if n == "any"
        min, max = occurs(e)
        return RawAnyParticle(ns_constraint(e, ctx), min, max)
    end
    if n in ("sequence", "choice", "all")
        comp = n == "sequence" ? COMP_SEQUENCE : n == "choice" ? COMP_CHOICE : COMP_ALL
        min, max = occurs(e)
        ps = RawParticle[]
        for c in child_elements(e)
            p = parse_particle(c, ctx)
            p === nothing || push!(ps, p)
        end
        return RawGroupParticle(comp, ps, min, max)
    end
    if n == "group"
        min, max = occurs(e)
        return RawGroupRef(schema_qname(e, required_attr(e, "ref")), min, max)
    end
    return nothing
end

function first_particle(e::XElement, ctx::LoadCtx)
    for c in child_elements(e)
        p = parse_particle(c, ctx)
        p === nothing || return p
    end
    return nothing
end

function parse_complex_type(e::XElement, ctx::LoadCtx)
    mixed = bool_attr(e, "mixed")
    derivation = nothing
    attributes, any = attribute_items(e, ctx)
    for c in child_elements(e)
        n = xs_name(c)
        if n == "complexContent"
            mixed |= bool_attr(c, "mixed")
            for d in child_elements(c)
                dn = xs_name(d)
                dn in ("extension", "restriction") || continue
                base = schema_qname(d, required_attr(d, "base"))
                particle = first_particle(d, ctx)
                attributes, any = attribute_items(d, ctx)
                derivation = dn == "extension" ? DerivComplexExtension(base, particle) :
                             DerivComplexRestriction(base, particle)
            end
        elseif n == "simpleContent"
            for d in child_elements(c)
                dn = xs_name(d)
                dn in ("extension", "restriction") || continue
                base = schema_qname(d, required_attr(d, "base"))
                attributes, any = attribute_items(d, ctx)
                if dn == "extension"
                    derivation = DerivSimpleExtension(base)
                else
                    inline = nothing
                    for s in child_elements(d)
                        if is_xs(s, "simpleType")
                            inline = parse_simple_type(s, ctx)
                            break
                        end
                    end
                    derivation = DerivSimpleRestriction(base, parse_facets(d), inline)
                end
            end
        elseif n in ("sequence", "choice", "all", "group")
            derivation = DerivNone(parse_particle(c, ctx))
        end
    end
    return RawComplexType(attr(e, "name"), ctx.target_ns, mixed, something(derivation, DerivNone(nothing)),
        attributes, any)
end

const FACET_NAMES = Dict("enumeration" => :enumeration, "minInclusive" => :minInclusive,
    "maxInclusive" => :maxInclusive, "minExclusive" => :minExclusive, "maxExclusive" => :maxExclusive,
    "pattern" => :pattern, "whiteSpace" => :whiteSpace)

function parse_facets(e::XElement)
    facets = Facet[]
    for c in child_elements(e)
        n = xs_name(c)
        (n === nothing || n in ("simpleType", "annotation")) && continue
        v = something(attr(c, "value"), "")
        if n == "whiteSpace" && !(strip(v) in ("preserve", "replace", "collapse"))
            throw(SchemaError("invalid schema: bad whiteSpace facet '$(strip(v))'"))
        end
        push!(facets, Facet(get(FACET_NAMES, n, Symbol(n)), v))
    end
    return facets
end

function inline_simple(e::XElement, ctx::LoadCtx)
    for c in child_elements(e)
        is_xs(c, "simpleType") && return parse_simple_type(c, ctx)
    end
    return nothing
end

function parse_simple_type(e::XElement, ctx::LoadCtx)
    name = attr(e, "name")
    variety = nothing
    for c in child_elements(e)
        n = xs_name(c)
        if n == "restriction"
            base = opt_qname(c, "base")
            inline = inline_simple(c, ctx)
            (base === nothing && inline === nothing) && throw(SchemaError("invalid schema: xs:restriction without base"))
            variety = RawRestriction(base, inline, parse_facets(c))
        elseif n == "list"
            item = opt_qname(c, "itemType")
            inline = inline_simple(c, ctx)
            (item === nothing && inline === nothing) && throw(SchemaError("invalid schema: xs:list without item type"))
            variety = RawList(item, inline)
        elseif n == "union"
            members = [schema_qname(c, m) for m in split(something(attr(c, "memberTypes"), ""))]
            inline = RawSimpleType[parse_simple_type(s, ctx) for s in child_elements(c) if is_xs(s, "simpleType")]
            variety = RawUnion(members, inline)
        end
    end
    variety === nothing && throw(SchemaError(
        "invalid schema: xs:simpleType $(something(name, "<anonymous>")) has no restriction, list or union"))
    return RawSimpleType(name, ctx.target_ns, variety)
end
