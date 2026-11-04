// Trusted paired endpoints: the nominal node owns the callback and accepts
// the matching opaque payload. No program value is cast through Js.Value.
export const root = () => ({$$root: () => {console.log('sent'); return null;}});
export const payload = () => null;
