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

1;
