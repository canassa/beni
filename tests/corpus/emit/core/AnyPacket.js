import { Js$Any$pack } from "./_core/Js/Any.mjs";
const AnyPacket$packet = ($m$0, $m$1, value$1, handler$2) => ({ t: 0, v: { a: value$1, b: handler$2, [Js$Any$pack.$packet.key]: "(" + $m$0 + ",(" + $m$0 + "->" + $m$1 + "))" } });
const AnyPacket$existing = (value$1) => Js$Any$pack("{a=core:Basics.Int,b=core:String.String}", value$1);
const AnyPacket$record$$packet$1 = { [Js$Any$pack.$packet.key]: "{a=core:Basics.Int,b=core:String.String}", a: undefined, b: undefined };
const AnyPacket$record = (value$1) => ({ ...AnyPacket$record$$packet$1, a: value$1, b: "capture" });
const AnyPacket$updated = (value$1, number$2) => Js$Any$pack("{a=core:Basics.Int,b=core:String.String}", { ...value$1, a: number$2 });
const AnyPacket$make = (number$1) => ({ a: number$1, b: "capture" });
const AnyPacket$called = (number$1) => Js$Any$pack("{a=core:Basics.Int,b=core:String.String}", AnyPacket$make(number$1));
export { AnyPacket$packet, AnyPacket$existing, AnyPacket$record, AnyPacket$updated, AnyPacket$called };
//# sourceMappingURL=AnyPacket.mjs.map
