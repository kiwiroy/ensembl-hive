=pod

=head1 NAME

Makefile.PL - Build a Makefile

=head1 DESCRIPTION

This exists for packaging purposes only and supports addition of the hive into
a cpanfile of another project.

=cut

use 5.016003;
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME            => 'Bio::EnsEMBL::Hive',
    ABSTRACT        => 'eHive is a system for running computation pipelines on distributed computing resources - clusters, farms or grids',
    VERSION_FROM    => 'modules/Bio/EnsEMBL/Hive/Version.pm',
    PMLIBDIRS       => [qw{lib modules}],
    PMLIBPARENTDIRS => [qw{modules}],
    NO_MYMETA       => 1,
    test            => { TESTS => 't/*/*.t' },
);
