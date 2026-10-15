// Me: 16 B raw
let Me = ge("<a></a>");
// Re (props): 429 B raw
let Re = e => {
  const {getParams: t} = Ie();
  return (() => {
    const n = Me.cloneNode(!0);
    return n.$$click = () => window.scrollTo(0, 0), me(n, () => e.children), $(r => {
      var o;
      const i = e.class, l = e.active || (null === (o = t()) || void 0 === o ? void 0 : o.routeName) === e.route, s = `#/${e.href || e.route}`;
      return i !== r._v$ && (n.className = r._v$ = i), l !== r._v$2 && n.classList.toggle("active", r._v$2 = l), 
      s !== r._v$3 && he(n, "href", r._v$3 = s), r;
    }, {
      _v$: void 0,
      _v$2: void 0,
      _v$3: void 0
    }), n;
  })();
};
// He: 36 B raw
let He = ge('<i class="ion-compose"></i>');
// Ge: 35 B raw
let Ge = ge('<li class="nav-item"></li>');
// Ke: 35 B raw
let Ke = ge('<i class="ion-gear-a"></i>');
// We: 149 B raw
let We = ge('<nav class="navbar navbar-light"><div class="container"><ul class="nav navbar-nav pull-xs-right"><li class="nav-item"></li></ul></div></nav>');
// Ye: 1043 B raw
let Ye = () => {
  const [e] = ze();
  return (() => {
    const t = We.cloneNode(!0), n = t.firstChild, r = n.firstChild, o = r.firstChild;
    return me(n, Z(Re, {
      class: "navbar-brand",
      route: "",
      get children() {
        return e.appName;
      }
    }), r), me(o, Z(Re, {
      class: "nav-link",
      route: "",
      children: "Home"
    })), me(r, Z(le, {
      get when() {
        return e.currentUser;
      },
      get fallback() {
        return [ (() => {
          const e = Ge.cloneNode(!0);
          return me(e, Z(Re, {
            class: "nav-link",
            route: "login",
            children: "Sign in"
          })), e;
        })(), (() => {
          const e = Ge.cloneNode(!0);
          return me(e, Z(Re, {
            class: "nav-link",
            route: "register",
            children: "Sign up"
          })), e;
        })() ];
      },
      get children() {
        return [ (() => {
          const e = Ge.cloneNode(!0);
          return me(e, Z(Re, {
            class: "nav-link",
            route: "editor",
            get children() {
              return [ He.cloneNode(!0), " New Post" ];
            }
          })), e;
        })(), (() => {
          const e = Ge.cloneNode(!0);
          return me(e, Z(Re, {
            class: "nav-link",
            route: "settings",
            get children() {
              return [ Ke.cloneNode(!0), " Settings" ];
            }
          })), e;
        })(), (() => {
          const t = Ge.cloneNode(!0);
          return me(t, Z(Re, {
            class: "nav-link",
            route: "profile",
            get href() {
              return `@${e.currentUser.username}`;
            },
            get children() {
              return e.currentUser.username;
            }
          })), t;
        })() ];
      }
    }), null), t;
  })();
};