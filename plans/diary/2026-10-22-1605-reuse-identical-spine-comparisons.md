# Reuse identical spine comparisons

Refreshing the ownership audit exposed the existing tuple-only depth-32
fixture under the hidden flag. Its smaller tuple DAG also revisits identical
separation operands through many paths (#753).

Annotation instantiation now compares each cell and approximation once and
reuses the resulting conjunction for identical selected cells. Every result
path still gets its own guard. The last approximation is retained in the
original traversal order, including when an operand repeats. No path fact,
condition, cap or budget is discarded or changed.

The reduced tuple case is a `node+everywhere` corpus fixture. Both it and the
existing depth-32 program check with the candidate. No performance or size
measurements were made. The separate experimental type-growth memoization was
dropped; it is not part of this change.
