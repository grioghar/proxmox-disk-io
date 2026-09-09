// Disk I/O Activity panel for Proxmox VE.
//
// Adds a live view of physical disk throughput, IOPS, utilization and latency
// under Node -> Disks, together with the attribution of that I/O to the
// containers and VMs responsible for it.
//
// Data comes from GET /nodes/{node}/disks/io, which returns monotonic
// counters. All rates are derived here from the delta between two samples, so
// the server stays stateless and the numbers reflect real elapsed time.

// Note: deliberately not in strict mode. ExtJS implements callParent() via
// Function.prototype.caller, which is null in strict mode, so every
// callParent() in a strict-mode file throws.
Ext.onReady(function () {
    const STYLE_ID = 'pve-disk-io-style';
    if (!document.getElementById(STYLE_ID)) {
        let style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = `
.pve-diskio-kpis {
    display: flex;
    align-items: stretch;
    height: 100%;
    gap: 1px;
    background: var(--pwt-chart-grid-stroke, #dddddd);
}
.pve-diskio-kpi {
    flex: 1 1 0;
    min-width: 0;
    padding: 8px 12px;
    background: var(--pwt-panel-background, #ffffff);
    display: flex;
    flex-direction: column;
    justify-content: center;
}
.pve-diskio-kpi-label {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.4px;
    opacity: 0.65;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
.pve-diskio-kpi-label i {
    width: 13px;
    text-align: center;
    margin-right: 3px;
}
.pve-diskio-kpi-value {
    font-size: 19px;
    line-height: 24px;
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
.pve-diskio-kpi-sub {
    font-size: 11px;
    opacity: 0.6;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}
/* PVE's dark theme sets color-scheme:dark on :root, so light-dark() follows
   whichever theme is active. The plain declaration comes first so browsers
   without light-dark() still get the readable light-theme colour. The text
   green is darker than the chart's #94ae0a, which has too little contrast on
   a white background. */
.pve-diskio-read {
    color: #115fa6;
    color: light-dark(#115fa6, #4db5ff);
}
.pve-diskio-write {
    color: #6d8007;
    color: light-dark(#6d8007, #b3d117);
}
.pve-diskio-busy {
    color: #cf5000;
    color: light-dark(#cf5000, #ffae0b);
}
.pve-diskio-tag {
    display: inline-block;
    padding: 0 5px;
    border-radius: 3px;
    font-size: 10px;
    line-height: 15px;
    text-transform: uppercase;
    letter-spacing: 0.3px;
    border: 1px solid var(--pwt-chart-grid-stroke, #dddddd);
    opacity: 0.85;
}
.pve-diskio-idle { opacity: 0.45; }
`;
        document.head.appendChild(style);
    }

    // ---------------------------------------------------------------- utils

    Ext.define('PVE.node.DiskIOUtils', {
        singleton: true,

        // A counter that went backwards means the device or guest was reset;
        // report nothing rather than a nonsense spike.
        rate: function (current, previous, dt) {
            if (current === undefined || previous === undefined || !(dt > 0)) {
                return 0;
            }
            let delta = current - previous;
            return delta > 0 ? delta / dt : 0;
        },

        renderRate: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">0</span>';
            }
            return Proxmox.Utils.format_size(value) + '/s';
        },

        renderReadRate: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">0</span>';
            }
            return '<span class="pve-diskio-read">' + Proxmox.Utils.format_size(value) + '/s</span>';
        },

        renderWriteRate: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">0</span>';
            }
            return (
                '<span class="pve-diskio-write">' + Proxmox.Utils.format_size(value) + '/s</span>'
            );
        },

        renderIops: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">0</span>';
            }
            if (value >= 10000) {
                return Ext.util.Format.number(value / 1000, '0.0') + 'k';
            }
            return Ext.util.Format.number(value, value < 10 ? '0.0' : '0');
        },

        renderMillis: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">-</span>';
            }
            let digits = value < 10 ? '0.00' : '0.0';
            return Ext.util.Format.number(value, digits) + ' ms';
        },

        renderQueue: function (value) {
            if (!value) {
                return '<span class="pve-diskio-idle">0</span>';
            }
            return Ext.util.Format.number(value, '0.00');
        },

        kindIcon: function (kind, transport) {
            if (transport === 'usb') {
                return 'fa fa-usb';
            }
            if (kind === 'nvme' || kind === 'ssd') {
                return 'fa fa-bolt';
            }
            return 'fa fa-hdd-o';
        },

        renderDevice: function (value, metaData, record) {
            let icon = PVE.node.DiskIOUtils.kindIcon(record.data.kind, record.data.transport);
            return '<i class="' + icon + '"></i> ' + Ext.htmlEncode(value);
        },

        renderBus: function (value, metaData, record) {
            let label = value === 'unknown' ? record.data.kind : value;
            return '<span class="pve-diskio-tag">' + Ext.htmlEncode(label) + '</span>';
        },

        renderConsumer: function (value, metaData, record) {
            let icons = {
                lxc: 'fa fa-cube',
                qemu: 'fa fa-desktop',
                host: 'fa fa-server',
            };
            let icon = icons[record.data.type] || 'fa fa-question-circle-o';
            let text = '<i class="' + icon + '"></i> ' + Ext.htmlEncode(value);

            // Worth showing: these bytes were measured against the FUSE daemon
            // and handed here, rather than charged to this consumer directly.
            if (record.data.viaPool) {
                text += ' <span class="pve-diskio-tag">' + gettext('via pool') + '</span>';
            }
            return text;
        },

        // Host units have no vmid; the store types the column as a number, so
        // an absent one arrives here as 0 and must not read as a real guest id.
        renderVmid: function (value, metaData, record) {
            if (!value) {
                let label = record.data.type === 'host' ? gettext('host') : '-';
                return '<span class="pve-diskio-idle">' + label + '</span>';
            }
            return value;
        },
    });

    // ------------------------------------------------------------ KPI strip

    Ext.define('PVE.node.DiskIOSummary', {
        extend: 'Ext.Component',
        alias: 'widget.pveNodeDiskIOSummary',

        cls: 'pve-diskio-summary',
        height: 62,

        tpl: [
            '<div class="pve-diskio-kpis">',
            '<tpl for="tiles">',
            '<div class="pve-diskio-kpi">',
            '<div class="pve-diskio-kpi-label"><i class="{icon}"></i>{label}</div>',
            '<div class="pve-diskio-kpi-value {cls}">{value}</div>',
            '<div class="pve-diskio-kpi-sub">{sub}</div>',
            '</div>',
            '</tpl>',
            '</div>',
        ],

        initComponent: function () {
            let me = this;
            me.callParent();
            me.update({ tiles: me.emptyTiles() });
        },

        emptyTiles: function () {
            return [
                { icon: 'fa fa-arrow-down', label: gettext('Read'), value: '-', sub: '', cls: '' },
                { icon: 'fa fa-arrow-up', label: gettext('Write'), value: '-', sub: '', cls: '' },
                { icon: 'fa fa-exchange', label: gettext('IOPS'), value: '-', sub: '', cls: '' },
                { icon: 'fa fa-tachometer', label: gettext('Busiest Disk'), value: '-', sub: '', cls: '' },
                { icon: 'fa fa-fire', label: gettext('Top Consumer'), value: '-', sub: '', cls: '' },
            ];
        },
    });

    // ----------------------------------------------------------- main panel

    Ext.define('PVE.node.DiskIO', {
        extend: 'Ext.panel.Panel',
        alias: 'widget.pveNodeDiskIO',

        onlineHelp: 'chapter_storage',

        layout: { type: 'vbox', align: 'stretch' },
        border: false,

        // Rolling window of samples kept for the chart.
        historyLength: 180,

        interval: 3,
        paused: false,

        // devno of the disk the consumer grid is scoped to, or null for "all".
        selectedDisk: null,

        // Host units that have done I/O since the panel opened, so they keep
        // their row instead of flickering in and out.
        activeHostUnits: null,

        // On by default: without it a FUSE pool's daemon absorbs the credit for
        // everything its callers do, which is the opposite of what this panel
        // is for. Can be turned off to avoid the holder scan.
        traceFuse: true,

        initComponent: function () {
            let me = this;

            let nodename = me.nodename || me.pveSelNode?.data?.node;
            if (!nodename) {
                throw 'no node name specified';
            }
            me.nodename = nodename;
            me.activeHostUnits = {};

            me.diskStore = Ext.create('Ext.data.Store', {
                fields: [
                    'dev',
                    'devno',
                    'model',
                    'serial',
                    'kind',
                    'transport',
                    'scheduler',
                    'topGuest',
                    { name: 'size', type: 'number' },
                    { name: 'readRate', type: 'number' },
                    { name: 'writeRate', type: 'number' },
                    { name: 'totalRate', type: 'number' },
                    { name: 'readIops', type: 'number' },
                    { name: 'writeIops', type: 'number' },
                    { name: 'iops', type: 'number' },
                    { name: 'util', type: 'number' },
                    { name: 'queue', type: 'number' },
                    { name: 'latency', type: 'number' },
                    { name: 'inFlight', type: 'number' },
                ],
                sorters: [{ property: 'dev', direction: 'ASC' }],
            });

            me.guestStore = Ext.create('Ext.data.Store', {
                fields: [
                    'id',
                    'name',
                    'type',
                    'source',
                    'disks',
                    { name: 'viaPool', type: 'boolean' },
                    { name: 'vmid', type: 'number' },
                    { name: 'readRate', type: 'number' },
                    { name: 'writeRate', type: 'number' },
                    { name: 'totalRate', type: 'number' },
                    { name: 'readIops', type: 'number' },
                    { name: 'writeIops', type: 'number' },
                    { name: 'iops', type: 'number' },
                    { name: 'share', type: 'number' },
                    { name: 'partial', type: 'boolean' },
                ],
                // Most rows sit at zero, and ties do not order deterministically
                // -- without the second key they reshuffle on every poll and the
                // grid churns under the pointer.
                sorters: [
                    { property: 'totalRate', direction: 'DESC' },
                    { property: 'id', direction: 'ASC' },
                ],
            });

            me.chartStore = Ext.create('Ext.data.Store', {
                fields: [
                    { name: 'time', type: 'number' },
                    { name: 'read', type: 'number' },
                    { name: 'write', type: 'number' },
                ],
                data: [],
            });

            me.summary = Ext.create('PVE.node.DiskIOSummary');

            me.chart = Ext.create('Proxmox.widget.RRDChart', {
                title: gettext('Throughput'),
                store: me.chartStore,
                fields: ['read', 'write'],
                fieldTitles: [gettext('Read'), gettext('Write')],
                colors: ['#115fa6', '#94ae0a'],
                unit: 'bytespersecond',
                height: 170,
                border: false,
            });

            me.disksGrid = me.buildDisksGrid();
            me.guestsGrid = me.buildGuestsGrid();

            me.items = [
                me.summary,
                me.chart,
                me.disksGrid,
                { xtype: 'splitter' },
                me.guestsGrid,
            ];

            me.tbar = me.buildToolbar();

            me.callParent();

            me.on('afterrender', me.startPolling, me);
            me.on('destroy', me.stopPolling, me);
        },

        buildToolbar: function () {
            let me = this;

            return [
                {
                    xtype: 'button',
                    text: gettext('Pause'),
                    iconCls: 'fa fa-pause',
                    handler: function (button) {
                        me.paused = !me.paused;
                        button.setText(me.paused ? gettext('Resume') : gettext('Pause'));
                        button.setIconCls(me.paused ? 'fa fa-play' : 'fa fa-pause');
                        if (me.paused) {
                            me.stopPolling();
                        } else {
                            // Drop the stale baseline so the first sample after
                            // resuming is not averaged over the whole pause.
                            me.previous = null;
                            me.startPolling();
                        }
                    },
                },
                '-',
                {
                    xtype: 'label',
                    text: gettext('Refresh') + ':',
                },
                {
                    xtype: 'combobox',
                    width: 90,
                    editable: false,
                    queryMode: 'local',
                    value: me.interval,
                    displayField: 'text',
                    valueField: 'value',
                    store: {
                        fields: ['value', 'text'],
                        data: [
                            { value: 1, text: '1 s' },
                            { value: 2, text: '2 s' },
                            { value: 3, text: '3 s' },
                            { value: 5, text: '5 s' },
                            { value: 10, text: '10 s' },
                            { value: 30, text: '30 s' },
                        ],
                    },
                    listeners: {
                        change: function (field, value) {
                            me.interval = value;
                            me.previous = null;
                            if (!me.paused) {
                                me.startPolling();
                            }
                        },
                    },
                },
                '-',
                {
                    xtype: 'checkbox',
                    boxLabel: gettext('Show unused devices'),
                    listeners: {
                        change: function (field, value) {
                            me.showUnused = value;
                            me.refreshDiskFilter();
                        },
                    },
                },
                '-',
                {
                    xtype: 'checkbox',
                    boxLabel: gettext('Trace FUSE pool'),
                    checked: true,
                    // Finding which processes hold files open on the pool costs
                    // a few hundred ms, so it is not paid unless asked for.
                    autoEl: {
                        tag: 'div',
                        'data-qtip': gettext(
                            'Attribute I/O that reaches the disks through a FUSE pool such as'
                                + ' mergerfs back to the container that asked for it. These rows'
                                + ' are measured at the syscall level, so they are not directly'
                                + ' comparable with the block level figures above.',
                        ),
                    },
                    listeners: {
                        change: function (field, value) {
                            me.traceFuse = value;
                            me.previous = null;
                            if (!me.paused) {
                                me.startPolling();
                            }
                        },
                    },
                },
                '->',
                {
                    xtype: 'tbtext',
                    itemId: 'scopeText',
                    text: '',
                },
                {
                    xtype: 'button',
                    itemId: 'clearScope',
                    text: gettext('Show all disks'),
                    iconCls: 'fa fa-times',
                    hidden: true,
                    handler: function () {
                        me.disksGrid.getSelectionModel().deselectAll();
                    },
                },
            ];
        },

        buildDisksGrid: function () {
            let me = this;
            let U = PVE.node.DiskIOUtils;

            return Ext.create('Ext.grid.Panel', {
                flex: 1,
                border: false,
                store: me.diskStore,
                title: gettext('Physical Disks'),
                emptyText: gettext('Sampling...'),
                // preserveScrollOnRefresh: the store is re-sorted on every poll,
                // and a refresh otherwise takes the viewport back with it.
                viewConfig: {
                    stripeRows: true,
                    deferEmptyText: false,
                    preserveScrollOnRefresh: true,
                },
                columns: [
                    {
                        text: gettext('Device'),
                        dataIndex: 'dev',
                        width: 110,
                        renderer: U.renderDevice,
                    },
                    {
                        text: gettext('Bus'),
                        dataIndex: 'transport',
                        width: 70,
                        align: 'center',
                        renderer: U.renderBus,
                    },
                    {
                        text: gettext('Model'),
                        dataIndex: 'model',
                        flex: 1,
                        minWidth: 130,
                        renderer: Ext.String.htmlEncode,
                    },
                    {
                        text: gettext('Size'),
                        dataIndex: 'size',
                        width: 85,
                        align: 'right',
                        hidden: true,
                        renderer: (v) => Proxmox.Utils.format_size(v),
                    },
                    {
                        text: gettext('Read'),
                        dataIndex: 'readRate',
                        width: 108,
                        align: 'right',
                        renderer: U.renderReadRate,
                    },
                    {
                        text: gettext('Write'),
                        dataIndex: 'writeRate',
                        width: 108,
                        align: 'right',
                        renderer: U.renderWriteRate,
                    },
                    {
                        text: gettext('IOPS'),
                        dataIndex: 'iops',
                        width: 70,
                        align: 'right',
                        renderer: U.renderIops,
                    },
                    {
                        text: gettext('Read IOPS'),
                        dataIndex: 'readIops',
                        width: 85,
                        align: 'right',
                        hidden: true,
                        renderer: U.renderIops,
                    },
                    {
                        text: gettext('Write IOPS'),
                        dataIndex: 'writeIops',
                        width: 85,
                        align: 'right',
                        hidden: true,
                        renderer: U.renderIops,
                    },
                    {
                        text: gettext('Busy'),
                        dataIndex: 'util',
                        width: 100,
                        xtype: 'widgetcolumn',
                        widget: {
                            xtype: 'progressbarwidget',
                            textTpl: '{percent:number("0")}%',
                        },
                    },
                    {
                        text: gettext('Latency'),
                        dataIndex: 'latency',
                        width: 85,
                        align: 'right',
                        renderer: U.renderMillis,
                    },
                    {
                        text: gettext('Queue'),
                        dataIndex: 'queue',
                        width: 70,
                        align: 'right',
                        hidden: true,
                        renderer: U.renderQueue,
                    },
                    {
                        text: gettext('In Flight'),
                        dataIndex: 'inFlight',
                        width: 75,
                        align: 'right',
                        hidden: true,
                    },
                    {
                        text: gettext('Top Consumer'),
                        dataIndex: 'topGuest',
                        width: 150,
                        renderer: function (value) {
                            if (!value) {
                                return '<span class="pve-diskio-idle">-</span>';
                            }
                            return Ext.htmlEncode(value);
                        },
                    },
                ],
                listeners: {
                    selectionchange: function (model, selected) {
                        me.selectedDisk = selected.length ? selected[0].data.devno : null;
                        me.refreshScopeIndicator();
                        if (me.latest) {
                            me.refreshFromSample(me.latest.current, me.latest.previous, me.latest.dt);
                        }
                    },
                },
            });
        },

        buildGuestsGrid: function () {
            let me = this;
            let U = PVE.node.DiskIOUtils;

            return Ext.create('Ext.grid.Panel', {
                flex: 1.3,
                border: false,
                store: me.guestStore,
                title: gettext('Consumers'),
                emptyText: gettext('Sampling...'),
                // preserveScrollOnRefresh: the store is re-sorted on every poll,
                // and a refresh otherwise takes the viewport back with it.
                viewConfig: {
                    stripeRows: true,
                    deferEmptyText: false,
                    preserveScrollOnRefresh: true,
                },
                columns: [
                    {
                        text: gettext('ID'),
                        dataIndex: 'vmid',
                        // Wide enough for a vmid plus the "fuse" tag.
                        width: 100,
                        renderer: U.renderVmid,
                    },
                    {
                        text: gettext('Name'),
                        dataIndex: 'name',
                        flex: 1,
                        minWidth: 170,
                        renderer: U.renderConsumer,
                    },
                    {
                        text: gettext('Read'),
                        dataIndex: 'readRate',
                        width: 108,
                        align: 'right',
                        renderer: U.renderReadRate,
                    },
                    {
                        text: gettext('Write'),
                        dataIndex: 'writeRate',
                        width: 108,
                        align: 'right',
                        renderer: U.renderWriteRate,
                    },
                    {
                        text: gettext('IOPS'),
                        dataIndex: 'iops',
                        width: 70,
                        align: 'right',
                        renderer: U.renderIops,
                    },
                    {
                        text: gettext('Share'),
                        dataIndex: 'share',
                        width: 90,
                        xtype: 'widgetcolumn',
                        widget: {
                            xtype: 'progressbarwidget',
                            textTpl: '{percent:number("0")}%',
                        },
                    },
                    {
                        text: gettext('Disks'),
                        dataIndex: 'disks',
                        width: 150,
                        renderer: function (value) {
                            if (!value) {
                                return '<span class="pve-diskio-idle">-</span>';
                            }
                            return Ext.htmlEncode(value);
                        },
                    },
                ],
            });
        },

        // ------------------------------------------------------- data cycle

        startPolling: function () {
            let me = this;
            me.stopPolling();
            me.poll();
            me.pollTask = Ext.TaskManager.start({
                run: me.poll,
                interval: me.interval * 1000,
                scope: me,
            });
        },

        stopPolling: function () {
            let me = this;
            if (me.pollTask) {
                Ext.TaskManager.stop(me.pollTask);
                me.pollTask = undefined;
            }
        },

        poll: function () {
            let me = this;
            if (me.pollInFlight || me.isDestroyed) {
                return;
            }
            me.pollInFlight = true;

            Proxmox.Utils.API2Request({
                url: '/nodes/' + me.nodename + '/disks/io' + (me.traceFuse ? '?fuse=1' : ''),
                method: 'GET',
                success: function (response) {
                    me.pollInFlight = false;
                    if (me.isDestroyed) {
                        return;
                    }
                    me.consume(response.result.data);
                },
                failure: function (response) {
                    me.pollInFlight = false;
                    if (me.isDestroyed) {
                        return;
                    }
                    Proxmox.Utils.setErrorMask(me.disksGrid, response.htmlStatus);
                },
            });
        },

        consume: function (sample) {
            let me = this;

            Proxmox.Utils.setErrorMask(me.disksGrid, false);

            let previous = me.previous;
            me.previous = sample;

            if (!previous) {
                // First sample: show the hardware straight away, rates follow.
                me.refreshDiskHardware(sample);
                return;
            }

            let dt = sample.time - previous.time;
            // A long gap (tab in the background, laptop asleep) would average
            // the whole interval; re-baseline instead of reporting a fake calm.
            if (dt <= 0 || dt > Math.max(30, me.interval * 6)) {
                return;
            }

            me.latest = { current: sample, previous: previous, dt: dt };
            me.refreshFromSample(sample, previous, dt);
        },

        refreshDiskHardware: function (sample) {
            let me = this;
            let rows = sample.disks.map((disk) => ({
                dev: disk.dev,
                devno: disk.devno,
                model: disk.model,
                serial: disk.serial,
                kind: disk.kind,
                transport: disk.transport,
                scheduler: disk.scheduler,
                size: disk.size,
                readRate: 0,
                writeRate: 0,
                totalRate: 0,
                readIops: 0,
                writeIops: 0,
                iops: 0,
                util: 0,
                queue: 0,
                latency: 0,
                inFlight: disk.in_flight,
                topGuest: '',
            }));
            me.diskStore.setData(rows);
            me.refreshDiskFilter();
        },

        refreshFromSample: function (current, previous, dt) {
            let me = this;
            let U = PVE.node.DiskIOUtils;

            let prevDisks = {};
            previous.disks.forEach((d) => {
                prevDisks[d.devno] = d;
            });

            let prevGuests = {};
            previous.guests.forEach((g) => {
                prevGuests[g.id] = g;
            });

            let byId = {};
            current.guests.forEach((g) => {
                byId[g.id] = g;
            });

            // --- per consumer, and per (consumer, disk) --------------------
            let guestRows = [];
            let rowsById = {};
            let perDisk = {}; // devno -> [{name, rate}]
            let diskGuestRate = {}; // devno -> total attributed rate

            // A FUSE daemon does none of this work for itself. Its block level
            // bytes are held back here and handed to whoever asked for them.
            let poolRates = {}; // devno -> {read, write}
            let poolNames = {};

            let credit = function (devno, label, rate) {
                if (rate <= 0) {
                    return;
                }
                (perDisk[devno] = perDisk[devno] || []).push({ name: label, rate: rate });
                diskGuestRate[devno] = (diskGuestRate[devno] || 0) + rate;
            };

            current.guests.forEach((guest) => {
                let before = prevGuests[guest.id];
                if (!before) {
                    return;
                }

                if (guest.pool) {
                    // Keyed by mountpoint, not by the daemon's name: the point
                    // of this is that the daemon never appears as a consumer.
                    poolNames[guest.pool] = guest.pool;
                    Object.keys(guest.devices || {}).forEach((devno) => {
                        let cur = guest.devices[devno];
                        let old = (before.devices || {})[devno];
                        if (!old) {
                            return;
                        }
                        let entry = (poolRates[devno] = poolRates[devno] || { read: 0, write: 0 });
                        entry.read += U.rate(cur.rbytes, old.rbytes, dt);
                        entry.write += U.rate(cur.wbytes, old.wbytes, dt);
                    });
                    return;
                }

                // Host units have no vmid, so the disk grid's label falls back
                // to just the name.
                let label = guest.vmid ? guest.name + ' (' + guest.vmid + ')' : guest.name;

                Object.keys(guest.devices || {}).forEach((devno) => {
                    let cur = guest.devices[devno];
                    let old = (before.devices || {})[devno];
                    if (!old) {
                        return;
                    }
                    credit(
                        devno,
                        label,
                        U.rate(cur.rbytes, old.rbytes, dt) + U.rate(cur.wbytes, old.wbytes, dt),
                    );
                });

                let readRate;
                let writeRate;
                let readIops;
                let writeIops;

                if (me.selectedDisk) {
                    let cur = (guest.devices || {})[me.selectedDisk];
                    let old = (before.devices || {})[me.selectedDisk];
                    if (!cur || !old) {
                        return;
                    }
                    readRate = U.rate(cur.rbytes, old.rbytes, dt);
                    writeRate = U.rate(cur.wbytes, old.wbytes, dt);
                    readIops = U.rate(cur.rios, old.rios, dt);
                    writeIops = U.rate(cur.wios, old.wios, dt);
                } else {
                    readRate = U.rate(guest.rbytes, before.rbytes, dt);
                    writeRate = U.rate(guest.wbytes, before.wbytes, dt);
                    readIops = U.rate(guest.rios, before.rios, dt);
                    writeIops = U.rate(guest.wios, before.wios, dt);
                }

                // A guest belongs in the list whether or not it is busy -- it
                // is a thing you expect to find. There are ~60 host units and
                // most never touch a disk, so they earn their row by doing I/O
                // once. They then keep it: adding and removing rows on every
                // poll made the grid jump under the pointer.
                if (guest.type === 'host') {
                    if (readRate + writeRate > 0) {
                        me.activeHostUnits[guest.id] = true;
                    }
                    if (!me.activeHostUnits[guest.id]) {
                        return;
                    }
                }

                let disks = Object.keys(guest.devices || {})
                    .map((devno) => (prevDisks[devno] || {}).dev || devno)
                    .sort();

                let row = {
                    id: guest.id,
                    vmid: guest.vmid,
                    name: guest.name,
                    type: guest.type,
                    source: guest.source,
                    partial: !!guest.partial,
                    viaPool: false,
                    readRate: readRate,
                    writeRate: writeRate,
                    totalRate: readRate + writeRate,
                    readIops: readIops,
                    writeIops: writeIops,
                    iops: readIops + writeIops,
                    share: 0,
                    disks: disks,
                };
                rowsById[guest.id] = row;
                guestRows.push(row);
            });

            // --- hand the pool's bytes to whoever asked for them ------------
            me.distributePoolIO(current, previous, dt, {
                poolRates: poolRates,
                poolNames: poolNames,
                rowsById: rowsById,
                guestRows: guestRows,
                byId: byId,
                prevDisks: prevDisks,
                credit: credit,
            });

            guestRows.forEach((row) => {
                let names = (row.disks || []).slice().sort();
                row.disks =
                    names.length > 3
                        ? names.slice(0, 3).join(', ') + ' +' + (names.length - 3)
                        : names.join(', ');
            });

            let guestTotal = guestRows.reduce((sum, row) => sum + row.totalRate, 0);
            guestRows.forEach((row) => {
                row.share = guestTotal > 0 ? row.totalRate / guestTotal : 0;
            });

            // --- per disk ---------------------------------------------------
            let totals = { read: 0, write: 0, iops: 0 };
            let busiest = null;

            let diskRows = current.disks.map((disk) => {
                let before = prevDisks[disk.devno] || {};

                let readRate = U.rate(disk.read_bytes, before.read_bytes, dt);
                let writeRate = U.rate(disk.write_bytes, before.write_bytes, dt);
                let readIops = U.rate(disk.read_ios, before.read_ios, dt);
                let writeIops = U.rate(disk.write_ios, before.write_ios, dt);

                // io_ticks counts milliseconds during which the queue was
                // non-empty, so its delta over the interval is utilization.
                let busyMs = Math.max(0, (disk.io_ticks || 0) - (before.io_ticks || 0));
                let util = Math.min(1, busyMs / (dt * 1000));

                let queueMs = Math.max(
                    0,
                    (disk.time_in_queue || 0) - (before.time_in_queue || 0),
                );
                let queue = queueMs / (dt * 1000);

                let ios =
                    Math.max(0, (disk.read_ios || 0) - (before.read_ios || 0)) +
                    Math.max(0, (disk.write_ios || 0) - (before.write_ios || 0));
                let ticks =
                    Math.max(0, (disk.read_ticks || 0) - (before.read_ticks || 0)) +
                    Math.max(0, (disk.write_ticks || 0) - (before.write_ticks || 0));
                let latency = ios > 0 ? ticks / ios : 0;

                totals.read += readRate;
                totals.write += writeRate;
                totals.iops += readIops + writeIops;

                if (!busiest || util > busiest.util) {
                    busiest = { dev: disk.dev, util: util, rate: readRate + writeRate };
                }

                let contributors = (perDisk[disk.devno] || []).sort((a, b) => b.rate - a.rate);
                let topGuest = '';
                if (contributors.length) {
                    let top = contributors[0];
                    let pct = diskGuestRate[disk.devno]
                        ? Math.round((top.rate / diskGuestRate[disk.devno]) * 100)
                        : 0;
                    topGuest = top.name + ' (' + pct + '%)';
                }

                return {
                    dev: disk.dev,
                    devno: disk.devno,
                    model: disk.model,
                    serial: disk.serial,
                    kind: disk.kind,
                    transport: disk.transport,
                    scheduler: disk.scheduler,
                    size: disk.size,
                    readRate: readRate,
                    writeRate: writeRate,
                    totalRate: readRate + writeRate,
                    readIops: readIops,
                    writeIops: writeIops,
                    iops: readIops + writeIops,
                    util: util,
                    queue: queue,
                    latency: latency,
                    inFlight: disk.in_flight,
                    topGuest: topGuest,
                };
            });

            me.syncRecords(me.diskStore, diskRows, 'devno', me.disksGrid);
            me.refreshDiskFilter();
            me.syncRecords(me.guestStore, guestRows, 'id', me.guestsGrid);

            me.pushChartSample(current.time, totals.read, totals.write);
            me.refreshSummary(totals, busiest, guestRows);
        },

        // A FUSE pool daemon does no work of its own: every byte it moves was
        // asked for by a container or a host process. The block layer cannot
        // see that, so the daemon's per disk bytes are shared out here among
        // the callers using the pool, in proportion to what each of them
        // actually read and wrote through it.
        //
        // The quantity handed out is block level throughout -- only the split
        // comes from syscall counters -- so the per disk totals still add up to
        // what the disk really did.
        distributePoolIO: function (current, previous, dt, ctx) {
            let me = this;
            let U = PVE.node.DiskIOUtils;

            let devnos = Object.keys(ctx.poolRates);
            if (!devnos.length) {
                return;
            }

            // Aggregate by owner rather than by pid. Pids churn constantly here
            // -- a transcode or an unpack is a fresh process every time -- and
            // matching on them meant a caller vanished from the comparison the
            // moment its pid changed, which sent its disk's whole load into the
            // unattributed bucket.
            let byOwner = function (list) {
                let out = {};
                (list || []).forEach((entry) => {
                    let ownerId =
                        entry.type === 'lxc' ? 'lxc:' + entry.vmid : 'host:' + entry.unit;
                    let owner = (out[ownerId] = out[ownerId] || {
                        ownerId: ownerId,
                        comm: entry.comm,
                        rchar: 0,
                        wchar: 0,
                        weights: {},
                    });
                    owner.rchar += entry.rchar || 0;
                    owner.wchar += entry.wchar || 0;
                    Object.keys(entry.weights || {}).forEach((devno) => {
                        owner.weights[devno] =
                            (owner.weights[devno] || 0) + entry.weights[devno];
                    });
                });
                return out;
            };

            let before = byOwner(previous.fuse);
            let now = byOwner(current.fuse);

            let owners = [];
            Object.keys(now).forEach((ownerId) => {
                let cur = now[ownerId];
                let old = before[ownerId];
                if (!old) {
                    return;
                }

                let read = U.rate(cur.rchar, old.rchar, dt);
                let write = U.rate(cur.wchar, old.wchar, dt);
                if (read + write <= 0) {
                    return;
                }

                let totalWeight = Object.keys(cur.weights).reduce(
                    (sum, devno) => sum + cur.weights[devno],
                    0,
                );

                owners.push({
                    ownerId: ownerId,
                    comm: cur.comm,
                    read: read,
                    write: write,
                    weights: cur.weights,
                    totalWeight: totalWeight,
                });
            });

            let residual = { read: 0, write: 0, disks: {} };

            let rowFor = function (owner) {
                let row = ctx.rowsById[owner.ownerId];
                if (row) {
                    return row;
                }

                // The caller does no block I/O of its own, so the main pass
                // never gave it a row -- everything it does goes via the pool.
                let known = ctx.byId[owner.ownerId] || {};
                row = {
                    id: owner.ownerId,
                    vmid: known.vmid,
                    name: known.name || owner.comm,
                    type: known.type || (owner.ownerId.indexOf('lxc:') === 0 ? 'lxc' : 'host'),
                    source: 'pool',
                    partial: false,
                    viaPool: true,
                    readRate: 0,
                    writeRate: 0,
                    totalRate: 0,
                    readIops: 0,
                    writeIops: 0,
                    iops: 0,
                    share: 0,
                    disks: [],
                };
                ctx.rowsById[owner.ownerId] = row;
                ctx.guestRows.push(row);
                return row;
            };

            devnos.forEach((devno) => {
                if (me.selectedDisk && devno !== me.selectedDisk) {
                    return;
                }

                let pool = ctx.poolRates[devno];
                if (pool.read + pool.write <= 0) {
                    return;
                }

                // Prefer callers with files open on this disk. Failing that,
                // fall back to every active caller: writeback happens long
                // after the write, often once the file is closed, so insisting
                // on a live descriptor would blame nobody for real work that a
                // real container caused.
                let onDisk = owners
                    .filter((o) => o.totalWeight > 0 && (o.weights[devno] || 0) > 0)
                    .map((o) => ({ owner: o, fraction: o.weights[devno] / o.totalWeight }));

                let shares = onDisk.length
                    ? onDisk
                    : owners.map((o) => ({ owner: o, fraction: 1 }));

                if (!shares.length) {
                    // Nothing is using the pool at all, so there is genuinely
                    // no one to credit. Dropping it would leave the disk's
                    // numbers not adding up, so it is kept as its own row.
                    residual.read += pool.read;
                    residual.write += pool.write;
                    residual.disks[devno] = true;
                    return;
                }

                let readWeight = shares.reduce((sum, s) => sum + s.owner.read * s.fraction, 0);
                let writeWeight = shares.reduce((sum, s) => sum + s.owner.write * s.fraction, 0);
                let anyWeight = shares.reduce(
                    (sum, s) => sum + (s.owner.read + s.owner.write) * s.fraction,
                    0,
                );

                let dev = (ctx.prevDisks[devno] || {}).dev || devno;

                shares.forEach((share) => {
                    let combined = (share.owner.read + share.owner.write) * share.fraction;

                    // Split reads by who was reading and writes by who was
                    // writing. When one side has no signal at all, fall back to
                    // overall activity rather than discarding those bytes.
                    let read =
                        readWeight > 0
                            ? pool.read * ((share.owner.read * share.fraction) / readWeight)
                            : anyWeight > 0
                              ? pool.read * (combined / anyWeight)
                              : 0;
                    let write =
                        writeWeight > 0
                            ? pool.write * ((share.owner.write * share.fraction) / writeWeight)
                            : anyWeight > 0
                              ? pool.write * (combined / anyWeight)
                              : 0;

                    if (read + write <= 0) {
                        return;
                    }

                    let row = rowFor(share.owner);
                    row.readRate += read;
                    row.writeRate += write;
                    row.totalRate += read + write;
                    row.viaPool = true;
                    if (row.disks.indexOf(dev) === -1) {
                        row.disks.push(dev);
                    }

                    let label = row.vmid ? row.name + ' (' + row.vmid + ')' : row.name;
                    ctx.credit(devno, label, read + write);
                });
            });

            if (residual.read + residual.write > 500000) {
                let poolName = Object.keys(ctx.poolNames).map((k) => ctx.poolNames[k])[0] || 'pool';
                let disks = Object.keys(residual.disks).map(
                    (devno) => (ctx.prevDisks[devno] || {}).dev || devno,
                );

                ctx.guestRows.push({
                    id: 'pool:unattributed',
                    vmid: undefined,
                    name: Ext.String.format(gettext('{0} (no active caller)'), poolName),
                    type: 'host',
                    source: 'pool',
                    partial: false,
                    viaPool: true,
                    readRate: residual.read,
                    writeRate: residual.write,
                    totalRate: residual.read + residual.write,
                    readIops: 0,
                    writeIops: 0,
                    iops: 0,
                    share: 0,
                    disks: disks,
                });
            }
        },

        // Update rows in place so the grid keeps its selection, scroll offset
        // and sort while the numbers change underneath. Adding or removing any
        // row still moves the viewport, so the scroll position is restored
        // explicitly afterwards.
        syncRecords: function (store, rows, keyOf, grid) {
            let key = Ext.isFunction(keyOf) ? keyOf : (r) => r[keyOf];

            let view = grid && grid.rendered ? grid.getView() : null;
            let scroller = view && view.getScrollable ? view.getScrollable() : null;
            let position = scroller ? scroller.getPosition() : null;

            let existing = {};
            store.each((record) => {
                existing[key(record.data)] = record;
            });

            let additions = [];
            let seen = {};

            rows.forEach((row) => {
                let id = key(row);
                seen[id] = true;
                let record = existing[id];
                if (record) {
                    record.set(row, { commit: true });
                } else {
                    additions.push(row);
                }
            });

            let removals = [];
            store.each((record) => {
                if (!seen[key(record.data)]) {
                    removals.push(record);
                }
            });

            if (removals.length) {
                store.remove(removals);
            }
            if (additions.length) {
                store.add(additions);
            }

            // Re-sorting refreshes the whole view, which drops the viewport
            // back to the top -- every poll, not just when rows come and go.
            store.sort();

            if (scroller && position && (position.x || position.y)) {
                scroller.scrollTo(position.x, position.y);
                // The refresh can settle a frame later and take the viewport
                // with it, so put it back once more after that has happened.
                Ext.defer(function () {
                    if (!store.destroyed && scroller && !scroller.destroyed) {
                        scroller.scrollTo(position.x, position.y);
                    }
                }, 1);
            }
        },

        refreshDiskFilter: function () {
            let me = this;
            me.diskStore.clearFilter();
            if (!me.showUnused) {
                me.diskStore.filterBy((record) => record.data.size > 0);
            }
        },

        pushChartSample: function (time, read, write) {
            let me = this;

            me.chartStore.add({
                time: time * 1000,
                read: read,
                write: write,
            });

            let overflow = me.chartStore.getCount() - me.historyLength;
            if (overflow > 0) {
                me.chartStore.remove(me.chartStore.getRange(0, overflow - 1));
            }
        },

        refreshSummary: function (totals, busiest, guestRows) {
            let me = this;
            let U = PVE.node.DiskIOUtils;

            let top = guestRows.reduce(
                (best, row) => (!best || row.totalRate > best.totalRate ? row : best),
                null,
            );

            let busiestSub = busiest
                ? Math.round(busiest.util * 100) + '% ' + gettext('busy')
                : '';

            me.summary.update({
                tiles: [
                    {
                        icon: 'fa fa-arrow-down',
                        label: gettext('Read'),
                        value: Proxmox.Utils.format_size(totals.read) + '/s',
                        sub: '',
                        cls: 'pve-diskio-read',
                    },
                    {
                        icon: 'fa fa-arrow-up',
                        label: gettext('Write'),
                        value: Proxmox.Utils.format_size(totals.write) + '/s',
                        sub: '',
                        cls: 'pve-diskio-write',
                    },
                    {
                        icon: 'fa fa-exchange',
                        label: gettext('IOPS'),
                        value: Ext.util.Format.number(totals.iops, '0'),
                        sub: gettext('across all disks'),
                        cls: '',
                    },
                    {
                        icon: 'fa fa-tachometer',
                        label: gettext('Busiest Disk'),
                        value: busiest ? busiest.dev : '-',
                        sub: busiestSub,
                        cls: busiest && busiest.util > 0.8 ? 'pve-diskio-busy' : '',
                    },
                    {
                        icon: 'fa fa-fire',
                        label: gettext('Top Consumer'),
                        value: top && top.totalRate > 0 ? top.name : '-',
                        sub:
                            top && top.totalRate > 0
                                ? Proxmox.Utils.format_size(top.totalRate) + '/s'
                                : gettext('idle'),
                        cls: '',
                    },
                ],
            });
        },

        refreshScopeIndicator: function () {
            let me = this;
            let text = me.down('#scopeText');
            let clear = me.down('#clearScope');
            if (!text || !clear) {
                return;
            }

            if (me.selectedDisk) {
                let record = me.diskStore.findRecord('devno', me.selectedDisk, 0, false, true, true);
                let dev = record ? record.data.dev : me.selectedDisk;
                text.setText(Ext.String.format(gettext('I/O shown for {0}'), dev));
                me.guestsGrid.setTitle(Ext.String.format(gettext('Consumers on {0}'), dev));
                clear.setHidden(false);
            } else {
                text.setText('');
                me.guestsGrid.setTitle(gettext('Consumers'));
                clear.setHidden(true);
            }
        },
    });

    // ------------------------------------------------ summary history charts

    // Distinguishable in both themes, and assigned by rank position so a
    // series keeps its colour between refreshes.
    const SERIES_PALETTE = [
        '#115fa6',
        '#94ae0a',
        '#a61120',
        '#ff8809',
        '#7c4b96',
        '#22b2b2',
        '#c14b9e',
        '#5f9c3a',
        '#e6650d',
        '#4d7fbf',
        '#b8a90d',
        '#8c5a2b',
    ];

    const OTHER_COLOR = '#9d9d9d';

    // The stock RRD store builds its URL as "<rrdurl>?timeframe=..&cf=..".
    // Carrying which disk or guest to plot means extending that; everything
    // else -- including following the page's Hour/Day/Week/Month/Year
    // selector -- is inherited unchanged.
    Ext.define('PVE.data.IOHistoryRRDStore', {
        extend: 'Proxmox.data.RRDStore',

        extraParams: undefined,

        setRRDUrl: function (timeframe, cf) {
            let me = this;
            me.callParent([timeframe, cf]);
            Ext.Object.each(me.extraParams || {}, function (key, value) {
                me.proxy.url += '&' + key + '=' + encodeURIComponent(value);
            });
        },
    });

    // Shared behaviour for the two Summary graphs: load a list of things that
    // can be plotted, put a picker for them in the chart's own header, and
    // rebuild the chart when the selection changes. Subclasses supply the URLs
    // and decide what series to draw.
    Ext.define('PVE.node.IOHistoryChart', {
        extend: 'Ext.panel.Panel',

        layout: 'fit',
        border: false,
        header: false,

        // Key of the entry being plotted, or 'all'.
        selected: 'all',

        // Whether the plotted series depend on the timeframe. They do for
        // guests, where the set drawn is whoever was busiest in that window.
        rebuildOnTimeframe: false,

        initComponent: function () {
            let me = this;

            let nodename = me.nodename || me.pveSelNode?.data?.node;
            if (!nodename) {
                throw 'no node name specified';
            }
            me.nodename = nodename;

            me.callParent();

            if (me.rebuildOnTimeframe) {
                let sp = Ext.state.Manager.getProvider();
                me.mon(sp, 'statechange', function (prov, key) {
                    if (key !== 'proxmoxRRDTypeSelection') {
                        return;
                    }
                    Ext.defer(function () {
                        if (!me.isDestroyed) {
                            me.loadList();
                        }
                    }, 1);
                });
            }

            me.loadList();
        },

        // The timeframe selector is shared page state rather than a property of
        // any one chart, so read it from where the stores read it.
        currentTimeframe: function () {
            let state = Ext.state.Manager.getProvider().get('proxmoxRRDTypeSelection');
            return {
                timeframe: (state && state.timeframe) || 'hour',
                cf: (state && state.cf) || 'AVERAGE',
            };
        },

        loadList: function () {
            let me = this;

            Proxmox.Utils.API2Request({
                url: me.getListUrl(),
                method: 'GET',
                success: function (response) {
                    if (me.isDestroyed) {
                        return;
                    }
                    Proxmox.Utils.setErrorMask(me, false);
                    me.entries = response.result.data || [];
                    me.buildChart();
                },
                failure: function (response) {
                    if (me.isDestroyed) {
                        return;
                    }
                    Proxmox.Utils.setErrorMask(me, response.htmlStatus);
                },
            });
        },

        buildChart: function () {
            let me = this;

            me.removeAll(true);
            if (me.rrdstore) {
                me.rrdstore.stopUpdate();
                me.rrdstore.destroy();
                me.rrdstore = undefined;
            }

            let spec = me.seriesFor(me.entries || []);

            if (!spec || !spec.fields.length) {
                me.add({
                    xtype: 'component',
                    padding: 20,
                    html: Ext.htmlEncode(me.emptyText || gettext('No history recorded yet.')),
                });
                return;
            }

            let params = {};
            params[me.paramName] = me.selected;

            me.rrdstore = Ext.create('PVE.data.IOHistoryRRDStore', {
                rrdurl: me.getDataUrl(),
                extraParams: params,
                // Same time handling as PVE's own RRD models: the API returns
                // epoch seconds and Ext converts them to a Date for the axis.
                fields: [{ name: 'time', type: 'date', dateFormat: 'timestamp' }].concat(
                    spec.fields,
                ),
            });

            let chart = Ext.create('Proxmox.widget.RRDChart', {
                title: spec.title,
                store: me.rrdstore,
                fields: spec.fields,
                fieldTitles: spec.fieldTitles,
                colors: spec.colors,
                unit: 'bytespersecond',
                seriesConfig: spec.seriesConfig,
                border: false,
            });

            // Put the picker in the chart's own header, beside the title and
            // legend, so the whole thing reads as one window rather than a
            // chart with a toolbar bolted on top.
            let header = chart.getHeader();
            if (header) {
                header.insert(1, me.buildPicker());

                // The legend flexes to fill the header, and with one entry per
                // guest it squeezes the title to zero width -- which loses the
                // graph's name on a page where several graphs are stacked.
                let title = header.down('title');
                if (title && title.setMinWidth) {
                    title.setMinWidth(150);
                    title.setFlex(0);
                }
            }

            me.add(chart);
            me.rrdstore.startUpdate();
        },

        buildPicker: function () {
            let me = this;

            return {
                xtype: 'combobox',
                margin: '0 8 0 8',
                width: me.pickerWidth || 260,
                editable: false,
                queryMode: 'local',
                displayField: 'label',
                valueField: 'key',
                value: me.selected,
                store: { fields: ['key', 'label'], data: me.pickerRows(me.entries || []) },
                listeners: {
                    change: function (field, value) {
                        if (value === me.selected) {
                            return;
                        }
                        me.selected = value;

                        // Rebuilding replaces the chart, and this combobox
                        // lives in that chart's header -- so it must not happen
                        // while ExtJS is still inside the combobox's own change
                        // handling, or it carries on against a destroyed field.
                        Ext.defer(function () {
                            if (!me.isDestroyed) {
                                me.buildChart();
                            }
                        }, 1);
                    },
                },
            };
        },

        doDestroy: function () {
            let me = this;
            if (me.rrdstore) {
                me.rrdstore.stopUpdate();
                me.rrdstore.destroy();
                me.rrdstore = undefined;
            }
            me.callParent();
        },
    });

    // --- physical disks ---

    Ext.define('PVE.node.DiskIOSummaryChart', {
        extend: 'PVE.node.IOHistoryChart',
        alias: 'widget.pveNodeDiskIOSummaryChart',

        paramName: 'disk',
        emptyText: gettext('No disk I/O history recorded yet.'),

        getListUrl: function () {
            return '/nodes/' + this.nodename + '/disks/io/rrdlist';
        },

        getDataUrl: function () {
            return '/api2/json/nodes/' + this.nodename + '/disks/io/rrddata';
        },

        pickerRows: function (entries) {
            let rows = [{ key: 'all', label: gettext('All disks') }];
            for (const disk of entries) {
                let label = disk.dev || disk.key;
                if (disk.model) {
                    label += ' - ' + disk.model;
                }
                if (!disk.present) {
                    label += ' (' + gettext('detached') + ')';
                }
                rows.push({ key: disk.key, label: label });
            }
            return rows;
        },

        seriesFor: function (entries) {
            let me = this;
            let single = me.selected !== 'all' ? entries.find((d) => d.key === me.selected) : null;

            // A specific disk splits into read and write, which is the
            // interesting question once you have picked one.
            if (single) {
                return {
                    title: Ext.String.format(
                        gettext('Disk I/O - {0}'),
                        single.dev || single.key,
                    ),
                    fields: ['read', 'write'],
                    fieldTitles: [gettext('Read'), gettext('Write')],
                    colors: ['#115fa6', '#94ae0a'],
                };
            }

            let usable = entries.filter((d) => d.dev);
            return {
                title: gettext('Disk I/O'),
                fields: usable.map((d) => d.dev),
                fieldTitles: usable.map(
                    (d) => d.dev + (d.present ? '' : ' (' + gettext('detached') + ')'),
                ),
                colors: usable.map((d, i) => SERIES_PALETTE[i % SERIES_PALETTE.length]),
                // RRDChart fills its series by default, which reads well for
                // two series but turns nine overlaid disks into a muddy stack
                // where no single one can be followed. Plain lines instead.
                seriesConfig: { fill: false, style: { lineWidth: 1.5, opacity: 1 } },
            };
        },
    });

    // --- guests ---

    Ext.define('PVE.node.GuestIOSummaryChart', {
        extend: 'PVE.node.IOHistoryChart',
        alias: 'widget.pveNodeGuestIOSummaryChart',

        paramName: 'guest',
        pickerWidth: 280,
        emptyText: gettext('No guest disk I/O recorded yet.'),

        // Which guests are drawn depends on who was busiest in the window on
        // screen, so switching timeframe has to re-rank, not just refetch.
        rebuildOnTimeframe: true,

        getListUrl: function () {
            let tf = this.currentTimeframe();
            return (
                '/nodes/' +
                this.nodename +
                '/disks/io/guestlist?timeframe=' +
                tf.timeframe +
                '&cf=' +
                tf.cf
            );
        },

        getDataUrl: function () {
            return '/api2/json/nodes/' + this.nodename + '/disks/io/guestrrddata';
        },

        pickerRows: function (entries) {
            let rows = [{ key: 'all', label: gettext('Busiest guests') }];
            let seen = {};
            for (const guest of entries) {
                if (guest.type === 'other' || !guest.vmid || seen[guest.vmid]) {
                    continue;
                }
                seen[guest.vmid] = true;
                rows.push({ key: String(guest.vmid), label: guest.name + ' (' + guest.vmid + ')' });
            }
            return rows;
        },

        seriesFor: function (entries) {
            let me = this;

            if (me.selected !== 'all') {
                let guest = entries.find((g) => String(g.vmid) === me.selected);
                let label = guest ? guest.name + ' (' + guest.vmid + ')' : me.selected;
                return {
                    title: Ext.String.format(gettext('Guest Disk I/O - {0}'), label),
                    fields: ['read', 'write'],
                    fieldTitles: [gettext('Read'), gettext('Write')],
                    colors: ['#115fa6', '#94ae0a'],
                };
            }

            // The ranked head of the list is what the data endpoint returns as
            // fields; entries after it are the full node roster for the picker.
            let ranked = entries.filter((g) => !g.selectable);
            return {
                title: gettext('Disk I/O by Guest'),
                fields: ranked.map((g) => g.field),
                fieldTitles: ranked.map((g) =>
                    g.type === 'other'
                        ? Ext.String.format(gettext('Other ({0})'), g.count)
                        : g.field,
                ),
                colors: ranked.map((g, i) =>
                    g.type === 'other' ? OTHER_COLOR : SERIES_PALETTE[i % SERIES_PALETTE.length],
                ),
                seriesConfig: { fill: false, style: { lineWidth: 1.5, opacity: 1 } },
            };
        },
    });

    // The node Summary builds its graphs into a single column container. Adding
    // to that after it exists puts these alongside the CPU, memory and network
    // graphs, picking up the same column width, height and padding defaults.
    Ext.define('PVE.node.DiskIOSummaryInjection', {
        override: 'PVE.node.Summary',

        initComponent: function () {
            let me = this;

            me.callParent();

            try {
                let container = me.down('#itemcontainer');
                if (!container) {
                    return;
                }
                let nodename = me.pveSelNode.data.node;

                if (!container.down('pveNodeDiskIOSummaryChart')) {
                    container.add({ xtype: 'pveNodeDiskIOSummaryChart', nodename: nodename });
                }
                if (!container.down('pveNodeGuestIOSummaryChart')) {
                    container.add({ xtype: 'pveNodeGuestIOSummaryChart', nodename: nodename });
                }
            } catch (err) {
                if (window.console && window.console.error) {
                    window.console.error('pve-disk-io: could not add summary charts', err);
                }
            }
        },
    });

    // ------------------------------------------------- menu entry injection

    // PVE.node.Config builds its item list and then hands it to
    // PVE.panel.Config, which turns it into the navigation tree. Overriding
    // that handover adds our card without editing pvemanagerlib.js, so a
    // pve-manager upgrade can never leave a half-applied patch behind.
    Ext.define('PVE.node.DiskIOMenuInjection', {
        override: 'PVE.panel.Config',

        initComponent: function () {
            let me = this;

            try {
                if (me.$className === 'PVE.node.Config' && Ext.isArray(me.items)) {
                    let present = me.items.some((item) => item && item.itemId === 'disk-io');
                    let anchor = me.items.findIndex((item) => item && item.itemId === 'storage');

                    if (!present && anchor !== -1) {
                        me.items.splice(anchor + 1, 0, {
                            xtype: 'pveNodeDiskIO',
                            title: gettext('I/O Activity'),
                            itemId: 'disk-io',
                            iconCls: 'fa fa-tachometer',
                            groups: ['storage'],
                            nodename: me.pveSelNode.data.node,
                        });
                    }
                }
            } catch (err) {
                // Decorating the menu must never break the panel it decorates.
                if (window.console && window.console.error) {
                    window.console.error('pve-disk-io: could not add menu entry', err);
                }
            }

            me.callParent();
        },
    });
});
