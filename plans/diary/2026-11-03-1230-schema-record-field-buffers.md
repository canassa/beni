# Schema record field buffers

Repeated end-to-end profiles put small List growth and the field traversal
among the library interpreter's costs. Its record loop now reads supplied
fields by offset and fills one typed array builder. It finishes the initialized
prefix once; errors still visit fields in order and never construct a partial
program value. The typed array operations are the existing core-private ones.

Four focused Schema fixture families passed twice, including generic/library
paths, construction errors, key handling and distinct endpoint identities.
Two serialized comparisons against the saved identity checkpoint reduced flat
library decode from about2000ns to1600ns and list decode from about2.0ms to1.6ms.
Encode and the compiled path had no consistent change. Exact paired samples
are in hostfree-review1/schema-cleanup/field-buffer on dagon.

Parity with the original workers base is still open; the remaining data boxing
and result wrappers need measurement next. No performance budget was raised.
