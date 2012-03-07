package Moonpig::Role::InvoiceCharge;
use Moose::Role;
with(
  'Moonpig::Role::Charge',
  'Moonpig::Role::HandlesEvents',
);

use namespace::autoclean;
use Moonpig::Behavior::EventHandlers;
use Moonpig::Types qw(GUID Time);
use MooseX::SetOnce;

# translate ->new({consumer => ... }) to
# ->new({ ledger_guid => ..., owner_guid => ... })
around BUILDARGS => sub {
  my $orig  = shift;
  my $class = shift;
  my $args = shift;

  if (my $consumer = delete $args->{consumer}) {
    $args->{owner_guid}  ||= $consumer->guid;
    $args->{ledger_guid} ||= $consumer->ledger->guid;
  }

  return $class->$orig($args, @_);
};

has owner_guid => (
  is   => 'ro',
#  does => 'Moonpig::Role::Consumer',
  isa => GUID,
  required => 1,
);

sub owner {
  my ($self) = @_;
  $self->ledger->consumer_collection
    ->find_by_guid({ guid => $self->owner_guid });
}

has ledger_guid => (
  is   => 'ro',
#  does => 'Moonpig::Role::Ledger',
  isa => GUID,
  required => 1,
);

has abandoned_date => (
  is => 'ro',
  isa => Time,
  predicate => 'is_abandoned',
  writer    => '__set_abandoned_date',
  traits => [ qw(SetOnce) ],
);

sub counts_toward_total { ! $_[0]->is_abandoned }

sub mark_abandoned {
  my ($self) = @_;
  $self->__set_abandoned_date( Moonpig->env->now );
}

sub ledger {
  my ($self) = @_;
  my $ledger = Moonpig->env->storage->retrieve_ledger_for_guid(
    $self->ledger_guid
  );

  return($ledger || Moonpig::X->throw("couldn't find ledger for charge"));
}

has executed_at => (
  is  => 'ro',
  isa => Time,
  predicate => 'is_executed',
  writer    => '__set_executed_at',
  traits    => [ qw(SetOnce) ],
);

sub __execute {
  # XXX: We get $ledger as a parameter here because we can't get it cheaply
  # otherwise.  This whole method should get moved somewhere else, probably.
  # -- rjbs, 2012-03-06
  my ($self, $ledger) = @_;

  Moonpig::X->throw("can't execute already-executed InvoiceCharge")
    if $self->is_executed;

  # Try to apply non-refundable credit first.  Within that, go for smaller
  # credits first. -- rjbs, 2012-03-06
  my @credits = sort { $b->is_refundable   <=> $a->is_refundable
                   || $a->unapplied_amount <=> $b->unapplied_amount }
                grep { $_->unapplied_amount }
                $ledger->credits;

  my $owner = $ledger->consumer_collection
              ->find_by_guid({ guid => $self->owner_guid });

  my $still_need = $self->amount;
  for my $credit (@credits) {
    my $to_xfer = $credit->unapplied_amount >= $still_need
                ? $still_need
                : $credit->unapplied_amount;
    $ledger->accountant->create_transfer({
      type => 'test_consumer_funding',
      from => $credit,
      to   => $owner,
      amount => $to_xfer,
    });
    $still_need -= $to_xfer;
    last if $still_need == 0;
  }

  $self->__set_executed_at( Moonpig->env->now );
}

implicit_event_handlers {
  return {
    'paid' => {
      'default' => Moonpig::Events::Handler::Noop->new,
    },
  }
};

1;
