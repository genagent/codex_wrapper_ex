# Test-only fixture for the Runner.Port cleanup tests. It is run as
# `perl cleanup_probe.pl DIR MODE [OUTPUT]` (so it needs no exec bit) and is not
# shipped with the package.
#
# It stands in for a native `codex`: it starts a "tool" child in a different
# process group, installs its own signal handlers, records what it receives and
# publishes the process ids the test needs. All evidence goes to files in DIR
# so the test can read it after the Port is gone.
#
# MODE chooses how the probe reacts to signals:
#
#   int         INT: record, stop and reap the tool, exit. TERM: record, exit
#               without touching the tool (so a TERM-only stop leaks the tool
#               and the test can tell it from the cooperative path).
#   ignore-int  INT: record and keep running. TERM: record, stop and reap the
#               tool, exit.
#   ignore-all  INT and TERM: record and keep running. Only KILL ends it.
#
# OUTPUT chooses what the probe writes to stdout once it is ready:
#
#   quiet       nothing (the default)
#   announce    one "ready" line
#   oversize    one line longer than the stream's 1 MiB limit
#
# Files written in DIR (each is replaced atomically, so existence means
# complete):
#
#   tool        "PID PGID" of the tool child
#   ready       key=value lines: target, target_pgid, supervisor, tool, tool_pgid
#   signals     appended "NAME EPOCH_SECONDS" lines, in delivery order
#   events      appended "tool-reaped" once the tool has been stopped and reaped
use strict;
use warnings;
use Time::HiRes qw(time sleep);

my ($dir, $mode, $output) = @ARGV;
die "usage: cleanup_probe.pl DIR MODE [OUTPUT]\n" unless defined $dir && defined $mode;
$output = 'quiet' unless defined $output;
$| = 1;

sub write_file {
    my ($name, $text) = @_;
    open(my $fh, '>', "$dir/$name.tmp") or die "open $name: $!";
    print $fh $text;
    close($fh) or die "close $name: $!";
    rename("$dir/$name.tmp", "$dir/$name") or die "rename $name: $!";
}

sub append_line {
    my ($name, $text) = @_;
    open(my $fh, '>>', "$dir/$name") or die "open $name: $!";
    print $fh "$text\n";
    close($fh) or die "close $name: $!";
}

# The tool child leaves the probe's process group, as a Codex tool child does.
# It is started before any handler is installed here, so it never runs them.
my $tool = fork();
die "fork: $!" unless defined $tool;

if ($tool == 0) {
    setpgrp(0, 0) or die "setpgrp: $!";
    # Hold none of the Port's pipes, so the tool cannot delay Port output EOF.
    open(STDIN, '<', '/dev/null') or die "reopen stdin: $!";
    open(STDOUT, '>', '/dev/null') or die "reopen stdout: $!";
    open(STDERR, '>', '/dev/null') or die "reopen stderr: $!";
    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    write_file('tool', $$ . ' ' . getpgrp(0));
    while (1) { sleep(1) }
}

my $tool_reaped = 0;

sub reap_tool {
    return if $tool_reaped;
    $tool_reaped = 1;
    kill('KILL', $tool);
    waitpid($tool, 0);
    append_line('events', 'tool-reaped');
}

sub record {
    my ($name) = @_;
    append_line('signals', sprintf('%s %.3f', $name, time()));
}

if ($mode eq 'int') {
    $SIG{INT} = sub { record('INT'); reap_tool(); exit 0 };
    $SIG{TERM} = sub { record('TERM'); exit 1 };
} elsif ($mode eq 'ignore-int') {
    $SIG{INT} = sub { record('INT') };
    $SIG{TERM} = sub { record('TERM'); reap_tool(); exit 0 };
} elsif ($mode eq 'ignore-all') {
    $SIG{INT} = sub { record('INT') };
    $SIG{TERM} = sub { record('TERM') };
} else {
    die "unknown mode: $mode\n";
}

my $deadline = time() + 5;
until (-e "$dir/tool") {
    die "tool child never started\n" if time() > $deadline;
    sleep(0.01);
}
open(my $tool_fh, '<', "$dir/tool") or die "open tool: $!";
my $tool_line = <$tool_fh>;
close($tool_fh);
my ($tool_pid, $tool_pgid) = split(' ', $tool_line);

write_file('ready', join("\n",
    "target=$$",
    'target_pgid=' . getpgrp(0),
    'supervisor=' . getppid(),
    "tool=$tool_pid",
    "tool_pgid=$tool_pgid",
) . "\n");

if ($output eq 'announce') {
    print "ready\n";
} elsif ($output eq 'oversize') {
    print 'x' x 1_200_000, "\n";
}

while (1) { sleep(0.05) }
