
use Test::Routine;
use Test::Routine::Util -all;
use Test::More;

BEGIN { use_ok('Moonpig::App::Ob') }

with ('t::lib::Role::UsesStorage');

test "load and ->new module" => sub {
  my ($self) = @_;
  local $ENV{MOONPIG_STORAGE_ROOT} = $self->tempdir;

  my $ob = Moonpig::App::Ob->new({ output_fh => undef });
  ok($ob);
};

run_me;
done_testing;
