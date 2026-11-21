// Run in the beni-website hero with ?edit: play the entrance frame by frame (so every run lands on the
// same pose), then render the BENI wordmark alone on the transparent canvas, at 2x.
(async () => {
  const h = window.hero;
  h.set("render", false);                       // stop the page's own loop: frames are driven from here
  h.set("pixelRatio", 0.5);                     // cheap frames while the entrance plays out
  let t = 0;
  for (let i = 0; i < 240; i++) { t += 0.05; h.frame(0.05, t); }   // 12 s of animation
  h.set("dogMotion", false); h.set("sparks", false); h.set("pixelRatio", 2);
  h.set("letters", true); h.set("dog", false); h.frame(0, t);
  return h.renderer.domElement.toDataURL("image/png");
})()
