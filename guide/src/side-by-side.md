# JExi and rexi side by side

This page helps you move between JExi and rexi, its Rust twin.

Each example in `jexi/examples/basics` has a
twin in `rexi/examples/basics` that prints exactly the same output. rexi's
`examples/basics/compare.sh` runs both and checks.

| Task | JExi (Julia) | rexi (Rust) |
|---|---|---|
| Compile a schema | `JExi.compile_files(path)` | `rexi_schema::compile_files(&[path])` |
| Strict options | `JExi.strict_options()` | `ExiOptions::strict()` |
| Change an option | `strict_options(; alignment = JExi.ALIGN_BYTE_ALIGNED)` | `.with_alignment(Alignment::ByteAligned)` |
| Header settings | `HeaderConfig(; cookie = true, include_options = true)` | `HeaderConfig::new().with_cookie(true).with_include_options(true)` |
| XML to EXI | `JExi.encode_xml(xml, tables; options, header)` | `rexi_xml::encode_xml(xml, tables, &opts, header)` |
| EXI to XML | `JExi.decode_to_xml(bytes, tables; options)` | `rexi_xml::decode_to_xml(bytes, tables, Some(opts))` |
| Read events | `for ev in dec` | `while let Some(ev) = dec.next_event()?` |
| Write events | `JExi.start_element!(enc, ns, name)` | `enc.start_element(ns, name)?` |
| Text to parse | `JExi.Lexical("42.95")` | `Value::Lexical("42.95")` |
| Structs | `JExi.to_exi` / `from_exi` with `exi_names` | `rexi_serde::to_exi` / `from_exi` with serde |
| Prebuilt tables | `JExi.SchemaGen.generate` | `rexi-schema-gen` command |
| Errors | Exceptions such as `UnsupportedError` | `Result` with `ExiError` |

rexi also has things JExi does not: `no_std` and fixed buffers for small devices,
streaming from any `Read`/`Write`, and a C API.
