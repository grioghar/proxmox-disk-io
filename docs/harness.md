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
scp YOUR-NODE:/usr/share/javascript/extjs/ext-all.js            "$H/ext6/"
scp YOUR-NODE:/usr/share/javascript/extjs/charts.js             "$H/ext6/"
scp YOUR-NODE:/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js "$H/"
scp YOUR-NODE:/usr/share/pve-manager/js/pvemanagerlib.js        "$H/js/"
cp  js/pve-disk-io.js                                      "$H/js/"

# Stylesheets, so the result actually looks like Proxmox.
rsync -a YOUR-NODE:/usr/share/javascript/extjs/theme-crisp      "$H/ext6/"
rsync -a YOUR-NODE:/usr/share/javascript/extjs/crisp            "$H/ext6/"
rsync -a YOUR-NODE:/usr/share/fonts-font-awesome/css            "$H/pve2/fa/"
rsync -a YOUR-NODE:/usr/share/fonts-font-awesome/fonts          "$H/pve2/fa/"
rsync -a YOUR-NODE:/usr/share/fonts-font-logos/                 "$H/pve2/font-logos/"
rsync -a YOUR-NODE:/usr/share/pve-manager/css/                  "$H/pve2/css/"
rsync -a YOUR-NODE:/usr/share/javascript/proxmox-widget-toolkit/css/    "$H/pwt/css/"
rsync -a YOUR-NODE:/usr/share/javascript/proxmox-widget-toolkit/themes/ "$H/pwt/themes/"

cd "$H" && python3 -m http.server 8899 --bind 127.0.0.1
```

`index.html` mirrors `/usr/share/pve-manager/index.html.tpl`: the same script
order, the `Proxmox` setup object, the `gettext` shims, and the
`#x-history-field` form. Shim **both** translation functions -- `proxmoxlib.js`
calls `ngettext` while building `Proxmox.Utils`, and without it that whole
object is left undefined, which surfaces much later as an unrelated-looking
`Cannot read properties of undefined (reading 'defaultText')` from
`pvemanagerlib.js`:

```js
function gettext(buf) { return buf; }
function ngettext(s, p, n) { return n === 1 ? s : p; }
``` It also records load-time exceptions:

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
ssh YOUR-NODE 'for i in $(seq 1 8); do pvesh get /nodes/NODENAME/disks/io \
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

The Summary graphs load through `Proxmox.RestProxy`, i.e. the real Ajax stack,
which is awkward to fake faithfully. Loading the recorded rows straight into the
chart's store gives it the same records it would get from the node:

```js
let chart = card.down('proxmoxRRDChart');
chart.getStore().stopUpdate();
chart.getStore().loadRawData(window.__samples.rrddata);
chart.redraw();
```

Geometry is worth asserting rather than eyeballing -- compare against a stock
graph in the same container, which is the thing these have to line up with:

```js
let c = summary.down('#itemcontainer');
c.down('proxmoxRRDChart').body.getHeight();            // stock plot height
c.down('pveNodeDiskIOSummaryChart').down('proxmoxRRDChart').body.getHeight();
```

Drive the viewport width across the column-layout breakpoint too
(`Proxmox.Utils.updateColumnWidth` switches between one and two columns), and
check the legend is not clipping: `el.scrollWidth > el.clientWidth` on the
legend element means entries have run off the right-hand edge.

The per-guest live page is driven the same way, through `PVE.lxc.Config`
(or `PVE.qemu.Config`) instead of `PVE.node.Config`. Both **throw
`no workspace specified`** before they build anything, so stub one — it needs
nothing real:

```js
let cfg = Ext.create('PVE.lxc.Config', {
  pveSelNode: { data: { node: 'proxmox', vmid: '3134', type: 'lxc',
                        id: 'lxc/3134', text: 'qbittorrent' } },
  showSearch: false,
  workspace: { onlineHelp: () => {}, setUrl: () => {}, updateUserInfo: () => {} },
});
cfg.activateCard('disk-io');
```

The card title will read `Container 3134 (undefined)`, which is PVE composing it
from a field the real tree supplies and the stub omits — not a fault in
anything under test.

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
diff <(curl -sk https://YOUR-NODE:8006/pve2/js/pve-disk-io.js) js/pve-disk-io.js
```
