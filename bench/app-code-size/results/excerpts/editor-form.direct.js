// ew (dg782_0): 33 B raw
let ew = [ [ "6:1179" ], false, false, false ];
// fw (dp782_0): 124 B raw
let fw = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let d;
      if (c.$ === 0) d = c.b; else d = c.a;
      if (d !== a.a0) {
        a.a0 = d;
        a.w1.data = d;
      }
    }
  }
};
// gw (p782): 49 B raw
let gw = Uf((a, b) => b, (a, b) => {}, 1, [ Qf(ew, fw, null) ], true);
// hw (t782): 16 B raw
let hw = Ca("<li> ", 0);
// iw (k782): 101 B raw
let iw = {
  m: a => {
    let c = hw(), e = {
      s: c,
      q: null,
      e: c,
      w1: c.firstChild,
      a0: undefined,
      g0_0: NaN
    };
    gw(e, a);
    return e;
  },
  p: gw
};
// jw (dg804_0): 43 B raw
let jw = [ [ "$producer/6:1158" ], false, false, false ];
// kw (dp804_0): 172 B raw
let kw = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g0_0 = b;
      let d = {
        m: e => {
          let b = Vf([ e ], Lf("", "6:1175"));
          return iw.m(b);
        },
        p: (a, e) => {
          let b = Vf([ e ], Lf("", "6:1175"));
          iw.p(a, b);
        }
      };
      ab(a.c0, c, d, null);
    }
  }
};
// lw (dr804_0): 16 B raw
let lw = a => {
  Ia(a.c0);
};
// mw (dg804_1): 24 B raw
let mw = [ [], false, true, false ];
// nw (dp804_1): 123 B raw
let nw = (a, b) => {
  let d = b[1];
  {
    let b = d;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let c = () => ({
        $: 0,
        a: d,
        b: null
      });
      if (c !== a.a1) {
        a.a1 = c;
        a.w1.$$submit = c;
      }
    }
  }
};
// ow (dg804_2): 33 B raw
let ow = [ [ "6:1227" ], false, false, false ];
// pw (dp804_2): 87 B raw
let pw = (a, b) => {
  let e = b[2];
  {
    let b = e;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      Pe(a.w2, "disabled", b ? "" : null);
    }
  }
};
// qw (dg804_3): 33 B raw
let qw = [ [ "6:1260" ], false, false, false ];
// rw (dp804_3): 88 B raw
let rw = (a, b) => {
  let f = b[3];
  {
    let b = f.title;
    if (b !== a.g3_0) {
      a.g3_0 = b;
      tf(a.w4, "value", f.title);
    }
  }
};
// sw (dg804_4): 23 B raw
let sw = [ [], false, true, true ];
// tw (dp804_4): 109 B raw
let tw = (a, b) => {
  {
    if (a.g4 === undefined) {
      a.g4 = true;
      let b = a => ({
        $: 4,
        a: a,
        b: null
      });
      if (b !== a.a4) {
        a.a4 = b;
        a.w4.$$input = b;
      }
    }
  }
};
// uw (dg804_5): 33 B raw
let uw = [ [ "6:1303" ], false, false, false ];
// vw (dp804_5): 80 B raw
let vw = (a, b) => {
  let f = b[3];
  {
    let b = f.D;
    if (b !== a.g5_0) {
      a.g5_0 = b;
      tf(a.w6, "value", f.D);
    }
  }
};
// ww (dg804_6): 23 B raw
let ww = [ [], false, true, true ];
// xw (dp804_6): 109 B raw
let xw = (a, b) => {
  {
    if (a.g6 === undefined) {
      a.g6 = true;
      let b = a => ({
        $: 2,
        a: a,
        b: null
      });
      if (b !== a.a6) {
        a.a6 = b;
        a.w6.$$input = b;
      }
    }
  }
};
// yw (dg804_7): 33 B raw
let yw = [ [ "6:1351" ], false, false, false ];
// zw (dp804_7): 86 B raw
let zw = (a, b) => {
  let f = b[3];
  {
    let b = f.body;
    if (b !== a.g7_0) {
      a.g7_0 = b;
      tf(a.w8, "value", f.body);
    }
  }
};
// Aw (dg804_8): 23 B raw
let Aw = [ [], false, true, true ];
// Bw (dp804_8): 109 B raw
let Bw = (a, b) => {
  {
    if (a.g8 === undefined) {
      a.g8 = true;
      let b = a => ({
        $: 1,
        a: a,
        b: null
      });
      if (b !== a.a8) {
        a.a8 = b;
        a.w8.$$input = b;
      }
    }
  }
};
// Cw (dg804_9): 33 B raw
let Cw = [ [ "6:1394" ], false, false, false ];
// Dw (dp804_9): 81 B raw
let Dw = (a, b) => {
  let f = b[3];
  {
    let b = f.A;
    if (b !== a.g9_0) {
      a.g9_0 = b;
      tf(a.w10, "value", f.A);
    }
  }
};
// Ew (dg804_10): 23 B raw
let Ew = [ [], false, true, true ];
// Fw (dp804_10): 114 B raw
let Fw = (a, b) => {
  {
    if (a.g10 === undefined) {
      a.g10 = true;
      let b = a => ({
        $: 3,
        a: a,
        b: null
      });
      if (b !== a.a10) {
        a.a10 = b;
        a.w10.$$input = b;
      }
    }
  }
};
// Gw (dg804_11): 33 B raw
let Gw = [ [ "6:1419" ], false, false, false ];
// Hw (dp804_11): 72 B raw
let Hw = (a, b) => {
  let g = b[4];
  {
    let b = g;
    if (b !== a.g11_0) {
      a.g11_0 = b;
      a.w12.data = b;
    }
  }
};
// Iw (p804): 231 B raw
let Iw = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.w || a.c0.l;
}, 5, [ Qf(jw, kw, lw), Qf(mw, nw, null), Qf(ow, pw, null), Qf(qw, rw, null), Qf(sw, tw, null), Qf(uw, vw, null), Qf(ww, xw, null), Qf(yw, zw, null), Qf(Aw, Bw, null), Qf(Cw, Dw, null), Qf(Ew, Fw, null), Qf(Gw, Hw, null) ], false);
// Jw (t804): 613 B raw
let Jw = Ca('<ul class=error-messages></ul><form id=editor-form><fieldset><fieldset class=form-group><input id=title class="form-control form-control-lg"placeholder="Article Title"></fieldset><fieldset class=form-group><input id=description class=form-control placeholder="What\'s this article about?"></fieldset><fieldset class=form-group><textarea id=body class=form-control rows=8 placeholder="Write your article (in markdown)"></textarea></fieldset><fieldset class=form-group><input id=tags class=form-control placeholder="Enter tags"></fieldset><button class="btn btn-lg pull-xs-right btn-primary"> ', 4);
// Kw (k804): 780 B raw
let Kw = {
  m: (a, b) => {
    let c = Jw(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.firstChild, h = g.firstChild, i = g.nextSibling, j = i.firstChild, k = i.nextSibling, l = k.firstChild, m = k.nextSibling, n = m.firstChild, p = m.nextSibling.firstChild, q = Da(d, null, b);
    e.$$submitX = Se;
    ff(e, "submit", 1);
    if (b !== null) e.$$cx = b;
    h.$$inputX = Hn;
    ff(h, "input", 0);
    if (b !== null) h.$$cx = b;
    j.$$inputX = Hn;
    ff(j, "input", 0);
    if (b !== null) j.$$cx = b;
    l.$$inputX = Hn;
    ff(l, "input", 0);
    if (b !== null) l.$$cx = b;
    n.$$inputX = Hn;
    ff(n, "input", 0);
    if (b !== null) n.$$cx = b;
    let r = {
      s: d,
      q: null,
      e: e,
      w1: e,
      w2: f,
      w4: h,
      w6: j,
      w8: l,
      w10: n,
      w12: p,
      c0: q,
      a1: undefined,
      a4: undefined,
      a6: undefined,
      a8: undefined,
      a10: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g3_0: NaN,
      g4: undefined,
      g5_0: NaN,
      g6: undefined,
      g7_0: NaN,
      g8: undefined,
      g9_0: NaN,
      g10: undefined,
      g11_0: NaN
    };
    Iw(r, a);
    return r;
  },
  p: Iw,
  l: true
};
// Lw (t688): 14 B raw
let Lw = Ca("<!>", 0);
// Mw (k688): 55 B raw
let Mw = {
  m: () => {
    let c = Lw();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Nw (b688): 16 B raw
let Nw = {
  t: Mw,
  v: null
};
// Ow (t698): 37 B raw
let Ow = Ca("<p>Article failed to load.", 0);
// Pw (k698): 55 B raw
let Pw = {
  m: () => {
    let c = Ow();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Qw (b698): 16 B raw
let Qw = {
  t: Pw,
  v: null
};
// Rw (dg749_0): 33 B raw
let Rw = [ [ "6:1030" ], false, false, false ];
// Sw (dp749_0): 438 B raw
let Sw = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g0_0 = c.status;
      a.g0_1 = d;
      let b = Nf("/6:1030", () => {
        let a = c.status, b;
        e: {
          switch (a.$) {
           case 0:
            {
              b = Nw;
              break e;
            }

           case 1:
            {
              b = En;
              break e;
            }

           case 2:
            {
              b = Qw;
              break e;
            }

           case 3:
            {
              b = Tw(d, [], a.b, true, "Update Article");
              break e;
            }

           case 4:
            {
              b = Tw(d, a.b, a.c, false, "Update Article");
              break e;
            }

           case 5:
            {
              b = Tw(d, a.a, a.b, false, "Publish Article");
              break e;
            }

           default:
            {
              b = Tw(d, [], a.a, true, "Publish Article");
              break e;
            }
          }
        }
        return b;
      });
      Of("/6:1030", () => Ve(a.c0, b));
    }
  }
};
// Uw (dr749_0): 16 B raw
let Uw = a => {
  $e(a.c0);
};
// Vw (p749): 58 B raw
let Vw = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l;
}, 2, [ Qf(Rw, Sw, Uw) ], false);
// Ww (t749): 126 B raw
let Ww = Ca('<div class=editor-page><div class="container page"><div class=row><div class="col-md-10 offset-md-1 col-xs-12">', 0);
// Xw (k749): 145 B raw
let Xw = {
  m: (a, b) => {
    let c = Ww(), g = Da(c.firstChild.firstChild.firstChild, null, b), h = {
      s: c,
      q: null,
      e: c,
      c0: g,
      g0_0: NaN,
      g0_1: NaN
    };
    Vw(h, a);
    return h;
  },
  p: Vw,
  l: true
};
// Yw (t671): 43 B raw
let Yw = Ca("<p>Sign in to edit this article.", 0);
// Zw (k671): 55 B raw
let Zw = {
  m: () => {
    let c = Yw();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// $w (b671): 16 B raw
let $w = {
  t: Zw,
  v: null
};
// Tw (viewForm): 58 B raw
let Tw = (a, b, c, d, e) => ({
  t: Kw,
  v: Vf([ b, a, d, c, e ], Lf("", "6:1145"))
});
// gx (view): 241 B raw
let gx = a => {
  let b;
  c: {
    switch (a.status.$) {
     case 5:
      {
        b = "New Article";
        break c;
      }

     case 6:
      {
        b = "New Article";
        break c;
      }

     default:
      {
        b = "Edit Article";
        break c;
      }
    }
  }
  let d = Zf(a.g), e;
  if (d.$ === "Just") e = {
    t: Xw,
    v: Vf([ a, d.a ], Lf("", "6:994"))
  }; else e = $w;
  return {
    content: e,
    title: b
  };
};