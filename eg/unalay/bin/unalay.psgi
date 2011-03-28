#!perl
use strict;
use warnings;

use lib 'eg/unalay/lib';

my $root = $ENV{UNALAY_STORAGE_ROOT} = 'eg/unalay/db';

use File::Spec;
use HTML::Mason::PSGIHandler;
use Plack::Util;

use Unalay::Mason::Request;
use Unalay::Schema;

use namespace::autoclean;

Unalay::Schema->shared_connection->deploy;

my $h = HTML::Mason::PSGIHandler->new(
  comp_root     => File::Spec->rel2abs("eg/unalay/mason"),
  request_class => 'Unalay::Mason::Request',
);

my $handler = sub {
  my $env = shift;
  my $res = $h->handle_psgi($env);

  if ($res->[0] > 399) {
    my $headers = Plack::Util::headers( $res->[1] );
    $headers->set('Content-Type' => 'text/plain');
    $headers->remove('Content-Length');

    $res->[2] = [ "Error code $res->[0]" ];
  }

  return $res;
};
