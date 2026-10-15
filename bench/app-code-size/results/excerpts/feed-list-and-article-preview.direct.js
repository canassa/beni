// wj (dg250_0): 32 B raw
let wj = [ [ "3:360" ], false, false, false ];
// xj (dp250_0): 86 B raw
let xj = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w0.setAttribute("class", b);
    }
  }
};
// yj (dg250_1): 32 B raw
let yj = [ [ "3:365" ], false, false, false ];
// zj (dp250_1): 121 B raw
let zj = (a, b) => {
  let d = b[1];
  {
    let b = d;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let c = Aj(d);
      if (c !== a.a1) {
        a.w0.setAttribute("src", Re(c));
        a.a1 = c;
      }
    }
  }
};
// Bj (p250): 65 B raw
let Bj = Uf((a, b) => b, (a, b) => {}, 2, [ Qf(wj, xj, null), Qf(yj, zj, null) ], false);
// Cj (t250): 16 B raw
let Cj = Ca("<img>", 0);
// Dj (k250): 99 B raw
let Dj = {
  m: a => {
    let c = Cj(), d = {
      s: c,
      q: null,
      e: c,
      w0: c,
      a1: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    Bj(d, a);
    return d;
  },
  p: Bj
};
// Ej (dg267_0): 40 B raw
let Ej = [ [ "3:393", "3:403" ], false, false, false ];
// Fj (dp267_0): 169 B raw
let Fj = (a, b) => {
  let c = b[0], d = b[1];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let e = tj({
        $: 7,
        a: d
      });
      if (e !== a.a0) {
        a.w0.setAttribute("href", Re(e));
        a.a0 = e;
      }
      if (d !== a.a1) {
        a.a1 = d;
        a.w1.data = d;
      }
    }
  }
};
// Gj (p267): 144 B raw
let Gj = Uf((a, b) => {
  let c = b[0];
  if (c !== a.l0_0) {
    a.l0_0 = c;
    let e = Hj(c);
    a.d0 = e;
  }
  let d = a.d0;
  return [ c, d ];
}, (a, b) => {
  let c = b[0], d = b[1];
}, 1, [ Qf(Ej, Fj, null) ], false);
// Ij (t267): 28 B raw
let Ij = Ca("<a class=author> ", 0);
// Jj (k267): 141 B raw
let Jj = {
  m: a => {
    let c = Ij(), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w1: c.firstChild,
      a0: undefined,
      a1: undefined,
      l0_0: NaN,
      d0: undefined,
      g0_0: NaN
    };
    Gj(e, a);
    return e;
  },
  p: Gj
};
// hk (defaultAvatar): 62 B raw
let hk = "https://static.productionready.io/images/smiley-cyrus.jpg";
// Aj (avatarSrc): 37 B raw
let Aj = a => a.$ === "Just" ? a.a === "" ? hk : a.a : hk;
// ik (avatar): 45 B raw
let ik = (a, b) => ({
  t: Dj,
  v: Vf([ b, a ], Lf("", "3:358"))
});
// jk (link): 39 B raw
let jk = a => ({
  t: Jj,
  v: Vf([ a ], Lf("", "3:386"))
});
// mk (dg507_0): 32 B raw
let mk = [ [ "1:841" ], false, false, false ];
// nk (dp507_0): 69 B raw
let nk = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w1.data = b;
    }
  }
};
// ok (p507): 50 B raw
let ok = Uf((a, b) => b, (a, b) => {}, 1, [ Qf(mk, nk, null) ], false);
// pk (t507): 29 B raw
let pk = Ca("<span class=date> ", 0);
// qk (k507): 88 B raw
let qk = {
  m: a => {
    let c = pk(), e = {
      s: c,
      q: null,
      e: c,
      w1: c.firstChild,
      g0_0: NaN
    };
    ok(e, a);
    return e;
  },
  p: ok
};
// Ck (dg536_0): 32 B raw
let Ck = [ [ "1:950" ], false, false, false ];
// Dk (dp536_0): 69 B raw
let Dk = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w1.data = b;
    }
  }
};
// Ek (p536): 49 B raw
let Ek = Uf((a, b) => b, (a, b) => {}, 1, [ Qf(Ck, Dk, null) ], true);
// Fk (t536): 59 B raw
let Fk = Ca('<li class="tag-default tag-pill tag-outline"> ', 0);
// Gk (k536): 88 B raw
let Gk = {
  m: a => {
    let c = Fk(), e = {
      s: c,
      q: null,
      e: c,
      w1: c.firstChild,
      g0_0: NaN
    };
    Ek(e, a);
    return e;
  },
  p: Ek
};
// Hk (dg538_0): 42 B raw
let Hk = [ [ "$producer/1:925" ], false, false, false ];
// Ik (dp538_0): 170 B raw
let Ik = (a, b) => {
  let c = b[0];
  {
    let b = c;
    {
      a.g0_0 = b;
      let d = {
        m: e => {
          let b = Vf([ e ], Lf("", "1:942"));
          return Gk.m(b);
        },
        p: (a, e) => {
          let b = Vf([ e ], Lf("", "1:942"));
          Gk.p(a, b);
        }
      };
      ab(a.c0, c, d, null);
    }
  }
};
// Jk (dr538_0): 16 B raw
let Jk = a => {
  Ia(a.c0);
};
// Kk (p538): 66 B raw
let Kk = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.w || a.c0.l;
}, 1, [ Qf(Hk, Ik, Jk) ], false);
// Lk (t538): 30 B raw
let Lk = Ca("<ul class=tag-list>", 0);
// Mk (k538): 103 B raw
let Mk = {
  m: (a, b) => {
    let c = Lk(), d = Da(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN
    };
    Kk(e, a);
    return e;
  },
  p: Kk,
  l: true
};
// Nk (dg565_0): 32 B raw
let Nk = [ [ "1:990" ], false, false, false ];
// Ok (dp565_0): 143 B raw
let Ok = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let d = `btn btn-primary btn-sm ${c}`;
      if (d !== a.a0) {
        a.w0.setAttribute("class", d);
        a.a0 = d;
      }
    }
  }
};
// Pk (dg565_1): 24 B raw
let Pk = [ [], false, true, false ];
// Qk (dp565_1): 72 B raw
let Qk = (a, b) => {
  let d = b[1];
  {
    let b = d;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      a.w0.$$click = b;
    }
  }
};
// Rk (dg565_2): 33 B raw
let Rk = [ [ "1:1014" ], false, false, false ];
// Sk (dp565_2): 112 B raw
let Sk = (a, b) => {
  let e = b[2];
  {
    let b = e.R;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      let c = ` ${Qd(e.R)}`;
      if (c !== a.a2) {
        a.a2 = c;
        a.x2.data = c;
      }
    }
  }
};
// Tk (p565): 80 B raw
let Tk = Uf((a, b) => b, (a, b) => {}, 3, [ Qf(Nk, Ok, null), Qf(Pk, Qk, null), Qf(Rk, Sk, null) ], false);
// Uk (t565): 38 B raw
let Uk = Ca("<button><i class=ion-heart>", 0);
// Vk (k565): 184 B raw
let Vk = {
  m: (a, b) => {
    let c = Uk();
    ff(c, "click", 0);
    if (b !== null) c.$$cx = b;
    let d = Oe(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x2: d,
      a0: undefined,
      a2: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    Tk(e, a);
    return e;
  },
  p: Tk
};
// Wk (dg579_0): 33 B raw
let Wk = [ [ "1:1031" ], false, false, false ];
// Xk (dp579_0): 151 B raw
let Xk = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let d = `btn btn-outline-primary btn-sm ${c}`;
      if (d !== a.a0) {
        a.w0.setAttribute("class", d);
        a.a0 = d;
      }
    }
  }
};
// Yk (dg579_1): 24 B raw
let Yk = [ [], false, true, false ];
// Zk (dp579_1): 72 B raw
let Zk = (a, b) => {
  let d = b[1];
  {
    let b = d;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      a.w0.$$click = b;
    }
  }
};
// $k (dg579_2): 33 B raw
let $k = [ [ "1:1055" ], false, false, false ];
// _k (dp579_2): 112 B raw
let _k = (a, b) => {
  let e = b[2];
  {
    let b = e.R;
    if (b !== a.g2_0) {
      a.g2_0 = b;
      let c = ` ${Qd(e.R)}`;
      if (c !== a.a2) {
        a.a2 = c;
        a.x2.data = c;
      }
    }
  }
};
// al (p579): 80 B raw
let al = Uf((a, b) => b, (a, b) => {}, 3, [ Qf(Wk, Xk, null), Qf(Yk, Zk, null), Qf($k, _k, null) ], false);
// bl (t579): 38 B raw
let bl = Ca("<button><i class=ion-heart>", 0);
// cl (k579): 184 B raw
let cl = {
  m: (a, b) => {
    let c = bl();
    ff(c, "click", 0);
    if (b !== null) c.$$cx = b;
    let d = Oe(c, null), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      x2: d,
      a0: undefined,
      a2: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    al(e, a);
    return e;
  },
  p: al
};
// dl (dg599_0): 33 B raw
let dl = [ [ "1:1090" ], false, false, false ];
// el (dp599_0): 134 B raw
let el = (a, b) => {
  let c = b[0];
  {
    let b = c.C;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      let d = tj({
        $: 6,
        a: c.C
      });
      if (d !== a.a0) {
        a.w0.setAttribute("href", Re(d));
        a.a0 = d;
      }
    }
  }
};
// fl (dg599_1): 33 B raw
let fl = [ [ "1:1101" ], false, false, false ];
// gl (dp599_1): 98 B raw
let gl = (a, b) => {
  let d = b[1];
  {
    let b = d;
    {
      a.g1_0 = b;
      let c = Nf("/1:1101", () => d);
      Of("/1:1101", () => Ve(a.c1, c));
    }
  }
};
// hl (dr599_1): 16 B raw
let hl = a => {
  $e(a.c1);
};
// il (p599): 73 B raw
let il = Uf((a, b) => b, (a, b) => {
  a.l = a.c1.l;
}, 2, [ Qf(dl, el, null), Qf(fl, gl, hl) ], false);
// jl (t599): 33 B raw
let jl = Ca("<a class=preview-link>", 0);
// kl (k599): 130 B raw
let kl = {
  m: (a, b) => {
    let c = jl(), d = Da(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      w0: c,
      c1: d,
      a0: undefined,
      g0_0: NaN,
      g1_0: NaN
    };
    il(e, a);
    return e;
  },
  p: il,
  l: true
};
// Jl (timestamp): 39 B raw
let Jl = a => ({
  t: qk,
  v: Vf([ a ], Lf("", "1:833"))
});
// Ll (tagList): 39 B raw
let Ll = a => ({
  t: Mk,
  v: Vf([ a ], Lf("", "1:915"))
});
// Ml (favoriteButton): 91 B raw
let Ml = (a, b, c, d) => a.ba ? {
  t: Vk,
  v: Vf([ d, c, a ], Lf("", "1:988"))
} : {
  t: cl,
  v: Vf([ d, b, a ], Lf("", "1:1029"))
};
// Nl (link): 46 B raw
let Nl = (a, b) => ({
  t: kl,
  v: Vf([ a, b ], Lf("", "1:1083"))
});
// Kn (dg224_0): 32 B raw
let Kn = [ [ "7:379" ], false, false, false ];
// Ln (dp224_0): 75 B raw
let Ln = (a, b) => {
  let c = b[0];
  {
    let b = c.title;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w1.data = b;
    }
  }
};
// Mn (dg224_1): 32 B raw
let Mn = [ [ "7:390" ], false, false, false ];
// Nn (dp224_1): 71 B raw
let Nn = (a, b) => {
  let c = b[0];
  {
    let b = c.D;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      a.w3.data = b;
    }
  }
};
// On (dg224_2): 32 B raw
let On = [ [ "7:406" ], false, false, false ];
// Pn (dp224_2): 115 B raw
let Pn = (a, b) => {
  let c = b[0];
  {
    let b = c.A;
    {
      a.g2_0 = b;
      let d = c.A;
      {
        a.a2_0 = d;
        Of("/7:406", () => Ve(a.c2, Nf("/7:406", () => Ll(d))));
      }
    }
  }
};
// Qn (dr224_2): 16 B raw
let Qn = a => {
  $e(a.c2);
};
// Rn (p224): 88 B raw
let Rn = Uf((a, b) => b, (a, b) => {
  a.l = a.c2.l;
}, 1, [ Qf(Kn, Ln, null), Qf(Mn, Nn, null), Qf(On, Pn, Qn) ], false);
// Sn (t224): 57 B raw
let Sn = Ca("<h1> </h1><p> </p><span>Read more...</span><!>", 4);
// Tn (k224): 235 B raw
let Tn = {
  m: (a, b) => {
    let c = Sn(), d = c.firstChild, e = d.firstChild, f = d.nextSibling, g = f.firstChild, h = f.nextSibling.nextSibling, i = Da(null, h, b), j = {
      s: d,
      q: null,
      e: h,
      w1: e,
      w3: g,
      c2: i,
      a2_0: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN
    };
    Rn(j, a);
    return j;
  },
  p: Rn,
  l: true
};
// Un (dg272_0): 48 B raw
let Un = [ [ "7:434", "7:446", "7:467" ], false, false, false ];
// Vn (dp272_0): 267 B raw
let Vn = (a, b) => {
  let c = b[0], e = b[2];
  {
    let b = c.n;
    {
      a.g0_0 = b;
      let d = tj({
        $: 7,
        a: e.username
      }), f = e.E, g = c.n;
      if (d !== a.a0) {
        a.w2.setAttribute("href", Re(d));
        a.a0 = d;
      }
      {
        a.a1_0 = f;
        Of("/7:446", () => Ve(a.c1, Nf("/7:446", () => ik(f, ""))));
      }
      {
        a.a2_0 = g;
        Of("/7:467", () => Ve(a.c2, Nf("/7:467", () => jk(g))));
      }
    }
  }
};
// Wn (dr272_0): 25 B raw
let Wn = a => {
  $e(a.c1);
  $e(a.c2);
};
// Xn (dg272_1): 32 B raw
let Xn = [ [ "7:473" ], false, false, false ];
// Yn (dp272_1): 115 B raw
let Yn = (a, b) => {
  let c = b[0];
  {
    let b = c.M;
    {
      a.g1_0 = b;
      let d = c.M;
      {
        a.a3_0 = d;
        Of("/7:473", () => Ve(a.c3, Nf("/7:473", () => Jl(d))));
      }
    }
  }
};
// Zn (dr272_1): 16 B raw
let Zn = a => {
  $e(a.c3);
};
// $n (t265): 14 B raw
let $n = Ca("<!>", 0);
// _n (k265): 55 B raw
let _n = {
  m: () => {
    let c = $n();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// ao (b265): 16 B raw
let ao = {
  t: _n,
  v: null
};
// bo (dg272_2): 32 B raw
let bo = [ [ "7:483" ], false, false, false ];
// co (dp272_2): 212 B raw
let co = (a, b) => {
  let c = b[0], d = b[1];
  {
    {
      a.g2_0 = d;
      a.g2_1 = c;
      let b = Nf("/7:483", () => {
        let a;
        if (d.$ === "Just") {
          let b = d.a;
          a = Ml(c, {
            $: 1,
            a: b,
            b: c.C
          }, {
            $: 2,
            a: b,
            b: c.C
          }, "pull-xs-right");
        } else a = ao;
        return a;
      });
      Of("/7:483", () => Ve(a.c4, b));
    }
  }
};
// eo (dr272_2): 16 B raw
let eo = a => {
  $e(a.c4);
};
// fo (dg272_3): 32 B raw
let fo = [ [ "7:519" ], false, false, false ];
// go (dp272_3): 150 B raw
let go = (a, b) => {
  let c = b[0], f = b[3];
  {
    {
      a.g3_0 = c.title;
      a.g3_1 = c.D;
      a.g3_2 = c.A;
      a.g3_3 = c;
      {
        a.a5_0 = c;
        a.a5_1 = f;
        Of("/7:519", () => Ve(a.c5, Nf("/7:519", () => Nl(c, f))));
      }
    }
  }
};
// ho (dr272_3): 16 B raw
let ho = a => {
  $e(a.c5);
};
// io (p272): 397 B raw
let io = Uf((a, b) => {
  let c = b[0], d = b[1];
  if (c.n !== a.l0_0) {
    a.l0_0 = c.n;
    let g = dk(c.n);
    a.d0 = g;
  }
  let e = a.d0;
  if (c.title !== a.l1_0 || c.D !== a.l1_1 || c.A !== a.l1_2) {
    a.l1_0 = c.title;
    a.l1_1 = c.D;
    a.l1_2 = c.A;
    let h = {
      t: Tn,
      v: Vf([ c ], Lf("", "7:373"))
    };
    a.d1 = h;
  }
  let f = a.d1;
  return [ c, d, e, f ];
}, (a, b) => {
  let c = b[0], d = b[1], e = b[2], f = b[3];
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l;
}, 2, [ Qf(Un, Vn, Wn), Qf(Xn, Yn, Zn), Qf(bo, co, eo), Qf(fo, go, ho) ], false);
// jo (t272): 91 B raw
let jo = Ca("<div class=article-preview><div class=article-meta><a></a><div class=info><!><!>", 0);
// ko (k272): 472 B raw
let ko = {
  m: (a, b) => {
    let c = jo(), d = c.firstChild, e = d.firstChild, f = e.nextSibling, g = f.firstChild, h = g.nextSibling, i = Da(e, null, b), j = Da(f, g, b), k = Da(f, h, b), l = Da(d, null, b), m = Da(c, null, b), n = {
      s: c,
      q: null,
      e: c,
      w2: e,
      c1: i,
      c2: j,
      c3: k,
      c4: l,
      c5: m,
      a0: undefined,
      a1_0: undefined,
      a2_0: undefined,
      a3_0: undefined,
      a5_0: undefined,
      a5_1: undefined,
      l0_0: NaN,
      d0: undefined,
      l1_0: NaN,
      l1_1: NaN,
      l1_2: NaN,
      d1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN,
      g3_0: NaN,
      g3_1: NaN,
      g3_2: NaN,
      g3_3: NaN
    };
    io(n, a);
    return n;
  },
  p: io,
  l: true
};
// lo (dg199_0): 32 B raw
let lo = [ [ "7:282" ], false, false, false ];
// mo (dp199_0): 118 B raw
let mo = (a, b) => {
  let c = b[0];
  {
    let b = c.B;
    {
      a.g0_0 = b;
      let d = c.B;
      {
        a.a0_1 = d;
        Of("/7:282", () => Ve(a.c0, Nf("/7:282", () => Dn(Jn, d))));
      }
    }
  }
};
// no (dr199_0): 16 B raw
let no = a => {
  $e(a.c0);
};
// oo (t177): 66 B raw
let oo = Ca("<div class=article-preview>No articles are here... yet.", 0);
// po (k177): 55 B raw
let po = {
  m: () => {
    let c = oo();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// qo (b177): 16 B raw
let qo = {
  t: po,
  v: null
};
// ro (dg196_0): 42 B raw
let ro = [ [ "$producer/7:318" ], false, false, false ];
// so (dp196_0): 115 B raw
let so = (a, b) => {
  let c = b[0];
  {
    {
      a.g0_0 = c.O;
      a.g0_1 = c.g;
      let b = c.O, d = a => a.C, e = {
        b: Mf(a => to(Zf(c.g), a))
      };
      Xe(a.c0, b, d, e, [ c.g ]);
    }
  }
};
// uo (dr196_0): 16 B raw
let uo = a => {
  Ia(a.c0);
};
// vo (p196): 66 B raw
let vo = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.w || a.c0.l;
}, 1, [ Qf(ro, so, uo) ], false);
// wo (t196): 35 B raw
let wo = Ca("<div class=article-list>", 0);
// xo (k196): 112 B raw
let xo = {
  m: (a, b) => {
    let c = wo(), d = Da(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN,
      g0_1: NaN
    };
    vo(e, a);
    return e;
  },
  p: vo,
  l: true
};
// yo (dg199_1): 32 B raw
let yo = [ [ "7:289" ], false, false, false ];
// zo (dp199_1): 142 B raw
let zo = (a, b) => {
  let c = b[0];
  {
    {
      a.g1_0 = c.O;
      a.g1_1 = c.g;
      let b = Nf("/7:289", () => hc(c.O) ? qo : {
        t: xo,
        v: Vf([ c ], Lf("", "7:308"))
      });
      Of("/7:289", () => Ve(a.c1, b));
    }
  }
};
// Ao (dr199_1): 16 B raw
let Ao = a => {
  $e(a.c1);
};
// Bo (p199): 79 B raw
let Bo = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.l || a.c1.l;
}, 1, [ Qf(lo, mo, no), Qf(yo, zo, Ao) ], false);
// Co (t199): 17 B raw
let Co = Ca("<!><!>", 4);
// Do (k199): 187 B raw
let Do = {
  m: (a, b) => {
    let c = Co(), d = c.firstChild, e = d.nextSibling, f = Da(null, d, b), g = Da(null, e, b), h = {
      s: null,
      q: f,
      e: e,
      c0: f,
      c1: g,
      a0_1: undefined,
      g0_0: NaN,
      g1_0: NaN,
      g1_1: NaN
    };
    Bo(h, a);
    return h;
  },
  p: Bo,
  l: true
};
// Eo (dg337_0): 32 B raw
let Eo = [ [ "7:596" ], false, false, false ];
// Fo (dp337_0): 153 B raw
let Fo = (a, b) => {
  let c = b[0], d = b[1];
  {
    if (c !== a.g0_0 || d.ha !== a.g0_1) {
      a.g0_0 = c;
      a.g0_1 = d.ha;
      let b = c === d.ha;
      if (b !== a.a0) {
        a.a0 = b;
        a.w0.classList.toggle("active", b);
      }
    }
  }
};
// Go (dg337_1): 40 B raw
let Go = [ [ "7:629", "7:655" ], false, false, false ];
// Ho (dp337_1): 166 B raw
let Ho = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g1_0) {
      a.g1_0 = b;
      let d = `page-${Qd(c)}`, e = Qd(c);
      if (d !== a.a1) {
        a.w1.setAttribute("id", d);
        a.a1 = d;
      }
      if (e !== a.a3) {
        a.a3 = e;
        a.w2.data = e;
      }
    }
  }
};
// Io (dg337_2): 24 B raw
let Io = [ [], false, true, false ];
// Jo (dp337_2): 142 B raw
let Jo = (a, b) => {
  let c = b[0], e = b[2];
  {
    if (c !== a.g2_0 || e !== a.g2_1) {
      a.g2_0 = c;
      a.g2_1 = e;
      let b = a => {
        In(a);
        return e(c);
      };
      if (b !== a.a2) {
        a.a2 = b;
        a.w1.$$click = b;
      }
    }
  }
};
// Ko (p337): 79 B raw
let Ko = Uf((a, b) => b, (a, b) => {}, 3, [ Qf(Eo, Fo, null), Qf(Go, Ho, null), Qf(Io, Jo, null) ], true);
// Lo (t337): 56 B raw
let Lo = Ca("<li class=page-item><a class=page-link href> ", 0);
// Mo (k337): 260 B raw
let Mo = {
  m: (a, b) => {
    let c = Lo(), d = c.firstChild, e = d.firstChild;
    d.$$clickX = Se;
    ff(d, "click", 0);
    if (b !== null) d.$$cx = b;
    let f = {
      s: c,
      q: null,
      e: c,
      w0: c,
      w1: d,
      w2: e,
      a0: false,
      a1: undefined,
      a2: undefined,
      a3: undefined,
      g0_0: NaN,
      g0_1: NaN,
      g1_0: NaN,
      g2_0: NaN,
      g2_1: NaN
    };
    Ko(f, a);
    return f;
  },
  p: Ko
};
// No (dg339_0): 42 B raw
let No = [ [ "$producer/7:575" ], false, false, false ];
// Oo (dp339_0): 225 B raw
let Oo = (a, b) => {
  let c = b[0], d = b[1], e = b[2];
  {
    {
      a.g0_0 = c;
      a.g0_1 = e;
      a.g0_2 = d.ha;
      let b = Ub(c), f = {
        m: (g, h, a) => {
          let b = Vf([ g, d, e ], Lf("", "7:594"));
          return Mo.m(b, a);
        },
        p: (a, g) => {
          let b = Vf([ g, d, e ], Lf("", "7:594"));
          Mo.p(a, b);
        }
      };
      Ye(a.c0, b, f, [ d.ha, e ]);
    }
  }
};
// Po (dr339_0): 16 B raw
let Po = a => {
  Ia(a.c0);
};
// Qo (p339): 66 B raw
let Qo = Uf((a, b) => b, (a, b) => {
  a.l = a.c0.w || a.c0.l;
}, 3, [ Qf(No, Oo, Po) ], false);
// Ro (t339): 32 B raw
let Ro = Ca("<ul class=pagination>", 0);
// So (k339): 121 B raw
let So = {
  m: (a, b) => {
    let c = Ro(), d = Da(c, null, b), e = {
      s: c,
      q: null,
      e: c,
      c0: d,
      g0_0: NaN,
      g0_1: NaN,
      g0_2: NaN
    };
    Qo(e, a);
    return e;
  },
  p: Qo,
  l: true
};
// To (t343): 14 B raw
let To = Ca("<!>", 0);
// Uo (k343): 55 B raw
let Uo = {
  m: () => {
    let c = To();
    return {
      s: c,
      q: null,
      e: c
    };
  },
  p: () => {}
};
// Vo (b343): 16 B raw
let Vo = {
  t: Uo,
  v: null
};
// to (viewPreview): 45 B raw
let to = (a, b) => ({
  t: ko,
  v: Vf([ b, a ], Lf("", "7:414"))
});
// lp (viewArticles): 39 B raw
let lp = a => ({
  t: Do,
  v: Vf([ a ], Lf("", "7:279"))
});
// mp (viewPagination): 80 B raw
let mp = (b, c) => {
  let e = a(c.va + 10 - 1);
  return e > 1 ? {
    t: So,
    v: Vf([ e, c, b ], Lf("", "7:565"))
  } : Vo;
};