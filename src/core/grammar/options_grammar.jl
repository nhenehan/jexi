# The grammar tables of the EXI Options document (spec Appendix C), used to code the
# options in a header (https://www.w3.org/TR/exi/#options). Converted once from rexi's
# hand-built OPTIONS_GRAMMARS (rexi-core/src/grammar/options_grammar.rs); the schema
# compiler test checks it against the compiled Appendix C schema. As in EXIficient, all
# types are not typecastable and only schemaId is nillable.

const EXI_OPTIONS_NS = "http://www.w3.org/2009/exi"
const EXI_URI = UriId(4)

const OPTIONS_GRAMMARS = GrammarSet(
    String["", "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2001/XMLSchema-instance", "http://www.w3.org/2001/XMLSchema", "http://www.w3.org/2009/exi", "xml", "xsi", "base", "id", "lang", "space", "nil", "type", "ENTITIES", "ENTITY", "ID", "IDREF", "IDREFS", "NCName", "NMTOKEN", "NMTOKENS", "NOTATION", "Name", "QName", "anySimpleType", "anyType", "anyURI", "base64Binary", "boolean", "byte", "date", "dateTime", "decimal", "double", "duration", "float", "gDay", "gMonth", "gMonthDay", "gYear", "gYearMonth", "hexBinary", "int", "integer", "language", "long", "negativeInteger", "nonNegativeInteger", "nonPositiveInteger", "normalizedString", "positiveInteger", "short", "string", "time", "token", "unsignedByte", "unsignedInt", "unsignedLong", "unsignedShort", "alignment", "blockSize", "comments", "common", "compression", "datatypeRepresentationMap", "dtd", "fragment", "header", "ieeeBinary32", "ieeeBinary64", "lesscommon", "lexicalValues", "pis", "pre-compress", "prefixes", "preserve", "schemaId", "selfContained", "strict", "uncommon", "valueMaxLength", "valuePartitionCapacity"],
    UriEntry[UriEntry(0, Span(0, 1), Span(0, 0)), UriEntry(1, Span(1, 1), Span(0, 4)), UriEntry(2, Span(2, 1), Span(4, 2)), UriEntry(3, Span(3, 0), Span(6, 46)), UriEntry(4, Span(3, 0), Span(52, 39))],
    StrIdx[0, 5, 6],
    StrIdx[7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 27, 60, 28, 29, 61, 62, 63, 64, 30, 31, 32, 33, 65, 66, 36, 37, 38, 39, 40, 67, 41, 68, 69, 43, 70, 71, 72, 73, 74, 75, 76, 77, 78, 52, 53, 79, 80, 81],
    Production[Production(term_se(1), 1), Production(term_se(17), 2), Production(term_se(21), 3), Production(Terminal(T_EE), NONE), Production(term_se(17), 2), Production(term_se(21), 3), Production(Terminal(T_EE), NONE), Production(term_se(21), 3), Production(Terminal(T_EE), NONE), Production(Terminal(T_EE), NONE), Production(term_se(2), 5), Production(term_se(10), 6), Production(term_se(16), 7), Production(Terminal(T_EE), NONE), Production(term_se(10), 6), Production(term_se(16), 7), Production(Terminal(T_EE), NONE), Production(term_se(16), 7), Production(Terminal(T_EE), NONE), Production(Terminal(T_EE), NONE), Production(term_se(3), 9), Production(term_se(6), 10), Production(term_se(7), 11), Production(term_se(8), 12), Production(term_se(9), 13), Production(Terminal(T_SE_ANY), 8), Production(Terminal(T_EE), NONE), Production(term_se(6), 10), Production(term_se(7), 11), Production(term_se(8), 12), Production(term_se(9), 13), Production(Terminal(T_EE), NONE), Production(term_se(7), 11), Production(term_se(8), 12), Production(term_se(9), 13), Production(Terminal(T_EE), NONE), Production(term_se(8), 12), Production(term_se(9), 13), Production(Terminal(T_EE), NONE), Production(term_se(9), 13), Production(Terminal(T_EE), NONE), Production(term_se(9), 13), Production(Terminal(T_EE), NONE), Production(term_se(4), 15), Production(term_se(5), 15), Production(Terminal(T_EE), NONE), Production(Terminal(T_EE), NONE), Production(term_ch(5), 18), Production(Terminal(T_EE), NONE), Production(Terminal(T_SE_ANY), 20), Production(Terminal(T_SE_ANY), 21), Production(Terminal(T_EE), NONE), Production(term_se(11), 23), Production(term_se(12), 24), Production(term_se(13), 25), Production(term_se(14), 26), Production(term_se(15), 27), Production(Terminal(T_EE), NONE), Production(term_se(12), 24), Production(term_se(13), 25), Production(term_se(14), 26), Production(term_se(15), 27), Production(Terminal(T_EE), NONE), Production(term_se(13), 25), Production(term_se(14), 26), Production(term_se(15), 27), Production(Terminal(T_EE), NONE), Production(term_se(14), 26), Production(term_se(15), 27), Production(Terminal(T_EE), NONE), Production(term_se(15), 27), Production(Terminal(T_EE), NONE), Production(Terminal(T_EE), NONE), Production(term_se(18), 29), Production(term_se(19), 30), Production(term_se(20), 31), Production(Terminal(T_EE), NONE), Production(term_se(19), 30), Production(term_se(20), 31), Production(Terminal(T_EE), NONE), Production(term_se(20), 31), Production(Terminal(T_EE), NONE), Production(Terminal(T_EE), NONE), Production(term_ch(9), 33), Production(Terminal(T_EE), NONE)],
    Rule[Rule(Span(0, 4)), Rule(Span(4, 3)), Rule(Span(7, 2)), Rule(Span(9, 1)), Rule(Span(10, 4)), Rule(Span(14, 3)), Rule(Span(17, 2)), Rule(Span(19, 1)), Rule(Span(20, 7)), Rule(Span(27, 5)), Rule(Span(32, 4)), Rule(Span(36, 3)), Rule(Span(39, 2)), Rule(Span(41, 2)), Rule(Span(43, 2)), Rule(Span(45, 1)), Rule(Span(46, 1)), Rule(Span(47, 1)), Rule(Span(48, 1)), Rule(Span(49, 1)), Rule(Span(50, 1)), Rule(Span(51, 1)), Rule(Span(52, 6)), Rule(Span(58, 5)), Rule(Span(63, 4)), Rule(Span(67, 3)), Rule(Span(70, 2)), Rule(Span(72, 1)), Rule(Span(73, 4)), Rule(Span(77, 3)), Rule(Span(80, 2)), Rule(Span(82, 1)), Rule(Span(83, 1)), Rule(Span(84, 1))],
    Grammar[Grammar(Span(0, 4)), Grammar(Span(4, 4)), Grammar(Span(8, 6)), Grammar(Span(14, 2)), Grammar(Span(16, 1)), Grammar(Span(17, 2)), Grammar(Span(19, 3)), Grammar(Span(22, 6)), Grammar(Span(28, 4)), Grammar(Span(32, 2))],
    ElementDecl[ElementDecl(QNameId(4, 20), 0, false, true), ElementDecl(QNameId(4, 25), 1, false, false), ElementDecl(QNameId(4, 36), 2, false, false), ElementDecl(QNameId(4, 0), 3, false, false), ElementDecl(QNameId(4, 4), 4, false, false), ElementDecl(QNameId(4, 28), 4, false, false), ElementDecl(QNameId(4, 32), 4, false, false), ElementDecl(QNameId(4, 37), 5, false, false), ElementDecl(QNameId(4, 38), 5, false, false), ElementDecl(QNameId(4, 8), 6, false, false), ElementDecl(QNameId(4, 30), 7, false, false), ElementDecl(QNameId(4, 13), 4, false, false), ElementDecl(QNameId(4, 29), 4, false, false), ElementDecl(QNameId(4, 26), 4, false, false), ElementDecl(QNameId(4, 5), 4, false, false), ElementDecl(QNameId(4, 27), 4, false, false), ElementDecl(QNameId(4, 2), 5, false, false), ElementDecl(QNameId(4, 6), 8, false, false), ElementDecl(QNameId(4, 7), 4, false, false), ElementDecl(QNameId(4, 14), 4, false, false), ElementDecl(QNameId(4, 31), 9, true, false), ElementDecl(QNameId(4, 33), 4, false, false)],
    ElemIdx[0],
    GlobalAttribute[],
    TypeDecl[TypeDecl(QNameId(NONE, 0), 0, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 1, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 2, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 3, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 4, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 5, 4, UNSIGNED_KIND, true, false), TypeDecl(QNameId(NONE, 0), 6, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 7, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 8, 4, UNTYPED_KIND, false, false), TypeDecl(QNameId(NONE, 0), 9, 4, string_kind(WS_PRESERVE), true, false)],
    Span[],
    StrIdx[],
    "http://www.w3.org/2009/exi",
)

# Local-name ids of the options elements in the exi partition (sorted by code point).
const OPT_LN_HEADER = LocalId(20)
const OPT_LN_LESSCOMMON = LocalId(25)
const OPT_LN_UNCOMMON = LocalId(36)
const OPT_LN_ALIGNMENT = LocalId(0)
const OPT_LN_BYTE = LocalId(4)
const OPT_LN_PRE_COMPRESS = LocalId(28)
const OPT_LN_SELFCONTAINED = LocalId(32)
const OPT_LN_VALUEMAXLENGTH = LocalId(37)
const OPT_LN_VALUEPARTITIONCAPACITY = LocalId(38)
const OPT_LN_DATATYPEREPRESENTATIONMAP = LocalId(8)
const OPT_LN_PRESERVE = LocalId(30)
const OPT_LN_DTD = LocalId(13)
const OPT_LN_PREFIXES = LocalId(29)
const OPT_LN_LEXICALVALUES = LocalId(26)
const OPT_LN_COMMENTS = LocalId(5)
const OPT_LN_PIS = LocalId(27)
const OPT_LN_BLOCKSIZE = LocalId(2)
const OPT_LN_COMMON = LocalId(6)
const OPT_LN_COMPRESSION = LocalId(7)
const OPT_LN_FRAGMENT = LocalId(14)
const OPT_LN_SCHEMAID = LocalId(31)
const OPT_LN_STRICT = LocalId(33)
