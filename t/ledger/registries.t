#!/usr/bin/env perl
use Test::Routine;
use Test::Routine::Util -all;

use Test::Fatal;
use Test::More;

use t::lib::TestEnv;

with(
  'Moonpig::Test::Role::LedgerTester',
);

use t::lib::Logger '$Logger';
use Moonpig::Test::Factory qw(do_with_fresh_ledger);

use Data::GUID qw(guid_string);
use List::Util qw(sum);
use Moonpig::Util qw(class days dollars event);

use namespace::autoclean;

sub random_xid {
  return 'urn:uuid:' . guid_string;
}

sub _test_ledgers_and_xids {
  my ($self) = @_;

  my (%ledger, %xid);

  for my $key (qw(1 2)) {
    $xid{ $key }    = $self->random_xid;
    $ledger{$key} = do_with_fresh_ledger({
        consumer => {
            class            => class('Consumer::Dummy'),
            xid              => $xid{$key},
            make_active      => 1,
            replacement_plan => [ get => '/nothing' ],
        }}, sub { return $_[0] })}

  return( \%ledger, \%xid );
}

test "global xid lookup" => sub {
  my ($self) = @_;

  Moonpig->env->storage->do_rw(sub {
    my ($ledger, $xid) = $self->_test_ledgers_and_xids;

    for my $id (1, 2) {
      my $got_ledger = Moonpig->env->storage->retrieve_ledger_active_for_xid(
        $xid->{$id}
      );

      isa_ok(
        $got_ledger,
        ref($ledger->{$id}),
        "ledger for xid $id"
      );

      is(
        $got_ledger->guid,
        $ledger->{$id}->guid,
        "xid $id -> ledger $id",
      );
    }
  });
};

test "one-ledger-per-xid safety" => sub {
  my ($self) = @_;

  my ($lhash, $xid) = $self->_test_ledgers_and_xids;

  my $err = exception {
    Moonpig->env->storage->do_with_ledger($lhash->{1}->guid, sub {
      my ($ledger) = @_;
      $ledger->add_consumer(
        class(qw(Consumer::Dummy)),
        {
          xid                => $xid->{2},
          make_active        => 1,

          replacement_plan    => [ get => '/nothing' ],
        },
      );
    })};

  ok($err, "we can't register 1 id with 2 ledgers");

  {
    local $TODO = "err msg currently provided by SQLite";
    like($err, qr/already registered/, "can't register 1 xid with 2 ledgers");
  }
};

test "registered abandoned xid" => sub {
  my ($self) = @_;

  my ($ledger, $xid) = $self->_test_ledgers_and_xids;

  # first, ensure that both X-1 and X-2 are taken by L-1 and L-2
  Moonpig->env->storage->do_rw(sub {
    for (1, 2) {
      is(
        Moonpig->env->storage->retrieve_ledger_active_for_xid($xid->{$_})->guid,
        $ledger->{$_}->guid,
        "xid $_ -> ledger $_",
      );
    }
  });

  Moonpig->env->storage->do_with_ledger($ledger->{1}->guid, sub {
    my ($ledger) = @_;
    my $consumer = $ledger->active_consumer_for_xid($xid->{1});
    $consumer->handle_event(event('terminate'));
  });

  Moonpig->env->storage->do_rw(sub {
    # now, active(X-1) is unclaimed
    is(
      Moonpig->env->storage->retrieve_ledger_active_for_xid($xid->{1}),
      undef,
      "xid 1 -> (nothing)",
    );

    # but unambiguous(X-1) should go to L-1, as the only once-held-it ledger
    is(
      Moonpig->env->storage->retrieve_ledger_unambiguous_for_xid($xid->{1})->guid,
      $ledger->{1}->guid,
      "xid 1 -> ledger 1",
    );

    # ...and X-2 is still L-2
    is(
      Moonpig->env->storage->retrieve_ledger_active_for_xid($xid->{2})->guid,
      $ledger->{2}->guid,
      "xid 2 -> ledger 2",
    );
  });

  # Since X-1 is unclaimed, we can give it to L-2
  Moonpig->env->storage->do_with_ledger($ledger->{2}->guid, sub {
    my ($ledger) = @_;
    $ledger->add_consumer(
      class(qw(Consumer::Dummy)),
      {
        xid                => $xid->{1},
        make_active        => 1,

        replacement_plan    => [ get => '/nothing' ],
      });
  });

  # Now make sure that both X-1 and X-2 are on L-2
  Moonpig->env->storage->do_rw(sub {
    for (1, 2) {
      my $got_ledger = Moonpig->env->storage->retrieve_ledger_active_for_xid($xid->{$_});

      is(
        $got_ledger->guid,
        $ledger->{2}->guid,
        "xid $_ -> ledger 2",
      );
    }
  });

  Moonpig->env->storage->do_with_ledger($ledger->{2}->guid, sub {
    my ($ledger) = @_;
    my $consumer = $ledger->active_consumer_for_xid($xid->{1});
    $consumer->handle_event(event('terminate'));
  });

  # unambiguous(X-1) is now nothing, since there is no unambiguous answer
  is(
    Moonpig->env->storage->retrieve_ledger_unambiguous_for_xid($xid->{1}),
    undef,
    "xid 1 -> (nothing)",
  );
};

run_me;
done_testing;
