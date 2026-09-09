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

        renderGuest: function (value, metaData, record) {
            let icon = record.data.type === 'lxc' ? 'fa fa-cube' : 'fa fa-desktop';
            return '<i class="' + icon + '"></i> ' + Ext.htmlEncode(value);
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

        // devno of the disk the guest grid is scoped to, or null for "all".
        selectedDisk: null,

        initComponent: function () {
            let me = this;

            let nodename = me.nodename || me.pveSelNode?.data?.node;
            if (!nodename) {
                throw 'no node name specified';
            }
            me.nodename = nodename;

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
                    'name',
                    'type',
                    'source',
                    'disks',
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
                sorters: [{ property: 'totalRate', direction: 'DESC' }],
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
                viewConfig: { stripeRows: true, deferEmptyText: false },
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
                title: gettext('Guests'),
                emptyText: gettext('Sampling...'),
                viewConfig: { stripeRows: true, deferEmptyText: false },
                columns: [
                    {
                        text: gettext('ID'),
                        dataIndex: 'vmid',
                        width: 70,
                    },
                    {
                        text: gettext('Name'),
                        dataIndex: 'name',
                        flex: 1,
                        minWidth: 120,
                        renderer: U.renderGuest,
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
                url: '/nodes/' + me.nodename + '/disks/io',
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
                prevGuests[g.type + ':' + g.vmid] = g;
            });

            // --- per guest, and per (guest, disk) ---------------------------
            let guestRows = [];
            let perDisk = {}; // devno -> [{name, rate}]
            let diskGuestRate = {}; // devno -> total attributed rate

            current.guests.forEach((guest) => {
                let key = guest.type + ':' + guest.vmid;
                let before = prevGuests[key];
                if (!before) {
                    return;
                }

                let label = guest.name + ' (' + guest.vmid + ')';

                // Per-disk contribution, used both for the guest grid when a
                // disk is selected and for the disks grid's top consumer.
                Object.keys(guest.devices || {}).forEach((devno) => {
                    let cur = guest.devices[devno];
                    let old = (before.devices || {})[devno];
                    if (!old) {
                        return;
                    }
                    let rate =
                        U.rate(cur.rbytes, old.rbytes, dt) + U.rate(cur.wbytes, old.wbytes, dt);
                    if (rate <= 0) {
                        return;
                    }
                    (perDisk[devno] = perDisk[devno] || []).push({ name: label, rate: rate });
                    diskGuestRate[devno] = (diskGuestRate[devno] || 0) + rate;
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

                let disks = Object.keys(guest.devices || {})
                    .map((devno) => (prevDisks[devno] || {}).dev || devno)
                    .sort();

                guestRows.push({
                    vmid: guest.vmid,
                    name: guest.name,
                    type: guest.type,
                    source: guest.source,
                    partial: !!guest.partial,
                    readRate: readRate,
                    writeRate: writeRate,
                    totalRate: readRate + writeRate,
                    readIops: readIops,
                    writeIops: writeIops,
                    iops: readIops + writeIops,
                    share: 0,
                    disks:
                        disks.length > 3
                            ? disks.slice(0, 3).join(', ') + ' +' + (disks.length - 3)
                            : disks.join(', '),
                });
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

            me.syncRecords(me.diskStore, diskRows, 'devno');
            me.refreshDiskFilter();
            me.syncRecords(me.guestStore, guestRows, (r) => r.type + ':' + r.vmid);

            me.pushChartSample(current.time, totals.read, totals.write);
            me.refreshSummary(totals, busiest, guestRows);
        },

        // Update rows in place so the grid keeps its selection, scroll offset
        // and sort while the numbers change underneath.
        syncRecords: function (store, rows, keyOf) {
            let key = Ext.isFunction(keyOf) ? keyOf : (r) => r[keyOf];

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
            store.sort();
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
                text.setText(Ext.String.format(gettext('Guest I/O shown for {0}'), dev));
                me.guestsGrid.setTitle(Ext.String.format(gettext('Guests on {0}'), dev));
                clear.setHidden(false);
            } else {
                text.setText('');
                me.guestsGrid.setTitle(gettext('Guests'));
                clear.setHidden(true);
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
