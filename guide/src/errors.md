# When things go wrong

In this chapter you'll match an error to its usual cause and fix.

JExi fails loudly instead of guessing. Almost every error it throws is a
subtype of `JExi.ExiError`. The one exception is `JExi.XmlSyntaxError`, thrown
when XML text is not well-formed (for example in `encode_xml`). It is a plain
`Exception`, because the problem is in the XML, not in EXI.

| You see | Usually because | Fix |
|---|---|---|
| `UnsupportedError` | You asked for an EXI feature JExi does not have, such as compression. | Use strict options, bit-packed or byte-aligned. |
| `UnsupportedError` with "restricted character sets" | A value's string type has an `xs:pattern` that allows only a small alphabet, but JExi could not parse the pattern, so it does not know the alphabet EXI writes the characters against. A plain string would give bytes other readers turn into garbage. | Fix the pattern so it is a valid XSD regular expression, or, for tables written by `SchemaGen` before restricted character sets were supported, regenerate them. The rest of the schema keeps working. |
| `SchemaError` with "refused" | An `xs:include` or `xs:import` names a file outside the main schema's folder, a URL, a pipe or device, or a file over 16 MiB. | If you trust the schema set, set its top folder as the root with `load_options = SchemaLoadOptions(; root = ...)`. See [Untrusted schemas](untrusted-input.md#untrusted-schemas). |
| `SchemaError` with "schema too large" | One type's content would grow past 100,000 grammar rules: a huge `maxOccurs`, or groups that keep doubling. | If you trust the schema, raise `max_grammar_size` in `SchemaLoadOptions`. See [Untrusted schemas](untrusted-input.md#untrusted-schemas). |
| `UnsupportedError` with "wildcards" | The schema uses `xs:any` or `xs:anyAttribute` there, and the document uses it. JExi does not do wildcards yet. | If you control the schema, declare the elements and attributes. |
| `LimitError`, such as "decoder limit exceeded: nesting depth is over 256" | The stream asked for more than a decoder limit allows: very deep nesting, a huge list, a huge integer or too much text. | If you trust the input, raise that limit with `limits = DecodeLimits(...)`. See [Untrusted input](untrusted-input.md). |
| `GrammarError` | An [event](glossary.md#event) came where the schema does not allow it. | Check the order of elements, and put attributes first, sorted by name. |
| `ValueError` | A value does not fit its type, such as `"two"` for an integer. | Fix the value, or the schema. |
| `HeaderError("stream carries no options and none were given out of band")` | The stream has no options in its header, and you did not pass `options`. | Pass the same options the encoder used, or put them in the [header](glossary.md#header). |
| `SchemaIdError` | The stream's `schemaId` names another schema than the tables, says `xsi:nil` (no schema), or names one when the tables have no id. | Decode with the schema the stream names. If it is the right one, give the tables that id with `with_schema_id`. |
| Wrong values, `TruncatedError`, or other strange errors | The two sides used different schemas or options. | Use the same `.xsd` on both ends, and think about adding a `schema_id`. |

The error messages use the same words as the EXI spec, so you can look them up
in [EXI 1.0](https://www.w3.org/TR/exi/) when you need more detail.
