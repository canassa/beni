const HostedMapJob$mapJob = (job$1, tag$2) => (send$3, $resume$1) => job$1((message$4) => send$3(tag$2(message$4)), $resume$1);
const HostedMapJob$beforeResult = (work$1, $resume$1) => {
  work$1(1);
  return work$1(2, $resume$1);
};
export { HostedMapJob$mapJob, HostedMapJob$beforeResult };
//# sourceMappingURL=HostedMapJob.mjs.map
