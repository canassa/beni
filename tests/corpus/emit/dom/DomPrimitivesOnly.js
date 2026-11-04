import { Rt$text, Rt$map } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomPrimitivesOnly$greeting = (name$1) => Rt$text(`hello ${name$1}`);
const DomPrimitivesOnly$tagged = (html$1) => Rt$map(html$1, String$fromInt);
export { DomPrimitivesOnly$greeting, DomPrimitivesOnly$tagged };
//# sourceMappingURL=DomPrimitivesOnly.mjs.map
