# Words you'll see

This page explains the EXI words the guide uses, so you can come back to it
whenever one is new.

## Schema

An XML Schema (an `.xsd` file) describes which elements and attributes a
document may have, in what order, and what type each value is. JExi needs one.

## Grammar, grammar tables

A **grammar** is the schema turned into rules for "what may come next" at each
point in a document. **Grammar tables** are all those rules in one value, made
by `JExi.compile_files`. The encoder and decoder both follow them.

## Event

One piece of a document: the start of the document or an element, an
attribute, some text, or an end. EXI writes a document as a list of events.

## Strict, non-strict

**Strict** mode allows only what the schema allows, which makes the output as
small as it can be. **Non-strict** mode also allows documents that stray from
the schema, at a cost in size. JExi does strict mode only.

## Header

The first few bits of every EXI stream. At its smallest it is one byte. It may
also hold a cookie and the options.

## Options

The settings that decide how the body is written, such as strict mode and
alignment. The decoder must know them to read the stream.

## Out of band

Agreed some other way, not written in the stream. Options sent out of band
live in a protocol spec, a config file or your code, on both ends.

## Cookie

The four bytes `$EXI` at the very start of a stream, so tools can spot the
format. It is optional.

## Bit-packed, byte-aligned

**Bit-packed** writes each item in as few bits as it needs, with no gaps. This
is the smallest. **Byte-aligned** starts each item on a new byte. It is a bit
bigger but easier to read in a hex dump.

## String table

EXI remembers each string it has written. When the same string comes again, it
writes a short number that points back to it, not the whole string.

## Text ("lexical") value

A value written as text, the way it looks in an XML file, such as `"42.95"`.
The EXI spec calls this the **lexical** form. JExi parses it into the schema's
type (here, a decimal) before writing it.

## Precompile

Julia can compile a package's code, and the constants in it, once when the
package is installed, not each time a program starts. Prebuilt grammar tables
use this to start fast.
