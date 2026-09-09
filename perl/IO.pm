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
            id => "lxc:$vmid",
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

# Work on the host itself -- mergerfs pooling media, a backup job, nfsd
# serving a share -- lives in no guest cgroup, so attributing only guests
# leaves that I/O showing on a disk with nothing accounting for it. systemd
# puts each unit in its own cgroup and system.slice does enable the io
# controller (unlike qemu.slice), so host work can be attributed per device
# exactly the way containers are, for about 7ms.
sub _host_consumers {
    my ($physical, $daemons) = @_;

    my $consumers = [];

    my @cgroups = (
        glob('/sys/fs/cgroup/system.slice/*/io.stat'),
        glob('/sys/fs/cgroup/user.slice/*/io.stat'),
        '/sys/fs/cgroup/init.scope/io.stat',
    );

    for my $path (@cgroups) {
        next if !-f $path;

        my $per_device = _cgroup_io_stat($path);
        next if !defined($per_device);

        my $dir = $path;
        $dir =~ s{/io\.stat$}{};
        my $unit = $dir;
        $unit =~ s{.*/}{};

        my $devices = {};
        my $total = { rbytes => 0, wbytes => 0, rios => 0, wios => 0, dbytes => 0, dios => 0 };

        for my $devno (keys %$per_device) {
            next if !$physical->{$devno};
            my $entry = $per_device->{$devno};
            $devices->{$devno} = $entry;
            $total->{$_} += $entry->{$_} for keys %$total;
        }

        next if !$total->{rbytes} && !$total->{wbytes};

        push @$consumers, {
            id => "host:$unit",
            name => _unit_label($unit, $dir),
            unit => $unit,
            type => 'host',
            source => 'cgroup',
            # A FUSE daemon does no work of its own: everything it moves was
            # asked for by someone else. Flagging it lets the panel hand its
            # bytes to the callers instead of listing it as the consumer.
            pool => $daemons->{$dir},
            devices => $devices,
            %$total,
        };
    }

    return $consumers;
}

# "mnt-storage.mount" is how systemd spells /mnt/storage, which is not what
# anyone wants to read in a table. Naming the process inside it as well turns
# a cryptic unit into the answer to "what is writing to this disk".
sub _unit_label {
    my ($unit, $dir) = @_;

    my $label = $unit;

    if ($unit =~ /^(.*)\.mount$/) {
        my $escaped = $1;
        # systemd escapes '/' as '-', so that substitution has to happen
        # before \xNN unescaping or a literal '-' (stored as \x2d) breaks.
        $escaped =~ s{-}{/}g;
        $escaped =~ s{\\x([0-9a-fA-F]{2})}{chr(hex($1))}ge;
        $label = "/$escaped";
    } else {
        $label =~ s/\.(?:service|scope|slice|socket|timer)$//;
    }

    if (defined(my $comm = _cgroup_first_comm($dir))) {
        $label .= " ($comm)";
    }

    return $label;
}

# Two extra reads per host cgroup measured ~30ms across the node, doubling the
# endpoint's cost for a string that changes only when a unit restarts.
my $UNIT_COMM_TTL = 60;
my $unit_comm_cache = { updated => 0, names => {} };

sub _cgroup_first_comm {
    my ($dir) = @_;

    if ((time() - $unit_comm_cache->{updated}) >= $UNIT_COMM_TTL) {
        $unit_comm_cache = { updated => time(), names => {} };
    }
    return $unit_comm_cache->{names}->{$dir} if exists $unit_comm_cache->{names}->{$dir};

    my $comm;
    if (my $procs = PVE::DiskIO::slurp("$dir/cgroup.procs")) {
        if (my ($pid) = $procs =~ /^(\d+)/) {
            my $name = PVE::DiskIO::slurp_trim("/proc/$pid/comm");
            $comm = $name if defined($name) && $name ne '';
        }
    }

    $unit_comm_cache->{names}->{$dir} = $comm;
    return $comm;
}

# --- work reaching the disks through a FUSE pool -------------------------

# A container writing to a mergerfs (or any FUSE) pool does not touch a block
# device itself: it makes a syscall, the FUSE daemon on the host does the
# actual I/O, and so the block layer -- and every cgroup built on it -- credits
# the daemon. The panel would then truthfully report "mergerfs is writing to
# sdh" while hiding the only thing worth knowing, which is who asked it to.
#
# These figures are syscall level (rchar/wchar), not block level: they include
# what the page cache absorbed and exclude readahead, so they are deliberately
# kept in their own view rather than summed with the block numbers elsewhere.

my $FUSE_HOLDER_TTL = 30;
my $fuse_holder_cache = { updated => 0, holders => undef };

# FUSE filesystems worth tracing: a storage pool, not PVE's own config
# filesystem or lxcfs.
sub _fuse_pools {
    my $pools = {};

    my $data = PVE::DiskIO::slurp('/proc/self/mountinfo') // '';
    for my $line (split(/\n/, $data)) {
        my @f = split(/\s+/, $line);
        next if scalar(@f) < 10;

        my ($mountpoint) = ($f[4]);
        my $sep = 0;
        $sep++ while $sep < @f && $f[$sep] ne '-';
        my $fstype = $f[$sep + 1] // '';

        next if $fstype !~ /^fuse(?:\.(.+))?$/;
        my $flavour = $1 // 'fuse';
        next if $flavour eq 'lxcfs';
        next if $mountpoint eq '/etc/pve';

        my $dev = (stat($mountpoint))[0];
        next if !defined($dev);

        $pools->{$dev} = { mount => $mountpoint, flavour => $flavour };
    }

    return $pools;
}

# Which physical disk each of a pool's branches lives on, so a file's branch
# can be turned into the disk actually carrying it.
sub _branch_disks {
    my ($physical, $cache) = @_;

    my $branches = {};
    my $data = PVE::DiskIO::slurp('/proc/self/mountinfo') // '';

    for my $line (split(/\n/, $data)) {
        my @f = split(/\s+/, $line);
        next if scalar(@f) < 10;
        my ($devno, $mountpoint) = ($f[2], $f[4]);
        next if $devno !~ /^\d+:\d+$/;

        my @disks = _resolve_physical($devno, $physical, $cache);
        next if !scalar(@disks);
        $branches->{$mountpoint} = \@disks;
    }

    return $branches;
}

# Who a process belongs to: a container, or a host systemd unit. Walking the
# cgroup tree to enumerate container pids instead measured ~960ms, because
# every entry needs a stat to tell a directory from a control file.
sub _pid_owner {
    my ($pid) = @_;

    my $cgroup = PVE::DiskIO::slurp("/proc/$pid/cgroup") // return undef;
    chomp $cgroup;

    return { type => 'lxc', vmid => $1 + 0, cgroup => "/sys/fs/cgroup/lxc/$1" }
        if $cgroup =~ m{/lxc/(\d+)};

    # Host side callers matter too: a rebalance script pooling media is as much
    # a consumer as a container is.
    if ($cgroup =~ m{^0::(/.*)$}) {
        my $path = $1;
        if ($path =~ m{^((?:/system\.slice|/user\.slice)/[^/]+)}) {
            my $dir = "/sys/fs/cgroup$1";
            my $unit = $1;
            $unit =~ s{.*/}{};
            return { type => 'host', unit => $unit, cgroup => $dir };
        }
    }

    return undef;
}

# Finding who holds files open on a pool is the expensive part, but a
# transcode or an unpack lasts minutes, so the set is cached and only the cheap
# per-process counters are re-read on each poll.
sub _fuse_holders {
    my ($physical, $cache) = @_;

    return $fuse_holder_cache->{holders}
        if defined($fuse_holder_cache->{holders})
        && (time() - $fuse_holder_cache->{updated}) < $FUSE_HOLDER_TTL;

    my $pools = _fuse_pools();
    if (!scalar(keys %$pools)) {
        $fuse_holder_cache = { updated => time(), holders => [], daemons => {} };
        return [];
    }

    my $branches = _branch_disks($physical, $cache);
    my $holders = [];
    my $daemons = {};

    for my $pid (PVE::DiskIO::listdir('/proc')) {
        next if $pid !~ /^\d+$/;

        my @matches;
        my $holds_fuse_dev = 0;

        for my $fd (PVE::DiskIO::listdir("/proc/$pid/fd")) {
            my $path = "/proc/$pid/fd/$fd";

            # Most descriptors are sockets and pipes. readlink is cheaper than
            # stat and rules those out without touching the filesystem.
            my $target = readlink($path);
            next if !defined($target) || $target !~ m{^/};

            # The daemon serving a pool holds /dev/fuse; its own file handles
            # point at the branches, not at the pool, so it never looks like a
            # caller of itself.
            if ($target eq '/dev/fuse') {
                $holds_fuse_dev = 1;
                next;
            }
            next if $target =~ m{^/(?:proc|sys|dev)/};

            # A container sees the pool at its own mountpoint, so match on the
            # filesystem itself rather than on any path prefix.
            my $dev = (stat($path))[0];
            next if !defined($dev) || !$pools->{$dev};

            push @matches, $path;
            last if scalar(@matches) >= 24;
        }

        if ($holds_fuse_dev) {
            my $cmdline = PVE::DiskIO::slurp("/proc/$pid/cmdline") // '';
            $cmdline =~ s/\0/ /g;
            for my $dev (keys %$pools) {
                my $mount = $pools->{$dev}->{mount};
                next if index($cmdline, $mount) < 0;
                if (my $owner = _pid_owner($pid)) {
                    $daemons->{ $owner->{cgroup} } = $mount;
                }
            }
        }

        next if !scalar(@matches);

        my $owner = _pid_owner($pid) or next;

        push @$holders, {
            pid => $pid + 0,
            owner => $owner,
            comm => PVE::DiskIO::slurp_trim("/proc/$pid/comm") // 'unknown',
            paths => \@matches,
            weights => {},
        };
    }

    _attach_branch_disks($holders, $branches, $physical);

    $fuse_holder_cache = { updated => time(), holders => $holders, daemons => $daemons };
    return $holders;
}

# mergerfs reports the branch a file actually lives on via an xattr. One
# getfattr call covers every open file at once rather than forking per file.
sub _attach_branch_disks {
    my ($holders, $branches, $physical) = @_;

    return if !scalar(@$holders);

    my $paths = [map { @{ $_->{paths} } } @$holders];
    return if !scalar(@$paths);

    my $basepath = {};
    my $current;

    # getfattr prints "# file: <path>" then "name=value" per file, which is the
    # shape that lets a single call cover every open file at once.
    eval {
        PVE::Tools::run_command(
            ['getfattr', '--absolute-names', '-n', 'user.mergerfs.basepath', @$paths],
            outfunc => sub {
                my ($line) = @_;
                if ($line =~ /^#\s*file:\s*(.+)$/) {
                    $current = $1;
                } elsif ($current && $line =~ /^user\.mergerfs\.basepath="?([^"]*)"?$/) {
                    $basepath->{$current} = $1;
                    $current = undef;
                }
            },
            errfunc => sub { },
            noerr => 1,
        );
    };

    for my $holder (@$holders) {
        my $weights = {};
        for my $path (@{ $holder->{paths} }) {
            my $branch = $basepath->{$path} or next;
            my $devnos = $branches->{$branch} or next;
            # How many of this caller's open files sit on each disk. That is the
            # only split available, and it is what decides how the daemon's
            # block level bytes get shared out between callers.
            $weights->{$_} = ($weights->{$_} // 0) + 1 for @$devnos;
        }
        $holder->{weights} = $weights;
        delete $holder->{paths};
    }
}

sub _fuse_consumers {
    my ($physical, $cache) = @_;

    my $holders = _fuse_holders($physical, $cache);
    my $consumers = [];

    for my $holder (@$holders) {
        my $io = PVE::DiskIO::slurp("/proc/$holder->{pid}/io") or next;
        my ($rchar) = $io =~ /^rchar:\s+(\d+)/m;
        my ($wchar) = $io =~ /^wchar:\s+(\d+)/m;
        next if !defined($rchar) && !defined($wchar);

        my $owner = $holder->{owner};

        push @$consumers, {
            id => "fuse:$holder->{pid}",
            pid => $holder->{pid},
            comm => $holder->{comm},
            type => $owner->{type},
            vmid => $owner->{vmid},
            unit => $owner->{unit},
            weights => $holder->{weights},
            rchar => ($rchar // 0) + 0,
            wchar => ($wchar // 0) + 0,
        };
    }

    return $consumers;
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
            id => "qemu:$vmid",
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
    return _fetch_rrd_file(PVE::DiskIO::rrd_file($node, $key), $timeframe, $cf);
}

sub _fetch_rrd_file {
    my ($file, $timeframe, $cf) = @_;

    my $spec = $TIMEFRAMES->{ $timeframe // 'hour' } or return undef;
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

# --- guest history --------------------------------------------------------

# PVE already records diskread/diskwrite per guest, with the same retention as
# every other guest metric -- that is what the Disk IO graph on a guest's own
# Summary draws. What is missing is a node level view of it, so this reads
# those existing RRDs rather than collecting anything new. Consequence worth
# knowing: it inherits their granularity, which has no per-physical-disk
# dimension. "Which guest" is answerable from history; "which guest on which
# disk" is only answerable live, from the I/O Activity panel.

# How long a computed window stays usable. Scaled to each timeframe's own
# resolution rather than a flat number: the week view consolidates at 30
# minutes and the year view at 6 hours, so re-reading 50 RRDs every 45s to
# redraw an identical line is pure waste. The day view is the expensive one
# (1440 points x ~50 guests, measured ~1.9s) and 5 minutes of staleness at the
# right hand edge of a 24 hour graph is not visible.
my $GUEST_HISTORY_TTL = {
    hour => 60,
    day => 300,
    week => 600,
    month => 900,
    year => 1800,
};

my $guest_history_cache = {};

my $CONSUMER_LIST_TTL = 120;
my $consumer_list_cache = { updated => 0, list => undef };

# Display names, written once a minute by the collector, so labelling a chart
# does not mean reloading every guest config from pmxcfs on each request.
sub _consumer_names {
    my ($node) = @_;
    my $raw = PVE::DiskIO::slurp(PVE::DiskIO::consumers_file($node));
    return defined($raw) ? (eval { decode_json($raw) } || {}) : {};
}

# Directory names are sanitised, so map back from what is on disk to the
# consumer id the collector used.
sub _consumer_dirs {
    my ($node) = @_;

    if ($consumer_list_cache->{list}
        && (time() - $consumer_list_cache->{updated}) < $CONSUMER_LIST_TTL) {
        return $consumer_list_cache->{list};
    }

    my $names = _consumer_names($node);
    my $root = PVE::DiskIO::rrd_dir($node);
    my $found = [];

    for my $vmid (PVE::DiskIO::listdir("$root/guests")) {
        next if $vmid !~ /^\d+$/;
        my $id = (grep { $_ eq "lxc:$vmid" || $_ eq "qemu:$vmid" } keys %$names)[0]
            // "lxc:$vmid";
        push @$found, {
            id => $id,
            vmid => $vmid + 0,
            kind => 'guest',
            dir => "$root/guests/$vmid",
            name => $names->{$id} // $vmid,
        };
    }

    my $host_by_dir = {};
    for my $id (keys %$names) {
        next if $id !~ /^host:(.+)$/;
        my $unit = $1;
        $unit =~ s/[^A-Za-z0-9_.@-]/_/g;
        $host_by_dir->{$unit} = $id;
    }

    for my $unit (PVE::DiskIO::listdir("$root/hosts")) {
        my $id = $host_by_dir->{$unit} // "host:$unit";
        push @$found, {
            id => $id,
            kind => 'host',
            dir => "$root/hosts/$unit",
            name => $names->{$id} // $unit,
        };
    }

    $consumer_list_cache = { updated => time(), list => $found };
    return $found;
}

sub _consumer_field {
    my ($consumer) = @_;
    return $consumer->{kind} eq 'guest'
        ? "$consumer->{name} ($consumer->{vmid})"
        : $consumer->{name};
}

# History for every consumer on the node, summed across the disks each touched.
# Read from this module's own RRDs rather than PVE's per-guest ones: those cover
# guests only, and they exclude I/O a guest does through a storage pool, which
# on a media host is most of it.
sub _consumer_history {
    my ($node, $timeframe, $cf) = @_;

    my $key = join('/', $node, $timeframe, $cf);
    my $ttl = $GUEST_HISTORY_TTL->{$timeframe} // 60;
    my $cached = $guest_history_cache->{$key};
    return $cached->{data} if $cached && (time() - $cached->{updated}) < $ttl;

    my $consumers = [];
    my $series = {};
    my $totals = {};
    my $timeline = {};

    for my $consumer (@{ _consumer_dirs($node) }) {
        my $points = {};
        my $total = 0;
        my $any = 0;

        for my $entry (PVE::DiskIO::listdir($consumer->{dir})) {
            next if $entry !~ /\.rrd$/;
            my $data = _fetch_rrd_file("$consumer->{dir}/$entry", $timeframe, $cf) or next;

            for my $point (@$data) {
                $timeline->{ $point->{time} } = 1;
                next if !defined($point->{read}) && !defined($point->{write});

                my $sum = ($point->{read} // 0) + ($point->{write} // 0);
                $points->{ $point->{time} } += $sum;
                $total += $sum;
                $any = 1;
            }
        }

        push @$consumers, $consumer;
        next if !$any;

        $series->{ $consumer->{id} } = $points;
        $totals->{ $consumer->{id} } = $total;
    }

    my $result = {
        consumers => $consumers,
        series => $series,
        totals => $totals,
        timeline => $timeline,
    };
    $guest_history_cache->{$key} = { updated => time(), data => $result };

    return $result;
}

sub _ranked_consumers {
    my ($history, $top) = @_;

    my $totals = $history->{totals};
    my $by_id = { map { $_->{id} => $_ } @{ $history->{consumers} } };

    my @ranked =
        sort { ($totals->{$b} // 0) <=> ($totals->{$a} // 0) || $a cmp $b }
        grep { ($totals->{$_} // 0) > 0 }
        keys %$totals;

    my @head = splice(@ranked, 0, $top);

    return {
        top => [map { $by_id->{$_} } @head],
        rest => [map { $by_id->{$_} } @ranked],
    };
}

# Either identifier is accepted: the guest pages know a vmid, the node chart
# knows a consumer id and may be pointing at a host unit.
sub _resolve_consumer {
    my ($param) = @_;

    return $param->{consumer} if $param->{consumer};
    return undef if !defined($param->{vmid});

    # A guest's directory is its vmid whichever type it is, so either prefix
    # resolves to the same place.
    return "lxc:$param->{vmid}";
}

# Which disks a guest has recorded history on, and how much it moved on each
# over the window being displayed, so the chart can rank and colour them.
sub _guest_disk_totals {
    my ($node, $id, $timeframe, $cf) = @_;

    my $dir = PVE::DiskIO::consumer_rrd_dir($node, $id);
    return [] if !$dir || !-d $dir;

    my $raw = PVE::DiskIO::slurp(PVE::DiskIO::index_file($node));
    my $index = defined($raw) ? (eval { decode_json($raw) } || []) : [];
    my $names = { map { $_->{key} => $_->{dev} } @$index };

    # Which of this guest's disks it reaches through a storage pool, so the
    # chart can say which series are apportioned rather than measured.
    my $flags_raw = PVE::DiskIO::slurp("$PVE::DiskIO::RRD_BASE/$node.guestflags.json");
    my $flags = defined($flags_raw) ? (eval { decode_json($flags_raw) } || {}) : {};

    my $out = [];
    my $timeline = {};

    for my $entry (PVE::DiskIO::listdir($dir)) {
        next if $entry !~ /^(.+)\.rrd$/;
        my $key = $1;

        my $series = _fetch_rrd_file("$dir/$entry", $timeframe, $cf) or next;

        my $total = 0;
        my $points = {};
        my $any = 0;
        for my $point (@$series) {
            # Keep every timestamp in the window, not only the ones with a
            # value. Dropping the empty leading rows shortened the x axis, so
            # the graph did not line up with the ones beside it on the page.
            $timeline->{ $point->{time} } = 1;

            next if !defined($point->{read}) && !defined($point->{write});

            my $sum = ($point->{read} // 0) + ($point->{write} // 0);
            $points->{ $point->{time} } = $sum;
            $total += $sum;
            $any = 1;
        }
        next if !$any;

        push @$out, {
            key => $key,
            dev => $names->{$key} // $key,
            total => $total,
            points => $points,
            via_pool => $flags->{"$id/$key"} ? 1 : 0,
        };
    }

    my $disks = [sort { $b->{total} <=> $a->{total} || $a->{dev} cmp $b->{dev} } @$out];
    return wantarray ? ($disks, $timeline) : $disks;
}

__PACKAGE__->register_method({
    name => 'guestdisklist',
    path => 'guestdisklist',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Disks a guest has recorded I/O history on, busiest first.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => {
                type => 'integer',
                optional => 1,
                description => "A guest. Shorthand for consumer=lxc:<vmid>; the"
                    . " guest pages use it, the node chart uses consumer.",
            },
            consumer => {
                type => 'string',
                optional => 1,
                pattern => '^(?:lxc|qemu|host):.+$',
                maxLength => 256,
                description => "A consumer id, as returned by guestlist -- a"
                    . " guest or a host unit.",
            },
            timeframe => {
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year'],
            },
            cf => {
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $id = _resolve_consumer($param) or return [];
        my $disks = _guest_disk_totals(
            $param->{node}, $id, $param->{timeframe}, $param->{cf} // 'AVERAGE',
        );

        return [
            map { { key => $_->{key}, dev => $_->{dev}, total => $_->{total},
                    via_pool => $_->{via_pool} } } @$disks
        ];
    },
});

__PACKAGE__->register_method({
    name => 'guestdiskrrddata',
    path => 'guestdiskrrddata',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "A guest's disk I/O history broken down by physical disk."
        . " Each row carries one field per disk, named the way the disk grid"
        . " names it.",
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => {
                type => 'integer',
                optional => 1,
                description => "A guest. Shorthand for consumer=lxc:<vmid>; the"
                    . " guest pages use it, the node chart uses consumer.",
            },
            consumer => {
                type => 'string',
                optional => 1,
                pattern => '^(?:lxc|qemu|host):.+$',
                maxLength => 256,
                description => "A consumer id, as returned by guestlist -- a"
                    . " guest or a host unit.",
            },
            timeframe => {
                type => 'string',
                enum => ['hour', 'day', 'week', 'month', 'year'],
            },
            cf => {
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $id = _resolve_consumer($param) or return [];
        my ($disks, $timeline) = _guest_disk_totals(
            $param->{node}, $id, $param->{timeframe}, $param->{cf} // 'AVERAGE',
        );
        return [] if !scalar(@$disks);

        # Seed every timestamp the window covers so the axis spans the same
        # range as the other graphs on the page; gaps render as gaps.
        my $rows = { map { $_ => { time => $_ + 0 } } keys %$timeline };
        for my $disk (@$disks) {
            for my $t (keys %{ $disk->{points} }) {
                my $row = $rows->{$t} //= { time => $t + 0 };
                $row->{ $disk->{dev} } = $disk->{points}->{$t};
            }
        }

        return [map { $rows->{$_} } sort { $a <=> $b } keys %$rows];
    },
});

__PACKAGE__->register_method({
    name => 'guestlist',
    path => 'guestlist',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Guests on this node ranked by how much disk I/O they did"
        . " over the given timeframe. The chart uses this to decide which"
        . " series to draw, so the ranking is per window: whoever mattered"
        . " overnight is not necessarily whoever matters this hour.",
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
            },
            cf => {
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
            top => {
                type => 'integer',
                minimum => 1,
                maximum => 16,
                optional => 1,
                default => 8,
                description => "How many guests to name individually; the rest"
                    . " are summed into a single 'Other' series.",
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $cf = $param->{cf} // 'AVERAGE';
        my $history = _consumer_history($param->{node}, $param->{timeframe}, $cf);
        my $ranked = _ranked_consumers($history, $param->{top} // 8);

        my $out = [];
        for my $consumer (@{ $ranked->{top} }) {
            push @$out, {
                id => $consumer->{id},
                vmid => $consumer->{vmid},
                name => $consumer->{name},
                type => $consumer->{kind},
                field => _consumer_field($consumer),
                total => $history->{totals}->{ $consumer->{id} } // 0,
            };
        }

        if (scalar(@{ $ranked->{rest} })) {
            # No vmid: 0 is not a guest id, and emitting one invites callers
            # to render it as though it were.
            push @$out, {
                name => 'Other',
                type => 'other',
                field => 'Other',
                count => scalar(@{ $ranked->{rest} }),
            };
        }

        # Everything on the node, so the picker can offer a guest that is not
        # currently in the top N (or is idle right now).
        return [
            @$out,
            map {
                {
                    id => $_->{id},
                    vmid => $_->{vmid},
                    name => $_->{name},
                    type => $_->{kind},
                    field => _consumer_field($_),
                    selectable => 1,
                }
            } @{ $history->{consumers} },
        ];
    },
});

__PACKAGE__->register_method({
    name => 'guestrrddata',
    path => 'guestrrddata',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Per-guest disk I/O history for the node, read from the"
        . " per-guest RRDs PVE already maintains. With guest=all each row"
        . " carries one field per top guest plus 'Other'; with a vmid each row"
        . " carries that guest's read and write.",
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
            },
            cf => {
                type => 'string',
                enum => ['AVERAGE', 'MAX'],
                optional => 1,
            },
            guest => {
                type => 'string',
                optional => 1,
                pattern => '^(?:all|\d+)$',
                description => "A vmid, or 'all' (the default) to overlay the"
                    . " busiest guests.",
            },
            top => {
                type => 'integer',
                minimum => 1,
                maximum => 16,
                optional => 1,
                default => 8,
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
    },
    code => sub {
        my ($param) = @_;

        my $cf = $param->{cf} // 'AVERAGE';
        my $which = $param->{guest} // 'all';
        my $history = _consumer_history($param->{node}, $param->{timeframe}, $cf);
        my $ranked = _ranked_consumers($history, $param->{top} // 8);

        # Seed the whole window so the axis matches the graphs beside it.
        my $rows = { map { $_ => { time => $_ + 0 } } keys %{ $history->{timeline} } };

        for my $consumer (@{ $ranked->{top} }) {
            my $field = _consumer_field($consumer);
            my $points = $history->{series}->{ $consumer->{id} } or next;
            for my $t (keys %$points) {
                $rows->{$t}->{$field} = $points->{$t};
            }
        }

        for my $consumer (@{ $ranked->{rest} }) {
            my $points = $history->{series}->{ $consumer->{id} } or next;
            for my $t (keys %$points) {
                $rows->{$t}->{Other} = ($rows->{$t}->{Other} // 0) + $points->{$t};
            }
        }

        return [map { $rows->{$_} } sort { $a <=> $b } keys %$rows];
    },
});

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
            fuse => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Also trace containers reaching the disks through"
                    . " a FUSE pool such as mergerfs. Costs a few hundred ms to"
                    . " find which processes hold files open, so it is opt in.",
            },
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
            fuse => {
                type => 'array',
                description => "Containers reaching the disks through a FUSE"
                    . " pool such as mergerfs, which the block layer credits to"
                    . " the FUSE daemon rather than to them. Counters are"
                    . " syscall level (rchar/wchar), so they are not comparable"
                    . " with the block level figures in 'guests'.",
                items => { type => 'object' },
            },
            guests => {
                type => 'array',
                description => "Everything accounted for the node's disk I/O:"
                    . " running guests, plus host systemd units, which is where"
                    . " work like mergerfs or a backup job shows up.",
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
        # Scan for FUSE callers first: it also identifies which host cgroup is
        # the pool's daemon, which the host consumer list needs in order to flag
        # it rather than present it as a consumer in its own right.
        my $fuse = $param->{fuse} ? (eval { _fuse_consumers($physical, $cache) } // []) : [];
        my $daemons = $param->{fuse} ? ($fuse_holder_cache->{daemons} // {}) : {};

        push @$guests, @{ _host_consumers($physical, $daemons) };

        return {
            time => $now,
            disks => $disks,
            guests => $guests,
            fuse => $fuse,
        };
    },
});

1;
