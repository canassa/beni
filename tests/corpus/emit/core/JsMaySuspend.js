const JsMaySuspend$direct = (f$1) => {
  f$1(null);
  return "directly";
};
const JsMaySuspend$start = (f$1) => JsMaySuspend$direct(f$1);
const JsMaySuspend$quick = () => JsMaySuspend$start(() => null);
const JsMaySuspend$quiet = () => null;
const JsMaySuspend$fixed = () => "quiet does not suspend";
export { JsMaySuspend$quick, JsMaySuspend$fixed };
//# sourceMappingURL=JsMaySuspend.mjs.map
