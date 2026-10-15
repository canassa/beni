// Kj (t283): 14 B raw
let Kj = Ca("<!>", 0);
// Lj (k283): 55 B raw
let Lj = {
  m: () => {
    let c = Kj();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Mj (b283): 16 B raw
let Mj = {
  t: Lj,
  v: null
};
// Nj (dg293_0): 24 B raw
let Nj = [ [], false, true, false ];
// Oj (dp293_0): 72 B raw
let Oj = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w0.$$click = b;
    }
  }
};
// Pj (dg293_1): 32 B raw
let Pj = [ [ "3:461" ], false, false, false ];
// Qj (dp293_1): 131 B raw
let Qj = (a, b) => {
  let d = b[1];
  {
    let b = d.username;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let c = ` Unfollow ${d.username}`;
      if (c !== a.a1) {
        a.a1 = c;
        a.x1.data = c;
      }
    }
  }
};
// Rj (p293): 65 B raw
let Rj = Uf((a, b) => b, (a, b) => {}, 2, [ Qf(Nj, Oj, null), Qf(Pj, Qj, null) ], false);
// Sj (t293): 89 B raw
let Sj = Ca('<button class="btn btn-sm action-btn btn-secondary"><i class=ion-plus-round>', 0);
// Tj (k293): 162 B raw
let Tj = {
  m: (a, b) => {
    let c = Sj();
    ff(c, "click", 0);
    if (b !== null) c.$$cx = b;
    let d = Oe(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x1: d,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    Rj(e, a);
    return e;
  },
  p: Rj
};
// Uj (dg303_0): 24 B raw
let Uj = [ [], false, true, false ];
// Vj (dp303_0): 72 B raw
let Vj = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w0.$$click = b;
    }
  }
};
// Wj (dg303_1): 32 B raw
let Wj = [ [ "3:500" ], false, false, false ];
// Xj (dp303_1): 129 B raw
let Xj = (a, b) => {
  let d = b[1];
  {
    let b = d.username;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let c = ` Follow ${d.username}`;
      if (c !== a.a1) {
        a.a1 = c;
        a.x1.data = c;
      }
    }
  }
};
// Yj (p303): 65 B raw
let Yj = Uf((a, b) => b, (a, b) => {}, 2, [ Qf(Uj, Vj, null), Qf(Wj, Xj, null) ], false);
// Zj (t303): 97 B raw
let Zj = Ca('<button class="btn btn-sm action-btn btn-outline-secondary"><i class=ion-plus-round>', 0);
// $j (k303): 162 B raw
let $j = {
  m: (a, b) => {
    let c = Zj();
    ff(c, "click", 0);
    if (b !== null) c.$$cx = b;
    let d = Oe(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x1: d,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    Yj(e, a);
    return e;
  },
  p: Yj
};
// kk (followButton): 146 B raw
let kk = (a, b, c) => {
  switch (c.$) {
   case 0:
    {
      return Mj;
    }

   case 1:
    {
      return {
        t: Tj,
        v: Vf([ b, c.a ], Lf("", "3:438"))
      };
    }

   default:
    {
      return {
        t: $j,
        v: Vf([ a, c.a ], Lf("", "3:477"))
      };
    }
  }
};
// rk (dg521_0): 32 B raw
let rk = [ [ "1:890" ], false, false, false ];
// sk (dp521_0): 69 B raw
let sk = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w1.data = b;
    }
  }
};
// tk (p521): 49 B raw
let tk = Uf((a, b) => b, (a, b) => {}, 1, [ Qf(rk, sk, null) ], true);
// uk (t521): 15 B raw
let uk = Ca("<p> ", 0);
// vk (k521): 88 B raw
let vk = {
  m: a => {
    let c = uk(), e = {
      s: c,
      q: null,
      e: c,
      w1: c.firstChild,
      g0_0: NaN
    };
    tk(e, a);
    return e;
  },
  p: tk
};
// wk (dg523_0): 42 B raw
let wk = [ [ "$producer/1:867" ], false, false, false ];
// xk (dp523_0): 185 B raw
let xk = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g0_0 = b;
      let d = Od(c, "\n\n"), e = {
        m: f => {
          let b = Vf([ f ], Lf("", "1:887"));
          return vk.m(b);
        },
        p: (a, f) => {
          let b = Vf([ f ], Lf("", "1:887"));
          vk.p(a, b);
        }
      };
      ab(a.c0, d, e, null);
    }
  }
};
// yk (dr523_0): 16 B raw
let yk = a => {
  Ia(a.c0);
};
// zk (p523): 66 B raw
let zk = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.w || a.c0.l;
}, 1, [ Qf(wk, xk, yk) ], false);
// Ak (t523): 38 B raw
let Ak = Ca("<div class=article-content>", 0);
// Bk (k523): 103 B raw
let Bk = {
  m: (a, b) => {
    let c = Ak(), d = Da(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN
    };
    zk(e, a);
    return e;
  },
  p: zk,
  l: true
};
// Kl (body): 39 B raw
let Kl = a => ({
  t: Bk,
  v: Vf([ a ], Lf("", "1:857"))
});
// Vt (dg807_0): 33 B raw
let Vt = [ [ "2:1327" ], false, false, false ];
// Wt (dp807_0): 135 B raw
let Wt = (a, b) => {
  let c = b[0];
  {
    let b = c.C;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let d = tj({
        $: 10,
        a: c.C
      });
      if (d !== a.a0) {
        a.w1.setAttribute("href", Re(d));
        a.a0 = d;
      }
    }
  }
};
// Xt (dg807_1): 50 B raw
let Xt = [ [ "2:1348", "2:1358", "2:1390" ], false, false, true ];
// Yt (dp807_1): 238 B raw
let Yt = (a, b) => {
  {
    if (a.g1 === undefined) {
      a.g1 = true;
      if (" Edit Article" !== a.a1) {
        a.a1 = " Edit Article";
        a.x1.data = " Edit Article";
      }
      if (" " !== a.a2) {
        a.a2 = " ";
        a.x2.data = " ";
      }
      if (" Delete Article" !== a.a4) {
        a.a4 = " Delete Article";
        a.x4.data = " Delete Article";
      }
    }
  }
};
// Zt (dg807_2): 24 B raw
let Zt = [ [], false, true, false ];
// $t (dp807_2): 146 B raw
let $t = (a, b) => {
  let c = b[0], d = b[1];
  {
    if (c.C !== a.g2_0 || d !== a.g2_1) {
      a.g2_0 = c.C;
      a.g2_1 = d;
      let b = {
        $: 0,
        a: d,
        b: c.C,
        c: null
      };
      if (b !== a.a3) {
        a.a3 = b;
        a.w3.$$click = b;
      }
    }
  }
};
// _t (p807): 80 B raw
let _t = Uf((a, b) => b, (a, b) => {}, 2, [ Qf(Vt, Wt, null), Qf(Xt, Yt, null), Qf(Zt, $t, null) ], false);
// au (t807): 158 B raw
let au = Ca('<span><a class="btn btn-outline-secondary btn-sm"><i class=ion-edit></i></a><button class="btn btn-outline-danger btn-sm"><i class=ion-trash-a>', 0);
// bu (k807): 305 B raw
let bu = {
  m: (a, b) => {
    let c = au(), d = c.firstChild, e = d.nextSibling, f = Oe(d, null), g = Oe(c, e);
    ff(e, "click", 0);
    if (b !== null) e.$$cx = b;
    let h = Oe(e, null), i = {
      s: c,
      q: null,
      e: c,
      w1: d,
      w3: e,
      x1: f,
      x2: g,
      x4: h,
      a0: undefined,
      a1: undefined,
      a2: undefined,
      a3: undefined,
      a4: undefined,
      g0_0: NaN,
      g1: undefined,
      g2_0: NaN,
      g2_1: NaN
    };
    _t(i, a);
    return i;
  },
  p: _t
};
// cu (dg837_0): 33 B raw
let cu = [ [ "2:1409" ], false, false, false ];
// du (dp837_0): 200 B raw
let du = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  {
    {
      a.g0_0 = c.n;
      a.g0_1 = d;
      let b = {
        $: 5,
        a: d,
        b: e,
        c: null
      }, f = {
        $: 6,
        a: d,
        b: e,
        c: null
      }, g = c.n;
      {
        a.a0_0 = b;
        a.a0_1 = f;
        a.a0_2 = g;
        Of("/2:1409", () => Ve(a.c0, Nf("/2:1409", () => kk(b, f, g))));
      }
    }
  }
};
// eu (dr837_0): 16 B raw
let eu = a => {
  $e(a.c0);
};
// fu (dg837_1): 32 B raw
let fu = [ [ "2:1425" ], false, false, true ];
// gu (dp837_1): 84 B raw
let gu = (a, b) => {
  {
    if (a.g1 === undefined) {
      a.g1 = true;
      if (" " !== a.a1) {
        a.a1 = " ";
        a.x1.data = " ";
      }
    }
  }
};
// hu (dg837_2): 33 B raw
let hu = [ [ "2:1431" ], false, false, false ];
// iu (dp837_2): 203 B raw
let iu = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g2_0 = d;
      a.g2_1 = c;
      a.g2_2 = c.C;
      let b = {
        $: 3,
        a: d,
        b: c.C,
        c: null
      }, e = {
        $: 4,
        a: d,
        b: c.C,
        c: null
      };
      {
        a.a2_0 = c;
        a.a2_1 = b;
        a.a2_2 = e;
        Of("/2:1431", () => Ve(a.c2, Nf("/2:1431", () => Ml(c, b, e, ""))));
      }
    }
  }
};
// ju (dr837_2): 16 B raw
let ju = a => {
  $e(a.c2);
};
// ku (p837): 211 B raw
let ku = Uf((a, b) => {
  let c = b[0], d = b[1];
  if (c.n !== a.l0_0) {
    a.l0_0 = c.n;
    let f = Hj(c.n);
    a.d0 = f;
  }
  let e = a.d0;
  return [ c, d, e ];
}, (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  a.l = a.c0.l || a.c2.l;
}, 2, [ Qf(cu, du, eu), Qf(fu, gu, null), Qf(hu, iu, ju) ], false);
// lu (t837): 26 B raw
let lu = Ca("<span><!><!><!>", 0);
// mu (k837): 353 B raw
let mu = {
  m: (a, b) => {
    let c = lu(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = Da(c, d, b), h = Da(c, f, b), i = Oe(c, e), j = {
      s: c,
      q: null,
      e: c,
      c0: g,
      x1: i,
      c2: h,
      a0_0: undefined,
      a0_1: undefined,
      a0_2: undefined,
      a1: undefined,
      a2_0: undefined,
      a2_1: undefined,
      a2_2: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1: undefined,
      g2_0: NaN,
      g2_1: NaN,
      g2_2: NaN
    };
    ku(j, a);
    return j;
  },
  p: ku,
  l: true
};
// nu (dg773_0): 51 B raw
let nu = [ [ "2:1223", "2:1233", "2:1253" ], false, false, false ];
// ou (dp773_0): 269 B raw
let ou = (a, b) => {
  let c = b[0], e = b[2], f = b[3];
  {
    let b = c.n;
    {
      a.g0_0 = b;
      let d = tj({
        $: 7,
        a: f
      }), g = e.E, h = c.n;
      if (d !== a.a0) {
        a.w1.setAttribute("href", Re(d));
        a.a0 = d;
      }
      {
        a.a1_0 = g;
        Of("/2:1233", () => Ve(a.c1, Nf("/2:1233", () => ik(g, ""))));
      }
      {
        a.a2_0 = h;
        Of("/2:1253", () => Ve(a.c2, Nf("/2:1253", () => jk(h))));
      }
    }
  }
};
// pu (dr773_0): 25 B raw
let pu = a => {
  $e(a.c1);
  $e(a.c2);
};
// qu (dg773_1): 33 B raw
let qu = [ [ "2:1259" ], false, false, false ];
// ru (dp773_1): 117 B raw
let ru = (a, b) => {
  let c = b[0];
  {
    let b = c.M;
    {
      a.g1_0 = b;
      let d = c.M;
      {
        a.a3_0 = d;
        Of("/2:1259", () => Ve(a.c3, Nf("/2:1259", () => Jl(d))));
      }
    }
  }
};
// su (dr773_1): 16 B raw
let su = a => {
  $e(a.c3);
};
// tu (t770): 14 B raw
let tu = Ca("<!>", 0);
// uu (k770): 55 B raw
let uu = {
  m: () => {
    let c = tu();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// vu (b770): 16 B raw
let vu = {
  t: uu,
  v: null
};
// wu (dg773_2): 33 B raw
let wu = [ [ "2:1269" ], false, false, false ];
// xu (dp773_2): 252 B raw
let xu = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g2_0 = d.g;
      a.g2_1 = c;
      let b = Nf("/2:1269", () => {
        let a = Zf(d.g), b;
        if (a.$ === "Just") {
          let e = a.a;
          b = c.n.$ === 0 ? {
            t: bu,
            v: Vf([ c, e ], Lf("", "2:1316"))
          } : {
            t: mu,
            v: Vf([ c, e ], Lf("", "2:1405"))
          };
        } else b = vu;
        return b;
      });
      Of("/2:1269", () => Ve(a.c4, b));
    }
  }
};
// yu (dr773_2): 16 B raw
let yu = a => {
  $e(a.c4);
};
// zu (p773): 289 B raw
let zu = Uf((a, b) => {
  let c = b[0], d = b[1];
  if (c.n !== a.l0_0) {
    a.l0_0 = c.n;
    let g = dk(c.n);
    a.d0 = g;
  }
  let e = a.d0;
  if (c.n !== a.l1_0) {
    a.l1_0 = c.n;
    a.d1 = e.username;
  }
  let f = a.d1;
  return [ c, d, e, f ];
}, (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l;
}, 2, [ Qf(nu, ou, pu), Qf(qu, ru, su), Qf(wu, xu, yu) ], false);
// Au (t773): 64 B raw
let Au = Ca("<div class=article-meta><a></a><div class=info><!><!>", 0);
// Bu (k773): 353 B raw
let Bu = {
  m: (a, b) => {
    let c = Au(), d = c.firstChild, e = d.nextSibling, f = e.firstChild, g = f.nextSibling, h = Da(d, null, b), i = Da(e, f, b), j = Da(e, g, b), k = Da(c, null, b), l = {
      s: c,
      q: null,
      e: c,
      w1: d,
      c1: h,
      c2: i,
      c3: j,
      c4: k,
      a0: undefined,
      a1_0: undefined,
      a2_0: undefined,
      a3_0: undefined,
      l0_0: NaN,
      d0: undefined,
      l1_0: NaN,
      d1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN
    };
    zu(l, a);
    return l;
  },
  p: zu,
  l: true
};
// Cu (dg947_0): 24 B raw
let Cu = [ [], false, true, false ];
// Du (dp947_0): 153 B raw
let Du = (a, b) => {
  let c = b[0], d = b[1];
  {
    if (c._ !== a.g0_0 || d !== a.g0_1) {
      a.g0_0 = c._;
      a.g0_1 = d;
      let b = () => ({
        $: 7,
        a: c._,
        b: d,
        c: null
      });
      if (b !== a.a0) {
        a.a0 = b;
        a.w0.$$submit = b;
      }
    }
  }
};
// Eu (dg947_1): 33 B raw
let Eu = [ [ "2:1636" ], false, false, false ];
// Fu (dp947_1): 76 B raw
let Fu = (a, b) => {
  let e = b[2];
  {
    let b = e;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      tf(a.w2, "value", e);
    }
  }
};
// Gu (dg947_2): 42 B raw
let Gu = [ [ "2:1641", "2:1682" ], false, false, false ];
// Hu (dp947_2): 117 B raw
let Hu = (a, b) => {
  let f = b[3];
  {
    let b = f;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      Pe(a.w2, "disabled", b ? "" : null);
      Pe(a.w4, "disabled", b ? "" : null);
    }
  }
};
// Iu (dg947_3): 23 B raw
let Iu = [ [], false, true, true ];
// Ju (dp947_3): 116 B raw
let Ju = (a, b) => {
  {
    if (a.g3 === undefined) {
      a.g3 = true;
      let b = a => ({
        $: 8,
        a: a,
        b: null,
        c: null
      });
      if (b !== a.a3) {
        a.a3 = b;
        a.w2.$$input = b;
      }
    }
  }
};
// Ku (dg947_4): 33 B raw
let Ku = [ [ "2:1666" ], false, false, false ];
// Lu (dp947_4): 138 B raw
let Lu = (a, b) => {
  let c = b[0];
  {
    let b = c.E;
    {
      a.g4_0 = b;
      let d = c.E;
      {
        a.a4_0 = d;
        Of("/2:1666", () => Ve(a.c4, Nf("/2:1666", () => ik(d, "comment-author-img"))));
      }
    }
  }
};
// Mu (dr947_4): 16 B raw
let Mu = a => {
  $e(a.c4);
};
// Nu (p947): 118 B raw
let Nu = Uf((a, b) => b, (a, b) => {
  a.l = a.c4.l;
}, 4, [ Qf(Cu, Du, null), Qf(Eu, Fu, null), Qf(Gu, Hu, null), Qf(Iu, Ju, null), Qf(Ku, Lu, Mu) ], false);
// Ou (t947): 257 B raw
let Ou = Ca('<form id=comment-form class="card comment-form"><div class=card-block><textarea id=comment class=form-control placeholder="Write a comment..."rows=3></textarea></div><div class=card-footer><button class="btn btn-sm btn-primary">Post Comment', 0);
// Pu (k947): 374 B raw
let Pu = {
  m: (a, b) => {
    let c = Ou(), d = c.firstChild, e = d.firstChild, f = d.nextSibling, g = f.firstChild, h = Da(f, g, b);
    c.$$submitX = Se;
    ff(c, "submit", 1);
    if (b !== null) c.$$cx = b;
    e.$$inputX = Hn;
    ff(e, "input", 0);
    if (b !== null) e.$$cx = b;
    let i = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w2: e,
      w4: g,
      c4: h,
      a0: undefined,
      a3: undefined,
      a4_0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g3: undefined,
      g4_0: NaN
    };
    Nu(i, a);
    return i;
  },
  p: Nu,
  l: true
};
// Qu (dg960_0): 59 B raw
let Qu = [ [ "2:1708", "2:1720", "2:1728", "2:1740" ], false, false, true ];
// Ru (dp960_0): 349 B raw
let Ru = a => {
  {
    if (a.g0 === undefined) {
      a.g0 = true;
      let b = tj(Tt), c = tj(Ut);
      if (b !== a.a0) {
        a.w1.setAttribute("href", Re(b));
        a.a0 = b;
      }
      if (" or " !== a.a1) {
        a.a1 = " or ";
        a.x1.data = " or ";
      }
      if (c !== a.a2) {
        a.w3.setAttribute("href", Re(c));
        a.a2 = c;
      }
      if (" to add comments on this article." !== a.a3) {
        a.a3 = " to add comments on this article.";
        a.x3.data = " to add comments on this article.";
      }
    }
  }
};
// Su (p960): 47 B raw
let Su = Uf((a, b) => b, () => {}, 0, [ Qf(Qu, Ru, null) ], false);
// Tu (t960): 45 B raw
let Tu = Ca("<p><a>Sign in</a><a>sign up</a><!>", 0);
// Uu (k960): 215 B raw
let Uu = {
  m: a => {
    let c = Tu(), d = c.firstChild, e = d.nextSibling, f = e.nextSibling, g = Oe(c, e), h = Oe(c, f), i = {
      s: c,
      q: null,
      e: c,
      w1: d,
      w3: e,
      x1: g,
      x3: h,
      a0: undefined,
      a1: undefined,
      a2: undefined,
      a3: undefined,
      g0: undefined
    };
    Su(i, a);
    return i;
  },
  p: Su
};
// Vu (dg1029_0): 33 B raw
let Vu = [ [ "2:1795" ], false, false, false ];
// Wu (dp1029_0): 74 B raw
let Wu = (a, b) => {
  let c = b[0];
  {
    let b = c.body;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w3.data = b;
    }
  }
};
// Xu (dg1029_1): 60 B raw
let Xu = [ [ "2:1822", "2:1834", "2:1860", "2:1872" ], false, false, false ];
// Yu (dp1029_1): 344 B raw
let Yu = (a, b) => {
  let c = b[0], f = b[3];
  {
    let b = c.n;
    {
      a.g1_0 = b;
      let c = tj({
        $: 7,
        a: f.username
      }), d = f.E, e = tj({
        $: 7,
        a: f.username
      }), g = f.username;
      if (c !== a.a1) {
        a.w5.setAttribute("href", Re(c));
        a.a1 = c;
      }
      {
        a.a2_0 = d;
        Of("/2:1834", () => Ve(a.c2, Nf("/2:1834", () => ik(d, "comment-author-img"))));
      }
      if (e !== a.a4) {
        a.w6.setAttribute("href", Re(e));
        a.a4 = e;
      }
      if (g !== a.a5) {
        a.a5 = g;
        a.w7.data = g;
      }
    }
  }
};
// Zu (dr1029_1): 16 B raw
let Zu = a => {
  $e(a.c2);
};
// $u (dg1029_2): 32 B raw
let $u = [ [ "2:1847" ], false, false, true ];
// _u (dp1029_2): 84 B raw
let _u = (a, b) => {
  {
    if (a.g2 === undefined) {
      a.g2 = true;
      if (" " !== a.a3) {
        a.a3 = " ";
        a.x3.data = " ";
      }
    }
  }
};
// av (dg1029_3): 33 B raw
let av = [ [ "2:1881" ], false, false, false ];
// bv (dp1029_3): 117 B raw
let bv = (a, b) => {
  let c = b[0];
  {
    let b = c.M;
    {
      a.g3_0 = b;
      let d = c.M;
      {
        a.a6_0 = d;
        Of("/2:1881", () => Ve(a.c6, Nf("/2:1881", () => Jl(d))));
      }
    }
  }
};
// cv (dr1029_3): 16 B raw
let cv = a => {
  $e(a.c6);
};
// dv (dg1023_0): 24 B raw
let dv = [ [], false, true, false ];
// ev (dp1023_0): 171 B raw
let ev = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  {
    if (c !== a.g0_0 || d !== a.g0_1 || e.W !== a.g0_2) {
      a.g0_0 = c;
      a.g0_1 = d;
      a.g0_2 = e.W;
      let b = {
        $: 1,
        a: c,
        b: d,
        c: e.W
      };
      if (b !== a.a0) {
        a.a0 = b;
        a.w1.$$click = b;
      }
    }
  }
};
// fv (p1023): 50 B raw
let fv = Uf((a, b) => b, (a, b) => {}, 3, [ Qf(dv, ev, null) ], false);
// gv (t1023): 56 B raw
let gv = Ca("<span class=mod-options><i class=ion-trash-a>", 0);
// hv (k1023): 168 B raw
let hv = {
  m: (a, b) => {
    let c = gv(), d = c.firstChild;
    ff(d, "click", 0);
    if (b !== null) d.$$cx = b;
    let e = {
      s: c,
      q: null,
      e: c,
      w1: d,
      a0: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN
    };
    fv(e, a);
    return e;
  },
  p: fv
};
// iv (t1026): 14 B raw
let iv = Ca("<!>", 0);
// jv (k1026): 55 B raw
let jv = {
  m: () => {
    let c = iv();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// kv (b1026): 16 B raw
let kv = {
  t: jv,
  v: null
};
// lv (dg1029_4): 33 B raw
let lv = [ [ "2:1887" ], false, false, false ];
// mv (dp1029_4): 265 B raw
let mv = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  {
    {
      a.g4_0 = c.n;
      a.g4_1 = d;
      a.g4_2 = e;
      a.g4_3 = c.W;
      let b = Nf("/2:1887", () => {
        let a = c.n, b;
        f: {
          g: {
            if (a.$ === 0) if (d.$ === "Just") {
              b = {
                t: hv,
                v: Vf([ d.a, e, c ], Lf("", "2:1904"))
              };
              break f;
            } else break g;
            break g;
          }
          b = kv;
        }
        return b;
      });
      Of("/2:1887", () => Ve(a.c7, b));
    }
  }
};
// nv (dr1029_4): 16 B raw
let nv = a => {
  $e(a.c7);
};
// ov (p1029): 263 B raw
let ov = Uf((a, b) => {
  let c = b[0], d = b[1], e = b[2];
  if (c.n !== a.l0_0) {
    a.l0_0 = c.n;
    let g = dk(c.n);
    a.d0 = g;
  }
  let f = a.d0;
  return [ c, d, e, f ];
}, (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  a.l = a.c2.l || a.c6.l || a.c7.l;
}, 3, [ Qf(Vu, Wu, null), Qf(Xu, Yu, Zu), Qf($u, _u, null), Qf(av, bv, cv), Qf(lv, mv, nv) ], false);
// pv (t1029): 165 B raw
let pv = Ca("<div class=card><div class=card-block><p class=card-text> </p></div><div class=card-footer><a class=comment-author></a><a class=comment-author> </a><!><!>", 0);
// qv (k1029): 478 B raw
let qv = {
  m: (a, b) => {
    let c = pv(), d = c.firstChild, f = d.firstChild.firstChild, g = d.nextSibling, h = g.firstChild, i = h.nextSibling, j = i.firstChild, k = i.nextSibling, l = k.nextSibling, m = Da(h, null, b), n = Da(g, k, b), o = Da(g, l, b), p = Oe(g, i), q = {
      s: c,
      q: null,
      e: c,
      w3: f,
      w5: h,
      w6: i,
      w7: j,
      c2: m,
      x3: p,
      c6: n,
      c7: o,
      a1: undefined,
      a2_0: undefined,
      a3: undefined,
      a4: undefined,
      a5: undefined,
      a6_0: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2: undefined,
      g3_0: NaN,
      g4_0: NaN,
      g4_1: NaN,
      g4_2: NaN,
      g4_3: NaN
    };
    ov(q, a);
    return q;
  },
  p: ov,
  l: true
};
// rv (t881): 14 B raw
let rv = Ca("<!>", 0);
// sv (k881): 55 B raw
let sv = {
  m: () => {
    let c = rv();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// tv (b881): 16 B raw
let tv = {
  t: sv,
  v: null
};
// uv (dg877_0): 33 B raw
let uv = [ [ "2:1479" ], false, false, false ];
// vv (dp877_0): 448 B raw
let vv = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  {
    {
      a.g0_0 = c.g;
      a.g0_1 = d;
      a.g0_2 = e;
      let b = c.g;
      {
        a.a0_0 = b;
        a.a0_1 = d;
        a.a0_2 = e;
        Of("/2:1479", () => Ve(a.c0, Nf("/2:1479", () => {
          if (b.$ === 0) {
            let c = b.b, f;
            if (e.$ === 0) f = {
              a: e.a,
              b: false
            }; else f = {
              a: e.a,
              b: true
            };
            return {
              t: Pu,
              v: Vf([ c, d, f.a, f.b ], Lf("", "2:1580"))
            };
          }
          if (Wf.$ === "Just") {
            let j = Wf.a, k;
            if (e.$ === 0) k = {
              a: e.a,
              b: false
            }; else k = {
              a: e.a,
              b: true
            };
            return {
              t: Pu,
              v: Vf([ j, d, k.a, k.b ], Lf("", "2:1580"))
            };
          }
          return {
            t: Uu,
            v: Vf([], Lf("", "2:1702"))
          };
        })));
      }
    }
  }
};
// wv (dr877_0): 16 B raw
let wv = a => {
  $e(a.c0);
};
// xv (dg877_1): 43 B raw
let xv = [ [ "$producer/2:1488" ], false, false, false ];
// yv (dp877_1): 134 B raw
let yv = (a, b) => {
  let c = b[0], d = b[1], f = b[3];
  {
    {
      a.g1_0 = c.g;
      a.g1_1 = d;
      a.g1_2 = f;
      let b = a => a.W, e = {
        b: Mf(a => zv(Zf(c.g), d, a))
      };
      Xe(a.c1, f, b, e, [ c.g, d ]);
    }
  }
};
// Av (dr877_1): 16 B raw
let Av = a => {
  Ia(a.c1);
};
// Bv (p877): 87 B raw
let Bv = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l || a.c1.w || a.c1.l;
}, 4, [ Qf(uv, vv, wv), Qf(xv, yv, Av) ], false);
// Cv (t877): 17 B raw
let Cv = Ca("<!><!>", 4);
// Dv (k877): 244 B raw
let Dv = {
  m: (a, b) => {
    let c = Cv(), d = c.firstChild, e = d.nextSibling, f = Da(null, d, b), g = Da(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_0: undefined,
      a0_1: undefined,
      a0_2: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g1_2: NaN
    };
    Bv(h, a);
    return h;
  },
  p: Bv,
  l: true
};
// Ev (t704): 14 B raw
let Ev = Ca("<!>", 0);
// Fv (k704): 55 B raw
let Fv = {
  m: () => {
    let c = Ev();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Gv (b704): 16 B raw
let Gv = {
  t: Fv,
  v: null
};
// Hv (dg698_0): 33 B raw
let Hv = [ [ "2:1008" ], false, false, false ];
// Iv (dp698_0): 75 B raw
let Iv = (a, b) => {
  let c = b[0];
  {
    let b = c.title;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w4.data = b;
    }
  }
};
// Jv (dg698_1): 42 B raw
let Jv = [ [ "2:1016", "2:1096" ], false, false, false ];
// Kv (dp698_1): 196 B raw
let Kv = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g1_0 = d;
      a.g1_1 = c;
      {
        a.a1_0 = d;
        a.a1_1 = c;
        Of("/2:1016", () => Ve(a.c1, Nf("/2:1016", () => Lv(d, c))));
      }
      {
        a.a5_0 = d;
        a.a5_1 = c;
        Of("/2:1096", () => Ve(a.c5, Nf("/2:1096", () => Lv(d, c))));
      }
    }
  }
};
// Mv (dr698_1): 25 B raw
let Mv = a => {
  $e(a.c1);
  $e(a.c5);
};
// Nv (dg698_2): 33 B raw
let Nv = [ [ "2:1022" ], false, false, false ];
// Ov (dp698_2): 120 B raw
let Ov = (a, b) => {
  let d = b[1];
  {
    let b = d.B;
    {
      a.g2_0 = b;
      let c = d.B;
      {
        a.a2_1 = c;
        Of("/2:1022", () => Ve(a.c2, Nf("/2:1022", () => Dn(Nt, c))));
      }
    }
  }
};
// Pv (dr698_2): 16 B raw
let Pv = a => {
  $e(a.c2);
};
// Qv (dg698_3): 33 B raw
let Qv = [ [ "2:1064" ], false, false, false ];
// Rv (dp698_3): 123 B raw
let Rv = (a, b) => {
  let c = b[0];
  {
    let b = c.body;
    {
      a.g3_0 = b;
      let d = c.body;
      {
        a.a3_0 = d;
        Of("/2:1064", () => Ve(a.c3, Nf("/2:1064", () => Kl(d))));
      }
    }
  }
};
// Sv (dr698_3): 16 B raw
let Sv = a => {
  $e(a.c3);
};
// Tv (dg698_4): 33 B raw
let Tv = [ [ "2:1070" ], false, false, false ];
// Uv (dp698_4): 117 B raw
let Uv = (a, b) => {
  let c = b[0];
  {
    let b = c.A;
    {
      a.g4_0 = b;
      let d = c.A;
      {
        a.a4_0 = d;
        Of("/2:1070", () => Ve(a.c4, Nf("/2:1070", () => Ll(d))));
      }
    }
  }
};
// Vv (dr698_4): 16 B raw
let Vv = a => {
  $e(a.c4);
};
// Wv (dg698_5): 33 B raw
let Wv = [ [ "2:1123" ], false, false, false ];
// Xv (dp698_5): 282 B raw
let Xv = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g5_0 = d;
      a.g5_1 = c.C;
      let b = c.C;
      {
        a.a6_0 = d;
        a.a6_1 = b;
        Of("/2:1123", () => Ve(a.c6, Nf("/2:1123", () => {
          let a = d.J;
          switch (a.$) {
           case 0:
            {
              return tv;
            }

           case 1:
            {
              return En;
            }

           case 2:
            {
              return {
                t: Dv,
                v: Vf([ d, b, a.a.a, a.a.b ], Lf("", "2:1476"))
              };
            }

           default:
            {
              return Fn("comments");
            }
          }
        })));
      }
    }
  }
};
// Yv (dr698_5): 16 B raw
let Yv = a => {
  $e(a.c6);
};
// Zv (p698): 165 B raw
let Zv = Uf((a, b) => b, (a, b) => {
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l || a.c6.l;
}, 2, [ Qf(Hv, Iv, null), Qf(Jv, Kv, Mv), Qf(Nv, Ov, Pv), Qf(Qv, Rv, Sv), Qf(Tv, Uv, Vv), Qf(Wv, Xv, Yv) ], false);
// $v (t698): 304 B raw
let $v = Ca('<div class=article-page><div class=banner><div class=container><h1> </h1><!><!></div></div><div class="container page"><div class="row article-content"><div class=col-md-12><!><!></div></div><hr><div class=article-actions></div><div class=row><div class="col-xs-12 col-md-8 offset-md-2">', 0);
// _v (k698): 614 B raw
let _v = {
  m: (a, b) => {
    let c = $v(), d = c.firstChild, e = d.firstChild, f = e.firstChild, g = f.firstChild, h = f.nextSibling, i = h.nextSibling, k = d.nextSibling.firstChild, l = k.firstChild, m = l.firstChild, n = m.nextSibling, o = k.nextSibling.nextSibling, q = o.nextSibling.firstChild, r = Da(e, h, b), s = Da(e, i, b), t = Da(l, m, b), u = Da(l, n, b), v = Da(o, null, b), w = Da(q, null, b), x = {
      s: c,
      q: null,
      e: c,
      w4: g,
      c1: r,
      c2: s,
      c3: t,
      c4: u,
      c5: v,
      c6: w,
      a1_0: undefined,
      a1_1: undefined,
      a2_1: undefined,
      a3_0: undefined,
      a4_0: undefined,
      a5_0: undefined,
      a5_1: undefined,
      a6_0: undefined,
      a6_1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN,
      g2_0: NaN,
      g3_0: NaN,
      g4_0: NaN,
      g5_0: NaN,
      g5_1: NaN
    };
    Zv(x, a);
    return x;
  },
  p: Zv,
  l: true
};
// Lv (viewMeta): 46 B raw
let Lv = (a, b) => ({
  t: Bu,
  v: Vf([ b, a ], Lf("", "2:1212"))
});
// zv (viewComment): 50 B raw
let zv = (a, b, c) => ({
  t: qv,
  v: Vf([ c, a, b ], Lf("", "2:1770"))
});
// cw (view): 254 B raw
let cw = a => {
  let b = a.L;
  switch (b.$) {
   case 0:
    {
      return {
        content: Gv,
        title: "Article"
      };
    }

   case 1:
    {
      return {
        content: En,
        title: "Article"
      };
    }

   case 2:
    {
      let c = b.a;
      return {
        content: {
          t: _v,
          v: Vf([ c, a ], Lf("", "2:978"))
        },
        title: c.title
      };
    }

   default:
    {
      return {
        content: Fn("article"),
        title: "Article"
      };
    }
  }
};