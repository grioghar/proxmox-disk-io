package PVE::DiskIO;

# Low level block device statistics, shared by the live API endpoint
# (PVE::API2::Disks::IO) and the history collector, plus the RRD layout used
# to persist that history.
#
# Everything here reads only procfs, sysfs and udev's on-disk database, so it
# is cheap enough both for a 1s UI poll and for a standalone collector that
# must not drag in the whole API stack.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use Fcntl qw(LOCK_EX LOCK_NB LOCK_UN);
use JSON qw(decode_json encode_json);

# Kernel always reports /proc/diskstats sectors in 512 byte units, regardless
# of the device's real logical block size.
use constant SECTOR_SIZE => 512;

our $RRD_BASE = '/var/lib/pve-disk-io';

# Not whole disks: partitions live under their parent, and the rest are either
# virtual (dm, md, loop, zram) or removable oddities we do not track.
my $SKIP_BLOCK_RE = qr/^(?:loop|ram|zram|sr|fd|nbd|md|dm-|zd)/;

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/ = undef;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub slurp_trim {
    my ($path) = @_;
    my $data = slurp($path);
    return undef if !defined($data);
    chomp $data;
    $data =~ s/^\s+|\s+$//g;
    return $data;
}

sub listdir {
    my ($path) = @_;
    opendir(my $dh, $path) or return ();
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return @entries;
}

# udev's database gives the good model/serial strings (the ones lsblk shows)
# without shelling out. sysfs 'device/model' is the raw SCSI INQUIRY string,
# which for a USB bridge describes the bridge rather than the drive behind it.
sub udev_props {
    my ($devno) = @_;
    my $props = {};
    my $data = slurp("/run/udev/data/b$devno");
    return $props if !defined($data);
    for my $line (split(/\n/, $data)) {
        next if $line !~ /^E:([^=]+)=(.*)$/;
        $props->{$1} = $2;
    }
    return $props;
}

# Enumerate whole physical disks, keyed by "major:minor".
sub physical_disks {
    my $disks = {};

    for my $name (listdir('/sys/block')) {
        next if $name =~ $SKIP_BLOCK_RE;

        my $devno = slurp_trim("/sys/block/$name/dev");
        next if !defined($devno) || $devno !~ /^\d+:\d+$/;

        my $sectors = slurp_trim("/sys/block/$name/size") // 0;
        my $rotational = slurp_trim("/sys/block/$name/queue/rotational");
        my $udev = udev_props($devno);

        # The bus is more reliably read off the sysfs device path than from
        # udev's ID_BUS, which is absent for NVMe and describes the bridge
        # rather than the drive for USB enclosures.
        my $syspath = readlink("/sys/block/$name") // '';
        my $transport =
            $name =~ /^nvme/ ? 'nvme'
          : $syspath =~ m{/usb\d+/} ? 'usb'
          : $udev->{ID_BUS} ? $udev->{ID_BUS}
          : 'unknown';

        my $kind = $name =~ /^nvme/ ? 'nvme' : (defined($rotational) && !$rotational) ? 'ssd' : 'hdd';

        my $scheduler = slurp_trim("/sys/block/$name/queue/scheduler") // '';
        $scheduler = $1 if $scheduler =~ /\[([^\]]+)\]/;

        my ($inflight_rd, $inflight_wr) = (0, 0);
        if (my $inflight = slurp_trim("/sys/block/$name/inflight")) {
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
            model => $udev->{ID_MODEL} // slurp_trim("/sys/block/$name/device/model") // '',
            serial => $udev->{ID_SERIAL_SHORT} // '',
            wwn => $udev->{ID_WWN} // '',
            inflight_read => int($inflight_rd // 0),
            inflight_write => int($inflight_wr // 0),
        };
    }

    return $disks;
}

# /proc/diskstats keyed by "major:minor". Field order is the documented kernel
# layout; the discard and flush fields only exist on newer kernels.
# ── SMART ────────────────────────────────────────────────────────────────────
# Health for the drives the panel already lists. Deliberately NOT the overall
# "SMART Health Status" flag on its own: that stays PASSED on a drive with two
# dozen pending and uncorrectable sectors, which is exactly the case this is
# meant to catch. Read the attributes that actually predict failure, plus any
# attribute the drive itself reports as FAILING_NOW.
#
# smartctl is slow (a second or so per USB-bridged spinner, and it can spin an
# idle drive up), so it never runs inline with the I/O poll. A systemd timer
# refreshes the cache every 10 minutes and the API only ever reads it, so a
# panel left open cannot keep the drives awake. Each entry carries an `age` in
# seconds so the UI can say how stale the reading is.

use constant SMART_CACHE => '/run/pve-disk-io-smart.json';
use constant SMART_LOCK => '/run/pve-disk-io-smart.lock';

# attribute id => key we report
my %SMART_ATTRS = (
    5 => 'reallocated',
    187 => 'reported_uncorrect',
    197 => 'pending',
    198 => 'offline_uncorrectable',
    199 => 'crc_errors',
);

sub _smart_one {
    my ($dev, $kind) = @_;

    # Flash runs hot by design: an NVMe at 66C is normal, a spinner at 66C is
    # cooking. One flat threshold would cry wolf on every SSD in the box.
    my ($t_warn, $t_crit) = ($kind && $kind ne 'hdd') ? (70, 80) : (55, 60);

    # USB bridges need -d sat; NVMe and plain SATA autodetect fine.
    my $json;
    for my $args ([ '-d', 'sat' ], []) {
        my $cmd = join(' ', 'smartctl', '-j', '-A', '-H', '-i', @$args, "/dev/$dev", '2>/dev/null');
        my $out = qx{$cmd};
        next if !defined($out) || $out eq '';
        my $d = eval { decode_json($out) };
        next if !$d;
        if ($d->{ata_smart_attributes} || $d->{smart_status} || $d->{nvme_smart_health_information_log}) {
            $json = $d;
            last;
        }
    }
    return undef if !$json;

    my $row = {
        passed => $json->{smart_status}->{passed} ? 1 : (defined($json->{smart_status}->{passed}) ? 0 : undef),
        temp => $json->{temperature}->{current},
        hours => $json->{power_on_time}->{hours},
        # -i is already in the command, so these are free here and save every
        # other consumer of this cache from shelling out to identify the drive.
        model => $json->{model_name},
        serial => $json->{serial_number},
    };

    my @failing;
    for my $a (@{ $json->{ata_smart_attributes}->{table} // [] }) {
        my $key = $SMART_ATTRS{ $a->{id} // -1 };
        $row->{$key} = $a->{raw}->{value} + 0 if defined $key;
        push @failing, $a->{name}
          if defined($a->{when_failed}) && $a->{when_failed} ne '' && $a->{when_failed} ne '-';
    }
    # NVMe reports differently
    if (my $n = $json->{nvme_smart_health_information_log}) {
        $row->{temp} //= $n->{temperature};
        $row->{hours} //= $n->{power_on_hours};
        $row->{wearout} = $n->{percentage_used};
    }
    $row->{failing_now} = \@failing;

    my @problems;
    push @problems, 'SMART overall health FAILED' if defined($row->{passed}) && !$row->{passed};
    push @problems, "attribute FAILING_NOW: " . join(', ', @failing) if @failing;
    for my $pair ([ 'pending', 'pending sectors' ],
        [ 'offline_uncorrectable', 'uncorrectable sectors' ],
        [ 'reallocated', 'reallocated sectors' ]) {
        my ($k, $human) = @$pair;
        push @problems, "$row->{$k} $human" if ($row->{$k} // 0) > 0;
    }
    my $t = $row->{temp};
    if (defined $t) {
        push @problems, "${t}C (at or over the ${t_crit}C limit)" if $t >= $t_crit;
        push @problems, "${t}C (warm)" if $t >= $t_warn && $t < $t_crit;
    }
    $row->{problems} = \@problems;

    $row->{state} =
        (defined($row->{passed}) && !$row->{passed})
        || @failing
        || ($row->{pending} // 0) > 0
        || ($row->{offline_uncorrectable} // 0) > 0
        || (defined($t) && $t >= $t_crit) ? 'critical'
      : @problems ? 'warn'
      : 'ok';

    return $row;
}

sub smart_refresh {
    # One refresher at a time: a stampede would spin every drive up at once.
    open(my $lock, '>', SMART_LOCK) or return 0;
    return 0 if !flock($lock, LOCK_EX | LOCK_NB);

    my $physical = physical_disks();
    my $out = { updated => time(), disks => {} };
    for my $devno (sort keys %$physical) {
        my $disk = $physical->{$devno};
        my $row = _smart_one($disk->{dev}, $disk->{kind});
        $out->{disks}->{ $disk->{dev} } = $row if $row;
    }

    my $tmp = SMART_CACHE . ".$$";
    if (open(my $fh, '>', $tmp)) {
        print {$fh} encode_json($out);
        close($fh);
        rename($tmp, SMART_CACHE);
    } else {
        unlink($tmp);
    }
    flock($lock, LOCK_UN);
    close($lock);
    return scalar keys %{ $out->{disks} };
}

sub smart_status {
    my $cached = {};
    if (my $raw = slurp(SMART_CACHE)) {
        my $d = eval { decode_json($raw) };
        if ($d && ref($d->{disks}) eq 'HASH') {
            $cached = $d->{disks};
            my $age = time() - ($d->{updated} // 0);
            $_->{age} = $age for values %$cached;
        }
    }
    return $cached;
}

sub diskstats {
    my $stats = {};

    my $data = slurp('/proc/diskstats') // '';
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

# --- history -------------------------------------------------------------

# A disk's kernel name is not stable: USB enclosures in particular reorder
# across reboots, so history keyed on "sdb" would silently follow whichever
# drive happened to enumerate second. Key on the serial instead, so a disk's
# history follows the physical drive. Cheap enclosures do sometimes report a
# blank or duplicated serial, hence the fallbacks.
sub disk_key {
    my ($disk, $taken) = @_;

    for my $candidate ($disk->{serial}, $disk->{wwn}) {
        next if !defined($candidate) || $candidate eq '';
        my $key = $candidate;
        $key =~ s/[^A-Za-z0-9_.-]/_/g;
        next if $key eq '' || ($taken && $taken->{$key});
        return $key;
    }

    my $key = "dev-$disk->{dev}";
    $key =~ s/[^A-Za-z0-9_.-]/_/g;
    return $key;
}

sub rrd_dir {
    my ($node) = @_;
    return "$RRD_BASE/rrd/$node";
}

sub rrd_file {
    my ($node, $key) = @_;
    return rrd_dir($node) . "/$key.rrd";
}

sub index_file {
    my ($node) = @_;
    return "$RRD_BASE/$node.index.json";
}

# Stored as raw counters with DERIVE, so rrdtool computes the rates itself.
# That keeps the collector stateless: it never has to remember a previous
# sample, and a missed run or a reboot cannot produce a bogus spike.
our @DS_NAMES = qw(rdbytes wrbytes rdios wrios iotime rdtime wrtime);

sub _ds_defs {
    # heartbeat 120 = two steps: one missed sample is interpolated, a longer
    # gap is recorded as unknown rather than smeared across the outage.
    return map { "DS:$_:DERIVE:120:0:U" } @DS_NAMES;
}

# Mirrors the retention of PVE's own node RRDs (pve-node-9.0) exactly, so the
# graph behaves identically under the Hour/Day/Week/Month/Year selector.
sub _rra_defs {
    return (
        'RRA:AVERAGE:0.5:1:1440',      # 1 min x 1440   = 24 hours
        'RRA:AVERAGE:0.5:30:1440',     # 30 min x 1440  = 30 days
        'RRA:AVERAGE:0.5:360:1440',    # 6 hours x 1440 = ~1 year
        'RRA:AVERAGE:0.5:10080:570',   # 7 days x 570   = ~11 years
        'RRA:MAX:0.5:1:1440',
        'RRA:MAX:0.5:30:1440',
        'RRA:MAX:0.5:360:1440',
        'RRA:MAX:0.5:10080:570',
    );
}

use constant RRD_STEP => 60;

sub ensure_rrd {
    my ($node, $key) = @_;

    my $file = rrd_file($node, $key);
    return $file if -f $file;

    make_path(dirname($file));

    require RRDs;
    RRDs::create($file, '--step', RRD_STEP, _ds_defs(), _rra_defs());
    if (my $err = RRDs::error()) {
        die "could not create $file: $err\n";
    }

    return $file;
}

sub update_rrd {
    my ($node, $key, $time, $values) = @_;

    my $file = ensure_rrd($node, $key);

    require RRDs;
    RRDs::update($file, '--', join(':', $time, @$values));
    if (my $err = RRDs::error()) {
        # A duplicate timestamp just means the collector ran twice in the same
        # second; that is not worth failing the whole run over.
        return 0 if $err =~ /illegal attempt to update using time/;
        die "could not update $file: $err\n";
    }

    return 1;
}


# --- per (guest, disk) history -------------------------------------------

# PVE's own guest RRDs record diskread/diskwrite but have no per-disk
# dimension, so "which guest" is answerable from history while "which guest, on
# which disk" is not. These add that dimension.
#
# Stored as GAUGE rates rather than DERIVE counters, because the figures are
# not all counters: I/O that reaches a disk through a FUSE pool has to be
# apportioned between the pool's callers, and an apportioned share is a rate,
# not something with a monotonic total behind it. The collector therefore keeps
# the previous sample and computes over the whole interval, rather than
# sampling briefly and extrapolating.

# Consumers are guests or host units, so their ids ("lxc:3111", "qemu:101",
# "host:rebalance-runner.service") become a directory each. Host unit names are
# sanitised because they are attacker-adjacent only in the sense that anything
# on the system can create a unit, and they end up as path components.
sub consumer_rrd_dir {
    my ($node, $id) = @_;

    my ($kind, $rest) = split(/:/, $id, 2);
    return undef if !defined($rest) || $rest eq '';

    $rest =~ s/[^A-Za-z0-9_.@-]/_/g;
    return undef if $rest eq '' || $rest =~ /^\.\.?$/;

    return rrd_dir($node) . ($kind eq 'host' ? "/hosts/$rest" : "/guests/$rest");
}

sub guest_rrd_dir {
    my ($node, $vmid) = @_;
    return rrd_dir($node) . "/guests/$vmid";
}

sub guest_rrd_file {
    my ($node, $vmid, $key) = @_;
    return guest_rrd_dir($node, $vmid) . "/$key.rrd";
}

sub consumer_rrd_file {
    my ($node, $id, $key) = @_;
    my $dir = consumer_rrd_dir($node, $id) or return undef;
    return "$dir/$key.rrd";
}

sub state_file {
    my ($node) = @_;
    return "$RRD_BASE/$node.state.json";
}

# Display names for consumers, written by the collector so the query side does
# not have to go back to pmxcfs for every guest on every request.
sub consumers_file {
    my ($node) = @_;
    return "$RRD_BASE/$node.consumers.json";
}

our @GUEST_DS_NAMES = qw(read write);

sub ensure_consumer_rrd {
    my ($node, $id, $key) = @_;

    my $file = consumer_rrd_file($node, $id, $key) or return undef;
    return $file if -f $file;

    make_path(dirname($file));

    require RRDs;
    RRDs::create(
        $file,
        '--step', RRD_STEP,
        (map { "DS:$_:GAUGE:120:0:U" } @GUEST_DS_NAMES),
        _rra_defs(),
    );
    if (my $err = RRDs::error()) {
        die "could not create $file: $err\n";
    }

    return $file;
}

sub update_consumer_rrd {
    my ($node, $id, $key, $time, $read, $write) = @_;

    my $file = ensure_consumer_rrd($node, $id, $key) or return 0;

    require RRDs;
    RRDs::update($file, '--', sprintf('%d:%.2f:%.2f', $time, $read, $write));
    if (my $err = RRDs::error()) {
        return 0 if $err =~ /illegal attempt to update using time/;
        die "could not update $file: $err\n";
    }

    return 1;
}



# Apportion two samples' worth of I/O to the consumers responsible, per disk.
#
# NOTE: this is the same algorithm as distributePoolIO() in pve-disk-io.js.
# The panel computes rates in the browser so the API can stay stateless, while
# the collector has to do it here; there is no way to share one implementation
# across both, so the two must be kept in step by hand.
#
# Returns { "<owner id>" => { "<major:minor>" => { read => bytes/s, write => ... } } }
sub attribute_io {
    my ($prev, $cur) = @_;

    my $dt = $cur->{time} - $prev->{time};
    return {} if !$dt || $dt <= 0;

    my $rate = sub {
        my ($now, $before) = @_;
        return 0 if !defined($now) || !defined($before);
        my $delta = $now - $before;
        return $delta > 0 ? $delta / $dt : 0;
    };

    my %before = map { $_->{id} => $_ } @{ $prev->{guests} };
    my $out = {};
    my $pool = {};

    for my $guest (@{ $cur->{guests} }) {
        my $old = $before{ $guest->{id} } or next;

        for my $devno (keys %{ $guest->{devices} // {} }) {
            my $now = $guest->{devices}->{$devno};
            my $was = ($old->{devices} // {})->{$devno} or next;

            my $read = $rate->($now->{rbytes}, $was->{rbytes});
            my $write = $rate->($now->{wbytes}, $was->{wbytes});
            next if $read + $write <= 0;

            # A FUSE daemon's bytes are not its own; hold them back to share out.
            if ($guest->{pool}) {
                $pool->{$devno}->{read} += $read;
                $pool->{$devno}->{write} += $write;
            } else {
                $out->{ $guest->{id} }->{$devno}->{read} += $read;
                $out->{ $guest->{id} }->{$devno}->{write} += $write;
            }
        }
    }

    return $out if !scalar(keys %$pool);

    # Aggregate callers by owner, not by pid: pids churn constantly here, and
    # matching on them loses a caller the moment its process is replaced.
    my $by_owner = sub {
        my ($list) = @_;
        my $owners = {};
        for my $entry (@{ $list // [] }) {
            my $id = $entry->{type} eq 'lxc'
                ? "lxc:$entry->{vmid}"
                : "host:" . ($entry->{unit} // 'unknown');
            my $owner = $owners->{$id} //= { rchar => 0, wchar => 0, weights => {} };
            $owner->{rchar} += $entry->{rchar} // 0;
            $owner->{wchar} += $entry->{wchar} // 0;
            $owner->{weights}->{$_} += $entry->{weights}->{$_}
                for keys %{ $entry->{weights} // {} };
        }
        return $owners;
    };

    my $was = $by_owner->($prev->{fuse});
    my $now = $by_owner->($cur->{fuse});

    my $callers = [];
    for my $id (keys %$now) {
        my $old = $was->{$id} or next;
        my $read = $rate->($now->{$id}->{rchar}, $old->{rchar});
        my $write = $rate->($now->{$id}->{wchar}, $old->{wchar});
        next if $read + $write <= 0;

        my $weights = $now->{$id}->{weights};
        my $total = 0;
        $total += $weights->{$_} for keys %$weights;

        push @$callers, {
            id => $id,
            read => $read,
            write => $write,
            weights => $weights,
            total_weight => $total,
        };
    }

    return $out if !scalar(@$callers);

    for my $devno (keys %$pool) {
        my $moved = $pool->{$devno};

        # Prefer callers with a descriptor open on this disk; failing that,
        # every active caller. Writeback lands long after the file is closed,
        # so insisting on a live descriptor would credit nobody for real work.
        my @shares =
            map { { caller => $_, fraction => $_->{weights}->{$devno} / $_->{total_weight} } }
            grep { $_->{total_weight} && ($_->{weights}->{$devno} // 0) > 0 } @$callers;

        @shares = map { { caller => $_, fraction => 1 } } @$callers if !scalar(@shares);

        my ($read_w, $write_w, $any_w) = (0, 0, 0);
        for my $share (@shares) {
            $read_w += $share->{caller}->{read} * $share->{fraction};
            $write_w += $share->{caller}->{write} * $share->{fraction};
            $any_w += ($share->{caller}->{read} + $share->{caller}->{write})
                * $share->{fraction};
        }

        for my $share (@shares) {
            my $caller = $share->{caller};
            my $combined = ($caller->{read} + $caller->{write}) * $share->{fraction};

            my $read =
                  $read_w > 0 ? $moved->{read} * ($caller->{read} * $share->{fraction} / $read_w)
                : $any_w > 0 ? $moved->{read} * ($combined / $any_w)
                : 0;
            my $write =
                  $write_w > 0
                ? $moved->{write} * ($caller->{write} * $share->{fraction} / $write_w)
                : $any_w > 0 ? $moved->{write} * ($combined / $any_w)
                : 0;

            next if $read + $write <= 0;

            $out->{ $caller->{id} }->{$devno}->{read} += $read;
            $out->{ $caller->{id} }->{$devno}->{write} += $write;

            # Worth carrying: these bytes were measured against the pool's
            # daemon and apportioned, so the split between simultaneous callers
            # is inference rather than measurement.
            $out->{ $caller->{id} }->{$devno}->{pool} = 1;
        }
    }

    return $out;
}


1;
