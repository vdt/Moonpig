package Moonpig::Role::Consumer;
# ABSTRACT: something that uses up money stored in a bank
use Moose::Role;
with(
  'Moonpig::Role::CanExpire',
  'Moonpig::Role::HandlesEvents',
  'Moonpig::Role::HasGuid',
  'Moonpig::Role::LedgerComponent',
  'Moonpig::Role::StubBuild',
);

use Moonpig::Behavior::EventHandlers;
implicit_event_handlers {
  return {
    'consumer-create-replacement' => {
      create_replacement => Moonpig::Events::Handler::Method->new(
        method_name => 'create_own_replacement',
      ),
    },
  };
};

use MooseX::SetOnce;
use Moonpig::Types qw(Ledger Millicents MRI);

use Moonpig::Logger '$Logger';

use namespace::autoclean;

has bank => (
  reader => 'bank',
  writer => '_set_bank',
  does   => 'Moonpig::Role::Bank',
  traits => [ qw(SetOnce) ],
  predicate => 'has_bank',
);

before _set_bank => sub {
  my ($self, $bank) = @_;

  unless ($self->ledger->guid eq $bank->ledger->guid) {
    confess sprintf(
      "cannot associate consumer from %s with bank from %s",
      $self->ledger->ident,
      $bank->ledger->ident,
    );
  }
};

sub unapplied_amount {
  my ($self) = @_;
  return $self->has_bank ? $self->bank->unapplied_amount : 0;
}

# Should take an optional parameter hash, construct a replacement object
# for this one, and install it in the ledger.
requires 'construct_replacement';

has replacement => (
  is   => 'rw',
  does => 'Moonpig::Role::Consumer',
  traits    => [ qw(SetOnce) ],
  predicate => 'has_replacement',
);

# If the consumer does not yet have a replacement, it may try to
# manufacture a replacement as described by this MRI
has replacement_mri => (
  is => 'rw',
  isa => MRI,
  required => 1,
  coerce => 1,
);

# XXX this is for testing only; when we figure out replacement semantics
has is_replaceable => (
  is => 'ro',
  isa => 'Bool',
  default => 1,
);

sub create_own_replacement {
  my ($self, $event, $arg) = @_;

  my $replacement_mri = $event->payload->{mri};

  $Logger->log([ "trying to set up replacement for %s", $self->TO_JSON ]);

  if ($self->is_replaceable && ! $self->has_replacement) {
    my $replacement = $replacement_mri->construct(
      { extra => { self => $self } }
     ) or return;
    $self->replacement($replacement);
    return $replacement;
  }
  return;
}

# the date is appended to this to make the cost path
# for this consumer's charges
has cost_path_prefix => (
  is => 'ro',
  isa => CostPath,
  coerce => 1,
  required => 1,
);

# When the object has less than this long to live, it will
# start posting low-balance events to its successor, or to itself if
# it has no successor
has old_age => (
  is => 'ro',
  required => 1,
  isa => TimeInterval,
);

1;
