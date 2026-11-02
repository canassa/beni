# Keep HTTP native handles typed

HTTP now uses generated native operations for URL parsing, headers, multipart
bodies, fetch initialization, responses, byte streams, decoding, timeout
reasons and validation patterns. Flight state and promise results retain
those native types; callbacks resume a typed Step through Task.resume.

Cancellation aborts its request and stops its timer. Its own timeout reason
is distinct from cancellation. Outside an abort, only TypeError is a network
failure; unknown rejections are raised unchanged. The URL fallback catches
only TypeError, and regular-expression construction only SyntaxError.

Generated binding validation passed. The focused HTTP family passed 56
program runs in development and release, including cancellation, progress,
multipart, request shape, metadata and JSON. Behavioural goldens did not
change. This checkpoint keeps HostFree off while the other families migrate;
full gates and run hashes remain for default-on.
