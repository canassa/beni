import { Js$Any$pack } from "./_core/Js/Any.mjs";
const AnyPacket$packet = ($m$0, $m$1, value$1, handler$2) => ({ t: 0, v: Js$Any$pack.$packet("(" + $m$0 + ",(" + $m$0 + "->" + $m$1 + "))", { a: value$1, b: handler$2 }) });
const AnyPacket$existing = (value$1) => Js$Any$pack("{a=core:Basics.Int,b=core:String.String}", value$1);
const AnyPacket$record = (value$1) => Js$Any$pack.$packet("{a=core:Basics.Int,b=core:String.String}", { a: value$1, b: "capture" });
export { AnyPacket$packet, AnyPacket$existing, AnyPacket$record };
//# sourceMappingURL=AnyPacket.mjs.map
