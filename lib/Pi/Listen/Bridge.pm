package Pi::Listen::Bridge;

use strict;
use warnings;

use Exporter qw(import);
use File::Path qw(make_path);
use Getopt::Long qw(GetOptionsFromArray);
use IO::Handle;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json);
use Time::HiRes qw(sleep);

our @EXPORT_OK = qw(
    cleanup_socket
    create_server
    default_options
    emit_packet
    ensure_socket_directory
    main
    parse_options
    run_demo
    run_whisper_bridge
);

sub default_options {
    return (
        demo   => 0,
        model  => $ENV{PI_LISTEN_MODEL} // 'base.en',
        socket => "/tmp/pi-listen-$$.sock",
    );
}

sub parse_options {
    my (@argv) = @_;
    my %options = default_options();

    my $ok;
    {
        local $SIG{__WARN__} = sub { };
        $ok = GetOptionsFromArray(
            \@argv,
            \%options,
            'demo',
            'model=s',
            'socket=s',
            'whisper=s',
        );
    }

    return ($ok ? undef : "Invalid arguments\n", \%options, \@argv);
}

sub ensure_socket_directory {
    my ($socket_path) = @_;
    return unless defined $socket_path;

    my $socket_dir = $socket_path;
    $socket_dir =~ s{/[^/]+$}{};
    return if !$socket_dir || -d $socket_dir;

    make_path($socket_dir);
}

sub cleanup_socket {
    my ($path) = @_;
    unlink $path if defined $path && -e $path;
}

sub create_server {
    my ($socket_path) = @_;
    return IO::Socket::UNIX->new(
        Type   => SOCK_STREAM,
        Local  => $socket_path,
        Listen => 1,
    );
}

sub emit_packet {
    my ($client_fh, $status, $text, $model) = @_;
    print {$client_fh} encode_json({
        status => $status,
        text   => $text,
        model  => $model,
    }) . "\n";
}

sub run_demo {
    my ($client_fh, $model, $sleep_fn) = @_;
    $sleep_fn ||= sub {
        my ($seconds) = @_;
        sleep($seconds);
    };

    my @partials = (
        'open the deployment notes',
        'open the deployment notes and summarize the rollback path',
    );

    for my $partial (@partials) {
        emit_packet($client_fh, 'streaming', $partial, $model);
        $sleep_fn->(0.35);
    }

    emit_packet($client_fh, 'final', 'open the deployment notes and summarize the rollback path', $model);
    $sleep_fn->(0.10);
}

sub run_whisper_bridge {
    my ($client_fh, $opt, $model) = @_;

    my $whisper_cmd = $opt->{whisper} // $ENV{PI_LISTEN_WHISPER_CMD};
    if (!$whisper_cmd) {
        emit_packet(
            $client_fh,
            'error',
            'Set PI_LISTEN_WHISPER_CMD or start with /listen --demo.',
            $model,
        );
        return 0;
    }

    my $pid = open(my $whisper_fh, '-|', '/bin/sh', '-lc', $whisper_cmd);
    if (!$pid) {
        emit_packet($client_fh, 'error', "Cannot execute whisper command: $!", $model);
        return 0;
    }

    $whisper_fh->autoflush(1);

    my $saw_packet = 0;
    my $saw_error = 0;

    while (my $line = <$whisper_fh>) {
        chomp $line;
        next if $line =~ /^\s*$/;

        if ($line =~ /^(streaming|final|error)\t(.*)$/s) {
            $saw_packet = 1;
            $saw_error = 1 if $1 eq 'error';
            emit_packet($client_fh, $1, $2, $model);
            next;
        }

        $saw_packet = 1;
        emit_packet($client_fh, 'final', $line, $model);
    }

    waitpid($pid, 0);
    my $exit_status = $? >> 8;
    my $signal = $? & 127;

    if (!$saw_packet) {
        emit_packet($client_fh, 'error', 'Speech backend exited before producing transcript output.', $model);
        return 0;
    }

    return 0 if $saw_error || $exit_status != 0 || $signal != 0;
    return 1;
}

sub main {
    my (@argv) = @_;
    my ($error, $options) = parse_options(@argv);
    if ($error) {
        die $error;
    }

    my $socket_path = $options->{socket};
    cleanup_socket($socket_path);
    ensure_socket_directory($socket_path);

    my $server = create_server($socket_path)
        or die "Cannot create socket at $socket_path: $!\n";

    $server->autoflush(1);

    local $SIG{INT} = sub {
        cleanup_socket($socket_path);
        exit 0;
    };

    local $SIG{TERM} = sub {
        cleanup_socket($socket_path);
        exit 0;
    };

    my $client = $server->accept()
        or die "Cannot accept socket client: $!\n";

    $client->autoflush(1);

    if ($options->{demo}) {
        run_demo($client, $options->{model});
        cleanup_socket($socket_path);
        return 0;
    }

    my $ok = run_whisper_bridge($client, $options, $options->{model});
    cleanup_socket($socket_path);
    return $ok ? 0 : 1;
}

1;
