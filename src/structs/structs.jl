# Julia structs to and from EXI, driven by the schema (rexi-serde).
#
# The schema decides the mapping, so plain structs need few annotations:
#
# - Root: the type's name (`exi_name`) is matched against the global elements;
#   `to_exi(...; root = "{uri}local")` names it explicitly.
# - Attributes vs elements: a field is an attribute when the grammar allows
#   AT(name) at that point, else a child element. Attributes are written in
#   schema order whatever the field order; child elements in field order.
# - Namespaces come from the grammar's productions; a `{uri}local` name picks
#   one when a name is declared in several namespaces.
# - `Vector{T}` is maxOccurs > 1, `Union{Nothing,T}` is minOccurs = 0 (`nothing`
#   is left out; a decoded xsi:nil="true" becomes `nothing`). `Vector{UInt8}` is
#   a binary value; a vector of simple values is an xs:list when the element's
#   type is one.
# - `@enum` values are xs:enumeration values (their names, after renaming).
# - Choices: a field whose type is a `Union` of structs, or an abstract type
#   with `exi_choices`, is written as the element named after the value's type.
#   With `exi_xsi_type(::Type{A}) = true` the element keeps its name and
#   xsi:type names the value's type instead.
# - A field named `"\$text"` (or `"\$value"` holding a simple value) is the
#   element's character content; `"\$value"` holding choices takes the child
#   elements no other field names, in document order.
# - Fields named `"@xsi:type"` (a type name) and `"@xsi:nil"` (a Bool) set those.
#
# Names: the XML name of a field is `exi_names(T)` for it, else the field name
# after `exi_rename_all(T)` (`:PascalCase`, `:camelCase`, `:lowercase`,
# `:UPPERCASE`, as serde's `rename_all`). Values are passed typed where the
# conversion is exact, else as text parsed with the schema's datatype
# (https://www.w3.org/TR/exi/#encodingDatatypes).

"""A struct does not fit the schema, or a decoded document does not fit a struct."""
struct MappingError <: ExiError
    msg::String
end
Base.showerror(io::IO, e::MappingError) = print(io, "mapping: ", e.msg)

"""The element name of a type (root, choice branch) or its name as an xsi:type."""
exi_name(::Type{T}) where {T} = string(nameof(T))

"""Field (or enum instance) name => XML name overrides, as a NamedTuple or Dict."""
exi_names(::Type) = NamedTuple()

"""How unnamed fields are renamed: `nothing`, `:PascalCase`, `:camelCase`, `:lowercase`, `:UPPERCASE`."""
exi_rename_all(::Type) = nothing

"""The concrete types an abstract field type stands for, as a tuple (a choice)."""
exi_choices(::Type) = nothing

"""Whether the choices of an abstract type are told apart by xsi:type (true) or by element name."""
exi_xsi_type(::Type) = false

const TEXT_FIELDS = ("\$text", "\$value")
const XSI_TYPE_FIELDS = ("@xsi:type", "xsi:type")
const XSI_NIL_FIELDS = ("@xsi:nil", "xsi:nil")

function rename(style, s::AbstractString)
    style === nothing && return String(s)
    words = split(s, '_'; keepempty = false)
    style == :PascalCase && return join(uppercasefirst.(words))
    style == :camelCase && return isempty(words) ? "" : words[1] * join(uppercasefirst.(words[2:end]))
    style == :lowercase && return lowercase(s)
    style == :UPPERCASE && return uppercase(s)
    throw(ArgumentError("unknown rename style $style"))
end

function lookup_name(names, key::Symbol)
    names isa NamedTuple && return haskey(names, key) ? String(names[key]) : nothing
    return haskey(names, key) ? String(names[key]) : nothing
end

"""The XML name of field `f` of `T`."""
function field_key(::Type{T}, f::Union{Symbol,Int}) where {T}
    s = f isa Symbol ? f : Symbol(f)
    n = lookup_name(exi_names(T), s)
    return n === nothing ? rename(exi_rename_all(T), string(s)) : n
end

"""The text of an enum value."""
function enum_text(x::Base.Enum)
    T = typeof(x)
    s = Symbol(x)
    n = lookup_name(exi_names(T), s)
    return n === nothing ? rename(exi_rename_all(T), string(s)) : n
end

# `{uri}local` or `local`, with an optional leading `@`.
function parse_field_name(s::AbstractString)
    s = startswith(s, '@') ? SubString(s, 2) : s
    if startswith(s, '{')
        i = findfirst('}', s)
        i === nothing || return (String(s[2:prevind(s, i)]), String(s[nextind(s, i):end]))
    end
    return (nothing, String(s))
end

function name_matches(g::GrammarSet, name, q::QNameId)
    uri, l = name
    local_name_str(g, q) == l || return false
    return uri === nothing || uri_str(g, q.uri) == uri
end

qname_strings(g::GrammarSet, q::QNameId) = (something(uri_str(g, q.uri), ""), something(local_name_str(g, q), ""))

# ------------------------------------------------------------------ items

# A value made ready for writing (rexi-serde item.rs).
abstract type Item end
struct ItemScalar <: Item
    value::Any
end
struct ItemUnit <: Item end
struct ItemNone <: Item end
struct ItemSeq <: Item
    items::Vector{Item}
end
struct ItemStruct <: Item
    name::String
    fields::Vector{Pair{String,Item}}
end
struct ItemVariant <: Item
    name::String
    inner::Item
end

is_scalar_value(x) = x isa Union{Bool,Number,AbstractString,Char,Symbol,Base.Enum,AbstractVector{UInt8},
    ExiDecimal,ExiFloat,ExiDateTime,EnumOrdinal,Lexical}

"""The choice types of a field type, or nothing when it is no choice."""
function choice_types(FT::Type)
    if FT isa Union
        ts = filter(t -> t !== Nothing, Base.uniontypes(FT))
        length(ts) > 1 && all(isstructtype, ts) && return Tuple(ts)
        return nothing
    end
    return exi_choices(FT)
end

"""Turns a value into items; `FT` is the declared type of the field holding it."""
function to_item(x, FT::Type = typeof(x))
    x === nothing && return ItemNone()
    is_scalar_value(x) && return ItemScalar(x)
    if x isa Tuple{} || x isa Nothing
        return ItemUnit()
    end
    if x isa AbstractVector
        ET = eltype(FT <: AbstractVector ? FT : typeof(x))
        return ItemSeq(Item[to_item(v, ET) for v in x])
    end
    T = typeof(x)
    isstructtype(T) || throw(MappingError("cannot map a value of type $T"))
    inner = struct_item(x)
    # A choice: by element name, or the same element with xsi:type.
    base = nonnothing(FT)
    if choice_types(base) !== nothing
        if isabstracttype(base) && exi_xsi_type(base)
            return ItemStruct(inner.name, Pair{String,Item}["@xsi:type" => ItemScalar(exi_name(T)); inner.fields])
        end
        return ItemVariant(exi_name(T), inner)
    end
    return inner
end

function struct_item(x)
    T = typeof(x)
    fields = Pair{String,Item}[]
    for (i, f) in enumerate(fieldnames(T))
        push!(fields, field_key(T, f) => to_item(getfield(x, i), fieldtype(T, i)))
    end
    return ItemStruct(exi_name(T), fields)
end

# ------------------------------------------------------------------ writing

# Plain text of a scalar, as rexi writes it (Rust's Display): no exponent and
# no trailing `.0` on whole floats.
function plain_float(x::AbstractFloat)
    isnan(x) && return "NaN"
    isinf(x) && return x > 0 ? "INF" : "-INF"
    isinteger(x) && abs(x) < 1e16 && return string(BigInt(x))
    # The shortest text that reads back as the same value *at its own width*, as
    # rexi does. Widening a Float32 to Float64 first would give the exact binary
    # value instead: 0.1f0 would come out as 0.10000000149011612, a different
    # number. Julia writes a Float32 as `0.1f0` or `1.0f-5`; with the `f` made an
    # `e` it is ordinary exponent form, handled below. Float16 goes through Float32
    # (exact), since Julia writes it as `Float16(0.1)`.
    s = x isa Union{Float32,Float16} ? replace(string(Float32(x)), 'f' => 'e') : string(Float64(x))
    occursin('e', s) || return s
    parts = split(s, 'e')
    m = String(parts[1])
    e = parse(Int, parts[2])
    neg = startswith(m, '-')
    neg && (m = m[2:end])
    dot = findfirst('.', m)
    ip = dot === nothing ? m : m[1:(dot - 1)]
    fp = dot === nothing ? "" : m[(dot + 1):end]
    digits = ip * fp
    point = length(ip) + e
    body::String = point <= 0 ? "0." * "0"^(-point) * digits :
                   point >= length(digits) ? digits * "0"^(point - length(digits)) :
                   digits[1:point] * "." * digits[(point + 1):end]
    occursin('.', body) && (body = String(rstrip(rstrip(body, '0'), '.')))
    return (neg ? "-" : "") * body
end

scalar_lexical(x::Bool) = x ? "true" : "false"
scalar_lexical(x::Integer) = string(x)
scalar_lexical(x::AbstractFloat) = plain_float(x)
scalar_lexical(x::AbstractString) = String(x)
scalar_lexical(x::Char) = string(x)
scalar_lexical(x::Symbol) = string(x)
scalar_lexical(x::Base.Enum) = enum_text(x)
scalar_lexical(x::AbstractVector{UInt8}) = format_hex(x)
scalar_lexical(x::Lexical) = x.text
scalar_lexical(x) = plain_format(x)

"""The value to hand the encoder: typed when the conversion is exact, else text."""
function prepare_scalar(x, kind::DatatypeKind)
    t = kind.tag
    (t == K_BOOLEAN || t == K_BOOLEAN_PATTERN) && x isa Bool && return x
    if x isa Integer && !(x isa Bool)
        (t == K_INTEGER || t == K_NBIT || t == K_DECIMAL) && return x
        (t == K_UNSIGNED && x >= 0) && return x
    end
    if t == K_DECIMAL && x isa AbstractFloat
        d = decimal_from_lexical(plain_float(x))
        return d === nothing ? Lexical(plain_float(x)) : d
    end
    if t == K_FLOAT && (x isa AbstractFloat || (x isa Integer && !(x isa Bool)))
        f = float_from_lexical(scalar_lexical(x))
        return f === nothing ? Lexical(scalar_lexical(x)) : f
    end
    (t == K_BASE64 || t == K_HEX) && x isa AbstractVector{UInt8} && return Vector{UInt8}(x)
    x isa Union{ExiDecimal,ExiFloat,ExiDateTime,EnumOrdinal,Lexical} && return x
    return Lexical(scalar_lexical(x))
end

function prepare_item(item::Item, kind::DatatypeKind, what::AbstractString)
    item isa ItemScalar && return prepare_scalar(item.value, kind)
    item isa ItemUnit && return Lexical("")
    if item isa ItemSeq
        parts = String[]
        for i in item.items
            i isa ItemScalar || throw(MappingError("$what: only a sequence of simple values can be a list value"))
            push!(parts, scalar_lexical(i.value))
        end
        return Lexical(join(parts, ' '))
    end
    throw(MappingError("$what: expected a simple value, found a structure"))
end

function expected_text(enc::Encoder)
    g = enc.tables
    parts = map(current_productions(enc)) do p
        t = p.terminal
        t.kind == T_SE && return "element " * something(local_name_str(g, gelement(g, t.a).qname), "?")
        t.kind == T_AT && return "attribute " * something(local_name_str(g, term_qname(t)), "?")
        (t.kind == T_CH || t.kind == T_CH_UNTYPED) && return "character content"
        t.kind == T_EE && return "end of element"
        return string(t.kind)
    end
    return join(parts, ", ")
end

function resolve_root(g::GrammarSet, name)
    isempty(g.global_elements) && throw(UnsupportedError(FEATURE_BUILT_IN_ELEMENT_GRAMMAR))
    matches = [gelement(g, e).qname for e in g.global_elements if name_matches(g, name, gelement(g, e).qname)]
    length(matches) == 1 && return qname_strings(g, matches[1])
    if isempty(matches)
        names = [qname_text(qname_strings(g, gelement(g, e).qname)...) for e in g.global_elements]
        throw(MappingError("no global element named $(name[2]); the schema declares $(join(names, ", "))"))
    end
    throw(MappingError("global element name $(name[2]) is ambiguous; rename the root as {uri}$(name[2])"))
end

function resolve_type_name(g::GrammarSet, name)
    matches = [t.qname for t in g.types if t.qname.uri != NONE && name_matches(g, name, t.qname)]
    length(matches) == 1 && return qname_strings(g, matches[1])
    isempty(matches) && throw(MappingError("xsi:type: no type named $(name[2])"))
    throw(MappingError("xsi:type: type name $(name[2]) is ambiguous; use {uri}$(name[2])"))
end

function write_document!(enc::Encoder, item::Item, root)
    if item isa ItemStruct
        name, content = something(root, item.name), item
    elseif item isa ItemVariant
        name, content = something(root, item.name), item.inner
    else
        root === nothing && throw(MappingError(
            "the top-level value must be a struct (named after the root element), or pass the root element name"))
        name, content = root, item
    end
    uri, l = resolve_root(enc.tables, parse_field_name(name))
    start_document!(enc)
    write_element!(enc, uri, l, content)
    end_document!(enc)
end

function write_element!(enc::Encoder, uri, l, item::Item)
    start_element!(enc, uri, l)
    write_content!(enc, l, item)
    end_element!(enc)
end

function write_content!(enc::Encoder, ctx, item::Item)
    (item isa ItemUnit || item isa ItemNone) && return
    (item isa ItemScalar || item isa ItemSeq) && return write_chars!(enc, ctx, item)
    item isa ItemVariant && return write_child!(enc, item.name, item.inner)
    write_struct!(enc, ctx, (item::ItemStruct).fields)
end

function write_chars!(enc::Encoder, ctx, item::Item)
    kind = nothing
    for p in current_productions(enc)
        if p.terminal.kind == T_CH
            kind = datatype(enc.tables, p.terminal.a)
            break
        elseif p.terminal.kind == T_CH_UNTYPED
            kind = UNTYPED_KIND
            break
        end
    end
    kind === nothing && throw(MappingError("$ctx: character content not allowed here; expected $(expected_text(enc))"))
    characters!(enc, prepare_item(item, kind, ctx))
end

function write_struct!(enc::Encoder, ctx, fields::Vector{Pair{String,Item}})
    used = [v isa ItemNone for (_, v) in fields]
    g = enc.tables
    # xsi:type, then xsi:nil: both must come right after the start tag.
    for (i, (k, v)) in enumerate(fields)
        (used[i] || !(k in XSI_TYPE_FIELDS)) && continue
        used[i] = true
        (v isa ItemScalar && v.value isa AbstractString) || throw(MappingError("$ctx: xsi:type must be a type name"))
        xsi_type!(enc, resolve_type_name(g, parse_field_name(v.value))...)
    end
    for (i, (k, v)) in enumerate(fields)
        (used[i] || !(k in XSI_NIL_FIELDS)) && continue
        used[i] = true
        (v isa ItemScalar && v.value isa Bool) || throw(MappingError("$ctx: xsi:nil must be a Bool"))
        xsi_nil!(enc, v.value)
    end
    # Attributes, in the order the grammar's productions list them: each pass
    # takes the first AT production of the current rule that an unused field
    # names; writing it moves the grammar on, and the loop asks again.
    while true
        pick = nothing
        for p in current_productions(enc)
            p.terminal.kind == T_AT || continue
            q = term_qname(p.terminal)
            i = findfirst(j -> !used[j] && !(fields[j][1] in TEXT_FIELDS) && name_matches(g, parse_field_name(fields[j][1]), q),
                eachindex(fields))
            if i !== nothing
                pick = (i, q, p.terminal.c)
                break
            end
        end
        pick === nothing && break
        i, q, ty = pick
        used[i] = true
        uri, l = qname_strings(g, q)
        attribute!(enc, uri, l, prepare_item(fields[i][2], datatype(g, ty), "$ctx/@$l"))
    end
    # Character content: a $text or $value field holding a single value or ().
    for (i, (k, v)) in enumerate(fields)
        (used[i] || !(k in TEXT_FIELDS)) && continue
        if v isa ItemScalar || v isa ItemUnit
            used[i] = true
            write_chars!(enc, ctx, v)
        end
    end
    # Child elements, in field order.
    for (i, (k, v)) in enumerate(fields)
        used[i] || write_child!(enc, k, v)
    end
end

function find_child(enc::Encoder, name::AbstractString)
    g = enc.tables
    parsed = parse_field_name(name)
    for p in current_productions(enc)
        p.terminal.kind == T_SE || continue
        d = gelement(g, p.terminal.a)
        if name_matches(g, parsed, d.qname)
            t = gtype(g, d.type_idx)
            return (d.qname, t.has_datatype ? t.datatype : nothing)
        end
    end
    return nothing
end

function write_child!(enc::Encoder, field::AbstractString, item::Item)
    item isa ItemNone && return
    if item isa ItemVariant
        name, content = item.name, item.inner
    elseif item isa ItemSeq
        # One element holding an xs:list (or binary) value, or the element
        # repeated once per item.
        c = find_child(enc, field)
        if c !== nothing && c[2] !== nothing && c[2].tag in (K_LIST, K_BASE64, K_HEX)
            name, content = field, item
        else
            foreach(it -> write_child!(enc, field, it), item.items)
            return
        end
    else
        name, content = field, item
    end
    c = find_child(enc, name)
    c === nothing && throw(MappingError("no element $name allowed here; expected $(expected_text(enc))"))
    write_element!(enc, qname_strings(enc.tables, c[1])..., content)
end

"""
    to_exi(x, tables; options = strict_options(), header = HeaderConfig(), root = nothing) -> Vector{UInt8}

Encodes the struct `x` as an EXI document of the schema `tables`.
"""
function to_exi(x, tables::GrammarSet; options::ExiOptions = strict_options(), header::HeaderConfig = HeaderConfig(),
    root::Union{Nothing,AbstractString} = nothing)
    enc = Encoder(tables, options; header)
    write_document!(enc, to_item(x), root)
    return finish!(enc)
end

# ------------------------------------------------------------------ reading

"""A decoded value with its standard text form."""
struct TextValue
    value::Any
    lexical::String
end

mutable struct Node
    uri::String
    local_name::String
    xsi_type::Union{Nothing,Tuple{String,String}}
    nil::Bool
    attrs::Vector{Tuple{String,String,TextValue}}
    text::Union{Nothing,TextValue}
    children::Vector{Node}
end

Node(uri, l) = Node(uri, l, nothing, false, Tuple{String,String,TextValue}[], nothing, Node[])

is_simple(n::Node) = isempty(n.attrs) && isempty(n.children) && n.xsi_type === nothing

function read_document(dec::Decoder)
    stack = Node[]
    # For each open node with more than one run of text (mixed content), the
    # runs joined so far. Joining with `*` each time would copy the text over
    # and over, which takes time that grows with the square of its length.
    joined = Union{Nothing,IOBuffer}[]
    root = nothing
    while true
        k = next!(dec)
        k == EV_DONE && break
        if k == EV_SE
            push!(stack, Node(event_qname(dec)...))
            push!(joined, nothing)
        elseif k == EV_EE
            n = pop!(stack)
            buf = pop!(joined)
            if buf !== nothing
                s = String(take!(buf))
                n.text = TextValue(s, s)
            end
            isempty(stack) ? (root = n) : push!(stack[end].children, n)
        elseif k == EV_AT
            u, l = event_qname(dec)
            push!(stack[end].attrs, (u, l, TextValue(dec.value, format_value(dec.last_kind, dec.value, dec.tables))))
        elseif k == EV_XSI_TYPE
            stack[end].xsi_type = event_qname(dec)
        elseif k == EV_XSI_NIL
            stack[end].nil = dec.nil
        elseif k == EV_CH
            t = TextValue(dec.value, format_value(dec.last_kind, dec.value, dec.tables))
            n = stack[end]
            prev = n.text
            # Mixed content: the runs of text are joined, as a plain string.
            if prev === nothing
                n.text = t
            else
                buf = joined[end]
                if buf === nothing
                    buf = IOBuffer()
                    print(buf, prev.lexical)
                    joined[end] = buf
                end
                print(buf, t.lexical)
            end
        end
    end
    root === nothing && throw(MappingError("document has no root element"))
    return root
end

function node_text(n::Node)
    t = n.text
    t === nothing || return t
    isempty(n.children) && return TextValue("", "")
    throw(MappingError("element $(n.local_name) has element content, expected a simple value"))
end

nonnothing(T::Type) = T isa Union ? Union{filter(t -> t !== Nothing, Base.uniontypes(T))...} : T
is_optional(T::Type) = T isa Union && Nothing <: T

function parse_number(::Type{T}, s::AbstractString) where {T<:AbstractFloat}
    s = strip(s)
    s == "INF" && return T(Inf)
    s == "-INF" && return T(-Inf)
    s == "NaN" && return T(NaN)
    v = tryparse(T, s)
    v === nothing && throw(MappingError("expected a number, found $(repr(s))"))
    return v
end

"""Converts a decoded value to the Julia type `T`."""
function from_text(::Type{T}, t::TextValue) where {T}
    v = t.value
    T === Any && return v
    T <: AbstractString && return T(t.lexical)
    T === Bool && (v isa Bool && return v; s = strip(t.lexical);
    (s == "true" || s == "1") && return true; (s == "false" || s == "0") && return false;
    throw(MappingError("expected a boolean, found $(repr(s))")))
    if T <: Integer
        if v isa Integer && !(v isa Bool)
            return convert(T, v)
        end
        x = tryparse(BigInt, strip(t.lexical))
        x === nothing && throw(MappingError("expected an integer, found $(repr(t.lexical))"))
        return convert(T, x)
    end
    T <: AbstractFloat && return parse_number(T, t.lexical)
    if T <: AbstractVector{UInt8}
        v isa AbstractVector{UInt8} && return T(v)
        return T(codeunits(t.lexical))
    end
    if T <: Base.Enum
        s = strip(t.lexical)
        for x in instances(T)
            enum_text(x) == s && return x
        end
        throw(MappingError("$(repr(s)) is not a value of $T"))
    end
    if T <: AbstractVector
        ET = eltype(T)
        if v isa ExiList
            parts = split(t.lexical)
            return T([from_text(ET, TextValue(x, i <= length(parts) ? parts[i] : plain_format(x)))
                      for (i, x) in enumerate(v.items)])
        end
        return T([from_text(ET, TextValue(p, p)) for p in split(t.lexical)])
    end
    v isa T && return v
    T <: Char && length(t.lexical) == 1 && return t.lexical[1]
    T === Symbol && return Symbol(t.lexical)
    throw(MappingError("cannot read $(repr(t.lexical)) as $T"))
end

# The keys a node's parts go by, for the fields of `T` (rexi-serde NodeMap).
function field_keys(::Type{T}) where {T}
    return [field_key(T, f) for f in fieldnames(T)]
end

function key_for(keys::Vector{String}, prefix::AbstractString, uri::AbstractString, l::AbstractString)
    for c in (l, prefix * l, "{$uri}$l", "$prefix{$uri}$l")
        c in keys && return c
    end
    return nothing
end

"""Builds a value of type `T` from a decoded element."""
function from_node(::Type{T}, n::Node) where {T}
    T === Any && return n
    is_optional(T) && return n.nil ? nothing : from_node(nonnothing(T), n)
    choices = choice_types(T)
    if choices !== nothing
        if isabstracttype(T) && exi_xsi_type(T)
            xt = n.xsi_type
            xt === nothing && throw(MappingError("element $(n.local_name) has no xsi:type; expected one of $T"))
            for S in choices
                exi_name(S) == xt[2] && return from_node(S, n)
            end
            throw(MappingError("xsi:type $(xt[2]) is not one of $T"))
        end
        for S in choices
            exi_name(S) == n.local_name && return from_node(S, n)
        end
        throw(MappingError("element $(n.local_name) is not one of the choices of $T"))
    end
    is_scalar_type(T) && return from_text(T, node_text(n))
    isstructtype(T) || throw(MappingError("cannot read element $(n.local_name) as $T"))
    keys = field_keys(T)
    # Children grouped by name, in the order each name first appears.
    groups = Dict{String,Vector{Node}}()
    taken = falses(length(n.children))
    for (i, c) in enumerate(n.children)
        k = key_for(keys, "", c.uri, c.local_name)
        k === nothing && continue
        push!(get!(Vector{Node}, groups, k), c)
        taken[i] = true
    end
    text_used = false
    args = map(1:fieldcount(T)) do i
        FT = fieldtype(T, i)
        k = keys[i]
        if k in XSI_TYPE_FIELDS
            xt = n.xsi_type
            return xt === nothing ? (is_optional(FT) ? nothing : "") : xt[2]
        elseif k in XSI_NIL_FIELDS
            return n.nil
        end
        for (u, l, v) in n.attrs
            key_for(keys, "@", u, l) == k && return from_text(nonnothing(FT), v)
        end
        if k in TEXT_FIELDS
            BT = nonnothing(FT)
            if is_scalar_type(BT) || is_list_like(BT)
                text_used = true
                n.text === nothing && is_optional(FT) && return nothing
                return from_text(BT, node_text(n))
            end
            # Choices: the children no other field names, in document order.
            rest = [c for (i, c) in enumerate(n.children) if !taken[i]]
            if BT <: AbstractVector
                return BT([from_node(eltype(BT), c) for c in rest])
            end
            isempty(rest) && is_optional(FT) && return nothing
            isempty(rest) && throw(MappingError("element $(n.local_name) has no content for $k"))
            return from_node(BT, rest[1])
        end
        nodes = get(groups, k, Node[])
        BT = nonnothing(FT)
        if BT <: AbstractVector && !(BT <: AbstractVector{UInt8})
            # One element holding an xs:list value, or the element repeated.
            t1 = length(nodes) == 1 && is_simple(nodes[1]) ? nodes[1].text : nothing
            (t1 !== nothing && t1.value isa Union{ExiList,AbstractVector{UInt8}}) && return from_text(BT, t1)
            return BT([from_node(eltype(BT), c) for c in nodes])
        end
        if isempty(nodes)
            is_optional(FT) && return nothing
            throw(MappingError("element $(n.local_name): missing $k"))
        end
        length(nodes) > 1 && throw(MappingError(
            "$(length(nodes)) $(nodes[1].local_name) elements for a single-valued field; use a Vector"))
        return from_node(FT, nodes[1])
    end
    return T(args...)
end

is_scalar_type(T::Type) = T <: Union{Bool,Number,AbstractString,Char,Symbol,Base.Enum,AbstractVector{UInt8},
    ExiDecimal,ExiFloat,ExiDateTime,EnumOrdinal}

# A vector field that one element can hold as an xs:list: simple items.
is_list_like(T::Type) = T <: AbstractVector && is_scalar_type(eltype(T))

"""
    from_exi(T, bytes, tables; options = nothing, limits = DecodeLimits()) -> T

Decodes an EXI document of the schema `tables` into a value of type `T`.
`options` are the options agreed out of band, when the header carries none.
`limits` caps what a hostile stream can ask for (see `DecodeLimits`).

The tree is turned into `T` by a function that calls itself once per level,
so its stack use grows with the depth of the document. The default
`max_depth` (256) keeps that safe. With a much higher `max_depth`, or with
`unlimited_limits()`, a very deep document can overflow the stack and throw a
`StackOverflowError`; only turn the cap off for input you trust.
"""
function from_exi(::Type{T}, bytes::AbstractVector{UInt8}, tables::GrammarSet;
    options::Union{Nothing,ExiOptions} = nothing, limits::DecodeLimits = DecodeLimits()) where {T}
    isempty(tables.global_elements) && throw(UnsupportedError(FEATURE_BUILT_IN_ELEMENT_GRAMMAR))
    return from_node(T, read_document(Decoder(bytes, tables; options, limits)))
end
