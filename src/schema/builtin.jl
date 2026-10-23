# The 46 XSD built-in types (rexi-schema builtin.rs), in the order of their
# names in the XSD partition of the string table (spec D.3), with each one's
# base and the datatype family it belongs to
# (https://www.w3.org/TR/exi/#builtInEXITypes).

abstract type Category end
struct CatAnyType <: Category end
struct CatString <: Category
    ws::WhiteSpace
end
struct CatBoolean <: Category end
struct CatDecimal <: Category end
struct CatFloat <: Category end
struct CatDateTime <: Category
    kind::DateTimeKind
end
struct CatBase64 <: Category end
struct CatHex <: Category end
struct CatInteger <: Category
    min::Union{Nothing,Int128}
    max::Union{Nothing,Int128}
end
struct CatList <: Category
    item::Int
end

struct Builtin
    name::String
    base::Union{Nothing,Int}
    category::Category
end

const BUILTIN_COUNT = 46

builtin_index(local_name::AbstractString) = (i = findfirst(==(local_name), XSD_LOCAL_NAMES); i === nothing ? nothing : i - 1)
lookup_builtin(ns::AbstractString, local_name::AbstractString) = ns == XSD_NS ? builtin_index(local_name) : nothing

const ANY_TYPE = 12
const ANY_SIMPLE_TYPE = 11
const STRING_TYPE = 39
const INTEGER_TYPE = 30
const QNAME_TYPE = 10
const NOTATION_TYPE = 8

bidx(name) = builtin_index(name)::Int

const BUILTINS = let
    S(ws) = CatString(ws)
    int(lo, hi) = CatInteger(lo === nothing ? nothing : Int128(lo), hi === nothing ? nothing : Int128(hi))
    b(name, base, cat) = Builtin(name, base === nothing ? nothing : bidx(base), cat)
    [
        b("ENTITIES", "anySimpleType", CatList(bidx("ENTITY"))),
        b("ENTITY", "NCName", S(WS_COLLAPSE)),
        b("ID", "NCName", S(WS_COLLAPSE)),
        b("IDREF", "NCName", S(WS_COLLAPSE)),
        b("IDREFS", "anySimpleType", CatList(bidx("IDREF"))),
        b("NCName", "Name", S(WS_COLLAPSE)),
        b("NMTOKEN", "token", S(WS_COLLAPSE)),
        b("NMTOKENS", "anySimpleType", CatList(bidx("NMTOKEN"))),
        b("NOTATION", "anySimpleType", S(WS_COLLAPSE)),
        b("Name", "token", S(WS_COLLAPSE)),
        b("QName", "anySimpleType", S(WS_COLLAPSE)),
        b("anySimpleType", "anyType", S(WS_PRESERVE)),
        b("anyType", nothing, CatAnyType()),
        b("anyURI", "anySimpleType", S(WS_COLLAPSE)),
        b("base64Binary", "anySimpleType", CatBase64()),
        b("boolean", "anySimpleType", CatBoolean()),
        b("byte", "short", int(-128, 127)),
        b("date", "anySimpleType", CatDateTime(DTK_DATE)),
        b("dateTime", "anySimpleType", CatDateTime(DTK_DATETIME)),
        b("decimal", "anySimpleType", CatDecimal()),
        b("double", "anySimpleType", CatFloat()),
        b("duration", "anySimpleType", S(WS_COLLAPSE)),
        b("float", "anySimpleType", CatFloat()),
        b("gDay", "anySimpleType", CatDateTime(DTK_GDAY)),
        b("gMonth", "anySimpleType", CatDateTime(DTK_GMONTH)),
        b("gMonthDay", "anySimpleType", CatDateTime(DTK_GMONTHDAY)),
        b("gYear", "anySimpleType", CatDateTime(DTK_GYEAR)),
        b("gYearMonth", "anySimpleType", CatDateTime(DTK_GYEARMONTH)),
        b("hexBinary", "anySimpleType", CatHex()),
        b("int", "long", int(-2_147_483_648, 2_147_483_647)),
        b("integer", "decimal", int(nothing, nothing)),
        b("language", "token", S(WS_COLLAPSE)),
        b("long", "integer", int(typemin(Int64), typemax(Int64))),
        b("negativeInteger", "nonPositiveInteger", int(nothing, -1)),
        b("nonNegativeInteger", "integer", int(0, nothing)),
        b("nonPositiveInteger", "integer", int(nothing, 0)),
        b("normalizedString", "string", S(WS_REPLACE)),
        b("positiveInteger", "nonNegativeInteger", int(1, nothing)),
        b("short", "int", int(-32768, 32767)),
        b("string", "anySimpleType", S(WS_PRESERVE)),
        b("time", "anySimpleType", CatDateTime(DTK_TIME)),
        b("token", "normalizedString", S(WS_COLLAPSE)),
        b("unsignedByte", "unsignedShort", int(0, 255)),
        b("unsignedInt", "unsignedLong", int(0, 4_294_967_295)),
        b("unsignedLong", "nonNegativeInteger", int(0, typemax(UInt64))),
        b("unsignedShort", "unsignedInt", int(0, 65535)),
    ]
end
