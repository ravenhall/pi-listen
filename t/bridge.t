use strict;
use warnings;

use Test::More;
use File::Path qw(make_path remove_tree);
use File::Spec;
use JSON::PP qw(decode_json);
use Socket qw(SOCK_STREAM);
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use Pi::Listen::Bridge qw(
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

{
    package TestSocket;

    sub new {
        my ($class) = @_;
        return bless { autoflush_calls => 0 }, $class;
    }

    sub autoflush {
        my ($self) = @_;
        $self->{autoflush_calls}++;
        return 1;
    }
}

{
    package TestServer;

    sub new {
        my ($class, $client) = @_;
        return bless { client => $client, autoflush_calls => 0, accept_calls => 0 }, $class;
    }

    sub autoflush {
        my ($self) = @_;
        $self->{autoflush_calls}++;
        return 1;
    }

    sub accept {
        my ($self) = @_;
        $self->{accept_calls}++;
        return $self->{client};
    }
}

sub capture_packets {
    my ($code) = @_;
    my $buffer = '';
    open my $fh, '>', \$buffer or die "open scalar fh failed: $!";
    $code->($fh);
    close $fh;

    return [
        map { decode_json($_) }
        grep { length $_ }
        split /\n/, $buffer
    ];
}

my %defaults = default_options();
ok(!$defaults{demo}, 'demo is disabled by default');
is($defaults{model}, $ENV{PI_LISTEN_MODEL} // 'base.en', 'default model is derived from env or base.en');
like($defaults{socket}, qr{/tmp/pi-listen-\d+\.sock$}, 'default socket path is namespaced in /tmp');

{
    my ($error, $options) = parse_options('--demo', '--model', 'tiny.en', '--socket', '/tmp/test.sock', '--whisper', 'echo hi');
    is($error, undef, 'parse_options accepts valid CLI args');
    is($options->{demo}, 1, 'demo flag parsed');
    is($options->{model}, 'tiny.en', 'model flag parsed');
    is($options->{socket}, '/tmp/test.sock', 'socket flag parsed');
    is($options->{whisper}, 'echo hi', 'whisper flag parsed');
}

{
    my ($error) = parse_options('--bogus');
    is($error, "Invalid arguments\n", 'parse_options rejects unknown args');
}

{
    my $root = File::Spec->catdir($RealBin, 'tmp-test-dir');
    my $socket = File::Spec->catfile($root, 'nested', 'bridge.sock');
    remove_tree($root) if -d $root;

    ensure_socket_directory($socket);
    ok(-d File::Spec->catdir($root, 'nested'), 'ensure_socket_directory creates missing socket directories');

    cleanup_socket($socket);
    remove_tree($root);
}

{
    my $root = File::Spec->catdir($RealBin, 'tmp-cleanup');
    my $socket = File::Spec->catfile($root, 'bridge.sock');
    make_path($root);
    open my $fh, '>', $socket or die "create socket placeholder failed: $!";
    print {$fh} "placeholder";
    close $fh;

    ok(-e $socket, 'placeholder socket file exists before cleanup');
    cleanup_socket($socket);
    ok(!-e $socket, 'cleanup_socket removes existing path');
    remove_tree($root);
}

{
    my $packets = capture_packets(sub {
        my ($fh) = @_;
        emit_packet($fh, 'streaming', 'partial text', 'small.en');
    });

    is_deeply(
        $packets,
        [{ status => 'streaming', text => 'partial text', model => 'small.en' }],
        'emit_packet emits JSON lines with model, status, and text'
    );
}

{
    my @sleeps;
    my $packets = capture_packets(sub {
        my ($fh) = @_;
        run_demo($fh, 'demo.en', sub {
            my ($seconds) = @_;
            push @sleeps, $seconds;
        });
    });

    is(scalar @$packets, 3, 'run_demo emits two streaming packets and one final packet');
    is($packets->[0]{status}, 'streaming', 'first packet is streaming');
    is($packets->[1]{status}, 'streaming', 'second packet is streaming');
    is($packets->[2]{status}, 'final', 'third packet is final');
    is_deeply(\@sleeps, [0.35, 0.35, 0.10], 'run_demo uses the expected pacing');
}

{
    my @sleeps;
    local *Pi::Listen::Bridge::sleep = sub {
        my ($seconds) = @_;
        push @sleeps, $seconds;
        return 1;
    };

    my $packets = capture_packets(sub {
        my ($fh) = @_;
        run_demo($fh, 'demo-default');
    });

    is(scalar @$packets, 3, 'run_demo works with the default sleep callback');
    is_deeply(\@sleeps, [0.35, 0.35, 0.10], 'default sleep callback delegates to package sleep');
}

{
    local $ENV{PI_LISTEN_WHISPER_CMD};
    my $packets = capture_packets(sub {
        my ($fh) = @_;
        run_whisper_bridge($fh, {}, 'base.en');
    });

    is_deeply(
        $packets,
        [{ status => 'error', text => 'Set PI_LISTEN_WHISPER_CMD or start with /listen --demo.', model => 'base.en' }],
        'run_whisper_bridge reports missing command via error packet'
    );
}

{
    my $command = q{printf 'streaming\tpartial\nfinal\tcomplete\nplain fallback\n'};
    my $packets = capture_packets(sub {
        my ($fh) = @_;
        run_whisper_bridge($fh, { whisper => $command }, 'tiny.en');
    });

    is_deeply(
        $packets,
        [
            { status => 'streaming', text => 'partial', model => 'tiny.en' },
            { status => 'final', text => 'complete', model => 'tiny.en' },
            { status => 'final', text => 'plain fallback', model => 'tiny.en' },
        ],
        'run_whisper_bridge maps prefixed and fallback transcript lines'
    );
}

{
    my @calls;
    my $client = TestSocket->new();
    my $server = TestServer->new($client);

    local *Pi::Listen::Bridge::create_server = sub {
        my ($path) = @_;
        push @calls, ['create_server', $path];
        return $server;
    };
    local *Pi::Listen::Bridge::ensure_socket_directory = sub {
        my ($path) = @_;
        push @calls, ['ensure_socket_directory', $path];
        return 1;
    };
    local *Pi::Listen::Bridge::cleanup_socket = sub {
        my ($path) = @_;
        push @calls, ['cleanup_socket', $path];
        return 1;
    };
    local *Pi::Listen::Bridge::run_demo = sub {
        my ($fh, $model) = @_;
        push @calls, ['run_demo', $fh, $model];
        return 1;
    };
    local *Pi::Listen::Bridge::run_whisper_bridge = sub {
        push @calls, ['run_whisper_bridge'];
        return 1;
    };

    my $result = main('--demo', '--socket', '/tmp/demo.sock', '--model', 'tiny.en');
    is($result, 0, 'main returns success in demo mode');
    is_deeply(
        \@calls,
        [
            ['cleanup_socket', '/tmp/demo.sock'],
            ['ensure_socket_directory', '/tmp/demo.sock'],
            ['create_server', '/tmp/demo.sock'],
            ['run_demo', $client, 'tiny.en'],
            ['cleanup_socket', '/tmp/demo.sock'],
        ],
        'main orchestrates demo-mode setup and teardown in order'
    );
    is($server->{autoflush_calls}, 1, 'server autoflush is enabled');
    is($server->{accept_calls}, 1, 'server accept is invoked once');
    is($client->{autoflush_calls}, 1, 'client autoflush is enabled');
}

{
    my @calls;
    my $client = TestSocket->new();
    my $server = TestServer->new($client);

    local *Pi::Listen::Bridge::create_server = sub { return $server; };
    local *Pi::Listen::Bridge::ensure_socket_directory = sub { return 1; };
    local *Pi::Listen::Bridge::cleanup_socket = sub {
        my ($path) = @_;
        push @calls, ['cleanup_socket', $path];
        return 1;
    };
    local *Pi::Listen::Bridge::run_demo = sub {
        push @calls, ['run_demo'];
        return 1;
    };
    local *Pi::Listen::Bridge::run_whisper_bridge = sub {
        my ($fh, $options, $model) = @_;
        push @calls, ['run_whisper_bridge', $fh, $options->{socket}, $options->{whisper}, $model];
        return 1;
    };

    my $result = main('--socket', '/tmp/live.sock', '--model', 'live.en', '--whisper', 'echo hi');
    is($result, 0, 'main returns success in whisper mode');
    is_deeply(
        \@calls,
        [
            ['cleanup_socket', '/tmp/live.sock'],
            ['run_whisper_bridge', $client, '/tmp/live.sock', 'echo hi', 'live.en'],
            ['cleanup_socket', '/tmp/live.sock'],
        ],
        'main routes non-demo invocations to run_whisper_bridge'
    );
}

{
    local *Pi::Listen::Bridge::create_server = sub {
        die 'create_server should not run after parse failure';
    };

    my $error;
    eval { main('--bogus'); 1 } or $error = $@;
    like($error, qr/^Invalid arguments/, 'main dies on invalid args');
}

{
    my @calls;
    local *IO::Socket::UNIX::new = sub {
        my ($class, %args) = @_;
        push @calls, [$class, \%args];
        return 'socket-sentinel';
    };

    my $server = create_server('/tmp/create-server.sock');
    is($server, 'socket-sentinel', 'create_server delegates to IO::Socket::UNIX');
    is_deeply(
        \@calls,
        [[
            'IO::Socket::UNIX',
            {
                Type => SOCK_STREAM,
                Local => '/tmp/create-server.sock',
                Listen => 1,
            },
        ]],
        'create_server passes the expected socket arguments'
    );
}

done_testing();
