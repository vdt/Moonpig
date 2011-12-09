package Moonpig::Role::Consumer::ByTime;
# ABSTRACT: a consumer that charges steadily as time passes

use Carp qw(confess croak);
use Moonpig;
use Moonpig::DateTime;
use Moonpig::Util qw(class days event sum);
use Moose::Role;
use MooseX::Types::Moose qw(ArrayRef Num);

use Moonpig::Logger '$Logger';
use Moonpig::Trait::Copy;

require Stick::Publisher;
Stick::Publisher->VERSION(0.20110324);
use Stick::Publisher::Publish 0.20110324;

with(
  'Moonpig::Role::Consumer::ChargesBank',
  'Moonpig::Role::Consumer::ChargesPeriodically',
  'Moonpig::Role::Consumer::InvoiceOnCreation',
  'Moonpig::Role::Consumer::MakesReplacement',
);

use Moonpig::Behavior::EventHandlers;

use Moonpig::Types qw(PositiveMillicents Time TimeInterval);

use namespace::autoclean;

sub now { Moonpig->env->now() }

sub cost_amount_on {
  my ($self, $date) = @_;

  my %costs = $self->costs_on($date);
  my $amount = sum(values %costs);

  return $amount;
}

sub invoice_costs {
  $_[0]->costs_on( Moonpig->env->now );
}

#  XXX this is period in days, which is not quite right, since a
#  charge of $10 per month or $20 per year is not any fixed number of
#  days, For example a charge of $20 annually, charged every day,
#  works out to 5479 mc per day in common years, but 5464 mc per day
#  in leap years.  -- 2010-10-26 mjd

has cost_period => (
   is => 'ro',
   required => 1,
   isa => TimeInterval,
  traits => [ qw(Copy) ],
);

after become_active => sub {
  my ($self) = @_;

  $self->grace_until( Moonpig->env->now  +  $self->grace_period_duration );

  $Logger->log([
    '%s: %s became active; grace until %s, last charge date %s',
    q{} . Moonpig->env->now,
    $self->ident,
    q{} . $self->grace_until,
    q{} . $self->last_charge_date,
  ]);
};

publish expire_date => { } => sub {
  my ($self) = @_;

  $self->has_last_charge_date ||
    confess "Can't calculate remaining life for inactive consumer";
  my $bank = $self->bank ||
    confess "Can't calculate remaining life for unfunded consumer";
  my $remaining = $bank->unapplied_amount();

  my $n_charge_periods_left
    = int($remaining / $self->calculate_charge_on( Moonpig->env->now ));

  return $self->next_charge_date() +
      $n_charge_periods_left * $self->charge_frequency;
};

# returns amount of life remaining, in seconds
sub remaining_life {
  my ($self, $when) = @_;
  $when ||= $self->now();
  $self->expire_date - $when;
}

sub will_die_soon { 0 } # Provided by MakesReplacement

################################################################
#
#

has grace_until => (
  is  => 'rw',
  isa => Time,
  clearer   => 'clear_grace_until',
  predicate => 'has_grace_until',
  traits => [ qw(Copy) ],
);

has grace_period_duration => (
  is  => 'rw',
  isa => TimeInterval,
  default => days(3),
  traits => [ qw(Copy) ],
);

sub in_grace_period {
  my ($self) = @_;

  return unless $self->has_grace_until;

  return $self->grace_until >= Moonpig->env->now;
}

################################################################
#
#

around charge => sub {
  my $orig = shift;
  my ($self, @args) = @_;

  return if $self->in_grace_period;
  return unless $self->is_active;

  $self->$orig(@args);
};

around charge_one_day => sub {
  my $orig = shift;
  my ($self, @args) = @_;

  unless ($self->can_make_payment_on( $self->next_charge_date )) {
    $self->expire;
    return;
  }

  $self->$orig(@args);
};

# how much do we charge each time we issue a new charge?
sub calculate_charges_on {
  my ($self, $date) = @_;

  my $n_periods = $self->cost_period / $self->charge_frequency;

  my @costs = $self->costs_on( $date );

  $costs[$_] /= $n_periods for grep { $_ % 2 } keys @costs;

  return @costs;
}

sub calculate_charge_on {
  my ($self, $date) = @_;
  my @costs = $self->calculate_charges_on( $date );
  my $charge = sum(map { $costs[$_] } grep { $_ % 2 } keys @costs);

  return $charge;
}

sub can_make_payment_on {
  my ($self, $date) = @_;
  return $self->unapplied_amount >= $self->calculate_charge_on($date);
}

# My predecessor is running out of money
sub predecessor_running_out {
  my ($self, $event, $args) = @_;
  my $remaining_life = $event->payload->{remaining_life}  # In seconds
    or confess("predecessor didn't advise me how long it has to live");
}

1;
