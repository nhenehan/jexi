# Errors shared by every layer of JExi. Each failure is its own exception type
# under `ExiError`, in the place of rexi's `ExiError` enum.

"""
    Feature

An EXI feature JExi does not implement, on purpose. When one of these shows up
it is always reported as an [`UnsupportedError`]; it is never quietly ignored.
"""
@enum Feature::UInt8 begin
    # EXI compression (https://www.w3.org/TR/exi/#compression).
    FEATURE_COMPRESSION
    # Pre-compression alignment (https://www.w3.org/TR/exi/#options).
    FEATURE_PRE_COMPRESSION
    # Self-contained elements, SC (https://www.w3.org/TR/exi/#addingProductions).
    FEATURE_SELF_CONTAINED
    # User-defined value forms (https://www.w3.org/TR/exi/#datatypeRepresentationMap).
    FEATURE_DATATYPE_REPRESENTATION_MAP
    # Restricted character sets from xsd:pattern
    # (https://www.w3.org/TR/exi/#restrictedCharSet).
    FEATURE_RESTRICTED_CHARACTER_SET
    # Several root elements in one body (https://www.w3.org/TR/exi/#informedFragGrammars).
    FEATURE_FRAGMENT
    # Grammars used when there is no schema; they "learn" new productions
    # (https://www.w3.org/TR/exi/#builtinElemGrammars).
    FEATURE_BUILT_IN_ELEMENT_GRAMMAR
    # The extra productions of non-strict grammars
    # (https://www.w3.org/TR/exi/#addingProductions).
    FEATURE_NON_STRICT_SCHEMA_INFORMED
    FEATURE_PRESERVE_DTD
    FEATURE_PRESERVE_PREFIXES
    FEATURE_PRESERVE_COMMENTS
    FEATURE_PRESERVE_PIS
    FEATURE_PRESERVE_LEXICAL_VALUES
    FEATURE_ENTITY_REFERENCE
    # Format versions other than final version 1 (https://www.w3.org/TR/exi/#version).
    FEATURE_FORMAT_VERSION
    # Wildcards inside an element: xs:any (SE(*), SE(uri:*)) and xs:anyAttribute
    # (AT(*), AT(uri:*)) (https://www.w3.org/TR/exi/#elementTerms). They are strict,
    # schema-declared productions, not a non-strict feature; they are just not
    # implemented yet. An undeclared root element is FEATURE_BUILT_IN_ELEMENT_GRAMMAR.
    FEATURE_WILDCARD
end

const FEATURE_NAMES = Dict{Feature,String}(
    FEATURE_COMPRESSION => "compression",
    FEATURE_PRE_COMPRESSION => "pre-compression alignment",
    FEATURE_SELF_CONTAINED => "selfContained",
    FEATURE_DATATYPE_REPRESENTATION_MAP => "datatypeRepresentationMap",
    FEATURE_RESTRICTED_CHARACTER_SET => "restricted character sets",
    FEATURE_FRAGMENT => "fragment grammars",
    FEATURE_BUILT_IN_ELEMENT_GRAMMAR => "built-in (schema-less) element grammars",
    FEATURE_NON_STRICT_SCHEMA_INFORMED => "non-strict schema-informed grammars",
    FEATURE_PRESERVE_DTD => "Preserve.dtd",
    FEATURE_PRESERVE_PREFIXES => "Preserve.prefixes",
    FEATURE_PRESERVE_COMMENTS => "Preserve.comments",
    FEATURE_PRESERVE_PIS => "Preserve.pis",
    FEATURE_PRESERVE_LEXICAL_VALUES => "Preserve.lexicalValues",
    FEATURE_ENTITY_REFERENCE => "entity references",
    FEATURE_FORMAT_VERSION => "EXI format versions other than 1",
    FEATURE_WILDCARD => "wildcards (xs:any, xs:anyAttribute)",
)

feature_name(f::Feature) = FEATURE_NAMES[f]

"""
    ExiError

The parent type of every failure JExi reports.
"""
abstract type ExiError <: Exception end

"""The stream ended before the decoder finished."""
struct TruncatedError <: ExiError end

"""The EXI header is badly formed."""
struct HeaderError <: ExiError
    msg::String
end

"""A feature documented as not supported, on purpose, was asked for or found."""
struct UnsupportedError <: ExiError
    feature::Feature
end

"""The event does not match any production of the current grammar rule."""
struct GrammarError <: ExiError
    # The events the rule allows here.
    expected::String
    # The event that was given or found.
    got::String
end

"""A value cannot be written in the datatype the grammar calls for."""
struct ValueError <: ExiError
    # Name of the datatype, for example "Integer".
    datatype::String
    # Why the value does not fit.
    reason::String
end

"""The string table does not add up, or a compact identifier is out of range."""
struct StringTableError <: ExiError
    msg::String
end

"""The grammar tables are not usable (for example a schema problem)."""
struct SchemaError <: ExiError
    msg::String
end

"""A bug in JExi: a state that should never happen."""
struct InternalError <: ExiError
    msg::String
end

Base.showerror(io::IO, ::TruncatedError) = print(io, "EXI stream is truncated")
Base.showerror(io::IO, e::HeaderError) = print(io, "bad EXI header: ", e.msg)
Base.showerror(io::IO, e::UnsupportedError) =
    print(io, "not supported: ", feature_name(e.feature))
Base.showerror(io::IO, e::GrammarError) =
    print(io, "grammar mismatch: expected ", e.expected, ", got ", e.got)
Base.showerror(io::IO, e::ValueError) =
    print(io, "bad ", e.datatype, " value: ", e.reason)
Base.showerror(io::IO, e::StringTableError) = print(io, "string table: ", e.msg)
Base.showerror(io::IO, e::SchemaError) = print(io, "schema: ", e.msg)
Base.showerror(io::IO, e::InternalError) = print(io, "internal error: ", e.msg)
