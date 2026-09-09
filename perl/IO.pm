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

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools;

use base qw(PVE::RESTHandler);

# Kernel always reports /proc/diskstats sectors in 512 byte units,
# regardless of the device's real logical block size.
use constant SECTOR_SIZE => 512;

my $SKIP_BLOCK_RE = qr/^(?:loop|ram|zram|sr|fd|nbd|md|dm-|zd)/;

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/ = undef;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub _slurp_trim {
    my ($path) = @_;
    my $data = _slurp($path);
    return undef if !defined($data);
    chomp $data;
    $data =~ s/^\s+|\s+$//g;
    return $data;
}

sub _listdir {
    my ($path) = @_;
    opendir(my $dh, $path) or return ();
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return @entries;
}

# udev's on-disk database gives us the good model/serial strings (the ones
# lsblk shows) without shelling out. sysfs 'device/model' is the raw SCSI
# INQUIRY string, which for USB bridges is the bridge, not the drive.
sub _udev_props {
    my ($devno) = @_;
    my $props = {};
    my $data = _slurp("/run/udev/data/b$devno");
    return $props if !defined($data);
    for my $line (split(/\n/, $data)) {
        next if $line !~ /^E:([^=]+)=(.*)$/;
        $props->{$1} = $2;
    }
    return $props;
}

# Enumerate whole physical disks (no partitions, no device-mapper, no loop).
sub _physical_disks {
    my $disks = {};

    for my $name (_listdir('/sys/block')) {
        next if $name =~ $SKIP_BLOCK_RE;

        my $devno = _slurp_trim("/sys/block/$name/dev");
        next if !defined($devno) || $devno !~ /^\d+:\d+$/;

        my $sectors = _slurp_trim("/sys/block/$name/size") // 0;
        my $rotational = _slurp_trim("/sys/block/$name/queue/rotational");
        my $udev = _udev_props($devno);

        # The bus is more reliably read off the sysfs device path than from
        # udev's ID_BUS, which is missing for NVMe and lies for USB bridges.
        my $syspath = readlink("/sys/block/$name") // '';
        my $transport =
            $name =~ /^nvme/ ? 'nvme'
          : $syspath =~ m{/usb\d+/} ? 'usb'
          : $udev->{ID_BUS} ? $udev->{ID_BUS}
          : 'unknown';

        my $kind = $name =~ /^nvme/ ? 'nvme' : (defined($rotational) && !$rotational) ? 'ssd' : 'hdd';

        my $scheduler = _slurp_trim("/sys/block/$name/queue/scheduler") // '';
        $scheduler = $1 if $scheduler =~ /\[([^\]]+)\]/;

        my ($inflight_rd, $inflight_wr) = (0, 0);
        if (my $inflight = _slurp_trim("/sys/block/$name/inflight")) {
            ($inflight_rd, $inflight_wr) = split(/\s+/, $inflight);
        }

        $disks->{$devno} = {
            dev => $name,
            devno => $devno,
            size => $sectors * SECTOR_SIZE,
            rotational => $rotational ? 1 : 0,
            kind => $kind,
            transport => $transport,
            scheduler => $scheduler,
            model => $udev->{ID_MODEL} // _slurp_trim("/sys/block/$name/device/model") // '',
            serial => $udev->{ID_SERIAL_SHORT} // '',
            wwn => $udev->{ID_WWN} // '',
            inflight_read => int($inflight_rd // 0),
            inflight_write => int($inflight_wr // 0),
        };
    }

    return $disks;
}

# /proc/diskstats, keyed by "major:minor". Field order is the documented
# kernel layout; fields 15-19 only exist on newer kernels (discard/flush).
sub _diskstats {
    my $stats = {};

    my $data = _slurp('/proc/diskstats') // '';
    for my $line (split(/\n/, $data)) {
        $line =~ s/^\s+//;
        my @f = split(/\s+/, $line);
        next if scalar(@f) < 14;

        my ($major, $minor, $name) = splice(@f, 0, 3);

        $stats->{"$major:$minor"} = {
            dev => $name,
            read_ios => $f[0] + 0,
            read_merges => $f[1] + 0,
            read_sectors => $f[2] + 0,
            read_ticks => $f[3] + 0,
            write_ios => $f[4] + 0,
            write_merges => $f[5] + 0,
            write_sectors => $f[6] + 0,
            write_ticks => $f[7] + 0,
            in_flight => $f[8] + 0,
            io_ticks => $f[9] + 0,
            time_in_queue => $f[10] + 0,
            discard_ios => ($f[11] // 0) + 0,
            discard_sectors => ($f[13] // 0) + 0,
            flush_ios => ($f[15] // 0) + 0,
            flush_ticks => ($f[16] // 0) + 0,
        };
    }

    return $stats;
}

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
            my $parent = _slurp_trim(dirname($real) . '/dev');
            if (defined($parent)) {
                $found{$_} = 1 for _resolve_physical($parent, $physical, $cache, $seen);
            }
        }
    } else {
        for my $slave (_listdir("$sysdir/slaves")) {
            my $sdevno = _slurp_trim("$sysdir/slaves/$slave/dev");
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

    my $data = _slurp('/proc/self/mountinfo') // '';
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
        my $devno = _slurp_trim("/sys/class/block/$name/dev");
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
    my $data = _slurp($path);
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
    for my $vmid (_listdir('/sys/fs/cgroup/lxc')) {
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

    for my $scope (_listdir('/sys/fs/cgroup/qemu.slice')) {
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
        my $physical = _physical_disks();
        my $diskstats = _diskstats();
        my $cache = {};

        my $disks = [];
        for my $devno (keys %$physical) {
            my $disk = $physical->{$devno};
            my $stats = $diskstats->{$devno};
            next if !$stats;

            my $entry = { %$disk };
            $entry->{$_} = $stats->{$_} for grep { $_ ne 'dev' } keys %$stats;
            $entry->{read_bytes} = $stats->{read_sectors} * SECTOR_SIZE;
            $entry->{write_bytes} = $stats->{write_sectors} * SECTOR_SIZE;
            $entry->{discard_bytes} = $stats->{discard_sectors} * SECTOR_SIZE;

            push @$disks, $entry;
        }

        my $lxc_ids = [grep { /^\d+$/ } _listdir('/sys/fs/cgroup/lxc')];
        my $qemu_ids =
            [map { /^(\d+)\.scope$/ ? $1 : () } _listdir('/sys/fs/cgroup/qemu.slice')];

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
