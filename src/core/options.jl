# EXI options (https://www.w3.org/TR/exi/#options) and the header settings.

"""How values are laid out in the body (https://www.w3.org/TR/exi/#key-alignmentOption)."""
@enum Alignment::UInt8 ALIGN_BIT_PACKED ALIGN_BYTE_ALIGNED ALIGN_PRE_COMPRESSION

"""Which parts of the XML the stream keeps (https://www.w3.org/TR/exi/#fidelityOptions)."""
Base.@kwdef struct Preserve
    dtd::Bool = false
    prefixes::Bool = false
    lexical_values::Bool = false
    comments::Bool = false
    pis::Bool = false
end

any_preserve(p::Preserve) = p.dtd || p.prefixes || p.lexical_values || p.comments || p.pis

"""The `schemaId` option set to `xsi:nil="true"` (https://www.w3.org/TR/exi/#key-schemaIdOption)."""
struct SchemaIdNil end
const SCHEMA_ID_NIL = SchemaIdNil()

"""
    ExiOptions(; alignment, compression, strict, fragment, preserve, self_contained,
               value_max_length, value_partition_capacity, block_size, schema_id,
               datatype_representation_map)

The EXI options. `schema_id` is `nothing` (absent), [`SCHEMA_ID_NIL`](@ref), or
a string (`""` is the empty schemaId). The two value limits are `nothing` when
unbounded. [`strict_options`](@ref) gives the profile JExi targets.
"""
Base.@kwdef struct ExiOptions
    alignment::Alignment = ALIGN_BIT_PACKED
    compression::Bool = false
    strict::Bool = false
    fragment::Bool = false
    preserve::Preserve = Preserve()
    self_contained::Bool = false
    value_max_length::Union{Nothing,UInt32} = nothing
    value_partition_capacity::Union{Nothing,UInt32} = nothing
    block_size::Union{Nothing,UInt32} = nothing
    schema_id::Union{Nothing,SchemaIdNil,String} = nothing
    datatype_representation_map::Bool = false
end

"""
    SchemaIdError(stream, tables)

The stream's `schemaId` option does not name the schema of the grammar tables
it is decoded with (https://www.w3.org/TR/exi/#key-schemaIdOption). `stream` is
what the options say ([`SCHEMA_ID_NIL`](@ref) or a string), and `tables` the
tables' own id (`nothing` if they have none). See [`check_schema_id`](@ref).
"""
struct SchemaIdError <: ExiError
    stream::Union{SchemaIdNil,String}
    tables::Union{Nothing,String}
end

function Base.showerror(io::IO, e::SchemaIdError)
    print(io, "schemaId mismatch: the stream names ")
    s = e.stream
    print(io, s isa SchemaIdNil ? "no schema (nil)" : isempty(s) ? "the built-in types (\"\")" : repr(s))
    print(io, e.tables === nothing ? ", the grammar has no schemaId" : ", the grammar is " * repr(e.tables))
end

"""
    check_schema_id(stream, tables)

Checks a stream's `schemaId` option (`nothing`, [`SCHEMA_ID_NIL`](@ref) or a
string) against the `schemaId` of the tables that will decode it (`nothing` or
a string), and throws a [`SchemaIdError`](@ref) if they do not match:

- absent (`nothing`): the schema was agreed out of band; nothing to check.
- `xsi:nil="true"` (no schema, built-in grammars): always refused, because
  JExi's tables are schema-informed.
- `""` (built-in types only) and any other value: the tables' id must be
  exactly that string. Tables with no id are refused, because a stream that
  names its schema cannot be checked against tables that do not.

rexi applies the same rule (`rexi_core::header::check_schema_id`).
"""
function check_schema_id(stream::Union{Nothing,SchemaIdNil,String}, tables::Union{Nothing,String})
    stream === nothing && return nothing
    stream isa String && stream == tables && return nothing
    throw(SchemaIdError(stream, tables))
end

"""Strict options with everything else at its default; keywords change other fields."""
strict_options(; kw...) = ExiOptions(; strict = true, kw...)

function Base.:(==)(a::ExiOptions, b::ExiOptions)
    return all(getfield(a, f) == getfield(b, f) for f in fieldnames(ExiOptions))
end

"""
    validate_options(opts)

Throws for any option JExi does not support (an [`UnsupportedError`](@ref)) and
for combinations the spec forbids (a [`HeaderError`](@ref)).
"""
function validate_options(o::ExiOptions)
    o.compression && throw(UnsupportedError(FEATURE_COMPRESSION))
    o.alignment == ALIGN_PRE_COMPRESSION && throw(UnsupportedError(FEATURE_PRE_COMPRESSION))
    o.self_contained && throw(UnsupportedError(FEATURE_SELF_CONTAINED))
    o.datatype_representation_map && throw(UnsupportedError(FEATURE_DATATYPE_REPRESENTATION_MAP))
    o.fragment && throw(UnsupportedError(FEATURE_FRAGMENT))
    p = o.preserve
    if o.strict && (p.dtd || p.prefixes || p.comments || p.pis)
        throw(HeaderError("strict cannot be combined with Preserve.dtd/prefixes/comments/pis"))
    end
    p.dtd && throw(UnsupportedError(FEATURE_PRESERVE_DTD))
    p.prefixes && throw(UnsupportedError(FEATURE_PRESERVE_PREFIXES))
    p.comments && throw(UnsupportedError(FEATURE_PRESERVE_COMMENTS))
    p.pis && throw(UnsupportedError(FEATURE_PRESERVE_PIS))
    p.lexical_values && throw(UnsupportedError(FEATURE_PRESERVE_LEXICAL_VALUES))
    o.strict || throw(UnsupportedError(FEATURE_NON_STRICT_SCHEMA_INFORMED))
    return nothing
end

is_byte_aligned(o::ExiOptions) = o.alignment != ALIGN_BIT_PACKED

"""
    HeaderConfig(; cookie = false, include_options = false)

What the EXI header carries: the `\$EXI` cookie, and the options document (when
`false`, the options must be agreed out of band).
"""
Base.@kwdef struct HeaderConfig
    cookie::Bool = false
    include_options::Bool = false
end
