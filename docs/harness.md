# Offline browser harness

A live Proxmox node is a poor place to debug web UI changes: a JavaScript
exception at load time aborts the `Ext.onReady` chain and the whole interface
comes up blank. This harness runs the real ExtJS, `proxmoxlib.js` and
`pvemanagerlib.js` from a node against a local static server, so panels can be
constructed and driven without touching anything.

## Build it

```bash
H=/tmp/pve-harness
mkdir -p "$H"/{ext6,js}

# Production build. Swap for ext-all-debug.js / charts-debug.js while
# debugging: the stack traces are far more useful.
scp pve1:/usr/share/javascript/extjs/ext-all.js            "$H/ext6/"
scp pve1:/usr/share/javascript/extjs/charts.js             "$H/ext6/"
scp pve1:/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js "$H/"
scp pve1:/usr/share/pve-manager/js/pvemanagerlib.js        "$H/js/"
cp  js/pve-disk-io.js                                      "$H/js/"

# Stylesheets, so the result actually looks like Proxmox.
rsync -a pve1:/usr/share/javascript/extjs/theme-crisp      "$H/ext6/"
rsync -a pve1:/usr/share/javascript/extjs/crisp            "$H/ext6/"
rsync -a pve1:/usr/share/fonts-font-awesome/css            "$H/pve2/fa/"
rsync -a pve1:/usr/share/fonts-font-awesome/fonts          "$H/pve2/fa/"
rsync -a pve1:/usr/share/fonts-font-logos/                 "$H/pve2/font-logos/"
rsync -a pve1:/usr/share/pve-manager/css/                  "$H/pve2/css/"
rsync -a pve1:/usr/share/javascript/proxmox-widget-toolkit/css/    "$H/pwt/css/"
rsync -a pve1:/usr/share/javascript/proxmox-widget-toolkit/themes/ "$H/pwt/themes/"

cd "$H" && python3 -m http.server 8899 --bind 127.0.0.1
```

`index.html` mirrors `/usr/share/pve-manager/index.html.tpl`: the same script
order, the `Proxmox` setup object, the `gettext` shims, and the
`#x-history-field` form. It also records load-time exceptions:

```js
window.__errors = [];
window.addEventListener('error', (e) => window.__errors.push({
  msg: String(e.message),
  stack: e.error && e.error.stack,
}));
```

## Record real data to replay

The endpoint returns monotonic counters, so any two samples are enough to
produce real rates:

```bash
ssh pve1 'for i in $(seq 1 8); do pvesh get /nodes/proxmox/disks/io \
  --output-format json; echo; sleep 2; done' > samples.ndjson
```

Convert to a JSON array as `samples.json` next to `index.html`.

## Drive it

Stub the API **before** constructing anything, and answer only the endpoint
under test — PVE's other widgets throw if fed data they cannot parse:

```js
Proxmox.Utils.API2Request = function (opts) {
  if (String(opts.url || '').indexOf('/disks/io') === -1) { return; }
  let s = window.__samples[Math.min(window.__idx++, window.__samples.length - 1)];
  opts.success.call(opts.scope || window, { result: { data: s } });
};
Ext.Ajax.request = function () {};

// PVE.StateProvider needs Ext.History wiring; a plain provider with one stub
// is enough to build every card.
let provider = Ext.create('Ext.state.Provider');
provider.encodeHToken = () => '';
Ext.state.Manager.setProvider(provider);
Ext.state.Manager.set('GuiCap', { nodes: { 'Sys.Audit': 1 }, vms: {}, storage: {},
  access: {}, dc: {}, sdn: {}, mapping: {} });

let vp = Ext.create('Ext.container.Viewport', { layout: 'fit' });
let panel = Ext.create('PVE.node.Config', {
  pveSelNode: { data: { node: 'proxmox', id: 'node/proxmox', text: 'proxmox' } },
  showSearch: false,
});
vp.add(panel);
panel.activateCard('disk-io');

let io = panel.down('pveNodeDiskIO');
io.stopPolling();
io.previous = null;
for (let i = 0; i < 8; i++) { io.poll(); }   // synchronous stub, no timers
```

Keep the replay stub synchronous. A hidden browser tab throttles `setTimeout`,
so an async replay that awaits between polls will stall.

## Check the dark theme

The dark theme is a separate stylesheet that sets `color-scheme: dark` on
`:root`:

```js
let l = document.createElement('link');
l.rel = 'stylesheet';
l.href = '/pwt/themes/theme-proxmox-dark.css';
document.head.appendChild(l);
l.onload = () => window.__io.chart.checkThemeColors();
```

That `color-scheme` is what makes CSS `light-dark()` track the active theme,
which is how the panel keeps its accent colours readable in both.

## Verify what you tested is what ships

```bash
diff <(curl -sk https://pve.grio.co:8006/pve2/js/pve-disk-io.js) js/pve-disk-io.js
```
