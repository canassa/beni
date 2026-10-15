// $l (dg149_0): 33 B raw
let $l = [ [ "11:357" ], false, false, false ];
// _l (dp149_0): 155 B raw
let _l = (a, b) => {
  let c = b[0], d = b[1];
  {
    if (c !== a.g0_0 || d !== a.g0_1) {
      a.g0_0 = c;
      a.g0_1 = d;
      let b = am(c, d) && d.$ !== 0;
      if (b !== a.a0) {
        a.a0 = b;
        a.w0.classList.toggle("active", b);
      }
    }
  }
};
// bm (dg149_1): 33 B raw
let bm = [ [ "11:393" ], false, false, false ];
// cm (dp149_1): 122 B raw
let cm = (a, b) => {
  let e = b[2];
  {
    let b = e;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let c = tj(e);
      if (c !== a.a1) {
        a.w1.setAttribute("href", Re(c));
        a.a1 = c;
      }
    }
  }
};
// dm (dg149_2): 33 B raw
let dm = [ [ "11:400" ], false, false, false ];
// em (dp149_2): 69 B raw
let em = (a, b) => {
  let f = b[3];
  {
    let b = f;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      a.w2.data = b;
    }
  }
};
// fm (p149): 80 B raw
let fm = Uf((a, b) => b, (a, b) => {}, 4, [ Qf($l, _l, null), Qf(bm, cm, null), Qf(dm, em, null) ], false);
// gm (t149): 49 B raw
let gm = Ca("<li class=nav-item><a class=nav-link> ", 0);
// hm (k149): 162 B raw
let hm = {
  m: a => {
    let c = gm(), d = c.firstChild, f = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w1: d,
      w2: d.firstChild,
      a0: false,
      a1: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    fm(f, a);
    return f;
  },
  p: fm
};
// im (dg118_0): 32 B raw
let im = [ [ "11:152" ], false, false, true ];
// jm (dp118_0): 111 B raw
let jm = (a, b) => {
  {
    if (a.g0 === undefined) {
      a.g0 = true;
      let b = tj(Tl);
      if (b !== a.a0) {
        a.w2.setAttribute("href", Re(b));
        a.a0 = b;
      }
    }
  }
};
// km (dg118_1): 33 B raw
let km = [ [ "11:173" ], false, false, false ];
// lm (dp118_1): 118 B raw
let lm = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g1_0 = b;
      {
        a.a1_0 = c;
        Of("/11:173", () => Ve(a.c1, Nf("/11:173", () => mm(c, Ol, Tl, "Home"))));
      }
    }
  }
};
// nm (dr118_1): 16 B raw
let nm = a => {
  $e(a.c1);
};
// om (dg98_0): 51 B raw
let om = [ [ "11:198", "11:208", "11:285" ], false, false, false ];
// pm (dp98_0): 281 B raw
let pm = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g0_0 = b;
      {
        a.a0_0 = c;
        Of("/11:198", () => Ve(a.c0, Nf("/11:198", () => mm(c, Ql, Wl, "New Article"))));
      }
      {
        a.a1_0 = c;
        Of("/11:208", () => Ve(a.c1, Nf("/11:208", () => mm(c, Zl, Yl, "Settings"))));
      }
      {
        a.a6_0 = c;
        Of("/11:285", () => Ve(a.c6, Nf("/11:285", () => mm(c, Rl, Vl, "Sign out"))));
      }
    }
  }
};
// qm (dr98_0): 34 B raw
let qm = a => {
  $e(a.c0);
  $e(a.c1);
  $e(a.c6);
};
// rm (dg98_1): 33 B raw
let rm = [ [ "11:220" ], false, false, false ];
// sm (dp98_1): 155 B raw
let sm = (a, b) => {
  let c = b[0], d = b[1];
  {
    if (c !== a.g1_0 || d !== a.g1_1) {
      a.g1_0 = c;
      a.g1_1 = d;
      let b = c.$ === 5 && c.a === d;
      if (b !== a.a2) {
        a.a2 = b;
        a.w1.classList.toggle("active", b);
      }
    }
  }
};
// tm (dg98_2): 42 B raw
let tm = [ [ "11:253", "11:273" ], false, false, false ];
// um (dp98_2): 141 B raw
let um = (a, b) => {
  let d = b[1];
  {
    let b = d;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      let c = tj({
        $: 7,
        a: d
      });
      if (c !== a.a3) {
        a.w2.setAttribute("href", Re(c));
        a.a3 = c;
      }
      a.x5.data = b;
    }
  }
};
// vm (dg98_3): 33 B raw
let vm = [ [ "11:264" ], false, false, false ];
// wm (dp98_3): 128 B raw
let wm = (a, b) => {
  let e = b[2];
  {
    let b = e.E;
    {
      a.g3_0 = b;
      let c = e.E;
      {
        a.a4_0 = c;
        Of("/11:264", () => Ve(a.c4, Nf("/11:264", () => ik(c, "user-pic"))));
      }
    }
  }
};
// xm (dr98_3): 16 B raw
let xm = a => {
  $e(a.c4);
};
// ym (p98): 125 B raw
let ym = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l || a.c1.l || a.c4.l || a.c6.l;
}, 3, [ Qf(om, pm, qm), Qf(rm, sm, null), Qf(tm, um, null), Qf(vm, wm, xm) ], false);
// zm (t98): 69 B raw
let zm = Ca("<!><li class=nav-item><a class=nav-link><!><!></a></li><!>", 4);
// Am (k98): 396 B raw
let Am = {
  m: (a, b) => {
    let c = zm(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.firstChild, h = g.nextSibling, i = e.nextSibling, j = Da(null, d, b), k = Da(null, e, b), l = Da(f, g, b), m = Da(null, i, b), n = Oe(f, h), o = {
      s: null,
      q: j,
      e: i,
      w1: e,
      w2: f,
      c0: j,
      c1: k,
      c4: l,
      x5: n,
      c6: m,
      a0_0: undefined,
      a1_0: undefined,
      a2: false,
      a3: undefined,
      a4_0: undefined,
      a6_0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g2_0: NaN,
      g3_0: NaN
    };
    ym(o, a);
    return o;
  },
  p: ym,
  l: true
};
// Bm (dg115_0): 42 B raw
let Bm = [ [ "11:302", "11:312" ], false, false, false ];
// Cm (dp115_0): 198 B raw
let Cm = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g0_0 = b;
      {
        a.a0_0 = c;
        Of("/11:302", () => Ve(a.c0, Nf("/11:302", () => mm(c, Pl, Ul, "Sign in"))));
      }
      {
        a.a1_0 = c;
        Of("/11:312", () => Ve(a.c1, Nf("/11:312", () => mm(c, Sl, Xl, "Sign up"))));
      }
    }
  }
};
// Dm (dr115_0): 25 B raw
let Dm = a => {
  $e(a.c0);
  $e(a.c1);
};
// Em (p115): 66 B raw
let Em = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l || a.c1.l;
}, 1, [ Qf(Bm, Cm, Dm) ], false);
// Fm (t115): 17 B raw
let Fm = Ca("<!><!>", 4);
// Gm (k115): 184 B raw
let Gm = {
  m: (a, b) => {
    let c = Fm(), d = c.firstChild, e = d.nextSibling, f = Da(null, d, b), g = Da(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_0: undefined,
      a1_0: undefined,
      g0_0: NaN
    };
    Em(h, a);
    return h;
  },
  p: Em,
  l: true
};
// Hm (dg118_2): 33 B raw
let Hm = [ [ "11:183" ], false, false, false ];
// Im (dp118_2): 238 B raw
let Im = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g2_0 = c;
      a.g2_1 = d;
      let b = Nf("/11:183", () => {
        let a;
        if (d.$ === "Just") {
          let b = d.a;
          a = {
            t: Am,
            v: Vf([ c, b._.username, b ], Lf("", "11:195"))
          };
        } else a = {
          t: Gm,
          v: Vf([ c ], Lf("", "11:299"))
        };
        return a;
      });
      Of("/11:183", () => Ve(a.c2, b));
    }
  }
};
// Jm (dr118_2): 16 B raw
let Jm = a => {
  $e(a.c2);
};
// Km (p118): 94 B raw
let Km = Uf((a, b) => b, (a, b) => {
  a.l = a.c1.l || a.c2.l;
}, 2, [ Qf(im, jm, null), Qf(km, lm, nm), Qf(Hm, Im, Jm) ], false);
// Lm (t118): 149 B raw
let Lm = Ca('<nav class="navbar navbar-light"><div class=container><a class=navbar-brand>conduit</a><ul class="nav navbar-nav pull-xs-right"><!><!>', 0);
// Mm (k118): 254 B raw
let Mm = {
  m: (a, b) => {
    let c = Lm(), e = c.firstChild.firstChild, f = e.nextSibling, g = f.firstChild, h = g.nextSibling, i = Da(f, g, b), j = Da(f, h, b), k = {
      s: c,
      q: null,
      e: c,
      w2: e,
      c1: i,
      c2: j,
      a0: undefined,
      a1_0: undefined,
      g0: undefined,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN
    };
    Km(k, a);
    return k;
  },
  p: Km,
  l: true
};
// Nm (dg156_0): 32 B raw
let Nm = [ [ "11:436" ], false, false, true ];
// Om (dp156_0): 107 B raw
let Om = a => {
  {
    if (a.g0 === undefined) {
      a.g0 = true;
      let b = tj(Tl);
      if (b !== a.a0) {
        a.w2.setAttribute("href", Re(b));
        a.a0 = b;
      }
    }
  }
};
// Pm (p156): 47 B raw
let Pm = Uf((a, b) => b, () => {}, 0, [ Qf(Nm, Om, null) ], false);
// Qm (t156): 179 B raw
let Qm = Ca("<footer><div class=container><a class=logo-font>conduit</a><span class=attribution>An interactive learning project from Thinkster. Code &amp; design licensed under MIT.", 0);
// Rm (k156): 116 B raw
let Rm = {
  m: a => {
    let c = Qm(), f = {
      s: c,
      q: null,
      e: c,
      w2: c.firstChild.firstChild,
      a0: undefined,
      g0: undefined
    };
    Pm(f, a);
    return f;
  },
  p: Pm
};
// Sm (dg29_0): 32 B raw
let Sm = [ [ "11:95" ], false, false, false ];
// Tm (dp29_0): 151 B raw
let Tm = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g0_0 = c;
      a.g0_1 = d;
      {
        a.a0_0 = c;
        a.a0_1 = d;
        Of("/11:95", () => Ve(a.c0, Nf("/11:95", () => ({
          t: Mm,
          v: Vf([ d, c ], Lf("", "11:127"))
        }))));
      }
    }
  }
};
// Um (dr29_0): 16 B raw
let Um = a => {
  $e(a.c0);
};
// Vm (dg29_1): 33 B raw
let Vm = [ [ "11:101" ], false, false, false ];
// Wm (dp29_1): 114 B raw
let Wm = (a, b) => {
  let e = b[2];
  {
    let b = e.content;
    {
      a.g1_0 = b;
      let c = Nf("/11:101", () => e.content);
      Of("/11:101", () => Ve(a.c1, c));
    }
  }
};
// Xm (dr29_1): 16 B raw
let Xm = a => {
  $e(a.c1);
};
// Ym (dg29_2): 32 B raw
let Ym = [ [ "11:106" ], false, false, true ];
// Zm (dp29_2): 81 B raw
let Zm = (a, b) => {
  {
    {
      a.g2 = true;
      let b = Nf("/11:106", () => $m);
      Of("/11:106", () => Ve(a.c2, b));
    }
  }
};
// _m (dr29_2): 16 B raw
let _m = a => {
  $e(a.c2);
};
// an (p29): 100 B raw
let an = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l || a.c1.l || a.c2.l;
}, 3, [ Qf(Sm, Tm, Um), Qf(Vm, Wm, Xm), Qf(Ym, Zm, _m) ], false);
// bn (t29): 35 B raw
let bn = Ca("<div class=app><!><!><!>", 0);
// cn (k29): 242 B raw
let cn = {
  m: (a, b) => {
    let c = bn(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = Da(c, d, b), h = Da(c, e, b), i = Da(c, f, b), j = {
      s: c,
      q: null,
      e: c,
      c0: g,
      c1: h,
      c2: i,
      a0_0: undefined,
      a0_1: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2: undefined
    };
    an(j, a);
    return j;
  },
  p: an,
  l: true
};
// mm (navbarLink): 54 B raw
let mm = (a, b, c, d) => ({
  t: hm,
  v: Vf([ a, b, c, d ], Lf("", "11:355"))
});
// $m (footer): 34 B raw
let $m = {
  t: Rm,
  v: Vf([], Lf("", "11:416"))
};
// Cn (frame): 99 B raw
let Cn = (a, b, c) => {
  let d = c.title + " — Conduit";
  return {
    body: {
      t: cn,
      v: Vf([ a, b, c ], Lf("", "11:86"))
    },
    title: d
  };
};