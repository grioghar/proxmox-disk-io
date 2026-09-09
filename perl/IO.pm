package PVE::API2::Disks::IO;

# Live block-device I/O statistics for the node, plus attribution of that
# I/O to the guests responsible for it.
#
# Everything here is deliberately cheap: the hot path reads only procfs and
# sysfs (no forks) so the endpoint can be polled at 1-2s intervals. The one
# exception is QEMU, which has no cgroup io accounting enabled under
# qemu.slice, so per-VM numbers come from QMP query-blockstats instead.
#
# Counters are returned raw (monotonic since boot) together with a
# high-resolution timestamp. Rates are derived client side from the delta
# between two polls, which keeps this endpoint stateless.

use strict;
use warnings;

use File::Basename qw(basename dirname);
use Time::HiRes qw(time);

use JSON;

use PVE::JSONSchema qw(get_standard_option);
use PVE::DiskIO;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::Tools;

use base qw(PVE::RESTHandler);

# Walk down the stacking (dm targets, partitions) to the physical disks that
# actually carry a block device. Memoised per request.
sub _resolve_physical {
    my ($devno, $physical, $cache, $seen) = @_;

    return @{ $cache->{$devno} } if $cache->{$devno};

    $seen //= {};
    return () if $seen->{$devno}++;

    if ($physical->{$devno}) {
        $cache->{$devno} = [$devno];
        return ($devno);
    }

    my $sysdir = "/sys/dev/block/$devno";
    my %found;

    if (-e "$sysdir/partition") {
        # A partition's parent disk is its containing sysfs directory.
        my $real = Cwd::realpath($sysdir);
        if ($real) {
            my $parent = PVE::DiskIO::slurp_trim(dirname($real) . '/dev');
            if (defined($parent)) {
                $found{$_} = 1 for _resolve_physical($parent, $physical, $cache, $seen);
            }
        }
    } else {
        for my $slave (PVE::DiskIO::listdir("$sysdir/slaves")) {
            my $sdevno = PVE::DiskIO::slurp_trim("$sysdir/slaves/$slave/dev");
            next if !defined($sdevno);
            $found{$_} = 1 for _resolve_physical($sdevno, $physical, $cache, $seen);
        }
    }

    my @result = sort keys %found;
    $cache->{$devno} = \@result;
    return @result;
}

# Map a filesystem path to the "major:minor" of the device backing it, using
# the mount table. Used for file-based (dir) storages.
sub _path_devno_via_mounts {
    my ($path) = @_;

    my $data = PVE::DiskIO::slurp('/proc/self/mountinfo') // '';
    my ($best_len, $best_devno) = (-1, undef);

    for my $line (split(/\n/, $data)) {
        my @f = split(/\s+/, $line);
        next if scalar(@f) < 5;
        my ($devno, $mountpoint) = ($f[2], $f[4]);
        next if $devno !~ /^\d+:\d+$/;

        my $prefix = $mountpoint eq '/' ? '/' : "$mountpoint/";
        next if index("$path/", $prefix) != 0;

        if (length($mountpoint) > $best_len) {
            ($best_len, $best_devno) = (length($mountpoint), $devno);
        }
    }

    return $best_devno;
}

sub _path_to_devno {
    my ($path) = @_;
    return undef if !defined($path);

    my $real = Cwd::realpath($path) // $path;
    if ($real =~ m{^/dev/(.+)$}) {
        my $name = $1;
        $name =~ s{/}{!}g;
        my $devno = PVE::DiskIO::slurp_trim("/sys/class/block/$name/dev");
        return $devno if defined($devno);
    }

    return _path_devno_via_mounts($real);
}

# --- guests ---------------------------------------------------------------

# Guest names, and the mapping from a VM's drives to the physical disks under
# them, only change when a guest is created, renamed or reconfigured. Reading
# them means going to pmxcfs, a FUSE filesystem replicated across the cluster,
# once per guest -- at a 1-3s poll interval that was by far the most expensive
# thing this endpoint did. So it is cached, and refreshed either on a timer or
# immediately when a guest appears that the cache has not seen.
my $METADATA_TTL = 30;
my $metadata = { updated => 0, lxc => {}, qemu => {} };

sub _guest_metadata {
    my ($lxc_ids, $qemu_ids, $physical, $cache) = @_;

    my $fresh = (time() - $metadata->{updated}) < $METADATA_TTL;
    if ($fresh) {
        for my $vmid (@$lxc_ids) {
            $fresh = 0 if !exists $metadata->{lxc}->{$vmid};
        }
        for my $vmid (@$qemu_ids) {
            $fresh = 0 if !exists $metadata->{qemu}->{$vmid};
        }
    }
    return $metadata if $fresh;

    my $next = { updated => time(), lxc => {}, qemu => {} };

    require PVE::LXC::Config;
    for my $vmid (@$lxc_ids) {
        my $name = eval { PVE::LXC::Config->load_config($vmid)->{hostname} };
        $next->{lxc}->{$vmid} = $name // "CT $vmid";
    }

    require PVE::QemuConfig;
    require PVE::Storage;
    my $storecfg = eval { PVE::Storage::config() };

    for my $vmid (@$qemu_ids) {
        my $conf = eval { PVE::QemuConfig->load_config($vmid) };
        next if !$conf;

        # Which physical disks each drive lives on, resolved through the
        # storage layer so LVM, thin, dir and ZFS all work the same way.
        my $drives = _qemu_drive_volids($conf);
        my $drive_disks = {};

        for my $key (keys %$drives) {
            my $volid = $drives->{$key};
            # Raw device passthrough (/dev/disk/by-id/...) never goes through
            # the storage layer, so use the path as given.
            my $path = $volid =~ m{^/}
                ? $volid
                : eval { PVE::Storage::path($storecfg, $volid) };
            next if !$path;

            my $devno = _path_to_devno($path);
            next if !defined($devno);

            $drive_disks->{$key} = [_resolve_physical($devno, $physical, $cache)];
        }

        $next->{qemu}->{$vmid} = {
            name => $conf->{name} // "VM $vmid",
            drives => $drive_disks,
        };
    }

    $metadata = $next;
    return $metadata;
}

# cgroup v2 io.stat: one line per device, "maj:min rbytes=.. wbytes=.. ..".
# The io controller charges every layer of the stack, so a guest on LVM shows
# up against both the dm device and the physical disk underneath. Summing all
# lines would double count; filtering to physical disks gives the true total.
sub _cgroup_io_stat {
    my ($path) = @_;

    my $per_device = {};
    my $data = PVE::DiskIO::slurp($path);
    return undef if !defined($data);

    for my $line (split(/\n/, $data)) {
        my @f = split(/\s+/, $line);
        my $devno = shift @f;
        next if !defined($devno) || $devno !~ /^\d+:\d+$/;

        my $entry = { rbytes => 0, wbytes => 0, rios => 0, wios => 0, dbytes => 0, dios => 0 };
        for my $kv (@f) {
            my ($k, $v) = split(/=/, $kv, 2);
            $entry->{$k} = ($v // 0) + 0 if exists $entry->{$k};
        }
        $per_device->{$devno} = $entry;
    }

    return $per_device;
}

sub _lxc_guests {
    my ($physical, $names) = @_;

    my $guests = [];
    for my $vmid (PVE::DiskIO::listdir('/sys/fs/cgroup/lxc')) {
        next if $vmid !~ /^\d+$/;

        my $per_device = _cgroup_io_stat("/sys/fs/cgroup/lxc/$vmid/io.stat");
        next if !defined($per_device);

        my $devices = {};
        my $total = { rbytes => 0, wbytes => 0, rios => 0, wios => 0, dbytes => 0, dios => 0 };

        for my $devno (keys %$per_device) {
            next if !$physical->{$devno};
            my $entry = $per_device->{$devno};
            $devices->{$devno} = $entry;
            $total->{$_} += $entry->{$_} for keys %$total;
        }

        push @$guests, {
            vmid => $vmid + 0,
            name => $names->{$vmid} // "CT $vmid",
            type => 'lxc',
            source => 'cgroup',
            devices => $devices,
            %$total,
        };
    }

    return $guests;
}

sub _qemu_drive_volids {
    my ($conf) = @_;

    my $drives = {};
    for my $key (keys %$conf) {
        next if $key !~ /^(?:(?:ide|sata|scsi|virtio)\d+|efidisk0|tpmstate0)$/;
        my $value = $conf->{$key};
        next if !defined($value) || $value =~ /\bmedia=cdrom\b/;

        my ($volid) = split(/,/, $value, 2);
        next if !defined($volid) || $volid eq '' || $volid eq 'none' || $volid eq 'cdrom';
        next if $volid =~ m{^/dev/cdrom};

        $drives->{$key} = $volid;
    }

    return $drives;
}

sub _qemu_guests {
    my ($meta) = @_;

    my $guests = [];

    for my $scope (PVE::DiskIO::listdir('/sys/fs/cgroup/qemu.slice')) {
        next if $scope !~ /^(\d+)\.scope$/;
        my $vmid = $1;

        my $info = $meta->{$vmid} or next;
        my $drive_disks = $info->{drives};

        my $blockstats = eval {
            require PVE::QemuServer::Monitor;
            PVE::QemuServer::Monitor::mon_cmd($vmid, 'query-blockstats');
        };

        my $devices = {};
        my $total = { rbytes => 0, wbytes => 0, rios => 0, wios => 0, dbytes => 0, dios => 0 };
        my $read_ns = 0;
        my $write_ns = 0;
        my $unattributed = 0;

        for my $entry (@{ $blockstats // [] }) {
            my $key = $entry->{qdev} // $entry->{device} // '';
            $key =~ s/^drive-//;
            next if $key eq '';

            my $s = $entry->{stats} or next;
            my $rbytes = $s->{rd_bytes} // 0;
            my $wbytes = $s->{wr_bytes} // 0;
            my $rios = $s->{rd_operations} // 0;
            my $wios = $s->{wr_operations} // 0;

            $total->{rbytes} += $rbytes;
            $total->{wbytes} += $wbytes;
            $total->{rios} += $rios;
            $total->{wios} += $wios;
            $total->{dbytes} += $s->{unmap_bytes} // 0;
            $total->{dios} += $s->{unmap_operations} // 0;
            $read_ns += $s->{rd_total_time_ns} // 0;
            $write_ns += $s->{wr_total_time_ns} // 0;

            my $disks = $drive_disks->{$key};
            if (!$disks || !scalar(@$disks)) {
                # Only worth flagging if the unresolved drive is actually doing
                # I/O; an idle efidisk/tpmstate would otherwise cry wolf.
                $unattributed = 1 if $rbytes || $wbytes;
                next;
            }

            # A drive spanning several physical disks (striped/linear LVM) has
            # no per-disk breakdown available, so split it evenly rather than
            # crediting the whole load to one spindle.
            my $share = scalar(@$disks);
            for my $devno (@$disks) {
                my $d = $devices->{$devno} //=
                    { rbytes => 0, wbytes => 0, rios => 0, wios => 0, dbytes => 0, dios => 0 };
                $d->{rbytes} += $rbytes / $share;
                $d->{wbytes} += $wbytes / $share;
                $d->{rios} += $rios / $share;
                $d->{wios} += $wios / $share;
            }
        }

        push @$guests, {
            vmid => $vmid + 0,
            name => $info->{name},
            type => 'qemu',
            source => $blockstats ? 'qmp' : 'unavailable',
            devices => $devices,
            partial => $unattributed,
            read_time_ns => $read_ns,
            write_time_ns => $write_ns,
            %$total,
        };
    }

    return $guests;
}

# --- history -------------------------------------------------------------

# Resolution and window per timeframe, matching what PVE's own rrddata
# endpoints return so this graph lines up with the ones beside it:
#   hour 60s x 60, day 60s x 1440, week 1800s x 336,
#   month 1800s x 1440, year 21600s x 1440.
my $TIMEFRAMES = {
    hour => { resolution => 60, count => 60 },
    day => { resolution => 60, count => 1440 },
    week => { resolution => 1800, count => 336 },
    month => { resolution => 1800, count => 1440 },
    year => { resolution => 21600, count => 1440 },
};

sub _fetch_rrd {
    my ($node, $key, $timeframe, $cf) = @_;

    my $spec = $TIMEFRAMES->{ $timeframe // 'hour' } or return undef;
    my $file = PVE::DiskIO::rrd_file($node, $key);
    return undef if !-f $file;

    require RRDs;

    my $seconds = $spec->{resolution} * $spec->{count};
    my ($start, $step, $names, $data) = RRDs::fetch(
        $file, $cf,
        '-r', $spec->{resolution},
        '-s', "-$seconds",
        '-e', 'now',
    );

    if (my $err = RRDs::error()) {
        syslog('err', "disk I/O history: cannot read $file: $err");
        return undef;
    }
    return undef if !$data || !$names;

    my $series = [];
    my $time = $start;
    for my $row (@$data) {
        my $point = { time => $time };
        for my $i (0 .. $#$names) {
            $point->{ $names->[$i] } = $row->[$i];
        }
        push @$series, $point;
        $time += $step;
    }

    return $series;
}

__PACKAGE__->register_method({
    name => 'rrdlist',
    path => 'rrdlist',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "List the physical disks that have recorded I/O history."
        . " Disks that are currently detached stay listed, with present=0, so"
        . " their history remains reachable.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $raw = PVE::DiskIO::slurp(PVE::DiskIO::index_file($param->{node}));
        return [] if !defined($raw);

        my $index = eval { decode_json($raw) } || [];

        # The index is written once a minute; reconcile it with what is
        # attached right now so a disk that just appeared or vanished is
        # labelled correctly without waiting for the next collector run.
        my $physical = PVE::DiskIO::physical_disks();
        my $live = {};
        my $taken = {};
        for my $devno (sort keys %$physical) {
            my $disk = $physical->{$devno};
            next if !$disk->{size};
            my $key = PVE::DiskIO::disk_key($disk, $taken);
            $taken->{$key} = 1;
            $live->{$key} = $disk;
        }

        for my $entry (@$index) {
            my $disk = $live->{ $entry->{key} };
            $entry->{present} = $disk ? 1 : 0;
            $entry->{dev} = $disk->{dev} if $disk;
        }

        return $index;
    },
});

__PACKAGE__->register_method({
    name => 'rrddata',
    path => 'rrddata',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Recorded physical disk I/O history, in the same shape as"
        . " the other rrddata endpoints so it can drive a standard RRD chart."
        . " With disk=all each row carries one field per disk (total throughput);"
        . " with a specific disk key each row carries that disk's detail.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            timeframe => {
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year'],
                description => "Specify the time frame to look up.",
            },
            cf => {
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
                description => "The RRD consolidation function.",
            },
            disk => {
                type => 'string',
                optional => 1,
                pattern => '^(?:all|[A-Za-z0-9_.-]+)$',
                maxLength => 128,
                description => "A disk key from rrdlist, or 'all' (the default)"
                    . " to overlay every disk.",
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $node = $param->{node};
        my $cf = $param->{cf} // 'AVERAGE';
        my $which = $param->{disk} // 'all';

        my $raw = PVE::DiskIO::slurp(PVE::DiskIO::index_file($node));
        my $index = defined($raw) ? (eval { decode_json($raw) } || []) : [];
        return [] if !scalar(@$index);

        my $wanted = $which eq 'all'
            ? $index
            : [grep { $_->{key} eq $which } @$index];
        return [] if !scalar(@$wanted);

        my $rows = {};

        for my $entry (@$wanted) {
            my $series = _fetch_rrd($node, $entry->{key}, $param->{timeframe}, $cf);
            next if !$series;

            for my $point (@$series) {
                # +0 keeps this a number in the JSON: using the value as a hash
                # key stringifies the scalar in place, and the chart's time axis
                # needs a number, not "1788972300".
                my $t = $point->{time};
                my $row = $rows->{$t} //= { time => $t + 0 };

                if ($which eq 'all') {
                    # One field per disk, named by its current kernel name so
                    # the chart legend reads the way the disk grid does.
                    my $total = 0;
                    $total += $point->{rdbytes} if defined($point->{rdbytes});
                    $total += $point->{wrbytes} if defined($point->{wrbytes});
                    $row->{ $entry->{dev} // $entry->{key} } = $total;
                } else {
                    $row->{read} = $point->{rdbytes};
                    $row->{write} = $point->{wrbytes};
                    $row->{readiops} = $point->{rdios};
                    $row->{writeiops} = $point->{wrios};

                    # io_ticks accrues milliseconds of non-idle time per second,
                    # so the rate is utilisation once scaled out of milliseconds.
                    $row->{util} = defined($point->{iotime})
                        ? $point->{iotime} / 10
                        : undef;

                    # Average service time: both sides are rates over the same
                    # interval, so the ratio is milliseconds per operation.
                    my $ios = ($point->{rdios} // 0) + ($point->{wrios} // 0);
                    my $ticks = ($point->{rdtime} // 0) + ($point->{wrtime} // 0);
                    $row->{latency} = $ios > 0 ? $ticks / $ios : 0;
                }
            }
        }

        return [map { $rows->{$_} } sort { $a <=> $b } keys %$rows];
    },
});

__PACKAGE__->register_method({
    name => 'io',
    path => '',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Live block device I/O counters for the node, with per-guest attribution."
        . " Counters are monotonic since boot; derive rates from the delta between two"
        . " samples using the returned timestamp.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            time => {
                type => 'number',
                description => "Sample timestamp (seconds since the epoch, sub-second precision).",
            },
            disks => {
                type => 'array',
                description => "Physical disks with their /proc/diskstats counters.",
                items => { type => 'object' },
            },
            guests => {
                type => 'array',
                description => "Running guests with the I/O they are responsible for.",
                items => { type => 'object' },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        require Cwd;

        my $now = time();
        my $physical = PVE::DiskIO::physical_disks();
        my $diskstats = PVE::DiskIO::diskstats();
        my $cache = {};

        my $disks = [];
        for my $devno (keys %$physical) {
            my $disk = $physical->{$devno};
            my $stats = $diskstats->{$devno};
            next if !$stats;

            my $entry = { %$disk };
            $entry->{$_} = $stats->{$_} for grep { $_ ne 'dev' } keys %$stats;
            $entry->{read_bytes} = $stats->{read_sectors} * PVE::DiskIO::SECTOR_SIZE;
            $entry->{write_bytes} = $stats->{write_sectors} * PVE::DiskIO::SECTOR_SIZE;
            $entry->{discard_bytes} = $stats->{discard_sectors} * PVE::DiskIO::SECTOR_SIZE;

            push @$disks, $entry;
        }

        my $lxc_ids = [grep { /^\d+$/ } PVE::DiskIO::listdir('/sys/fs/cgroup/lxc')];
        my $qemu_ids =
            [map { /^(\d+)\.scope$/ ? $1 : () } PVE::DiskIO::listdir('/sys/fs/cgroup/qemu.slice')];

        my $meta = _guest_metadata($lxc_ids, $qemu_ids, $physical, $cache);

        my $guests = [];
        push @$guests, @{ _lxc_guests($physical, $meta->{lxc}) };
        push @$guests, @{ _qemu_guests($meta->{qemu}) };

        return {
            time => $now,
            disks => $disks,
            guests => $guests,
        };
    },
});

1;
